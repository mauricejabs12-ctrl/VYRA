import Foundation

// ---------------------------------------------------------------- Relevante Textstellen auswaehlen (statt nur den Seitenanfang)
public final class Passage {
    public var source = 0, order = 0
    public var text = ""
    public var score = 0.0
    public init() {}
}

public extension Array {
    /// Stabile Sortierung (wie LINQ OrderBy/OrderByDescending: gleiche Werte behalten ihre Reihenfolge).
    func stableSorted(by less: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map { $0.element }
    }
}

public enum Passages {
    /// Teilt Text an Absatzgrenzen in Stuecke von etwa "size" Zeichen; Ueberschriften bleiben beim folgenden Text.
    public static func split(_ text: String, _ size: Int) -> [String] {
        var outp = [String]()
        if text.trimmed.isEmpty { return outp }
        var cur = ""
        for raw in text.rep("\r", "").splitKeep("\n") {
            let l = raw.trimEnd()
            if l.trimmed.isEmpty {
                if Double(cur.len) >= Double(size) * 0.6 { outp.append(cur.trimmed); cur = "" } else if !cur.isEmpty { cur += "\n" }
                continue
            }
            let heading = l.hasPrefix("#")
            if heading && Double(cur.len) >= Double(size) * 0.35 { outp.append(cur.trimmed); cur = "" }
            if Double(l.len) > Double(size) * 1.6 { // sehr lange Zeile an Satzgrenzen teilen
                for sent in Rx.split(l, "(?<=[.!?])\\s+") {
                    if cur.len + sent.len > size && !cur.isEmpty { outp.append(cur.trimmed); cur = "" }
                    cur += sent + " "
                }
                continue
            }
            if cur.len + l.len > size && !cur.isEmpty { outp.append(cur.trimmed); cur = "" }
            cur += l + "\n"
        }
        if !cur.trimmed.isEmpty { outp.append(cur.trimmed) }
        return outp.filter { $0.len >= 40 }
    }
    /// BM25 ueber alle Stuecke; liefert die besten Stuecke je Quelle in Originalreihenfolge.
    public static func score(_ all: [Passage], _ query: String) {
        var seenQ = Set<String>()
        let q = Knowledge.tokens(query, expand: true).filter { seenQ.insert($0).inserted }
        let docs = all.map { Knowledge.tokens($0.text, expand: false) }
        let N = Double(max(1, all.count))
        let avg = max(1.0, docs.isEmpty ? 1.0 : Double(docs.reduce(0) { $0 + $1.count }) / Double(docs.count))
        var df = [String: Int]()
        for d in docs { for t in Set(d) { df[t, default: 0] += 1 } }
        for i in 0..<all.count {
            var tf = [String: Int]()
            for t in docs[i] { tf[t, default: 0] += 1 }
            var s = 0.0
            for t in q {
                guard let f = tf[t] else { continue }
                let n = Double(df[t] ?? 0)
                let idf = log(1 + (N - n + 0.5) / (n + 0.5))
                s += idf * (Double(f) * 2.2) / (Double(f) + 1.2 * (0.25 + 0.75 * Double(docs[i].count) / avg))
            }
            if all[i].order == 0 { s += 0.35 } // Einleitung ist oft eine gute Zusammenfassung
            if Rx.isMatch(all[i].text, "\\d") { s += 0.1 }
            all[i].score = s
        }
    }
    public static func select(_ text: String, _ query: String, _ budget: Int) -> String {
        if text.len <= budget { return text }
        let parts = split(text, max(250, min(700, budget / 3)))
        var all = [Passage]()
        for (i, t) in parts.enumerated() { let p = Passage(); p.order = i; p.text = t; all.append(p) }
        score(all, query)
        var pick = [Passage]()
        var used = 0
        for p in all.stableSorted(by: { $0.score > $1.score }) {
            if used + p.text.len > budget { if Double(used) > Double(budget) * 0.7 { break }; continue }
            pick.append(p); used += p.text.len + 5
        }
        return pick.sorted { $0.order < $1.order }.map { $0.text }.joined(separator: "\n…\n")
    }
}
