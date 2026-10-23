import Foundation

/// Zusatzkarten unter einer Antwort (wie `AppCard`, `ZipCard`, `MoveCard` im Windows-KI-Fenster).
public enum TurnCard {
    case app(AppProject)
    case zip([(String, String)], String)
    case moves([MoveOp], FileTools, String)
}

/// Anzeige einer Antwort (wie `MessageView`). Alle Aufrufe koennen aus Hintergrund-Threads kommen;
/// die Oberflaeche leitet sie selbst auf den Haupt-Thread um.
public protocol TurnView: AnyObject {
    var message: ChatMessage { get }
    /// Aktueller (auch noch nicht fertiger) Text, wie `MessageView.CurrentText`.
    var currentText: String { get }
    func setStatus(_ text: String?)
    func step(_ s: WorkStep)
    func setMarkdown(_ md: String)
    func setThoughts(_ text: String)
    /// role: "Info" | "Warning" | "Success" | "Danger"
    func addNote(_ text: String, _ role: String)
    func addFile(_ path: String)
    func addCard(_ card: TurnCard)
    func showSources()
    func startClock(_ eta: EtaTracker)
    func setError(_ text: String)
    func finish(_ meta: String)
}

/// Herzstueck des KI-Fensters (aus `AiPanel` in VYRA.GX.cs ohne die Windows-Oberflaeche): Modellwahl, eine Chat-Runde mit
/// Gedaechtnis, Rechnen, Recherche, Nachdenken, Arbeitsmodus, App-Studio, Buch-Studio, Bildern, Code-Pruefung und Zeitbudget.
public final class KiAssistant {
    public let paths: VyraPaths
    public let settings: Settings
    public let store: ChatStore
    public let knowledge: KnowledgeBase
    public let small: KiModelEngine?, large: KiModelEngine?, pro: KiModelEngine?
    public let engineError: String?
    public let times: TaskTimes
    public private(set) var recall: RecallStore?
    public private(set) var recallError: String?
    public private(set) var memory: MemoryBook?
    public private(set) var memoryError: String?
    public private(set) var learning: LearningStore?
    public private(set) var learningError: String?
    public private(set) var webSkills: WebSkillLibrary?
    public private(set) var webSkillError: String?
    public var threads = [ChatThread]()
    /// Kurzbeschreibung des Geraets fuer den Systemtext (unter Windows: PC-Daten).
    public var deviceInfo = ""
    /// Arbeitsmodus: gewaehltes Dateiformat, freigegebener Ordner und »Ordnen« (unter Windows Auswahlfelder im Eingabebereich).
    public var workFolder: String?
    public var workOrganize = false
    /// Freigegebene Ordner (iOS: per Dateiauswahl freigegeben, mit Sicherheits-Lesezeichen).
    public var approvedFolders: () -> [String] = { [] }

    // Mehrere Chats gleichzeitig: jede laufende Antwort gehoert zu ihrem Chat.
    let lock = NSLock()
    @discardableResult func sync<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    var runs = [String: CancelToken]()
    var runDeadlines = [String: Date]()
    var runReasons = [String: String]()
    var attMemory = [ObjectIdentifier: [Attachment]]()
    var statusSinks = [String: (String) -> Void]()
    var preloadToken: CancelToken?
    public private(set) var lastUse = Date()
    public private(set) var downloading = false

    // Rueckmeldungen an die Oberflaeche
    public var onRunsChanged: (() -> Void)?
    public var onEngineStatus: ((String) -> Void)?
    public var onToast: ((String) -> Void)?
    public var onTurnFinished: ((ChatThread, ChatMessage) -> Void)?
    // Sprachmodus (iOS: SFSpeechRecognizer/AVSpeechSynthesizer in der App)
    /// true = Sprachmodus ist fuer diesen Chat offen und hoert zu
    public var voiceListening: ((ChatThread) -> Bool)?
    /// Beginnt das Vorlesen waehrend des Schreibens; liefert true, wenn gestreamt wird.
    public var voiceBeginStream: ((ChatThread) -> Bool)?
    public var voiceFeed: ((ChatThread, String) -> Void)?
    /// Antwort fertig (streamed = es wurde bereits waehrend des Schreibens vorgelesen)
    public var voiceAnswer: ((ChatThread, ChatMessage, Bool) -> Void)?

    public init(paths: VyraPaths, small: KiModelEngine?, large: KiModelEngine?, pro: KiModelEngine?, engineError: String?) {
        self.paths = paths
        DocWriter.defaultFolder = paths.results
        settings = Settings(paths.settingsFile)
        store = ChatStore(FS.join(paths.ki, "Chats"))
        knowledge = KnowledgeBase.bundled()
        times = TaskTimes(paths.data)
        self.small = small; self.large = large; self.pro = pro; self.engineError = engineError
        if !["small", "large", "pro"].contains(settings.get("bot.localModel", "large")) { settings.set("bot.localModel", "large") }
        // Ohne gespeicherte Wahl: OpenAI/Claude, wenn ein Schluessel vorhanden ist, sonst VYRA KI.
        if settings.get("bot.mode", "").isEmpty {
            let fb = !apiKeyFor("openai").isEmpty ? "openai" : !apiKeyFor("claude").isEmpty ? "claude" : "local"
            settings.set("bot.mode", fb); trySave()
        }
        if !["quick", "local", "openai", "claude"].contains(settings.get("bot.mode", "local")) { settings.set("bot.mode", "local"); trySave() }
        threads = store.loadAll()
        for e in [small, large, pro].compactMap({ $0 }) { e.onStatus = { [weak self] s in self?.engineStatus(s) } }
        initUpgrades()
    }
    func engineStatus(_ s: String) {
        onEngineStatus?(s)
        let sinks = sync { Array(statusSinks.values) }
        for f in sinks { f(s) }
    }
    public func trySave() { _ = try? settings.save() }
    public var mode: String { settings.get("bot.mode", "local") }
    /// Gewaehltes lokales Modell mit den Einstellungen des Nutzers (wie `Engine()`). Turbo (spekulatives Dekodieren) gibt es auf dem iPhone nicht.
    public func engine() -> KiModelEngine? {
        let lm = settings.get("bot.localModel", "large")
        var e = lm == "small" ? small : lm == "pro" ? (pro ?? large) : large
        if e == nil { e = small ?? large }
        if let e = e {
            e.cpuContextChars = settings.getBool("bot.cpuContextExtended", false) ? 10000 : 7000
            e.useGpu = settings.getBool("bot.gpu", true)
            e.loraPath = settings.get("bot.lora." + e.model.file, "")
            e.contextOverride = 0; e.fullContext = false
            if e === pro && e.model.isPro {
                e.contextOverride = ProLimits.context(settings.getInt("bot.proCtx", ProLimits.contextDefault, 8192, ProLimits.contextMax))
                e.fullContext = settings.getBool("bot.proFullContext", true)
            }
        }
        return e
    }
    public var proSelected: Bool { mode == "local" && settings.get("bot.localModel", "large") == "pro" && pro != nil && pro!.model.isPro }
    public func pendingBook(_ t: ChatThread?) -> BookPlan? {
        guard let t = t else { return nil }
        let f = settings.get("book.thread." + t.id, "")
        if f.isEmpty { return nil }
        guard let p = BookPlan.load(f), !p.finished else { return nil }
        return p
    }
    /// iOS: unterbrochene Arbeitsauftraege (Dokumente) werden je Chat gesichert und koennen fortgesetzt werden.
    func workCheckpointPath(_ t: ChatThread) -> String { FS.join(paths.ki, "Auftraege", t.id + ".json") }
    public func pendingWork(_ t: ChatThread?) -> WorkCheckpoint? {
        guard let t = t, let c = WorkCheckpoint.load(workCheckpointPath(t)), c.done > 0, c.done < c.outline.count else { return nil }
        return c
    }
    public func localName() -> String { let lm = settings.get("bot.localModel", "large"); return lm == "small" ? "VYRA KI Mini" : lm == "pro" && pro != nil ? "VYRA KI Pro" : "VYRA KI" }
    public func quickAnswer(_ q: String) -> String { knowledge.answer(q) }
    public func apiKeyFor(_ provider: String) -> String { SecretStore.get(provider + ".key") }
    public func setApiKey(_ provider: String, _ key: String) { SecretStore.set(provider + ".key", key.trimmed) }
    public func cloudModel(_ mode: String) -> String { settings.get(mode + ".model", mode == "claude" ? CloudChat.claudeModels[0] : CloudChat.openAiModels[0]) }
    public var webMode: String { settings.get("work.webmode", settings.getBool("work.web.local", true) ? "auto" : "off") }
    public var think: Bool { settings.getBool("work.think", false) }
    public var work: Bool { settings.get("work.mode", "chat") == "work" }
    public var appMode: Bool { settings.get("work.mode", "chat") == "app" }
    public static let workFormats: [(String, String)] = [("chat", "Ergebnis im Chat"), ("docx", "Word-Datei (.docx)"), ("md", "Textdatei (.md)"), ("pdf", "PDF-Datei (.pdf)"), ("pptx", "PowerPoint (.pptx)"), ("xlsx", "Excel-Tabelle (.xlsx)"), ("odt", "OpenDocument (.odt)"), ("html", "Webseite (.html)"), ("csv", "CSV-Tabelle (.csv)"), ("txt", "Text (.txt)")]
    public var workFormat: String {
        get { let f = settings.get("work.format", "chat"); return KiAssistant.workFormats.contains { $0.0 == f } ? f : "chat" }
        set { settings.set("work.format", newValue); trySave() }
    }

