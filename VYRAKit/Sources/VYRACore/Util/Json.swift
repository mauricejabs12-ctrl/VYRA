import Foundation

/// JSON-Objekt mit fester Schluesselreihenfolge (wie `Dictionary` in C#: Einfuegereihenfolge bleibt erhalten).
/// Die Reihenfolge ist wichtig: Schemata fuer die Grammatik und Prompts bleiben so identisch zu Windows.
public final class JObject {
    public private(set) var keys: [String] = []
    public private(set) var values: [String: Any] = [:]
    public init() {}
    public init(_ pairs: [(String, Any?)]) { for (k, v) in pairs { self[k] = v } }
    public subscript(key: String) -> Any? {
        get { values[key] }
        set {
            if let v = newValue {
                if values[key] == nil { keys.append(key) }
                values[key] = v
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }
    public var count: Int { keys.count }
    public var entries: [(String, Any)] { keys.map { ($0, values[$0]!) } }
}

/// Platzhalter fuer `null` in Listen und Objekten.
public struct JNull: Equatable { public init() {} }

/// Kleiner JSON-Leser/-Schreiber, verhaltensgleich zur `Json`-Klasse aus VYRA.GXCore.cs
/// (Zahlen sind `Double`, Ausgabe ist reines ASCII mit \u-Escapes).
public enum Json {
    public struct FormatError: Error, CustomStringConvertible { public let description: String }

    /// Baut ein Objekt aus Schluessel-Wert-Paaren (wie `Obj(...)` in C#).
    public static func obj(_ pairs: (String, Any)...) -> JObject {
        let o = JObject(); for (k, v) in pairs { o[k] = v }; return o
    }

    public static func parse(_ text: String) throws -> Any {
        let u = Array(text.utf16)
        var i = 0
        let v = try value(u, &i, 0)
        skip(u, &i)
        if i != u.count { throw FormatError(description: "Unerwartete Zeichen nach JSON-Wert bei Position \(i).") }
        return v
    }
    static func skip(_ s: [UInt16], _ i: inout Int) {
        while i < s.count, s[i] == 32 || s[i] == 9 || s[i] == 13 || s[i] == 10 || s[i] == 0xFEFF { i += 1 }
    }
    static func lit(_ s: [UInt16], _ i: Int, _ w: String) -> Bool {
        let u = Array(w.utf16)
        if i + u.count > s.count { return false }
        for k in 0..<u.count where s[i + k] != u[k] { return false }
        return true
    }
    static func value(_ s: [UInt16], _ i: inout Int, _ depth: Int) throws -> Any {
        if depth > 256 { throw FormatError(description: "JSON ist zu tief verschachtelt.") }
        skip(s, &i)
        if i >= s.count { throw FormatError(description: "JSON endet unerwartet.") }
        let c = s[i]
        if c == 123 { // {
            let d = JObject(); i += 1; skip(s, &i)
            if i < s.count, s[i] == 125 { i += 1; return d }
            while true {
                skip(s, &i)
                if i >= s.count || s[i] != 34 { throw FormatError(description: "JSON-Schluessel erwartet bei Position \(i).") }
                let k = try str(s, &i)
                skip(s, &i)
                if i >= s.count || s[i] != 58 { throw FormatError(description: "':' erwartet bei Position \(i).") }
                i += 1
                d[k] = try value(s, &i, depth + 1)
                skip(s, &i)
                if i < s.count, s[i] == 44 { i += 1; continue }
                if i < s.count, s[i] == 125 { i += 1; return d }
                throw FormatError(description: "',' oder '}' erwartet bei Position \(i).")
            }
        }
        if c == 91 { // [
            var l = [Any](); i += 1; skip(s, &i)
            if i < s.count, s[i] == 93 { i += 1; return l }
            while true {
                l.append(try value(s, &i, depth + 1)); skip(s, &i)
                if i < s.count, s[i] == 44 { i += 1; continue }
                if i < s.count, s[i] == 93 { i += 1; return l }
                throw FormatError(description: "',' oder ']' erwartet bei Position \(i).")
            }
        }
        if c == 34 { return try str(s, &i) }
        if lit(s, i, "true") { i += 4; return true }
        if lit(s, i, "false") { i += 5; return false }
        if lit(s, i, "null") { i += 4; return JNull() }
        let st = i
        while i < s.count, let ch = Unicode.Scalar(s[i]), "+-0123456789.eE".unicodeScalars.contains(ch) { i += 1 }
        if st == i { throw FormatError(description: "Ungueltiger JSON-Wert bei Position \(i).") }
        let numText = String(decoding: s[st..<i], as: UTF16.self)
        guard let n = Double(numText) else { throw FormatError(description: "Ungueltige Zahl bei Position \(st).") }
        return n
    }
    static func str(_ s: [UInt16], _ i: inout Int) throws -> String {
        i += 1
        var b = [UInt16]()
        while i < s.count {
            let c = s[i]; i += 1
            if c == 34 { return String(decoding: b, as: UTF16.self) }
            if c != 92 { b.append(c); continue }
            if i >= s.count { break }
            let e = s[i]; i += 1
            switch e {
            case 110: b.append(10)
            case 114: b.append(13)
            case 116: b.append(9)
            case 98: b.append(8)
            case 102: b.append(12)
            case 117:
                if i + 4 > s.count { throw FormatError(description: "Unvollstaendiges \\u-Zeichen.") }
                guard let v = UInt16(String(decoding: s[i..<(i + 4)], as: UTF16.self), radix: 16) else { throw FormatError(description: "Ungueltiges \\u-Zeichen.") }
                b.append(v); i += 4
            default: b.append(e)
            }
        }
        throw FormatError(description: "Nicht abgeschlossener JSON-Text.")
    }

    // ---------------------------------------------------------------- Schreiben
    public static func serialize(_ v: Any?) -> String { var b = ""; write(&b, v); return b }
    static func write(_ b: inout String, _ v: Any?) {
        guard let v = v else { b += "null"; return }
        switch v {
        case is JNull: b += "null"
        case let s as String: quote(&b, s)
        case let x as Bool: b += x ? "true" : "false"
        case let x as Int: b += number(Double(x))
        case let x as Int64: b += number(Double(x))
        case let x as Int32: b += number(Double(x))
        case let x as UInt: b += number(Double(x))
        case let x as Double: b += number(x)
        case let x as Float: b += number(Double(x))
        case let o as JObject:
            b += "{"; var first = true
            for (k, val) in o.entries { if !first { b += "," }; first = false; quote(&b, k); b += ":"; write(&b, val) }
            b += "}"
        case let d as [String: Any]:
            b += "{"; var first = true
            for k in d.keys.sorted() { if !first { b += "," }; first = false; quote(&b, k); b += ":"; write(&b, d[k]) }
            b += "}"
        case let l as [Any]:
            b += "["; var first = true
            for o in l { if !first { b += "," }; first = false; write(&b, o) }
            b += "]"
        default: quote(&b, "\(v)")
        }
    }
    /// Wie `ToString("R")`: ganze Zahlen ohne Nachkommastellen.
    public static func number(_ x: Double) -> String {
        if x.isNaN || x.isInfinite { return "0" }
        if x == x.rounded(), abs(x) < 1e15 { return String(Int64(x)) }
        return "\(x)"
    }
    static func quote(_ b: inout String, _ s: String) {
        b += "\""
        for c in s.utf16 {
            switch c {
            case 34: b += "\\\""
            case 92: b += "\\\\"
            case 10: b += "\\n"
            case 13: b += "\\r"
            case 9: b += "\\t"
            default:
                if c < 0x20 || c > 0x7E { b += "\\u" + String(format: "%04x", c) } else { b.unicodeScalars.append(Unicode.Scalar(c)!) }
            }
        }
        b += "\""
    }

    // ---------------------------------------------------------------- Bequeme Zugriffe (wie Json.Str/Num/Arr/Get)
    public static func get(_ o: Any?, _ key: String) -> Any? {
        guard let d = o as? JObject, let v = d[key], !(v is JNull) else { return nil }
        return v
    }
    public static func str(_ o: Any?, _ key: String) -> String {
        guard let v = get(o, key) else { return "" }
        return text(v)
    }
    /// Wie `Convert.ToString(v, InvariantCulture)`.
    public static func text(_ v: Any?) -> String {
        guard let v = v else { return "" }
        switch v {
        case let s as String: return s
        case let x as Double: return number(x)
        case let x as Bool: return x ? "True" : "False"
        case is JNull: return ""
        case let x as Int: return String(x)
        default: return "\(v)"
        }
    }
    public static func num(_ o: Any?, _ key: String, _ fallback: Double) -> Double {
        let v = get(o, key)
        if let x = v as? Double { return x }
        if let x = v as? Int { return Double(x) }
        return fallback
    }
    public static func arr(_ o: Any?, _ key: String) -> [Any] {
        guard let v = get(o, key) else { return [] }
        return (v as? [Any]) ?? []
    }
    public static func bool(_ o: Any?, _ key: String) -> Bool? { get(o, key) as? Bool }
    public static func readFile(_ path: String, maxBytes: Int) throws -> Any {
        let url = URL(fileURLWithPath: path)
        let size = FS.size(path)
        if size > maxBytes { throw VyraError("Datei ist zu groß: \(url.lastPathComponent)") }
        let data = try Data(contentsOf: url)
        return try parse(String(decoding: data, as: UTF8.self))
    }
}

/// Allgemeiner Fehler mit verstaendlicher deutscher Meldung (wie die Ausnahmetexte unter Windows).
public struct VyraError: Error, LocalizedError, CustomStringConvertible {
    public let message: String
    public let kind: Kind
    public enum Kind { case general, invalidData, notSupported, io, cancelled, invalidOperation, argument, timeout }
    public init(_ message: String, _ kind: Kind = .general) { self.message = message; self.kind = kind }
    public var errorDescription: String? { message }
    public var description: String { message }
    public static let cancelled = VyraError("Abgebrochen.", .cancelled)
}

public extension Error {
    /// Verstaendliche Meldung (ohne Typnamen).
    var vyraMessage: String {
        if let v = self as? VyraError { return v.message }
        if let j = self as? Json.FormatError { return j.description }
        if self is CancellationError { return "Abgebrochen." }
        let ns = self as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet: return "Keine Internetverbindung."
            case NSURLErrorTimedOut: return "Zeitüberschreitung."
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "Server nicht gefunden."
            case NSURLErrorCancelled: return "Abgebrochen."
            default: break
            }
        }
        return (self as? LocalizedError)?.errorDescription ?? ns.localizedDescription
    }
    var isCancellation: Bool {
        if self is CancellationError { return true }
        if let v = self as? VyraError, v.kind == .cancelled { return true }
        let ns = self as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }
}
