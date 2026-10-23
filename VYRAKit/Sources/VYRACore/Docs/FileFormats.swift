import Foundation

public enum FileFormats {
    public static let documents = ["docx", "pdf", "odt", "rtf", "html", "md", "txt"]
    public static let rawText = ["json", "xml", "svg", "ics", "vcf", "yaml", "yml", "toml", "ini", "cfg", "conf", "log", "srt", "vtt", "tex", "bib", "sql", "py", "js", "mjs", "ts", "tsx", "jsx", "css", "scss", "java", "kt", "c", "h", "cpp", "hpp", "cs", "vb", "go", "rs", "rb", "php", "lua", "pl", "r", "swift", "dart", "sh", "bash", "ps1", "psm1", "bat", "cmd", "reg", "ahk", "nfo", "htm", "gitignore", "env", "properties", "gradle", "kts", "m", "asm", "vbs", "xaml", "csproj", "sln", "plist", "geojson", "gpx", "kml", "rss", "atom", "opml", "m3u", "pls", "cue", "nsi", "iss"]
    /// Liefert die Art des Formats: chat | doc | slides | data | raw
    public static func kind(_ format: String?) -> String {
        let f = (format ?? "chat").lowercased()
        if f == "chat" || f == "none" || f.isEmpty { return "chat" }
        if f == "pptx" { return "slides" }
        if f == "xlsx" || f == "csv" { return "data" }
        if documents.contains(f) { return "doc" }
        return "raw"
    }
    /// "x:name.ext" oder "x:ext" -> Dateiendung
    public static func rawExt(_ format: String?) -> String {
        var f = format ?? ""
        if f.hasPrefix("x:") { f = f.sub(2) }
        let dot = f.lastIndexOf(".")
        return (dot >= 0 ? f.sub(dot + 1) : f).lowercased()
    }
    public static func rawName(_ format: String?) -> String? {
        var f = format ?? ""
        if f.hasPrefix("x:") { f = f.sub(2) }
        return f.indexOf(".") > 0 ? f : nil
    }
    public static func describe(_ format: String) -> String {
        switch kind(format) == "raw" ? "raw" : format {
        case "docx": return "Word-Dokument"
        case "pdf": return "PDF-Dokument"
        case "odt": return "OpenDocument-Text"
        case "rtf": return "RTF-Dokument"
        case "html": return "HTML-Seite"
        case "md": return "Markdown-Datei"
        case "txt": return "Textdatei"
        case "pptx": return "PowerPoint-Präsentation"
        case "xlsx": return "Excel-Tabelle"
        case "csv": return "CSV-Tabelle"
        default: break
        }
        let e = rawExt(format)
        switch e {
        case "svg": return "SVG-Grafik"
        case "ics": return "Kalenderdatei"
        case "vcf": return "Kontaktdatei (vCard)"
        case "json": return "JSON-Datei"
        case "xml": return "XML-Datei"
        default: return "." + e + "-Datei"
        }
    }
    static func m(_ t: String, _ p: String) -> Bool { Rx.isMatch(t, p) }
    /// Erkennt aus der Anfrage, welche Datei gewuenscht ist (nil = keine Datei).
    public static func detect(_ q: String?) -> String? {
        let t = (q ?? "").lowercased()
        let create = m(t, "\\b(erstell|schreib|mach|verfass|generier|exportier|speicher|gib|bau|entwirf|entwerf|zeichne|gestalte|produzier|leg\\w* an|anleg|konvertier|wandle|umwandel)\\w*")
        if !create { return nil }
        // ausdrueckliche Dateinamen wie "config.yaml" oder "termine.ics"
        if let fm = Rx.match(t, "\\b([a-z0-9_\\-]{1,40})\\.([a-z0-9]{1,6})\\b") {
            let ext = fm.group(2)
            if ["docx", "pdf", "odt", "rtf", "html", "md", "txt", "pptx", "xlsx", "csv"].contains(ext) { return ext }
            if rawText.contains(ext) { return "x:" + fm.group(1) + "." + ext }
        }
        if m(t, "\\b(power ?point|pptx|präsentation|praesentation|foliensatz|folien|slides|vortragsfolien)\\b") { return "pptx" }
        if m(t, "\\b(excel|xlsx|tabellenkalkulation|spreadsheet|excel-?tabelle|excel-?liste|excel-?datei|haushaltsbuch|budget-?tabelle)\\b") { return "xlsx" }
        if m(t, "\\bcsv\\b") { return "csv" }
        if m(t, "\\bpdf\\b") { return "pdf" }
        if m(t, "\\b(word|docx|word-?datei|word-?dokument)\\b") { return "docx" }
        if m(t, "\\b(odt|opendocument|libre ?office|open ?office)\\b") { return "odt" }
        if m(t, "\\brtf\\b") { return "rtf" }
        if m(t, "\\b(markdown)\\b") { return "md" }
        if m(t, "\\b(txt|textdatei|text-datei)\\b") { return "txt" }
        if m(t, "\\b(html-?datei|html-?dokument)\\b") { return "html" }
        if m(t, "\\b(svg|vektorgrafik|vektor-?logo|logo|icon)\\b") { return "x:svg" }
        if m(t, "\\b(ics|kalenderdatei|kalender-?datei|kalender-?einträge?|kalendereintrag)\\b") { return "x:ics" }
        if m(t, "\\b(vcf|vcard|kontaktdatei|kontakt-?datei)\\b") { return "x:vcf" }
        for e in ["json", "xml", "yaml", "yml", "toml", "ini", "sql", "srt", "gpx", "kml", "m3u", "reg", "bat", "ps1", "geojson"] where m(t, "\\b" + e + "\\b") { return "x:" + e }
        if m(t, "\\b(referat|hausarbeit|facharbeit|bericht|handout|dokumentation|bewerbung|lebenslauf|anschreiben|vertrag|brief)\\b") && m(t, "\\b(datei|dokument|ausdrucken|drucken)\\b") { return "docx" }
        return nil
    }
    public static func ext(_ format: String) -> String { kind(format) == "raw" ? "." + rawExt(format) : "." + format }
}

