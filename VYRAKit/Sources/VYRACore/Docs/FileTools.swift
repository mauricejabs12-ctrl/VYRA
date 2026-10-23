import Foundation

// ---------------------------------------------------------------- Dateien in freigegebenen Ordnern (aus `FileTools`)
// iOS: Ordner werden ueber die Dateien-App freigegeben (Ordnerauswahl mit dauerhafter Freigabe/Bookmark). Die App startet
// den Zugriff, bevor sie FileTools mit den freigegebenen Pfaden anlegt. Nichts wird geloescht oder ueberschrieben.
public final class FileEntry {
    public var path = "", name = "", rel = ""
    public var bytes: Int64 = 0
    public var folder = false
}
public final class MoveOp {
    public var from = "", to = "", reason = ""
    public var done = false
    public init(_ from: String = "", _ to: String = "", _ reason: String = "") { self.from = from; self.to = to; self.reason = reason }
}
public final class FileTools {
    public private(set) var roots = [String]()
    public static var readable: [String] { DocReader.readable }
    public init(_ approved: [String]?) {
        for a in approved ?? [] {
            let t = a.trimmed
            if t.isEmpty { continue }
            let f = FS.full(t).trimEnd("/")
            if FS.isDir(f) && !FileTools.blocked(f) { roots.append(f) }
        }
    }
    /// Systemordner und Wurzeln sind nie freigebbar.
    public static func blocked(_ full: String) -> Bool {
        let f = full.trimEnd("/")
        if f.trimmed.isEmpty || f.len <= 3 { return true }
        for p in ["/System", "/usr", "/bin", "/sbin", "/private/var/mobile/Library", "/Applications"] where f == p || f.hasPrefix(p + "/") { return true }
        let home = FS.full(NSHomeDirectory()).trimEnd("/")
        if f == home { return true }
        return false
    }
    public func rootOf(_ path: String) -> String? {
        let f = FS.full(path).trimEnd("/")
        for r in roots where f == r || f.hasPrefix(r + "/") { return r }
        return nil
    }
    public func allowed(_ path: String) -> Bool { rootOf(path) != nil }
    public func list(_ folder: String, _ maxDepth: Int, _ max: Int) throws -> [FileEntry] {
        var list = [FileEntry]()
        if !allowed(folder) { throw VyraError("Dieser Ordner ist für VYRA KI nicht freigegeben.", .invalidOperation) }
        let root = FS.full(folder).trimEnd("/")
        walk(root, root, 0, maxDepth, max, &list)
        return list
    }
    func walk(_ root: String, _ dir: String, _ depth: Int, _ maxDepth: Int, _ max: Int, _ list: inout [FileEntry]) {
        if list.count >= max { return }
        let items = FS.list(dir)
        let files = items.filter { FS.isFile($0) }.sorted { $0.lowercased() < $1.lowercased() }
        let dirs = items.filter { FS.isDir($0) }.sorted { $0.lowercased() < $1.lowercased() }
        for f in files {
            if list.count >= max { return }
            let name = FS.fileName(f)
            if name.hasPrefix(".") { continue }
            let e = FileEntry(); e.path = f; e.name = name; e.rel = rel(root, f); e.bytes = FS.size(f); list.append(e)
        }
        for d in dirs {
            if list.count >= max { return }
            let name = FS.fileName(d)
            if name.hasPrefix(".") || FS.isSymlink(d) { continue }
            let e = FileEntry(); e.path = d; e.name = name; e.rel = rel(root, d); e.folder = true; list.append(e)
            if depth < maxDepth { walk(root, d, depth + 1, maxDepth, max, &list) }
        }
    }
    func rel(_ root: String, _ p: String) -> String { p.len > root.len ? p.sub(root.len).trimStart("/") : "" }
    public func readText(_ path: String, _ maxChars: Int) throws -> String {
        if !allowed(path) { throw VyraError("Diese Datei liegt nicht in einem freigegebenen Ordner.", .invalidOperation) }
        return try DocReader.read(path, maxChars)
    }
    /// Pruefen: Quelle existiert und liegt im freigegebenen Ordner, Ziel ebenfalls; nichts wird ueberschrieben oder geloescht.
    public func validate(_ folder: String, _ ops: [MoveOp], _ problems: inout [String]) -> [MoveOp] {
        var ok = [MoveOp]()
        var used = Set<String>()
        guard let root = rootOf(folder) else { problems.append("Ordner nicht freigegeben."); return ok }
        let baseDir = FS.full(folder).trimEnd("/")
        for o in ops {
            var from = FS.full(o.from.hasPrefix("/") ? o.from : FS.join(baseDir, o.from))
            var to = FS.full(o.to.hasPrefix("/") ? o.to : FS.join(baseDir, o.to))
            if !FS.exists(from) { problems.append("Nicht gefunden: " + o.from); continue }
            if !allowed(from) || !allowed(to) { problems.append("Außerhalb des freigegebenen Ordners: " + o.from + " → " + o.to); continue }
            if from.trimEnd("/") == root { problems.append("Der freigegebene Ordner selbst wird nicht verschoben."); continue }
            if from.lowercased() == to.lowercased() { continue }
            if FS.isDir(to) && FS.isFile(from) { to = FS.join(to, FS.fileName(from)) }
            let stem = FS.join(FS.dirName(to), FS.stem(to)), ext = FS.ext(to)
            var n = 2
            while FS.exists(to) || used.contains(to.lowercased()) { to = stem + " (\(n))" + ext; n += 1 }
            used.insert(to.lowercased())
            from = FS.full(from)
            ok.append(MoveOp(from, to, o.reason))
        }
        return ok
    }
    /// Fuehrt bestaetigte Verschiebungen aus und schreibt eine Rueckgaengig-Datei.
    public func execute(_ ops: [MoveOp], _ undoFolder: String) throws -> String {
        var done = [Any]()
        for o in ops {
            if !allowed(o.from) || !allowed(o.to) { continue }
            try FS.mkdir(FS.dirName(o.to))
            if FS.exists(o.from) { try FS.fm.moveItem(atPath: o.from, toPath: o.to); o.done = true }
            if o.done { done.append(Json.obj(("from", o.from), ("to", o.to))) }
        }
        try FS.mkdir(undoFolder)
        let file = FS.join(undoFolder, "Rueckgaengig-" + DE.stamp(Date(), "yyyyMMdd-HHmmss") + ".json")
        try FS.write(file, text: Json.serialize(Json.obj(("format", "vyra-ki-moves-1"), ("moves", done))))
        return file
    }
    public func undo(_ undoFile: String) throws -> Int {
        let o = try Json.parse(try FS.readText(undoFile))
        let moves = Json.arr(o, "moves")
        var n = 0
        for m in moves.reversed() {
            let from = Json.str(m, "from"), to = Json.str(m, "to")
            if !allowed(from) || !allowed(to) { continue }
            if FS.exists(to) && !FS.exists(from) {
                try? FS.mkdir(FS.dirName(from))
                if (try? FS.fm.moveItem(atPath: to, toPath: from)) != nil { n += 1 }
            }
        }
        return n
    }
}
