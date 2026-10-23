import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class SearchHit {
    public var title = "", url = "", snippet = "", engine = ""
    public var id = 0
    public var rank = 0
    public init() {}
    public init(title: String, url: String, snippet: String = "", engine: String = "") { self.title = title; self.url = url; self.snippet = snippet; self.engine = engine }
}
public final class PageText {
    public var url = "", title = "", text = ""
    public var unreadable = false
    public var problem = ""
}

/// Kleiner HTTP-Helfer (wie der gemeinsame HttpClient unter Windows): Abbruch ueber CancelToken, Zeitlimit, Groessengrenze.
public enum Http {
    public struct Response {
        public let status: Int
        public let headers: [String: String]
        public let data: Data
        public var text: String { String(decoding: data, as: UTF8.self) }
        public func header(_ name: String) -> String? {
            for (k, v) in headers where k.lowercased() == name.lowercased() { return v }
            return nil
        }
        public var ok: Bool { (200...299).contains(status) }
    }
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 20
        c.httpMaximumConnectionsPerHost = 16
        return URLSession(configuration: c)
    }()
    public static var userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    public static func request(_ url: URL, method: String = "GET", body: Data? = nil, headers: [String: String] = [:], timeout: Double = 20, maxBytes: Int = 3_000_000, token: CancelToken) async throws -> Response {
        try token.check()
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.httpBody = body
        r.timeoutInterval = timeout
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        r.setValue("de-DE,de;q=0.9,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let box = TaskBox()
        let id = token.register { box.cancel() }
        defer { token.unregister(id) }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Response, Error>) in
            let t = session.dataTask(with: r) { data, resp, err in
                if let err = err {
                    if (err as NSError).code == NSURLErrorCancelled { c.resume(throwing: VyraError.cancelled) }
                    else if (err as NSError).code == NSURLErrorTimedOut { c.resume(throwing: VyraError("Zeitüberschreitung", .timeout)) }
                    else { c.resume(throwing: VyraError(err.vyraMessage, .io)) }
                    return
                }
                let h = resp as? HTTPURLResponse
                var hs = [String: String]()
                for (k, v) in h?.allHeaderFields ?? [:] { hs[String(describing: k)] = String(describing: v) }
                let d = data ?? Data()
                if d.count > maxBytes * 2 { c.resume(throwing: VyraError("Antwort zu groß.", .invalidData)); return }
                c.resume(returning: Response(status: h?.statusCode ?? 0, headers: hs, data: d.count > maxBytes ? d.prefix(maxBytes) : d))
            }
            box.set(t)
            t.resume()
        }
    }
    public static func get(_ url: String, timeout: Double = 20, token: CancelToken) async throws -> Response {
        guard let u = URL(string: url) else { throw VyraError("Ungültige Adresse.", .argument) }
        return try await request(u, timeout: timeout, token: token)
    }
    public static func formEncode(_ pairs: [(String, String)]) -> Data {
        Data(pairs.map { escapeForm($0.0) + "=" + escapeForm($0.1) }.joined(separator: "&").utf8)
    }
    static func escapeForm(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return (s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s).rep("%20", "+")
    }
    /// Wie `Uri.EscapeDataString`.
    public static func escape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func set(_ t: URLSessionTask) { lock.lock(); task = t; let c = cancelled; lock.unlock(); if c { t.cancel() } }
    func cancel() { lock.lock(); cancelled = true; let t = task; lock.unlock(); t?.cancel() }
}

public enum WebAddress {
    public static func isWeb(_ s: String) -> Bool {
        guard let u = URL(string: s), let sc = u.scheme?.lowercased() else { return false }
        return sc == "https" || sc == "http"
    }
    public static func hostOf(_ s: String) -> String {
        guard let u = URL(string: s), let h = u.host, !h.isEmpty else { return "" }
        return h.lowercased()
    }
    public static func display(_ url: String) -> String {
        guard let u = URL(string: url), let h0 = u.host else { return url }
        var h = h0
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        return h
    }
}

