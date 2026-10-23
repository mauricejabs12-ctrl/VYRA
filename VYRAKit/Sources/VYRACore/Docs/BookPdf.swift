import Foundation

/// WinAnsi (Windows-1252) fuer PDF-Schriften – unveraendert aus `WinAnsi`.
public enum WinAnsi {
    static let high: [UInt16] = [0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0, 0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178]
    static let map: [UInt16: Int] = {
        var m = [UInt16: Int]()
        for c in 32..<127 { m[UInt16(c)] = c }
        for (i, h) in high.enumerated() where h != 0 { m[h] = 0x80 + i }
        for c in 0xA0...0xFF { m[UInt16(c)] = c }
        return m
    }()
    /// Unicode -> WinAnsi-Code (32..255) oder -1.
    public static func code(_ c: UInt16) -> Int { map[c] ?? -1 }
    public static func toChar(_ code: Int) -> UInt16 {
        if code >= 32 && code < 127 { return UInt16(code) }
        if code >= 0x80 && code < 0xA0 { return high[code - 0x80] == 0 ? 63 : high[code - 0x80] }
        if code >= 0xA0 && code <= 0xFF { return UInt16(code) }
        return 63
    }
    /// Ersetzt Zeichen, die in den PDF-Schriften nicht vorkommen, durch gut lesbare Entsprechungen.
    public static func normalize(_ s: String) -> String {
        if s.isEmpty { return "" }
        var b = [UInt16](); b.reserveCapacity(s.len)
        func app(_ t: String) { b.append(contentsOf: t.utf16) }
        for c in s.utf16 {
            if code(c) >= 0 { b.append(c); continue }
            switch c {
            case 0x09: b.append(32)
            case 0x2212, 0x2010, 0x2011: b.append(45)
            case 0x2012, 0x2015: b.append(0x2013)
            case 0x2192: app("->")
            case 0x2190: app("<-")
            case 0x21d2: app("=>")
            case 0x2264: app("<=")
            case 0x2265: app(">=")
            case 0x2260: app("!=")
            case 0x2248: b.append(126)
            case 0x201f: b.append(0x201c)
            case 0x201b: b.append(0x2018)
            case 0x2032: b.append(39)
            case 0x2033: b.append(34)
            case 0x2009, 0x200a, 0x202f, 0x2007, 0x2002, 0x2003: b.append(32)
            case 0x00ad, 0x200b, 0x200c, 0x200d, 0xfeff: break
            case 0x2042, 0x2234: app("* * *")
            case 0x25cf, 0x25aa, 0x25e6, 0x2023: b.append(0x2022)
            case 0x2713, 0x2714: b.append(43)
            case 0x2717, 0x2718: b.append(120)
            case 0x0a, 0x0d: b.append(c)
            default:
                if UTF16.isLeadSurrogate(c) || UTF16.isTrailSurrogate(c) { break } // Emojis u. a. entfallen
                guard let sc = Unicode.Scalar(c) else { break }
                let d = String(Character(sc)).decomposedStringWithCanonicalMapping
                if let basic = d.utf16.first(where: { code($0) >= 0 && $0 < 128 }) { b.append(basic) }
            }
        }
        return String(utf16CodeUnits: b, count: b.count)
    }
    /// Grossbuchstaben wie `ToUpperInvariant` (ß bleibt ß).
    public static func upper(_ s: String) -> String {
        var out = [UInt16]()
        for c in s.utf16 {
            if c == 0xDF { out.append(c); continue }
            if let sc = Unicode.Scalar(c) { let u = String(Character(sc)).uppercased().utf16; out.append(u.count == 1 ? u.first! : c) } else { out.append(c) }
        }
        return String(utf16CodeUnits: out, count: out.count)
    }
}

