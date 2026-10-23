import Foundation

/// Regulaere Ausdruecke mit derselben Bedeutung wie `System.Text.RegularExpressions` in VYRA (ICU kennt dieselbe
/// Syntax: Lookbehind, benannte Gruppen, \p{L}). Positionen sind UTF-16-Indizes wie in C#.
public struct RxOptions: OptionSet {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let i = RxOptions(rawValue: 1)          // IgnoreCase
    public static let s = RxOptions(rawValue: 2)          // Singleline (. passt auf \n)
    public static let m = RxOptions(rawValue: 4)          // Multiline (^ $ je Zeile)
    var ns: NSRegularExpression.Options {
        var o: NSRegularExpression.Options = []
        if contains(.i) { o.insert(.caseInsensitive) }
        if contains(.s) { o.insert(.dotMatchesLineSeparators) }
        if contains(.m) { o.insert(.anchorsMatchLines) }
        return o
    }
}

public struct RxMatch {
    let text: NSString
    let result: NSTextCheckingResult
    public var index: Int { result.range.location }
    public var length: Int { result.range.length }
    public var end: Int { result.range.location + result.range.length }
    public var value: String { text.substring(with: result.range) }
    public func group(_ i: Int) -> String {
        guard i < result.numberOfRanges else { return "" }
        let r = result.range(at: i)
        return r.location == NSNotFound ? "" : text.substring(with: r)
    }
    public func success(_ i: Int) -> Bool { i < result.numberOfRanges && result.range(at: i).location != NSNotFound }
    public func groupIndex(_ i: Int) -> Int { i < result.numberOfRanges ? result.range(at: i).location : NSNotFound }
    public func group(_ name: String) -> String {
        let r = result.range(withName: name)
        return r.location == NSNotFound ? "" : text.substring(with: r)
    }
    public func success(_ name: String) -> Bool { result.range(withName: name).location != NSNotFound }
    public var groupCount: Int { result.numberOfRanges }
}

public enum Rx {
    private static let lock = NSLock()
    private static var cache = [String: NSRegularExpression]()

    public static func re(_ pattern: String, _ o: RxOptions = []) -> NSRegularExpression {
        let key = "\(o.rawValue)|" + pattern
        lock.lock(); defer { lock.unlock() }
        if let r = cache[key] { return r }
        do {
            let r = try NSRegularExpression(pattern: pattern, options: o.ns)
            if cache.count > 2000 { cache.removeAll() }
            cache[key] = r
            return r
        } catch {
            // Ein fehlerhaftes Muster ist ein Programmierfehler; in Tests sofort sichtbar machen.
            assertionFailure("Ungueltiger regulaerer Ausdruck: \(pattern) – \(error)")
            return try! NSRegularExpression(pattern: "(?!)", options: [])
        }
    }
    public static func isMatch(_ s: String, _ pattern: String, _ o: RxOptions = []) -> Bool {
        let ns = NSString(string: s)
        return re(pattern, o).firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) != nil
    }
    public static func match(_ s: String, _ pattern: String, _ o: RxOptions = [], from: Int = 0) -> RxMatch? {
        let ns = NSString(string: s)
        let start = max(0, min(from, ns.length))
        guard let r = re(pattern, o).firstMatch(in: s, options: [], range: NSRange(location: start, length: ns.length - start)) else { return nil }
        return RxMatch(text: ns, result: r)
    }
    public static func matches(_ s: String, _ pattern: String, _ o: RxOptions = []) -> [RxMatch] {
        let ns = NSString(string: s)
        return re(pattern, o).matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)).map { RxMatch(text: ns, result: $0) }
    }
    public static func count(_ s: String, _ pattern: String, _ o: RxOptions = []) -> Int {
        let ns = NSString(string: s)
        return re(pattern, o).numberOfMatches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
    }
    /// Ersetzen mit Vorlage ($1, $2) wie in .NET.
    public static func replace(_ s: String, _ pattern: String, _ template: String, _ o: RxOptions = []) -> String {
        let ns = NSString(string: s)
        // .NET: "$$" = Dollar; ICU: "\$". Backslashes in der Vorlage sind in .NET normale Zeichen.
        let tpl = template.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "$$", with: "\\$")
        return re(pattern, o).stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: tpl)
    }
    /// Ersetzen mit Funktion (MatchEvaluator).
    public static func replace(_ s: String, _ pattern: String, _ o: RxOptions = [], _ eval: (RxMatch) -> String) -> String {
        let ns = NSString(string: s)
        let ms = re(pattern, o).matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
        if ms.isEmpty { return s }
        var out = ""
        var pos = 0
        for r in ms {
            if r.range.location > pos { out += ns.substring(with: NSRange(location: pos, length: r.range.location - pos)) }
            out += eval(RxMatch(text: ns, result: r))
            pos = r.range.location + r.range.length
        }
        if pos < ns.length { out += ns.substring(from: pos) }
        return out
    }
    /// Zerlegen wie `Regex.Split` in .NET: Teile zwischen den Treffern, dazu die Werte erfasster Gruppen.
    public static func split(_ s: String, _ pattern: String, _ o: RxOptions = []) -> [String] {
        let ns = NSString(string: s)
        let ms = re(pattern, o).matches(in: s, options: [], range: NSRange(location: 0, length: ns.length))
        if ms.isEmpty { return [s] }
        var out = [String]()
        var pos = 0
        for r in ms {
            out.append(ns.substring(with: NSRange(location: pos, length: r.range.location - pos)))
            if r.numberOfRanges > 1 {
                for g in 1..<r.numberOfRanges {
                    let gr = r.range(at: g)
                    if gr.location != NSNotFound { out.append(ns.substring(with: gr)) }
                }
            }
            pos = r.range.location + r.range.length
        }
        out.append(ns.substring(from: pos))
        return out
    }
    public static func escape(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }
}