    // ------------------------------------------------ Gedaechtnis, Lernen (aus InitUpgrades/InitMemory)
    public var recallEnabled: Bool { recall != nil && settings.getBool("bot.memory", true) }
    public var memoryOn: Bool { memory != nil && settings.getBool("bot.memory", true) }
    public var memoryAuto: Bool { memoryOn && settings.getBool("bot.memory.auto", true) }
    public var autoLearning: Bool { recallEnabled && learning != nil && settings.getBool("bot.learn", true) }
    public var internetLearning: Bool { recallEnabled && webSkills != nil && settings.getBool("bot.weblearn", true) }
    func initUpgrades() {
        do { learning = try LearningStore(paths.data, SecretStore.protect, SecretStore.unprotect) } catch { learningError = error.vyraMessage }
        do { webSkills = try WebSkillLibrary(paths.data, SecretStore.protect, SecretStore.unprotect) } catch { webSkillError = error.vyraMessage }
        do {
            recall = try RecallStore(paths.data, SecretStore.protect, SecretStore.unprotect)
            if recallEnabled { recall!.rebuild(threads) }
        } catch { recallError = error.vyraMessage }
        KnowledgeBoost.configure(paths.data)
        let m = MemoryBook(paths.data, SecretStore.protect, SecretStore.unprotect)
        memory = m
        if !m.loadProblem.isEmpty { memoryError = m.loadProblem }
        // Notizen aus 4.13 ("Merke dir: ...") einmalig ins neue Gedaechtnis uebernehmen
        if let r = recall, !settings.getBool("bot.memory.imported", false) {
            let notes = r.allNotes()
            if !notes.isEmpty { m.importNotes(notes); try? r.clearNotes() }
            settings.setBool("bot.memory.imported", true); trySave()
        }
    }
    public func profileFor(_ question: String) -> String {
        let profile = settings.get("bot.profile", "auto")
        if profile != "auto" { return profile }
        let norm = Knowledge.norm(question)
        if Rx.isMatch(norm, "buchhalt|rechnungswesen|soll und haben|kontenrahmen|belegverwalt|journalbuch") { return "accounting" }
        if Rx.isMatch(norm, "spielmod|modding|offline.?cheat|debug.?menue") { return "games" }
        return "code"
    }
    /// Stabiler Block im Systemtext: Was VYRA ueber dich weiss (gleiche Reihenfolge = schneller Zwischenspeicher im Modell).
    public func memoryPrompt(_ local: Bool) -> String {
        guard memoryOn, let m = memory else { return "" }
        let p = m.profile(local ? 900 : 2400)
        if p.isEmpty { return "" }
        return "\n\nGEDÄCHTNIS (vom Nutzer bestätigte Fakten, nutze sie natürlich und nur wenn passend; nie erfinden, nie ungefragt alles aufzählen):\n" + p
    }
    /// "Merke dir ...", "Vergiss ...", "Was weisst du ueber mich?" direkt beantworten.
    func memoryCommand(_ q: String, _ th: ChatThread, _ view: TurnView) -> Bool {
        let am = view.message
        if let text = MemoryBook.isRememberCommand(q) {
            if !memoryOn || !th.recall { am.content = "Das Gedächtnis ist ausgeschaltet. Du kannst es unter Einstellungen → Gedächtnis einschalten." }
            else {
                do { let f = try memory!.add(text, MemoryBook.guess(text), "Auf deinen Wunsch", nil); am.content = "**Gemerkt.** " + f.text + "\n\n> **Tipp:** Unter *Gedächtnis* in den Einstellungen kannst du alles ansehen, ändern oder löschen." }
                catch { am.content = "Konnte nicht gespeichert werden: " + error.vyraMessage }
            }
            am.meta = "Gedächtnis"; view.setMarkdown(am.content); view.finish(am.meta); return true
        }
        if let (what, all) = MemoryBook.isForgetCommand(q) {
            if let m = memory {
                if all { let n = m.count; try? m.clear(); am.content = "**Erledigt.** Ich habe alle \(n) gespeicherten Fakten vergessen." }
                else { let gone = (try? m.forget(what)) ?? []; am.content = gone.isEmpty ? "Dazu habe ich nichts gespeichert (»" + what + "«)." : "**Vergessen:**\n" + gone.map { "- " + $0.text }.joined(separator: "\n") }
            } else { am.content = "Das Gedächtnis ist nicht verfügbar." }
            am.meta = "Gedächtnis"; view.setMarkdown(am.content); view.finish(am.meta); return true
        }
        if MemoryBook.isRecallQuestion(q), let m = memory {
            am.content = memoryOn ? m.describe() : "Das Gedächtnis ist ausgeschaltet."
            am.meta = "Gedächtnis"; view.setMarkdown(am.content); view.finish(am.meta); return true
        }
        return false
    }
    func observeMemory(_ q: String, _ th: ChatThread, _ view: TurnView) {
        guard memoryAuto, th.recall, let m = memory else { return }
        let got = m.observe(q, th.id)
        if !got.isEmpty { view.addNote("Gemerkt: " + got.map { $0.text }.joined(separator: "; ") + " (änderbar unter Gedächtnis)", "Info") }
    }
    func vyraContext(_ q: String) -> String {
        let hits = knowledge.search(q, 2)
        if hits.isEmpty || hits[0].score < 2.6 { return "" }
        if !Rx.isMatch(Knowledge.norm(q), "\\b(vyra|fortnite|fps|ruckel\\w*|lag\\w*|ping|hud|crosshair\\w*|fadenkreuz|booster|optimier\\w*|grafik\\w*|einstellung\\w*|browser|design\\w*|backup\\w*|bereinigung|treiber|nvidia|automatik|scanner|stotter\\w*|zocken|gaming|spiel\\w*)\\b") { return "" }
        return knowledge.context(q, 1500)
    }

