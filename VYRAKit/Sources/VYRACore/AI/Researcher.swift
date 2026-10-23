import Foundation

// ---------------------------------------------------------------- Chat, Recherche und Arbeitsmodus (aus VYRA.GXCore.cs)
public final class WorkStep {
    public var kind = "", text = "", detail = ""
    public var done = false, failed = false
    public var index = 0
}
public final class WorkTask {
    public var text = ""
    public var web = true
    public var format = "chat"
    public var folder: String?
    public var organize = false
    public var title = ""
    public var think = false
    public var attachments = [Attachment]()
    public init() {}
}
public final class WorkResult {
    public var answer = "", thoughts = ""
    public var usedWeb = false
    public var sources = [SearchHit]()
    public var files = [String]()
    public var moves = [MoveOp]()
    public var problems = [String]()
    public var folder: String?
    public init() {}
}
public final class AskRequest {
    public var question = ""
    public var history = [ChatTurn]()
    public var attachments = [Attachment]()
    public var webMode = "auto"
    public var think = false
    public var style = "normal"
    public var knowledge = ""
    public init() {}
}
public final class Attachment {
    public var name = "", path = "", text = ""
    public var bytes: Int64 = 0
    public var problem = ""
    public init() {}
}

/// Das Herz der VYRA KI: normaler Chat mit Anhaengen, Websuche mit Quellen, Nachdenken, Fortsetzen
/// und der Arbeitsmodus (Dokumente). Gleiche Prompts und Ablaeufe wie unter Windows.
public final class Researcher {
    let brain: ChatBrain
    let files: FileTools
    let docFolder: String
    let baseSystem: String
    public var onStep: ((WorkStep) -> Void)?
    var stepNo = 0
    /// 4.15: true = VYRA Pro lokal (laengere Antworten, mehr Fortsetzungen, laengeres Nachdenken, mehr Quellen).
    public var pro = false
    var proLocal: Bool { pro && brain.local }
    public private(set) var log = [String]()
    let logLock = NSLock()

    public init(_ brain: ChatBrain, _ files: FileTools?, _ docFolder: String, _ baseSystem: String?) {
        self.brain = brain; self.files = files ?? FileTools(nil); self.docFolder = docFolder; self.baseSystem = baseSystem ?? ""
    }
    func begin(_ kind: String, _ text: String) -> WorkStep {
        let s = WorkStep(); s.kind = kind; s.text = text
        logLock.lock(); stepNo += 1; s.index = stepNo; logLock.unlock()
        raise(s); return s
    }
    func raise(_ s: WorkStep) { onStep?(s) }
    func end(_ s: WorkStep, _ detail: String?, _ failed: Bool) {
        s.done = true; s.failed = failed
        if let d = detail { s.detail = d }
        logLock.lock(); log.append(s.kind + ": " + s.text + " " + s.detail + (failed ? " [x]" : "")); logLock.unlock()
        raise(s)
    }

    // Fester Systemprompt (bleibt pro Tag gleich, damit das Modell den Anfang zwischenspeichern kann).
    // Wie gute Antworten aussehen (fuer lokale und Online-Modelle gleich): klar, gegliedert, ohne Fuelltext.
    public static let answerStyle =
        "So sehen deine Antworten aus (übersichtlich wie ein guter Assistent):\n" +
        "- Beginne sofort mit der direkten Antwort. Bei längeren Antworten lautet die erste Zeile: **Kurz gesagt:** <Antwort in 1–2 Sätzen>. Keine Einleitung, keine Wiederholung der Frage.\n" +
        "- Danach nur so viel wie nötig: wenige ## Überschriften (höchstens 4), Absätze mit höchstens 3 Sätzen, Leerzeile zwischen Blöcken.\n" +
        "- Schritte in fester Reihenfolge als nummerierte Liste, Optionen und Punkte als Stichpunkte, Vergleiche mehrerer Dinge als Tabelle.\n" +
        "- Einen wirklich wichtigen Hinweis als Zitatblock: »> **Tipp:** …« oder »> **Achtung:** …« (höchstens einer).\n" +
        "- **Fett** nur für Schlüsselbegriffe und Ergebnisse, nie für ganze Sätze.\n" +
        "- Code immer im Codeblock mit Sprachangabe (z. B. ```python), vollständig und lauffähig; bei mehreren Dateien steht der Dateiname als ### Überschrift darüber. Danach 1–3 Sätze, was er tut und wie man ihn startet.\n" +
        "- Konkret statt allgemein: Zahlen, Namen, Beispiele. Unsicheres kennzeichnest du klar und sagst, wie man es prüft.\n" +
        "- Kein Floskel-Schluss (»Ich hoffe, das hilft«). Höchstens ein kurzer, nützlicher nächster Schritt.\n"