/// Websuche ohne Schluessel und Seitenlesen (unveraendert: DuckDuckGo, Bing, DuckDuckGo Lite, Mojeek, Wikipedia).
public enum WebResearch {
    public static var ddgHtml = "https://html.duckduckgo.com/html/"
    public static var ddgLite = "https://lite.duckduckgo.com/lite/"
    public static var bingUrl = "https://www.bing.com/search"
    public static var mojeekUrl = "https://www.mojeek.com/search"
    public static var wikiBase = "https://{0}.wikipedia.org"
    public static var allowLocalForTests = false

    // Seiten, die ohne Anmeldung keinen Text liefern: nur der Suchtext wird genutzt.
    static let snippetOnly = ["facebook.com", "instagram.com", "tiktok.com", "x.com", "twitter.com", "pinterest.", "linkedin.com", "youtube.com", "youtu.be", "threads.net"]
    public static func isSnippetOnly(_ url: String) -> Bool {
        let h = WebAddress.hostOf(url)
        return snippetOnly.contains { s in s.hasSuffix(".") ? h.contains(s) : (h == s || h.hasSuffix("." + s)) }
    }
    static func safe(_ name: String, _ token: CancelToken, _ problems: ProblemList, _ f: () async throws -> [SearchHit]) async throws -> [SearchHit] {
        do { return try await f() }
        catch {
            if error.isCancellation || (error as? VyraError)?.kind == .timeout {
                if token.isCancelled { throw VyraError.cancelled }
                problems.add(name + " antwortet nicht"); return []
            }
            problems.add(name + ": " + error.vyraMessage); return []
        }
    }
    static func limit(_ token: CancelToken, _ seconds: Double) -> CancelToken { let c = CancelToken.linked(token); c.cancelAfter(seconds); return c }