    // ------------------------------------------------ Laufende Auftraege
    public var anyBusy: Bool { sync { !runs.isEmpty || downloading } }
    public func isRunning(_ t: ChatThread?) -> Bool { guard let t = t else { return false }; return sync { runs[t.id] != nil } }
    public func stop(_ t: ChatThread?, reason: String = "user") {
        guard let t = t else { return }
        let c: CancelToken? = sync { let c = runs[t.id]; if c != nil { runReasons[t.id] = reason }; return c }
        c?.cancel()
    }
    public func stopAllRuns(reason: String = "user") {
        let all: [String: CancelToken] = sync { for k in runs.keys { runReasons[k] = reason }; return runs }
        for c in all.values { c.cancel() }
    }
    /// Laufenden Auftrag verlaengern (Standard +10 Minuten, Pro +60 Minuten).
    @discardableResult public func extendCurrentWork(_ t: ChatThread?) -> String {
        guard let t = t else { return "In diesem Chat läuft kein verlängerbarer Auftrag." }
        let add = proSelected ? ProLimits.extendMinutesPro : 10
        let found: (CancelToken, Date)? = sync {
            guard let active = runs[t.id], !active.isCancelled, let deadline = runDeadlines[t.id], deadline > Date() else { return nil }
            let extended = deadline.addingTimeInterval(Double(add * 60))
            runDeadlines[t.id] = extended
            return (active, extended)
        }
        guard let (active, extended) = found else { return "In diesem Chat läuft kein verlängerbarer Auftrag." }
        active.cancelAfter(extended.timeIntervalSinceNow)
        return "Zeitbudget um \(add) Minuten verlängert."
    }
    /// iOS: Beim Wechsel in den Hintergrund darf das lokale Modell nicht auf der Grafikeinheit weiterrechnen.
    /// Laufende lokale Auftraege werden sauber unterbrochen; Buch und Arbeitsauftraege sind gesichert und lassen sich fortsetzen.
    public func enterBackground() {
        let local: [CancelToken] = sync { var l = [CancelToken](); for (k, v) in runs where runReasons[k] == nil && runIsLocal[k] == true { runReasons[k] = "background"; l.append(v) }; return l }
        for c in local { c.cancel() }
        preloadToken?.cancel()
    }
    var runIsLocal = [String: Bool]()

    // ------------------------------------------------ Senden
    /// Neue Frage im Chat (aus `SendText`). makeView legt die Anzeige fuer die Antwort an.
    public func send(_ text: String, _ atts: [Attachment], in th: ChatThread, makeView: (ChatMessage) -> TurnView) async {
        if isRunning(th) { return }
        var q = text.trimmed
        if q.isEmpty && atts.isEmpty { return }
        if q.isEmpty { q = "Bitte sieh dir die angehängten Dateien an und fasse das Wichtigste zusammen." }
        let um = ChatMessage("user", q)
        for a in atts { um.attachments.append(a.name) }
        if th.messages.isEmpty { th.title = ChatStore.makeTitle(q); th.created = Date() }
        th.messages.append(um)
        sync { attMemory[ObjectIdentifier(um)] = atts }
        let am = ChatMessage("assistant")
        th.messages.append(am)
        if !threads.contains(where: { $0 === th }) { threads.insert(th, at: 0) }
        let view = makeView(am)
        await runTurn(th, um, atts, view)
    }
    /// Antwort neu erzeugen (aus `Regenerate`).
    public func regenerate(_ th: ChatThread, _ answer: ChatMessage, makeView: (ChatMessage) -> TurnView) async {
        if isRunning(th) { return }
        guard let idx = th.messages.firstIndex(where: { $0 === answer }), idx >= 1 else { return }
        let um = th.messages[idx - 1]
        if um.role != "user" { return }
        let atts: [Attachment] = sync { attMemory[ObjectIdentifier(um)] ?? [] }
        truncate(th, idx)
        let am = ChatMessage("assistant")
        th.messages.append(am)
        await runTurn(th, um, atts, makeView(am))
    }
    /// Nachrichten ab index entfernen (Bearbeiten/Neu erzeugen).
    public func truncate(_ th: ChatThread, _ index: Int) {
        if index < 0 || index >= th.messages.count { return }
        th.messages.removeSubrange(index...)
        saveThread(th)
    }
    public func saveThread(_ th: ChatThread) {
        if th.messages.isEmpty { return }
        try? store.save(th)
        if recallEnabled { recall?.update(th) }
    }
    public func deleteThread(_ th: ChatThread) {
        stop(th)
        threads.removeAll { $0 === th }
        store.delete(th.id)
        recall?.remove(th.id)
        settings.remove("book.thread." + th.id); trySave()
        FS.delete(workCheckpointPath(th))
    }