/// Minimaler TrueType-Leser: Kennzahlen, Zeichenbreiten fuer WinAnsi und die Schriftdatei zum Einbetten.
public final class TrueTypeFont {
    public var postScriptName = ""
    public var data = [UInt8]()
    public var unitsPerEm = 1000, ascent = 800, descent = -200, capHeight = 700, xMin = 0, yMin = -200, xMax = 1000, yMax = 900
    public var italicAngle = 0.0
    public var italic = false, bold = false, fixedPitch = false
    public var widths = [Int](repeating: 0, count: 256)
    static func bad() -> VyraError { VyraError("Schriftdatei ist beschädigt.", .invalidData) }
    static func u16(_ d: [UInt8], _ o: Int) throws -> Int { if o < 0 || o + 2 > d.count { throw bad() }; return Int(d[o]) << 8 | Int(d[o + 1]) }
    static func s16(_ d: [UInt8], _ o: Int) throws -> Int { let v = try u16(d, o); return v >= 32768 ? v - 65536 : v }
    static func u32(_ d: [UInt8], _ o: Int) throws -> Int64 { if o < 0 || o + 4 > d.count { throw bad() }; return Int64(d[o]) << 24 | Int64(d[o + 1]) << 16 | Int64(d[o + 2]) << 8 | Int64(d[o + 3]) }
    public static func load(_ path: String) throws -> TrueTypeFont { try parse([UInt8](FS.read(path))) }
    public static func parse(_ d: [UInt8]) throws -> TrueTypeFont {
        if d.count < 12 || d.count > 20_000_000 { throw VyraError("Keine gültige Schriftdatei.", .invalidData) }
        let version = try u32(d, 0)
        if version != 0x00010000 && version != 0x74727565 { throw VyraError("Nur TrueType-Schriften (.ttf) werden unterstützt.", .invalidData) }
        let count = try u16(d, 4)
        var tables = [String: (Int, Int)]()
        for i in 0..<count {
            let r = 12 + 16 * i
            if r + 16 > d.count { throw bad() }
            let tag = String(decoding: d[r..<r + 4], as: UTF8.self)
            let off = try u32(d, r + 8), len = try u32(d, r + 12)
            if off + len > Int64(d.count) { throw bad() }
            tables[tag] = (Int(off), Int(len))
        }
        for need in ["head", "hhea", "hmtx", "cmap", "maxp"] where tables[need] == nil { throw VyraError("Schriftdatei unvollständig (" + need + ").", .invalidData) }
        let f = TrueTypeFont(); f.data = d
        let head = tables["head"]!.0
        f.unitsPerEm = max(16, try u16(d, head + 18)); f.xMin = try s16(d, head + 36); f.yMin = try s16(d, head + 38); f.xMax = try s16(d, head + 40); f.yMax = try s16(d, head + 42)
        let mac = try u16(d, head + 44); f.bold = mac & 1 != 0; f.italic = mac & 2 != 0
        let hhea = tables["hhea"]!.0
        f.ascent = try s16(d, hhea + 4); f.descent = try s16(d, hhea + 6)
        let metrics = try u16(d, hhea + 34)
        let glyphs = try u16(d, tables["maxp"]!.0 + 4)
        if let os2 = tables["OS/2"] {
            let os = os2.0
            let ver = try u16(d, os)
            let typoA = try s16(d, os + 68), typoD = try s16(d, os + 70)
            if typoA > 0 { f.ascent = typoA; f.descent = typoD }
            f.capHeight = ver >= 2 && os2.1 >= 90 ? try s16(d, os + 88) : Int(Double(f.ascent) * 0.7)
            let fsType = try u16(d, os + 8)
            if fsType & 0x000F == 0x0002 { throw VyraError("Diese Schrift darf nicht eingebettet werden.", .invalidData) }
        } else { f.capHeight = Int(Double(f.ascent) * 0.7) }
        if let post = tables["post"]?.0 {
            f.italicAngle = Double(Int32(truncatingIfNeeded: try u32(d, post + 4))) / 65536.0
            if f.italicAngle > 180 { f.italicAngle -= 65536 }
            f.fixedPitch = try u32(d, post + 12) != 0
        }
        f.postScriptName = try name(d, tables)
        let hmtx = tables["hmtx"]!.0
        func advance(_ g: Int) throws -> Int { let k = min(max(0, g), max(0, metrics - 1)); return try u16(d, hmtx + 4 * k) }
        let cmap = try cmap4(d, tables["cmap"]!.0)
        let missing = try advance(0)
        for code in 32..<256 {
            let c = WinAnsi.toChar(code)
            if let g = cmap[c], g > 0, g < glyphs { f.widths[code] = Int((Double(try advance(g)) * 1000.0 / Double(f.unitsPerEm)).rounded(.toNearestOrEven)) }
            else { f.widths[code] = Int((Double(missing) * 1000.0 / Double(f.unitsPerEm)).rounded(.toNearestOrEven)) }
        }
        if f.widths[32] <= 0 { f.widths[32] = 250 }
        return f
    }
    static func name(_ d: [UInt8], _ tables: [String: (Int, Int)]) throws -> String {
        let fallback = "VYRASerif"
        guard let nm = tables["name"]?.0 else { return fallback }
        let count = try u16(d, nm + 2), strings = nm + (try u16(d, nm + 4))
        for i in 0..<count {
            let r = nm + 6 + 12 * i
            let plat = try u16(d, r), id = try u16(d, r + 6), len = try u16(d, r + 8), off = try u16(d, r + 10)
            if id != 6 || strings + off + len > d.count { continue }
            let bytes = Array(d[(strings + off)..<(strings + off + len)])
            var v: String
            if plat == 3 || plat == 0 {
                var u = [UInt16](); var k = 0
                while k + 1 < bytes.count { u.append(UInt16(bytes[k]) << 8 | UInt16(bytes[k + 1])); k += 2 }
                v = String(utf16CodeUnits: u, count: u.count)
            } else { v = String(decoding: bytes.map { $0 & 0x7F }, as: UTF8.self) }
            v = String(v.unicodeScalars.filter { ($0 >= "A" && $0 <= "Z") || ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" }.map(Character.init))
            if !v.isEmpty { return v.len > 60 ? v.sub(0, 60) : v }
        }
        return fallback
    }
    static func cmap4(_ d: [UInt8], _ cmap: Int) throws -> [UInt16: Int] {
        let n = try u16(d, cmap + 2)
        var best = -1
        for i in 0..<n {
            let r = cmap + 4 + 8 * i
            let plat = try u16(d, r), enc = try u16(d, r + 2)
            let off = cmap + Int(try u32(d, r + 4))
            if try u16(d, off) != 4 { continue }
            if plat == 3 && enc == 1 { best = off; break }
            if plat == 0 && best < 0 { best = off }
        }
        if best < 0 { throw VyraError("Schrift hat keine Unicode-Zuordnung (cmap Format 4).", .invalidData) }
        var map = [UInt16: Int]()
        let segX2 = try u16(d, best + 6), segs = segX2 / 2
        let ends = best + 14, starts = ends + segX2 + 2, deltas = starts + segX2, ranges = deltas + segX2
        for s in 0..<segs {
            let end = try u16(d, ends + 2 * s), start = try u16(d, starts + 2 * s), delta = try s16(d, deltas + 2 * s), ro = try u16(d, ranges + 2 * s)
            if start > end || start == 0xFFFF { continue }
            var c = max(start, 32)
            while c <= end && c <= 0xFFFD {
                defer { c += 1 }
                if WinAnsi.code(UInt16(c)) < 0 { continue }
                var g: Int
                if ro == 0 { g = (c + delta) & 0xFFFF }
                else {
                    let a = ranges + 2 * s + ro + 2 * (c - start)
                    if a + 2 > d.count { continue }
                    g = try u16(d, a)
                    if g != 0 { g = (g + delta) & 0xFFFF }
                }
                map[UInt16(c)] = g
            }
        }
        return map
    }
}

/// Eine Schrift im PDF: eingebettete TrueType-Schrift oder (Rueckfall) eine der 14 PDF-Standardschriften.
public final class PdfFace {
    public var baseName = ""
    public var ttf: TrueTypeFont?
    public var widths = [Int](repeating: 0, count: 256)
    public var italic = false, bold = false
    public func width(_ s: String, _ size: Double) -> Double { widthU(Array(s.utf16), size) }
    func widthU(_ s: [UInt16], _ size: Double) -> Double {
        var w = 0
        for c in s { var code = WinAnsi.code(c); if code < 32 { code = 63 }; w += widths[code] }
        return Double(w) * size / 1000.0
    }
    public static func fromTtf(_ t: TrueTypeFont, _ italic: Bool, _ bold: Bool) -> PdfFace {
        let f = PdfFace(); f.baseName = t.postScriptName; f.ttf = t; f.italic = italic; f.bold = bold; f.widths = t.widths; return f
    }
    public static func standard(_ style: Int) -> PdfFace {
        let f = PdfFace(); f.italic = style == 1 || style == 3; f.bold = style >= 2
        let w = style == 1 ? timesIW : style == 2 ? timesBW : style == 3 ? timesBIW : timesW
        f.baseName = style == 1 ? "Times-Italic" : style == 2 ? "Times-Bold" : style == 3 ? "Times-BoldItalic" : "Times-Roman"
        for i in 0..<224 { f.widths[32 + i] = w[i] > 0 ? w[i] : 500 }
        return f
    }
    static let timesW = [250, 333, 408, 500, 500, 833, 778, 180, 333, 333, 500, 564, 250, 333, 250, 278, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 278, 278, 564, 564, 564, 444, 921, 722, 667, 667, 722, 611, 556, 722, 722, 333, 389, 722, 611, 889, 722, 722, 556, 722, 667, 556, 611, 722, 722, 944, 722, 722, 611, 333, 278, 333, 469, 500, 333, 444, 500, 444, 500, 444, 333, 500, 500, 278, 278, 500, 278, 778, 500, 500, 500, 500, 333, 389, 278, 500, 500, 722, 500, 500, 444, 480, 200, 480, 541, 761, 500, 0, 333, 500, 444, 1000, 500, 500, 333, 1000, 556, 333, 889, 0, 611, 0, 0, 333, 333, 444, 444, 350, 500, 1000, 333, 980, 389, 333, 722, 0, 444, 722, 250, 333, 500, 500, 500, 500, 200, 500, 333, 760, 276, 500, 564, 333, 760, 333, 400, 564, 300, 300, 333, 500, 453, 250, 333, 300, 310, 500, 750, 750, 750, 444, 722, 722, 722, 722, 722, 722, 889, 667, 611, 611, 611, 611, 333, 333, 333, 333, 722, 722, 722, 722, 722, 722, 722, 564, 722, 722, 722, 722, 722, 722, 556, 500, 444, 444, 444, 444, 444, 444, 667, 444, 444, 444, 444, 444, 278, 278, 278, 278, 500, 500, 500, 500, 500, 500, 500, 564, 500, 500, 500, 500, 500, 500, 500, 500]
    static let timesIW = [250, 333, 420, 500, 500, 833, 778, 214, 333, 333, 500, 675, 250, 333, 250, 278, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 333, 333, 675, 675, 675, 500, 920, 611, 611, 667, 722, 611, 611, 722, 722, 333, 444, 667, 556, 833, 667, 722, 611, 722, 611, 500, 556, 722, 611, 833, 611, 556, 556, 389, 278, 389, 422, 500, 333, 500, 500, 444, 500, 444, 278, 500, 500, 278, 278, 444, 278, 722, 500, 500, 500, 500, 389, 389, 278, 500, 444, 667, 444, 444, 389, 400, 275, 400, 541, 761, 500, 0, 333, 500, 556, 889, 500, 500, 333, 1000, 500, 333, 944, 0, 556, 0, 0, 333, 333, 556, 556, 350, 500, 889, 333, 980, 389, 333, 667, 0, 389, 556, 250, 389, 500, 500, 500, 500, 275, 500, 333, 760, 276, 500, 675, 333, 760, 333, 400, 675, 300, 300, 333, 500, 523, 250, 333, 300, 310, 500, 750, 750, 750, 500, 611, 611, 611, 611, 611, 611, 889, 667, 611, 611, 611, 611, 333, 333, 333, 333, 722, 667, 722, 722, 722, 722, 722, 675, 722, 722, 722, 722, 722, 556, 611, 500, 500, 500, 500, 500, 500, 500, 667, 444, 444, 444, 444, 444, 278, 278, 278, 278, 500, 500, 500, 500, 500, 500, 500, 675, 500, 500, 500, 500, 500, 444, 500, 444]
    static let timesBW = [250, 333, 555, 500, 500, 1000, 833, 278, 333, 333, 500, 570, 250, 333, 250, 278, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 333, 333, 570, 570, 570, 500, 930, 722, 667, 722, 722, 667, 611, 778, 778, 389, 500, 778, 667, 944, 722, 778, 611, 778, 722, 556, 667, 722, 722, 1000, 722, 722, 667, 333, 278, 333, 581, 500, 333, 500, 556, 444, 556, 444, 333, 500, 556, 278, 333, 556, 278, 833, 556, 500, 556, 556, 444, 389, 333, 556, 500, 722, 500, 500, 444, 394, 220, 394, 520, 761, 500, 0, 333, 500, 500, 1000, 500, 500, 333, 1000, 556, 333, 1000, 0, 667, 0, 0, 333, 333, 500, 500, 350, 500, 1000, 333, 1000, 389, 333, 722, 0, 444, 722, 250, 333, 500, 500, 500, 500, 220, 500, 333, 747, 300, 500, 570, 333, 747, 333, 400, 570, 300, 300, 333, 556, 540, 250, 333, 300, 330, 500, 750, 750, 750, 500, 722, 722, 722, 722, 722, 722, 1000, 722, 667, 667, 667, 667, 389, 389, 389, 389, 722, 722, 778, 778, 778, 778, 778, 570, 778, 722, 722, 722, 722, 722, 611, 556, 500, 500, 500, 500, 500, 500, 722, 444, 444, 444, 444, 444, 278, 278, 278, 278, 500, 556, 500, 500, 500, 500, 500, 570, 500, 556, 556, 556, 556, 500, 556, 500]
    static let timesBIW = [250, 389, 555, 500, 500, 833, 778, 278, 333, 333, 500, 570, 250, 333, 250, 278, 500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 333, 333, 570, 570, 570, 500, 832, 667, 667, 667, 722, 667, 667, 722, 778, 389, 500, 667, 611, 889, 722, 722, 611, 722, 667, 556, 611, 722, 667, 889, 667, 611, 611, 333, 278, 333, 570, 500, 333, 500, 500, 444, 500, 444, 333, 500, 556, 278, 278, 500, 278, 778, 556, 500, 500, 500, 389, 389, 278, 556, 444, 667, 500, 444, 389, 348, 220, 348, 570, 761, 500, 0, 333, 500, 500, 1000, 500, 500, 333, 1000, 556, 333, 944, 0, 611, 0, 0, 333, 333, 500, 500, 350, 500, 1000, 333, 1000, 389, 333, 722, 0, 389, 611, 250, 389, 500, 500, 500, 500, 220, 500, 333, 747, 266, 500, 606, 333, 747, 333, 400, 570, 300, 300, 333, 576, 500, 250, 333, 300, 300, 500, 750, 750, 750, 500, 667, 667, 667, 667, 667, 667, 944, 667, 667, 667, 667, 667, 389, 389, 389, 389, 722, 722, 722, 722, 722, 722, 722, 570, 722, 722, 722, 722, 722, 611, 611, 500, 500, 500, 500, 500, 500, 500, 722, 444, 444, 444, 444, 444, 278, 278, 278, 278, 500, 556, 500, 500, 500, 500, 500, 570, 500, 556, 556, 556, 556, 444, 500, 444]
}

public final class BookFormat {
    public let id: String, name: String
    public let w: Double, h: Double, body: Double, lead: Double, top: Double, bottom: Double, outside: Double
    init(_ id: String, _ name: String, _ w: Double, _ h: Double, _ body: Double, _ lead: Double, _ top: Double, _ bottom: Double, _ outside: Double) {
        self.id = id; self.name = name; self.w = w; self.h = h; self.body = body; self.lead = lead; self.top = top; self.bottom = bottom; self.outside = outside
    }
    public static let all: [BookFormat] = [
        BookFormat("6x9", "6 × 9 Zoll (15,24 × 22,86 cm, KDP-Standard)", 432, 648, 11.5, 15.2, 54, 54, 46.8),
        BookFormat("5.5x8.5", "5,5 × 8,5 Zoll (13,97 × 21,59 cm)", 396, 612, 11.2, 14.8, 52, 52, 45),
        BookFormat("5x8", "5 × 8 Zoll (12,7 × 20,32 cm)", 360, 576, 10.8, 14.2, 50, 50, 43.2),
        BookFormat("a5", "DIN A5 (14,8 × 21 cm)", 419.53, 595.28, 11, 14.6, 52, 52, 45),
        BookFormat("a4", "DIN A4 (21 × 29,7 cm)", 595.28, 841.89, 12.5, 17, 72, 72, 64),
    ]
    public static func get(_ id: String?) -> BookFormat { let k = (id ?? "").trimmed.lowercased(); return all.first { $0.id == k } ?? all[0] }
    /// Erkennt ein Buchformat im Wunsch des Nutzers (nil = nicht genannt).
    public static func detect(_ text: String?) -> String? {
        let t = (text ?? "").lowercased().rep(",", ".")
        if Rx.isMatch(t, "\\b(din[ -]?)?a4\\b") { return "a4" }
        if Rx.isMatch(t, "\\b(din[ -]?)?a5\\b") { return "a5" }
        if Rx.isMatch(t, "\\b5\\.5\\s*(x|×|mal)\\s*8\\.5\\b") { return "5.5x8.5" }
        if Rx.isMatch(t, "\\b5\\s*(x|×|mal)\\s*8\\b") { return "5x8" }
        if Rx.isMatch(t, "\\b6\\s*(x|×|mal)\\s*9\\b|\\bkdp\\b|taschenbuch|paperback|amazon") { return "6x9" }
        return nil
    }
    /// KDP-Mindestbundsteg nach Seitenzahl (Zoll).
    public static func gutterInches(_ pages: Int) -> Double { pages <= 150 ? 0.375 : pages <= 300 ? 0.5 : pages <= 500 ? 0.625 : pages <= 700 ? 0.75 : 0.875 }
}

public final class BookChapterText { public var title = "", text = ""; public init(_ t: String = "", _ x: String = "") { title = t; text = x } }
public final class BookDocument {
    public var title = "", subtitle = "", author = "", format = "6x9", kind = "roman", chapterLabel = "Kapitel"
    public var year = DE.year
    public var chapters = [BookChapterText]()
    public var numberChapters = true, chaptersOnRecto = true
    public init() {}
}
public final class BookPdfResult {
    public var bytes = Data()
    public var pages = 0, words = 0
    public var gutterInches = 0.0
    public var fontsEmbedded = false
    public var fontName = "", formatName = ""
    public var chapterPages = [Int]()
}

/// Buchsatz als PDF (Titelei, Inhaltsverzeichnis, Kapitel, Kolumnentitel, Bundsteg nach KDP) – unveraendert aus `BookPdf`.
public enum BookPdf {
    public static let fontRegular = "CrimsonText-Regular.ttf", fontItalic = "CrimsonText-Italic.ttf", fontBold = "CrimsonText-Bold.ttf", fontBoldItalic = "CrimsonText-BoldItalic.ttf"
    /// iOS: Die Schriften liegen im App-Paket (Resources/Schriften).
    public static func defaultFontFolder() -> String {
        if let u = Bundle.module.url(forResource: "CrimsonText-Regular", withExtension: "ttf", subdirectory: "Resources/Schriften") { return u.deletingLastPathComponent().path }
        return ""
    }
    /// Laedt die vier Schnitte. Fehlt etwas, nimmt VYRA die PDF-Standardschrift Times (dann nicht eingebettet).
    public static func faces(_ folder: String?, _ embedded: inout Bool, _ name: inout String) -> [PdfFace] {
        embedded = false; name = "Times (PDF-Standardschrift, nicht eingebettet)"
        if let folder = folder, !folder.isEmpty, FS.isDir(folder) {
            let files = [fontRegular, fontItalic, fontBold, fontBoldItalic]
            var ttf = [TrueTypeFont?](repeating: nil, count: 4)
            do {
                for i in 0..<4 { let p = FS.join(folder, files[i]); if FS.isFile(p) { ttf[i] = try TrueTypeFont.load(p) } }
                if ttf[0] != nil {
                    if ttf[1] == nil { ttf[1] = ttf[0] }
                    if ttf[2] == nil { ttf[2] = ttf[0] }
                    if ttf[3] == nil { ttf[3] = ttf[2] }
                    embedded = true; name = "Crimson Text (eingebettet, SIL Open Font License)"
                    return (0..<4).map { PdfFace.fromTtf(ttf[$0]!, $0 == 1 || $0 == 3, $0 >= 2) }
                }
            } catch {}
        }
        return (0..<4).map { PdfFace.standard($0) }
    }
    @discardableResult
    public static func write(_ path: String, _ doc: BookDocument, _ fontFolder: String?) throws -> BookPdfResult {
        let r = try build(doc, fontFolder)
        try FS.writeAtomic(path, r.bytes)
        return r
    }

    // ------------------------------------------------ Satz
    final class Piece { var text: [UInt16]; var style: Int; init(_ t: [UInt16], _ s: Int) { text = t; style = s } }
    final class Word { var parts = [Piece](); var width = 0.0; var join = false }
    final class Line { var words = [Word](); var indent = 0.0, extra = 0.0, natural = 0.0, size = 0.0, tracking = 0.0, avail = 0.0; var align = 0; var marker: String? }
    final class Para { var kind = "p"; var lines = [Line](); init(_ k: String = "p") { kind = k } }
    final class Draw { let l: Line; let x: Double, y: Double; init(_ l: Line, _ x: Double, _ y: Double) { self.l = l; self.x = x; self.y = y } }
    final class Page { var items = [Draw](); var head = ""; var folio = false, blank = false, opening = false; var chapterIndex = -1 }
    final class Ctx {
        var f: [PdfFace]; let fmt: BookFormat; let doc: BookDocument
        var inside = 0.0, width = 0.0
        var pages = [Page]()
        var y0 = 0.0, linesBottom = 0.0
        var linesPerPage = 0
        init(_ f: [PdfFace], _ fmt: BookFormat, _ doc: BookDocument) { self.f = f; self.fmt = fmt; self.doc = doc }
        func left(_ pageIndex: Int) -> Double { pageIndex % 2 == 0 ? inside : fmt.outside } // pageIndex 0 = Seite 1 (rechts)
        func index(_ p: Page) -> Int { pages.firstIndex { $0 === p } ?? -1 }
    }
    static let rxInline = "(\\*\\*\\*[^*]+\\*\\*\\*|\\*\\*[^*]+\\*\\*|(?<![\\w*])\\*[^*\\s][^*]*\\*(?![\\w*])|(?<![\\w_])_[^_\\s][^_]*_(?![\\w_])|`[^`]+`)"
    static func isLetter(_ c: UInt16) -> Bool {
        guard let s = Unicode.Scalar(c) else { return false }
        switch s.properties.generalCategory { case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true; default: return false }
    }
    /// Inline-Auszeichnungen -> Woerter mit Schnitten. Trennstellen an vorhandenen Bindestrichen und Schraegstrichen.
    static func words(_ c: Ctx, _ text0: String, _ baseStyle: Int, _ size: Double) -> [Word] {
        let text = WinAnsi.normalize(Rx.replace(text0, "\\[([^\\]]+)\\]\\((https?://[^)]+)\\)", "$1"))
        var chars = [(UInt16, Int)]()
        var pos = 0
        func add(_ s: String, _ st: Int) { for ch in s.utf16 { chars.append((ch, st)) } }
        for m in Rx.matches(text, rxInline) {
            if m.index > pos { add(text.sub(pos, m.index - pos), baseStyle) }
            let v = m.value
            if v.hasPrefix("***") { add(v.sub(3, v.len - 6), 3) }
            else if v.hasPrefix("**") { add(v.sub(2, v.len - 4), baseStyle | 2) }
            else if v.hasPrefix("`") { add(v.sub(1, v.len - 2), baseStyle) }
            else { add(v.sub(1, v.len - 2), baseStyle ^ 1) }
            pos = m.index + m.length
        }
        if pos < text.len { add(text.sub(pos), baseStyle) }
        var words = [Word]()
        var cur: Word?
        func put(_ ch: UInt16, _ st: Int) {
            if cur == nil { cur = Word(); words.append(cur!) }
            if let last = cur!.parts.last, last.style == st { last.text.append(ch) } else { cur!.parts.append(Piece([ch], st)) }
        }
        for i in 0..<chars.count {
            let (ch, st) = chars[i]
            if ch == 32 || ch == 10 || ch == 13 { cur = nil; continue }
            put(ch, st)
            // Umbruch nach Bindestrich/Schraegstrich, wenn davor und danach mindestens zwei Buchstaben stehen
            if (ch == 45 || ch == 47), let w = cur, i + 2 < chars.count, isLetter(chars[i + 1].0), isLetter(chars[i + 2].0) {
                let t = textOf(w)
                if t.count >= 3 && isLetter(t[t.count - 2]) { w.join = true; cur = nil }
            }
        }
        for w in words { w.width = measure(c, w, size) }
        return words
    }
    static func textOf(_ w: Word) -> [UInt16] { w.parts.flatMap { $0.text } }
    static func str(_ u: [UInt16]) -> String { String(utf16CodeUnits: u, count: u.count) }
    static func measure(_ c: Ctx, _ w: Word, _ size: Double) -> Double { w.parts.reduce(0.0) { $0 + c.f[$1.style].widthU($1.text, size) } }
    /// Sehr lange Woerter (Links, Zahlenketten) hart teilen.
    static func splitLong(_ c: Ctx, _ words: [Word], _ width: Double, _ size: Double) -> [Word] {
        var outp = [Word]()
        for w in words {
            if w.width <= width { outp.append(w); continue }
            var flat = [(UInt16, Int)]()
            for p in w.parts { for ch in p.text { flat.append((ch, p.style)) } }
            var cur = Word()
            for (ch, st) in flat {
                let trial = Word()
                trial.parts = cur.parts.map { Piece($0.text, $0.style) }
                if let lp = trial.parts.last, lp.style == st { lp.text.append(ch) } else { trial.parts.append(Piece([ch], st)) }
                if measure(c, trial, size) + c.f[st].width("-", size) > width && !cur.parts.isEmpty {
                    cur.parts[cur.parts.count - 1].text.append(45); cur.join = true; cur.width = measure(c, cur, size); outp.append(cur)
                    cur = Word(); cur.parts.append(Piece([ch], st))
                } else { cur = trial }
            }
            cur.join = w.join; cur.width = measure(c, cur, size); outp.append(cur)
        }
        return outp
    }
    /// Optimaler Zeilenfall fuer den ganzen Absatz (wie im Buchsatz): gleichmaessige Wortabstaende statt Luecken.
    static func breakLines(_ c: Ctx, _ words0: [Word], _ width: Double, _ indent: Double, _ size: Double, _ justify: Bool, _ align: Int) -> [Line] {
        var lines = [Line]()
        let words = splitLong(c, words0, width - indent, size)
        let n = words.count
        if n == 0 { return lines }
        let space = c.f[0].width(" ", size)
        var cost = [Double](repeating: Double.greatestFiniteMagnitude, count: n + 1); cost[0] = 0
        var prev = [Int](repeating: 0, count: n + 1)
        for j in 1...n {
            var natural = 0.0
            var gaps = 0
            var i = j - 1
            while i >= 0 {
                natural += words[i].width
                if i < j - 1 && !words[i].join { natural += space; gaps += 1 }
                let avail = width - (i == 0 ? indent : 0)
                let shrink = Double(gaps) * space * 0.25
                if natural - shrink > avail && i < j - 1 { break }
                var cst: Double
                let last = j == n
                if natural - shrink > avail { cst = 1e7 }
                else if last { cst = natural <= avail ? 0 : 100 * pow((natural - avail) / max(0.01, shrink), 3) }
                else if !justify { cst = 100 * pow((avail - natural) / max(1, avail), 2) * 10 }
                else if gaps == 0 { cst = 5000 + 20000 * pow((avail - natural) / max(1, avail), 2) } // einzelnes Wort in der Zeile: nur als letzter Ausweg
                else {
                    let r = (avail - natural) / (Double(gaps) * space)
                    let ratio = r >= 0 ? r / 0.6 : -r / 0.25
                    cst = 100 * pow(ratio, 3)
                    if r > 2.5 { cst += 3000 }
                }
                if cost[i] < Double.greatestFiniteMagnitude && cost[i] + cst + 1 < cost[j] { cost[j] = cost[i] + cst + 1; prev[j] = i }
                i -= 1
            }
        }
        var ends = [Int]()
        var j = n
        while j > 0 { ends.append(j); j = prev[j] }
        ends.reverse()
        var start = 0
        for end in ends {
            let l = Line(); l.size = size; l.align = align; l.indent = start == 0 ? indent : 0
            var natural = 0.0
            var gaps = 0
            for k in start..<end { l.words.append(words[k]); natural += words[k].width; if k < end - 1 && !words[k].join { natural += space; gaps += 1 } }
            l.natural = natural; l.avail = width - l.indent
            if justify && gaps > 0 && (end < n || natural > l.avail) { l.extra = max(-space * 0.25, (l.avail - natural) / Double(gaps)) } // letzte Zeile nur stauchen, nie dehnen
            lines.append(l); start = end
        }
        return lines
    }
    /// Fuer Tests: setzt einen Absatz und liefert die Zeilen als Text (mit Wortabstand-Zuschlag).
    public static func previewLines(_ paragraph: String, _ format: String, _ fontFolder: String?, _ indent: Bool) -> [String] {
        var embedded = false, fontName = ""
        let c = Ctx(faces(fontFolder, &embedded, &fontName), BookFormat.get(format), BookDocument())
        c.inside = (0.375 + 0.15) * 72; c.width = c.fmt.w - c.inside - c.fmt.outside
        var outp = [String]()
        for l in breakLines(c, words(c, paragraph, 0, c.fmt.body), c.width, indent ? c.fmt.body * 1.3 : 0, c.fmt.body, true, 0) {
            var gaps = 0
            for k in 0..<max(0, l.words.count - 1) where !l.words[k].join { gaps += 1 }
            let final = l.natural + l.extra * Double(gaps)
            outp.append(l.words.map { str(textOf($0)) + ($0.join ? "|" : "") }.joined(separator: " ") + " [extra=" + String(format: "%.2f", l.extra) + " nat=" + String(format: "%.1f", l.natural) + " final=" + String(format: "%.1f", final) + "/" + String(format: "%.1f", l.avail) + "]")
        }
        return outp
    }
    static func simple(_ c: Ctx, _ text: String, _ style: Int, _ size: Double, _ tracking: Double) -> Line {
        let l = Line(); l.size = size; l.align = 1; l.tracking = tracking
        let w = Word(); w.parts.append(Piece(Array(WinAnsi.normalize(text).utf16), style))
        w.width = measure(c, w, size) + tracking * Double(max(0, w.parts[0].text.count))
        l.words.append(w); l.natural = w.width; l.avail = c.width
        return l
    }
    static let rxScene = "^\\s*((\\*\\s*){3,}|(-\\s*){3,}|(_\\s*){3,}|(~\\s*){3,}|#{1,6}|\u{2042}|\u{2234}|\u{25c6}|\u{2766}|\u{00a7})\\s*$"
    /// Kapiteltext (Markdown-aehnlich) -> Absaetze. Jede Textzeile ist ein Absatz (so schreiben KI-Modelle Romane).
    static func paragraphs(_ c: Ctx, _ text: String, _ fiction: Bool) -> [Para] {
        var paras = [Para]()
        let size = c.fmt.body, indent = size * 1.3
        var afterBreak = true
        for raw in text.rep("\r", "").components(separatedBy: "\n") {
            let t = raw.trimmed
            if t.isEmpty { continue }
            if Rx.isMatch(t, rxScene) { if let l = paras.last, l.kind != "scene" { paras.append(Para("scene")) }; afterBreak = true; continue }
            if let hm = Rx.match(t, "^#{1,6}\\s+(.+)$") {
                let p = Para("head")
                p.lines.append(contentsOf: breakLines(c, words(c, hm.group(1).trim("# *"), 2, size * 1.08), c.width, 0, size * 1.08, false, 0))
                paras.append(p); afterBreak = true; continue
            }
            if let li = Rx.match(t, "^([-*+\u{2022}]|\\d{1,3}[.)])\\s+(.+)$"), !(fiction && li.group(1) == "-") {
                let g1 = li.group(1)
                let mark = g1.first!.isASCII && g1.first!.isNumber ? g1 : "\u{2022}"
                let p = Para("list")
                let hang = size * 1.6
                let ls = breakLines(c, words(c, li.group(2), 0, size), c.width - hang, 0, size, true, 0)
                for l in ls { l.indent += hang }
                if let f = ls.first { f.marker = mark }
                p.lines.append(contentsOf: ls); paras.append(p); afterBreak = false; continue
            }
            if t.hasPrefix(">") {
                let p = Para("quote")
                let ls = breakLines(c, words(c, t.trimStart("> "), 1, size), c.width - size * 2.4, 0, size, true, 0)
                for l in ls { l.indent += size * 1.2 }
                p.lines.append(contentsOf: ls); paras.append(p); afterBreak = true; continue
            }
            let pp = Para("p")
            pp.lines.append(contentsOf: breakLines(c, words(c, t, 0, size), c.width, afterBreak ? 0 : indent, size, true, 0))
            paras.append(pp); afterBreak = false
        }
        while let l = paras.last, l.kind == "scene" { paras.removeLast() }
        return paras
    }
    static func newPage(_ c: Ctx, _ recto: Bool) -> Page {
        if recto && c.pages.count % 2 == 1 { let b = Page(); b.blank = true; c.pages.append(b) }
        let p = Page(); c.pages.append(p); return p
    }
    static func put(_ c: Ctx, _ page: Page, _ l: Line, _ y: Double) {
        let index = c.index(page)
        let left = c.left(index)
        var x = left + l.indent
        if l.align == 1 { x = left + (c.width - l.natural) / 2 }
        page.items.append(Draw(l, x, y))
    }
    static func grid(_ c: Ctx, _ y: Double) -> Int { max(0, Int(((c.y0 - y) / c.fmt.lead - 1e-6).rounded(.up))) }
    /// Ein Kapitel setzen: Kapitelanfang (abgesenkt), Absaetze mit Schusterjungen-/Hurenkinder-Regel (mindestens 2 Zeilen).
    static func chapter(_ c: Ctx, _ index: Int, _ ch: BookChapterText, _ fiction: Bool) -> Int {
        var page = newPage(c, c.doc.chaptersOnRecto)
        let first = c.pages.count - 1
        page.chapterIndex = index; page.folio = true; page.opening = true
        var y = c.y0 - (c.y0 - c.linesBottom) * 0.16
        let size = c.fmt.body
        if c.doc.numberChapters { let lab = simple(c, WinAnsi.upper(c.doc.chapterLabel + " \(index + 1)"), 0, size * 0.82, size * 0.16); put(c, page, lab, y); y -= c.fmt.lead * 1.5 }
        let ts = size * 1.7
        for l in breakLines(c, words(c, ch.title, 0, ts), c.width * 0.86, 0, ts, false, 1) { l.align = 1; put(c, page, l, y); y -= ts * 1.28 }
        y -= c.fmt.lead * 1.6
        var row = grid(c, y)
        for para in paragraphs(c, ch.text, fiction) {
            if para.kind == "scene" {
                if row >= c.linesPerPage - 1 { page = body(c, index); row = 0; continue } // Szenenwechsel am Seitenende: neue Seite genuegt
                if row == 0 { continue }
                put(c, page, simple(c, "*      *      *", 0, size, 0), c.y0 - Double(row) * c.fmt.lead); row += 1; continue
            }
            if para.kind == "head" {
                if row > 0 { row += 1 }
                if row + para.lines.count + 2 > c.linesPerPage { page = body(c, index); row = 0 }
                for l in para.lines { put(c, page, l, c.y0 - Double(row) * c.fmt.lead); row += 1 }
                continue
            }
            let n = para.lines.count
            var done = 0
            while done < n {
                let left = c.linesPerPage - row, rest = n - done
                if left <= 0 { page = body(c, index); row = 0; continue }
                var take = min(left, rest)
                if take < rest && row > 0 { // Absatz wird geteilt: keine einzelne erste Zeile unten, keine einzelne letzte Zeile oben
                    if done == 0 && take < 2 { page = body(c, index); row = 0; continue }
                    if rest - take == 1 {
                        if take - 1 >= (done == 0 ? 2 : 1) { take -= 1 }
                        else if done == 0 { page = body(c, index); row = 0; continue }
                    }
                }
                for k in 0..<take { put(c, page, para.lines[done + k], c.y0 - Double(row) * c.fmt.lead); row += 1 }
                done += take
            }
        }
        return first
    }
    static func body(_ c: Ctx, _ chapter: Int) -> Page {
        let p = newPage(c, false); p.chapterIndex = chapter; p.folio = true
        p.head = chapter >= 0 && chapter < c.doc.chapters.count ? c.doc.chapters[chapter].title : ""
        return p
    }
    static func dots(_ c: Ctx, _ width: Double, _ size: Double) -> String {
        let d = c.f[0].width(". ", size)
        let n = Int(((width + c.f[0].width(" ", size)) / max(0.1, d)).rounded(.down))
        return n < 2 ? "" : Array(repeating: ".", count: n).joined(separator: " ")
    }

    public static func build(_ doc: BookDocument, _ fontFolder: String?) throws -> BookPdfResult {
        var embedded = false, fontName = ""
        let faces = faces(fontFolder, &embedded, &fontName)
        let fmt = BookFormat.get(doc.format)
        let fiction = !Rx.isMatch(doc.kind.lowercased(), "sach|ratgeber|lehr|fach|handbuch|biograf|anleitung")
        let words = doc.chapters.reduce(0) { $0 + Rx.count($1.text, "\\S+") }
        let estimate = max(24, words / 260 + doc.chapters.count + 6)
        var gutter = BookFormat.gutterInches(estimate)
        var c = Ctx(faces, fmt, doc)
        var starts = [Int]()
        for _ in 0..<4 {
            c = Ctx(faces, fmt, doc); c.inside = (gutter + 0.15) * 72; c.width = fmt.w - c.inside - fmt.outside
            c.y0 = fmt.h - fmt.top - fmt.body * 0.8
            c.linesPerPage = Int(((c.y0 - fmt.bottom) / fmt.lead).rounded(.down)) + 1
            c.linesBottom = c.y0 - Double(c.linesPerPage - 1) * fmt.lead
            starts = layout(c, fiction)
            let need = BookFormat.gutterInches(c.pages.count)
            if abs(need - gutter) < 0.001 { break }
            gutter = need
        }
        let res = BookPdfResult()
        res.pages = c.pages.count; res.words = words; res.gutterInches = gutter; res.fontsEmbedded = embedded; res.fontName = fontName; res.formatName = fmt.name
        res.chapterPages = starts.map { $0 + 1 }
        res.bytes = assemble(c, starts)
        return res
    }
    /// Titelei (Titel, Impressum, Inhalt) und Kapitel. Liefert die Startseite (Index) je Kapitel.
    static func layout(_ c: Ctx, _ fiction: Bool) -> [Int] {
        let fmt = c.fmt, doc = c.doc
        let size = fmt.body
        // Seite 1: Titel
        let title = newPage(c, false)
        var y = fmt.h * 0.70
        let ts = min(size * 2.5, 30)
        for l in breakLines(c, words(c, doc.title, 0, ts), c.width * 0.92, 0, ts, false, 1) { l.align = 1; put(c, title, l, y); y -= ts * 1.22 }
        if !doc.subtitle.trimmed.isEmpty {
            y -= size * 1.2
            let ss = size * 1.3
            for l in breakLines(c, words(c, doc.subtitle, 1, ss), c.width * 0.86, 0, ss, false, 1) { l.align = 1; put(c, title, l, y); y -= ss * 1.3 }
        }
        if !doc.author.trimmed.isEmpty { put(c, title, simple(c, doc.author, 0, size * 1.3, 0), fmt.h * 0.30) }
        // Seite 2: Impressum
        let imp = newPage(c, false)
        var lines = [String]()
        lines.append("© \(doc.year)" + (doc.author.trimmed.isEmpty ? "" : " " + doc.author.trimmed)); lines.append("Alle Rechte vorbehalten."); lines.append("")
        lines.append(fiction ? "Dieses Buch ist ein Werk der Fiktion. Namen, Personen, Orte und Ereignisse sind frei erfunden; Ähnlichkeiten mit realen Personen oder Ereignissen wären zufällig." : "Alle Angaben wurden sorgfältig zusammengestellt, erfolgen aber ohne Gewähr.")
        let isz = size * 0.8
        var impLines = [Line?]()
        for t in lines { if t.isEmpty { impLines.append(nil); continue }; impLines.append(contentsOf: breakLines(c, words(c, t, 0, isz), c.width, 0, isz, false, 0).map { Optional($0) }) }
        y = fmt.bottom + Double(impLines.count) * isz * 1.4
        for l in impLines { if let l = l { put(c, imp, l, y) }; y -= isz * 1.4 }
        // Inhalt: erst Zeilen setzen (Seitenzahl-Platz reserviert), Nummern nach dem Kapitelsatz eintragen
        var toc = [(Int, [Line])]()
        let numW = c.f[0].width("000", size) + size
        for i in 0..<doc.chapters.count {
            let label = (doc.numberChapters ? "\(i + 1).\u{00a0}" : "") + doc.chapters[i].title
            toc.append((i, breakLines(c, words(c, label, 0, size), c.width - numW, 0, size, false, 0)))
        }
        var tocPage = newPage(c, true); tocPage.folio = true; tocPage.opening = true
        var tocSlots = [(Page, Double, Line, Int)]()
        y = c.y0 - (c.y0 - c.linesBottom) * 0.16
        put(c, tocPage, simple(c, "Inhalt", 0, size * 1.6, 0), y); y -= fmt.lead * 2.6
        for e in toc {
            if y - Double(e.1.count) * fmt.lead < c.linesBottom { tocPage = newPage(c, false); tocPage.folio = true; y = c.y0 }
            for k in 0..<e.1.count {
                let l = e.1[k]
                if k > 0 { l.indent = c.f[0].width("\(e.0 + 1).\u{00a0}", size) }
                put(c, tocPage, l, y)
                if k == e.1.count - 1 { tocSlots.append((tocPage, y, l, e.0)) }
                y -= fmt.lead
            }
            y -= fmt.lead * 0.35
        }
        // Kapitel
        var starts = [Int]()
        for i in 0..<doc.chapters.count { starts.append(chapter(c, i, doc.chapters[i], fiction)) }
        // Seitenzahlen und Punktlinien im Inhaltsverzeichnis
        for slot in tocSlots {
            let page = slot.0
            let pi = c.index(page)
            let left = c.left(pi)
            let num = String(starts[slot.3] + 1)
            let nw = c.f[0].width(num, size)
            let nl = simple(c, num, 0, size, 0); nl.align = 0
            page.items.append(Draw(nl, left + c.width - nw, slot.1))
            let from = left + slot.2.indent + slot.2.natural + size * 0.4, to = left + c.width - nw - size * 0.4
            if to - from > size {
                let d = dots(c, to - from, size)
                let dl = simple(c, d, 0, size, 0); dl.align = 0
                let dw = c.f[0].width(d, size)
                page.items.append(Draw(dl, to - dw, slot.1))
            }
        }
        return starts
    }

    // ------------------------------------------------ PDF schreiben
    static func esc(_ s: [UInt16]) -> String {
        var b = ""
        for ch in s {
            var v = WinAnsi.code(ch)
            if v < 0 { v = 63 }
            if v == 40 || v == 41 || v == 92 { b += "\\" + String(UnicodeScalar(UInt8(v))) }
            else if v < 32 || v > 126 { b += "\\" + String(v, radix: 8).padLeft(3, "0") }
            else { b.unicodeScalars.append(UnicodeScalar(UInt8(v))) }
        }
        return b
    }
    static func esc(_ s: String) -> String { esc(Array(s.utf16)) }
    static func utf16Hex(_ s: String) -> String { "<FEFF" + s.utf16.map { String(format: "%04X", $0) }.joined() + ">" }
    static func n(_ v: Double) -> String { PdfWriter.fmt(v, 3) }
    static func content(_ c: Ctx, _ index: Int) -> String {
        let page = c.pages[index]
        if page.blank { return "" }
        var sb = ""
        var tc = 0.0, tw = 0.0
        var first = true
        func text(_ l: Line, _ x: Double, _ y: Double) {
            sb += "BT "
            if first || abs(l.tracking - tc) > 1e-6 { sb += n(l.tracking) + " Tc "; tc = l.tracking }
            if first || abs(l.extra - tw) > 1e-6 { sb += n(l.extra) + " Tw "; tw = l.extra }
            first = false
            sb += n(x) + " " + n(y) + " Td "
            // Teile gleichen Schnitts zusammenfassen; Leerzeichen gehoert zum vorigen Teil (Tw wirkt auf Code 32).
            var runs = [Piece]()
            for w in 0..<l.words.count {
                let word = l.words[w]
                for p in 0..<word.parts.count {
                    let part = word.parts[p]
                    var t = part.text
                    if p == word.parts.count - 1 && w < l.words.count - 1 && !word.join { t.append(32) }
                    if let last = runs.last, last.style == part.style { last.text.append(contentsOf: t) } else { runs.append(Piece(t, part.style)) }
                }
            }
            var font = -1
            for r in runs {
                if r.style != font { sb += "/F\(r.style + 1) " + n(l.size) + " Tf "; font = r.style }
                sb += "(" + esc(r.text) + ") Tj "
            }
            sb += "ET\n"
            if let m = l.marker {
                let mw = c.f[0].width(m, l.size)
                sb += "BT 0 Tw /F1 " + n(l.size) + " Tf " + n(x - l.size * 0.55 - mw) + " " + n(y) + " Td (" + esc(m) + ") Tj ET\n"
                tw = 0
            }
        }
        sb += "0 g\n"
        for d in page.items { text(d.l, d.x, d.y) }
        let size = c.fmt.body
        let left = c.left(index)
        // Kolumnentitel (nicht auf Kapitelanfangsseiten) und Seitenzahl
        if page.chapterIndex >= 0 && !page.opening {
            let head = index % 2 == 1 ? c.doc.title : (!page.head.isEmpty ? page.head : c.doc.title)
            let hs = size * 0.74
            var ht = WinAnsi.upper(WinAnsi.normalize(head))
            if ht.len > 70 { ht = ht.sub(0, 68) + "\u{2026}" }
            let hl = simple(c, ht, 0, hs, hs * 0.12)
            let hx = left + (c.width - hl.natural) / 2
            sb += "0.3 g\n"; text(hl, hx, c.fmt.h - c.fmt.top * 0.55)
        }
        if page.folio {
            let fl = simple(c, String(index + 1), 0, size * 0.86, 0)
            sb += "0.2 g\n"; text(fl, left + (c.width - fl.natural) / 2, c.fmt.bottom * 0.5)
        }
        return sb
    }
    static func stream(_ dict: String, _ raw: Data) -> Data {
        let z = (try? Zlib.deflate(raw, .zlib, level: 9)) ?? Data([0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01])
        var all = TextCodec.encodeLatin1("<< /Length \(z.count) /Filter /FlateDecode" + (dict.isEmpty ? "" : " " + dict) + " >>\nstream\n")
        all.append(z); all.append(TextCodec.encodeLatin1("\nendstream"))
        return all
    }
    static func assemble(_ c: Ctx, _ starts: [Int]) -> Data {
        var objs = [Data]()
        func add(_ s: String) -> Int { objs.append(TextCodec.encodeLatin1(s)); return objs.count }
        func addRaw(_ b: Data) -> Int { objs.append(b); return objs.count }
        let catalog = add(""), pagesObj = add("")
        var fontIds = [Int](repeating: 0, count: 4)
        var done = [ObjectIdentifier: Int]()
        for s in 0..<4 {
            let face = c.f[s]
            guard let t = face.ttf else { fontIds[s] = add("<< /Type /Font /Subtype /Type1 /BaseFont /" + face.baseName + " /Encoding /WinAnsiEncoding >>"); continue }
            let key = ObjectIdentifier(t)
            var file = 0
            if let f = done[key] { file = f } else { file = addRaw(stream("/Length1 \(t.data.count)", Data(t.data))); done[key] = file }
            let k = 1000.0 / Double(t.unitsPerEm)
            let flags = 32 | 2 | (face.italic ? 64 : 0) | (t.fixedPitch ? 1 : 0)
            let desc = add("<< /Type /FontDescriptor /FontName /" + face.baseName + " /Flags \(flags) /FontBBox [" + n(Double(t.xMin) * k) + " " + n(Double(t.yMin) * k) + " " + n(Double(t.xMax) * k) + " " + n(Double(t.yMax) * k) + "] /ItalicAngle " + n(face.italic && t.italicAngle == 0 ? -10 : t.italicAngle) + " /Ascent " + n(Double(t.ascent) * k) + " /Descent " + n(Double(t.descent) * k) + " /CapHeight " + n(Double(t.capHeight) * k) + " /StemV \(face.bold ? 120 : 80) /FontFile2 \(file) 0 R >>")
            let w = (32..<256).map { String(face.widths[$0]) }.joined(separator: " ")
            fontIds[s] = add("<< /Type /Font /Subtype /TrueType /BaseFont /" + face.baseName + " /FirstChar 32 /LastChar 255 /Widths [" + w + "] /Encoding /WinAnsiEncoding /FontDescriptor \(desc) 0 R >>")
        }
        let fonts = "/F1 \(fontIds[0]) 0 R /F2 \(fontIds[1]) 0 R /F3 \(fontIds[2]) 0 R /F4 \(fontIds[3]) 0 R"
        var kids = [Int]()
        let box = "[0 0 " + n(c.fmt.w) + " " + n(c.fmt.h) + "]"
        for i in 0..<c.pages.count {
            let cont = addRaw(stream("", TextCodec.encodeLatin1(content(c, i))))
            kids.append(add("<< /Type /Page /Parent \(pagesObj) 0 R /MediaBox " + box + " /TrimBox " + box + " /Resources << /Font << " + fonts + " >> >> /Contents \(cont) 0 R >>"))
        }
        // Lesezeichen je Kapitel
        var outlines = 0
        if !starts.isEmpty {
            outlines = add("")
            let firstItem = objs.count + 1
            for i in 0..<starts.count {
                let me = firstItem + i
                let t = (c.doc.numberChapters ? c.doc.chapterLabel + " \(i + 1): " : "") + c.doc.chapters[i].title
                _ = add("<< /Title " + utf16Hex(t) + " /Parent \(outlines) 0 R" + (i > 0 ? " /Prev \(me - 1) 0 R" : "") + (i < starts.count - 1 ? " /Next \(me + 1) 0 R" : "") + " /Dest [\(kids[starts[i]]) 0 R /XYZ 0 " + n(c.fmt.h) + " 0] >>")
            }
            objs[outlines - 1] = TextCodec.encodeLatin1("<< /Type /Outlines /First \(firstItem) 0 R /Last \(firstItem + starts.count - 1) 0 R /Count \(starts.count) >>")
        }
        objs[catalog - 1] = TextCodec.encodeLatin1("<< /Type /Catalog /Pages \(pagesObj) 0 R" + (outlines > 0 ? " /Outlines \(outlines) 0 R /PageMode /UseOutlines" : "") + " /ViewerPreferences << /DisplayDocTitle true >> /Lang (de-DE) >>")
        objs[pagesObj - 1] = TextCodec.encodeLatin1("<< /Type /Pages /Kids [" + kids.map { "\($0) 0 R" }.joined(separator: " ") + "] /Count \(kids.count) >>")
        let info = add("<< /Title " + utf16Hex(c.doc.title) + (c.doc.author.trimmed.isEmpty ? "" : " /Author " + utf16Hex(c.doc.author)) + " /Creator (VYRA Buch-Studio) /Producer (VYRA KI 4.15) /CreationDate (D:" + DE.stamp(Date(), "yyyyMMddHHmmss") + ") >>")
        var ms = Data()
        ms.append(TextCodec.encodeLatin1("%PDF-1.6\n%\u{e2}\u{e3}\u{cf}\u{d3}\n"))
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
