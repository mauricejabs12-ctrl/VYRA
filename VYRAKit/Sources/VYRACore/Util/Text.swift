import Foundation

// Hilfen fuer Zeichenketten mit derselben Zaehlweise wie in C# (UTF-16-Codeeinheiten), damit die
// portierten Algorithmen (Kuerzen, Ausschnitte, Budgets) dieselben Ergebnisse liefern wie unter Windows.
public extension String {
    /// Laenge in UTF-16-Codeeinheiten (wie `string.Length` in C#).
    @inline(__always) var len: Int { utf16.count }

    /// Teilstring ab `from` mit `count` UTF-16-Einheiten (wie `Substring(from,count)`), Grenzen werden abgefangen.
    func sub(_ from: Int, _ count: Int) -> String {
        let n = len
        let s = Swift.max(0, Swift.min(from, n))
        let e = Swift.max(s, Swift.min(s + Swift.max(0, count), n))
        if s == 0 && e == n { return self }
        return NSString(string: self).substring(with: NSRange(location: s, length: e - s))
    }
    /// Teilstring ab `from` bis zum Ende (wie `Substring(from)`).
    func sub(_ from: Int) -> String { sub(from, Swift.max(0, len - from)) }

    /// Zeichen an UTF-16-Position (wie `s[i]` in C#).
    func at(_ i: Int) -> Character {
        let ns = NSString(string: self)
        guard i >= 0 && i < ns.length else { return "\0" }
        return Character(Unicode.Scalar(ns.character(at: i)) ?? " ")
    }
    func code(_ i: Int) -> UInt16 {
        let ns = NSString(string: self)
        guard i >= 0 && i < ns.length else { return 0 }
        return ns.character(at: i)
    }

    /// Erste Fundstelle (ordinal) ab `from`, -1 wenn nicht gefunden.
    func indexOf(_ needle: String, from: Int = 0, ignoreCase: Bool = false) -> Int {
        if needle.isEmpty { return Swift.min(Swift.max(0, from), len) }
        let ns = NSString(string: self)
        let start = Swift.max(0, Swift.min(from, ns.length))
        let r = ns.range(of: needle, options: ignoreCase ? [.literal, .caseInsensitive] : [.literal], range: NSRange(location: start, length: ns.length - start))
        return r.location == NSNotFound ? -1 : r.location
    }
    /// Letzte Fundstelle (ordinal), die bei oder vor `before` beginnt (wie `LastIndexOf(s, startIndex)`).
    func lastIndexOf(_ needle: String, before: Int? = nil, ignoreCase: Bool = false) -> Int {
        let ns = NSString(string: self)
        if needle.isEmpty { return ns.length }
        let limit = Swift.min(ns.length, (before ?? ns.length) + needle.len)
        if limit <= 0 { return -1 }
        let opts: NSString.CompareOptions = ignoreCase ? [.literal, .backwards, .caseInsensitive] : [.literal, .backwards]
        let r = ns.range(of: needle, options: opts, range: NSRange(location: 0, length: limit))
        return r.location == NSNotFound ? -1 : r.location
    }
    /// `LastIndexOf(value, startIndex, count)` aus C#: sucht rueckwaerts im Bereich [startIndex-count+1, startIndex].
    func lastIndexOf(_ needle: String, start: Int, count: Int) -> Int {
        let ns = NSString(string: self)
        if ns.length == 0 { return -1 }
        let st = Swift.min(start, ns.length - 1)
        let lo = Swift.max(0, st - count + 1)
        let hi = Swift.min(ns.length, st + 1)
        if hi - lo < needle.len { return -1 }
        let r = ns.range(of: needle, options: [.literal, .backwards], range: NSRange(location: lo, length: hi - lo))
        return r.location == NSNotFound ? -1 : r.location
    }
    func containsOrdinal(_ s: String) -> Bool { indexOf(s) >= 0 }
    func containsIgnoreCase(_ s: String) -> Bool { indexOf(s, ignoreCase: true) >= 0 }
    func startsWithIgnoreCase(_ s: String) -> Bool { lowercased().hasPrefix(s.lowercased()) }
    func endsWithIgnoreCase(_ s: String) -> Bool { lowercased().hasSuffix(s.lowercased()) }
    func equalsIgnoreCase(_ s: String) -> Bool { caseInsensitiveCompare(s) == .orderedSame }