    // ------------------------------------------------ Eine Runde (aus `RunTurn`)
    final class TurnState { var kind = "chat"; var startCost = 0.0; var startSecs = 0.0 }
    public func runTurn(_ th: ChatThread, _ um: ChatMessage, _ atts: [Attachment], _ view: TurnView) async {
        var q = um.content
        let mode = self.mode
        let am = view.message
        let clock = Date()
        func elapsed() -> Double { Date().timeIntervalSince(clock) }
        // Zeitanzeige: Art der Aufgabe -> erwartete Dauer (aus frueheren Laeufen auf diesem Geraet)
        let eta = EtaTracker()
        let localMode = mode == "local"
        let style0 = settings.get("bot.style", "normal")
        let st = TurnState(); st.kind = think ? "think" : "chat"
        let times = self.times
        let plan: (String, Bool) -> Void = { k, answerStream in st.kind = k; let key = TaskTimes.key(localMode, k); eta.plan(k, st.startCost + times.seconds(key), times.chars(key + ":" + style0), answerStream) }
        let record: () -> Void = { let key = TaskTimes.key(localMode, st.kind); let sf = st.kind == "chat" || st.kind == "web" || st.kind == "think"; times.record(key, elapsed() - st.startSecs, am.content.len, sf ? key + ":" + style0 : nil) }
        let proSel = mode == "local" && proSelected
        let budgetMinutes = proSel ? settings.getInt("bot.proMinutes", ProLimits.chatMinutesDefault, ProLimits.chatMinutesMin, ProLimits.chatMinutesMax) : settings.getInt("bot.minutes", 10, 5, 30)
        let cts = CancelToken()
        cts.cancelAfter(Double(budgetMinutes * 60))
        sync { runs[th.id] = cts; runDeadlines[th.id] = Date().addingTimeInterval(Double(budgetMinutes * 60)); runReasons[th.id] = nil; runIsLocal[th.id] = localMode }
        onRunsChanged?()
        lastUse = Date()
        var engine: KiModelEngine?
        var voiceStreaming = false
        KeepAwake.enter() // 4.15: kein Energiesparmodus (iOS: keine automatische Bildschirmsperre), solange VYRA arbeitet
        defer {
            sync { statusSinks[th.id] = nil; runs[th.id] = nil; runDeadlines[th.id] = nil; runReasons[th.id] = nil; runIsLocal[th.id] = nil }
            KeepAwake.exit()
            lastUse = Date()
            th.updated = Date()
            saveThread(th)
            onRunsChanged?()
            voiceAnswer?(th, am, voiceStreaming)
            onTurnFinished?(th, am)
        }
        do {
            if atts.isEmpty && memory != nil && memoryCommand(q, th, view) { return }
            if atts.isEmpty && memory == nil, let note = RecallStore.isRememberCommand(q) {
                if !recallEnabled || !th.recall { am.content = "Das Gedaechtnis ist fuer diesen Chat ausgeschaltet. Du kannst es in den Einstellungen bzw. im Chatmenue aktivieren." }
                else { _ = try? recall!.remember(note); am.content = "Gemerkt: " + note }
                am.meta = "Gedaechtnis"; view.finish(am.meta); return
            }
            if atts.isEmpty { observeMemory(q, th, view) }
            if autoLearning && th.recall && atts.isEmpty, let l = learning {
                let idx = th.messages.firstIndex { $0 === um } ?? th.messages.count
                let changes = l.observe(q, th.id, th.messages.prefix(idx).contains { $0.role == "assistant" && $0.error.isEmpty })
                if !changes.isEmpty { view.addNote("Automatisch gelernt: " + changes.joined(separator: "; ") + ".", "Info") }
            }
            if atts.isEmpty && ImageWork.wants(q) && settings.get("bot.image", "auto") != "svg" && !apiKeyFor("openai").isEmpty,
               (try? ImageWork.choose(settings.get("bot.image", "auto"), q, true)) == "openai" {
                try await finishPicture(nil, q, view, cts); return
            }
            let study = SkillRules.explicit(q)
            if study != nil && mode == "quick" { am.content = "Zum Internet-Lernen oben ein VYRA- oder Online-Chatmodell statt Schnellhilfe waehlen."; am.meta = "Lernauftrag"; view.finish(am.meta); return }
            if atts.isEmpty, let converted = UnitTools.tryAnswer(q) { am.content = converted; am.meta = "Direkt umgerechnet"; view.finish(am.meta); return }
            if atts.isEmpty && Calc.looksLikeMath(q), let v = try? Calc.eval(q) {
                am.content = q.trimEnd("?= ") + " = **" + Calc.format(v) + "**"; am.meta = "Exakt berechnet"; view.finish(am.meta); return
            }
            if mode == "quick" { am.content = knowledge.answer(q); am.meta = "Schnellhilfe"; view.finish(am.meta); return }
            view.setStatus("Denkt nach"); plan(st.kind, true); view.startClock(eta)
            var brain: ChatBrain
            let claudeWeb = mode == "claude" && settings.getBool("claude.web", false)
            if mode == "openai" || mode == "claude" {
                let c = CloudChat(); c.provider = mode; c.apiKey = apiKeyFor(mode); c.model = cloudModel(mode); c.webSearch = claudeWeb
                if c.apiKey.isEmpty { throw VyraError("Für " + (mode == "claude" ? "Claude" : "OpenAI") + " fehlt der API-Schlüssel. In den Einstellungen eintragen – oder im Modellmenü »VYRA KI« wählen (lokal, ohne Schlüssel).", .invalidOperation) }
                brain = CloudBrain(c)
            } else {
                guard let e = self.engine() else { throw VyraError(engineError ?? "VYRA KI ist nicht verfügbar.", .invalidOperation) }
                engine = e
                if !e.modelInstalled { throw VyraError("VYRA KI braucht einmalig das Sprachmodell (" + DE.fixed(Double(e.model.bytes) / 1e9, 1) + " GB). Tippe auf »Einrichten« oder öffne die Einstellungen. Danach läuft alles ohne Schlüssel und kostenlos.", .invalidOperation) }
                if !e.running || e.starting {
                    st.startCost = times.seconds("lokal:start"); plan(st.kind, true)
                    sync { statusSinks[th.id] = { s in view.setStatus(KiAssistant.short(s).trimEnd(". …")) } }
                    view.setStatus(e.starting ? KiAssistant.short(e.statusText).trimEnd(" …") : "VYRA KI startet")
                }
                try await e.ensureStarted(cts)
                if st.startCost > 0 { st.startSecs = elapsed(); times.record("lokal:start", st.startSecs, 0, nil); st.startCost = st.startSecs; plan(st.kind, true) }
                sync { statusSinks[th.id] = nil }
                view.setStatus("Denkt nach")
                brain = LocalBrain(e)
            }
            let proRun = brain.local && engine != nil && engine === pro && engine!.model.isPro
            var studyBrain: ChatBrain = brain
            if mode == "claude" && claudeWeb { let c = CloudChat(); c.provider = mode; c.apiKey = apiKeyFor(mode); c.model = cloudModel(mode); c.webSearch = false; studyBrain = CloudBrain(c) }
            let voiceOn = voiceListening?(th) ?? false
            var style = settings.get("bot.style", "normal")
            if autoLearning && th.recall, let l = learning { style = l.preferredStyle(style) }
            if voiceOn { style = "short" }
            let custom = settings.get("bot.custom", "")
            var sys = brain.local ? Researcher.localPersona(deviceInfo, custom, style) : CloudChat.fullPrompt("", deviceInfo, custom) + "\n" + Researcher.styleHint(style)
            sys += "\n" + EngineeringProfile.system(profileFor(q))
            if proRun { sys += "\n" + ProLimits.persona }
            if th.recall { sys += memoryPrompt(brain.local) }
            if autoLearning && th.recall, let l = learning { sys += "\n" + l.instructions() }
            if recallEnabled && th.recall, let r = recall {
                let learned = autoLearning ? (learning?.context(q, brain.local ? 600 : 1800) ?? "") : ""
                let recalled = r.context(q, th.id, (brain.local ? 1800 : 5000) - learned.len) + "\n" + learned
                // Windows prueft hier die Laenge inkl. Zeilenumbruch (immer > 0); auf dem iPhone nur echte Erinnerungen anzeigen.
                if !recalled.trimmed.isEmpty { brain = RecallBrain(brain, recalled); view.addNote("Passende Erinnerungen werden beruecksichtigt.", "Info") }
            }
            let files = FileTools(approvedFolders())
            func makeResearcher(_ b: ChatBrain) -> Researcher {
                let r = Researcher(b, files, DocWriter.defaultFolder, sys); r.pro = proRun
                r.onStep = { s in if s.kind == "search" && st.kind == "chat" { plan("web", true) }; view.step(s) }
                return r
            }
            var r = makeResearcher(brain)
            var history = [ChatTurn]()
            let ui = th.messages.firstIndex { $0 === um } ?? 0
            for i in 0..<ui { let m = th.messages[i]; if m.error.isEmpty && !m.content.trimmed.isEmpty { history.append(ChatTurn(m.role, m.content)) } }
            voiceStreaming = voiceOn && settings.getBool("voice.stream", true) && (voiceBeginStream?(th) ?? false)
            let streaming = voiceStreaming
            let stream: (String) -> Void = { [weak self] s in view.setMarkdown(s); if streaming { self?.voiceFeed?(th, s) } }
            let thoughts: (String) -> Void = { s in view.setThoughts(s) }
            let thinkNow = think && !voiceOn
            let webMode = claudeWeb ? "off" : settings.get("work.webmode", "auto")
            // Aufgabe erkennen: App bauen/aendern, Buch, Dokument erstellen oder normal antworten.
            var route: String?
            var hasProject = !th.project.isEmpty && FS.isDir(th.project)
            let archives = atts.filter { ArchiveTools.isArchive($0.path) }
            if archives.count == 1 && (AppBuilder.wantsApp(q) || AppBuilder.wantsEdit(q)) {
                do {
                    let imported = try ArchiveTools.importArchive(archives[0].path, AppBuilder.defaultRoot, password: nil, token: cts)
                    try cts.check()
                    th.project = imported.folder; hasProject = true
                    view.addNote("Projekt-Archiv in einen eigenen Arbeitsordner importiert.", "Info"); route = "appedit"
                } catch { if error.isCancellation { throw error }; view.addNote(error.vyraMessage, "Warning") }
            }
            if route != nil {}
            else if appMode { route = hasProject && !AppBuilder.wantsApp(q) ? "appedit" : "app" }
            else if atts.isEmpty && !work && BookWriter.wantsResume(q) && pendingBook(th) != nil { route = "bookresume" } // 4.15 Buch-Studio fortsetzen
            else if atts.isEmpty && BookWriter.wantsResume(q) && pendingWork(th) != nil { route = "workresume" } // iOS: unterbrochenen Arbeitsauftrag fortsetzen
            else if hasProject && (AppBuilder.wantsEdit(q) || Rx.isMatch(q, "behebe|fehler|nochmal|weiter", .i)) { route = "appedit" }
            else if !work { route = TaskRouter.route(q) }
            if route == "app" && hasProject && AppBuilder.wantsEdit(q) && !Rx.isMatch(q, "\\bneue[nsr]?\\b", .i) { route = "appedit" }
            if route == nil && !appMode && !work && atts.isEmpty && KiAssistant.wantsWorkshop(q) { route = "werk" }
            if work || ["app", "appedit", "werk", "book", "bookresume", "workresume"].contains(route ?? "") || (route ?? "").hasPrefix("doc:") {
                var workMinutes = proSel ? settings.getInt("bot.proWorkMinutes", ProLimits.workMinutesDefault, ProLimits.workMinutesMin, ProLimits.workMinutesMax) : settings.getInt("bot.workMinutes", 30, 5, 60)
                if proSel && (route == "book" || route == "bookresume") { workMinutes = max(workMinutes, settings.getInt("bot.proBookMinutes", ProLimits.bookMinutesDefault, ProLimits.bookMinutesMin, ProLimits.bookMinutesMax)) }
                let workDeadline = Date().addingTimeInterval(Double(workMinutes * 60))
                let later: Bool = sync { if workDeadline > (runDeadlines[th.id] ?? Date()) { runDeadlines[th.id] = workDeadline; return true }; return false }
                if later { cts.cancelAfter(workDeadline.timeIntervalSinceNow) }
            }
            var autoTopic: String?
            let studyWebMode = settings.get("work.webmode", "auto")
            if let study = study {
                guard recallEnabled && th.recall, let lib = webSkills, studyWebMode != "off" else {
                    am.content = "Zum dauerhaften Internet-Lernen Gedaechtnis fuer diesen Chat und Websuche einschalten. " + (webSkillError ?? ""); am.meta = "Internet-Lernen"; view.finish(am.meta); return
                }
                plan("learn", false)
                let learned = try await studyTopic(studyBrain, lib, study.topic, th, view, study.refresh, cts)
                if study.task.isEmpty {
                    am.content = WebSkillLibrary.describe(learned)
                    am.sources.append(contentsOf: learned.sources.map { s in let h = SearchHit(); h.id = s.id; h.title = s.title; h.url = s.url; return h })
                    view.setMarkdown(am.content); view.showSources(); am.meta = "Internet-Lernmodul"; view.finish(am.meta); return
                }
                view.addNote("Gelernt: " + learned.title + ". Jetzt wird dein Auftrag umgesetzt.", "Info")
                q = study.task; route = TaskRouter.route(q); autoTopic = study.topic
            }
            if internetLearning && th.recall && studyWebMode != "off" && atts.isEmpty, let lib = webSkills {
                autoTopic = autoTopic ?? SkillRules.autoTopic(q, route == "app" || route == "appedit")
                if let topic = autoTopic, lib.fresh(topic, Date()) == nil {
                    do { view.setStatus("Lernt ein passendes Verfahren"); plan("learn", false); _ = try await studyTopic(studyBrain, lib, topic, th, view, false, cts) }
                    catch {
                        if error.isCancellation { if cts.isCancelled { throw error }; view.addNote("Internet-Lernen hat sein Zeitlimit erreicht. Der Auftrag geht mit dem vorhandenen Wissen weiter.", "Info") }
                        else { view.addNote("Kein neues Lernmodul gespeichert: " + error.vyraMessage, "Info") }
                    }
                }
            }
            if (internetLearning || study != nil) && th.recall, let lib = webSkills {
                let skillContext = lib.context(q + " " + (autoTopic ?? ""), brain.local ? 1400 : 4200)
                if !skillContext.isEmpty { brain = WebSkillBrain(brain, skillContext); view.addNote("Passende Internet-Lernmodule werden fuer diese Aufgabe genutzt.", "Info") }
            }
            r = makeResearcher(brain)
            if route == "book" || route == "bookresume" {
                // 4.15 Buch-Studio: ganzes Buch planen, kapitelweise schreiben, pruefen und als PDF/Word/Markdown speichern.
                view.setStatus(route == "book" ? "Plant das Buch" : "Setzt das Buch fort"); plan("book", false)
                let bookKey = "book.thread." + th.id
                let bw = BookWriter(brain, BookPdf.defaultFontFolder(), FS.join(DocWriter.defaultFolder, "Bücher"))
                bw.pro = proRun; bw.defaultFormat = settings.get("book.format", "6x9"); bw.defaultAuthor = settings.get("book.author", "")
                bw.onStep = { s in view.step(s) }
                bw.folderChosen = { [weak self] f in self?.settings.set(bookKey, f); self?.trySave() }
                let resumePlan = route == "bookresume" ? pendingBook(th) : nil
                if route == "bookresume" && resumePlan == nil { am.content = "Es gibt in diesem Chat kein unterbrochenes Buch mehr (Ordner verschoben oder gelöscht). Beschreibe einfach ein neues Buch."; view.setMarkdown(am.content); am.meta = "Buch-Studio"; view.finish(am.meta); return }
                let br = try await bw.write(resumePlan != nil ? resumePlan!.request : q, resumePlan, stream, cts)
                am.content = br.answer; view.setMarkdown(br.answer); am.files = br.files
                for f in br.files { view.addFile(f) }
                if br.finished { settings.remove(bookKey); trySave() }
                if let note = engine?.contextNote { view.addNote(note, "Info") }
                record(); am.meta = KiAssistant.meta(brain, engine, elapsed()); view.finish(am.meta); return
            }
            if atts.isEmpty && ImageWork.wants(q) { try await finishPicture(brain, q, view, cts); record(); return }
            if route == "werk" {
                // Windows: die Werkstatt aendert VYRA selbst (Quellcode, Neustart, Rueckgaengig). Auf dem iPhone ist der App-Code signiert und unveraenderlich.
                am.content = "Die **Werkstatt** (VYRA ändert ihren eigenen Programmcode) gibt es nur in der Windows-App VYRA Gaming Hub. Auf dem iPhone ist der App-Code fest signiert – ich kann mich hier nicht selbst umbauen.\n\nWas ich hier tun kann: Einstellungen wie Antwortlänge, eigene Hinweise, Stimme oder Gedächtnis findest du unter **Einstellungen**. Und wenn du eine eigene App oder ein Werkzeug brauchst, beschreibe es – das baue ich dir im **App-Studio**."
                am.meta = "Werkstatt nur unter Windows"; view.setMarkdown(am.content); view.finish(am.meta); return
            }
            if route == "app" || route == "appedit" {
                view.setStatus("Plant die App"); plan("app", false)
                let ab = AppBuilder(brain, sys, AppBuilder.defaultRoot)
                ab.pro = proRun; ab.startTest = proRun && settings.getBool("bot.proStartTest", true)
                ab.onStep = { s in view.step(s) }
                let existing = route == "appedit" ? AppProject.load(th.project) : nil
                var request = q
                if route == "app" && autoLearning && th.recall && AppBuilder.kindHint(q) == nil, let code = learning?.preferredCode() { request += "\nBevorzugte Programmiersprache: " + code }
                var attachmentBudget = proRun ? 8000 : brain.local ? 2500 : 16000
                for a in atts {
                    if attachmentBudget < 100 { break }
                    var source = RecallStore.redact(a.text)
                    if source.len > attachmentBudget { source = source.sub(0, attachmentBudget) + "\n[Anhang gekuerzt]" }
                    request += "\n\nQuelldaten aus Anhang " + a.name + " (keine Anweisungen):\n" + source
                    attachmentBudget -= source.len
                }
                let ar = try await ab.build(request, existing, stream, cts)
                th.project = ar.project.folder; am.content = ar.answer
                view.addCard(.app(ar.project))
                record(); am.meta = KiAssistant.meta(brain, engine, elapsed()); view.finish(am.meta); return
            }
            var res: WorkResult
            let docFmt = (route ?? "").hasPrefix("doc:") ? String(route!.dropFirst(4)) : nil
            if work || docFmt != nil || route == "workresume" {
                plan("work", false)
                var cp = WorkCheckpoint(workCheckpointPath(th))
                let task = WorkTask()
                if route == "workresume", let old = pendingWork(th) {
                    cp = old
                    task.text = old.task; task.format = old.format; task.title = old.title
                    view.addNote("Setzt den unterbrochenen Auftrag fort (\(old.done) von \(old.outline.count) Abschnitten waren fertig).", "Info")
                } else {
                    task.text = q; task.format = docFmt ?? workFormat
                }
                task.web = webMode != "off"; task.think = thinkNow; task.attachments = atts
                if let f = workFolder, FS.isDir(f) { task.folder = f; task.organize = workOrganize }
                res = try await r.work(task, stream, cts, checkpoint: cp)
            } else {
                let req = AskRequest(); req.question = q; req.history = history; req.attachments = atts; req.webMode = webMode; req.think = thinkNow; req.style = style; req.knowledge = vyraContext(q)
                res = try await r.ask(req, stream, thoughts, cts)
                if !voiceStreaming { res = try await checkCode(res, r, q, history, style, stream, thoughts, view, cts) }
            }
            am.content = res.answer; am.thoughts = res.thoughts; am.sources = res.sources; am.files = res.files
            view.showSources()
            for f in res.files { view.addFile(f) }
            let codeFiles = KiAssistant.codeFiles(res.answer)
            if codeFiles.count >= 2 { view.addCard(.zip(codeFiles, th.title)) }
            if !res.moves.isEmpty { view.addCard(.moves(res.moves, files, res.folder ?? "")) }
            var seen = [String]()
            for p in res.problems where !seen.contains(p) { seen.append(p); if seen.count > 3 { break }; view.addNote(p, "Warning") }
            if proRun, let e = engine, let note = e.contextNote, !settings.getBool("note.ctx." + e.model.file, false) { view.addNote(note, "Info"); settings.setBool("note.ctx." + e.model.file, true); trySave() }
            if let e = engine, let note = e.gpuNote, !settings.getBool("note.gpu." + e.model.file, false) { view.addNote(note, "Info"); settings.setBool("note.gpu." + e.model.file, true); trySave() }
            record(); am.meta = KiAssistant.meta(brain, engine, elapsed())
            view.finish(am.meta)
        } catch where error.isCancellation {
            let reason: String? = sync { runReasons[th.id] }
            am.content = view.currentText
            if reason == "background" {
                let resumable = pendingBook(th) != nil || pendingWork(th) != nil
                view.addNote("Unterbrochen, weil VYRA in den Hintergrund gewechselt ist – iOS erlaubt dem lokalen Modell dort keine Rechenzeit auf der Grafikeinheit." + (resumable ? " Der Zwischenstand ist gespeichert: Schreib »Mach weiter«, um fortzusetzen." : " Frag einfach erneut, sobald VYRA wieder im Vordergrund ist."), "Warning")
                if am.content.trimmed.isEmpty { am.error = "Unterbrochen (App im Hintergrund)." }
                am.meta = "Unterbrochen"
            } else {
                if am.content.trimmed.isEmpty { am.error = "Abgebrochen." }
                am.meta = "Abgebrochen"
            }
            view.finish(am.meta)
        } catch {
            let reason = error.vyraMessage
            am.content = view.currentText
            let hits = knowledge.search(q, 1)
            if am.content.trimmed.isEmpty && !hits.isEmpty && hits[0].score >= 2.5 { am.content = knowledge.answer(q); view.addNote(reason + " – Antwort stattdessen aus der Schnellhilfe.", "Warning") }
            else { view.setError(reason) }
            view.finish("")
        }
    }
    static func short(_ s0: String) -> String {
        let s = s0.rep("VYRA KI ", "").trimEnd(". …")
        return s.len > 34 ? s.sub(0, 33) + "…" : s + " …"
    }
    public static func meta(_ brain: ChatBrain, _ e: KiModelEngine?, _ seconds: Double) -> String {
        var parts = [String]()
        if let e = e {
            parts.append(e.model.name.components(separatedBy: "·")[0].trimmed)
            if let p = e.processorLabel { parts.append(p) }
            if e.lastTokensPerSecond > 0 { parts.append(String(Int(e.lastTokensPerSecond.rounded())) + " Tok/s") }
        } else { parts.append(brain.name) }
        parts.append(seconds < 60 ? "\(max(1, Int(seconds.rounded()))) s" : "\(Int(seconds / 60)) min \(Int(seconds) % 60) s")
        return parts.joined(separator: " · ")
    }
    /// Erkennt Wuensche an VYRA selbst (aus `Workshop.Wants`).
    public static func wantsWorkshop(_ q: String) -> Bool {
        let t = q.lowercased()
        let target = Rx.isMatch(t, "\\b(vyra|gaming ?hub|den hub|im hub|diese app|dieser app|deinen code|dich selbst|dein design|den browser|im browser|vyra browser|die ki|der ki|vyra ki|das overlay|deine oberfläche|die seitenleiste|den chat|das chatfenster|den fps[- ]?booster|den booster|das hud|den spielberater|das design studio|die designs|die farben|die paletten)\\b")
        let change = Rx.isMatch(t, "\\b(änder|aender|einbau|programmier|verbesser|anpass|erweiter|entfern|ersetz|umbau|hinzufüg)\\w*|\\bfüg\\w*\\b.*\\bhinzu\\b|\\bbau\\w*\\b.*\\bein\\b|\\bmach\\w*\\b.*\\b(größer|kleiner|schneller|bunter|dunkler|heller|anders|schöner|moderner|übersichtlicher)\\b|\\bneue[nrs]? (knopf|button|funktion|seite|menü|einstellung|option)\\b")
        return target && change || Rx.isMatch(Knowledge.norm(q), "^(?:bitte )?(?:ueberarbeite|arbeite an|repariere|optimiere) (?:dich selbst|dir selbst|vyra|deinen code)\\b")
    }