    public static func localPersona(_ deviceInfo: String, _ custom: String, _ style: String = "normal") -> String {
        var b = Platform.personaIntro
        b += "Du hilfst bei allem: Wissen und Erklären (Wissenschaft, Technik, Geschichte, Geografie, Sprache, Alltag, Wirtschaft, Kultur, Sport), Programmieren, Schreiben, Lernen, Planen, Rechnen und Gaming (besonders Fortnite und PC-Leistung).\n"
        b += answerStyle
        b += "Regeln:\n"
        b += "- Ehrlich: Erfinde keine Fakten, Zahlen, Zitate, Links, Bibliotheken oder Programmfunktionen. Wenn du etwas nicht sicher weißt, sag es.\n"
        b += "- Mitgelieferte Nachschlage-Auszüge, Suchergebnisse und Dateien haben Vorrang vor deinem Gedächtnis; belege Aussagen daraus mit [Nummer].\n"
        b += "- Formeln als normaler Text (a² + b² = c²), kein LaTeX.\n"
        b += "- Bei kniffligen Fragen (Mathe, Logik, Code, Planung) denkst du still in Schritten und prüfst das Ergebnis, bevor du antwortest. Einfache Fragen beantwortest du sofort.\n"
        b += "- Nur bei echter Mehrdeutigkeit eine kurze Rückfrage; sonst eine vernünftige Annahme treffen und in einem Satz nennen.\n"
        b += "- VYRA erstellt auf Wunsch Dateien (Word, PDF, Excel, PowerPoint, CSV, ODT, HTML, Markdown, SVG, .ics, .vcf, JSON/XML/YAML, jede Code-Datei), programmiert Apps und liest ZIP-Archive. Sag nie, dass du keine Dateien erstellen kannst. Fotos/PNG nur mit angeschlossenem Bilddienst – sonst SVG anbieten.\n"
        b += Platform.deviceRule
        b += Platform.workshopRule
        b += "- Gespeicherte Gedächtnis-Einträge über den Nutzer nutzt du natürlich und nur, wenn sie zur Frage passen.\n"
        b += "- " + styleHint(style) + "\n"
        b += "Heute ist " + today() + "."
        if !deviceInfo.trimmed.isEmpty { b += "\n" + Platform.deviceLabel + deviceInfo.trimmed }
        let c = custom.trimmed
        if !c.isEmpty { b += "\nHinweise des Nutzers zu sich und zum Antwortstil (immer beachten): " + (c.len > 1500 ? c.sub(0, 1500) : c) }
        return b
    }
    public static func styleHint(_ style: String) -> String {
        if style == "short" { return "Antworte knapp: höchstens etwa 5 Sätze oder 6 Stichpunkte, außer der Nutzer möchte ausdrücklich mehr." }
        if style == "long" { return "Antworte gründlich und vollständig, mit Beispielen, Begründungen und einer kurzen Zusammenfassung am Ende." }
        return "Antworte präzise: zuerst die direkte Antwort, dann nur die nötigen Details – kurz und übersichtlich, ohne Fülltext."
    }
    public static func styleTokens(_ style: String, _ local: Bool) -> Int {
        if style == "short" { return local ? 600 : 900 }
        if style == "long" { return local ? 3200 : 6000 }
        return local ? 1800 : 3000
    }
    public static func today() -> String { DE.longDate() }
    func sys() -> String { baseSystem.containsOrdinal("Heute ist") ? baseSystem : baseSystem + "\nHeute ist " + Researcher.today() + "." }
    /// Vorwaermen: liest den Systemtext einmal ein, damit die erste echte Frage sofort beginnt.
    public func warm(_ token: CancelToken) async throws -> String {
        let o = GenOptions(); o.maxTokens = 1; o.temperature = 0
        return try await brain.complete(sys(), Researcher.one("Hallo"), nil, o, token)
    }
    static func one(_ text: String) -> [ChatTurn] { [ChatTurn("user", text)] }

