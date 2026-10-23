import Foundation

// ---------------------------------------------------------------- Dokumente schreiben (Word .docx, Markdown, Text …) – unveraendert portiert
public enum DocWriter {
    /// Unter Windows: Dokumente\VYRA KI. Auf dem iPhone: Dateien-App › Auf meinem iPhone › VYRA KI.
    public static var defaultFolder = VyraPaths.standard().results
    public static func safeName(_ title: String?) -> String {
        var t = (title ?? "").trimmed
        if t.isEmpty { t = "VYRA KI Ergebnis" }
        for c in "<>:\"/\\|?*" { t = t.rep(String(c), " ") }
        t = String(t.unicodeScalars.filter { $0.value >= 0x20 }.map(Character.init))
        t = Rx.replace(t, "\\s+", " ").trimmed.trimEnd(".")
        if t.len > 70 { t = t.sub(0, 70).trimmed }
        return t.isEmpty ? "VYRA KI Ergebnis" : t
    }
    public static func uniquePath(_ folder: String, _ name: String, _ ext: String) throws -> String {
        try FS.mkdir(folder)
        var path = FS.join(folder, safeName(name) + ext)
        var n = 2
        while FS.exists(path) { path = FS.join(folder, safeName(name) + " (\(n))" + ext); n += 1 }
        return path
    }
    public static func save(_ folder: String, _ title0: String, _ body: String, _ format: String) throws -> String {
        try FS.mkdir(folder)
        var title = title0
        let ext = FileFormats.kind(format) == "chat" ? ".md" : FileFormats.ext(format)
        if let rawName = FileFormats.rawName(format) { let bn = FS.stem(rawName); if !bn.isEmpty { title = bn } }
        let name = safeName(title)
        var path = FS.join(folder, name + ext)
        var n = 2
        while FS.exists(path) { path = FS.join(folder, name + " (\(n))" + ext); n += 1 }
        if format == "docx" { try writeDocx(path, title, body) }
        else if format == "rtf" { try FS.write(path, Data(RtfWriter.build(title, body).utf8)) }
        else if format == "odt" { try OdtWriter.write(path, title, body) }
        else if format == "pptx" { try PptxWriter.write(path, title, PptxWriter.fromMarkdown(body), "Erstellt mit VYRA KI · " + DE.date()) }
        else if format == "xlsx" { try XlsxWriter.write(path, XlsxWriter.fromMarkdown(body, title)) }
        else if format == "csv" { try FS.write(path, TextCodec.utf8(XlsxWriter.csv(XlsxWriter.fromMarkdown(body, title)[0]), bom: true)) }
        else if FileFormats.kind(format) == "raw" {
            let e = FileFormats.rawExt(format)
            var code = AppBuilder.extractCode(body)
            if code.trimmed.isEmpty { code = body }
            try FS.write(path, RawFileCheck.encode(e, RawFileCheck.normalize(e, code)))
        }
        else if format == "pdf" { try PdfWriter.write(path, title, body) }
        else if format == "html" { try FS.write(path, text: html(title, body)) }
        else if format == "txt" { try FS.write(path, text: (title + "\n\n" + body.rep("**", "")).rep("\n", "\r\n"), bom: true) }
        else { try FS.write(path, text: "# " + title + "\n\n" + body + "\n") }
        return path
    }
    static func x(_ s: String) -> String { HTMLEntities.xml(s) }
    static func runs(_ text0: String) -> String {
        var text = Rx.replace(text0, "`([^`]+)`", "$1")
        text = Rx.replace(text, "\\[([^\\]]+)\\]\\((https?://[^)]+)\\)", "$1 ($2)")
        text = Rx.replace(text, "(?<![*\\w])\\*([^*\\n]+)\\*(?!\\*)", "$1")
        var b = ""
        for p in Rx.split(text, "(\\*\\*[^*]+\\*\\*)") {
            if p.isEmpty { continue }
            let bold = p.hasPrefix("**") && p.hasSuffix("**") && p.len > 4
            let t = bold ? p.sub(2, p.len - 4) : p
            b += "<w:r>" + (bold ? "<w:rPr><w:b/></w:rPr>" : "") + "<w:t xml:space=\"preserve\">" + x(t) + "</w:t></w:r>"
        }
        return b
    }
    static func para(_ style: String?, _ text: String) -> String { "<w:p>" + (style != nil ? "<w:pPr><w:pStyle w:val=\"" + style! + "\"/></w:pPr>" : "") + runs(text) + "</w:p>" }
    public static func documentXml(_ title: String, _ body: String) -> String {
        var b = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>"
        b += para("Title", title)
        var code = false
        for raw in body.rep("\r", "").splitKeep("\n") {
            let l = raw.trimEnd()
            if l.trimStart().hasPrefix("```") { code = !code; continue }
            if code { b += "<w:p><w:pPr><w:pStyle w:val=\"Code\"/></w:pPr><w:r><w:t xml:space=\"preserve\">" + x(l) + "</w:t></w:r></w:p>"; continue }
            let tl = l.trimmed
            if tl.isEmpty { continue }
            if Rx.isMatch(tl, "^(-{3,}|\\*{3,}|_{3,})$") { continue }
            if Rx.isMatch(tl, "^\\|?\\s*:?-+:?\\s*(\\|\\s*:?-+:?\\s*)*\\|?$") { continue } // Tabellen-Trennzeile
            if tl.hasPrefix("|") { let cells = tl.trim("|").splitKeep("|").map { $0.trimmed }; b += para(nil, cells.joined(separator: "   ·   ")); continue }
            if l.trimStart().hasPrefix("> ") { b += para("Quote", l.trimStart().sub(2)); continue }
            if l.hasPrefix("### ") { b += para("Heading3", l.sub(4)) }
            else if l.hasPrefix("## ") { b += para("Heading2", l.sub(3)) }
            else if l.hasPrefix("# ") { b += para("Heading1", l.sub(2)) }
            else if l.trimStart().hasPrefix("- ") || l.trimStart().hasPrefix("* ") { b += para("ListBullet", "• " + l.trimStart().sub(2)) }
            else if Rx.isMatch(l.trimStart(), "^\\d{1,3}[.)] ") { b += para("ListBullet", l.trimStart()) }
            else { b += para(nil, l) }
        }
        b += "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1417\" w:right=\"1417\" w:bottom=\"1134\" w:left=\"1417\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>"
        return b
    }
    static let styles = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">" +
        "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:cs=\"Calibri\" w:eastAsia=\"Calibri\"/><w:sz w:val=\"22\"/><w:lang w:val=\"de-DE\"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\"160\" w:line=\"276\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>" +
        "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/></w:style>" +
        "<w:style w:type=\"paragraph\" w:styleId=\"Title\"><w:name w:val=\"Title\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"300\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"48\"/><w:color w:val=\"2F2A6B\"/></w:rPr></w:style>" +
        "<w:style w:type=\"paragraph\" w:styleId=\"Heading1\"><w:name w:val=\"heading 1\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:pPr><w:keepNext/><w:spacing w:before=\"360\" w:after=\"120\"/><w:outlineLvl w:val=\"0\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"32\"/><w:color w:val=\"2F2A6B\"/></w:rPr></w:style>" +
        "<w:style w:type=\"paragraph\" w:styleId=\"Heading2\"><w:name w:val=\"heading 2\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:pPr><w:keepNext/><w:spacing w:before=\"280\" w:after=\"100\"/><w:outlineLvl w:val=\"1\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"28\"/><w:color w:val=\"3B3486\"/></w:rPr></w:style>" +
        "<w:style w:type=\"paragraph\" w:styleId=\"Heading3\"><w:name w:val=\"heading 3\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:pPr><w:keepNext/><w:spacing w:before=\"200\" w:after=\"80\"/><w:outlineLvl w:val=\"2\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"24\"/></w:rPr></w:style>" +
        "<w:style w:type=\"paragraph\" w:styleId=\"Code\"><w:name w:val=\"Code\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F5\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\" w:cs=\"Consolas\"/><w:sz w:val=\"19\"/></w:rPr></w:style>" +
        "<w:style w:type=\"paragraph\" w:styleId=\"Quote\"><w:name w:val=\"Quote\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:ind w:left=\"567\"/></w:pPr><w:rPr><w:i/><w:color w:val=\"555566\"/></w:rPr></w:style>" +
        "<w:style w:type=\"paragraph\" w:styleId=\"ListBullet\"><w:name w:val=\"List Bullet\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"60\"/><w:ind w:left=\"360\" w:hanging=\"240\"/></w:pPr></w:style></w:styles>"
    public static func writeDocx(_ path: String, _ title: String, _ body: String) throws {
        let zip = try ZipWriter(path)
        try zip.add("[Content_Types].xml", text: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/><Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/></Types>")
        try zip.add("_rels/.rels", text: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/></Relationships>")
        try zip.add("word/_rels/document.xml.rels", text: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>")
        try zip.add("word/styles.xml", text: styles)
        try zip.add("word/document.xml", text: documentXml(title, body))
        try zip.add("docProps/core.xml", text: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><dc:title>" + x(title) + "</dc:title><dc:creator>VYRA KI</dc:creator><dcterms:created xsi:type=\"dcterms:W3CDTF\">" + utcStamp() + "</dcterms:created></cp:coreProperties>")
        try zip.close()
    }
    static func utcStamp() -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: Date())
    }
    static func html(_ title: String, _ body: String) -> String {
        var b = "<!doctype html><html lang=\"de\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>" + x(title) + "</title><style>body{font:16px/1.65 'Segoe UI',system-ui,sans-serif;max-width:46em;margin:3em auto;padding:0 1.2em;color:#1d1f24}h1{font-size:2em;margin:0 0 .6em}h2{margin:1.6em 0 .4em}table{border-collapse:collapse;margin:1em 0}td,th{border:1px solid #d5d8e0;padding:.4em .7em;text-align:left}th{background:#f2f3f7}pre{background:#f4f5f8;padding:1em;border-radius:8px;overflow:auto}blockquote{border-left:3px solid #7c83ff;margin:1em 0;padding:.2em 1em;color:#555}@media(prefers-color-scheme:dark){body{background:#15161a;color:#e8e9ee}th{background:#22242b}td,th{border-color:#363944}pre{background:#202228}}</style></head><body><h1>" + x(title) + "</h1>"
        func inl(_ s: String) -> String { MdBlocks.runs(s).map { $0.1 ? "<strong>" + x($0.0) + "</strong>" : x($0.0) }.joined() }
        for k in MdBlocks.parse(body) {
            switch k.kind {
            case "h": let lv = min(6, max(2, k.level)); b += "<h\(lv)>" + x(MdBlocks.plain(k.text)) + "</h\(lv)>"
            case "ul": b += "<ul>" + k.items.map { "<li>" + inl($0) + "</li>" }.joined() + "</ul>"
            case "ol": b += "<ol>" + k.items.map { "<li>" + inl($0) + "</li>" }.joined() + "</ol>"
            case "code": b += "<pre><code>" + x(k.text) + "</code></pre>"
            case "quote": b += "<blockquote>" + inl(k.text) + "</blockquote>"
            case "hr": b += "<hr>"
            case "table":
                b += "<table>"
                for (i, r) in k.rows.enumerated() { b += "<tr>" + r.map { i == 0 ? "<th>" + x($0) + "</th>" : "<td>" + x($0) + "</td>" }.joined() + "</tr>" }
                b += "</table>"
            default: b += "<p>" + inl(k.text) + "</p>"
            }
        }
        return b + "</body></html>"
    }
    /// Text aus .docx lesen (fuer "Dateien lesen").
    public static func readDocxText(_ path: String) throws -> String {
        let zip = try ZipReader(path)
        guard let xml0 = try zip.text("word/document.xml") else { return "" }
        var xml = Rx.replace(xml0, "</w:p>", "\n")
        xml = Rx.replace(xml, "<w:tab/>", "\t")
        xml = Rx.replace(xml, "<w:br/>", "\n")
        xml = Rx.replace(xml, "<[^>]+>", "")
        return HTMLEntities.decode(xml).trimmed
    }
}
