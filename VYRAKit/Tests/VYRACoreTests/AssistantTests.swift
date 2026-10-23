import Foundation
import XCTest
@testable import VYRACore

/// Ablauf einer Chat-Runde (Port von AiPanel.RunTurn) mit dem Ersatzmodell.
final class AssistantTests: XCTestCase {
    func testDirectAnswersCalcUnitsQuickHelp() async {
        let a = TestEnv.assistant()
        let (v1, th) = await TestEnv.ask(a, "Was ist 12 * (3 + 4)?")
        XCTAssertEqual(v1.message.content, "Was ist 12 * (3 + 4) = **84**")
        XCTAssertEqual(v1.finished, "Exakt berechnet")
        let (v2, _) = await TestEnv.ask(a, "5 km in m", in: th)
        XCTAssertEqual(v2.message.content, "5 km = **5.000 m**")
        let (v3, _) = await TestEnv.ask(a, "100 F in C", in: th)
        XCTAssertTrue(v3.message.content.contains("°C"), v3.message.content)
        a.settings.set("bot.mode", "quick")
        let (v4, _) = await TestEnv.ask(a, "Wie aktiviere ich den FPS-Booster?", in: th)
        XCTAssertEqual(v4.finished, "Schnellhilfe")
        XCTAssertTrue(v4.message.content.contains("FPS-Booster"), v4.message.content)
        XCTAssertTrue(v4.message.content.contains("Windows-App"), v4.message.content)
        // Chat gespeichert (vyra-chat-1)
        XCTAssertTrue(FS.isFile(FS.join(a.store.folder, th.id + ".json")))
        XCTAssertEqual(a.store.loadAll().first?.messages.count, 8)
    }

    func testMemoryCommands() async {
        let a = TestEnv.assistant()
        let (v1, th) = await TestEnv.ask(a, "Merke dir: Ich programmiere am liebsten in Swift.")
        XCTAssertTrue(v1.message.content.hasPrefix("**Gemerkt.**"), v1.message.content)
        XCTAssertEqual(a.memory?.count, 1)
        let (v2, _) = await TestEnv.ask(a, "Was weißt du über mich?", in: th)
        XCTAssertTrue(v2.message.content.contains("Swift"), v2.message.content)
        XCTAssertTrue(a.memoryPrompt(true).contains("Swift"))
        let (v3, _) = await TestEnv.ask(a, "Vergiss alles über mich", in: th)
        XCTAssertEqual(v3.finished, "Gedächtnis")
        XCTAssertEqual(a.memory?.count, 0)
        // Gedaechtnis-Dateien sind verschluesselt (kein Klartext); Chats liegen wie unter Windows als JSON vor.
        let files = FS.allFiles(a.paths.data).filter { FS.size($0) > 0 && !$0.contains("/Chats/") }
        for f in files where (try? FS.readText(f))?.contains("programmiere am liebsten") == true { XCTFail("Klartext in " + f) }
    }

    func testLocalChatTurnStreamsAndMeta() async {
        let e = FakeEngine()
        let a = TestEnv.assistant(e)
        let (v, th) = await TestEnv.ask(a, "Erzähl mir etwas über Leuchttürme.")
        XCTAssertFalse(v.message.content.isEmpty)
        XCTAssertEqual(v.message.error, "")
        let meta = v.finished ?? ""
        XCTAssertTrue(meta.hasPrefix("VYRA Fake"), meta)
        XCTAssertTrue(meta.contains("Grafikeinheit"), meta)
        XCTAssertTrue(meta.contains("12 Tok/s"), meta)
        XCTAssertTrue(e.running)
        XCTAssertFalse(a.isRunning(th))
        XCTAssertEqual(KeepAwake.current, 0)
        // Neu erzeugen ersetzt die Antwort
        var v2: RecordingView!
        await a.regenerate(th, th.messages[1]) { m in v2 = RecordingView(m); return v2 }
        XCTAssertEqual(th.messages.count, 2)
        XCTAssertFalse(v2.message.content.isEmpty)
    }

