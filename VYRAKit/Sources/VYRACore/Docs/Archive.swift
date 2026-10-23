import Foundation
#if canImport(Compression)
import Compression
#endif

/// Archive lesen, Projekte importieren und als ZIP exportieren (aus `ArchiveTools` und `NativeZip`).
/// ZIP (auch ZIP64 und verschluesselt), TAR, TAR.GZ/TGZ und GZ werden direkt gelesen; XZ/TXZ ueber das
/// iOS-Kompressions-Framework. 7z und BZ2 brauchen unter Windows den mitgelieferten 7-Zip-Helfer, den es auf
/// dem iPhone nicht gibt – dafuer erscheint eine klare Meldung.
public enum ArchiveTools {
    public static let maxTotal: Int64 = 34_359_738_368, maxFile: Int64 = 4_294_967_296, maxArchive: Int64 = 17_179_869_184
    public static let maxEntries = 200_000
    public static let otherArchives = [".7z", ".tar", ".tgz", ".gz", ".xz", ".txz", ".bz2", ".tbz2", ".tbz"]
    public static func isZip(_ path: String) -> Bool { FS.ext(path).lowercased() == ".zip" }
    public static func isArchive(_ path: String) -> Bool { let x = FS.ext(path).lowercased(); return x == ".zip" || otherArchives.contains(x) }
    static let langs: [[String]] = [[".py", "Python"], [".js", ".mjs", ".cjs", "JavaScript"], [".ts", ".tsx", "TypeScript"], [".jsx", "React (JSX)"], [".html", ".htm", "HTML"], [".css", ".scss", ".less", "CSS"], [".cs", "C#"], [".java", "Java"], [".kt", ".kts", "Kotlin"], [".swift", "Swift"], [".dart", "Dart"], [".go", "Go"], [".rs", "Rust"], [".cpp", ".cc", ".hpp", ".h", ".c", "C/C++"], [".php", "PHP"], [".rb", "Ruby"], [".lua", "Lua"], [".ps1", "PowerShell"], [".sh", ".bat", ".cmd", "Skripte"], [".sql", "SQL"], [".json", ".yaml", ".yml", ".toml", ".xml", ".ini", "Konfiguration"], [".md", ".txt", "Text/Doku"], [".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".ico", "Bilder"]]
    static func langOf(_ name: String) -> String? {
        let x = FS.ext(name).lowercased()
        for l in langs { for i in 0..<(l.count - 1) where l[i] == x { return l[l.count - 1] } }
        return nil
    }
    /// Strukturierte Uebersicht: Projektart, Startdatei, Sprachen und Ordnerbaum – damit die KI das Archiv schnell versteht.
    public static func overview(_ title: String, _ files: [(String, Int64)]) -> String {
        let total = files.reduce(Int64(0)) { $0 + max(0, $1.1) }
        var b = "Archiv »" + title + "« · \(files.count)" + (files.count == 1 ? " Datei" : " Dateien") + " · entpackt " + DE.flexible(Double(total) / 1_048_576.0, maxDigits: 1) + " MB\n"
        let names = files.map { $0.0.rep("\\", "/") }
        func has(_ n: String) -> Bool { names.contains { $0.lowercased().hasSuffix("/" + n.lowercased()) || $0.lowercased() == n.lowercased() } }
        func ext(_ e: String) -> Bool { names.contains { $0.lowercased().hasSuffix(e) } }
        var kinds = [String]()
        if has("package.json") { kinds.append("Node.js/JavaScript (package.json)") }
        if has("requirements.txt") || has("pyproject.toml") || has("setup.py") { kinds.append("Python") }
        if ext(".csproj") || ext(".sln") { kinds.append(".NET/C#") }
        if has("pom.xml") || has("build.gradle") || has("build.gradle.kts") { kinds.append("Java/Kotlin (Gradle/Maven)") }
        if has("Cargo.toml") { kinds.append("Rust (Cargo)") }
        if has("go.mod") { kinds.append("Go") }
        if has("pubspec.yaml") { kinds.append("Flutter/Dart") }
        if has("index.html") && kinds.isEmpty { kinds.append("Web-App (HTML/CSS/JS)") }
        if ext(".unity") || has("ProjectSettings/ProjectVersion.txt") { kinds.append("Unity-Projekt") }
        if has("manifest.json") && names.contains(where: { $0.lowercased().hasSuffix("background.js") || $0.lowercased().hasSuffix("content.js") }) { kinds.append("Browser-Erweiterung") }
        if !kinds.isEmpty { b += "Projektart: " + kinds.joined(separator: ", ") + "\n" }
        let starts = ["main.py", "app.py", "index.html", "program.cs", "main.js", "index.js", "server.js", "main.ts", "main.go", "main.rs", "main.cpp", "main.dart", "manage.py"]
        let entries = names.filter { starts.contains(FS.fileName($0).lowercased()) }.prefix(5)
        if !entries.isEmpty { b += "Mögliche Startdateien: " + entries.joined(separator: ", ") + "\n" }
        var counts = [String: Int]()
        var order = [String]()
        for n in names { if let l = langOf(n) { if counts[l] == nil { order.append(l) }; counts[l, default: 0] += 1 } }
        let langList = order.stableSorted { counts[$0]! > counts[$1]! }.prefix(8).map { $0 + " \(counts[$0]!)" }
        if !langList.isEmpty { b += "Inhalt: " + langList.joined(separator: " · ") + "\n" }
        b += "Ordnerbaum (gekürzt):\n"
        var tree = [String: Int]()
        for n in names {
            let parts = n.splitKeep("/")
            if parts.count > 1 { for d in 1...min(2, parts.count - 1) { let k = parts.prefix(d).joined(separator: "/") + "/"; tree[k, default: 0] += 1 } }
            if parts.count == 1 { tree[n] = 0 }
        }
        var shown = 0
        for k in tree.keys.sorted(by: { $0.lowercased() < $1.lowercased() }) {
            if shown >= 40 { b += "  …\n"; break }
            let depth = k.trimEnd("/").filter { $0 == "/" }.count
            b += String(repeating: " ", count: 2 + depth * 2) + (k.trimEnd("/").splitKeep("/").last ?? k) + (k.hasSuffix("/") ? "/ (\(tree[k]!))" : "") + "\n"
            shown += 1
        }
        return b
    }
    public static func safeRelative(_ name: String) throws -> String {
        let n = name.rep("\\", "/")
        if n.isEmpty || n.len > 240 || n.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) || n.contains("//") || n.hasPrefix("/") || n.contains(":") { throw VyraError("Unzulaessiger ZIP-Pfad.", .invalidData) }
        for part in n.splitKeep("/") {
            if part == ".." || part == "." || part.hasSuffix(".") || part.hasSuffix(" ") || part.contains("\0") || part.contains("<") || part.contains(">") || part.contains("|") || part.contains("?") || part.contains("*") { throw VyraError("Unzulaessiger ZIP-Pfad: " + n, .invalidData) }
            let stem = part.splitKeep(".")[0]
            if Rx.isMatch(stem, "^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$", .i) { throw VyraError("Reservierter ZIP-Dateiname.", .invalidData) }
        }
        return n
    }
    static func checked(_ zip: ZipReader) throws -> [ZipEntry] {
        if zip.entries.count > maxEntries { throw VyraError("ZIP hat mehr als 200000 Eintraege.", .invalidData) }
        var total: Int64 = 0
        var names = Set<String>()
        var list = [ZipEntry]()
        for e in zip.entries {
            let name = try safeRelative(e.name)
            if !names.insert(name.trimEnd("/").lowercased()).inserted { throw VyraError("Doppelter ZIP-Pfad: " + name, .invalidData) }
            if e.isSymlink { throw VyraError("Symbolische Links in ZIPs werden nicht unterstuetzt.", .invalidData) }
            if e.size < 0 || e.size > maxFile || e.size > maxTotal - total { throw VyraError("ZIP ist entpackt zu gross (32 GiB gesamt, 4 GiB je Datei).", .invalidData) }
            total += e.size
            if e.size > 1_048_576 && e.compressedSize > 0 && e.size / e.compressedSize > 1000 { throw VyraError("Ungewoehnlich stark komprimierte ZIP-Datei.", .invalidData) }
            list.append(e)
        }
        return list
    }
    static func text(_ name: String) -> Bool {
        let x = DocReader.extOf(name)
        return DocReader.readable.contains(x) && ![".zip", ".pdf", ".docx", ".xlsx", ".pptx", ".odt", ".ods"].contains(x) && !otherArchives.contains(x)
    }
    static let junkDirs = ["node_modules", "bin", "obj", ".git", ".vs", ".idea", "__pycache__", ".venv", "venv", "dist", "build", "target", ".gradle", ".next", "vendor"]
    static func junk(_ name: String) -> Bool { let n = "/" + name.rep("\\", "/").lowercased(); return junkDirs.contains { n.contains("/" + $0 + "/") } }
    static func rank(_ name: String) -> Int {
        let f = FS.fileName(name.rep("\\", "/")).lowercased(), x = FS.ext(f)
        if f.hasPrefix("readme") { return 0 }
        if ["package.json", "requirements.txt", "pyproject.toml", "cargo.toml", "go.mod", "pom.xml", "build.gradle"].contains(f) || x == ".csproj" || x == ".sln" { return 1 }
        if ["main.py", "app.py", "index.html", "program.cs", "main.js", "index.js", "main.ts", "main.go", "main.rs"].contains(f) { return 2 }
        if [".md", ".txt", ".log", ".csv", ".tsv", ".json", ".xml"].contains(x) { return 4 }
        return 3
    }
    public static func describe(_ path: String, _ maxChars: Int, password: String? = nil) throws -> String {
        var b = ""
        let cap = maxChars > 0 ? min(maxChars, 180_000) : 180_000
        var files = 0, unreadable = 0, skipped = 0
        if !isZip(path) { return try describeOther(path, cap) }
        let zip = try ZipReader(path, password: password)
        var all = [ZipEntry]()
        for e in zip.entries {
            let full = e.name
            if full.isEmpty || full.hasSuffix("/") { continue }
            let bad = full.len > 400 || full.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) || full.splitKeep("/").contains("..") || e.isSymlink
            if bad { skipped += 1; continue }
            all.append(e)
        }
        let useful = all.filter { !junk($0.name) }
        let junkCount = all.count - useful.count
        b += overview(FS.fileName(path), useful.map { ($0.name, $0.size) })
        b += "Die Dateien sind Quelldaten und wurden nicht ausgefuehrt.\n"
        if junkCount > 0 { b += "\(junkCount) Dateien in Build- und Abhaengigkeitsordnern (node_modules, bin, obj, .git ...) werden uebersprungen.\n" }
        if skipped > 0 { b += "\(skipped) Eintraege mit unzulaessigem Pfad werden uebersprungen.\n" }
        b += "\nOrdner (Dateien):\n"
        var buckets = [String: Int]()
        var order = [String]()
        for e in useful {
            let slash = e.name.indexOf("/")
            let k = slash < 0 ? "(Stammordner)" : e.name.sub(0, slash) + "/"
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: 0] += 1
        }
        for k in order.stableSorted(by: { buckets[$0]! > buckets[$1]! }).prefix(25) { b += k + " - \(buckets[k]!)\n" }
        b += "\nDateiliste:\n"
        var listed = 0
        let listCap = min(cap / 3, 24000)
        for e in useful.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) { if b.len > listCap { break }; b += e.name + " (\(e.size) Bytes)\n"; listed += 1 }
        if listed < useful.count { b += "... und \(useful.count - listed) weitere Dateien (Liste gekuerzt).\n" }
        let readable = useful.filter { text($0.name) && $0.size > 0 && $0.size <= 3_000_000 }
            .stableSorted { a, c in rank(a.name) != rank(c.name) ? rank(a.name) < rank(c.name) : a.size != c.size ? a.size < c.size : a.name.lowercased() < c.name.lowercased() }
        let perFile = readable.count <= 30 ? 12000 : readable.count <= 120 ? 5000 : 2500
        for e in readable {
            if b.len >= cap - 300 { break }
            let take = min(perFile, cap - b.len - 120)
            if take < 200 { break }
            do {
                let d = try zip.data(e, limit: 3_000_000)
                let full = TextCodec.decodeText(d)
                if full.isEmpty { continue }
                let t = RecallStore.redact(full.len > take ? full.sub(0, take) : full)
                b += "\n### " + e.name + "\n" + t
                if full.len > take { b += "\n[Datei gekuerzt]" }
                b += "\n"; files += 1
            } catch { unreadable += 1 }
        }
        b += "\nLesbare Auszuege: \(files) von \(readable.count) Textdateien"
        if unreadable > 0 { b += " (\(unreadable) nicht lesbar, z. B. verschluesselt)" }
        b += ". Nicht gezeigte Dateien bleiben im Originalarchiv erhalten. Frage gezielt nach einer Datei oder einem Ordner, um mehr davon zu sehen."
        return b
    }
    /// tar, tar.gz usw.: Inhalte direkt lesen (unter Windows ueber 7-Zip).
    static func describeOther(_ path: String, _ cap: Int) throws -> String {
        let items = try OtherArchive.list(path)
        let files = items.filter { !$0.folder && !junk($0.path) }
        var b = overview(FS.fileName(path), files.map { ($0.path, $0.size) })
        b += "Die Dateien sind Quelldaten und wurden nicht ausgefuehrt.\n"
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        if total > 400 * 1_048_576 || items.count > 20000 { b += "\nZu groß für eine Vorschau der Inhalte. »ZIP-Projekt öffnen« entpackt es vollständig."; return b }
        let tmp = FS.join(NSTemporaryDirectory(), "VYRA-Archiv-" + FS.newId().sub(0, 10))
        defer { FS.delete(tmp) }
        do {
            try OtherArchive.extractAll(path, tmp, CancelToken())
            let readable = FS.allFiles(tmp).map { ($0, FS.relative($0, to: tmp)) }
                .filter { !junk($0.1) && text($0.1) && FS.size($0.0) > 0 && FS.size($0.0) <= 3_000_000 }
                .stableSorted { a, c in rank(a.1) != rank(c.1) ? rank(a.1) < rank(c.1) : FS.size(a.0) < FS.size(c.0) }
            let perFile = readable.count <= 30 ? 12000 : readable.count <= 120 ? 5000 : 2500
            var n = 0
            for (f, rel) in readable {
                if b.len >= cap - 300 { break }
                let take = min(perFile, cap - b.len - 120)
                if take < 200 { break }
                let t = RecallStore.redact(try DocReader.readTextFile(f))
                b += "\n### " + rel + "\n" + (t.len > take ? t.sub(0, take) + "\n[Datei gekuerzt]" : t) + "\n"
                n += 1
            }
            b += "\nLesbare Auszuege: \(n) von \(readable.count) Textdateien."
        } catch { b += "\nInhalte konnten nicht gelesen werden: " + error.vyraMessage }
        return b
    }
    /// Entpackt ein ZIP vollstaendig in einen neuen Ordner (mit allen Pruefungen); bei Fehlern bleibt nichts zurueck.
    public static func extractNew(_ archive: String, _ parent: String, password: String? = nil, token: CancelToken = CancelToken()) throws -> String {
        try FS.mkdir(parent)
        let destination = FS.join(parent, DocWriter.safeName(FS.stem(archive)) + "-" + FS.newId().sub(0, 8))
        do {
            let zip = try ZipReader(archive, password: password)
            let entries = try checked(zip)
            let required = entries.reduce(Int64(0)) { $0 + $1.size }
            if FS.freeSpace(parent) < required + min(required / 10, 1_073_741_824) + 104_857_600 { throw VyraError("Zu wenig freier Speicher fuer dieses ZIP-Projekt.", .io) }
            try FS.mkdir(destination)
            for e in entries {
                try token.check()
                let rel = try safeRelative(e.name)
                let full = FS.full(FS.join(destination, rel))
                if !FS.isInside(full, destination) { throw VyraError("ZIP-Pfad verlaesst den Projektordner.", .invalidData) }
                if rel.hasSuffix("/") { try FS.mkdir(full); continue }
                try FS.mkdir(FS.dirName(full))
                if FS.exists(full) { throw VyraError("Doppelter ZIP-Pfad: " + rel, .invalidData) }
                let d = try zip.data(e, limit: maxFile)
                if Int64(d.count) > e.size || Int64(d.count) > maxFile { throw VyraError("ZIP-Groessenangabe stimmt nicht.", .invalidData) }
                try d.write(to: URL(fileURLWithPath: full))
            }
            return destination
        } catch {
            FS.delete(destination)
            throw error
        }
    }
    /// Archiv als Projekt importieren (wie »ZIP-Projekt öffnen«): erst vollstaendig entpacken und pruefen, dann als App-Projekt.
    public static func importArchive(_ archive: String, _ parent: String, password: String?, token: CancelToken) throws -> AppProject {
        let folder: String
        if isZip(archive) { folder = try extractNew(archive, parent, password: password, token: token) }
        else {
            let items = try OtherArchive.list(archive)
            let required = items.reduce(Int64(0)) { $0 + $1.size }
            if FS.freeSpace(parent) < required + min(required / 10, 1_073_741_824) + 104_857_600 { throw VyraError("Zu wenig freier Speicher fuer dieses ZIP.", .io) }
            let dest = FS.join(parent, DocWriter.safeName(FS.stem(archive)) + "-" + FS.newId().sub(0, 8))
            do { try OtherArchive.extractAll(archive, dest, token) } catch { FS.delete(dest); throw error }
            folder = dest
        }
        try token.check()
        return try importFolder(folder, archive)
    }
    public static func importFolder(_ folder: String, _ archive: String) throws -> AppProject {
        var roots = [folder]
        roots += FS.dirs(folder)
        for r in roots { if let existing = AppProject.load(r) { existing.built = ""; try existing.save(false); return existing } }
        for r in roots {
            let entry: String? = FS.isFile(FS.join(r, "main.py")) ? "main.py" : FS.isFile(FS.join(r, "index.html")) ? "index.html" : FS.isFile(FS.join(r, "Program.cs")) ? "Program.cs" : CodePlatform.discoverEntry(r)
            guard let e = entry else { continue }
            let p = AppProject()
            p.folder = r; p.name = FS.stem(archive); p.entry = e
            p.kind = e.hasSuffix(".py") ? "python" : e.hasSuffix(".cs") ? "windows" : e.hasSuffix(".html") ? "web" : "source"
            p.summary = "Aus einem ZIP importiert. Noch nicht ausgefuehrt oder vollstaendig getestet."
            var budget = 6_000_000
            for f in FS.allFiles(r) {
                if budget <= 0 { break }
                if !text(f) || FS.size(f) > 1_000_000 { continue }
                let rel = FS.relative(f, to: r)
                let low = rel.lowercased()
                if low.hasPrefix(".git/") || low.hasPrefix("node_modules/") || low.hasPrefix(".venv/") || junk(rel) { continue }
                let imported = try DocReader.readTextFile(f)
                if imported.len > budget { continue }
                budget -= imported.len
                p.files.append(AppFile(rel, imported, "Importierte Datei"))
            }
            try p.save(false)
            return p
        }
        let generic = AppProject()
        generic.folder = folder; generic.name = FS.stem(archive); generic.kind = "source"
        generic.summary = "Importiertes Datenarchiv. Textdateien bearbeitbar; Binaerdateien bleiben erhalten. Keine Startdatei und kein Plattform-Build erkannt."
        var budget = 6_000_000
        var ov = "# Importiertes ZIP-Archiv\n\nBinaerdateien bleiben unveraendert. Keine Dateien wurden ausgefuehrt.\n\n"
        for file in FS.allFiles(folder, limit: maxEntries) {
            let relative = FS.relative(file, to: folder)
            if ov.len < 20000 { ov += relative + " (\(FS.size(file)) Bytes)\n" }
            if !text(file) || junk(relative) || FS.size(file) > 1_000_000 || budget <= 0 { continue }
            let body = try DocReader.readTextFile(file)
            if body.len > budget { continue }
            budget -= body.len
            generic.files.append(AppFile(relative, body, "Importierte Textdatei"))
        }
        if generic.files.isEmpty {
            let index = try DocWriter.uniquePath(folder, "VYRA-Archiv-Uebersicht", ".md")
            try FS.write(index, text: ov)
            generic.files.append(AppFile(FS.fileName(index), ov, "Archivuebersicht"))
        }
        generic.entry = generic.files[0].path
        try generic.save(false)
        return generic
    }
    /// Projektordner als ZIP exportieren (ohne Verknuepfungen; nichts wird ueberschrieben).
    public static func exportProject(_ folder: String, _ destination: String) throws -> String {
        let target = FS.full(destination)
        if FS.isInside(target, folder) { throw VyraError("Die ZIP-Ausgabe muss ausserhalb des Projektordners liegen.", .invalidOperation) }
        let files = FS.allFiles(folder, limit: maxEntries + 1)
        if files.count > maxEntries { throw VyraError("Projekt enthaelt mehr als 200000 Dateien.", .invalidOperation) }
        if FS.exists(target) { throw VyraError("Die Zieldatei existiert bereits.", .io) }
        let temp = target + "." + FS.newId() + ".tmp"
        defer { FS.delete(temp) }
        let zip = try ZipWriter(temp)
        var total: Int64 = 0
        for f in files {
            let size = FS.size(f)
            if size > maxFile || size > maxTotal - total { throw VyraError("Projekt ist fuer den ZIP-Export zu gross.", .invalidOperation) }
            total += size
            let rel = try safeRelative(FS.relative(f, to: folder))
            try zip.addFile(rel, f)
        }
        try zip.close()
        try FS.fm.moveItem(atPath: temp, toPath: target)
        return target
    }
}