// ---------------------------------------------------------------- Markdown in einfache Bloecke zerlegen (fuer alle Dokumentformate)
public final class MdBlock {
    public var kind = "p"
    public var level = 0
    public var text = ""
    public var items = [String]()
    public var rows = [[String]]()
    init(_ kind: String) { self.kind = kind }
}
public enum MdBlocks {
    static let rxBullet = "^([-*+•])\\s+"
    static let rxNum = "^\\d{1,3}[.)]\\s+"
    public static func parse(_ md: String) -> [MdBlock] {
        var list = [MdBlock]()
        let lines = md.rep("\r", "").splitKeep("\n")
        var i = 0
        while i < lines.count {
            let tl = lines[i].trimmed
            defer { i += 1 }
            if tl.isEmpty { continue }
            if tl.hasPrefix("```") {
                let b = MdBlock("code"); var sb = ""; i += 1
                while i < lines.count && !lines[i].trimmed.hasPrefix("```") { sb += lines[i] + "\n"; i += 1 }
                b.text = sb.trimEnd("\n"); list.append(b); continue
            }
            if let hm = Rx.match(tl, "^(#{1,6})\\s+(.*)$") {
                let b = MdBlock("h"); b.level = hm.group(1).len; b.text = hm.group(2).trimmed.trimEnd("#").trimmed; list.append(b); continue
            }
            if Rx.isMatch(tl, "^(-{3,}|\\*{3,}|_{3,})$") { list.append(MdBlock("hr")); continue }
            if tl.hasPrefix("|") {
                let b = MdBlock("table")
                while i < lines.count && lines[i].trimmed.hasPrefix("|") {
                    let row = lines[i].trimmed
                    if !Rx.isMatch(row, "^\\|[\\s:\\-|]+\\|?$") { b.rows.append(splitRow(row)) }
                    i += 1
                }
                i -= 1
                if !b.rows.isEmpty { list.append(b) }
                continue
            }
            if Rx.isMatch(tl, rxBullet) {
                let b = MdBlock("ul")
                while i < lines.count && Rx.isMatch(lines[i].trimmed, rxBullet) { b.items.append(Rx.replace(lines[i].trimmed, rxBullet, "")); i += 1 }
                i -= 1; list.append(b); continue
            }
            if Rx.isMatch(tl, rxNum) {
                let b = MdBlock("ol")
                while i < lines.count && Rx.isMatch(lines[i].trimmed, rxNum) { b.items.append(Rx.replace(lines[i].trimmed, rxNum, "")); i += 1 }
                i -= 1; list.append(b); continue
            }
            if tl.hasPrefix(">") {
                var sb = ""
                while i < lines.count && lines[i].trimmed.hasPrefix(">") { sb += lines[i].trimmed.trimStart(">").trimmed + " "; i += 1 }
                i -= 1
                let b = MdBlock("quote"); b.text = sb.trimmed; list.append(b); continue
            }
            var p = tl
            while i + 1 < lines.count {
                let n = lines[i + 1].trimmed
                if n.isEmpty || n.hasPrefix("#") || n.hasPrefix("|") || n.hasPrefix("```") || n.hasPrefix(">") || Rx.isMatch(n, "^([-*+•]|\\d{1,3}[.)])\\s+") { break }
                p += " " + n; i += 1
            }
            let b = MdBlock("p"); b.text = p; list.append(b)
        }
        return list
    }
    public static func splitRow(_ row: String) -> [String] {
        var r = row.trimmed
        if r.hasPrefix("|") { r = r.sub(1) }
        if r.hasSuffix("|") { r = r.sub(0, r.len - 1) }
        return r.splitKeep("|").map { plain($0.trimmed) }
    }
    /// Inline-Markdown entfernen (fett, kursiv, Code, Links)
    public static func plain(_ s0: String) -> String {
        var s = Rx.replace(s0, "\\[([^\\]]+)\\]\\((https?://[^)]+)\\)", "$1")
        s = s.rep("**", "").rep("__", "")
        s = Rx.replace(s, "(?<![\\w*])\\*(?!\\s)([^*]+?)\\*(?!\\w)", "$1")
        return s.rep("`", "")
    }
    /// Text in Abschnitte normal/fett zerlegen
    public static func runs(_ s0: String) -> [(String, Bool)] {
        var r = [(String, Bool)]()
        if s0.isEmpty { return r }
        let s = Rx.replace(s0, "\\[([^\\]]+)\\]\\((https?://[^)]+)\\)", "$1 ($2)").rep("`", "")
        for p in Rx.split(s, "(\\*\\*[^*]+\\*\\*)") {
            if p.isEmpty { continue }
            if p.hasPrefix("**") && p.hasSuffix("**") && p.len > 4 { r.append((p.sub(2, p.len - 4), true)) } else { r.append((plain(p), false)) }
        }
        return r
    }
}