    /// Wie `Trim()` in C#: Leerraum an beiden Enden entfernen.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    func trimStart() -> String { String(drop(while: { $0.isWhitespace })) }
    func trimEnd() -> String {
        var s = self
        while let l = s.last, l.isWhitespace { s.removeLast() }
        return s
    }
    func trim(_ chars: String) -> String { trimStart(chars).trimEnd(chars) }
    func trimStart(_ chars: String) -> String {
        let set = Set(chars.unicodeScalars)
        var sc = Substring(self).unicodeScalars
        while let f = sc.first, set.contains(f) { sc.removeFirst() }
        return String(sc)
    }
    func trimEnd(_ chars: String) -> String {
        let set = Set(chars.unicodeScalars)
        var sc = Substring(self).unicodeScalars
        while let l = sc.last, set.contains(l) { sc.removeLast() }
        return String(sc)
    }
    /// Ersetzen (ordinal), wie `Replace(a,b)` in C#.
    func rep(_ a: String, _ b: String) -> String { a.isEmpty ? self : replacingOccurrences(of: a, with: b) }

    /// Zerlegen an einem Zeichen; leere Teile bleiben erhalten (wie `Split('x')`).
    func splitKeep(_ sep: Character) -> [String] { split(separator: sep, omittingEmptySubsequences: false).map(String.init) }
    func splitKeep(_ sep: String) -> [String] { components(separatedBy: sep) }
    /// Zerlegen an mehreren Zeichen, leere Teile entfernt (wie `Split(chars, RemoveEmptyEntries)`).
    func splitAny(_ seps: String) -> [String] {
        let set = Set(seps)
        return split(whereSeparator: { set.contains($0) }).map(String.init)
    }

    /// `PadLeft`
    func padLeft(_ total: Int, _ c: Character = " ") -> String { len >= total ? self : String(repeating: String(c), count: total - len) + self }

    /// Erstes Zeichen gross (deutsch).
    var capitalizedFirst: String { guard let f = first else { return self }; return String(f).uppercased(with: Locale(identifier: "de_DE")) + dropFirst() }
    /// Text auf `max` Zeichen kuerzen (mit "…").
    func clip(_ max: Int, ellipsis: String = "…") -> String { len > max ? sub(0, max) + ellipsis : self }
}

public extension Character {
    var isLetterOrDigit: Bool { isLetter || isNumber }
}

