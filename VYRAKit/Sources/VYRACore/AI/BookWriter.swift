import Foundation

// ---------------------------------------------------------------- 4.15 Buch-Studio: ganze Buecher planen, kapitelweise schreiben, pruefen, fortsetzen und als PDF setzen
public final class BookChapterPlan {
    public var title = "", synopsis = "", summary = "", file = ""
    public var words = 0
    public var done = false
    public var parts = [String]()
    public init() {}
}

public final class BookPlan {
    public var request = "", title = "", subtitle = "", author = "", kind = "roman", genre = "", audience = "", tone = "", perspective = "", setting = "", premise = "", pageFormat = "6x9", folder = "", blurb = "", language = "Deutsch"
    public var wordsPerChapter = 2500, partWords = 900
    public var finished = false, pro = false
    public var created = Date()
    public var characters = [[String]]()
    public var chapters = [BookChapterPlan]()
    public var facts = [String]()
    public static let stateFile = "vyra-buch.json"
    public init() {}
    public var fiction: Bool { kind != "sachbuch" }
    public var wordsWritten: Int { chapters.reduce(0) { $0 + ($1.done ? $1.words : $1.parts.reduce(0) { $0 + BookWriter.countWords($1) }) } }
    public var chaptersDone: Int { chapters.filter { $0.done }.count }
    public var partsPerChapter: Int { max(1, Int((Double(wordsPerChapter) / Double(max(200, partWords))).rounded(.toNearestOrEven))) }
    public var statePath: String { FS.join(folder, BookPlan.stateFile) }
    public func save() {
        try? FS.mkdir(folder)
        let chs = chapters.map { c in Json.obj(("titel", c.title), ("inhalt", c.synopsis), ("zusammenfassung", c.summary), ("datei", c.file), ("woerter", Double(c.words)), ("fertig", c.done), ("teile", c.parts as [Any])) as Any }
        let m = Json.obj(("format", "vyra-book-1"), ("wunsch", request), ("titel", title), ("untertitel", subtitle), ("autor", author), ("art", kind), ("genre", genre), ("zielgruppe", audience), ("ton", tone), ("perspektive", perspective), ("schauplatz", setting), ("praemisse", premise),
                         ("seitenformat", pageFormat), ("sprache", language), ("klappentext", blurb), ("woerter_je_kapitel", Double(wordsPerChapter)), ("woerter_je_teil", Double(partWords)), ("fertig", finished), ("pro", pro), ("erstellt", ISO.string(created)),
                         ("figuren", characters.map { $0 as [Any] } as [Any]), ("fakten", facts as [Any]), ("kapitel", chs))
        try? FS.writeAtomic(statePath, text: Json.serialize(m))
    }
    public static func load(_ folder: String?) -> BookPlan? {
        guard let folder = folder, !folder.trimmed.isEmpty else { return nil }
        let path = FS.join(folder, stateFile)
        guard FS.isFile(path), let o = try? Json.readFile(path, maxBytes: 50_000_000), Json.str(o, "format") == "vyra-book-1" else { return nil }
        let p = BookPlan()
        p.folder = folder; p.request = Json.str(o, "wunsch"); p.title = Json.str(o, "titel"); p.subtitle = Json.str(o, "untertitel"); p.author = Json.str(o, "autor"); p.kind = Json.str(o, "art"); p.genre = Json.str(o, "genre"); p.audience = Json.str(o, "zielgruppe"); p.tone = Json.str(o, "ton")
        p.perspective = Json.str(o, "perspektive"); p.setting = Json.str(o, "schauplatz"); p.premise = Json.str(o, "praemisse"); p.pageFormat = Json.str(o, "seitenformat"); p.language = Json.str(o, "sprache"); p.blurb = Json.str(o, "klappentext")
        p.wordsPerChapter = Int(Json.num(o, "woerter_je_kapitel", 2500)); p.partWords = Int(Json.num(o, "woerter_je_teil", 900))
        p.finished = Json.bool(o, "fertig") ?? false; p.pro = Json.bool(o, "pro") ?? false
        if let d = ISO.parse(Json.str(o, "erstellt")) { p.created = d }
        if p.language.isEmpty { p.language = "Deutsch" }
        if p.kind.isEmpty { p.kind = "roman" }
        for f in Json.arr(o, "figuren") { if let l = f as? [Any], l.count >= 1 { p.characters.append(Array((l.map { Json.text($0) } + ["", "", ""]).prefix(3))) } }
        for f in Json.arr(o, "fakten") { p.facts.append(Json.text(f)) }
        for c in Json.arr(o, "kapitel") {
            let ch = BookChapterPlan()
            ch.title = Json.str(c, "titel"); ch.synopsis = Json.str(c, "inhalt"); ch.summary = Json.str(c, "zusammenfassung"); ch.file = Json.str(c, "datei"); ch.words = Int(Json.num(c, "woerter", 0))
            ch.done = Json.bool(c, "fertig") ?? false
            for t in Json.arr(c, "teile") { ch.parts.append(Json.text(t)) }
            if ch.done {
                let full = ch.file.isEmpty ? nil : AppBuilder.insideFolder(folder, ch.file)
                if full == nil || !FS.isFile(full!) { ch.done = false; ch.parts.removeAll() } // fehlende Kapiteldatei: neu schreiben
            }
            p.chapters.append(ch)
        }
        return p.title.isEmpty ? nil : p
    }
    public func chapterText(_ c: BookChapterPlan) -> String {
        if !c.done { return c.parts.joined(separator: "\n\n") }
        guard let path = AppBuilder.insideFolder(folder, c.file), FS.isFile(path) else { return "" }
        return (try? FS.readText(path)) ?? ""
    }
}
public final class BookRequest {
    public var kind = "roman", author = "", title = "", language = "Deutsch"
    public var format: String?
    public var chapters = 0, wordsPerChapter = 0, partWords = 0
    public var notes = [String]()
    public init() {}
}
public final class BookResult {
    public var plan: BookPlan?
    public var answer = ""
    public var files = [String]()
    public var problems = [String]()
    public var finished = false
    public var pdf: BookPdfResult?
}

public final class BookWriter {
    let brain: ChatBrain
    let fontFolder: String?, booksRoot: String
    var stepNo = 0
    public var pro = false
    public var defaultFormat = "6x9", defaultAuthor = ""
    public var onStep: ((WorkStep) -> Void)?
    /// meldet den Buchordner, sobald er feststeht (zum spaeteren Fortsetzen)
    public var folderChosen: ((String) -> Void)?
    public init(_ brain: ChatBrain, _ fontFolder: String?, _ booksRoot: String) { self.brain = brain; self.fontFolder = fontFolder; self.booksRoot = booksRoot }
    public static func defaultRoot() -> String { FS.join(DocWriter.defaultFolder, "Bücher") }
    var big: Bool { pro || !brain.local }
    func begin(_ kind: String, _ text: String) -> WorkStep { stepNo += 1; let s = WorkStep(); s.kind = kind; s.text = text; s.index = stepNo; onStep?(s); return s }
    func end(_ s: WorkStep, _ detail: String?, _ failed: Bool) { s.done = true; s.failed = failed; if let d = detail { s.detail = d }; onStep?(s) }
    static func one(_ t: String) -> [ChatTurn] { [ChatTurn("user", t)] }
    static func obj(_ pairs: (String, Any)...) -> JObject { let o = JObject(); for (k, v) in pairs { o[k] = v }; return o }