    func testMissingModelAndMissingKeyMessages() async {
        let e = FakeEngine(); e.modelInstalled = false
        let a = TestEnv.assistant(e)
        let (v, _) = await TestEnv.ask(a, "Hallo, wie geht es dir heute?")
        XCTAssertTrue(v.error.contains("braucht einmalig das Sprachmodell"), v.error)
        a.settings.set("bot.mode", "claude")
        let (v2, _) = await TestEnv.ask(a, "Hallo, wie geht es dir heute?")
        XCTAssertTrue(v2.error.contains("fehlt der API-Schlüssel"), v2.error)
        // kein stiller Wechsel auf ein anderes Modell
        XCTAssertEqual(a.mode, "claude")
    }

    func testUserStopKeepsPartialAnswer() async {
        let e = FakeEngine(); e.delay = 2
        let a = TestEnv.assistant(e)
        let th = ChatThread()
        let task = Task { await TestEnv.ask(a, "Schreib eine lange Geschichte über das Meer.", in: th) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(a.isRunning(th))
        a.stop(th)
        let (v, _) = await task.value
        XCTAssertEqual(v.finished, "Abgebrochen")
        XCTAssertEqual(v.message.error, "Abgebrochen.")
        XCTAssertFalse(a.isRunning(th))
    }

    func testWorkModeDocxInterruptedByBackgroundAndResumed() async throws {
        let e = FakeEngine()
        let a = TestEnv.assistant(e) { s in s.set("work.mode", "work"); s.set("work.format", "docx") }
        let th = ChatThread()
        var sectionsDone = 0
        let lock = NSLock()
        let task = Task { await TestEnv.ask(a, "Schreib einen Bericht über Leuchttürme an der Nordsee", in: th, onStep: { s in
            if s.kind == "write" && s.done { lock.lock(); sectionsDone += 1; let n = sectionsDone; lock.unlock(); if n == 1 { e.delay = 0.6 } }
        }) }
        // warten, bis der erste Abschnitt fertig ist, dann App in den Hintergrund
        for _ in 0..<100 { let n = lock.withLock { sectionsDone }; if n >= 1 { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        a.enterBackground()
        let (v, _) = await task.value
        XCTAssertEqual(v.finished, "Unterbrochen")
        XCTAssertTrue(v.notes.contains { $0.0.contains("Mach weiter") }, "\(v.notes)")
        let cp = try XCTUnwrap(a.pendingWork(th))
        XCTAssertGreaterThanOrEqual(cp.done, 1)
        XCTAssertLessThan(cp.done, cp.outline.count)
        // Fortsetzen
        e.delay = 0
        a.settings.set("work.mode", "chat")
        let (v2, _) = await TestEnv.ask(a, "Mach weiter", in: th)
        XCTAssertTrue(v2.notes.contains { $0.0.contains("Setzt den unterbrochenen Auftrag fort") }, "\(v2.notes)")
        XCTAssertEqual(v2.message.error, "")
        let docx = try XCTUnwrap(v2.message.files.first { $0.hasSuffix(".docx") })
        let text = try DocWriter.readDocxText(docx)
        for h in cp.outline { XCTAssertTrue(text.contains(h), "Abschnitt fehlt: " + h) }
        XCTAssertNil(a.pendingWork(th))
        // Abschnitte vor der Unterbrechung wurden nicht neu geschrieben
        XCTAssertTrue(v2.steps.contains { $0.contains("Auftrag fortsetzen") }, "\(v2.steps)")
    }

    func testBookStudioWritesPdfAndResumesAfterInterruption() async throws {
        let e = FakeEngine()
        let a = TestEnv.assistant(e)
        let th = ChatThread()
        var parts = 0
        let lock = NSLock()
        let task = Task { await TestEnv.ask(a, "Schreib mir einen kurzen Roman mit drei Kapiteln über einen Leuchtturm", in: th, onStep: { s in
            if s.kind == "write" && s.done && s.text.hasPrefix("Kapitel") { lock.lock(); parts += 1; let n = parts; lock.unlock(); if n == 2 { e.delay = 0.6 } }
        }) }
        for _ in 0..<200 { let n = lock.withLock { parts }; if n >= 2 { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        a.enterBackground()
        let (v, _) = await task.value
        XCTAssertEqual(v.finished, "Unterbrochen")
        let pending = try XCTUnwrap(a.pendingBook(th))
        XCTAssertEqual(pending.chapters.count, 3)
        XCTAssertGreaterThan(pending.wordsWritten, 0)
        e.delay = 0
        let (v2, _) = await TestEnv.ask(a, "Schreib das Buch weiter", in: th)
        XCTAssertEqual(v2.message.error, "", v2.error)
        XCTAssertTrue(v2.message.content.contains("ist fertig"), v2.message.content)
        let pdf = try XCTUnwrap(v2.message.files.first { $0.hasSuffix(".pdf") })
        let bytes = try FS.read(pdf)
        XCTAssertEqual(String(decoding: bytes.prefix(8), as: UTF8.self), "%PDF-1.6")
        XCTAssertTrue(v2.message.files.contains { $0.hasSuffix(".docx") })
        XCTAssertTrue(v2.message.files.contains { $0.hasSuffix(".md") })
        XCTAssertNil(a.pendingBook(th))
        XCTAssertTrue(v2.message.content.contains("Crimson Text (eingebettet"), v2.message.content)
        XCTAssertTrue(v2.message.content.contains("VYRA KI › Bücher ›"), v2.message.content)
    }

    func testWorkshopRequestIsAnsweredHonestly() async {
        let a = TestEnv.assistant()
        let (v, _) = await TestEnv.ask(a, "Ändere VYRA so, dass der Chat größer wird")
        XCTAssertEqual(v.finished, "Werkstatt nur unter Windows")
        XCTAssertTrue(v.message.content.contains("nur in der Windows-App"))
    }

    func testCodeCheckFindsAndRepairs() throws {
        let md = "Hier:\n```json\n{\"a\": 1,\n \"b\": [1, 2,\n}\n```\n\n```javascript\nfunction x() {\n  return (1 + 2;\n}\n```"
        let r = try CodeCheck.run(md, CancelToken())
        XCTAssertEqual(r.checked, 2)
        XCTAssertEqual(r.problems.count, 2, "\(r.problems)")
        let ok = try CodeCheck.run("```json\n{\n \"a\": 1\n}\n```", CancelToken())
        XCTAssertEqual(ok.problems.count, 0)
        // Python wird auf dem iPhone nicht ausgefuehrt/geprueft
        let py = try CodeCheck.run("```python\ndef x(:\n  pass\n  pass\n```", CancelToken())
        XCTAssertEqual(py.checked, 0)
    }

    func testCodeFilesForZip() throws {
        let md = "**index.html**\n```html\n<html></html>\n```\n\nDatei: `js/app.js`\n```javascript\nconsole.log(1)\n```\n```css\nbody{}\n```"
        let f = KiAssistant.codeFiles(md)
        XCTAssertEqual(f.map { $0.0 }, ["index.html", "js/app.js", "datei3.css"])
        let zip = FS.join(TestEnv.tempDir(), "code.zip")
        try KiAssistant.writeZip(f, zip)
        let r = try ZipReader(zip)
        XCTAssertEqual(r.entries.map { $0.name }.sorted(), ["datei3.css", "index.html", "js/app.js"])
    }
}

/// Werkzeuge ohne Modell: Rechnen, Einheiten, Stimme, Buch-Erkennung, Buchsatz, Wissen, Verschluesselung.
final class ToolTests: XCTestCase {
    func testCalc() throws {
        XCTAssertTrue(Calc.looksLikeMath("Was ist 3 + 4?"))
        XCTAssertFalse(Calc.looksLikeMath("Was ist Liebe?"))
        XCTAssertEqual(try Calc.eval("2^10"), 1024)
        XCTAssertEqual(try Calc.eval("15 % von 200"), 30)
        XCTAssertEqual(try Calc.eval("wurzel aus 81"), 9)
        XCTAssertEqual(try Calc.eval("1.234,5 + 0,5"), 1235)
        XCTAssertThrowsError(try Calc.eval("1/0"))
        XCTAssertEqual(Calc.format(1234567), "1.234.567")
        XCTAssertEqual(Calc.format(2.5), "2,5")
        XCTAssertEqual(UnitTools.tryAnswer("Rechne 2 GiB in MiB"), "2 GiB = **2.048 MiB**")
        XCTAssertEqual(UnitTools.tryAnswer("-300 C in K"), "Die Temperatur liegt unter dem absoluten Nullpunkt.")
        XCTAssertNil(UnitTools.tryAnswer("5 km in kg"))
    }
    func testEtaFormatting() {
        XCTAssertEqual(EtaTracker.formatElapsed(75), "1:15 min")
        XCTAssertEqual(EtaTracker.formatRemaining(3), "gleich fertig")
        XCTAssertEqual(EtaTracker.formatRemaining(23), "noch ca. 25 s")
        XCTAssertEqual(EtaTracker.formatRemaining(400), "noch ca. 7 min")
        let dir = TestEnv.tempDir()
        let t = TaskTimes(dir)
        XCTAssertEqual(t.seconds("lokal:web"), 45)
        t.record("lokal:web", 10, 900, "lokal:web:normal")
        t.record("lokal:web", 20, 900, nil)
        XCTAssertEqual(TaskTimes(dir).seconds("lokal:web"), 13.5, accuracy: 0.05)
    }
    func testVoiceTextAndStreaming() {
        XCTAssertEqual(SoftVoice.speakable("**VYRA** braucht z. B. 4 GB & 60 Hz [2]"), "Wira braucht zum Beispiel 4 Gigabyte und 60 Hertz")
        XCTAssertEqual(SoftVoice.sentences("Hallo Welt. Wie geht es? Gut!"), ["Hallo Welt.", "Wie geht es?", "Gut!"])
        let f = VoiceFeeder()
        var said = [String]()
        f.onSentence = { s, _ in said.append(s) }
        f.beginStream()
        f.feed("Das ist z. B. ein Test. Und noch")
        XCTAssertEqual(said, ["Das ist zum Beispiel ein Test."])
        f.feed("Das ist z. B. ein Test. Und noch ein Satz. ```code")
        XCTAssertEqual(said.count, 2)
        f.endStream("Das ist z. B. ein Test. Und noch ein Satz. Ende.")
        XCTAssertEqual(said.last, "Ende.")
        XCTAssertEqual(SpeechText.spokenText("Siehe ```py\nx=1\n``` und https://a.de/x"), "Siehe  Der Code steht im Chat.  und  Link im Chat. ")
        let clip = SoftVoice.process((0..<22050).map { Int16(truncatingIfNeeded: Int(sin(Double($0) / 10) * 8000)) }, 22050, 0.45)
        XCTAssertEqual(clip.samples.count, 22050)
        XCTAssertEqual(clip.env.count, 50)
        XCTAssertGreaterThan(clip.env.max() ?? 0, 0.1)
    }
    func testBookDetection() {
        XCTAssertTrue(BookWriter.wants("Schreib mir einen Roman über Drachen"))
        XCTAssertTrue(BookWriter.wants("Kannst du ein Kinderbuch über einen Igel schreiben?"))
        XCTAssertFalse(BookWriter.wants("Fasse das Buch zusammen, bitte"))
        XCTAssertFalse(BookWriter.wants("Schreib eine Zusammenfassung zum Buch Momo"))
        XCTAssertTrue(BookWriter.wantsResume("Schreib das Buch weiter"))
        XCTAssertTrue(BookWriter.wantsResume("mach weiter!"))
        XCTAssertFalse(BookWriter.wantsResume("Mach weiter mit der Erklärung von Rekursion, aber diesmal ausführlich und mit Beispielen in Python bitte"))
        let r = BookWriter.parse("Schreibe ein Kinderbuch mit 5 Kapiteln, Autorin: Lea Sommer, Titel „Igel Ilse“", false, "6x9")
        XCTAssertEqual(r.kind, "kinderbuch"); XCTAssertEqual(r.chapters, 5); XCTAssertEqual(r.author, "Lea Sommer"); XCTAssertEqual(r.title, "Igel Ilse")
        let r2 = BookWriter.parse("Ein Sachbuch mit 200 Seiten in A5", false, "6x9")
        XCTAssertEqual(r2.format, "a5"); XCTAssertEqual(r2.kind, "sachbuch")
        XCTAssertFalse(r2.notes.isEmpty) // auf 24.000 Woerter begrenzt (ohne Pro)
        XCTAssertEqual(BookWriter.cleanPart("Natürlich! Hier ist der Text:\n## Kapitel 1\n\nEs war **dunkel**.\n\n(Fortsetzung folgt)", true, "Der Anfang"), "Es war dunkel.")
        XCTAssertEqual(BookWriter.trimToSentence("Sie lief los. Dann sah sie"), "Sie lief los.")
        XCTAssertTrue(BookWriter.hasLoop(String(repeating: "Das ist ein sehr langer Satz, der sich ständig wiederholt. ", count: 3)))
    }
    func testBookTypesettingWithEmbeddedFont() throws {
        let doc = BookDocument()
        doc.title = "Das Licht von Hallig Nord"; doc.subtitle = "Roman"; doc.author = "Test Autorin"
        let e = FakeEngine()
        for i in 1...4 { doc.chapters.append(BookChapterText("Kapitel Titel \(i)", e.text(1200))) }
        let folder = BookPdf.defaultFontFolder()
        XCTAssertFalse(folder.isEmpty)
        let r = try BookPdf.build(doc, folder)
        XCTAssertTrue(r.fontsEmbedded)
        XCTAssertEqual(r.fontName, "Crimson Text (eingebettet, SIL Open Font License)")
        XCTAssertGreaterThanOrEqual(r.pages, 20)
        XCTAssertEqual(r.chapterPages.count, 4)
        XCTAssertTrue(r.chapterPages.allSatisfy { $0 % 2 == 1 }) // Kapitel beginnen rechts
        let text = Pdf.extractText(r.bytes)
        XCTAssertTrue(text.contains("Inhalt"), String(text.prefix(300)))
        let lines = BookPdf.previewLines(e.text(200), "6x9", folder, true)
        XCTAssertGreaterThan(lines.count, 3)
        let tt = try TrueTypeFont.load(FS.join(folder, BookPdf.fontRegular))
        XCTAssertEqual(tt.postScriptName, "CrimsonText-Regular")
    }
    func testKnowledgeBaseAndSecrets() {
        let k = KnowledgeBase.bundled()
        XCTAssertEqual(k.count, 31 + 64)
        XCTAssertTrue(k.answer("Warum ruckelt Fortnite?").contains("Windows-App"))
        XCTAssertTrue(k.answer("Hallo").hasPrefix("Hallo! Ich bin VYRA Bot."))
        let c = SecretStore.protect("geheim")!
        XCTAssertNotEqual(c, "geheim")
        XCTAssertEqual(SecretStore.unprotect(c), "geheim")
        XCTAssertTrue(SecretStore.set("openai.key", "sk-test"))
        XCTAssertEqual(SecretStore.get("openai.key"), "sk-test")
        SecretStore.set("openai.key", "")
    }
}