    // Begruessungen, Dank und sehr kurze Nachrichten brauchen keine Websuche.
    static let rxSmallTalk = "^(hallo|hi|hey|moin|servus|guten (morgen|tag|abend)|danke|dankeschoen|vielen dank|thx|ok|okay|super|cool|tschuess|bye|wie gehts|wie geht es dir|alles klar)\\b[ a-z]{0,20}$"
    public static func isSmallTalk(_ q: String) -> Bool {
        var t = Knowledge.norm(q).trimmed
        t = Rx.replace(t, "\\s+", " ")
        return t.len < 3 || Rx.isMatch(t, rxSmallTalk)
    }
    public static func needsWeb(_ q: String) -> Bool {
        let t = q.trimmed
        if t.len < 4 || isSmallTalk(t) { return false }
        return t.split(separator: " ").count >= 2
    }
    static let rxStrong = "\\b(aktuell\\w*|heute|heutig\\w*|gestern|morgen|derzeit\\w*|momentan\\w*|zurzeit|gerade jetzt|diese[nrsm]? (woche|monat|jahr|saison|season)|neueste\\w*|neuste\\w*|latest|news|nachricht\\w*|schlagzeile\\w*|wetter\\w*|preis\\w*|kostet|kosten|guenstigst\\w*|angebot\\w*|aktienkurs|kurs von|aktie\\w*|boerse\\w*|ergebnis\\w*|spielstand|bundesliga|champions league|wahl\\w*|release|erscheint|erscheinungsdatum|update|patch\\w*|patchnotes|season|saison|chapter|item ?shop|server ?status|serverstatus|ausfall|stoerung|live|turnier\\w*|202[4-9]|203[0-9]|recherchier\\w*|im internet|im netz|googel|google|such\\w* (im|nach|online)|online nach|quelle\\w*|webseite|website|link zu|offizielle seite|wer (ist|sind) .{0,30}(praesident|kanzler|ceo|chef|trainer|weltmeister|meister|champion|minister|buergermeister|papst|koenig)\\w*)\\b"
    static let rxFact = "^(wer (ist|war|sind|hat|hatte|gewann|gewinnt|spielt|leitet|regiert)|wann (ist|war|wurde|kommt|erscheint|startet|beginnt|endet|findet)|wie (alt|gross|hoch|lang|viele|teuer|schwer) (ist|war|sind)|wie viel (kostet|verdient)|wo (liegt|ist|wohnt|spielt)|welche[rsn]? (ist|sind|war|hat) (der|die|das) (beste|groesste|neueste|aktuelle)|gibt es (schon|noch|bereits))"
    static let rxCreative = "^(bitte )?(schreib|formulier|uebersetz|erklaer|erzaehl|dicht|reim|programmier|code|korrigier|verbesser|ueberarbeit|fass|zusammenfass|rechne|berechne|loes|hilf mir (beim|bei der|mit)|mach mir|erstell|entwirf|denk dir|stell dir vor|gib mir ideen|brainstorm|was bedeutet|was heisst|definier)"
    /// 2 = braucht aktuelle Infos aus dem Netz, 1 = Faktenfrage (kleine Modelle irren sich hier oft), 0 = ohne Netz beantwortbar.
    public static func webNeed(_ q: String) -> Int {
        if q.trimmed.isEmpty || isSmallTalk(q) { return 0 }
        if Rx.isMatch(q, "https?://|www\\.[a-z0-9-]+\\.[a-z]{2,}", .i) { return 2 }
        let t = Rx.replace(Knowledge.norm(q), "\\s+", " ").trimmed
        let creative = Rx.isMatch(t, rxCreative)
        if Rx.isMatch(t, rxStrong) {
            return creative && !Rx.isMatch(t, "\\b(aktuell\\w*|neueste\\w*|neuste\\w*|heute|202[4-9]|recherchier\\w*|im internet|quelle\\w*)\\b") ? 0 : 2
        }
        if creative { return 0 }
        if Rx.isMatch(t, rxFact) { return 1 }
        return 0
    }
    /// Waehlt die juengsten Nachrichten, die in das Budget passen. Lange Antworten werden gekuerzt.
    public static func fitHistory(_ history: [ChatTurn], _ maxChars: Int) -> [ChatTurn] {
        var outp = [ChatTurn]()
        var used = 0
        for h in history.reversed() {
            if (h.role != "user" && h.role != "assistant") || h.content.isEmpty { continue }
            var c = h.content
            let cap = h.role == "assistant" ? 2500 : 4000
            if c.len > cap { c = c.sub(0, cap) + " …" }
            if used + c.len > maxChars && !outp.isEmpty { break }
            if used + c.len > maxChars { c = c.sub(0, max(0, maxChars - used)) }
            outp.insert(ChatTurn(h.role, c), at: 0)
            used += c.len
        }
        while let f = outp.first, f.role != "user" { outp.removeFirst() }
        // Abwechselnd user/assistant erzwingen (zwei Nutzernachrichten hintereinander zusammenfassen).
        var merged = [ChatTurn]()
        for t in outp {
            if let last = merged.last, last.role == t.role { last.content += "\n\n" + t.content } else { merged.append(t) }
        }
        return merged
    }
    /// Erstes JSON-Objekt bzw. erste JSON-Liste aus einer Modellantwort lesen (kleine Modelle schreiben oft Text drumherum).
    public static func jsonIn(_ text0: String?) -> Any? {
        guard var text = text0 else { return nil }
        text = text.rep("```json", "").rep("```", "")
        let ca = text.indexOf("{"), la = text.indexOf("[")
        let order: [String] = la >= 0 && (ca < 0 || la < ca) ? ["[", "{"] : ["{", "["]
        for open in order {
            let a = text.indexOf(open)
            if a < 0 { continue }
            let close = open == "{" ? "}" : "]"
            var b = text.lastIndexOf(close)
            while b > a {
                if let v = try? Json.parse(text.sub(a, b - a + 1)) { return v }
                if b == 0 { break }
                b = text.lastIndexOf(close, before: b - 1)
            }
        }
        return nil
    }
    static func obj(_ pairs: (String, Any)...) -> JObject { let o = JObject(); for (k, v) in pairs { o[k] = v }; return o }
    static func strArray(_ min: Int, _ max: Int) -> JObject { obj(("type", "array"), ("items", obj(("type", "string"))), ("minItems", Double(min)), ("maxItems", Double(max))) }
    static func isCode(_ q: String) -> Bool {
        Rx.isMatch(Knowledge.norm(q), "\\b(code|programm\\w*|python|swift|swiftui|kotlin|dart|flutter|rust|golang|javascript|typescript|java|c sharp|csharp|c\\+\\+|powershell|html|css|sql|skript|script|funktion|klasse|bug|fehlermeldung|compiler|regex|api)\\b")
    }
    static let thinkPrompt = "\n\n---\nDenke zuerst gründlich nach, bevor du antwortest. Schreibe NUR deine Überlegungen als knappe Notizen: Was genau ist gefragt? Welche Fakten, Schritte oder Rechenwege braucht es? Rechne Zwischenschritte nach. Wo könnte ein Fehler oder eine Falle stecken? Gib noch KEINE fertige Antwort."

