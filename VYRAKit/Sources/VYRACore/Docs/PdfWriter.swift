import Foundation

/// PDF ohne Zusatzbibliotheken (Helvetica/Courier, WinAnsi) – unveraendert portiert aus `PdfWriter`.
public enum PdfWriter {
    // Zeichenbreiten (1/1000 em) der PDF-Standardschriften Helvetica und Helvetica-Bold fuer ASCII 32..126.
    static let helvW = [278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556, 1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, 333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556, 556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584]
    static let helvBW = [278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611, 975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778, 667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556, 333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611, 611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584]
    static let pageW = 595.28, pageH = 841.89, margin = 56.0
    final class Run { var text: String; var font: Int; var size: Double; var gray: Double = 0
        init(_ t: String, _ f: Int, _ s: Double, _ g: Double = 0) { text = t; font = f; size = s; gray = g } } // Font: 1 normal, 2 fett, 3 kursiv, 4 Courier
    final class Line { var runs = [Run](); var x = 0.0, height = 0.0, size = 0.0; var rule = false, shade = false; var shadeH = 0.0
        init(x: Double = 0, height: Double = 0, size: Double = 0) { self.x = x; self.height = height; self.size = size } }
    static func base(_ c: UInt16) -> UInt16 {
        switch c {
        case 0xe4, 0xe0, 0xe1, 0xe2: return 97 // a
        case 0xf6, 0xf3, 0xf2, 0xf4: return 111 // o
        case 0xfc, 0xfa, 0xf9, 0xfb: return 117 // u
        case 0xc4, 0xc0, 0xc1: return 65
        case 0xd6: return 79
        case 0xdc: return 85
        case 0xe9, 0xe8, 0xea: return 101
        case 0xc9: return 69
        case 0xdf: return 66
        case 0x2013: return 45
        case 0x2014: return 87
        case 0x2022: return 111
        default: return c
        }
    }
    public static func width(_ s: String, _ font: Int, _ size: Double) -> Double {
        if font == 4 { return Double(s.len) * 0.6 * size }
        var w = 0.0
        let t = font == 2 ? helvBW : helvW
        for c0 in s.utf16 { let c = base(c0); w += Double((c >= 32 && c <= 126) ? t[Int(c) - 32] : 556) }
        return w * size / 1000.0
    }
    /// Unicode -> WinAnsi (Windows-1252) als PDF-Zeichenkette mit Escapes.
    static func enc(_ s: String) -> String {
        var b = ""
        for c in s.utf16 {
            var v: Int
            switch c {
            case 0x20ac: v = 0x80
            case 0x201a: v = 0x82
            case 0x201e: v = 0x84
            case 0x2026: v = 0x85
            case 0x2018: v = 0x91
            case 0x2019: v = 0x92
            case 0x201c: v = 0x93
            case 0x201d: v = 0x94
            case 0x2022: v = 0x95
            case 0x2013: v = 0x96
            case 0x2014: v = 0x97
            case 0x2122: v = 0x99
            default: v = c < 256 ? Int(c) : 63
            }
            if v == 40 || v == 41 || v == 92 { b += "\\" + String(UnicodeScalar(UInt8(v))) }
            else if v < 32 || v > 126 { b += "\\" + String(v, radix: 8).padLeft(3, "0") }
            else { b.unicodeScalars.append(UnicodeScalar(UInt8(v))) }
        }
        return b
    }
    /// Inline-Markdown in Abschnitte zerlegen: **fett**, *kursiv*, `code`, [Text](Link)
    static func inline(_ text0: String, _ size: Double, _ baseFont: Int) -> [Run] {
        var runs = [Run]()
        let text = Rx.replace(text0, "\\[([^\\]]+)\\]\\((https?://[^)]+)\\)", "$1 ($2)")
        var pos = 0
        for m in Rx.matches(text, "(\\*\\*[^*]+\\*\\*|`[^`]+`|(?<![\\w*])\\*[^*\\s][^*]*\\*(?![\\w*]))") {
            if m.index > pos { runs.append(Run(text.sub(pos, m.index - pos), baseFont, size)) }
            let v = m.value
            if v.hasPrefix("**") { runs.append(Run(v.sub(2, v.len - 4), 2, size)) }
            else if v.hasPrefix("`") { runs.append(Run(v.sub(1, v.len - 2), 4, size * 0.92)) }
            else { runs.append(Run(v.sub(1, v.len - 2), baseFont == 2 ? 2 : 3, size)) }
            pos = m.index + m.length
        }
        if pos < text.len { runs.append(Run(text.sub(pos), baseFont, size)) }
        return runs
    }
    /// Umbruch nach Woertern auf die verfuegbare Breite.
    static func wrap(_ runs: [Run], _ x: Double, _ width: Double, _ size: Double, _ lead: Double) -> [Line] {
        var lines = [Line]()
        var cur = Line(x: x, height: size * lead, size: size)
        var used = 0.0
        for r in runs {
            for w0 in Rx.split(r.text, "(\\s+)") {
                if w0.isEmpty { continue }
                var w = w0.rep("\t", "    ")
                if w.contains("\n") { continue }
                let space = w.trimmed.isEmpty
                var ww = PdfWriter.width(w, r.font, r.size)
                if !space && used + ww > width && used > 0 { lines.append(cur); cur = Line(x: x, height: size * lead, size: size); used = 0 }
                if space && used == 0 { continue }
                // sehr lange Woerter (z. B. Links) hart teilen
                while !space && ww > width && w.len > 1 {
                    let n = max(1, Int(Double(w.len) * width / ww) - 1)
                    cur.runs.append(Run(w.sub(0, n), r.font, r.size))
                    lines.append(cur); cur = Line(x: x, height: size * lead, size: size)
                    w = w.sub(n); ww = PdfWriter.width(w, r.font, r.size); used = 0
                }
                if let last = cur.runs.last, last.font == r.font && last.size == r.size { last.text += w } else { cur.runs.append(Run(w, r.font, r.size, r.gray)) }
                used += ww
            }
        }
        if !cur.runs.isEmpty { lines.append(cur) }
        for l in lines { if let last = l.runs.last { last.text = last.text.trimEnd() } }
        return lines
    }
    public static func write(_ path: String, _ title: String, _ markdown: String) throws { try FS.write(path, build(title, markdown)) }
    /// "0.##"
    static func f2(_ v: Double) -> String { fmt(v, 2) }
    static func f3(_ v: Double) -> String { fmt(v, 3) }
    static func fmt(_ v: Double, _ digits: Int) -> String {
        let p = pow(10.0, Double(digits))
        let r = (v * p).rounded() / p
        if r == r.rounded() { return String(Int64(r)) }
        var s = String(format: "%.\(digits)f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
    public static func build(_ title: String, _ markdown: String) -> Data {
        let width = pageW - 2 * margin
        var lines = [Line]()
        func gap(_ h: Double) { lines.append(Line(height: h)) }
        if !title.trimmed.isEmpty {
            lines += wrap(inline(title, 21, 2), margin, width, 21, 1.25)
            gap(4)
            let r = Line(height: 14); r.rule = true; lines.append(r)
        }
        var code = false
        for raw in markdown.rep("\r", "").splitKeep("\n") {
            let l = raw.trimEnd(), t = l.trimmed
            if t.hasPrefix("```") { code = !code; gap(4); continue }
            if code {
                var cl: Line = Line(x: margin + 8, height: 12.5, size: 9.5); cl.shade = true; cl.shadeH = 12.5
                cl.runs.append(Run(l.rep("\t", "    "), 4, 9.5))
                // zu lange Codezeilen umbrechen
                let max = width - 16
                while PdfWriter.width(cl.runs[0].text, 4, 9.5) > max {
                    let n = Int(max / (0.6 * 9.5))
                    let rest = cl.runs[0].text.sub(n)
                    cl.runs[0].text = cl.runs[0].text.sub(0, n)
                    lines.append(cl)
                    cl = Line(x: margin + 8, height: 12.5, size: 9.5); cl.shade = true; cl.shadeH = 12.5
                    cl.runs.append(Run(rest, 4, 9.5))
                }
                lines.append(cl); continue
            }
            if t.isEmpty { gap(6); continue }
            if Rx.isMatch(t, "^([-*_])(\\s*\\1){2,}$") { let r = Line(height: 12); r.rule = true; lines.append(r); continue }
            if Rx.isMatch(t, "^\\|?\\s*:?-+:?\\s*(\\|\\s*:?-+:?\\s*)*\\|?$") && t.contains("-") && t.contains("|") { let r = Line(height: 6); r.rule = true; lines.append(r); continue }
            if let hm = Rx.match(t, "^(#{1,6})\\s+(.*)$") {
                let lv = hm.group(1).len
                let sz: Double = lv == 1 ? 16 : lv == 2 ? 14 : 12
                gap(lv <= 2 ? 8 : 5)
                lines += wrap(inline(hm.group(2).trim("# "), sz, 2), margin, width, sz, 1.3)
                gap(2); continue
            }
            if t.hasPrefix("|") {
                let cells = t.trim("|").splitKeep("|").map { $0.trimmed }
                let cw = width / Double(max(1, cells.count))
                // jede Zelle eigene Spalte; Hoehe = laengste Zelle
                var cols = [[Line]]()
                for (i, c) in cells.enumerated() { cols.append(wrap(inline(c, 10, 1), margin + Double(i) * cw, cw - 8, 10, 1.35)) }
                let rows = cols.map { $0.count }.max() ?? 0
                for r in 0..<rows {
                    let row = Line(height: 13.5, size: 10)
                    for c in cols where r < c.count {
                        var first = true
                        for run in c[r].runs { if first { run.gray = -c[r].x }; first = false; row.runs.append(run) }
                    }
                    lines.append(row)
                }
                continue
            }
            if let li = Rx.match(l, "^(\\s*)([-*+•]|\\d{1,3}[.)])\\s+(.*)$") {
                let depth = min(3, li.group(1).rep("\t", "    ").len / 2)
                let ind = margin + 10 + Double(depth) * 14
                let g2 = li.group(2)
                let mark = g2.len == 1 && !(g2.first?.isNumber ?? false) ? "•" : g2
                let wl = wrap(inline(li.group(3), 11, 1), ind + 16, width - (ind - margin) - 16, 11, 1.42)
                if !wl.isEmpty { wl[0].runs.insert(Run(mark, 1, 11, -ind), at: 0) }
                lines += wl; continue
            }
            if t.hasPrefix(">") {
                for x in wrap(inline(t.trimStart("> "), 11, 3), margin + 16, width - 16, 11, 1.42) { for r in x.runs { r.gray = 0.35 }; lines.append(x) }
                continue
            }
            lines += wrap(inline(t, 11, 1), margin, width, 11, 1.42)
        }
        // Seiten setzen
        var pages = [String]()
        var sb = ""
        var y = pageH - margin
        for l in lines {
            if y - l.height < margin + 20 {
                footer(&sb, pages.count + 1); pages.append(sb); sb = ""; y = pageH - margin
                if l.runs.isEmpty && !l.shade { continue }
            }
            y -= l.height
            if l.rule { sb += "0.8 0.8 0.85 RG 0.6 w \(f2(margin)) \(f2(y + l.height / 2)) m \(f2(pageW - margin)) \(f2(y + l.height / 2)) l S\n"; continue }
            if l.shade { sb += "0.95 0.95 0.97 rg \(f2(margin)) \(f2(y - 3)) \(f2(pageW - 2 * margin)) \(f2(l.shadeH)) re f\n" }
            var x = l.x
            for r in l.runs {
                if r.gray < 0 { x = -r.gray } // Spalten- bzw. Aufzaehlungsbeginn
                let fontName = r.font == 2 ? "F2" : r.font == 3 ? "F3" : r.font == 4 ? "F4" : "F1"
                let g = r.gray > 0 ? r.gray : 0.1
                sb += "BT \(f3(g)) \(f3(g)) \(f3(g)) rg /\(fontName) \(f2(r.size)) Tf \(f2(x)) \(f2(y + 2)) Td (" + enc(r.text) + ") Tj ET\n"
                x += PdfWriter.width(r.text, r.font, r.size)
                if r.gray < 0 && (r.text == "•" || Rx.isMatch(r.text, "^\\d{1,3}[.)]$")) { x = -r.gray + max(16, PdfWriter.width(r.text, r.font, r.size) + 5) }
            }
        }
        footer(&sb, pages.count + 1); pages.append(sb)
        return assemble(pages, title)
    }
    static func footer(_ sb: inout String, _ n: Int) {
        let t = "Seite \(n)"
        sb += "BT 0.5 0.5 0.55 rg /F1 9 Tf \(f2((pageW - width(t, 1, 9)) / 2)) 30 Td (" + enc(t) + ") Tj ET\n"
    }
    static func assemble(_ pages: [String], _ title: String) -> Data {
        var objs = [Data]()
        func add(_ s: String) -> Int { objs.append(TextCodec.encodeLatin1(s)); return objs.count }
        let catalog = add(""), pagesObj = add("")
        let f1 = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        let f2o = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>")
        let f3o = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Oblique /Encoding /WinAnsiEncoding >>")
        let f4 = add("<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>")
        var kids = [Int]()
        for p in pages {
            let raw = TextCodec.encodeLatin1(p)
            let z = (try? Zlib.deflate(raw, .zlib, level: 9)) ?? raw
            var all = TextCodec.encodeLatin1("<< /Length \(z.count) /Filter /FlateDecode >>\nstream\n")
            all.append(z); all.append(TextCodec.encodeLatin1("\nendstream"))
            objs.append(all)
            let content = objs.count
            kids.append(add("<< /Type /Page /Parent \(pagesObj) 0 R /MediaBox [0 0 \(f2(pageW)) \(f2(pageH))] /Resources << /Font << /F1 \(f1) 0 R /F2 \(f2o) 0 R /F3 \(f3o) 0 R /F4 \(f4) 0 R >> >> /Contents \(content) 0 R >>"))
        }
        objs[catalog - 1] = TextCodec.encodeLatin1("<< /Type /Catalog /Pages \(pagesObj) 0 R >>")
        objs[pagesObj - 1] = TextCodec.encodeLatin1("<< /Type /Pages /Kids [" + kids.map { "\($0) 0 R" }.joined(separator: " ") + "] /Count \(kids.count) >>")
        let info = add("<< /Title (" + enc(title) + ") /Producer (VYRA KI) /CreationDate (D:" + DE.stamp(Date(), "yyyyMMddHHmmss") + ") >>")
        var ms = Data()
        ms.append(TextCodec.encodeLatin1("%PDF-1.4\n%\u{e2}\u{e3}\u{cf}\u{d3}\n"))
        var offs = [Int]()
        for (i, o) in objs.enumerated() {
            offs.append(ms.count)
            ms.append(TextCodec.encodeLatin1("\(i + 1) 0 obj\n")); ms.append(o); ms.append(TextCodec.encodeLatin1("\nendobj\n"))
        }
        let xref = ms.count
        var t = "xref\n0 \(objs.count + 1)\n0000000000 65535 f \n"
        for o in offs { t += String(o).padLeft(10, "0") + " 00000 n \n" }
        t += "trailer\n<< /Size \(objs.count + 1) /Root \(catalog) 0 R /Info \(info) 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        ms.append(TextCodec.encodeLatin1(t))
        return ms
    }
}
