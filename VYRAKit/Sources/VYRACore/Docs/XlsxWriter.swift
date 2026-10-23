import Foundation

// ---------------------------------------------------------------- Excel (.xlsx) ohne Office (unveraendert portiert)
public final class SheetData {
    public var name = "Tabelle1"
    public var rows = [[String]]()
    public init(name: String = "Tabelle1", rows: [[String]] = []) { self.name = name; self.rows = rows }
}
public enum XlsxWriter {
    static func x(_ s: String) -> String { HTMLEntities.xml(s) }
    public static func col(_ i0: Int) -> String {
        var s = ""
        var i = i0 + 1
        while i > 0 { let m = (i - 1) % 26; s = String(UnicodeScalar(UInt8(65 + m))) + s; i = (i - 1) / 26 }
        return s
    }
    /// Zahl erkennen: 1234 | 1.234,56 | 12,5 | 12.5 | 15 % | 9,99 EUR / 9,99 €
    public static func tryNumber(_ raw: String) -> (Double, Int)? {
        var s = raw.trimmed
        var style = 0
        if s.isEmpty || s.len > 30 { return nil }
        if s.hasSuffix("%") { style = 2; s = s.trimEnd("%").trimmed }
        else if s.hasSuffix("€") || s.hasSuffix("EUR") || s.hasPrefix("€") { style = 3; s = s.rep("€", "").rep("EUR", "").trimmed }
        if !Rx.isMatch(s, "^[-+]?(\\d{1,3}(\\.\\d{3})+|\\d+)(,\\d+)?$|^[-+]?\\d+(\\.\\d+)?$") { return nil }
        var n = s
        if n.contains(",") { n = n.rep(".", "").rep(",", ".") }
        else if Rx.isMatch(n, "^[-+]?\\d{1,3}(\\.\\d{3})+$") { n = n.rep(".", "") }
        guard var v = Double(n) else { return nil }
        if style == 2 { v /= 100.0 }
        return (v, style)
    }
    static let fn: [String: String] = [
        "SUMME": "SUM", "MITTELWERT": "AVERAGE", "ANZAHL2": "COUNTA", "ANZAHL": "COUNT", "WENN": "IF", "RUNDEN": "ROUND", "SVERWEIS": "VLOOKUP", "WVERWEIS": "HLOOKUP",
        "HEUTE": "TODAY", "JETZT": "NOW", "ZÄHLENWENN": "COUNTIF", "SUMMEWENN": "SUMIF", "UND": "AND", "ODER": "OR", "VERKETTEN": "CONCATENATE", "ABRUNDEN": "ROUNDDOWN", "AUFRUNDEN": "ROUNDUP",
        "WURZEL": "SQRT", "ABS": "ABS", "MAX": "MAX", "MIN": "MIN", "JAHR": "YEAR", "MONAT": "MONTH", "TAG": "DAY", "DATUM": "DATE", "LÄNGE": "LEN", "LINKS": "LEFT", "RECHTS": "RIGHT", "TEIL": "MID", "INDEX": "INDEX", "VERGLEICH": "MATCH", "ISTLEER": "ISBLANK", "WENNFEHLER": "IFERROR", "POTENZ": "POWER", "REST": "MOD", "PRODUKT": "PRODUCT"
    ]
    /// Deutsche Excel-Formeln in die Dateischreibweise (englisch, Komma) umwandeln.
    public static func formula(_ f: String) -> String {
        var s = f.trimmed.trimStart("=")
        s = Rx.replace(s, "([A-Za-zÄÖÜäöü]+[0-9]?)\\s*\\(") { m in
            let k = m.group(1)
            return (fn[k.uppercased()] ?? k.uppercased()) + "("
        }
        // Dezimalkomma in Zahlen ausserhalb von Texten ersetzen, danach Trennzeichen ; -> ,
        var sb = ""
        var q = false
        let c = Array(s)
        for i in 0..<c.count {
            let ch = c[i]
            if ch == "\"" { q = !q }
            if !q && ch == "," && i > 0 && i + 1 < c.count && c[i - 1].isNumber && c[i + 1].isNumber { sb.append(".") }
            else if !q && ch == ";" { sb.append(",") } else { sb.append(ch) }
        }
        return sb
    }
    public static func write(_ path: String, _ sheets0: [SheetData]) throws {
        let sheets = sheets0.isEmpty ? [SheetData()] : sheets0
        var names = Set<String>()
        for sh in sheets {
            var n = Rx.replace(sh.name, "[\\[\\]\\*\\?/\\\\:]", "").trimmed
            if n.isEmpty { n = "Tabelle" }
            if n.len > 31 { n = n.sub(0, 31) }
            let b = n
            var k = 2
            while names.contains(n.lowercased()) { let suf = " \(k)"; k += 1; n = (b.len + suf.len > 31 ? b.sub(0, 31 - suf.len) : b) + suf }
            names.insert(n.lowercased()); sh.name = n
        }
        let zip = try ZipWriter(path)
        var ct = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        for i in 0..<sheets.count { ct += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }
        ct += "</Types>"
        try zip.add("[Content_Types].xml", text: ct)
        try zip.add("_rels/.rels", text: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")
        var wb = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets>"
        var rels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for i in 0..<sheets.count {
            wb += "<sheet name=\"" + x(sheets[i].name) + "\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
            rels += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }
        wb += "</sheets><calcPr calcId=\"191029\" fullCalcOnLoad=\"1\"/></workbook>"
        rels += "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>"
        try zip.add("xl/workbook.xml", text: wb)
        try zip.add("xl/_rels/workbook.xml.rels", text: rels)
        // Stile: 0 normal, 1 Kopfzeile fett, 2 Prozent, 3 Euro, 4 Dezimalzahl
        try zip.add("xl/styles.xml", text: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><numFmts count=\"2\"><numFmt numFmtId=\"164\" formatCode=\"#,##0.00\\ &quot;€&quot;\"/><numFmt numFmtId=\"165\" formatCode=\"#,##0.##\"/></numFmts><fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font><font><b/><sz val=\"11\"/><color rgb=\"FFFFFFFF\"/><name val=\"Calibri\"/></font></fonts><fills count=\"3\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill><fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF3F4A63\"/><bgColor indexed=\"64\"/></patternFill></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"5\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/><xf numFmtId=\"0\" fontId=\"1\" fillId=\"2\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\"/><xf numFmtId=\"10\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/><xf numFmtId=\"164\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/><xf numFmtId=\"165\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/></cellXfs><cellStyles count=\"1\"><cellStyle name=\"Standard\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>")
        for (si, sheet) in sheets.enumerated() {
            let rows = sheet.rows
            let cols = rows.isEmpty ? 1 : max(1, rows.map { $0.count }.max() ?? 1)
            var widths = [Double](repeating: 0, count: cols)
            for r in rows { for c in 0..<min(r.count, cols) { widths[c] = max(widths[c], min(60, Double(r[c].len) * 1.1 + 2)) } }
            var sx = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
            if rows.count > 1 { sx += "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>" }
            sx += "<cols>"
            for c in 0..<cols { sx += "<col min=\"\(c + 1)\" max=\"\(c + 1)\" width=\"" + oneDecimal(max(9, widths[c])) + "\" customWidth=\"1\"/>" }
            sx += "</cols><sheetData>"
            for (ri, row) in rows.enumerated() {
                sx += "<row r=\"\(ri + 1)\">"
                for c in 0..<min(row.count, cols) {
                    let v = row[c]
                    let refc = col(c) + "\(ri + 1)"
                    if v.isEmpty { continue }
                    if ri == 0 { sx += "<c r=\"" + refc + "\" s=\"1\" t=\"inlineStr\"><is><t xml:space=\"preserve\">" + x(v) + "</t></is></c>"; continue }
                    if v.hasPrefix("=") && v.len > 1 { sx += "<c r=\"" + refc + "\"><f>" + x(formula(v)) + "</f></c>" }
                    else if let (d, st) = tryNumber(v) {
                        let s = st == 2 ? " s=\"2\"" : st == 3 ? " s=\"3\"" : (d.truncatingRemainder(dividingBy: 1) != 0 ? " s=\"4\"" : "")
                        sx += "<c r=\"" + refc + "\"" + s + "><v>" + Json.number(d) + "</v></c>"
                    } else { sx += "<c r=\"" + refc + "\" t=\"inlineStr\"><is><t xml:space=\"preserve\">" + x(v) + "</t></is></c>" }
                }
                sx += "</row>"
            }
            sx += "</sheetData>"
            if rows.count > 1 && cols > 0 { sx += "<autoFilter ref=\"A1:" + col(cols - 1) + "\(rows.count)\"/>" }
            sx += "</worksheet>"
            try zip.add("xl/worksheets/sheet\(si + 1).xml", text: sx)
        }
        try zip.close()
    }
    static func oneDecimal(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }
    /// Tabellen aus Markdown: jede Tabelle wird ein Blatt (Name = letzte Ueberschrift davor).
    public static func fromMarkdown(_ md: String, _ title: String?) -> [SheetData] {
        var list = [SheetData]()
        var head = title
        let loose = SheetData(name: "Inhalt")
        for b in MdBlocks.parse(md) {
            if b.kind == "h" { head = MdBlocks.plain(b.text); continue }
            if b.kind == "table" { list.append(SheetData(name: head ?? "Tabelle", rows: b.rows)); continue }
            if b.kind == "ul" || b.kind == "ol" { for it in b.items { loose.rows.append([MdBlocks.plain(it)]) } }
            else if b.kind == "p" || b.kind == "quote" { loose.rows.append([MdBlocks.plain(b.text)]) }
        }
        if list.isEmpty { loose.rows.insert([title ?? "Inhalt"], at: 0); list.append(loose) }
        return list
    }
    public static func csv(_ sh: SheetData) -> String {
        var sb = ""
        for r in sh.rows {
            sb += r.map { v -> String in v.contains(";") || v.contains("\"") || v.contains("\n") || v.contains("\r") ? "\"" + v.rep("\"", "\"\"") + "\"" : v }.joined(separator: ";") + "\r\n"
        }
        return sb
    }
    public static func toMarkdown(_ sh: SheetData, _ maxRows: Int) -> String {
        if sh.rows.isEmpty { return "" }
        let cols = sh.rows.map { $0.count }.max() ?? 0
        func line(_ r: [String]) -> String { "| " + (0..<cols).map { $0 < r.count ? r[$0].rep("|", "\\|") : "" }.joined(separator: " | ") + " |" }
        var sb = line(sh.rows[0]) + "\n" + "|" + String(repeating: "---|", count: cols) + "\n"
        for r in sh.rows.dropFirst().prefix(maxRows) { sb += line(r) + "\n" }
        if sh.rows.count - 1 > maxRows { sb += "\n*… \(sh.rows.count - 1 - maxRows) weitere Zeilen in der Datei.*\n" }
        return sb
    }
}