    // ------------------------------------------------ Normaler Chat (mit Anhaengen, optionaler Websuche und Nachdenken)
    public func ask(_ req: AskRequest, _ onText: ((String) -> Void)?, _ onThoughts: ((String) -> Void)?, _ token: CancelToken) async throws -> WorkResult {
        let res = WorkResult()
        let q = req.question.trimmed
        let hasAtt = req.attachments.contains { !$0.text.isEmpty }
        let need = req.webMode == "off" ? 0 : Researcher.webNeed(q)
        let web = req.webMode == "on" ? (Researcher.needsWeb(q) || q.len > 3) : (req.webMode == "auto" && need >= 2)
        res.usedWeb = web
        let total = brain.contextChars
        let outTok = ProLimits.answerTokens(req.style, brain.local, proLocal)
        let room = max(3000, total - Int(Double(outTok) * 2.9) - sys().len - 200)
        var ctx = ""
        if hasAtt {
            let withText = req.attachments.filter { !$0.text.isEmpty }
            let per = max(1500, Int(Double(room) * (web ? 0.35 : 0.6)) / max(1, req.attachments.count))
            ctx += "Angehängte Dateien:\n"
            for a in withText {
                let text = Passages.select(a.text, q, per)
                ctx += "### Datei: " + a.name + (text.len < a.text.len ? " (Auszug)" : "") + "\n" + text.trimmed + "\n\n"
            }
        }
        var notes = ""
        if web {
            let queries = try await self.queries(q, req.history, token)
            let budget = max(2500, Int(Double(room) * (hasAtt ? 0.4 : 0.62)))
            notes = try await gather(queries, proLocal ? (req.think ? ProLimits.webPagesProThink : ProLimits.webPagesPro) : brain.local ? (req.think ? 10 : 6) : 6, budget, q, res, token)
            if !notes.isEmpty { ctx += "Suchergebnisse aus dem Internet (abgerufen am " + Researcher.today() + "):\n" + notes + "\n" }
        }
        if !req.knowledge.trimmed.isEmpty && !web { ctx += "Hintergrund aus den VYRA-Anleitungen (nur verwenden, wenn es zur Nachricht passt):\n" + req.knowledge.trimmed + "\n\n" }
        // 4.14 Wissens-Booster: Bei Wissensfragen holt VYRA in unter 3 Sekunden einen geprueften Lexikon-Auszug (mit Zwischenspeicher).
        var facts = false
        if !web && req.webMode == "auto" && brain.local && !hasAtt && !Researcher.isCode(q) && (need == 1 || KnowledgeBoost.wants(q)) {
            let sk = begin("search", "Wissen nachschlagen")
            do {
                let found = try await KnowledgeBoost.lookup(q, token)
                if !found.isEmpty {
                    ctx += "Nachschlagewerk (Wikipedia-Auszüge, abgerufen " + Researcher.today() + "):\n"
                    var id = 1
                    for f in found {
                        ctx += "[\(id)] " + f.title + ": " + f.text + "\n\n"
                        let h = SearchHit(); h.id = id; h.title = f.title + " – Wikipedia"; h.url = f.url; h.engine = "Wikipedia"
                        res.sources.append(h); id += 1
                    }
                    facts = true
                    end(sk, found.map { $0.title }.joined(separator: " · ") + (found.contains { $0.cached } ? " (gespeichert)" : ""), false)
                } else { end(sk, "kein passender Eintrag", false) }
            } catch {
                if error.isCancellation { if token.isCancelled { throw error }; end(sk, "zu langsam – eigenes Wissen", false) }
                else { end(sk, error.vyraMessage, true) }
            }
        }
        var user = ctx.isEmpty ? q : ctx + "Nachricht des Nutzers: " + q
        if web && !notes.isEmpty { user += "\n\nAnweisung: Beantworte die Nachricht mithilfe der Suchergebnisse. Belege Aussagen aus den Ergebnissen direkt dahinter mit [Nummer], z. B. [1] oder [2][3]. Nenne keine Quellen, die nicht in der Liste stehen. Wenn die Ergebnisse die Frage nicht beantworten oder sich widersprechen, sag das ehrlich und ergänze vorsichtig aus deinem Wissen." }
        else if web { user += "\n\nHinweis: Die Websuche hat nichts Brauchbares geliefert. Antworte aus deinem Wissen und sag kurz dazu, dass keine aktuellen Quellen gefunden wurden." }
        else if facts { user += "\n\nAnweisung: Nutze die Nachschlage-Auszüge für Fakten (Namen, Zahlen, Daten) und belege sie knapp mit [Nummer]. Ergänze nur sicheres Allgemeinwissen. Wenn die Auszüge nicht passen, ignoriere sie." }
        let histBudget = max(1500, min(room - user.len, Int(Double(total) * 0.45)))
        var msgs = Researcher.fitHistory(req.history, histBudget)
        msgs.append(ChatTurn("user", user))
        let opt: GenOptions
        if web { opt = GenOptions(); opt.maxTokens = outTok; opt.temperature = 0.5; opt.topP = 0.85; opt.topK = 20 }
        else if Researcher.isCode(q) { opt = GenOptions(); opt.maxTokens = max(outTok, proLocal ? ProLimits.codeMinTokensPro : 2000); opt.temperature = 0.2; opt.topP = 0.9 }
        else { opt = GenOptions.chat(outTok) }
        if req.think {
            let st = begin("think", "Nachdenken")
            do {
                var tm = Array(msgs.dropLast())
                tm.append(ChatTurn("user", user + Researcher.thinkPrompt))
                res.thoughts = try await brain.complete(sys(), tm, onThoughts, GenOptions.precise(proLocal ? ProLimits.thinkTokensPro : brain.local ? 1024 : 1500), token)
                end(st, nil, false)
                msgs[msgs.count - 1] = ChatTurn("user", user + "\n\n---\nDeine eigenen Vorüberlegungen (der Nutzer sieht sie nicht):\n" + res.thoughts + "\n---\nPrüfe die Vorüberlegungen kritisch, korrigiere Fehler und schreibe jetzt die endgültige Antwort an den Nutzer (ohne die Notizen zu erwähnen).")
            } catch {
                if error.isCancellation { throw error }
                end(st, error.vyraMessage, true)
            }
        }
        if web { let sw = begin("write", "Antwort schreiben"); res.answer = try await brain.complete(sys(), msgs, onText, opt, token); end(sw, nil, false) }
        else { res.answer = try await brain.complete(sys(), msgs, onText, opt, token) }
        var lastContinuation = ""
        var next = msgs
        let maxContinuations = proLocal ? ProLimits.continuationsPro : ProLimits.continuationsStandard
        var continuation = 0
        while continuation < maxContinuations && (brain.lastFinish == "length" || brain.lastFinish == "max_tokens") {
            try token.check()
            let more = begin("write", "Antwort vervollstaendigen (\(continuation + 1)/\(maxContinuations))")
            let prefix = res.answer
            do {
                // Only the immediately preceding piece is added on each turn.
                next.append(ChatTurn("assistant", continuation == 0 ? prefix : lastContinuation))
                next.append(ChatTurn("user", "Setze die abgeschnittene Antwort unmittelbar an der letzten Stelle fort. Wiederhole nichts. Schliesse begonnenen Code und die Aufgabe ab."))
                let cb: ((String) -> Void)? = onText == nil ? nil : { s in onText?(prefix + "\n" + s) }
                let tail = try await brain.complete(sys(), next, cb, opt, token)
                if !ContinuationGuard.hasNewText(prefix, tail) {
                    res.problems.append("Fortsetzung ohne neuen Inhalt gestoppt."); onText?(prefix); end(more, "Wiederholung erkannt", true); break
                }
                lastContinuation = tail
                res.answer = prefix + "\n" + tail
                end(more, nil, false)
            } catch {
                if error.isCancellation { throw error }
                res.problems.append("Fortsetzung: " + error.vyraMessage); onText?(prefix); end(more, error.vyraMessage, true); break
            }
            continuation += 1
        }
        if brain.lastFinish == "length" || brain.lastFinish == "max_tokens" { res.problems.append("Antwortlaengengrenze erreicht. Mit 'Weiter' kann die Aufgabe fortgesetzt werden.") }
        return res
    }
    /// Kompatibel zur alten Oberflaeche.
    public func answerWithWeb(_ question: String, _ history: [ChatTurn], _ onText: ((String) -> Void)?, _ token: CancelToken) async throws -> WorkResult {
        let r = AskRequest(); r.question = question; r.history = history; r.webMode = "on"
        return try await ask(r, onText, nil, token)
    }
    /// Suchanfragen: bei Folgefragen aus dem Verlauf ableiten, sonst die Frage selbst (bereinigt).
    func queries(_ question: String, _ history: [ChatTurn], _ token: CancelToken) async throws -> [String] {
        var outp = [String]()
        let clean = Researcher.cleanQuery(question)
        let follow = !history.isEmpty && (question.len < 28 || Rx.isMatch(" " + Knowledge.norm(question) + " ", " (es|das|der|die|den|dem|dies\\w*|davon|dazu|darueber|er|sie|ihm|ihr|dort|damals|stattdessen|und|auch|noch) "))
        if follow || question.len > 160 {
            let s0 = begin("plan", "Suchbegriffe wählen")
            do {
                var c = ""
                for h in history.suffix(4) { c += (h.role == "user" ? "Nutzer: " : "Antwort: ") + (h.content.len > 400 ? h.content.sub(0, 400) : h.content) + "\n" }
                let prompt = "Gespräch bisher:\n" + c + "\nNeue Nachricht: " + question + "\n\nSchreibe 1 bis 2 Websuchen (je 3 bis 8 Wörter), mit denen man die neue Nachricht beantworten kann. Die Suchen müssen ohne das Gespräch verständlich sein (Namen statt »er«/»es«). Aktuelles Jahr: \(DE.year). Antworte NUR mit JSON: {\"suchanfragen\": [\"...\"]}"
                let o = Researcher.jsonIn(try await brain.complete(sys(), Researcher.one(prompt), nil, GenOptions.structured(Researcher.obj(("type", "object"), ("properties", Researcher.obj(("suchanfragen", Researcher.strArray(1, 2)))), ("required", ["suchanfragen"] as [Any])), 120), token))
                for x in Json.arr(o, "suchanfragen") {
                    let s = Json.text(x).trimmed.trim("\"")
                    if s.len > 2 && s.len < 140 && outp.count < 2 { outp.append(s) }
                }
                end(s0, outp.isEmpty ? "Frage direkt" : outp.joined(separator: " · "), outp.isEmpty)
            } catch {
                if error.isCancellation { throw error }
                end(s0, error.vyraMessage, true)
            }
        }
        if outp.isEmpty { outp.append(clean) }
        return outp
    }
    public static func cleanQuery(_ q: String) -> String {
        var s = q.trimmed
        s = Rx.replace(s, "^(bitte\\s+)?(recherchier\\w*|such\\w*|google\\w*|finde?\\s+(heraus|raus)?|schau\\s+nach|kannst du (mal )?(nachschauen|recherchieren|suchen))\\s*(mal\\s+)?(im (internet|netz|web)\\s*)?(nach\\s+)?(,|:)?\\s*", "", .i)
        s = s.trim(" ?!.")
        if s.len < 3 { s = q.trimmed }
        let n = Knowledge.norm(s)
        if Rx.isMatch(n, "\\b(aktuell\\w*|neueste\\w*|neuste\\w*|derzeit\\w*|diese[nrsm]? (saison|season|jahr))\\b") && !Rx.isMatch(s, "\\b(19|20)\\d\\d\\b") { s += " \(DE.year)" }
        return s.len > 200 ? s.sub(0, 200) : s
    }