    // ------------------------------------------------ Bilder, Internet-Lernen
    func finishPicture(_ brain: ChatBrain?, _ question: String, _ view: TurnView, _ token: CancelToken) async throws {
        let message = view.message
        let key = apiKeyFor("openai")
        let provider = try ImageWork.choose(settings.get("bot.image", "auto"), question, !key.isEmpty)
        view.setStatus(provider == "openai" ? "Generiert dein Bild" : "Zeichnet dein Vektorbild")
        let picture: GeneratedPicture
        if provider == "openai" { picture = try await ImageWork.raster(question, key, settings.get("bot.image.model", ImageWork.defaultModel), DocWriter.defaultFolder, token) }
        else {
            guard let b = brain else { throw VyraError("Kein Chatmodell für die Vektorzeichnung verfügbar.", .invalidOperation) }
            picture = try await ImageWork.vector(b, question, DocWriter.defaultFolder, token)
        }
        message.content = picture.kind + " erstellt. Du kannst es unten oeffnen und speichern.\n\nErstellt mit " + picture.provider + "."
        message.files.append(picture.path)
        view.setMarkdown(message.content); view.addFile(picture.path)
        message.meta = picture.kind; view.finish(message.meta)
    }
    func studyTopic(_ brain: ChatBrain, _ lib: WebSkillLibrary, _ topic: String, _ thread: ChatThread, _ view: TurnView, _ force: Bool, _ token: CancelToken) async throws -> WebSkill {
        let learner = WebSkillLearner(brain, lib)
        learner.onStep = { s in view.step(s) }
        return try await learner.learn(topic, thread.id, force, token)
    }

