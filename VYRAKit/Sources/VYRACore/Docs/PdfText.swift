import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// Einfache PDF-Textextraktion (unkomprimiert und Flate), ausreichend fuer die meisten normal erstellten PDFs.
/// Unveraendert aus `Pdf` portiert; auf dem iPhone hilft zusaetzlich PDFKit, wenn so kein Text gefunden wird.
public enum Pdf {
    public static func extractText(_ pdf: Data) -> String {
        var t = extractCore([UInt8](pdf))
        #if canImport(PDFKit)
        if t.trimmed.len < 20, let doc = PDFDocument(data: pdf) {
            var b = ""
            for i in 0..<doc.pageCount { if let p = doc.page(at: i), let s = p.string { b += s + "\n\n" } }
            if b.trimmed.len > t.trimmed.len { t = b }
        }
        #endif
        return t
    }
    static func find(_ h: [UInt8], _ n: [UInt8], _ from: Int) -> Int {
        if n.isEmpty || from < 0 || h.count < n.count { return -1 }
        var i = from
        let last = h.count - n.count
        let f = n[0]
        while i <= last {
            if h[i] == f {
                var ok = true
                for k in 1..<n.count where h[i + k] != n[k] { ok = false; break }
                if ok { return i }
            }
            i += 1
        }
        return -1
    }
    /// Wie `LastIndexOf(value, startIndex, count)`: sucht rueckwaerts im Bereich [start-count+1, start].
    static func findBack(_ h: [UInt8], _ n: [UInt8], _ start: Int, _ count: Int) -> Int {
        let lo = max(0, start - count + 1)
        var i = min(start, h.count - 1) - n.count + 1
        while i >= lo {
            var ok = true
            for k in 0..<n.count where h[i + k] != n[k] { ok = false; break }
            if ok { return i }
            i -= 1
        }
        return -1
    }
    static let kStream = Array("stream".utf8), kEnd = Array("endstream".utf8), kDict = Array("<<".utf8)
    static func extractCore(_ raw: [UInt8]) -> String {
        var outp = ""
        var pos = 0, streams = 0
        while true {
            let s = find(raw, kStream, pos)
            if s < 0 { break }
            let e = find(raw, kEnd, s + 6)
            if e < 0 { break }
            if s >= 3 && raw[s - 3] == 0x65 && raw[s - 2] == 0x6E && raw[s - 1] == 0x64 { pos = s + 6; continue } // "end"
            let dictStart = s > 0 ? findBack(raw, kDict, s, min(s, 4000)) : -1
            let dict = dictStart >= 0 ? TextCodec.decodeLatin1(raw[dictStart..<s]) : ""
            var dataStart = s + 6
            if dataStart < raw.count && raw[dataStart] == 0x0D { dataStart += 1 }
            if dataStart < raw.count && raw[dataStart] == 0x0A { dataStart += 1 }
            let len = e - dataStart
            pos = e + 9
            streams += 1
            if len <= 0 || streams > 4000 { continue }
            if dict.contains("/Image") || (dict.contains("/XObject") && !dict.contains("/Form")) || dict.contains("/FontFile") || dict.contains("/DCTDecode") || dict.contains("/Length1") { continue }
            let data = Data(raw[dataStart..<(dataStart + len)])
            var content: String
            if dict.contains("/FlateDecode") { guard let c = inflate(data) else { continue }; content = c }
            else if dict.contains("/Filter") { continue }
            else { content = TextCodec.decodeLatin1(data) }
            if !content.contains("BT") { continue }
            textOps(content, &outp)
        }
        var t = Rx.replace(outp, "[ \\t]+", " ")
        t = Rx.replace(t, "\\n{3,}", "\n\n")
        return t.trimmed
    }
    static func inflate(_ data: Data) -> String? {
        let off = data.count > 2 && (data[data.startIndex] & 0x0F) == 8 ? 2 : 0 // zlib-Kopf ueberspringen
        guard let d = try? Zlib.inflate(data.dropFirst(off), .raw, limit: 20_000_000, partialOK: true), !d.isEmpty else { return nil }
        return TextCodec.decodeLatin1(d)
    }
    /// Liest (Text) Tj, [(Te) -200 (xt)] TJ, ' und " sowie Zeilenwechsel (Td, TD, T*, ET).
    static func textOps(_ s: String, _ outp: inout String) {
        let c = Array(s.unicodeScalars)
        var i = 0
        var inText = false
        var line = ""
        func isLetter(_ u: Unicode.Scalar) -> Bool { u.properties.isAlphabetic }
        func isDigit(_ u: Unicode.Scalar) -> Bool { u >= "0" && u <= "9" }
        while i < c.count {
            let ch = c[i]
            if ch == "(" { let str = readString(c, &i); if inText { line += str }; continue }
            if ch == "[" && inText {
                i += 1
                while i < c.count && c[i] != "]" {
                    if c[i] == "(" { line += readString(c, &i); continue }
                    if c[i] == "-" || isDigit(c[i]) {
                        let st = i
                        while i < c.count && (c[i] == "-" || c[i] == "." || isDigit(c[i])) { i += 1 }
                        var num = ""; num.unicodeScalars.append(contentsOf: c[st..<i])
                        if let k = Double(num), k < -180 { line += " " }
                        continue
                    }
                    i += 1
                }
                i += 1
                continue
            }
            if ch == "%" { while i < c.count && c[i] != "\n" && c[i] != "\r" { i += 1 }; continue }
            if isLetter(ch) || ch == "'" || ch == "\"" || ch == "*" {
                let st = i
                while i < c.count && (isLetter(c[i]) || c[i] == "*" || c[i] == "'" || c[i] == "\"") { i += 1 }
                var op = ""; op.unicodeScalars.append(contentsOf: c[st..<i])
                if op == "BT" { inText = true }
                else if op == "ET" { inText = false; flush(&line, &outp) }
                else if op == "Td" || op == "TD" || op == "T*" || op == "'" || op == "\"" { if !line.isEmpty && !line.hasSuffix(" ") { flush(&line, &outp) } }
                continue
            }
            i += 1
        }
        flush(&line, &outp)
    }
    static func flush(_ line: inout String, _ outp: inout String) { let l = line.trimmed; if !l.isEmpty { outp += l + "\n" }; line = "" }
    static func readString(_ c: [Unicode.Scalar], _ i: inout Int) -> String {
        var b = ""
        var depth = 0
        i += 1
        while i < c.count {
            let ch = c[i]; i += 1
            if ch == "\\" && i < c.count {
                let n = c[i]; i += 1
                switch n {
                case "n": b += "\n"
                case "r", "b", "f", "\r", "\n": break
                case "t": b += " "
                case "(": b += "("
                case ")": b += ")"
                case "\\": b += "\\"
                default:
                    if n >= "0" && n <= "7" {
                        var v = Int(n.value) - 48
                        var k = 0
                        while k < 2 && i < c.count && c[i] >= "0" && c[i] <= "7" { v = v * 8 + Int(c[i].value) - 48; i += 1; k += 1 }
                        b.unicodeScalars.append(winAnsi(v))
                    } else { b.unicodeScalars.append(n) }
                }
                continue
            }
            if ch == "(" { depth += 1; b.unicodeScalars.append(ch); continue }
            if ch == ")" { if depth == 0 { break }; depth -= 1; b.unicodeScalars.append(ch); continue }
            b.unicodeScalars.append(winAnsi(Int(ch.value)))
        }
        return b
    }
    static func winAnsi(_ v: Int) -> Unicode.Scalar {
        if v == 0x80 { return "\u{20AC}" }
        if v == 0x91 || v == 0x92 { return "'" }
        if v == 0x93 || v == 0x94 { return "\"" }
        if v == 0x96 || v == 0x97 { return "-" }
        if v == 0x84 { return "\"" }
        if v < 0x20 && v != 9 && v != 10 { return " " }
        return Unicode.Scalar(UInt32(v)) ?? " "
    }
}