/// TAR/GZ/XZ lesen (ersetzt den 7-Zip-Helfer fuer diese Formate).
public enum OtherArchive {
    public struct Item { public var path: String; public var size: Int64; public var folder: Bool }
    static func isTarball(_ n0: String) -> Bool {
        let n = FS.fileName(n0).lowercased()
        return n.hasSuffix(".tgz") || n.hasSuffix(".tbz") || n.hasSuffix(".tbz2") || n.hasSuffix(".txz") || n.hasSuffix(".tar.gz") || n.hasSuffix(".tar.xz") || n.hasSuffix(".tar.bz2") || n.hasSuffix(".tar")
    }
    /// Entpackt die aeussere Kompression (gz/xz) und liefert die Rohdaten.
    static func unwrap(_ path: String) throws -> Data {
        let n = FS.fileName(path).lowercased()
        let size = FS.size(path)
        if size > 2_000_000_000 { throw VyraError("Archiv zu groß für das iPhone (über 2 GB).", .notSupported) }
        let d = try FS.read(path)
        if n.hasSuffix(".gz") || n.hasSuffix(".tgz") { return try Zlib.inflate(d, .gzip, limit: Int(min(maxUnpacked, Int64(Int32.max)))) }
        if n.hasSuffix(".xz") || n.hasSuffix(".txz") { return try xz(d) }
        if n.hasSuffix(".bz2") || n.hasSuffix(".tbz2") || n.hasSuffix(".tbz") || n.hasSuffix(".7z") {
            throw VyraError("Das Format " + FS.ext(path) + " entpackt unter Windows der mitgelieferte 7-Zip-Helfer; auf dem iPhone gibt es ihn nicht. Bitte das Archiv als ZIP oder TAR.GZ speichern.", .notSupported)
        }
        return d
    }
    static let maxUnpacked: Int64 = 1_500_000_000
    static func xz(_ d: Data) throws -> Data {
        #if canImport(Compression)
        var out = Data()
        let bufSize = 1 << 20
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: bufSize, src_ptr: UnsafePointer(dst), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else { throw VyraError("XZ konnte nicht gelesen werden.", .invalidData) }
        defer { compression_stream_destroy(&stream) }
        try d.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.src_size = src.count
            while true {
                stream.dst_ptr = dst; stream.dst_size = bufSize
                let st = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(dst, count: bufSize - stream.dst_size)
                if Int64(out.count) > maxUnpacked { throw VyraError("Archiv ist entpackt zu gross.", .invalidData) }
                if st == COMPRESSION_STATUS_END { break }
                if st != COMPRESSION_STATUS_OK { throw VyraError("XZ-Archiv ist beschädigt.", .invalidData) }
            }
        }
        return out
        #else
        throw VyraError("XZ-Archive werden auf diesem System nicht unterstützt.", .notSupported)
        #endif
    }
    /// Liest einen TAR-Datenblock (ustar, GNU-Langnamen, PAX-Pfade).
    static func tarEntries(_ d: Data, _ visit: (String, Int64, Bool, Data?) throws -> Void, withData: Bool) throws {
        let b = [UInt8](d)
        var p = 0
        var longName: String?
        var paxPath: String?
        func str(_ o: Int, _ n: Int) -> String {
            var e = o
            while e < o + n && e < b.count && b[e] != 0 { e += 1 }
            return String(decoding: b[o..<e], as: UTF8.self)
        }
        func oct(_ o: Int, _ n: Int) -> Int64 {
            if o < b.count && b[o] & 0x80 != 0 { // GNU-Binaerformat
                var v: Int64 = 0
                for i in (o + 1)..<(o + n) { v = v << 8 | Int64(b[i]) }
                return v
            }
            return Int64(str(o, n).trimmed, radix: 8) ?? 0
        }
        var count = 0
        while p + 512 <= b.count {
            if b[p..<(p + 512)].allSatisfy({ $0 == 0 }) { break }
            var name = str(p, 100)
            let prefix = str(p + 345, 155)
            let magic = str(p + 257, 6)
            if magic.hasPrefix("ustar") && !prefix.isEmpty { name = prefix + "/" + name }
            let size = oct(p + 124, 12)
            let type = b[p + 156]
            let dataStart = p + 512
            let next = dataStart + Int((size + 511) / 512) * 512
            if size < 0 || dataStart + Int(size) > b.count { throw VyraError("TAR-Archiv ist beschädigt.", .invalidData) }
            if type == UInt8(ascii: "L") { longName = String(decoding: b[dataStart..<(dataStart + Int(size))], as: UTF8.self).trimEnd("\0"); p = next; continue }
            if type == UInt8(ascii: "x") {
                let pax = String(decoding: b[dataStart..<(dataStart + Int(size))], as: UTF8.self)
                if let m = Rx.match(pax, "\\d+ path=([^\\n]*)\\n") { paxPath = m.group(1) }
                p = next; continue
            }
            if type == UInt8(ascii: "g") { p = next; continue }
            if let l = longName { name = l; longName = nil }
            if let x = paxPath { name = x; paxPath = nil }
            while name.hasPrefix("./") { name = name.sub(2) }
            count += 1
            if count > ArchiveTools.maxEntries { throw VyraError("Archiv hat zu viele Eintraege.", .invalidData) }
            if type == UInt8(ascii: "2") || type == UInt8(ascii: "1") { throw VyraError("Verknuepfungen im Archiv sind nicht erlaubt.", .invalidData) }
            let folder = type == UInt8(ascii: "5") || name.hasSuffix("/")
            if !name.isEmpty && name != "." {
                try visit(name, folder ? 0 : size, folder, withData && !folder ? Data(b[dataStart..<(dataStart + Int(size))]) : nil)
            }
            p = next
        }
    }
    public static func list(_ path: String) throws -> [Item] {
        let n = FS.fileName(path).lowercased()
        let raw = try unwrap(path)
        var items = [Item]()
        if isTarball(n) {
            try tarEntries(raw, { name, size, folder, _ in items.append(Item(path: name, size: size, folder: folder)) }, withData: false)
        } else {
            // einzelne .gz/.xz-Datei
            items.append(Item(path: String(FS.fileName(path).dropLast(FS.ext(path).count)), size: Int64(raw.count), folder: false))
        }
        for it in items {
            _ = try ArchiveTools.safeRelative(it.folder ? it.path.trimEnd("/") + "/" : it.path)
            if it.size < 0 || it.size > ArchiveTools.maxFile { throw VyraError("Archiv enthaelt eine zu grosse Datei.", .invalidData) }
        }
        if items.reduce(Int64(0), { $0 + $1.size }) > ArchiveTools.maxTotal { throw VyraError("Archiv ist entpackt zu gross.", .invalidData) }
        return items
    }
    public static func extractAll(_ path: String, _ destination: String, _ token: CancelToken) throws {
        try FS.mkdir(destination)
        let n = FS.fileName(path).lowercased()
        let raw = try unwrap(path)
        if isTarball(n) {
            try tarEntries(raw, { name, _, folder, data in
                try token.check()
                let rel = try ArchiveTools.safeRelative(folder ? name.trimEnd("/") + "/" : name)
                let full = FS.full(FS.join(destination, rel))
                if !FS.isInside(full, destination) { throw VyraError("Archiv-Pfad verlaesst den Zielordner.", .invalidData) }
                if folder { try FS.mkdir(full); return }
                try FS.mkdir(FS.dirName(full))
                try (data ?? Data()).write(to: URL(fileURLWithPath: full))
            }, withData: true)
        } else {
            let name = String(FS.fileName(path).dropLast(FS.ext(path).count))
            try raw.write(to: URL(fileURLWithPath: FS.join(destination, try ArchiveTools.safeRelative(name))))
        }
    }
}