/// Zeichenkodierungen, die VYRA beim Lesen und Schreiben braucht.
public enum TextCodec {
    /// Windows-1252 (alte deutsche Textdateien) -> Unicode.
    static let cp1252High: [UInt32] = [0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
                                       0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178]
    public static func decodeWindows1252(_ data: Data) -> String {
        var s = String.UnicodeScalarView()
        s.reserveCapacity(data.count)
        for b in data {
            let v: UInt32 = (b >= 0x80 && b < 0xA0) ? cp1252High[Int(b) - 0x80] : UInt32(b)
            s.append(Unicode.Scalar(v) ?? "?")
        }
        return String(s)
    }
    static let cp1252Map: [UInt32: UInt8] = {
        var m = [UInt32: UInt8]()
        for (i, v) in cp1252High.enumerated() { m[v] = UInt8(0x80 + i) }
        return m
    }()
    /// Unicode -> Windows-1252 (fuer PDF-Standardschriften); unbekannte Zeichen werden '?'.
    public static func encodeWindows1252(_ s: String) -> [UInt8] {
        var out = [UInt8]()
        for u in s.unicodeScalars {
            if u.value < 0x80 || (u.value >= 0xA0 && u.value < 0x100) { out.append(UInt8(u.value)) }
            else { out.append(cp1252Map[u.value] ?? 0x3F) }
        }
        return out
    }
    /// ISO-8859-1: 1 Byte = 1 Zeichen (fuer PDF-Rohdaten).
    public static func decodeLatin1(_ data: Data) -> String {
        var s = String.UnicodeScalarView()
        s.reserveCapacity(data.count)
        for b in data { s.append(Unicode.Scalar(b)) }
        return String(s)
    }
    public static func decodeLatin1<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        var s = String.UnicodeScalarView()
        s.reserveCapacity(bytes.count)
        for b in bytes { s.append(Unicode.Scalar(b)) }
        return String(s)
    }
    /// Unicode -> ISO-8859-1 (Zeichen ueber 255 werden '?').
    public static func encodeLatin1(_ s: String) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(s.utf16.count)
        for u in s.unicodeScalars { out.append(u.value < 256 ? UInt8(u.value) : 0x3F) }
        return Data(out)
    }
    /// Codepage 850 (DOS, fuer .bat/.cmd wie unter Windows).
    static let cp850High: [UInt32] = [0xC7, 0xFC, 0xE9, 0xE2, 0xE4, 0xE0, 0xE5, 0xE7, 0xEA, 0xEB, 0xE8, 0xEF, 0xEE, 0xEC, 0xC4, 0xC5,
                                      0xC9, 0xE6, 0xC6, 0xF4, 0xF6, 0xF2, 0xFB, 0xF9, 0xFF, 0xD6, 0xDC, 0xF8, 0xA3, 0xD8, 0xD7, 0x192,
                                      0xE1, 0xED, 0xF3, 0xFA, 0xF1, 0xD1, 0xAA, 0xBA, 0xBF, 0xAE, 0xAC, 0xBD, 0xBC, 0xA1, 0xAB, 0xBB,
                                      0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0xC1, 0xC2, 0xC0, 0xA9, 0x2563, 0x2551, 0x2557, 0x255D, 0xA2, 0xA5, 0x2510,
                                      0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0xE3, 0xC3, 0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0xA4,
                                      0xF0, 0xD0, 0xCA, 0xCB, 0xC8, 0x131, 0xCD, 0xCE, 0xCF, 0x2518, 0x250C, 0x2588, 0x2584, 0xA6, 0xCC, 0x2580,
                                      0xD3, 0xDF, 0xD4, 0xD2, 0xF5, 0xD5, 0xB5, 0xFE, 0xDE, 0xDA, 0xDB, 0xD9, 0xFD, 0xDD, 0xAF, 0xB4,
                                      0xAD, 0xB1, 0x2017, 0xBE, 0xB6, 0xA7, 0xF7, 0xB8, 0xB0, 0xA8, 0xB7, 0xB9, 0xB3, 0xB2, 0x25A0, 0xA0]
    static let cp850Map: [UInt32: UInt8] = {
        var m = [UInt32: UInt8]()
        for (i, v) in cp850High.enumerated() { m[v] = UInt8(0x80 + i) }
        return m
    }()
    public static func encodeCP850(_ s: String) -> Data {
        var out = [UInt8]()
        for u in s.unicodeScalars {
            if u.value < 0x80 { out.append(UInt8(u.value)) } else { out.append(cp850Map[u.value] ?? 0x3F) }
        }
        return Data(out)
    }
    /// UTF-16 LE mit BOM (Windows-Registrierungsdateien .reg).
    public static func encodeUTF16LEWithBOM(_ s: String) -> Data {
        var out: [UInt8] = [0xFF, 0xFE]
        for u in s.utf16 { out.append(UInt8(u & 0xFF)); out.append(UInt8(u >> 8)) }
        return Data(out)
    }
    public static func utf8(_ s: String, bom: Bool = false) -> Data {
        var d = Data(); if bom { d.append(contentsOf: [0xEF, 0xBB, 0xBF]) }
        d.append(contentsOf: Array(s.utf8)); return d
    }
    /// Text aus Bytes: UTF-8 (mit/ohne BOM), UTF-16 mit BOM, sonst Windows-1252 – wie `DocReader` unter Windows.
    public static func decodeText(_ d: Data) -> String {
        let b = [UInt8](d.prefix(4))
        if b.count >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF { return String(decoding: d.dropFirst(3), as: UTF8.self) }
        if b.count >= 2 && b[0] == 0xFF && b[1] == 0xFE { return String(data: d.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if b.count >= 2 && b[0] == 0xFE && b[1] == 0xFF { return String(data: d.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        if let s = String(data: d, encoding: .utf8) { return s }
        return decodeWindows1252(d)
    }
}

/// HTML-Entitaeten dekodieren (wie `WebUtility.HtmlDecode`).
public enum HTMLEntities {
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß",
        "euro": "€", "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "ndash": "–", "mdash": "—", "laquo": "«", "raquo": "»", "bdquo": "„", "ldquo": "“", "rdquo": "”",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "middot": "·", "bull": "•", "deg": "°", "eacute": "é", "egrave": "è", "ecirc": "ê", "euml": "ë", "Eacute": "É", "Egrave": "È",
        "aacute": "á", "agrave": "à", "acirc": "â", "atilde": "ã", "aring": "å", "aelig": "æ", "Aacute": "Á", "Agrave": "À", "Acirc": "Â", "Aring": "Å", "AElig": "Æ",
        "ccedil": "ç", "Ccedil": "Ç", "iacute": "í", "igrave": "ì", "icirc": "î", "iuml": "ï", "Iacute": "Í", "ntilde": "ñ", "Ntilde": "Ñ", "oacute": "ó", "ograve": "ò",
        "ocirc": "ô", "otilde": "õ", "oslash": "ø", "Oslash": "Ø", "Oacute": "Ó", "uacute": "ú", "ugrave": "ù", "ucirc": "û", "Uacute": "Ú", "yacute": "ý", "yuml": "ÿ",
        "times": "×", "divide": "÷", "plusmn": "±", "sup1": "¹", "sup2": "²", "sup3": "³", "frac12": "½", "frac14": "¼", "frac34": "¾", "para": "¶", "sect": "§",
        "shy": "\u{00AD}", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔", "rArr": "⇒", "lArr": "⇐", "hearts": "♥", "spades": "♠", "clubs": "♣", "diams": "♦",
        "cent": "¢", "pound": "£", "yen": "¥", "curren": "¤", "iexcl": "¡", "iquest": "¿", "ordf": "ª", "ordm": "º", "not": "¬", "macr": "¯", "acute": "´", "micro": "µ",
        "cedil": "¸", "uml": "¨", "brvbar": "¦", "thinsp": "\u{2009}", "ensp": "\u{2002}", "emsp": "\u{2003}", "zwnj": "\u{200C}", "zwj": "\u{200D}", "lrm": "\u{200E}", "rlm": "\u{200F}",
        "prime": "′", "Prime": "″", "minus": "−", "le": "≤", "ge": "≥", "ne": "≠", "asymp": "≈", "infin": "∞", "sum": "∑", "radic": "√", "alpha": "α", "beta": "β", "gamma": "γ",
        "delta": "δ", "Delta": "Δ", "pi": "π", "Pi": "Π", "sigma": "σ", "Sigma": "Σ", "omega": "ω", "Omega": "Ω", "mu": "μ", "lambda": "λ", "theta": "θ", "check": "✓",
        "dagger": "†", "Dagger": "‡", "permil": "‰", "lsaquo": "‹", "rsaquo": "›", "circ": "ˆ", "tilde": "˜", "Scaron": "Š", "scaron": "š", "OElig": "Œ", "oelig": "œ", "Yuml": "Ÿ",
        "fnof": "ƒ", "Zcaron": "Ž", "zcaron": "ž", "THORN": "Þ", "thorn": "þ", "ETH": "Ð", "eth": "ð", "Iuml": "Ï", "Euml": "Ë"
    ]
    public static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].prefix(34).firstIndex(of: ";") {
                let body = s[s.index(after: i)..<semi]
                if body.hasPrefix("#") {
                    let num = body.dropFirst()
                    var v: UInt32?
                    if num.hasPrefix("x") || num.hasPrefix("X") { v = UInt32(num.dropFirst(), radix: 16) } else { v = UInt32(num, radix: 10) }
                    if let v = v, let sc = Unicode.Scalar(v) { out.unicodeScalars.append(sc); i = s.index(after: semi); continue }
                } else if let r = named[String(body)] {
                    out += r; i = s.index(after: semi); continue
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }
    /// Wie `WebUtility.HtmlEncode` / `SecurityElement.Escape`.
    public static func encode(_ s: String) -> String {
        var b = ""
        b.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": b += "&amp;"
            case "<": b += "&lt;"
            case ">": b += "&gt;"
            case "\"": b += "&quot;"
            case "'": b += "&#39;"
            default: b.append(c)
            }
        }
        return b
    }
    /// XML-Text (fuer DOCX/XLSX/PPTX/ODT): Steuerzeichen entfernen, Sonderzeichen maskieren.
    public static func xml(_ s: String) -> String {
        var b = ""
        b.reserveCapacity(s.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": b += "&amp;"
            case "<": b += "&lt;"
            case ">": b += "&gt;"
            case "\"": b += "&quot;"
            case "'": b += "&apos;"
            default:
                if u.value < 0x20 && u != "\t" && u != "\n" && u != "\r" { continue }
                if u.value == 0xFFFE || u.value == 0xFFFF { continue }
                b.unicodeScalars.append(u)
            }
        }
        return b
    }
}

