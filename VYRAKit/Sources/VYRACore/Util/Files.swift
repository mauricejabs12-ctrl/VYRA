import Foundation

/// Datei-Hilfen mit derselben Sorgfalt wie unter Windows (erst temporaer schreiben, dann ersetzen).
public enum FS {
    public static var fm: FileManager { FileManager.default }
    public static func exists(_ p: String) -> Bool { fm.fileExists(atPath: p) }
    public static func isDir(_ p: String) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue }
    public static func isFile(_ p: String) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: p, isDirectory: &d) && !d.boolValue }
    public static func size(_ p: String) -> Int64 { ((try? fm.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.int64Value ?? 0 }
    public static func modified(_ p: String) -> Date { ((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date) ?? .distantPast }
    public static func mkdir(_ p: String) throws { try fm.createDirectory(atPath: p, withIntermediateDirectories: true) }
    public static func join(_ a: String, _ parts: String...) -> String {
        var u = URL(fileURLWithPath: a)
        for p in parts { u.appendPathComponent(p) }
        return u.path
    }
    public static func join(_ a: String, _ parts: [String]) -> String {
        var u = URL(fileURLWithPath: a)
        for p in parts { u.appendPathComponent(p) }
        return u.path
    }
    public static func fileName(_ p: String) -> String { (p as NSString).lastPathComponent }
    public static func dirName(_ p: String) -> String { (p as NSString).deletingLastPathComponent }
    /// Endung mit Punkt (wie `Path.GetExtension`), sonst "".
    public static func ext(_ p: String) -> String {
        let n = fileName(p)
        guard let dot = n.lastIndex(of: "."), dot != n.startIndex else { return "" }
        return String(n[dot...])
    }
    public static func stem(_ p: String) -> String {
        let n = fileName(p)
        guard let dot = n.lastIndex(of: "."), dot != n.startIndex else { return n }
        return String(n[..<dot])
    }
    public static func full(_ p: String) -> String { URL(fileURLWithPath: p).standardizedFileURL.path }
    public static func read(_ p: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: p)) }
    public static func readText(_ p: String) throws -> String { String(decoding: try read(p), as: UTF8.self) }
    public static func delete(_ p: String) { try? fm.removeItem(atPath: p) }
    /// Schreibt atomar: erst in eine temporaere Datei daneben, dann ersetzen.
    public static func writeAtomic(_ p: String, _ data: Data) throws {
        let dir = dirName(p)
        if !dir.isEmpty { try mkdir(dir) }
        let tmp = p + "." + newId() + ".tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmp))
            // rename(2) ersetzt die Zieldatei atomar (wie File.Replace unter Windows).
            if rename(tmp, p) != 0 { throw VyraError("Datei konnte nicht gespeichert werden: " + fileName(p) + " (" + String(cString: strerror(errno)) + ")", .io) }
        } catch {
            delete(tmp)
            throw error
        }
        delete(tmp)
    }
    public static func writeAtomic(_ p: String, text: String, bom: Bool = false) throws { try writeAtomic(p, TextCodec.utf8(text, bom: bom)) }
    public static func write(_ p: String, _ data: Data) throws {
        let dir = dirName(p); if !dir.isEmpty { try mkdir(dir) }
        try data.write(to: URL(fileURLWithPath: p))
    }
    public static func write(_ p: String, text: String, bom: Bool = false) throws { try write(p, TextCodec.utf8(text, bom: bom)) }
    public static func list(_ dir: String) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted().map { join(dir, $0) } }
    public static func files(_ dir: String) -> [String] { list(dir).filter { isFile($0) } }
    public static func dirs(_ dir: String) -> [String] { list(dir).filter { isDir($0) } }
    /// Alle Dateien rekursiv (ohne symbolischen Verknuepfungen zu folgen).
    public static func allFiles(_ dir: String, limit: Int = 200_000) -> [String] {
        var out = [String]()
        var stack = [dir]
        while let cur = stack.popLast() {
            for p in list(cur) {
                if isSymlink(p) { continue }
                if isDir(p) { stack.append(p) } else { out.append(p); if out.count >= limit { return out.sorted() } }
            }
        }
        return out.sorted()
    }
    public static func isSymlink(_ p: String) -> Bool {
        ((try? fm.attributesOfItem(atPath: p))?[.type] as? FileAttributeType) == .typeSymbolicLink
    }
    public static func freeSpace(_ path: String) -> Int64 {
        #if os(iOS)
        if let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage { return v }
        #endif
        if let a = try? fm.attributesOfFileSystem(forPath: path), let f = a[.systemFreeSize] as? NSNumber { return f.int64Value }
        return Int64.max
    }
    public static func newId() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    /// Relativer Pfad mit "/" (fuer ZIP-Eintraege und Projektdateien).
    public static func relative(_ path: String, to root: String) -> String {
        let r = full(root).trimEnd("/") + "/"
        let p = full(path)
        return p.hasPrefix(r) ? String(p.dropFirst(r.count)) : fileName(p)
    }
    /// Pfad bleibt innerhalb von `root` (Schutz vor "../").
    public static func isInside(_ path: String, _ root: String) -> Bool {
        let r = full(root).trimEnd("/") + "/"
        let p = full(path)
        return p == full(root) || p.hasPrefix(r)
    }
}

/// Ablageorte der App. Unter iOS: Daten in »Application Support/VYRA«, Ergebnisse in »Dokumente/VYRA KI«
/// (in der Dateien-App unter »Auf meinem iPhone › VYRA KI« sichtbar).
public final class VyraPaths {
    public let dataRoot: String
    public let documents: String
    public init(dataRoot: String, documents: String) {
        self.dataRoot = dataRoot; self.documents = documents
        try? FS.mkdir(dataRoot); try? FS.mkdir(documents)
    }
    public static func standard() -> VyraPaths {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("VYRA").path
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("VYRA KI").path
        return VyraPaths(dataRoot: support, documents: docs)
    }
    /// Wie `data` unter Windows (%LOCALAPPDATA%\VYRA).
    public var data: String { dataRoot }
    public var ki: String { FS.join(dataRoot, "KI") }
    public var models: String { FS.join(dataRoot, "KI", "Modelle") }
    public var settingsFile: String { FS.join(dataRoot, "VYRA-NOVA.cfg") }
    /// Wie `DocWriter.DefaultFolder()` (Dokumente\VYRA KI).
    public var results: String { documents }
    public var apps: String { FS.join(documents, "Apps") }
    public var books: String { FS.join(documents, "Bücher") }
}
