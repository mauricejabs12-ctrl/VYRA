import Foundation

/// Textnormalisierung und Suchwoerter (aus `Knowledge` in VYRA.GXCore.cs). Wird von der Relevanzbewertung (BM25),
/// dem Gedaechtnis, dem Wissens-Booster und der Aufgabenerkennung genutzt.
public enum Knowledge {
    static let stop: Set<String> = Set("der die das den dem des ein eine einer eines einem einen und oder aber auch als am an auf aus bei bin bis bist da dann darf dass dein deine dem den denn der des dich dir doch du durch er es euch fuer gibt hab habe hat hatte ich ihr im in ist ja kann kannst mich mir mit muss nach nicht noch nur ob oft schon sehr sein sich sie sind so soll ueber um und uns unter viel vom von vor war was weil welche welcher welches wenn wer wie wieso warum wird wo wurde zu zum zur mein meine meinen meinem meiner mache machen bitte gerne hallo hey hi mal etwas jetzt immer man einfach geht gehen tun tut kriege kriegen bekomme bekommen moechte will wollen was's".split(separator: " ").map(String.init))
    static let synonyms: [String: String] = [
        "ruckelt": "stotter ruckel frametime", "ruckeln": "stotter ruckel frametime", "stottern": "stotter ruckel frametime", "lag": "ping netzwerk latenz eingabe", "lagt": "ping netzwerk latenz eingabe stotter",
        "laggy": "ping netzwerk latenz", "ping": "ping netzwerk latenz", "fps": "fps bild booster", "frames": "fps bild", "einbrueche": "stotter fps frametime", "drops": "stotter fps",
        "zielkreuz": "crosshair fadenkreuz", "fadenkreuz": "crosshair", "crosshairs": "crosshair", "overlay": "hud", "anzeige": "hud", "design": "design themes farbe", "farbe": "design farbe", "themes": "design",
        "browser": "browser web tab", "internet": "browser web", "werbung": "werbeblocker filter browser", "ki": "nova ki modell", "nova": "nova ki", "neustart": "neustart anmelden", "abmelden": "anmelden neustart",
        "rueckgaengig": "backup sicherung zuruecksetzen", "zuruecksetzen": "backup sicherung", "konto": "konto anmelden passwort", "passwort": "konto passwort", "maus": "eingabe maus", "tastatur": "eingabe",
        "nvidia": "nvidia grafik treiber", "grafikkarte": "nvidia grafik gpu", "speicher": "speicher ram bereinigung", "aufraeumen": "bereinigung temp", "automatisch": "automatik", "optimieren": "optimierung automatik"
    ]
    /// Kleinbuchstaben, Umlaute als ae/oe/ue/ss, alles andere ausser Buchstaben/Ziffern wird Leerzeichen.
    public static func norm(_ s: String) -> String {
        var b = String.UnicodeScalarView()
        for ch in s.lowercased().unicodeScalars {
            switch ch {
            case "ä": b.append("a"); b.append("e")
            case "ö": b.append("o"); b.append("e")
            case "ü": b.append("u"); b.append("e")
            case "ß": b.append("s"); b.append("s")
            default:
                if ch.properties.isAlphabetic || ch.properties.generalCategory == .decimalNumber { b.append(ch) } else { b.append(" ") }
            }
        }
        return String(b)
    }
    public static func stem(_ w: String) -> String {
        if w.len <= 4 { return w }
        for suf in ["ungen", "ung", "heiten", "heit", "keiten", "keit", "ern", "en", "er", "es", "em", "e", "n", "s"] {
            if w.len - suf.len >= 4 && w.hasSuffix(suf) { return String(w.dropLast(suf.count)) }
        }
        return w
    }
    public static func tokens(_ s: String, expand: Bool) -> [String] {
        var r = [String]()
        for w0 in norm(s).split(separator: " ").map(String.init) {
            if stop.contains(w0) || w0.len < 2 { continue }
            r.append(stem(w0))
            if expand, let syn = synonyms[w0] { for x in syn.split(separator: " ") { r.append(stem(String(x))) } }
        }
        return r
    }
}