/// Deutsche Zahlen- und Datumsformate (wie `de-DE` in C#).
public enum DE {
    public static let locale = Locale(identifier: "de_DE")
    /// "N0": 1.234
    public static func n0(_ v: Double) -> String {
        let f = NumberFormatter(); f.locale = locale; f.numberStyle = .decimal; f.maximumFractionDigits = 0; f.minimumFractionDigits = 0
        f.groupingSeparator = "."; f.decimalSeparator = ","; f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: v.rounded())) ?? String(Int(v))
    }
    public static func n0(_ v: Int) -> String { n0(Double(v)) }
    /// Feste Nachkommastellen mit Komma, z. B. "0.0" -> "2,5".
    public static func fixed(_ v: Double, _ digits: Int) -> String {
        let f = NumberFormatter(); f.locale = locale; f.numberStyle = .decimal; f.maximumFractionDigits = digits; f.minimumFractionDigits = digits
        f.groupingSeparator = "."; f.decimalSeparator = ","; f.usesGroupingSeparator = false
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
    /// "#,##0.##########"
    public static func flexible(_ v: Double, maxDigits: Int = 10) -> String {
        let f = NumberFormatter(); f.locale = locale; f.numberStyle = .decimal; f.maximumFractionDigits = maxDigits; f.minimumFractionDigits = 0
        f.groupingSeparator = "."; f.decimalSeparator = ","; f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
    static let weekdays = ["Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag"]
    static let months = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"]
    /// "dddd, d. MMMM yyyy"
    public static func longDate(_ d: Date = Date()) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: d)
        return "\(weekdays[(c.weekday ?? 1) - 1]), \(c.day ?? 1). \(months[(c.month ?? 1) - 1]) \(c.year ?? 2026)"
    }
    /// "d. MMMM yyyy"
    public static func date(_ d: Date = Date()) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: d)
        return "\(c.day ?? 1). \(months[(c.month ?? 1) - 1]) \(c.year ?? 2026)"
    }
    /// "dd.MM.yyyy HH:mm"
    public static func dateTime(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = locale; f.dateFormat = "dd.MM.yyyy HH:mm"; return f.string(from: d)
    }
    public static func stamp(_ d: Date = Date(), _ format: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = format; return f.string(from: d)
    }
    public static var year: Int { Calendar(identifier: .gregorian).component(.year, from: Date()) }
}

/// ISO-8601 wie `ToString("o")` (Rundreise) und tolerantes Einlesen.
public enum ISO {
    public static func string(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
    public static func parse(_ s: String) -> Date? {
        let t = s.trimmed
        if t.isEmpty { return nil }
        let a = ISO8601DateFormatter(); a.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = a.date(from: t) { return d }
        let b = ISO8601DateFormatter(); b.formatOptions = [.withInternetDateTime]
        if let d = b.date(from: t) { return d }
        // .NET schreibt 7 Nachkommastellen ("2026-10-22T10:00:00.1234567Z"); auf 3 kuerzen.
        if let r = t.range(of: #"\.(\d{4,})"#, options: .regularExpression) {
            var u = t; let digits = t[r].dropFirst(); u.replaceSubrange(r, with: "." + digits.prefix(3))
            if let d = a.date(from: u) { return d }
            if let d = a.date(from: u + "Z") { return d }
        }
        if let d = a.date(from: t + "Z") { return d }
        if let d = b.date(from: t + "Z") { return d }
        return nil
    }
}