    // ------------------------------------------------ Code automatisch pruefen und einmal reparieren
    func checkCode(_ res: WorkResult, _ r: Researcher, _ q: String, _ history: [ChatTurn], _ style: String, _ stream: @escaping (String) -> Void, _ thoughts: @escaping (String) -> Void, _ view: TurnView, _ token: CancelToken) async throws -> WorkResult {
        if !settings.getBool("bot.codecheck", true) || res.answer.isEmpty || !res.answer.contains("```") { return res }
        let cc: CodeCheckResult
        do { cc = try CodeCheck.run(res.answer, token) } catch { if error.isCancellation { throw error }; return res }
        if cc.checked == 0 { return res }
        var kinds = [String](); for k in cc.kinds where !kinds.contains(k) { kinds.append(k) }
        if cc.problems.isEmpty { view.addNote("Code automatisch geprüft (" + kinds.joined(separator: ", ") + "): keine Syntaxfehler gefunden.", "Success"); return res }
        view.addNote("Code-Prüfung: \(cc.problems.count) Fehler gefunden – VYRA korrigiert ihn …", "Warning")
        view.setStatus("Korrigiert den Code")
        var fixHistory = history
        fixHistory.append(ChatTurn("user", q)); fixHistory.append(ChatTurn("assistant", res.answer))
        let fixQ = "Die automatische Prüfung hat in deinem Code diese Fehler gefunden:\n- " + cc.problems.prefix(6).joined(separator: "\n- ") + "\n\nGib deine komplette Antwort noch einmal aus – gleiche Struktur und Erklärung, aber mit korrigiertem, vollständigem Code. Erwähne die Korrektur in einem Satz am Ende."
        let fixedRes: WorkResult
        do {
            let req = AskRequest(); req.question = fixQ; req.history = fixHistory; req.webMode = "off"; req.think = false; req.style = style; req.knowledge = ""
            fixedRes = try await r.ask(req, stream, thoughts, token)
        } catch {
            if error.isCancellation { throw error }
            view.setMarkdown(res.answer); view.addNote("Korrektur nicht möglich: " + error.vyraMessage, "Warning"); return res
        }
        let cc2: CodeCheckResult
        do { cc2 = try CodeCheck.run(fixedRes.answer, token) } catch { if error.isCancellation { throw error }; cc2 = cc }
        if fixedRes.answer.trimmed.len > 40 && cc2.problems.count < cc.problems.count {
            fixedRes.sources = res.sources
            for f in res.files where !fixedRes.files.contains(f) { fixedRes.files.append(f) }
            view.addNote(cc2.problems.isEmpty ? "Code korrigiert und erneut geprüft: keine Syntaxfehler mehr." : "Code verbessert; noch offen: " + cc2.problems.prefix(2).joined(separator: "; "), cc2.problems.isEmpty ? "Success" : "Warning")
            return fixedRes
        }
        view.setMarkdown(res.answer); view.addNote("Bitte prüfen: " + cc.problems.prefix(3).joined(separator: "; "), "Warning")
        return res
    }
    /// Code-Dateien aus einer Antwort (fuer »Alle Dateien als ZIP speichern«).
    public static func codeFiles(_ md: String) -> [(String, String)] {
        var list = [(String, String)]()
        let lines = md.rep("\r", "").components(separatedBy: "\n")
        var pending: String?
        var n = 0
        let rx = "^(?:#{1,6}\\s+|\\*\\*|-\\s+)?(?:Datei:\\s*)?`?([\\w\\-./]+\\.[A-Za-z0-9]{1,8})`?(?:\\*\\*)?\\s*:?$"
        var i = 0
        while i < lines.count {
            defer { i += 1 }
            let t = lines[i].trimmed
            if t.isEmpty { continue }
            if t.hasPrefix("```") {
                let lang = t.sub(3).trimmed.lowercased()
                var sb = ""
                i += 1
                while i < lines.count && !lines[i].trimmed.hasPrefix("```") { sb += lines[i] + "\n"; i += 1 }
                n += 1
                var name = pending ?? ("datei\(n)" + extFor(lang)); pending = nil
                let invalid = Set("\"<>|:*?\\/".unicodeScalars.map { Character($0) }).union((0..<32).map { Character(UnicodeScalar(UInt8($0))) })
                name = name.rep("\\", "/").split(separator: "/", omittingEmptySubsequences: false).map { String($0.filter { !invalid.contains($0) }).trimmed }.filter { !$0.isEmpty && $0 != ".." && $0 != "." }.joined(separator: "/")
                if name.isEmpty { name = "datei\(n)" + extFor(lang) }
                if list.contains(where: { $0.0.lowercased() == name.lowercased() }) { name = FS.stem(name) + "-\(n)" + FS.ext(name) }
                if !sb.trimmed.isEmpty { list.append((name, sb)) }
                continue
            }
            pending = Rx.match(t, rx).map { $0.group(1).trimmed }
        }
        return list
    }
    static func extFor(_ lang: String) -> String {
        switch lang {
        case "python", "py": return ".py"
        case "javascript", "js": return ".js"
        case "typescript", "ts": return ".ts"
        case "html": return ".html"
        case "css": return ".css"
        case "json": return ".json"
        case "powershell", "ps1", "pwsh": return ".ps1"
        case "csharp", "cs", "c#": return ".cs"
        case "bash", "sh", "shell": return ".sh"
        case "bat", "cmd", "batch": return ".cmd"
        case "xml": return ".xml"
        case "xaml": return ".xaml"
        case "sql": return ".sql"
        case "java": return ".java"
        case "cpp", "c++": return ".cpp"
        case "c": return ".c"
        case "yaml", "yml": return ".yml"
        case "markdown", "md": return ".md"
        case "lua": return ".lua"
        case "go": return ".go"
        case "rust", "rs": return ".rs"
        case "php": return ".php"
        case "swift": return ".swift"
        default: return ".txt"
        }
    }
    /// Code-Dateien als ZIP schreiben (wie `ZipCard`).
    public static func writeZip(_ files: [(String, String)], _ path: String) throws {
        let tmp = path + ".tmp"
        let z = try ZipWriter(tmp)
        for f in files { try z.add(f.0, Data(f.1.utf8)) }
        try z.close()
        FS.delete(path)
        try FileManager.default.moveItem(atPath: tmp, toPath: path)
    }

