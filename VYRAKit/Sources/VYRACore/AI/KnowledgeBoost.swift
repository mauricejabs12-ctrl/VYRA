import Foundation

public final class WikiFact {
    public var title = "", url = "", text = "", lang = "de"
    public var cached = false
    public init() {}
}

/// 4.14 Wissens-Booster: Bei Wissensfragen holt VYRA kurze, gepruefte Lexikon-Auszuege (Wikipedia) und merkt sie sich lokal.
/// Kleine lokale Modelle wissen dadurch deutlich mehr und erfinden seltener Fakten. (unveraendert portiert)
public enum KnowledgeBoost {
    static let lock = NSLock()
    static var file: String?
    static var cache: JObject?
    public static var apiBase = "https://{0}.wikipedia.org/w/api.php"
    public static var cachedEntries: Int { lock.lock(); defer { lock.unlock() }; load(); return cache!.count }
    public static func configure(_ dataRoot: String?) { lock.lock(); file = dataRoot.map { FS.join($0, "KI", "Wissen-Cache.json") }; cache = nil; lock.unlock() }
    static let rxWant = "^(?:bitte\\s+|sag\\s+mir\\s+|kannst\\s+du\\s+(?:mir\\s+)?)?(?:was\\s+(?:ist|sind|war|waren|bedeutet|bedeuten|heisst|versteht\\s+man\\s+unter|macht\\s+(?:ein|eine|der|die|das))|wer\\s+(?:ist|war|sind|waren|erfand|entdeckte|gruendete|schrieb|malte|komponierte|baute|regierte)|wie\\s+(?:funktioniert|funktionieren|entsteht|entstehen|entstand|wirkt|hoch|gross|alt|lang|tief|weit|schwer)|warum|wieso|weshalb|wo\\s+(?:liegt|liegen|befindet)|wann\\s+(?:war|wurde|begann|endete|lebte|starb|fand)|erklaer\\w*|erzaehl\\w*\\s+(?:mir\\s+)?(?:etwas\\s+|was\\s+)?(?:ueber|von)|definier\\w*|beschreib\\w*|infos?\\s+(?:zu|ueber)|was\\s+weisst\\s+du\\s+ueber)\\b"
    public static func wants(_ q: String) -> Bool {
        let n = Rx.replace(Knowledge.norm(q), " +", " ").trimmed
        if n.len < 8 || n.len > 220 { return false }
        if Rx.isMatch(n, "\\b(?:mein|meine|meinen|meinem|meiner|ich|mich|vyra|code|programm\\w*|skript|script|fehler|rechne|berechne)\\b") { return false }
        return Rx.isMatch(n, rxWant)
    }
    public static func topic(_ q: String) -> String {
        var t = q.trimmed.trimEnd("?!. ")
        t = Rx.replace(t, "^(?:bitte\\s+|sag\\s+mir\\s+|kannst\\s+du\\s+(?:mir\\s+)?)?(?:was\\s+(?:ist|sind|war|waren|bedeutet|bedeuten|hei(?:ss|ß)t)|was\\s+versteht\\s+man\\s+unter|wer\\s+(?:ist|war|sind|waren)|erkl(?:ä|ae)r\\w*(?:\\s+mir)?(?:\\s+(?:was|wie|wer))?|erz(?:ä|ae)hl\\w*\\s+(?:mir\\s+)?(?:etwas\\s+|was\\s+)?(?:(?:ü|ue)ber|von)|definier\\w*|beschreib\\w*|infos?\\s+(?:zu|(?:ü|ue)ber)|was\\s+wei(?:ss|ß)t\\s+du\\s+(?:ü|ue)ber)\\s+", "", .i)
        t = Rx.replace(t, "^(?:ein|eine|einen|der|die|das|den|dem)\\s+", "", .i)
        return t.len > 120 ? t.sub(0, 120) : t.trimmed
    }
    static func load() {
        if cache != nil { return }
        let c = JObject()
        cache = c
        guard let f = file, FS.isFile(f), FS.size(f) < 6_000_000 else { return }
        if let o = try? Json.parse(FS.readText(f)), let e = Json.get(o, "entries") as? JObject {
            for (k, v) in e.entries { c[k] = v }
        }
    }
    static func save() {
        guard let f = file, let c = cache else { return }
        if c.count > 3000 {
            let old = c.entries.stableSorted { Json.num($0.1, "t", 0) < Json.num($1.1, "t", 0) }.prefix(c.count - 2500).map { $0.0 }
            for k in old { c[k] = nil }
        }
        try? FS.writeAtomic(f, text: Json.serialize(Json.obj(("format", "vyra-wissen-1"), ("entries", c))))
    }
    static func now() -> Double { Date().timeIntervalSince(DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 2020, month: 1, day: 1).date!) / 3600 }
    static func facts(_ e: Any?) -> [WikiFact] {
        Json.arr(e, "facts").map { f in let w = WikiFact(); w.title = Json.str(f, "title"); w.url = Json.str(f, "url"); w.text = Json.str(f, "text"); w.lang = Json.str(f, "lang"); w.cached = true; return w }
    }
    static func fromCache(_ key: String) -> [WikiFact]? {
        lock.lock(); defer { lock.unlock() }
        load()
        guard let e = cache![key] else { return nil }
        if now() - Json.num(e, "t", 0) > 24 * 45 { return nil }
        return facts(e).filter { !$0.text.isEmpty }
    }
    static func store(_ key: String, _ list: [WikiFact]) {
        lock.lock(); defer { lock.unlock() }
        load()
        cache![key] = Json.obj(("t", now()), ("facts", list.map { f -> Any in Json.obj(("title", f.title), ("url", f.url), ("text", f.text), ("lang", f.lang)) }))
        save()
    }
    public static func clear() { lock.lock(); cache = JObject(); if let f = file { FS.delete(f) }; lock.unlock() }
    /// Nur offline: gespeicherte Auszuege durchsuchen (wenn das Internet fehlt).
    public static func offline(_ q: String) -> [WikiFact] {
        let key = Knowledge.norm(topic(q)).trimmed
        if key.len < 3 { return [] }
        if let hit = fromCache(key) { return hit }
        let w = words(key)
        if w.isEmpty { return [] }
        lock.lock(); defer { lock.unlock() }
        load()
        var best: (Any, Int)?
        for (k, v) in cache!.entries {
            let score = words(k).filter { w.contains($0) }.count
            if score >= max(1, w.count - 1) && (best == nil || score > best!.1) { best = (v, score) }
        }
        guard let b = best else { return [] }
        return facts(b.0)
    }
    static let stop: Set<String> = Set("der die das ein eine einer eines und oder von vom zum zur im in am an auf mit fuer ueber unter bei aus wie was wer wo wann warum wieso weshalb ist sind war waren the a an of and for".split(separator: " ").map(String.init))
    static func words(_ norm: String) -> [String] {
        var seen = Set<String>()
        return Rx.split(norm, " +").filter { $0.len >= 3 && !stop.contains($0) && seen.insert($0).inserted }
    }
    static func relevant(_ topic: String, _ f: WikiFact) -> Bool {
        let w = words(Knowledge.norm(topic))
        if w.isEmpty { return true }
        let hay = Knowledge.norm(f.title + " " + (f.text.len > 500 ? f.text.sub(0, 500) : f.text))
        let hits = w.filter { hay.contains($0.len > 5 ? $0.sub(0, $0.len - 1) : $0) }.count
        return hits >= max(1, (w.count + 1) / 2)
    }
    public static func lookup(_ q: String, _ token: CancelToken) async throws -> [WikiFact] {
        let t = topic(q)
        if t.len < 2 { return [] }
        let key = Knowledge.norm(t).trimmed
        if let c = fromCache(key) { return c }
        let limit = CancelToken.linked(token)
        limit.cancelAfter(3)
        var list: [WikiFact]
        do {
            list = try await query("de", t, limit)
            if list.isEmpty { list = try await query("en", t, limit) }
        } catch {
            if token.isCancelled { throw VyraError.cancelled }
            let off = offline(q)
            if !off.isEmpty { return off }
            throw error
        }
        list = Array(list.filter { relevant(t, $0) }.prefix(2))
        if !list.isEmpty { store(key, list) }
        return list
    }
    static func query(_ lang: String, _ topic: String, _ token: CancelToken) async throws -> [WikiFact] {
        let url = apiBase.rep("{0}", lang) + "?action=query&format=json&formatversion=2&utf8=1&redirects=1&generator=search&gsrlimit=3&gsrsearch=" + Http.escape(topic) + "&prop=extracts%7Cinfo&inprop=url&exintro=1&explaintext=1&exsentences=8"
        let json = try await WebResearch.getText(url, token)
        let pages = Json.arr(Json.get(try Json.parse(json), "query"), "pages")
        var outp = [WikiFact]()
        for p in pages.stableSorted(by: { Json.num($0, "index", 99) < Json.num($1, "index", 99) }) {
            var text = Json.str(p, "extract").trimmed
            let title = Json.str(p, "title")
            if text.len < 80 { continue }
            if Rx.isMatch(text, "(steht für|bezeichnet|may refer to|steht für:)\\s*:?\\s*$") || text.hasSuffix(":") { continue } // Begriffsklaerung
            text = Rx.replace(text, "\\s*\\([^()]{0,80}(?:Aussprache|ˈ|IPA|listen)[^()]{0,80}\\)", "")
            if text.len > 1100 {
                let cut = text.lastIndexOf(". ", before: 1100 - 2)
                text = text.sub(0, cut > 400 ? cut + 1 : 1100)
            }
            var link = Json.str(p, "fullurl")
            if !WebAddress.isWeb(link) { link = "https://" + lang + ".wikipedia.org/wiki/" + Http.escape(title.rep(" ", "_")) }
            let f = WikiFact(); f.title = title; f.url = link; f.text = text; f.lang = lang
            outp.append(f)
        }
        return outp
    }
}