// ---------------------------------------------------------------- Wissensbasis der Schnellhilfe (aus `Knowledge`: Anleitungen + 64 Massnahmen)
public final class KnowledgeDoc {
    public var id = "", title = "", kind = "", page = "", text = ""
    public var points = [String]()
    var terms = [String: Int]()
    var length = 0
    public init() {}
}
public final class KnowledgeHit { public let doc: KnowledgeDoc; public let score: Double; init(_ d: KnowledgeDoc, _ s: Double) { doc = d; score = s } }

public final class KnowledgeBase {
    var docs = [KnowledgeDoc]()
    var df = [String: Int]()
    var avg = 1.0
    public init() {}
    public var count: Int { docs.count }
    /// Laedt Guides.json und Tweaks.json aus dem App-Paket (unveraendert aus der Windows-Ausgabe).
    public static func bundled() -> KnowledgeBase {
        let k = KnowledgeBase()
        if let u = Bundle.module.url(forResource: "Guides", withExtension: "json", subdirectory: "Resources/Wissen") { try? k.loadGuides(u.path) }
        if let u = Bundle.module.url(forResource: "Tweaks", withExtension: "json", subdirectory: "Resources/Wissen") { try? k.loadTweaks(u.path) }
        return k
    }
    public func add(_ d: KnowledgeDoc) {
        for t in Knowledge.tokens(d.title + " " + d.title + " " + d.text + " " + d.points.joined(separator: " "), expand: false) { d.terms[t, default: 0] += 1; d.length += 1 }
        for t in d.terms.keys { df[t, default: 0] += 1 }
        docs.append(d)
        avg = docs.reduce(0.0) { $0 + Double(max(1, $1.length)) } / Double(docs.count)
    }
    public static func pageForGuide(_ id: String) -> String {
        switch id {
        case "automatik", "plan": return "Automatik"
        case "optimierungen": return "64 Optimierungen"
        case "scanner": return "PC-Scanner"
        case "live": return "Live-Monitor"
        case "hud", "fpsfreigabe": return "Fortnite HUD"
        case "booster": return "FPS-Booster"
        case "crosshair", "eigene-crosshairs": return "Crosshair Lab"
        case "bereinigung": return "Bereinigung"
        case "backups": return "Backups & Verlauf"
        case "konto": return "Konto & Einstellungen"
        case "designs": return "Design Studio"
        case "browser": return "Webbrowser"
        case "nova", "vyra-ki": return "VYRA KI"
        case "systemcheck", "probleme": return "Systemcheck"
        default: return "Anleitungen"
        }
    }
    public func loadGuides(_ path: String) throws {
        for g in (try Json.readFile(path, maxBytes: 1_048_576) as? [Any]) ?? [] {
            let d = KnowledgeDoc()
            d.id = "guide:" + Json.str(g, "id"); d.title = Json.str(g, "title"); d.kind = "Anleitung"; d.page = KnowledgeBase.pageForGuide(Json.str(g, "id")); d.text = Json.str(g, "intro")
            for s in Json.arr(g, "steps") { d.points.append(Json.text(s)) }
            for s in Json.arr(g, "tips") { d.points.append("Tipp: " + Json.text(s)) }
            if !d.title.isEmpty { add(d) }
        }
    }
    public func loadTweaks(_ path: String) throws {
        for t in (try Json.readFile(path, maxBytes: 4_194_304) as? [Any]) ?? [] {
            let d = KnowledgeDoc()
            d.id = "tweak:" + Json.str(t, "id"); d.title = Json.str(t, "title"); d.kind = "Maßnahme · " + Json.str(t, "category"); d.page = "64 Optimierungen"; d.text = Json.str(t, "description") + " " + Json.str(t, "category")
            for s in Json.arr(t, "steps") { d.points.append(Json.text(s)) }
            let note = Json.str(t, "note")
            if !note.isEmpty { d.points.append("Hinweis: " + note) }
            if !d.title.isEmpty { add(d) }
        }
    }
    public func search(_ query: String, _ take: Int) -> [KnowledgeHit] {
        var q = [String]()
        for t in Knowledge.tokens(query, expand: true) where !q.contains(t) { q.append(t) }
        var hits = [KnowledgeHit]()
        if q.isEmpty || docs.isEmpty { return hits }
        let n = Double(docs.count)
        for d in docs {
            var score = 0.0
            for t in q {
                guard let f = d.terms[t] else { continue }
                let c = Double(df[t] ?? 0)
                let idf = log(1 + (n - c + 0.5) / (c + 0.5))
                score += idf * (Double(f) * 2.2) / (Double(f) + 1.2 * (0.25 + 0.75 * Double(d.length) / avg))
            }
            let nt = Knowledge.norm(d.title)
            for t in q where t.len >= 4 && nt.contains(t) { score += 1.5 }
            if score > 0 { hits.append(KnowledgeHit(d, score)) }
        }
        return Array(hits.stableSorted { $0.score > $1.score }.prefix(take))
    }
    /// Antwort ohne Sprachmodell: kurze, ehrliche Zusammenfassung der passenden Anleitungen.
    public func answer(_ question: String) -> String {
        let q = Knowledge.norm(question).trimmed
        if q.isEmpty { return "Stell mir eine Frage zu VYRA, Fortnite-Leistung, HUD, Crosshairs, Browser oder Designs." }
        if Rx.isMatch(q, "^(hallo|hi|hey|moin|servus|guten (morgen|tag|abend))( (nova|vyra bot|vyrabot))?$") { return "Hallo! Ich bin VYRA Bot. Frag mich zum Beispiel: »Wie aktiviere ich den FPS-Booster?« oder »Warum ruckelt Fortnite?«" }
        if Rx.isMatch(q, "^(danke|dankeschoen|vielen dank|thx|merci)") { return "Gern geschehen! Viel Erfolg im nächsten Match." }
        if q.contains("wer bist du") || q.contains("was bist du") || q.contains("was kannst du") { return "Ich bin VYRA Bot, der Assistent in VYRA. Im Schnellhilfe-Modus suche ich passende Antworten in den VYRA-Anleitungen und den 64 Maßnahmen – sofort und offline. Mit dem optionalen KI-Modell kann ich zusätzlich frei formulierte Antworten schreiben." }
        let hits = search(question, 3)
        if hits.isEmpty || hits[0].score < 1.2 { return "Dazu habe ich in den VYRA-Anleitungen nichts Passendes gefunden. Versuche es mit anderen Stichworten (zum Beispiel »FPS«, »Ruckeln«, »HUD«, »Crosshair«, »Browser«). Für allgemeine Fragen (Lernen, Programmieren, Schreiben, Recherche) oben »VYRA KI« wählen – die eigene KI ohne Schlüssel – oder »OpenAI« bzw. »Claude« mit deinem API-Schlüssel." }
        let top = hits[0].doc
        var b = top.title + " (" + top.kind + ")\n"
        if !top.text.trimmed.isEmpty { b += top.text.trimmed + "\n" }
        var i = 1
        for p in top.points.prefix(6) { if p.hasPrefix("Tipp:") || p.hasPrefix("Hinweis:") { b += "• " } else { b += "\(i). "; i += 1 }; b += p + "\n" }
        b += Platform.pagePointer(top.page)
        let more = hits.dropFirst().filter { $0.score >= hits[0].score * 0.45 }.map { $0.doc.title }
        if !more.isEmpty { b += "\n\nAuch passend: " + more.joined(separator: " · ") + "." }
        return b
    }
    public func context(_ question: String, _ maxChars: Int) -> String {
        var b = ""
        for h in search(question, 3) {
            if h.score < 1 { continue }
            var part = "[" + h.doc.title + " – Seite " + h.doc.page + "] " + h.doc.text.trimmed
            for p in h.doc.points.prefix(5) { part += " | " + p }
            if b.len + part.len > maxChars { break }
            b += part + "\n"
        }
        return b
    }
}