    /// Websuche ohne Schluessel: DuckDuckGo und Bing parallel, dann DuckDuckGo Lite, Mojeek und Wikipedia als Ersatz.
    public static func search(_ query0: String, _ max: Int, _ token: CancelToken) async throws -> [SearchHit] {
        let problems = ProblemList()
        var query = query0.trimmed
        if query.isEmpty { return [] }
        if query.len > 300 { query = query.sub(0, 300) }
        let q = query
        // Jede Suchmaschine bekommt hoechstens 7 Sekunden, damit eine langsame nicht alles aufhaelt.
        async let a = safe("DuckDuckGo", token, problems) { try await ddgSearch(ddgHtml, q, false, limit(token, 7)) }
        async let b = safe("Bing", token, problems) { try await bingSearch(q, limit(token, 7)) }
        var hits = merge([try await a, try await b])
        if hits.count < 4 {
            async let c = safe("DuckDuckGo Lite", token, problems) { try await ddgSearch(ddgLite, q, true, limit(token, 6)) }
            async let d = safe("Mojeek", token, problems) { try await mojeekSearch(q, limit(token, 6)) }
            hits = merge([hits, try await c, try await d])
        }
        if hits.count < 3 {
            for lang in ["de", "en"] {
                if hits.count >= max { break }
                let w = try await safe("Wikipedia", token, problems) { try await wikiSearch(lang, q, 3, limit(token, 6)) }
                hits = merge([hits, w])
            }
        }
        if hits.isEmpty, let p = problems.first { throw VyraError("Die Websuche hat nicht geantwortet (" + p + "). Prüfe die Internetverbindung.", .io) }
        let res = Array(hits.prefix(max))
        for (i, h) in res.enumerated() { h.rank = i + 1 }
        return res
    }
    /// Kleiner GET-Helfer (z. B. fuer den Wissens-Booster).
    public static func getText(_ url: String, _ token: CancelToken) async throws -> String {
        let r = try await Http.get(url, token: token)
        if !r.ok { throw VyraError("HTTP \(r.status)", .io) }
        if r.data.count > 3_000_000 { throw VyraError("Antwort zu groß.", .invalidData) }
        return r.text
    }
    /// Ergebnisse mehrerer Suchmaschinen abwechselnd zusammenfuehren (beste Treffer jeder Quelle zuerst), Doppelte entfernen.
    public static func merge(_ lists: [[SearchHit]]) -> [SearchHit] {
        var outp = [SearchHit]()
        var seen = Set<String>()
        let longest = lists.map { $0.count }.max() ?? 0
        for i in 0..<longest {
            for l in lists where i < l.count {
                let h = l[i]
                let k = urlKey(h.url)
                if k.isEmpty || seen.contains(k.lowercased()) { continue }
                seen.insert(k.lowercased())
                if h.url.lowercased().hasSuffix(".pdf") { continue }
                outp.append(h)
            }
        }
        return outp
    }
    public static func urlKey(_ url: String) -> String {
        guard let u = URL(string: url), let host = u.host else { return "" }
        var h = host.lowercased()
        if h.hasPrefix("www.") { h = String(h.dropFirst(4)) }
        if h.hasPrefix("m.") && h.contains("wikipedia") { h = String(h.dropFirst(2)) }
        let query = u.query.map { "?" + $0 } ?? ""
        return h + u.path.trimEnd("/").lowercased() + (query.len > 1 ? query : "")
    }
    static func ddgSearch(_ url: String, _ query: String, _ lite: Bool, _ token: CancelToken) async throws -> [SearchHit] {
        guard let u = URL(string: url) else { return [] }
        let r = try await Http.request(u, method: "POST", body: Http.formEncode([("q", query), ("kl", "de-de")]), headers: ["Content-Type": "application/x-www-form-urlencoded"], token: token)
        if !r.ok { throw VyraError("HTTP \(r.status)", .io) }
        return lite ? parseDdgLite(r.text) : parseDdgHtml(r.text)
    }
    static func bingSearch(_ query: String, _ token: CancelToken) async throws -> [SearchHit] {
        let r = try await Http.get(bingUrl + "?q=" + Http.escape(query) + "&setlang=de&cc=DE&mkt=de-DE", token: token)
        if !r.ok { throw VyraError("HTTP \(r.status)", .io) }
        return parseBing(r.text)
    }
    static func mojeekSearch(_ query: String, _ token: CancelToken) async throws -> [SearchHit] {
        let r = try await Http.get(mojeekUrl + "?q=" + Http.escape(query) + "&lb=de", token: token)
        if !r.ok { throw VyraError("HTTP \(r.status)", .io) }
        return parseMojeek(r.text)
    }
    static let rxDdgA = "<a[^>]*class=\"[^\"]*result__a[^\"]*\"[^>]*>(.*?)</a>"
    static let rxHref = "href=[\"']([^\"']+)[\"']"
    static let rxDdgSnippet = "class=\"[^\"]*result__snippet[^\"]*\"[^>]*>(.*?)</(a|div|td)>"
    public static func parseDdgHtml(_ html: String) -> [SearchHit] {
        var list = [SearchHit]()
        if html.isEmpty { return list }
        let ms = Rx.matches(html, rxDdgA, [.s, .i])
        for (i, m) in ms.enumerated() {
            let start = m.index, end = i + 1 < ms.count ? ms[i + 1].index : html.len
            let box = html.lastIndexOf("class=\"result ", before: start)
            if box >= 0 {
                let q = html.indexOf("\"", from: box + 7)
                if q > box && html.sub(box, q - box).contains("result--ad") { continue }
            }
            guard let hm = Rx.match(m.value, rxHref, .i), let url = decodeDdgUrl(hm.group(1)) else { continue }
            let sm = Rx.match(html.sub(start, end - start), rxDdgSnippet, [.s, .i])
            list.append(SearchHit(title: plain(m.group(1)), url: url, snippet: sm.map { plain($0.group(1)) } ?? "", engine: "DuckDuckGo"))
        }
        return list
    }
    static let rxLiteA = "<a[^>]*class=['\"]result-link['\"][^>]*>(.*?)</a>"
    static let rxLiteSnippet = "class=['\"]result-snippet['\"][^>]*>(.*?)</td>"
    public static func parseDdgLite(_ html: String) -> [SearchHit] {
        var list = [SearchHit]()
        if html.isEmpty { return list }
        let ms = Rx.matches(html, rxLiteA, [.s, .i])
        for (i, m) in ms.enumerated() {
            let start = m.index, end = i + 1 < ms.count ? ms[i + 1].index : html.len
            guard let hm = Rx.match(m.value, rxHref, .i), let url = decodeDdgUrl(hm.group(1)) else { continue }
            let sm = Rx.match(html.sub(start, end - start), rxLiteSnippet, [.s, .i])
            list.append(SearchHit(title: plain(m.group(1)), url: url, snippet: sm.map { plain($0.group(1)) } ?? "", engine: "DuckDuckGo"))
        }
        return list
    }
    // Bing: <li class="b_algo"> <h2><a href="...">Titel</a></h2> ... <p>Ausschnitt</p>
    static let rxBingH2 = "<h2[^>]*>\\s*<a\\b([^>]*)>(.*?)</a>"
    static let rxBingP = "<p\\b[^>]*>(.*?)</p>"
    public static func parseBing(_ html: String) -> [SearchHit] {
        var list = [SearchHit]()
        if html.isEmpty { return list }
        let parts = Rx.split(html, "<li class=\"b_algo\\b", .i)
        if parts.count < 2 { return list }
        for i in 1..<parts.count {
            var block = parts[i]
            let stop = block.indexOf("<li class=\"b_", ignoreCase: true)
            if stop > 0 { block = block.sub(0, stop) }
            guard let h = Rx.match(block, rxBingH2, [.s, .i]), let hm = Rx.match(h.group(1), rxHref, .i), let url = decodeBingUrl(hm.group(1)) else { continue }
            var snip = ""
            for p in Rx.matches(block, rxBingP, [.s, .i]) { let t = plain(p.group(1)); if t.len > snip.len { snip = t } }
            list.append(SearchHit(title: plain(h.group(2)), url: url, snippet: snip, engine: "Bing"))
        }
        return list
    }
    /// Bing-Klicklinks: bing.com/ck/a?...&u=a1<base64url der Zieladresse>
    public static func decodeBingUrl(_ href0: String) -> String? {
        var href = HTMLEntities.decode(href0)
        if href.containsIgnoreCase("bing.com/ck/a") {
            guard let m = Rx.match(href, "[?&]u=a1([^&]+)") else { return nil }
            var b = m.group(1).rep("-", "+").rep("_", "/")
            while b.len % 4 != 0 { b += "=" }
            guard let d = Data(base64Encoded: b), let s = String(data: d, encoding: .utf8) else { return nil }
            href = s
        }
        guard let x = URL(string: href), let sc = x.scheme?.lowercased(), sc == "http" || sc == "https", let host0 = x.host else { return nil }
        let host = host0.lowercased()
        if host.hasSuffix("bing.com") || (host.hasSuffix("microsoft.com") && x.path.hasPrefix("/bing")) { return nil }
        return x.absoluteString
    }
    // Mojeek: <a class="title" href="...">Titel</a> ... <p class="s">Ausschnitt</p>
    static let rxMojA = "<a\\b([^>]*\\bclass=\"title\"[^>]*)>(.*?)</a>"
    static let rxMojS = "<p class=\"s\"[^>]*>(.*?)</p>"
    public static func parseMojeek(_ html: String) -> [SearchHit] {
        var list = [SearchHit]()
        if html.isEmpty { return list }
        let ms = Rx.matches(html, rxMojA, [.s, .i])
        for (i, m) in ms.enumerated() {
            let end = i + 1 < ms.count ? ms[i + 1].index : html.len
            guard let hm = Rx.match(m.group(1), rxHref, .i) else { continue }
            let href = HTMLEntities.decode(hm.group(1))
            guard let x = URL(string: href), let sc = x.scheme?.lowercased(), sc == "http" || sc == "https", let host = x.host, !host.hasSuffix("mojeek.com") else { continue }
            let sm = Rx.match(html.sub(m.index, end - m.index), rxMojS, [.s, .i])
            list.append(SearchHit(title: plain(m.group(2)), url: x.absoluteString, snippet: sm.map { plain($0.group(1)) } ?? "", engine: "Mojeek"))
        }
        return list
    }
    /// DuckDuckGo leitet ueber //duckduckgo.com/l/?uddg=<Ziel> weiter; Werbelinks (y.js) werden verworfen.
    public static func decodeDdgUrl(_ href0: String) -> String? {
        var href = HTMLEntities.decode(href0)
        if href.hasPrefix("//") { href = "https:" + href }
        if href.contains("duckduckgo.com/y.js") || href.contains("ad_domain=") || href.contains("ad_provider=") { return nil }
        let u = href.indexOf("uddg=")
        if u >= 0 {
            var v = href.sub(u + 5)
            let amp = v.indexOf("&")
            if amp >= 0 { v = v.sub(0, amp) }
            href = v.removingPercentEncoding ?? v
        }
        guard let x = URL(string: href), let sc = x.scheme?.lowercased(), sc == "http" || sc == "https", let host = x.host else { return nil }
        if host.lowercased().hasSuffix("duckduckgo.com") { return nil }
        return x.absoluteString
    }
    public static func wikiSearch(_ lang: String, _ query: String, _ max: Int, _ token: CancelToken) async throws -> [SearchHit] {
        let baseUrl = wikiBase.rep("{0}", lang)
        let url = baseUrl + "/w/api.php?action=query&list=search&format=json&utf8=1&srlimit=\(max)&srsearch=" + Http.escape(query)
        var list = [SearchHit]()
        let r = try await Http.get(url, token: token)
        if !r.ok { return list }
        let o = try Json.parse(r.text)
        for it in Json.arr(Json.get(o, "query"), "search") {
            let title = Json.str(it, "title")
            if title.isEmpty { continue }
            list.append(SearchHit(title: title + " – Wikipedia", url: baseUrl + "/wiki/" + Http.escape(title.rep(" ", "_")), snippet: plain(Json.str(it, "snippet")), engine: "Wikipedia"))
        }
        return list
    }
    static func privateHost(_ u: URL) -> Bool {
        if allowLocalForTests { return false }
        let h = (u.host ?? "").lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".internal") || h.hasSuffix(".lan") || h.hasSuffix(".home") || h.hasSuffix(".fritz.box") { return true }
        let t = h.trim("[]")
        let parts = t.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 && t.split(separator: ".").count == 4 {
            let b = parts
            return b[0] == 10 || b[0] == 127 || (b[0] == 192 && b[1] == 168) || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 169 && b[1] == 254) || b[0] == 0 || (b[0] == 100 && b[1] >= 64 && b[1] <= 127)
        }
        if t.contains(":") { // IPv6
            return t == "::1" || t.hasPrefix("fe8") || t.hasPrefix("fe9") || t.hasPrefix("fea") || t.hasPrefix("feb") || t.hasPrefix("fec") || t.hasPrefix("fc") || t.hasPrefix("fd")
        }
        return false
    }
    /// Laedt eine Seite und liefert den lesbaren Text (ohne Menues, Skripte, Werbung).
    public static func read(_ url: String, _ maxChars: Int, _ token: CancelToken) async throws -> PageText {
        let p = PageText(); p.url = url
        guard let u = URL(string: url), let sc = u.scheme?.lowercased(), sc == "http" || sc == "https" else { p.unreadable = true; p.problem = "keine Webadresse"; return p }
        if privateHost(u) { p.unreadable = true; p.problem = "lokale Adressen werden nicht geöffnet"; return p }
        if let wiki = Rx.match(u.absoluteString, "^https?://([a-z\\-]+)\\.(?:m\\.)?wikipedia\\.org/wiki/([^?#]+)", .i), !allowLocalForTests {
            do {
                let title = (wiki.group(2).removingPercentEncoding ?? wiki.group(2)).rep("_", " ")
                let api = wikiBase.rep("{0}", wiki.group(1)) + "/w/api.php?action=query&prop=extracts&explaintext=1&format=json&utf8=1&redirects=1&titles=" + Http.escape(title)
                let r = try await Http.get(api, token: token)
                let o = try Json.parse(r.text)
                if let pages = Json.get(Json.get(o, "query"), "pages") as? JObject, let first = pages.entries.first {
                    p.title = Json.str(first.1, "title")
                    p.text = squeeze(Rx.replace(Json.str(first.1, "extract"), "^=+\\s*(.*?)\\s*=+\\s*$", "## $1", .m), maxChars)
                }
                if !p.text.isEmpty { return p }
            } catch { if token.isCancelled { throw VyraError.cancelled } }
        }
        do {
            let lim = CancelToken.linked(token)
            lim.cancelAfter(8)
            let r = try await Http.request(u, timeout: 8, maxBytes: 3_000_000, token: lim)
            if !r.ok { p.unreadable = true; p.problem = "HTTP \(r.status)"; return p }
            let ctype = (r.header("Content-Type") ?? "").lowercased()
            let type = ctype.split(separator: ";").first.map { String($0).trimmed } ?? ""
            if type.contains("pdf") { p.unreadable = true; p.problem = "PDF im Netz wird übersprungen"; return p }
            if !type.isEmpty && !type.contains("html") && !type.hasPrefix("text/") && !type.contains("xml") { p.unreadable = true; p.problem = "kein Text (" + type + ")"; return p }
            let cs = Rx.match(ctype, "charset=\"?([a-z0-9_\\-]+)")?.group(1)
            let html = decode(r.data, cs)
            if type.hasPrefix("text/plain") { p.text = squeeze(html, maxChars); return p }
            p.title = titleOf(html)
            p.text = htmlToText(html, maxChars)
            if p.text.len < 200 {
                // Seiten, die nur mit JavaScript laufen: wenigstens die Beschreibung verwenden.
                let desc = metaDescription(html)
                if desc.len > p.text.len { p.text = desc }
                p.unreadable = p.text.isEmpty
                if p.unreadable { p.problem = "Seite enthält keinen lesbaren Text (vermutlich nur mit JavaScript)" }
            }
            return p
        } catch {
            if token.isCancelled { throw VyraError.cancelled }
            if error.isCancellation || (error as? VyraError)?.kind == .timeout { p.unreadable = true; p.problem = "Zeitüberschreitung"; return p }
            p.unreadable = true; p.problem = error.vyraMessage; return p
        }
    }
    static func decode(_ data: Data, _ charset: String?) -> String {
        var cs = charset?.lowercased()
        if cs == nil {
            let head = TextCodec.decodeLatin1(data.prefix(2048))
            cs = Rx.match(head, "charset=[\"']?([A-Za-z0-9_\\-]+)", .i)?.group(1).lowercased()
        }
        switch cs ?? "utf-8" {
        case "iso-8859-1", "latin1", "latin-1", "windows-1252", "cp1252", "iso-8859-15": return TextCodec.decodeWindows1252(data)
        case "utf-16", "utf-16le": return String(data: data, encoding: .utf16LittleEndian) ?? String(decoding: data, as: UTF8.self)
        case "utf-16be": return String(data: data, encoding: .utf16BigEndian) ?? String(decoding: data, as: UTF8.self)
        default: return String(decoding: data, as: UTF8.self)
        }
    }
    static func titleOf(_ html: String) -> String {
        var m = Rx.match(html, "<meta[^>]+property=[\"']og:title[\"'][^>]+content=[\"']([^\"']+)", .i)
        if m == nil { m = Rx.match(html, "<title[^>]*>(.*?)</title>", [.s, .i]) }
        return m.map { plain($0.group(1)) } ?? ""
    }
    static func metaDescription(_ html: String) -> String {
        Rx.match(html, "<meta[^>]+(?:name|property)=[\"'](?:og:)?description[\"'][^>]+content=[\"']([^\"']{30,})", .i).map { plain($0.group(1)) } ?? ""
    }
    public static func plain(_ html: String) -> String {
        var s = Rx.replace(html, "<[^>]+>", " ")
        s = HTMLEntities.decode(s)
        s = Rx.replace(s, "\\s+", " ")
        return s.trimmed
    }
    /// Lesbarer Haupttext: Artikel bzw. Hauptbereich, ohne Navigation, Kopf- und Fusszeilen, Formulare und Skripte.
    public static func htmlToText(_ html: String, _ maxChars: Int) -> String {
        if html.isEmpty { return "" }
        var s = Rx.replace(html, "<!--.*?-->", "", [.s, .i])
        for tag in ["script", "style", "noscript", "svg", "template", "iframe", "head", "canvas", "select", "button"] { s = Rx.replace(s, "<" + tag + "\\b.*?</" + tag + ">", " ", [.s, .i]) }
        var body = s
        for tag in ["article", "main"] {
            var best = ""
            for m in Rx.matches(s, "<" + tag + "\\b[^>]*>(.*?)</" + tag + ">", [.s, .i]) where m.group(1).len > best.len { best = m.group(1) }
            if plain(best).len > 400 { body = best; break }
        }
        for tag in ["nav", "header", "footer", "aside", "form", "figure"] { body = Rx.replace(body, "<" + tag + "\\b.*?</" + tag + ">", " ", [.s, .i]) }
        body = Rx.replace(body, "<(div|section)[^>]*(cookie|consent|banner|newsletter|share|social|related|comment|advert|sidebar|breadcrumb|menu)[^>]*>", " ", .i)
        body = Rx.replace(body, "<h([1-4])[^>]*>", "\n\n## ", .i)
        body = Rx.replace(body, "<li[^>]*>", "\n- ", .i)
        body = Rx.replace(body, "<(br|/p|/h[1-6]|/li|/div|/tr|/section|/blockquote|/pre|/table|/ul|/ol|p|tr|div|section)\\b[^>]*>", "\n", .i)
        body = Rx.replace(body, "<(td|th)[^>]*>", " | ", .i)
        body = Rx.replace(body, "<[^>]+>", "")
        body = HTMLEntities.decode(body)
        var lines = [String]()
        var seen = Set<String>()
        for raw in body.splitKeep("\n") {
            let l = Rx.replace(raw, "[ \\t\\u00a0]+", " ").trimmed
            if l.isEmpty { if let last = lines.last, !last.isEmpty { lines.append("") }; continue }
            let heading = l.hasPrefix("## "), item = l.hasPrefix("- "), row = l.hasPrefix("|") && l.len > 12
            if !heading && !item && !row && l.len < 35 { continue }
            if item && l.len < 14 { continue }
            if heading && l.len < 6 { continue }
            if seen.contains(l) { continue }
            seen.insert(l)
            lines.append(l)
        }
        // Ueberschriften ohne folgenden Text entfernen
        var outp = [String]()
        for i in 0..<lines.count {
            if lines[i].hasPrefix("## ") {
                var j = i + 1
                while j < lines.count && lines[j].isEmpty { j += 1 }
                if j >= lines.count || lines[j].hasPrefix("## ") { continue }
            }
            outp.append(lines[i])
        }
        return squeeze(outp.joined(separator: "\n"), maxChars)
    }
    public static func squeeze(_ s0: String, _ maxChars: Int) -> String {
        var s = Rx.replace(s0, "\n{3,}", "\n\n").trimmed
        if maxChars > 0 && s.len > maxChars {
            var cut = s.lastIndexOf("\n", before: maxChars)
            if cut < maxChars / 2 { cut = s.lastIndexOf(". ", before: maxChars - 1) + 1 }
            if cut < maxChars / 2 { cut = maxChars }
            s = s.sub(0, cut).trimEnd() + " …"
        }
        return s
    }
}