    // ------------------------------------------------ Erkennen
    static let rxBook = #"\b(schreib\w*|verfass\w*|erstell\w*|mach\w*|generier\w*|entwirf|entwerf\w*|produzier\w*|denk\w* dir)\b.{0,90}?\b(buch|bücher|buecher|roman|romane|kinderbuch|jugendbuch|sachbuch|fachbuch|ratgeber|e-?book|novelle|krimi|thriller|fantasyroman|fantasy-roman|liebesroman|science-fiction-roman|biografie|biographie|memoiren|kurzgeschichtensammlung|geschichtensammlung|gedichtband|anthologie)\b|\b(buch|bücher|buecher|roman|romane|kinderbuch|jugendbuch|sachbuch|fachbuch|ratgeber|e-?book|novelle|krimi|thriller|fantasyroman|fantasy-roman|liebesroman|science-fiction-roman|biografie|biographie|memoiren|kurzgeschichtensammlung|geschichtensammlung|gedichtband|anthologie)\b.{0,50}?\b(schreiben|verfassen|erstellen|machen|generieren|entwerfen)\b"#
    static let rxNotBook = #"\b(zusammenfassung|rezension|inhaltsangabe|analyse|interpretation|klappentext|buchtitel|titelideen?|titel f(ü|ue)r|cover|umschlag|buchr(ü|ue)cken|layout|werbetext|beschreibung f(ü|ue)r|leseprobe zu|über das buch|ueber das buch|zum buch|des buches|aus dem buch|im buch|buchhaltung\w*|buchung\w*|buchen|gebucht|buchempfehlung\w*|empfiehl|empfehlung\w*|welche[sn]? b(ü|ue)cher|ein kapitel|einen absatz|eine seite|eine szene)\b"#
    public static func wants(_ q: String?) -> Bool {
        let t = (q ?? "").trimmed
        if t.len < 12 || (t.hasSuffix("?") && !Rx.isMatch(t, #"^(kannst|könntest|koenntest|würdest|wuerdest) du"#, .i)) { return false }
        return Rx.isMatch(t, rxBook, .i) && !Rx.isMatch(t, rxNotBook, .i)
    }
    static let rxResume = #"^(bitte\s+)?((schreib|mach|arbeite?)\w*\s+(das buch|den roman|das manuskript|am buch|am roman)?\s*weiter|setz\w*\s+(das buch|den roman|das manuskript)?\s*fort|weiter(schreiben| schreiben|machen)?|fortsetzen|(das )?buch (weiter|fortsetzen|fertig ?(schreiben|stellen|machen))|mach(e)? weiter|nächstes kapitel|naechstes kapitel)\b"#
    public static func wantsResume(_ q: String?) -> Bool { let t = (q ?? "").trimmed.trimEnd(".! "); return t.len <= 80 && Rx.isMatch(t, rxResume, .i) }

    // ------------------------------------------------ Umfang aus dem Wunsch lesen
    static let numberWords: [(String, Int)] = [("drei", 3), ("vier", 4), ("fünf", 5), ("fuenf", 5), ("sechs", 6), ("sieben", 7), ("acht", 8), ("neun", 9), ("zehn", 10), ("elf", 11), ("zwölf", 12), ("zwoelf", 12), ("dreizehn", 13), ("vierzehn", 14), ("fünfzehn", 15), ("sechzehn", 16), ("siebzehn", 17), ("achtzehn", 18), ("neunzehn", 19), ("zwanzig", 20), ("fünfundzwanzig", 25), ("dreißig", 30), ("dreissig", 30), ("vierzig", 40), ("fünfzig", 50), ("hundert", 100)]
    static func number(_ text: String, _ unit: String) -> Int {
        if let m = Rx.match(text, #"(\d{1,3}(?:[.']\d{3})+|\d+)\s*(?:-|bis)?\s*(?:\d+\s*)?"# + unit, .i), let v = Int(Rx.replace(m.group(1), "[.']", "")) { return v }
        for (k, v) in numberWords where Rx.isMatch(text, "\\b" + k + "\\s+" + unit, .i) { return v }
        return 0
    }
    public static func parse(_ q: String?, _ big: Bool, _ defaultFormat: String?) -> BookRequest {
        let t = (q ?? "").lowercased()
        let r = BookRequest()
        if Rx.isMatch(t, "kinderbuch|für kinder|fuer kinder|gute-?nacht|vorlese") { r.kind = "kinderbuch" }
        else if Rx.isMatch(t, "sachbuch|fachbuch|ratgeber|lehrbuch|handbuch|leitfaden|anleitung|guide|biografie|biographie|memoiren") { r.kind = "sachbuch" }
        else if Rx.isMatch(t, "kurzgeschichten|geschichtensammlung|anthologie|gedichtband|sammlung von (geschichten|gedichten)") { r.kind = "sammlung" }
        r.format = BookFormat.detect(t) ?? ((defaultFormat ?? "").isEmpty ? "6x9" : defaultFormat!)
        if Rx.isMatch(t, "\\b(auf|in) englisch|\\benglish\\b|in english") { r.language = "Englisch" }
        if let am = Rx.match(q ?? "", #"(?:Autor(?:in)?|Autorenname|Verfasser(?:in)?)\s*(?:ist|:|=)?\s*[„"»']?([A-ZÄÖÜ][\wäöüß.\-]+(?:\s+[A-ZÄÖÜ][\wäöüß.\-]+){0,3})"#) { r.author = am.group(1).trimmed }
        if let tm = Rx.match(q ?? "", #"(?:Titel|heißen|heissen|heißt|heisst|namens)\s*(?:soll|ist|:)?\s*[„"»']([^"“”«'\n]{2,90})[“”"«']"#) { r.title = tm.group(1).trimmed }
        var chapters = number(t, "kapitel")
        var words = number(t, "(?:wörter|woerter|worte|wörtern|woertern)")
        let pages = number(t, "seiten")
        if words == 0 && pages > 0 { words = pages * (r.format == "a4" ? 520 : r.format == "5x8" ? 250 : 290) }
        let defChapters = r.kind == "kinderbuch" ? (big ? 10 : 6) : r.kind == "sachbuch" ? (big ? 10 : 7) : big ? 12 : 8
        let defWords = r.kind == "kinderbuch" ? (big ? 700 : 500) : r.kind == "sachbuch" ? (big ? 2400 : 1300) : r.kind == "sammlung" ? (big ? 2200 : 1200) : big ? 2600 : 1500
        let maxChapters = big ? 40 : 12, maxPer = big ? 6000 : 2000, maxTotal = big ? 150000 : 24000, minPer = r.kind == "kinderbuch" ? 150 : 400
        if chapters <= 0 && words > 0 { chapters = Int((Double(words) / Double(defWords)).rounded(.toNearestOrEven)) }
        if chapters <= 0 { chapters = defChapters }
        if chapters > maxChapters { r.notes.append("Höchstens \(maxChapters) Kapitel" + (big ? "" : " (in VYRA Pro bis zu 40)") + "."); chapters = maxChapters }
        chapters = max(3, chapters)
        var per = words > 0 ? Int((Double(words) / Double(chapters)).rounded(.toNearestOrEven)) : defWords
        if per * chapters > maxTotal { r.notes.append("Umfang auf etwa " + DE.n0(maxTotal) + " Wörter begrenzt" + (big ? "." : " – für längere Bücher VYRA Pro wählen.")); per = maxTotal / chapters }
        if per > maxPer { r.notes.append("Kapitel auf etwa " + DE.n0(maxPer) + " Wörter begrenzt."); per = maxPer }
        r.chapters = chapters; r.wordsPerChapter = max(minPer, per); r.partWords = big ? 900 : 700
        return r
    }

    // ------------------------------------------------ Textpruefungen (statisch, testbar)
    public static func countWords(_ s: String?) -> Int { guard let s = s, !s.isEmpty else { return 0 }; return Rx.count(s, #"[\wÀ-ɏ]+(?:[-'’][\wÀ-ɏ]+)*"#) }
    static let rxPreamble = #"^(natürlich|natuerlich|gerne|gern|selbstverständlich|selbstverstaendlich|okay|ok|klar|hier (ist|folgt|kommt)|im folgenden|nachfolgend|sure|here is|here's)\b"#
    static let rxTrailer = #"^(\(?\s*fortsetzung folgt|ende (von |des )?(teil|kapitel|abschnitt)|\[?\s*ende\s*\]?$|---+$|wie geht es weiter|soll ich (weiter|fort)|möchtest du|moechtest du|ich hoffe|\(?\s*wortanzahl|\(?\s*wörter:|\(?\s*\d+\s*wörter\)?$)"#
    /// Entfernt Vorreden, Ueberschriften, Nachsaetze und Formatierungsreste aus einem Buchteil.
    public static func cleanPart(_ text: String?, _ fiction: Bool, _ chapterTitle: String?) -> String {
        var s = EngineText.clean(text ?? "").rep("\r", "")
        s = Rx.replace(s, "^```[a-z]*\\s*$", "", .m)
        var lines = s.components(separatedBy: "\n")
        var k = 0
        while k < 4 && !lines.isEmpty {
            let l = lines[0].trimmed
            if l.isEmpty { lines.removeFirst(); continue }
            let ct = chapterTitle ?? ""
            let head = Rx.isMatch(l, "^#{1,2}\\s") || (Rx.isMatch(l, "^#{3,6}\\s") && (fiction || Rx.isMatch(l, "^#+\\s*(kapitel|teil|chapter)\\s*\\d", .i))) || (!ct.isEmpty && Knowledge.norm(l).trim("* #:").rep("*", "") == Knowledge.norm(ct).trimmed)
            let chatter = Rx.isMatch(l, rxPreamble, .i) && (l.hasSuffix(":") || l.len < 90)
            let boldTitle = Rx.isMatch(l, "^\\*\\*[^*]{1,120}\\*\\*:?$")
            let label = Rx.isMatch(l, "^(kapitel|teil|chapter|part)\\s+\\d+[^.!?]{0,80}$", .i)
            if head || chatter || boldTitle || label { lines.removeFirst(); k += 1; continue }
            break
        }
        k = 0
        while k < 4 && !lines.isEmpty {
            let l = lines[lines.count - 1].trimmed
            if l.isEmpty || Rx.isMatch(l, rxTrailer, .i) { lines.removeLast(); k += 1; continue }
            break
        }
        var outp = [String]()
        for raw in lines {
            var l = raw.trimEnd()
            if fiction {
                if let hm = Rx.match(l.trimmed, "^#{1,6}\\s*(.*)$") { if hm.group(1).trimmed.isEmpty { outp.append("* * *") }; continue } // Ueberschriften gehoeren nicht in Romantext
                l = l.rep("**", "")
            }
            outp.append(l)
        }
        s = outp.joined(separator: "\n")
        s = Rx.replace(s, "\n{3,}", "\n\n").trimmed
        return s
    }
    /// Kuerzt auf den letzten vollstaendigen Satz (bei abgeschnittenen Antworten).
    public static func trimToSentence(_ s0: String?) -> String {
        let s = (s0 ?? "").trimEnd()
        if s.isEmpty { return s }
        let u = Array(s.utf16)
        let closers: Set<UInt16> = [46, 33, 63, 0x2026, 0x201c, 34, 0xab, 0xbb, 41]
        if closers.contains(u[u.count - 1]) { return s }
        var best = -1
        var i = u.count - 1
        while i >= max(0, u.count - 1500) {
            let c = u[i]
            if c == 46 || c == 33 || c == 63 || c == 0x2026 {
                var end = i + 1
                while end < u.count && (u[end] == 0x201c || u[end] == 34 || u[end] == 0xab || u[end] == 41) { end += 1 }
                best = end; break
            }
            i -= 1
        }
        return best > 0 ? s.sub(0, best).trimEnd() : s
    }
    static let englishWords: Set<String> = ["the", "and", "was", "were", "with", "that", "his", "her", "she", "he", "they", "you", "of", "to", "it", "in", "for", "had", "not", "but", "on", "at", "from", "said"]
    static let germanWords: Set<String> = ["der", "die", "das", "und", "ist", "war", "nicht", "sie", "er", "ich", "mit", "auf", "dem", "den", "ein", "eine", "zu", "es", "sich", "als", "auch", "dass", "wie", "aus"]
    public static func looksEnglish(_ s0: String?) -> Bool {
        let s = s0 ?? ""
        var en = 0, de = 0
        for m in Rx.matches(s.len > 4000 ? s.sub(0, 4000) : s, "[A-Za-zäöüß]+") {
            let w = m.value.lowercased()
            if englishWords.contains(w) { en += 1 }
            if germanWords.contains(w) { de += 1 }
        }
        return en >= 12 && en > de * 2
    }
    static func shingles(_ s: String?, _ n: Int) -> Set<String> {
        let words = Rx.matches((s ?? "").lowercased(), "[\\wäöüß]+").map { $0.value }
        var set = Set<String>()
        var i = 0
        while i + n <= words.count { set.insert(words[i..<i + n].joined(separator: " ")); i += 1 }
        return set
    }
    /// Anteil der 8-Wort-Folgen eines neuen Teils, die schon im bisherigen Text vorkommen (0..1).
    public static func overlap(_ previous: String?, _ part: String?) -> Double {
        let a = shingles(part, 8)
        if a.count < 10 { return 0 }
        let b = shingles(previous, 8)
        if b.isEmpty { return 0 }
        return Double(a.filter { b.contains($0) }.count) / Double(a.count)
    }
    /// Wiederholt sich der Teil selbst (Schleife)?
    public static func hasLoop(_ part: String?) -> Bool {
        let sentences = Rx.split(part ?? "", "(?<=[.!?…])\\s+").map { $0.trimmed }.filter { $0.len >= 40 }
        if Dictionary(grouping: sentences, by: { $0 }).contains(where: { $0.value.count >= 3 }) { return true }
        let paras = (part ?? "").components(separatedBy: "\n\n").filter { !$0.isEmpty }.map { $0.trimmed }.filter { $0.len >= 120 }
        return Dictionary(grouping: paras, by: { $0 }).contains(where: { $0.value.count >= 2 })
    }

    // ------------------------------------------------ Prompts
    func writerSystem(_ p: BookPlan) -> String {
        var b = "Du bist VYRA, eine erfahrene Buchautorin und Lektorin. Du schreibst ein vollständiges Buch Teil für Teil in druckreifem " + p.language + ".\n"
        b += "Du lieferst ausschließlich den Buchtext dieses Teils – keine Vorrede, keine Überschrift, keine Kapitelnummer, keine Erklärung, keine Zusammenfassung, keine Fragen an den Nutzer, kein Fettdruck.\n"
        b += "Du hältst Figuren, Namen, Fakten, Zeitlinie, Erzählperspektive und Ton strikt konsistent mit der Buchbibel und dem bisherigen Text. Du wiederholst keine Sätze, Bilder oder Formulierungen aus dem bisherigen Text.\n"
        if p.kind == "sachbuch" { b += "Sachbuch-Stil: klar, sachlich, anschaulich, mit konkreten Beispielen und praktischen Schritten. Zwischenüberschriften als eigene Zeile mit ### sind erlaubt, Aufzählungen mit »- «. Erfinde keine Studien, Statistiken, Zitate, Personen oder Quellen; Beispiele kennzeichnest du als Beispiele. Keine Rechts-, Medizin- oder Finanzversprechen.\n" }
        else if p.kind == "kinderbuch" { b += "Kinderbuch-Stil: warmherzig, bildhaft, kurze klare Sätze, kindgerechte Wörter, wiederkehrende Motive, liebevolle Dialoge, nichts Ängstigendes ohne gutes Ende.\n" }
        else { b += "Erzählstil: zeigen statt erzählen – konkrete Sinneseindrücke, Handlungen, innere Regungen, lebendige Dialoge in „Anführungszeichen“. Abwechslungsreiche Satzlängen, starke Verben, keine Floskeln und Klischees, keine Moral am Ende. Szenenwechsel als eigene Zeile »* * *«.\n" }
        b += "Absätze trennst du durch eine Leerzeile. Du schreibst immer den vollen gewünschten Umfang."
        return b
    }
    func bible(_ p: BookPlan, _ maxChars: Int) -> String {
        var b = "BUCHBIBEL\nTitel: " + p.title
        if !p.subtitle.isEmpty { b += " – " + p.subtitle }
        b += "\n"
        b += "Art: " + BookWriter.kindName(p.kind) + (p.genre.isEmpty ? "" : " · " + p.genre) + "\n"
        if !p.audience.isEmpty { b += "Zielgruppe: " + p.audience + "\n" }
        if !p.perspective.isEmpty { b += "Erzählperspektive: " + p.perspective + "\n" }
        if !p.tone.isEmpty { b += "Ton und Stil: " + p.tone + "\n" }
        if !p.setting.isEmpty { b += "Schauplatz und Zeit: " + p.setting + "\n" }
        if !p.premise.isEmpty { b += "Prämisse: " + p.premise + "\n" }
        if !p.characters.isEmpty {
            b += "Figuren:\n"
            for c in p.characters { b += "- " + c[0] + (c[1].isEmpty ? "" : " (" + c[1] + ")") + (c[2].isEmpty ? "" : ": " + c[2]) + "\n" }
        }
        return b.len > maxChars ? b.sub(0, maxChars) + "…\n" : b
    }
    public static func kindName(_ k: String) -> String { k == "kinderbuch" ? "Kinderbuch" : k == "sachbuch" ? "Sachbuch/Ratgeber" : k == "sammlung" ? "Sammlung" : "Roman" }
    func storySoFar(_ p: BookPlan, _ chapter: Int, _ maxChars: Int) -> String {
        if chapter == 0 || maxChars < 200 { return "" }
        var items = [String]()
        for k in 0..<chapter {
            let c = p.chapters[k]
            var sum = c.summary.isEmpty ? c.synopsis : c.summary
            if k < chapter - 4 { let dot = sum.indexOf(". "); if dot > 40 { sum = sum.sub(0, dot + 1) } }
            items.append("Kapitel \(k + 1) „" + c.title + "“: " + sum)
        }
        while items.count > 1 && items.reduce(0, { $0 + $1.len + 1 }) > maxChars { items.removeFirst() }
        let s = items.joined(separator: "\n")
        return s.len > maxChars ? s.sub(s.len - maxChars) : s
    }
    func facts(_ p: BookPlan, _ maxChars: Int) -> String {
        if p.facts.isEmpty || maxChars < 100 { return "" }
        var b = ""
        for f in p.facts.reversed() { let line = "- " + f + "\n"; if b.len + line.len > maxChars { break }; b = line + b }
        return b
    }
    func partTokens(_ p: BookPlan) -> Int { min(big ? 3600 : 2200, Int(Double(p.partWords) * 2.3) + 200) }

    // ------------------------------------------------ Planen
    func plan(_ p: BookPlan, _ r: BookRequest, _ token: CancelToken) async throws {
        if p.premise.isEmpty { try await concept(p, r, token) }
        try await outline(p, token)
    }
    func concept(_ p: BookPlan, _ r: BookRequest, _ token: CancelToken) async throws {
        let sp = begin("plan", "Buchkonzept entwickeln")
        do {
            let person = BookWriter.obj(("type", "object"), ("properties", BookWriter.obj(("name", BookWriter.obj(("type", "string"))), ("rolle", BookWriter.obj(("type", "string"))), ("beschreibung", BookWriter.obj(("type", "string"))))), ("required", ["name", "rolle", "beschreibung"] as [Any]))
            let schema = BookWriter.obj(("type", "object"), ("properties", BookWriter.obj(("titel", BookWriter.obj(("type", "string"))), ("untertitel", BookWriter.obj(("type", "string"))), ("genre", BookWriter.obj(("type", "string"))), ("zielgruppe", BookWriter.obj(("type", "string"))), ("erzaehlperspektive", BookWriter.obj(("type", "string"))), ("ton", BookWriter.obj(("type", "string"))), ("schauplatz", BookWriter.obj(("type", "string"))), ("praemisse", BookWriter.obj(("type", "string"))),
                                                                                       ("figuren", BookWriter.obj(("type", "array"), ("maxItems", 12.0), ("items", person))))), ("required", ["titel", "untertitel", "genre", "zielgruppe", "ton", "praemisse", "figuren"] as [Any]))
            let ask = "Wunsch des Nutzers: " + rText(p) + "\n\nArt: " + BookWriter.kindName(p.kind) + ". Sprache: " + p.language + ". Umfang: \(p.chapters.count) Kapitel mit je etwa \(p.wordsPerChapter) Wörtern.\n" +
                "Entwickle wie eine erfahrene Lektorin das Konzept für ein vollständiges, fesselndes Buch: treffender Titel, Untertitel, Genre, Zielgruppe, " + (p.fiction ? "Erzählperspektive (z. B. Ich-Perspektive, personal, auktorial; Vergangenheit), " : "") + "Ton und Stil, Schauplatz und Zeit, Prämisse (5–8 Sätze: Ausgangslage, zentraler Konflikt oder Kernfrage, was auf dem Spiel steht, Ziel), " +
                (p.fiction ? "und die wichtigsten Figuren mit Rolle und prägnanter Beschreibung (Aussehen, Wesen, Wunsch, Schwäche)." : "und bei Bedarf wichtige Personen oder Beispiele (sonst leere Liste).") +
                (r.title.isEmpty ? "" : " Der Titel lautet genau: „" + r.title + "“.") + " Antworte NUR mit JSON."
            var o: Any?
            var attempt = 0
            while attempt < 2 && o == nil {
                o = Researcher.jsonIn(try await brain.complete(writerSystemPlain(p), BookWriter.one(ask), nil, GenOptions.structured(schema, big ? 1800 : 1100), token))
                if Json.str(o, "titel").trimmed.isEmpty { o = nil }
                attempt += 1
            }
            if let o = o {
                p.title = !r.title.isEmpty ? r.title : Json.str(o, "titel").trimmed.trim("\"„“")
                p.subtitle = Json.str(o, "untertitel").trimmed; p.genre = Json.str(o, "genre").trimmed; p.audience = Json.str(o, "zielgruppe").trimmed
                p.perspective = Json.str(o, "erzaehlperspektive").trimmed; p.tone = Json.str(o, "ton").trimmed; p.setting = Json.str(o, "schauplatz").trimmed; p.premise = Json.str(o, "praemisse").trimmed
                for f in Json.arr(o, "figuren").prefix(12) { let n = Json.str(f, "name").trimmed; if !n.isEmpty { p.characters.append([n, Json.str(f, "rolle").trimmed, Json.str(f, "beschreibung").trimmed]) } }
                end(sp, "„" + p.title + "“ · " + (p.genre.isEmpty ? "" : p.genre + " · ") + "\(p.characters.count)" + (p.characters.count == 1 ? " Figur" : " Figuren"), false)
            } else {
                p.title = !r.title.isEmpty ? r.title : ChatStore.makeTitle(p.request); p.premise = p.request
                end(sp, "vereinfacht (kein gültiger Plan)", true)
            }
        } catch {
            if error.isCancellation { throw error }
            if p.title.isEmpty { p.title = !r.title.isEmpty ? r.title : ChatStore.makeTitle(p.request) }
            if p.premise.isEmpty { p.premise = p.request }
            end(sp, error.vyraMessage, true)
        }
        p.save()
    }
    /// Kapitelplan in Bloecken (bleibt auch bei kleinem Kontext stabil). Bereits geplante Bloecke bleiben beim Fortsetzen erhalten.
    func outline(_ p: BookPlan, _ token: CancelToken) async throws {
        let total = p.chapters.count
        let batch = big ? 8 : 6
        var a = 0
        while a < total {
            defer { a += batch }
            try token.check()
            let n = min(batch, total - a)
            if p.chapters[a..<a + n].allSatisfy({ !$0.title.isEmpty && !$0.synopsis.isEmpty }) { continue }
            let so = begin("plan", "Kapitel \(a + 1)" + (n > 1 ? "–\(a + n)" : "") + " von \(total) planen")
            do {
                let item = BookWriter.obj(("type", "object"), ("properties", BookWriter.obj(("titel", BookWriter.obj(("type", "string"))), ("inhalt", BookWriter.obj(("type", "string"))))), ("required", ["titel", "inhalt"] as [Any]))
                let schema = BookWriter.obj(("type", "object"), ("properties", BookWriter.obj(("kapitel", BookWriter.obj(("type", "array"), ("minItems", Double(n)), ("maxItems", Double(n)), ("items", item))))), ("required", ["kapitel"] as [Any]))
                var before = ""
                for k in 0..<a { let syn = p.chapters[k].synopsis; before += "\(k + 1). " + p.chapters[k].title + ": " + (syn.len > 220 ? syn.sub(0, 220) + "…" : syn) + "\n" }
                let arc = p.fiction ? "Dramaturgie über alle \(total) Kapitel: Anfang (bis Kapitel \(max(1, Int((Double(total) * 0.2).rounded(.toNearestOrEven))))) Einführung und auslösendes Ereignis; dann steigende Komplikationen und eine Wende in der Mitte (um Kapitel \(max(1, Int((Double(total) * 0.5).rounded(.toNearestOrEven))))); danach Zuspitzung bis zum tiefsten Punkt (um Kapitel \(max(1, Int((Double(total) * 0.8).rounded(.toNearestOrEven))))); die letzten Kapitel Höhepunkt und befriedigende Auflösung aller Handlungsfäden."
                    : "Aufbau über alle \(total) Kapitel: von den Grundlagen über Vertiefung und Praxis bis zu Zusammenfassung und nächsten Schritten; jedes Kapitel hat ein klares Thema ohne Wiederholungen."
                let ask = bible(p, 4000) + "\n" + (before.isEmpty ? "" : "Bereits geplante Kapitel:\n" + (before.len > 6000 ? before.sub(before.len - 6000) : before) + "\n") + arc + "\n\nPlane jetzt die Kapitel \(a + 1) bis \(a + n) von \(total). Für jedes Kapitel: ein ausdrucksstarker Titel (ohne »Kapitel« und ohne Nummer) und eine Inhaltsangabe mit 3–5 Sätzen, die konkret sagt, was passiert" + (p.fiction ? " (Ereignisse, Entscheidungen, Wendungen, Stand am Kapitelende)" : " (Kernaussagen, Beispiele, praktische Schritte)") + ". Jedes Kapitel bringt die Handlung spürbar voran. Antworte NUR mit JSON: {\"kapitel\":[{\"titel\":\"…\",\"inhalt\":\"…\"}]}"
                var o: Any?
                var attempt = 0
                while attempt < 2 && o == nil {
                    o = Researcher.jsonIn(try await brain.complete(writerSystemPlain(p), BookWriter.one(ask), nil, GenOptions.structured(schema, min(big ? 3600 : 2400, n * 260 + 300)), token))
                    if Json.arr(o, "kapitel").isEmpty { o = nil }
                    attempt += 1
                }
                let arr = Json.arr(o, "kapitel")
                for k in 0..<n {
                    let ch = p.chapters[a + k]
                    if k < arr.count {
                        var tt = Json.str(arr[k], "titel").trimmed
                        tt = Rx.replace(tt, "^(kapitel|chapter|teil)\\s*\\d+\\s*[:.\\-–]?\\s*", "", .i).trim("\"„“ ")
                        ch.title = tt.isEmpty ? "Kapitel \(a + k + 1)" : tt
                        ch.synopsis = Json.str(arr[k], "inhalt").trimmed
                    } else if ch.title.isEmpty { ch.title = "Kapitel \(a + k + 1)" }
                }
                end(so, arr.count >= n ? p.chapters[a..<a + n].map { $0.title }.joined(separator: " · ") : "vereinfacht", arr.count < n)
            } catch {
                if error.isCancellation { throw error }
                for k in 0..<n where p.chapters[a + k].title.isEmpty { p.chapters[a + k].title = "Kapitel \(a + k + 1)" }
                end(so, error.vyraMessage, true)
            }
            p.save()
        }
    }
    func rText(_ p: BookPlan) -> String { p.request.len > 2500 ? p.request.sub(0, 2500) + "…" : p.request }
    func writerSystemPlain(_ p: BookPlan) -> String { "Du bist VYRA, eine erfahrene Lektorin und Buchautorin. Du planst Bücher klar, originell und stimmig und antwortest exakt im verlangten JSON-Format auf " + p.language + "." }

    // ------------------------------------------------ Schreiben
    func writePart(_ p: BookPlan, _ ci: Int, _ pi: Int, _ parts: Int, _ show: ((String) -> Void)?, _ problems: inout [String], _ token: CancelToken) async throws -> String {
        let ch = p.chapters[ci]
        let target = max(120, p.wordsPerChapter / parts)
        let maxTok = max(400, min(partTokens(p), Int(Double(target) * 2.3) + 200))
        let chapterSoFar = ch.parts.joined(separator: "\n\n")
        var prevChapterEnd = ""
        if chapterSoFar.isEmpty && ci > 0 { let t = p.chapterText(p.chapters[ci - 1]); prevChapterEnd = t.len > 1200 ? t.sub(t.len - 1200) : t }
        let budget = max(4000, brain.contextChars - Int(Double(maxTok) * 2.9) - writerSystem(p).len - 900)
        let tailChars = min(big ? 2600 : 1500, budget / 4)
        let tail = chapterSoFar.len > tailChars ? "…" + chapterSoFar.sub(chapterSoFar.len - tailChars) : chapterSoFar
        let bib = bible(p, min(4000, budget / 3))
        let fac = facts(p, min(2500, budget / 6))
        let storyBudget = max(300, budget - bib.len - fac.len - tail.len - prevChapterEnd.len - ch.synopsis.len - 1200)
        let story = storySoFar(p, ci, min(big ? 9000 : 4000, storyBudget))
        let next = ci + 1 < p.chapters.count ? p.chapters[ci + 1] : nil
        var b = bib
        if !fac.isEmpty { b += "\nFeste Fakten (müssen stimmen):\n" + fac }
        if !story.isEmpty { b += "\nBisherige Handlung:\n" + story + "\n" }
        b += "\nAKTUELLES KAPITEL \(ci + 1) von \(p.chapters.count): „" + ch.title + "“\nInhalt dieses Kapitels: " + (ch.synopsis.isEmpty ? "(frei, passend zur Prämisse)" : ch.synopsis) + "\n"
        if let nx = next { b += "Danach folgt Kapitel \(ci + 2) „" + nx.title + "“ – nimm es NICHT vorweg.\n" }
        else { b += "Dies ist das LETZTE Kapitel des Buches.\n" }
        if !tail.isEmpty { b += "\nBisheriger Text dieses Kapitels (Ende):\n" + tail + "\n" }
        else if !prevChapterEnd.isEmpty { b += "\nEnde des vorigen Kapitels (nur zur Anschlussfähigkeit, nicht wiederholen):\n…" + prevChapterEnd + "\n" }
        b += "\nAUFGABE: Schreibe Teil \(pi + 1) von \(parts) dieses Kapitels mit etwa \(target) Wörtern. "
        if pi == 0 { b += p.fiction ? "Beginne mit einem starken, szenischen Einstieg (kein Wetterbericht, kein Aufwachen). " : "Beginne mit einem klaren Einstieg ins Thema, der neugierig macht. " }
        if pi < parts - 1 { b += "Schließe das Kapitel noch NICHT ab: Höre an einer natürlichen Stelle mitten im Geschehen auf, sodass der nächste Teil direkt anschließen kann. " }
        else { b += next != nil ? "Führe das Kapitel zu dem in der Inhaltsangabe beschriebenen Ende, gern mit einem Sog zum nächsten Kapitel. " : "Führe das Buch zu einem runden, befriedigenden Ende und löse die offenen Handlungsfäden auf. " }
        b += "Schreibe direkt den Buchtext auf " + p.language + "."
        let prompt = b
        var recent = (ci > 0 ? p.chapterText(p.chapters[ci - 1]) : "") + "\n\n" + chapterSoFar
        if recent.len > 30000 { recent = recent.sub(recent.len - 30000) }
        var best: String?
        var bestScore = Double.greatestFiniteMagnitude
        for attempt in 0..<2 {
            try token.check()
            let opt = GenOptions(); opt.maxTokens = maxTok; opt.temperature = attempt == 0 ? 0.8 : 0.9; opt.topP = 0.92; opt.topK = 40; opt.minP = 0.05; opt.presencePenalty = attempt == 0 ? 0.3 : 0.8
            let extra = attempt == 0 ? "" : "\n\nWICHTIG: Der vorige Versuch " + (!problems.isEmpty ? "hatte ein Problem (" + problems[problems.count - 1] + ")" : "war unbrauchbar") + ". Schreibe einen neuen, eigenständigen Text ohne Wiederholungen, vollständig auf " + p.language + "."
            let raw = try await brain.complete(writerSystem(p), BookWriter.one(prompt + extra), show, opt, token)
            let cut = brain.lastFinish == "length" || brain.lastFinish == "max_tokens"
            var text = BookWriter.cleanPart(raw, p.fiction, ch.title)
            if cut { text = BookWriter.trimToSentence(text) }
            let words = BookWriter.countWords(text)
            let ov = BookWriter.overlap(recent, text)
            let loop = BookWriter.hasLoop(text)
            let english = p.language == "Deutsch" && BookWriter.looksEnglish(text)
            let issue: String? = Double(words) < max(60, Double(target) * 0.3) ? "zu kurz (\(words) Wörter)" : loop ? "Wiederholungsschleife" : english ? "falsche Sprache" : ov > 0.2 ? "wiederholt bisherigen Text" : nil
            let score = (issue == nil ? 0 : 1000) + ov * 100 + (Double(words) < Double(target) * 0.5 ? (Double(target) * 0.5 - Double(words)) / 10.0 : 0)
            if best == nil || score < bestScore { best = text; bestScore = score }
            if issue == nil { break }
            problems.append("Kapitel \(ci + 1), Teil \(pi + 1): " + issue!)
        }
        // Zu kurz geratene Teile einmal fortsetzen lassen.
        if let bst = best, Double(BookWriter.countWords(bst)) < Double(target) * 0.55 && bestScore < 1000 {
            let opt = GenOptions(); opt.maxTokens = maxTok; opt.temperature = 0.8; opt.topP = 0.92; opt.topK = 40; opt.minP = 0.05; opt.presencePenalty = 0.4
            let more = try await brain.complete(writerSystem(p), BookWriter.one(prompt + "\n\nBereits geschrieben (setze GENAU hier fort, nichts wiederholen):\n…" + (bst.len > 2500 ? bst.sub(bst.len - 2500) : bst) + "\n\nSchreibe jetzt weiter, etwa \(target - BookWriter.countWords(bst)) Wörter."), show, opt, token)
            var add = BookWriter.cleanPart(more, p.fiction, ch.title)
            if brain.lastFinish == "length" || brain.lastFinish == "max_tokens" { add = BookWriter.trimToSentence(add) }
            if BookWriter.countWords(add) > 30 && BookWriter.overlap(bst, add) < 0.2 && !BookWriter.hasLoop(add) { best = bst + "\n\n" + add }
        }
        return best ?? ""
    }
    func summarize(_ p: BookPlan, _ ci: Int, _ text: String, _ token: CancelToken) async throws {
        let ch = p.chapters[ci]
        let ss = begin("check", "Kapitel \(ci + 1) zusammenfassen und Fakten sichern")
        do {
            let schema = BookWriter.obj(("type", "object"), ("properties", BookWriter.obj(("zusammenfassung", BookWriter.obj(("type", "string"))), ("fakten", BookWriter.obj(("type", "array"), ("maxItems", 8.0), ("items", BookWriter.obj(("type", "string"))))))), ("required", ["zusammenfassung", "fakten"] as [Any]))
            let room = max(3000, brain.contextChars - 3500)
            let body = text.len > room ? text.sub(0, room * 2 / 5) + "\n[…]\n" + text.sub(text.len - room * 3 / 5) : text
            let ask = "Buch: „" + p.title + "“ (" + BookWriter.kindName(p.kind) + ")\nKapitel \(ci + 1) „" + ch.title + "“:\n" + body + "\n\nFasse dieses Kapitel für die Fortsetzung zusammen: 4–6 Sätze mit allen wichtigen Ereignissen, Entscheidungen und dem Stand am Kapitelende. Liste außerdem bis zu 8 neue feste Fakten auf, die später stimmen müssen (Namen, Orte, Beziehungen, Gegenstände, Verletzungen, Zeitpunkte, Versprechen). Antworte NUR mit JSON: {\"zusammenfassung\":\"…\",\"fakten\":[\"…\"]}"
            let o = Researcher.jsonIn(try await brain.complete("Du bist eine sorgfältige Lektorin. Du fasst Buchkapitel genau und knapp zusammen und antwortest nur mit JSON.", BookWriter.one(ask), nil, GenOptions.structured(schema, big ? 900 : 700), token))
            let sum = Json.str(o, "zusammenfassung").trimmed
            ch.summary = sum.len > 20 ? sum : ch.synopsis
            for f in Json.arr(o, "fakten").prefix(8) {
                let fact = Json.text(f).trimmed
                if fact.len > 3 && !p.facts.contains(where: { $0.lowercased() == fact.lowercased() }) { p.facts.append(fact.len > 220 ? fact.sub(0, 220) : fact) }
            }
            let cap = big ? 80 : 30
            if p.facts.count > cap { p.facts.removeFirst(p.facts.count - cap) }
            end(ss, sum.len > 20 ? "gesichert" : "Inhaltsangabe übernommen", sum.len <= 20)
        } catch {
            if error.isCancellation { throw error }
            ch.summary = ch.synopsis; end(ss, error.vyraMessage, true)
        }
    }

    // ------------------------------------------------ Gesamtablauf
    public func write(_ request: String?, _ resume: BookPlan?, _ onText: ((String) -> Void)?, _ token: CancelToken) async throws -> BookResult {
        let res = BookResult()
        let p: BookPlan
        if let rp = resume {
            p = rp
            if pro { p.pro = true }
            if !p.finished && p.chapters.contains(where: { !$0.done && ($0.title.isEmpty || $0.synopsis.isEmpty) }) {
                // Abbruch waehrend der Planung: fehlende Planteile ergaenzen (Konzept und fertige Bloecke bleiben).
                let r = BookRequest(); r.title = p.title; r.kind = p.kind; r.format = p.pageFormat; r.language = p.language; r.chapters = p.chapters.count; r.wordsPerChapter = p.wordsPerChapter; r.partWords = p.partWords
                try await plan(p, r, token); p.save()
            }
        } else {
            let r = BookWriter.parse(request, big, defaultFormat)
            res.problems.append(contentsOf: r.notes)
            p = BookPlan()
            p.request = request ?? ""; p.kind = r.kind; p.pageFormat = r.format ?? "6x9"; p.author = !r.author.isEmpty ? r.author : defaultAuthor.trimmed; p.language = r.language; p.wordsPerChapter = r.wordsPerChapter; p.partWords = r.partWords; p.pro = pro
            for _ in 0..<r.chapters { p.chapters.append(BookChapterPlan()) }
            let baseName = DocWriter.safeName(!r.title.isEmpty ? r.title : ChatStore.makeTitle(request ?? ""))
            var folder = FS.join(booksRoot, baseName)
            var k = 2
            while FS.exists(folder) { folder = FS.join(booksRoot, baseName + " (\(k))"); k += 1 }
            p.folder = folder; p.title = !r.title.isEmpty ? r.title : ChatStore.makeTitle(request ?? ""); p.save()
            folderChosen?(folder)
            try await plan(p, r, token)
            p.save()
        }
        res.plan = p
        for i in 0..<p.chapters.count where p.chapters[i].title.isEmpty { p.chapters[i].title = "Kapitel \(i + 1)" }
        let parts = p.partsPerChapter
        for ci in 0..<p.chapters.count {
            let ch = p.chapters[ci]
            if ch.done { continue }
            var pi = ch.parts.count
            while pi < parts {
                defer { pi += 1 }
                try token.check()
                let sw = begin("write", "Kapitel \(ci + 1)/\(p.chapters.count)" + (parts > 1 ? " · Teil \(pi + 1)/\(parts)" : "") + ": " + ch.title)
                let header = progress(p, ci, pi, parts)
                let sofar = ch.parts.joined(separator: "\n\n")
                let shown = sofar.len > 1800 ? "…" + sofar.sub(sofar.len - 1800) : sofar
                var probs = [String]()
                let fiction = p.fiction, title = ch.title
                let part = try await writePart(p, ci, pi, parts, { s in onText?(header + shown + (shown.isEmpty ? "" : "\n\n") + BookWriter.cleanPart(s, fiction, title)) }, &probs, token)
                res.problems.append(contentsOf: probs)
                if part.trimmed.isEmpty { end(sw, "kein Text – Teil wird übersprungen", true); res.problems.append("Kapitel \(ci + 1), Teil \(pi + 1): kein brauchbarer Text."); continue }
                ch.parts.append(part); p.save()
                end(sw, "\(BookWriter.countWords(part)) Wörter", false)
            }
            let text = ch.parts.joined(separator: "\n\n").trimmed
            try FS.mkdir(FS.join(p.folder, "Kapitel"))
            let rel = "Kapitel/Kapitel-" + String(ci + 1).padLeft(2, "0") + ".md"
            guard let full = AppBuilder.insideFolder(p.folder, rel) else { throw VyraError("Ungültiger Kapitelpfad.", .io) }
            try FS.write(full, text: text)
            ch.file = rel; ch.words = BookWriter.countWords(text)
            try await summarize(p, ci, text, token)
            ch.done = true; ch.parts.removeAll(); p.save()
        }
        // Klappentext und Ausgabe
        if p.blurb.isEmpty {
            let sb = begin("write", "Klappentext schreiben")
            do {
                var sums = p.chapters.enumerated().map { "\($0.offset + 1). " + $0.element.title + ": " + ($0.element.summary.isEmpty ? $0.element.synopsis : $0.element.summary) }.joined(separator: "\n")
                if sums.len > 9000 { sums = sums.sub(0, 9000) }
                let opt = GenOptions(); opt.maxTokens = 600; opt.temperature = 0.7; opt.topP = 0.9; opt.topK = 40
                let blurb = try await brain.complete(writerSystem(p), BookWriter.one(bible(p, 3500) + "\nKapitelübersicht:\n" + sums + "\n\nSchreibe den Klappentext für die Buchrückseite (110–170 Wörter): packender erster Satz, " + (p.fiction ? "Hauptfigur, Konflikt und was auf dem Spiel steht, Spannung – ohne das Ende zu verraten" : "Nutzen für die Leser, was sie lernen und für wen das Buch ist") + ". Nur der Text."), nil, opt, token)
                p.blurb = BookWriter.cleanPart(blurb, true, "")
                end(sb, "\(BookWriter.countWords(p.blurb)) Wörter", false)
            } catch {
                if error.isCancellation { throw error }
                end(sb, error.vyraMessage, true)
            }
        }
        p.finished = true; p.save()
        let sv = begin("save", "Buch setzen und speichern (PDF, Word, Markdown)")
        let name = DocWriter.safeName(p.title)
        let doc = BookDocument()
        doc.title = p.title; doc.subtitle = p.subtitle; doc.author = p.author; doc.format = p.pageFormat; doc.kind = p.kind; doc.chapterLabel = p.language == "Englisch" ? "Chapter" : "Kapitel"
        var md = "# " + p.title + "\n\n"
        if !p.subtitle.isEmpty { md += "*" + p.subtitle + "*\n\n" }
        if !p.author.isEmpty { md += p.author + "\n\n" }
        for i in 0..<p.chapters.count {
            let t = p.chapterText(p.chapters[i])
            doc.chapters.append(BookChapterText(p.chapters[i].title, t))
            md += "## " + doc.chapterLabel + " \(i + 1): " + p.chapters[i].title + "\n\n" + t + "\n\n"
        }
        do {
            let pdf = FS.join(p.folder, name + ".pdf")
            res.pdf = try BookPdf.write(pdf, doc, fontFolder)
            res.files.append(pdf)
            if !(res.pdf!.fontsEmbedded) { res.problems.append("Die Buchschrift fehlt im App-Paket. Das PDF nutzt die Standardschrift Times ohne Einbettung – für den KDP-Druck die App neu installieren.") }
        } catch { res.problems.append("PDF: " + error.vyraMessage) }
        do {
            let docx = FS.join(p.folder, name + ".docx")
            let nl = md.indexOf("\n")
            try DocWriter.writeDocx(docx, p.title, md.sub(nl + 1))
            res.files.append(docx)
        } catch { res.problems.append("Word: " + error.vyraMessage) }
        do { let mdPath = FS.join(p.folder, name + ".md"); try FS.write(mdPath, text: md); res.files.append(mdPath) } catch { res.problems.append("Markdown: " + error.vyraMessage) }
        if !p.blurb.isEmpty { let bp = FS.join(p.folder, "Klappentext.txt"); if (try? FS.write(bp, text: p.blurb + "\r\n", bom: true)) != nil { res.files.append(bp) } }
        end(sv, res.pdf != nil ? "\(res.pdf!.pages) Seiten" : "ohne PDF", res.pdf == nil)
        res.finished = true; res.answer = BookWriter.report(p, res)
        return res
    }
    func progress(_ p: BookPlan, _ ci: Int, _ pi: Int, _ parts: Int) -> String {
        let done = p.wordsWritten
        let total = p.wordsPerChapter * p.chapters.count
        return "## " + p.title + "\n\n**Kapitel \(ci + 1) von \(p.chapters.count)" + (parts > 1 ? " · Teil \(pi + 1) von \(parts)" : "") + ": " + p.chapters[ci].title + "**  \n" + DE.n0(done) + " von etwa " + DE.n0(total) + " Wörtern · Zwischenstand wird laufend gespeichert. Falls etwas unterbricht: »Schreib das Buch weiter«.\n\n---\n\n"
    }
    static func report(_ p: BookPlan, _ res: BookResult) -> String {
        var a = "## " + p.title + "\n\n"
        if !p.subtitle.isEmpty { a += "*" + p.subtitle + "*\n\n" }
        a += "**Kurz gesagt:** Dein " + kindName(p.kind) + " ist fertig – \(p.chapters.count) Kapitel, " + DE.n0(p.wordsWritten) + " Wörter" + (res.pdf != nil ? ", \(res.pdf!.pages) Seiten als PDF" : "") + ".\n\n"
        a += "| Kapitel | Titel | Wörter |\n|---|---|---|\n"
        for i in 0..<p.chapters.count { a += "| \(i + 1) | " + p.chapters[i].title.rep("|", "/") + " | " + DE.n0(p.chapters[i].words) + " |\n" }
        if let pdf = res.pdf {
            a += "\n### Druckfertiges PDF\n- Format: " + pdf.formatName + "\n- Seiten: \(pdf.pages)" + (pdf.pages < 24 ? " (KDP-Taschenbücher brauchen mindestens 24 Seiten)" : "") + "\n- Bundsteg: " + DE.flexible(pdf.gutterInches, maxDigits: 3) + " Zoll + Reserve (passend zur Seitenzahl), gespiegelte Ränder\n- Schrift: " + pdf.fontName + "\n- Inhaltsverzeichnis mit Seitenzahlen, Kolumnentitel, Seitenzahlen, Lesezeichen je Kapitel\n"
        }
        if !p.blurb.isEmpty { a += "\n### Klappentext\n" + p.blurb + "\n" }
        a += "\n> **Tipp:** Lies das Manuskript vor der Veröffentlichung einmal komplett gegen (die Word-Datei liegt daneben). KDP fragt beim Hochladen, ob Inhalte KI-generiert sind – dort wahrheitsgemäß »Ja« angeben.\n"
        var issues = [String]()
        for s in res.problems where !issues.contains(s) { issues.append(s) }
        if !issues.isEmpty {
            a += "\nHinweise:\n"
            for s in issues.prefix(8) { a += "- " + s + "\n" }
            if issues.count > 8 { a += "- … und \(issues.count - 8) weitere\n" }
        }
        a += "\nOrdner: " + Platform.shownPath(p.folder)
        return a
    }
}
