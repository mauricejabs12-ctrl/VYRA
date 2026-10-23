import Foundation

/// Gesicherter Zwischenstand eines Arbeitsauftrags (iOS-Anpassung): Unter iOS kann die App jederzeit in den
/// Hintergrund wechseln oder beendet werden. Nach jedem fertigen Abschnitt wird der Stand gespeichert;
/// »Fortsetzen« macht beim naechsten Abschnitt weiter, statt von vorn zu beginnen.
public final class WorkCheckpoint {
    public let path: String
    public var title = ""
    public var outline = [String]()
    public var head = ""
    public var doc = ""
    public var done = 0
    public var sources = [SearchHit]()
    public var format = ""
    public var task = ""
    public init(_ path: String) { self.path = path }
    public static func load(_ path: String) -> WorkCheckpoint? {
        guard FS.isFile(path), let o = try? Json.parse(FS.readText(path)), Json.str(o, "format") == "vyra-work-1" else { return nil }
        let c = WorkCheckpoint(path)
        c.title = Json.str(o, "title"); c.outline = Json.arr(o, "outline").map { Json.text($0) }; c.head = Json.str(o, "head"); c.doc = Json.str(o, "doc")
        c.done = Int(Json.num(o, "done", 0)); c.format = Json.str(o, "fmt"); c.task = Json.str(o, "task")
        c.sources = Json.arr(o, "sources").map { s in let h = SearchHit(); h.id = Int(Json.num(s, "id", 0)); h.title = Json.str(s, "title"); h.url = Json.str(s, "url"); return h }
        return c
    }
    public func save() {
        let o = Json.obj(("format", "vyra-work-1"), ("title", title), ("outline", outline as [Any]), ("head", head), ("doc", doc), ("done", Double(done)), ("fmt", format), ("task", task),
                         ("sources", sources.map { Json.obj(("id", Double($0.id)), ("title", $0.title), ("url", $0.url)) as Any }))
        try? FS.writeAtomic(path, text: Json.serialize(o)) // legt den Ordner bei Bedarf an
    }
    public func delete() { FS.delete(path) }
}

