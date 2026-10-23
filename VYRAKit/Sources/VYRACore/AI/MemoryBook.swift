import Foundation

// ---------------------------------------------------------------- Gedaechtnis: was VYRA ueber den Nutzer weiss (lokal, verschluesselt, jederzeit einsehbar)
public final class MemoryFact {
    public var id = "", category = "", text = "", source = "", slot = ""
    public var created = Date(), updated = Date()
    public var pinned = false
    func copy() -> MemoryFact { let f = MemoryFact(); f.id = id; f.category = category; f.text = text; f.source = source; f.slot = slot; f.created = created; f.updated = updated; f.pinned = pinned; return f }
}
public final class MemoryBook {
    public static let categories = ["Über dich", "Vorlieben", "Gaming", "PC & Technik", "Projekte & Ziele", "Sonstiges"]
    let file: String
    let protect: (String) -> String?
    let unprotect: (String) -> String?
    let lock = NSRecursiveLock()
    var facts = [MemoryFact]()
    public private(set) var loadProblem = ""
    public init(_ dataRoot: String, _ enc: @escaping (String) -> String?, _ dec: @escaping (String) -> String?) {
        file = FS.join(dataRoot, "KI", "Gedaechtnis.dat")
        protect = enc; unprotect = dec
        if !FS.isFile(file) { return }
        do {
            if FS.size(file) > 4_000_000 { throw VyraError("Die Gedächtnisdatei ist zu groß.", .invalidData) }
            let raw = try FS.readText(file)
            guard let plain = unprotect(raw), !(raw.len > 0 && plain.isEmpty) else { throw VyraError("Das Gedächtnis gehört zu einem anderen Gerät oder Benutzer und kann hier nicht gelesen werden.", .invalidData) }
            for r in Json.arr(try Json.parse(plain), "facts").prefix(600) {
                let text = Json.str(r, "text"), id = Json.str(r, "id")
                if id.len != 32 || !MemoryBook.safe(text) { continue }
                var cat = Json.str(r, "category")
                if !MemoryBook.categories.contains(cat) { cat = "Sonstiges" }
                let f = MemoryFact(); f.id = id; f.text = text; f.category = cat; f.source = Json.str(r, "source"); f.slot = Json.str(r, "slot")
                f.created = ISO.parse(Json.str(r, "created")) ?? Date(); f.updated = ISO.parse(Json.str(r, "updated")) ?? Date()
                f.pinned = Json.bool(r, "pinned") == true
                facts.append(f)
            }
        } catch { loadProblem = error.vyraMessage }
    }
    static func safe(_ s: String) -> Bool {
        !s.trimmed.isEmpty && s.len <= 600 && RecallStore.redact(s) == s && SkillRules.safe(s) && !Rx.isMatch(s, "\\b(?:passwort|password|kennwort|pin|iban|kreditkarte|kartennummer|cvv|tan|api.?key|access.?token|private key|sozialversicherungs\\w*|steuer-?id|ausweisnummer)\\b", .i)
    }
    public var count: Int { lock.lock(); defer { lock.unlock() }; return facts.count }
    public func all() -> [MemoryFact] { lock.lock(); defer { lock.unlock() }; return facts.map { $0.copy() } }
    func save() throws {
        let obj = Json.obj(("format", "vyra-gedaechtnis-1"), ("facts", facts.map { f -> Any in Json.obj(("id", f.id), ("text", f.text), ("category", f.category), ("source", f.source), ("slot", f.slot), ("pinned", f.pinned), ("created", ISO.string(f.created)), ("updated", ISO.string(f.updated))) }))
        guard let enc = protect(Json.serialize(obj)), !enc.isEmpty else { throw VyraError("Das Gedächtnis konnte nicht verschlüsselt werden.", .invalidOperation) }
        try FS.writeAtomic(file, text: enc)
    }
    func change(_ a: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        let before = facts.map { $0.copy() }
        do { try a(); try save() } catch { facts = before; throw error }
    }
    public static func guess(_ text: String) -> String {
        let n = " " + Knowledge.norm(text) + " "
        if Rx.isMatch(n, " (fortnite|spiel\\w*|zock\\w*|game\\w*|minecraft|valorant|rocket league|apex|warzone|cod|fifa|fc \\d+|skin\\w*|rang|ranked|clan|team|controller|crosshair\\w*) ") { return "Gaming" }
        if Rx.isMatch(n, " (pc|computer|laptop|grafikkarte|gpu|cpu|prozessor|ram|arbeitsspeicher|monitor|maus|tastatur|headset|windows|ssd|festplatte|rtx|gtx|ryzen|intel|nvidia|amd|hz) ") { return "PC & Technik" }
        if Rx.isMatch(n, " (projekt\\w*|ziel\\w*|lerne\\w*|plane\\w*|baue\\w*|app|buch|roman|schreibe|kanal|youtube|stream\\w*) ") { return "Projekte & Ziele" }
        if Rx.isMatch(n, " (mag|liebe|lieblings\\w*|gern|gerne|bevorzuge|hasse|lieber) ") { return "Vorlieben" }
        if Rx.isMatch(n, " (heisse|name|wohne|lebe|komme aus|beruf|arbeite|geburtstag|familie|hund|katze) ") { return "Über dich" }
        return "Sonstiges"
    }
    @discardableResult public func add(_ text0: String, _ category0: String, _ source: String?, _ slot: String?) throws -> MemoryFact {
        var text = MemoryBook.clean(text0)
        if text.len < 3 { throw VyraError("Das ist zu kurz zum Merken.", .argument) }
        if text.len > 600 { text = text.sub(0, 600) }
        if !MemoryBook.safe(text) { throw VyraError("Passwörter, PINs, Kontodaten und Schlüssel speichert VYRA bewusst nicht im Gedächtnis.", .argument) }
        let category = MemoryBook.categories.contains(category0) ? category0 : MemoryBook.guess(text)
        var result: MemoryFact!
        try change {
            let norm = Knowledge.norm(text).trimmed
            if let same = facts.first(where: { Knowledge.norm($0.text).trimmed == norm || (slot != nil && !slot!.isEmpty && $0.slot == slot) }) {
                same.text = text; same.category = category; same.updated = Date()
                if let s = source, !s.isEmpty { same.source = s }
                result = same; return
            }
            if facts.count >= 500, let old = facts.filter({ !$0.pinned }).min(by: { $0.updated < $1.updated }) { facts.removeAll { $0 === old } }
            let f = MemoryFact(); f.id = FS.newId(); f.text = text; f.category = category; f.source = source ?? ""; f.slot = slot ?? ""
            facts.append(f); result = f
        }
        return result.copy()
    }
    public func update(_ id: String, _ text0: String, _ category: String, _ pinned: Bool) throws {
        let text = MemoryBook.clean(text0)
        if !MemoryBook.safe(text) { throw VyraError("Dieser Text kann nicht gespeichert werden (zu lang, leer oder enthält Zugangsdaten).", .argument) }
        try change {
            guard let f = facts.first(where: { $0.id == id }) else { return }
            f.text = text; if MemoryBook.categories.contains(category) { f.category = category }; f.pinned = pinned; f.updated = Date()
        }
    }
    public func delete(_ id: String) throws { try change { facts.removeAll { $0.id == id } } }
    public func clear() throws { try change { facts.removeAll() } }
    static func clean(_ s0: String) -> String {
        var s = s0.trimmed.trim("\"„“'")
        s = Rx.replace(s, "\\s+", " ")
        return s.trimEnd(". ")
    }
    /// Kurzprofil fuer die Grundanweisungen: Angeheftete und neueste Eintraege zuerst, nach Bereich gruppiert.
    public func profile(_ maxChars: Int) -> String {
        if maxChars < 120 { return "" }
        let list = all()
        if list.isEmpty { return "" }
        var b = "Gedächtnis – vom Nutzer selbst mitgeteilt (natürlich nutzen, nicht ungefragt aufzählen):\n"
        let sorted = list.stableSorted { a, c in
            if a.pinned != c.pinned { return a.pinned }
            let ia = MemoryBook.categories.firstIndex(of: a.category) ?? 99, ic = MemoryBook.categories.firstIndex(of: c.category) ?? 99
            if ia != ic { return ia < ic }
            return a.updated > c.updated
        }
        for f in sorted { let line = "- " + f.text + "\n"; if b.len + line.len > maxChars { break }; b += line }
        return b.trimEnd()
    }
    public func describe() -> String {
        let list = all()
        if list.isEmpty { return "Ich habe mir noch nichts über dich gemerkt.\n\nSag zum Beispiel **»Merke dir, dass ich am liebsten Fortnite im Arena-Modus spiele«** oder **»Ich heiße Max«** – dann weiß ich es auch in späteren Chats. Alles steht unter **🧠 Gedächtnis** in der Seitenleiste." }
        var b = "**Kurz gesagt:** Ich habe mir \(list.count)" + (list.count == 1 ? " Sache" : " Dinge") + " über dich gemerkt.\n"
        for cat in MemoryBook.categories {
            let part = list.filter { $0.category == cat }.stableSorted { a, c in a.pinned != c.pinned ? a.pinned : a.updated > c.updated }
            if part.isEmpty { continue }
            b += "\n### " + cat + "\n"
            for f in part { b += "- " + f.text + "\n" }
        }
        b += "\n> **Tipp:** Unter **🧠 Gedächtnis** in der Seitenleiste kannst du alles ansehen, ändern oder löschen. »Vergiss …« entfernt einzelne Einträge."
        return b
    }
    public func forget(_ what: String) throws -> [MemoryFact] {
        let words = Rx.split(Knowledge.norm(what), " +").filter { $0.len >= 3 && $0 != "dass" && $0 != "ich" && $0 != "mein" && $0 != "meine" }
        var removed = [MemoryFact]()
        if words.isEmpty { return removed }
        lock.lock()
        for f in facts {
            let n = Knowledge.norm(f.text)
            let hit = words.filter { n.contains($0) }.count
            if hit >= max(1, Int(ceil(Double(words.count) * 0.6))) { removed.append(f.copy()) }
        }
        lock.unlock()
        if !removed.isEmpty { let ids = Set(removed.map { $0.id }); try change { facts.removeAll { ids.contains($0.id) } } }
        return removed
    }
    public static func isRememberCommand(_ q: String) -> String? {
        guard let m = Rx.match(q, "^\\s*(?:bitte\\s+)?(?:merke?\\s+dir|merk\\s+dir|speicher(?:e)?\\s+(?:dir|das|als erinnerung|im ged(?:ä|ae)chtnis)|vergiss\\s+nicht)\\s*[,!:]?\\s*(?:,?\\s*dass\\s+)?(.+)$", [.i, .s]) else { return nil }
        let t = m.group(1).trimmed
        return t.len >= 3 ? t : nil
    }
    /// (what, all) oder nil
    public static func isForgetCommand(_ q: String) -> (String, Bool)? {
        guard let m = Rx.match(q, "^\\s*(?:bitte\\s+)?(?:vergiss|l(?:ö|oe)sche?\\s+(?:aus\\s+deinem\\s+ged(?:ä|ae)chtnis|die\\s+erinnerung(?:\\s+an)?)|entferne\\s+aus\\s+(?:deinem|dem)\\s+ged(?:ä|ae)chtnis)\\s*[,:]?\\s*(?:,?\\s*dass\\s+|das\\s+mit\\s+|alles\\s+(?:was\\s+du\\s+)?(?:über|ueber)\\s+(?:mich|mir)\\s*(?:wei(?:ss|ß)t)?\\s*$)?(.*)$", [.i, .s]) else { return nil }
        let n = Knowledge.norm(q)
        let all = Rx.isMatch(n, "\\b(?:vergiss|loesch\\w*|entferne)\\b.*\\balles\\b")
        let what = m.group(1).trimmed.trimEnd(".!")
        return all || what.len >= 3 ? (what, all) : nil
    }
    public static func isRecallQuestion(_ q: String) -> Bool {
        let n = Rx.replace(Knowledge.norm(q), " +", " ").trimmed
        return Rx.isMatch(n, "^(?:was\\s+(?:weisst|hast|kennst)\\s+du\\s+(?:alles\\s+|schon\\s+)?(?:ueber|von)\\s+mich|was\\s+hast\\s+du\\s+dir\\s+(?:ueber\\s+mich\\s+)?gemerkt|was\\s+(?:steht|ist)\\s+in\\s+deinem\\s+gedaechtnis|zeig\\w*\\s+(?:mir\\s+)?(?:dein|mein|das)\\s+gedaechtnis|woran\\s+erinnerst\\s+du\\s+dich)\\b")
    }
    // Automatisch merken: nur klare Aussagen des Nutzers ueber sich selbst (keine Fragen, Zitate, Beispiele oder Zugangsdaten).
    static let rules: [[String]] = [
        ["name", "Über dich", "\\b(?:ich\\s+hei(?:ß|ss)e|mein\\s+name\\s+ist|nenn(?:e|t)?\\s+mich(?:\\s+bitte)?)\\s+([A-ZÄÖÜ][\\p{L}'\\-]{1,24}(?:\\s+[A-ZÄÖÜ][\\p{L}'\\-]{1,24})?)", "Heißt {0}"],
        ["wohnort", "Über dich", "\\bich\\s+(?:wohne|lebe)\\s+(?:in|bei)\\s+([A-ZÄÖÜ][\\p{L}\\-]{1,30}(?:\\s+[A-ZÄÖÜ][\\p{L}\\-]{1,30})?)", "Wohnt in {0}"],
        ["herkunft", "Über dich", "\\bich\\s+komme\\s+(?:ursprünglich\\s+)?aus\\s+([A-ZÄÖÜ][\\p{L}\\-]{1,30}(?:\\s+[A-ZÄÖÜ][\\p{L}\\-]{1,30})?)", "Kommt aus {0}"],
        ["beruf", "Über dich", "\\bich\\s+(?:arbeite\\s+als|bin\\s+von\\s+beruf|bin\\s+beruflich)\\s+([\\p{L}\\- ]{3,40})", "Beruf: {0}"],
        ["lieblingsspiel", "Gaming", "\\b(?:mein\\s+lieblingsspiel\\s+ist|ich\\s+spiele\\s+(?:am\\s+liebsten|meistens|hauptsächlich))\\s+([\\p{L}\\d:'\\- ]{2,40})", "Spielt am liebsten {0}"],
        ["spielt", "Gaming", "\\bich\\s+spiele\\s+(?:gerne?|viel|oft|täglich|jeden\\s+tag)\\s+([\\p{L}\\d:'\\- ]{2,40})", "Spielt gern {0}"],
        ["epicname", "Gaming", "\\bmein\\s+(?:fortnite|epic(?:\\s+games)?)[\\- ]?(?:name|account|nick(?:name)?|ingame-?name)\\s+(?:ist|lautet|hei(?:ß|ss)t)\\s+([\\p{L}\\d_.\\-]{2,32})", "Fortnite-/Epic-Name: {0}"],
        ["gpu", "PC & Technik", "\\b(?:ich\\s+habe|mein\\s+pc\\s+hat|in\\s+meinem\\s+pc\\s+(?:ist|steckt)|meine\\s+grafikkarte\\s+ist)\\s+(?:eine?\\s+|die\\s+)?((?:nvidia\\s+|amd\\s+|intel\\s+)?(?:geforce\\s+|radeon\\s+)?(?:rtx|gtx|rx|arc)\\s?[a-z]?\\d{3,4}\\s?(?:ti|super|xt|xtx|gre)?)\\b", "Grafikkarte: {0}"],
        ["cpu", "PC & Technik", "\\b(?:ich\\s+habe\\s+(?:einen\\s+)?|mein\\s+prozessor\\s+ist\\s+(?:ein\\s+)?)((?:intel\\s+)?(?:core\\s+)?(?:i[3579]|ultra\\s+[579])[\\- ]\\d{3,5}[a-z]{0,3}|(?:amd\\s+)?ryzen\\s+[3579]\\s+\\d{4}[a-z0-9]{0,4})\\b", "Prozessor: {0}"],
        ["ram", "PC & Technik", "\\b(?:ich\\s+habe|mein\\s+pc\\s+hat)\\s+(\\d{1,3})\\s?gb\\s+(?:ram|arbeitsspeicher)", "Arbeitsspeicher: {0} GB"],
        ["monitor", "PC & Technik", "\\b(?:mein\\s+monitor\\s+hat|ich\\s+habe\\s+einen)\\s+(\\d{2,3})\\s?hz", "Monitor: {0} Hz"],
        ["", "Vorlieben", "\\bmein(?:e)?\\s+lieblings(\\p{L}{3,20})\\s+(?:ist|sind)\\s+([^.!?\\n,]{2,40})", "Lieblings{0}: {1}"],
        ["", "Vorlieben", "\\bich\\s+(?:mag|liebe)\\s+(?!es\\b|das\\b|nicht\\b|dich\\b|keine?n?\\b)([\\p{L}\\d'\\- ]{3,40})", "Mag {0}"],
        ["", "Vorlieben", "\\bich\\s+(?:mag\\s+keine?n?|hasse|kann\\s+(?:\\w+\\s+)?nicht\\s+leiden)\\s+([\\p{L}\\d'\\- ]{3,40})", "Mag nicht: {0}"],
        ["ziel", "Projekte & Ziele", "\\bmein\\s+ziel\\s+ist(?:\\s+es)?,?\\s+([^.!?\\n]{4,80})", "Ziel: {0}"],
        ["", "Projekte & Ziele", "\\bich\\s+(?:arbeite\\s+(?:gerade\\s+)?an|baue\\s+gerade|programmiere\\s+gerade|schreibe\\s+gerade(?:\\s+an)?)\\s+([^.!?\\n]{4,80})", "Projekt: {0}"]
    ]
    public func observe(_ userText: String, _ thread: String) -> [MemoryFact] {
        var added = [MemoryFact]()
        let q = userText.trimmed
        if q.len < 6 || q.len > 1500 || q.contains("```") || !MemoryBook.safe(q.len > 600 ? q.sub(0, 600) : q) { return added }
        if Rx.isMatch(q, "^\\s*(?:beispiel|zitat|zitiere|übersetze|uebersetze|angenommen|stell\\s+dir\\s+vor|schreib\\w*|formulier\\w*|erfinde)\\b", .i) || q.hasPrefix(">") || q.contains("„") || q.filter({ $0 == "\"" }).count >= 2 { return added }
        // Nur Aussagesaetze (keine Fragen) auswerten.
        for sentence in Rx.split(q, "(?<=[.!?\\n])\\s+") {
            let st = sentence.trimmed
            if st.len < 6 || st.contains("?") { continue }
            for r in MemoryBook.rules {
                guard let m = Rx.match(st, r[2], .i) else { continue }
                var v1 = MemoryBook.trimValue(m.group(1))
                let v2 = m.groupCount > 2 ? MemoryBook.trimValue(m.group(2)) : ""
                if v1.len < 2 { continue }
                if Rx.isMatch(Knowledge.norm(v1), "^(?:es|das|dies|so|nicht|auch|gerade|eigentlich|halt|mal|ja|nein|dich|euch|sie|ihn)$") { continue }
                if r[0] == "name" || r[0] == "wohnort" || r[0] == "herkunft" { v1 = MemoryBook.title(v1) }
                let fav = r[0].isEmpty && r[3].hasPrefix("Lieblings")
                let text = r[3].rep("{0}", fav ? v1.lowercased() : v1).rep("{1}", v2)
                let slot = !r[0].isEmpty ? r[0] : fav ? "fav:" + Knowledge.norm(v1).trimmed : ""
                if let f = try? add(text, r[1], "automatisch gemerkt", slot) { added.append(f) }
                if added.count >= 3 { return added }
            }
        }
        return added
    }
    static func title(_ v: String) -> String { v.splitKeep(" ").map { $0.isEmpty ? $0 : $0.capitalizedFirst }.joined(separator: " ") }
    static func trimValue(_ v0: String) -> String {
        var v = v0.trimmed.trimEnd(".,; !")
        v = Rx.replace(v, "\\s+(?:und|aber|weil|denn|da|wenn|als|oder|mit|seit)(?:\\s.*)?$", "", .i)
        return v.len > 60 ? v.sub(0, 60) : v
    }
    /// Einmalige Uebernahme der bisherigen "Merke dir"-Notizen (4.11-4.13).
    @discardableResult public func importNotes(_ notes: [RecallNote]) -> Int {
        var n = 0
        for note in notes { if (try? add(note.text, MemoryBook.guess(note.text), "Notiz (bis 4.13)", nil)) != nil { n += 1 } }
        return n
    }
}