    // Suchen (parallel), Seiten lesen (parallel) und die zur Frage passenden Textstellen auswaehlen.
    func gather(_ queries: [String], _ maxPages: Int, _ budget: Int, _ relevance: String, _ res: WorkResult, _ token: CancelToken) async throws -> String {
        let s = begin("search", "Suche: " + queries.joined(separator: " · "))
        let problems = ProblemList()
        let results: [[SearchHit]] = try await withThrowingTaskGroup(of: (Int, [SearchHit]).self) { g in
            for (i, q) in queries.enumerated() { g.addTask { (i, try await self.searchOne(q, token, problems)) } }
            var r = [[SearchHit]](repeating: [], count: queries.count)
            for try await (i, l) in g { r[i] = l }
            return r
        }
        let merged = WebResearch.merge(results)
        // hoechstens zwei Seiten pro Website, damit verschiedene Quellen zu Wort kommen
        var perHost = [String: Int]()
        var cand = [SearchHit]()
        for h in merged {
            let host = WebAddress.display(h.url)
            let n = perHost[host] ?? 0
            if n >= 2 { continue }
            perHost[host] = n + 1
            cand.append(h)
            if cand.count >= maxPages + 3 { break }
        }
        end(s, "\(merged.count) Treffer", merged.isEmpty)
        if merged.isEmpty { if let p = problems.first { res.problems.append(p) }; return "" }
        let texts = PageSlots(cand.count)
        let limit = CancelToken.linked(token)
        limit.cancelAfter(Double(proLocal ? ProLimits.webSecondsPro : brain.local ? 25 : 18))
        let counter = PageCounter()
        let gate = AsyncSemaphore(4)
        let want = min(maxPages, cand.count)
        let readClock = Date()
        let readers = Task {
            await withTaskGroup(of: Void.self) { g in
                for (k, h) in cand.enumerated() { g.addTask { await self.readOne(h, k, texts, gate, limit, token, counter) } }
            }
        }
        // Nicht auf die langsamsten Seiten warten: genug Seiten gelesen (oder nach 5 s mindestens 2) -> sofort weiter.
        while !counter.allDone(cand.count) {
            try token.check()
            let ok = counter.ok
            if ok >= want || (ok >= 2 && Date().timeIntervalSince(readClock) >= 5) { counter.enough = true; limit.cancel(); break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        await readers.value
        try token.check()
        var all = [Passage]()
        for i in 0..<cand.count {
            let parts = Passages.split(texts.text[i] ?? "", 650)
            for j in 0..<min(parts.count, 60) { let p = Passage(); p.source = i; p.order = j; p.text = parts[j]; all.append(p) }
        }
        if all.isEmpty { return "" }
        Passages.score(all, relevance)
        var best = [Int: Double]()
        for p in all { if let v = best[p.source], v >= p.score { continue }; best[p.source] = p.score }
        let top = best.values.max() ?? 0
        // Quellen: nach Suchrang, aber offensichtlich unpassende Seiten (kaum Treffer) weglassen.
        let srcs = best.filter { $0.value >= max(0.6, top * 0.18) || $0.key < 2 }.map { $0.key }.sorted().prefix(maxPages)
        var chosen = [Passage]()
        var used = 0
        for src in srcs {
            if let p = all.filter({ $0.source == src }).max(by: { $0.score < $1.score }) { chosen.append(p); used += p.text.len + 20 }
        }
        let srcSet = Set(srcs)
        for p in all.filter({ srcSet.contains($0.source) && !chosen.contains(where: { c in c === $0 }) }).sorted(by: { $0.score > $1.score }) {
            if p.score <= 0.05 { break }
            if chosen.filter({ $0.source == p.source }).count >= 4 { continue }
            if used + p.text.len > budget { continue }
            chosen.append(p); used += p.text.len + 8
        }
        var sb = ""
        for src in srcs {
            let h = cand[src]
            h.id = res.sources.count + 1
            if let t = texts.title[src], !t.isEmpty, h.title.isEmpty { h.title = t }
            if h.title.isEmpty { h.title = WebAddress.display(h.url) }
            res.sources.append(h)
            sb += "[\(h.id)] " + h.title + " – " + WebAddress.display(h.url) + "\n"
            sb += chosen.filter { $0.source == src }.sorted { $0.order < $1.order }.map { $0.text.trimmed }.joined(separator: "\n…\n") + "\n\n"
        }
        return sb.len > budget + 600 ? sb.sub(0, budget + 600) : sb
    }
    func searchOne(_ q: String, _ token: CancelToken, _ problems: ProblemList) async throws -> [SearchHit] {
        do { return try await WebResearch.search(q, 8, token) }
        catch {
            if error.isCancellation && token.isCancelled { throw error }
            problems.add(error.vyraMessage); return []
        }
    }
    func readOne(_ h: SearchHit, _ k: Int, _ slots: PageSlots, _ gate: AsyncSemaphore, _ limit: CancelToken, _ token: CancelToken, _ counter: PageCounter) async {
        let r = begin("read", "Lese: " + (h.title.len > 60 ? h.title.sub(0, 60) + "…" : h.title))
        defer { counter.finish() }
        if WebResearch.isSnippetOnly(h.url) {
            let t: String? = h.snippet.len >= 60 ? h.snippet : nil
            slots.set(k, t, nil)
            end(r, t != nil ? "nur Suchtext" : "übersprungen", t == nil)
            return
        }
        var entered = false
        do {
            try await gate.wait(limit)
            entered = true
            let page = try await WebResearch.read(h.url, 60000, limit)
            if page.unreadable || page.text.len < 150 {
                if h.snippet.len >= 60 { slots.set(k, h.snippet, nil); end(r, "nur Suchtext (" + (page.problem.isEmpty ? "kein Text" : page.problem) + ")", false) }
                else { end(r, page.problem.isEmpty ? "kein Text" : page.problem, true) }
                if entered { await gate.signal() }
                return
            }
            slots.set(k, page.text, page.title)
            counter.success()
            end(r, WebAddress.display(h.url), false)
        } catch {
            if error.isCancellation {
                if h.snippet.len >= 60 { slots.set(k, h.snippet, nil) }
                if token.isCancelled { end(r, "abgebrochen", true) }
                else if counter.enough { end(r, "nicht mehr nötig (genug Quellen)", false) }
                else { end(r, "zu langsam – übersprungen", true) }
            } else { end(r, error.vyraMessage, true) }
        }
        if entered { await gate.signal() }
    }
}

// ------------------------------------------------ Hilfen fuer das parallele Lesen
final class ProblemList: @unchecked Sendable {
    private let lock = NSLock()
    private var items = [String]()
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var first: String? { lock.lock(); defer { lock.unlock() }; return items.first }
}
final class PageSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String?]
    private var titles: [String?]
    init(_ n: Int) { texts = Array(repeating: nil, count: n); titles = Array(repeating: nil, count: n) }
    func set(_ i: Int, _ t: String?, _ title: String?) { lock.lock(); texts[i] = t; if title != nil { titles[i] = title }; lock.unlock() }
    var text: [String?] { lock.lock(); defer { lock.unlock() }; return texts }
    var title: [String?] { lock.lock(); defer { lock.unlock() }; return titles }
}
final class PageCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var okCount = 0, finished = 0
    private var enoughFlag = false
    var ok: Int { lock.lock(); defer { lock.unlock() }; return okCount }
    var enough: Bool {
        get { lock.lock(); defer { lock.unlock() }; return enoughFlag }
        set { lock.lock(); enoughFlag = newValue; lock.unlock() }
    }
    func success() { lock.lock(); okCount += 1; lock.unlock() }
    func finish() { lock.lock(); finished += 1; lock.unlock() }
    func allDone(_ n: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return finished >= n }
}
/// Begrenzt gleichzeitige Seitenaufrufe (wie `SemaphoreSlim(4)`).
public actor AsyncSemaphore {
    private var count: Int
    private var waiters: [(id: Int, c: CheckedContinuation<Bool, Never>)] = []
    private var next = 0
    public init(_ n: Int) { count = n }
    /// Wartet auf einen Platz; wirft bei Abbruch.
    public func wait(_ token: CancelToken) async throws {
        try token.check()
        if count > 0 { count -= 1; return }
        next += 1
        let id = next
        let cid = token.register { [weak self] in Task { await self?.cancelWaiter(id) } }
        let got = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in waiters.append((id, c)) }
        token.unregister(cid)
        if !got { throw VyraError.cancelled }
    }
    private func cancelWaiter(_ id: Int) {
        if let i = waiters.firstIndex(where: { $0.id == id }) { let w = waiters.remove(at: i); w.c.resume(returning: false) }
    }
    public func signal() {
        if waiters.isEmpty { count += 1 } else { waiters.removeFirst().c.resume(returning: true) }
    }
}