extension Researcher {
    // ------------------------------------------------ Arbeitsmodus (Dokumente, Tabellen, Dateien, Ordner)
    public func work(_ task: WorkTask, _ onText: ((String) -> Void)?, _ token: CancelToken, checkpoint: WorkCheckpoint? = nil) async throws -> WorkResult {
        let res = WorkResult(); res.folder = task.folder
        let local = brain.local
        let total = brain.contextChars
        let kind = FileFormats.kind(task.format)
        let slides = kind == "slides"
        let minSec = slides ? 4 : 3, maxSec = slides ? (proLocal ? 15 : 10) : (proLocal ? 12 : 7)
        var queries = [String](), outline = [String]()
        var title = task.title
        let organize = task.organize && task.folder != nil
        let resuming = checkpoint != nil && checkpoint!.done > 0 && !checkpoint!.outline.isEmpty && checkpoint!.task == task.text && checkpoint!.format == task.format
        let maxOut = kind == "chat" || kind == "raw" || kind == "data" ? (proLocal ? 6000 : local ? 2600 : 7000) : slides ? (proLocal ? 800 : local ? 500 : 900) : (proLocal ? 1800 : local ? 900 : 1800)
        let wopt = GenOptions(); wopt.maxTokens = maxOut; wopt.temperature = 0.55; wopt.topP = 0.85; wopt.topK = 20
        var head = ""
        if resuming, let c = checkpoint {
            let sr = begin("plan", "Auftrag fortsetzen")
            title = c.title; outline = c.outline; head = c.head; res.sources = c.sources
            end(sr, "\(c.done) von \(c.outline.count) Abschnitten bereits fertig", false)
        } else {
            // 1. Plan (lokal per JSON-Grammatik erzwungen)
            let sp = begin("plan", "Aufgabe planen")
            do {
                let schema = Researcher.obj(("type", "object"), ("properties", Researcher.obj(("titel", Researcher.obj(("type", "string"))), ("suchanfragen", Researcher.strArray(0, task.web ? 4 : 0)), ("gliederung", Researcher.strArray(minSec, maxSec)))), ("required", ["titel", "suchanfragen", "gliederung"] as [Any]))
                let prompt = "Aufgabe des Nutzers: " + task.text + "\n\nPlane die Arbeit. Antworte NUR mit JSON in genau dieser Form:\n{\"titel\": \"kurzer, treffender Titel\", \"suchanfragen\": [\"Websuche 1\", \"Websuche 2\"], \"gliederung\": [\"Überschrift 1\", \"Überschrift 2\", \"Überschrift 3\"]}\n" + (task.web ? "1 bis 4 Suchanfragen (je 3 bis 8 Wörter, verschiedene Aspekte; aktuelles Jahr: \(DE.year))" : "Keine Suchanfragen (leere Liste)") + (slides ? " und 5 bis \(maxSec) Folientitel für eine Präsentation in sinnvoller Reihenfolge (ohne Titelfolie)." : kind == "data" ? " und 3 Überschriften (werden kaum gebraucht)." : " und 3 bis \(maxSec) Überschriften in sinnvoller Reihenfolge.")
                let planText = try await brain.complete(sys(), Researcher.one(prompt), nil, GenOptions.structured(schema, proLocal ? 700 : 400), token)
                let plan = Researcher.jsonIn(planText)
                for q in Json.arr(plan, "suchanfragen") { let s = Json.text(q).trimmed; if s.len > 2 && queries.count < 4 { queries.append(s) } }
                for o in Json.arr(plan, "gliederung") { let s = Json.text(o).trimmed.trimStart("# "); if s.len > 1 && outline.count < maxSec { outline.append(s) } }
                if title.trimmed.isEmpty { title = Json.str(plan, "titel") }
                end(sp, (queries.isEmpty ? "" : "\(queries.count)" + (queries.count == 1 ? " Suchanfrage, " : " Suchanfragen, ")) + "\(outline.count) Abschnitte", false)
            } catch {
                if error.isCancellation { throw error }
                end(sp, "Plan vereinfacht (" + error.vyraMessage + ")", true)
            }
            if task.web && queries.isEmpty { queries.append(Researcher.cleanQuery(task.text.len > 120 ? task.text.sub(0, 120) : task.text)) }
            if outline.isEmpty { outline = ["Überblick", "Details", "Fazit"] }
            if title.trimmed.isEmpty { title = task.text.len > 60 ? task.text.sub(0, 60) : task.text }
            let relevance = task.text + " " + outline.joined(separator: " ")
            let notesBudget = max(3000, total - Int(Double(maxOut) * 2.9) - sys().len - (task.format == "chat" ? 1200 : 2600))
            var notes = ""
            // 2. Anhaenge
            for a in task.attachments where !a.text.isEmpty {
                let sa = begin("file", "Anhang: " + a.name)
                notes += "Datei " + a.name + ":\n" + Passages.select(a.text, relevance, max(1500, notesBudget / 4)).trimmed + "\n\n"
                end(sa, nil, false)
            }
            // 3. Ordner
            if let folder = task.folder {
                let sf = begin("files", "Ordner lesen: " + FS.fileName(folder.trimEnd("/")))
                var entries: [FileEntry]?
                do { entries = try files.list(folder, 2, 400); end(sf, "\(entries!.filter { !$0.folder }.count) Dateien, \(entries!.filter { $0.folder }.count) Ordner", false) }
                catch { if error.isCancellation { throw error }; end(sf, error.vyraMessage, true); res.problems.append(error.vyraMessage) }
                if let entries = entries, !entries.isEmpty {
                    var listing = ""
                    for (i, e) in entries.prefix(250).enumerated() { listing += "\(i + 1). " + (e.folder ? "[Ordner] " : "") + e.rel + (e.folder ? "" : " (\(e.bytes / 1024 + 1) KB)") + "\n" }
                    notes += "Dateien im Ordner \"" + FS.fileName(folder) + "\":\n" + (listing.len > 2500 ? listing.sub(0, 2500) + "…\n" : listing) + "\n"
                    let readable = entries.filter { !$0.folder && DocReader.canRead($0.name) }
                    var pick = Array(readable.prefix(5))
                    if readable.count > 5 {
                        do {
                            var sel = ""
                            for k in 0..<min(readable.count, 120) { sel += "\(k + 1). " + readable[k].rel + "\n" }
                            let schema = Researcher.obj(("type", "object"), ("properties", Researcher.obj(("nummern", Researcher.obj(("type", "array"), ("items", Researcher.obj(("type", "integer"))), ("maxItems", 6.0))))), ("required", ["nummern"] as [Any]))
                            let o = Researcher.jsonIn(try await brain.complete(sys(), Researcher.one("Aufgabe: " + task.text + "\n\nWelche dieser Dateien sollte man für die Aufgabe lesen? Antworte NUR mit JSON: {\"nummern\": [1, 4]} (höchstens 6 Nummern).\n\n" + sel), nil, GenOptions.structured(schema, 80), token))
                            var nums = Json.arr(o, "nummern")
                            if nums.isEmpty, let l = o as? [Any] { nums = l }
                            if !nums.isEmpty {
                                pick = []
                                for x in nums { if let k = Int(Json.text(x)), k >= 1, k <= readable.count, pick.count < 6 { pick.append(readable[k - 1]) } }
                            }
                        } catch { if error.isCancellation { throw error } }
                    }
                    let perFile = max(1200, notesBudget / (2 * max(1, pick.count)))
                    for f in pick {
                        try token.check()
                        let sr = begin("file", "Lese Datei: " + f.rel)
                        do { let text = try files.readText(f.path, 0); notes += "Datei " + f.rel + ":\n" + Passages.select(text, relevance, perFile).trimmed + "\n\n"; end(sr, nil, false) }
                        catch { if error.isCancellation { throw error }; end(sr, error.vyraMessage, true) }
                    }
                    if organize {
                        let so = begin("organize", "Ordnung vorschlagen")
                        do {
                            let flat = entries.filter { !$0.folder }.prefix(150)
                            let lst = flat.map { $0.rel + "\n" }.joined()
                            let item = Researcher.obj(("type", "object"), ("properties", Researcher.obj(("datei", Researcher.obj(("type", "string"))), ("ziel", Researcher.obj(("type", "string"))), ("grund", Researcher.obj(("type", "string"))))), ("required", ["datei", "ziel"] as [Any]))
                            let schema = Researcher.obj(("type", "object"), ("properties", Researcher.obj(("verschiebungen", Researcher.obj(("type", "array"), ("maxItems", 60.0), ("items", item))))), ("required", ["verschiebungen"] as [Any]))
                            let o = Researcher.jsonIn(try await brain.complete(sys(), Researcher.one("Aufgabe: " + task.text + "\n\nDateien (Pfad relativ zum Ordner):\n" + lst + "\nSchlage vor, wie man die Dateien sinnvoll in Unterordner ordnet (nach Thema, Art oder Jahr). Antworte NUR mit JSON: {\"verschiebungen\": [{\"datei\": \"alter/pfad.txt\", \"ziel\": \"Unterordner/pfad.txt\", \"grund\": \"kurz\"}]}. Nichts löschen. Höchstens 60 Einträge. Dateien, die schon passen, weglassen."), nil, GenOptions.structured(schema, 2000), token))
                            var arr = Json.arr(o, "verschiebungen")
                            if arr.isEmpty, let l = o as? [Any] { arr = l }
                            var ops = [MoveOp]()
                            for x in arr { let a = Json.str(x, "datei"), b = Json.str(x, "ziel"); if !a.isEmpty && !b.isEmpty { ops.append(MoveOp(a, b, Json.str(x, "grund"))) } }
                            res.moves = files.validate(folder, ops, &res.problems)
                            end(so, "\(res.moves.count) Verschiebungen vorgeschlagen (warten auf deine Bestätigung)", res.moves.isEmpty)
                        } catch { if error.isCancellation { throw error }; end(so, error.vyraMessage, true) }
                    }
                }
            }
            // 4. Internet
            if task.web && !queries.isEmpty {
                let webBudget = max(2500, notesBudget - notes.len)
                let w = try await gather(queries, proLocal ? (task.think ? ProLimits.webPagesProThink : ProLimits.webPagesPro) : local ? (task.think ? 10 : 6) : 8, webBudget, relevance, res, token)
                if !w.isEmpty { notes += "Suchergebnisse aus dem Internet (abgerufen am " + Researcher.today() + "):\n" + w }
            }
            // 5. Ergebnis schreiben. Die Notizen stehen immer am Anfang: so kann das Modell sie zwischen den Abschnitten wiederverwenden (schneller).
            var allNotes = notes
            if allNotes.len > notesBudget { allNotes = allNotes.sub(0, notesBudget) }
            head = "Arbeitsnotizen (Dateien und Suchergebnisse):\n" + (allNotes.isEmpty ? "(keine)" : allNotes) + "\n\n---\nAufgabe des Nutzers: " + task.text + "\nTitel: " + title + "\nGliederung: " + outline.joined(separator: " | ") + "\n\nRegeln: Schreibe auf Deutsch, sachlich, konkret und gut gegliedert. Belege Aussagen aus den Suchergebnissen mit [Nummer]. Erfinde keine Fakten, Zahlen oder Quellen; wenn etwas fehlt, sag es."
        }
        if kind == "data" {
            // Tabellen (Excel/CSV): Inhalt als strukturiertes JSON erzwingen, dann als echte Datei schreiben.
            let sw = begin("write", "Tabelle erstellen")
            var sheets = [SheetData]()
            do {
                let sheetItem = Researcher.obj(("type", "object"), ("properties", Researcher.obj(("name", Researcher.obj(("type", "string"))), ("spalten", Researcher.strArray(1, 14)), ("zeilen", Researcher.obj(("type", "array"), ("maxItems", 300.0), ("items", Researcher.strArray(0, 14)))))), ("required", ["name", "spalten", "zeilen"] as [Any]))
                let schema = Researcher.obj(("type", "object"), ("properties", Researcher.obj(("blaetter", Researcher.obj(("type", "array"), ("minItems", 1.0), ("maxItems", 4.0), ("items", sheetItem))))), ("required", ["blaetter"] as [Any]))
                let js = try await brain.complete(sys(), Researcher.one(head + "\n\nErstelle jetzt die Tabelle. Antworte NUR mit JSON in dieser Form: {\"blaetter\": [{\"name\": \"Blattname\", \"spalten\": [\"Spalte A\", \"Spalte B\"], \"zeilen\": [[\"Wert\", \"12,5\"]]}]}\nRegeln: Jede Zeile hat so viele Werte wie es Spalten gibt. Zahlen ohne Einheit (Einheit in den Spaltenkopf), Prozent als \"15 %\", Euro als \"9,99 €\". Formeln sind erlaubt und beginnen mit = (z. B. \"=SUMME(B2:B9)\"; Zeile 1 sind die Spaltenköpfe, die erste Datenzeile ist Zeile 2). Für Vorlagen (Budget, Plan, Liste) sinnvolle Beispielwerte, für Fakten nur belegte Werte."), nil, GenOptions.structured(schema, proLocal ? 6000 : local ? 3200 : 9000), token)
                let o = Researcher.jsonIn(js)
                for b in Json.arr(o, "blaetter") {
                    let sh = SheetData(name: Json.str(b, "name"))
                    let head1 = Json.arr(b, "spalten").map { Json.text($0) }
                    if !head1.isEmpty { sh.rows.append(head1) }
                    for r in Json.arr(b, "zeilen") { if let l = r as? [Any] { sh.rows.append(l.map { v in v is JNull ? "" : (v as? Double).map { DE.flexible($0) } ?? Json.text(v) }) } }
                    if !sh.rows.isEmpty { sheets.append(sh) }
                }
            } catch { if error.isCancellation { throw error }; res.problems.append("Tabelle: " + error.vyraMessage) }
            if sheets.isEmpty {
                // Notfalls als Markdown-Tabelle schreiben lassen
                let md = try await brain.complete(sys(), Researcher.one(head + "\n\nErstelle jetzt die Tabelle als Markdown-Tabelle (| Spalte | Spalte |). Nur die Tabelle."), onText, wopt, token)
                sheets = XlsxWriter.fromMarkdown(md, title)
            }
            end(sw, "\(sheets.count)" + (sheets.count == 1 ? " Blatt, " : " Blätter, ") + "\(sheets.reduce(0) { $0 + max(0, $1.rows.count - 1) }) Zeilen", false)
            let sv = begin("save", "Datei speichern")
            do {
                let path = try DocWriter.uniquePath(docFolder, title, task.format == "csv" ? ".csv" : ".xlsx")
                if task.format == "csv" { try FS.write(path, TextCodec.utf8(XlsxWriter.csv(sheets[0]), bom: true)) } else { try XlsxWriter.write(path, sheets) }
                res.files.append(path); end(sv, FS.fileName(path), false)
            } catch { end(sv, error.vyraMessage, true); res.problems.append(error.vyraMessage) }
            var ans = "## " + title + "\n\n"
            for sh in sheets { if sheets.count > 1 { ans += "### " + sh.name + "\n\n" }; ans += XlsxWriter.toMarkdown(sh, 25) + "\n" }
            if sheets.contains(where: { $0.rows.contains(where: { $0.contains(where: { $0.hasPrefix("=") }) }) }) { ans += "\n*Formeln werden beim Öffnen in Excel berechnet.*\n" }
            res.answer = ans
        } else if kind == "raw" {
            // Text- und Code-Dateien (JSON, SVG, Kalender, vCard, YAML, Skripte ...): Inhalt schreiben, pruefen, notfalls einmal reparieren.
            let ext = FileFormats.rawExt(task.format)
            let fname = FileFormats.rawName(task.format) ?? (DocWriter.safeName(title) + "." + ext)
            let extra = ext == "svg" ? "Zeichne eine saubere, moderne Vektorgrafik mit viewBox (keine externen Bilder oder Schriften, klare Formen, höchstens 80 Elemente)." : ext == "ics" ? "iCalendar nach RFC 5545: VERSION:2.0, PRODID, je Termin UID, DTSTAMP, SUMMARY, DTSTART/DTEND (z. B. 20261018T180000)." : ext == "vcf" ? "vCard 3.0 (BEGIN:VCARD, VERSION:3.0, FN, N, ...)." : ext == "json" ? "Gültiges JSON (doppelte Anführungszeichen, keine Kommentare)." : ext == "bat" || ext == "cmd" ? "Windows-Batchdatei mit @echo off und verständlichen Kommentaren (REM)." : ext == "reg" ? "Windows-Registrierungsdatei (Windows Registry Editor Version 5.00), nur ungefährliche Einträge." : ""
            let sw = begin("write", "Datei schreiben: " + fname)
            let outp = try await brain.complete(sys(), Researcher.one(head + "\n\nErstelle jetzt den vollständigen Inhalt der Datei \"" + fname + "\" (" + FileFormats.describe(task.format) + "). " + extra + " Antworte NUR mit einem einzigen Codeblock (```" + ext + " … ```), ohne Erklärung."), onText, wopt, token)
            var content = AppBuilder.extractCode(outp)
            var problem = RawFileCheck.problem(ext, RawFileCheck.normalize(ext, content))
            end(sw, problem == nil ? "geprüft" : "Fehler: " + problem!, problem != nil)
            if let pr = problem {
                let sf = begin("fix", "Behebt den Fehler")
                do {
                    let fixd = AppBuilder.extractCode(try await brain.complete(sys(), Researcher.one("Die Datei \"" + fname + "\" hat einen Fehler: " + pr + "\n\nInhalt:\n```" + ext + "\n" + content + "\n```\n\nGib die vollständige, korrigierte Datei NUR als einen Codeblock zurück."), nil, wopt, token))
                    let p2 = RawFileCheck.problem(ext, RawFileCheck.normalize(ext, fixd))
                    if p2 == nil { content = fixd; problem = nil }
                    end(sf, problem == nil ? "behoben" : problem!, problem != nil)
                } catch { if error.isCancellation { throw error }; end(sf, error.vyraMessage, true) }
            }
            let sv = begin("save", "Datei speichern")
            do {
                let path = try DocWriter.uniquePath(docFolder, FS.stem(fname), "." + ext)
                try FS.write(path, RawFileCheck.encode(ext, RawFileCheck.normalize(ext, content)))
                res.files.append(path); end(sv, FS.fileName(path), false)
            } catch { end(sv, error.vyraMessage, true); res.problems.append(error.vyraMessage) }
            if let p = problem { res.problems.append("Prüfung: " + p) }
            let prev = content.len > 5000 ? content.sub(0, 5000) + "\n…" : content
            res.answer = "**" + fname + "** – " + FileFormats.describe(task.format) + (problem == nil ? " (geprüft)" : "") + "\n\n```" + ext + "\n" + prev + "\n```"
        } else if kind == "chat" {
            if task.think {
                let st = begin("think", "Nachdenken")
                do { res.thoughts = try await brain.complete(sys(), Researcher.one(head + Researcher.thinkPrompt), nil, GenOptions.precise(proLocal ? ProLimits.thinkTokensPro : local ? 1024 : 1500), token); end(st, nil, false) }
                catch { if error.isCancellation { throw error }; end(st, error.vyraMessage, true) }
            }
            let sw = begin("write", "Ergebnis schreiben")
            res.answer = try await brain.complete(sys(), Researcher.one(head + (res.thoughts.isEmpty ? "" : "\n\nDeine Vorüberlegungen:\n" + res.thoughts) + "\n\nSchreibe jetzt das vollständige Ergebnis mit den Überschriften der Gliederung (## Überschrift)."), onText, wopt, token)
            end(sw, nil, false)
        } else {
            var doc = resuming ? checkpoint!.doc : ""
            let start = resuming ? checkpoint!.done : 0
            if let c = checkpoint, !resuming { c.title = title; c.outline = outline; c.head = head; c.doc = ""; c.done = 0; c.format = task.format; c.task = task.text; c.sources = res.sources; c.save() }
            for i in start..<outline.count {
                try token.check()
                let sw = begin("write", "Schreibe Abschnitt \(i + 1)/\(outline.count): " + outline[i])
                let prevChars = proLocal ? 3500 : 1800
                let prev = doc.len > prevChars ? doc.sub(doc.len - prevChars) : doc
                let section = outline[i]
                let ask = slides ? "Schreibe jetzt NUR die Stichpunkte für die Folie \"" + section + "\": 3 bis 6 kurze, aussagekräftige Stichpunkte, jede Zeile beginnt mit \"- \", höchstens 14 Wörter je Punkt. Keine Überschrift, keine Einleitung, nichts wiederholen."
                    : "Schreibe jetzt NUR den Abschnitt \"" + section + "\" (" + (proLocal ? "etwa 300 bis 600" : "etwa 180 bis 350") + " Wörter, Absätze, Listen oder eine Tabelle, wo es passt). Keine Überschrift, kein Titel, nichts wiederholen."
                let docNow = doc
                var part = try await brain.complete(sys(), Researcher.one(head + "\n\nBisher geschrieben (Ende):\n" + (prev.isEmpty ? "(noch nichts)" : prev) + "\n\n" + ask), { t in onText?(docNow + "## " + section + "\n" + t) }, wopt, token)
                part = Rx.replace(part.trimmed, "^#+\\s*" + Rx.escape(section) + "\\s*\\n", "", .i)
                doc += "## " + section + "\n" + part.trimmed + "\n\n"
                end(sw, nil, false)
                if let c = checkpoint { c.doc = doc; c.done = i + 1; c.sources = res.sources; c.save() }
            }
            if !res.sources.isEmpty { doc += "## Quellen\n"; for s in res.sources { doc += "- [\(s.id)] " + s.title + " – " + s.url + "\n" } }
            if !slides { doc += "\n*Erstellt von VYRA KI am " + DE.date() + ". Bitte wichtige Angaben in den Quellen prüfen.*\n" }
            let sv = begin("save", "Datei speichern")
            do { let path = try DocWriter.save(docFolder, title, doc, task.format); res.files.append(path); end(sv, FS.fileName(path), false) }
            catch { end(sv, error.vyraMessage, true); res.problems.append(error.vyraMessage) }
            checkpoint?.delete()
            res.answer = doc
        }
        return res
    }
}
