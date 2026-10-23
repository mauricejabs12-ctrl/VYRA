import Foundation

/// Dateien lesen (auch fuer Anhaenge im Chat) – unveraendert portiert aus `DocReader`.
public enum DocReader {
    public static let readable = [".txt", ".md", ".csv", ".tsv", ".json", ".log", ".xml", ".html", ".htm", ".docx", ".ini", ".cfg", ".rtf", ".pdf", ".cs", ".ps1", ".py", ".js", ".ts", ".java", ".cpp", ".c", ".h", ".css", ".yaml", ".yml", ".bat", ".cmd", ".sql", ".lua", ".zip", ".swift", ".kt", ".kts", ".dart", ".tsx", ".jsx", ".go", ".rs", ".php", ".rb", ".sh", ".toml", ".csproj", ".xaml", ".vue", ".svelte", ".gradle", ".properties", ".hpp", ".sln",
                                  // 4.14: weitere Archive, Office-Dateien, Notebooks und Code-Typen
                                  ".7z", ".tar", ".tgz", ".gz", ".xz", ".txz", ".bz2", ".tbz2", ".xlsx", ".pptx", ".odt", ".ods", ".ipynb", ".scss", ".less", ".mjs", ".cjs", ".vb", ".r", ".scala", ".pl", ".ex", ".exs", ".hs", ".asm", ".ino", ".gd", ".hlsl", ".glsl", ".ahk", ".cmake", ".mk", ".tf", ".graphql", ".proto", ".srt", ".vtt", ".tex", ".bib", ".reg", ".nfo", ".mod", ".sum", ".lock", ".editorconfig", ".gitignore"]
    static func archiveExt(_ ext: String) -> Bool { ext == ".zip" || ArchiveTools.otherArchives.contains(ext) }
    public static func canRead(_ path: String) -> Bool { readable.contains(extOf(path)) }
    /// Endung wie .NET (".gitignore" ist eine Endung).
    static func extOf(_ path: String) -> String {
        let n = FS.fileName(path).lowercased()
        guard let dot = n.lastIndex(of: ".") else { return "" }
        return String(n[dot...])
    }
    public static func read(_ path: String, _ maxChars: Int) throws -> String {
        if !FS.isFile(path) { throw VyraError("Datei nicht gefunden: " + FS.fileName(path), .io) }
        let ext = extOf(path)
        if !readable.contains(ext) { throw VyraError("Dateityp " + ext + " kann VYRA KI nicht lesen.", .notSupported) }
        let size = FS.size(path)
        if size > (archiveExt(ext) ? ArchiveTools.maxArchive : 40_000_000) { throw VyraError(archiveExt(ext) ? "Archiv zu groß (über 16 GiB)." : "Datei zu groß (über 40 MB).", .notSupported) }
        var text: String
        if archiveExt(ext) { text = try ArchiveTools.describe(path, maxChars) }
        else if [".xlsx", ".pptx", ".odt", ".ods"].contains(ext) { text = try officeText(path, ext) }
        else if ext == ".ipynb" { text = try notebookText(path) }
        else if ext == ".docx" { text = try DocWriter.readDocxText(path) }
        else if ext == ".pdf" { text = Pdf.extractText(try FS.read(path)) }
        else {
            text = try readTextFile(path)
            if ext == ".html" || ext == ".htm" { text = WebResearch.htmlToText(text, 0) }
            else if ext == ".rtf" { text = Rx.replace(Rx.replace(text, "\\\\[a-z]+-?\\d* ?|[{}]", ""), "\\s+\\n", "\n") }
        }
        if ext == ".pdf" && text.trimmed.len < 20 { throw VyraError("Aus dieser PDF lässt sich kein Text lesen (vermutlich eingescannt oder mit Sonderschriften).", .notSupported) }
        return maxChars > 0 ? WebResearch.squeeze(text, maxChars) : text
    }
    /// Text aus Excel, PowerPoint und OpenDocument (ohne Office): Zellen bzw. Folientexte in Lesereihenfolge.
    public static func officeText(_ path: String, _ ext: String) throws -> String {
        var b = ""
        let zip = try ZipReader(path)
        func load(_ e: ZipEntry?) -> XmlNode? {
            guard let e = e, e.size <= 30_000_000, let d = try? zip.data(e) else { return nil }
            return try? XmlDom.parse(d)
        }
        if ext == ".xlsx" {
            var shared = [String]()
            if let sst = load(zip.entry("xl/sharedStrings.xml")) { for si in sst.elements("si") { shared.append(si.innerText) } }
            var sheetNo = 0
            let sheets = zip.entries.filter { $0.name.lowercased().hasPrefix("xl/worksheets/sheet") && $0.name.lowercased().hasSuffix(".xml") }
                .sorted { $0.name.len != $1.name.len ? $0.name.len < $1.name.len : $0.name < $1.name }
            for e in sheets {
                guard let d = load(e) else { continue }
                sheetNo += 1
                b += "## Tabelle \(sheetNo)\n"
                var rows = 0
                for row in d.elements("row") {
                    rows += 1
                    if rows > 2000 { b += "[weitere Zeilen gekuerzt]\n"; break }
                    var cells = [String]()
                    for c in row.children where c.localName == "c" {
                        let t = c.attr("t") ?? ""
                        var v = ""
                        for k in c.children { if k.localName == "v" { v = k.innerText } else if k.localName == "is" { v = k.innerText } }
                        if t == "s", let idx = Int(v), idx >= 0 && idx < shared.count { v = shared[idx] }
                        cells.append(v.rep("|", "/"))
                    }
                    b += "| " + cells.joined(separator: " | ") + " |\n"
                }
            }
        } else if ext == ".pptx" {
            let slides = zip.entries.filter { Rx.isMatch($0.name, "^ppt/slides/slide\\d+\\.xml$", .i) }
                .sorted { (Int(Rx.match($0.name, "\\d+")?.value ?? "0") ?? 0) < (Int(Rx.match($1.name, "\\d+")?.value ?? "0") ?? 0) }
            for e in slides {
                guard let d = load(e) else { continue }
                b += "## Folie " + (Rx.match(e.name, "\\d+")?.value ?? "") + "\n"
                for para in d.elements("a:p") { let t = para.innerText.trimmed; if !t.isEmpty { b += "- " + t + "\n" } }
            }
        } else {
            if let d = load(zip.entry("content.xml")) {
                for n in d.elements("*") where n.localName == "p" || n.localName == "h" {
                    let t = n.innerText.trimmed
                    if !t.isEmpty { b += (n.localName == "h" ? "## " : "") + t + "\n" }
                }
            }
        }
        return b
    }
    /// Jupyter-Notebook: Text- und Codezellen in Reihenfolge.
    public static func notebookText(_ path: String) throws -> String {
        let o = try Json.parse(try readTextFile(path))
        var b = ""
        var n = 0
        for cell in Json.arr(o, "cells") {
            let type = Json.str(cell, "cell_type")
            let src = Json.get(cell, "source")
            let text = src is String ? (src as! String) : Json.arr(cell, "source").map { Json.text($0) }.joined()
            if type == "code" { n += 1; b += "### Zelle \(n) (Code)\n```python\n" + text.trimEnd() + "\n```\n\n" } else { b += text.trimmed + "\n\n" }
        }
        return b
    }
    /// UTF-8 mit Rueckfall auf Windows-1252 (alte deutsche Textdateien).
    public static func readTextFile(_ path: String) throws -> String {
        let d = try FS.read(path)
        return TextCodec.decodeText(d).trimStart("\u{FEFF}")
    }
    public static func load(_ path: String, _ maxChars: Int) -> Attachment {
        let a = Attachment(); a.path = path; a.name = FS.fileName(path)
        do { a.bytes = FS.size(path); a.text = try read(path, maxChars) } catch { a.problem = error.vyraMessage }
        return a
    }
}