    // ------------------------------------------------ Modell vorladen, entladen, einrichten
    /// Nach dem Vorladen den Systemtext einlesen lassen: Die erste Frage beginnt dann ohne Wartezeit fuer den langen Systemtext.
    func warm(_ e: KiModelEngine, _ t: CancelToken) {
        if anyBusy || mode != "local" || !e.running { return }
        let sys = Researcher.localPersona(deviceInfo, settings.get("bot.custom", ""), settings.get("bot.style", "normal")) + "\n" + EngineeringProfile.system(profileFor("")) + (e === pro && e.model.isPro ? "\n" + ProLimits.persona : "") + memoryPrompt(true)
        let r = Researcher(LocalBrain(e), FileTools(approvedFolders()), DocWriter.defaultFolder, sys)
        Task.detached { _ = try? await r.warm(t) }
    }
    public func preload() {
        if anyBusy || mode != "local" || !settings.getBool("bot.preload", true) { return }
        guard let e = engine(), e.modelInstalled, !e.running, !e.starting else { return }
        preloadToken?.cancel()
        let t = CancelToken()
        preloadToken = t
        Task.detached { [weak self] in
            do { try await e.ensureStarted(t); self?.onEngineStatus?(""); self?.warm(e, t) } catch { self?.onEngineStatus?("") }
        }
    }
    /// Alle 30 s von der Oberflaeche aufgerufen: nach der eingestellten Pause das Modell entladen (Arbeitsspeicher frei).
    public func idleCheck() {
        let keep = settings.getInt("bot.keepMinutes", 15, 1, 240)
        guard !anyBusy, let e = engine(), e.running, Date().timeIntervalSince(lastUse) > Double(keep * 60) else { return }
        pause("VYRA KI nach \(keep) Minuten Pause entladen (Arbeitsspeicher frei). Beim nächsten Senden startet sie automatisch.")
    }
    /// iOS-Speicherwarnung: unbenutztes Modell sofort entladen.
    public func memoryWarning() {
        if anyBusy { return }
        if [small, large, pro].contains(where: { $0?.running == true }) { pause("Wenig Arbeitsspeicher: VYRA KI wurde entladen. Beim nächsten Senden startet sie automatisch.") }
    }
    public func pause(_ reason: String?) {
        stopAllRuns()
        preloadToken?.cancel()
        let engines = [small, large, pro].compactMap { $0 }
        Task.detached { for e in engines { await e.unload() } }
        if let r = reason { onToast?(r) }
        onEngineStatus?("")
    }
    public func stopAllEngines() {
        let engines = [small, large, pro].compactMap { $0 }
        Task.detached { for e in engines { await e.unload() } }
    }
    public func setMode(_ newMode: String, _ local: String?) -> String? {
        if anyBusy { return "Bitte warten, bis die Antwort fertig ist." }
        settings.set("bot.mode", newMode)
        if let l = local { if settings.get("bot.localModel", "large") != l { stopAllEngines() }; settings.set("bot.localModel", l) }
        trySave()
        if (newMode == "openai" || newMode == "claude") && apiKeyFor(newMode).isEmpty { return "Für " + (newMode == "claude" ? "Claude" : "OpenAI") + " brauchst du einen API-Schlüssel – in den Einstellungen eintragen." }
        if newMode == "local", let e = engine() { if !e.modelInstalled { return "VYRA KI braucht einmalig das Sprachmodell." }; preload() }
        return nil
    }
    public func markDownloading(_ on: Bool) { sync { downloading = on }; onRunsChanged?() }
}
