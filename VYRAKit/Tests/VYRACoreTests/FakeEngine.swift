import Foundation
import XCTest
@testable import VYRACore

/// Deterministisches Ersatzmodell fuer Ablauftests (Routing, Buch-Studio, Arbeitsmodus, Unterbrechen/Fortsetzen).
/// Liefert fuer JSON-Schemata gueltiges JSON und sonst abwechslungsreiche deutsche Saetze. Das echte Modell
/// (llama.cpp) wird in EngineTests und AssistantRealModelTests geprueft.
final class FakeEngine: KiModelEngine {
    let model: ModelInfo
    var contextTokens = 8192
    var lastFinish = "stop"
    var lastTokensPerSecond = 0.0
    var gpuFull = true
    var fullContext = false
    var cpuContextChars = 7000
    var modelInstalled = true
    var running = false
    var starting = false
    var statusText = ""
    var onStatus: ((String) -> Void)?
    var contextNote: String?
    var gpuNote: String?
    var processorLabel: String? { running ? "Grafikeinheit" : nil }
    var useGpu = true
    var loraPath = ""
    var contextOverride = 0
    /// Wartezeit je Aufruf (fuer Abbruch-Tests)
    var delay = 0.0
    let lock = NSLock()
    private(set) var calls = 0
    private(set) var prompts = [String]()
    var rng = SeededRandom(42)

    init(name: String = "VYRA Fake · Test", pro: Bool = false) {
        let m = ModelInfo(); m.file = "fake.gguf"; m.name = name; m.bytes = 1_000_000; m.ctx = 8192; m.maxCtx = 16384; m.layers = 10
        if pro { m.tier = "pro" }
        model = m
    }
    func ensureStarted(_ token: CancelToken) async throws {
        if running { return }
        starting = true; onStatus?("VYRA KI lädt das Modell …")
        try await VYRACore.delay(0.01, token)
        starting = false; running = true
    }
    func unload() async { running = false }
    func complete(_ system: String, _ turns: [ChatTurn], _ onText: ((String) -> Void)?, _ opt: GenOptions, _ token: CancelToken) async throws -> String {
        lock.lock(); calls += 1; prompts.append(turns.last?.content ?? ""); lock.unlock()
        if delay > 0 { try await VYRACore.delay(delay, token) }
        try token.check()
        lastTokensPerSecond = 12
        lastFinish = "stop"
        let out: String
        if let schema = opt.jsonSchema { out = Json.serialize(gen(schema, "")) }
        else {
            let words = max(25, min(900, Int(Double(opt.maxTokens - 200) / 2.3)))
            out = text(words)
        }
        var shown = ""
        for part in out.split(separator: " ", omittingEmptySubsequences: false).prefix(400) { shown += (shown.isEmpty ? "" : " ") + part; if shown.count % 7 == 0 { onText?(shown) } }
        onText?(out)
        return out
    }
    static let subjects = ["Die Wärterin", "Der alte Fischer", "Ein Kind aus dem Dorf", "Die Möwe", "Der Nebel", "Das Licht", "Eine Fremde", "Der Bürgermeister", "Die Lehrerin", "Ein Hund", "Der Sturm", "Die Nachbarin", "Ein Händler", "Der Junge", "Die Malerin"]
    static let verbs = ["betrachtet", "sucht", "findet", "versteckt", "repariert", "beschreibt", "vermisst", "rettet", "begleitet", "erinnert sich an", "zeichnet", "öffnet", "verliert", "bewacht", "erklärt"]
    static let objects = ["die rostige Laterne", "einen verlorenen Brief", "das kleine Boot", "die Karte der Bucht", "den Schlüssel zum Turm", "eine alte Fotografie", "das Logbuch", "die steinerne Treppe", "den Kompass", "ein zerrissenes Netz", "die Glocke am Hafen", "einen Korb voller Muscheln", "das Fenster im Dachboden", "die Uhr des Vaters", "ein Paket aus der Stadt"]
    static let places = ["am frühen Morgen", "hinter den Dünen", "während der Flut", "im Schatten der Klippen", "kurz vor Mitternacht", "neben dem Leuchtturm", "auf dem Markt", "im kalten Wind", "unter dem Vordach", "zwischen den Felsen", "nach dem Gewitter", "bei Kerzenlicht", "am Ende des Stegs", "im verlassenen Schuppen", "trotz des Regens"]
    static let tails = ["und lächelt dabei.", "obwohl niemand zusieht.", "weil es wichtig erscheint.", "bevor die Glocke schlägt.", "ohne ein Wort zu sagen.", "mit zitternden Händen.", "und hält kurz inne.", "als hinge alles davon ab.", "noch ehe es dunkel wird.", "während die Wellen rauschen."]
    func pick(_ a: [String]) -> String { a[Int(rng.next() % UInt64(a.count))] }
    func sentence() -> String { pick(FakeEngine.subjects) + " " + pick(FakeEngine.verbs) + " " + pick(FakeEngine.objects) + " " + pick(FakeEngine.places) + " " + pick(FakeEngine.tails) }
    func text(_ words: Int) -> String {
        var paras = [String]()
        var count = 0
        while count < words {
            var p = [String]()
            for _ in 0..<4 { let s = sentence(); p.append(s); count += s.split(separator: " ").count }
            paras.append(p.joined(separator: " "))
        }
        return paras.joined(separator: "\n\n")
    }
    var counter = 0
    func gen(_ schema: Any?, _ key: String) -> Any {
        let type = Json.str(schema, "type")
        switch type {
        case "object":
            let o = JObject()
            if let props = Json.get(schema, "properties") as? JObject { for (k, v) in props.entries { o[k] = gen(v, k) } }
            return o
        case "array":
            let minI = Int(Json.num(schema, "minItems", 0)), maxI = Int(Json.num(schema, "maxItems", 3))
            let n = max(minI, min(maxI, 3))
            return (0..<n).map { _ in gen(Json.get(schema, "items"), key) } as [Any]
        case "integer", "number": return 1.0
        case "boolean": return true
        default:
            counter += 1
            switch key {
            case "titel": return counter == 1 ? "Das Licht von Hallig Nord" : "Abschnitt \(counter)"
            case "name": return ["Mara", "Jonte", "Ilse"][counter % 3]
            case "zusammenfassung": return sentence() + " " + sentence()
            case "praemisse", "inhalt": return sentence() + " " + sentence() + " " + sentence()
            default: return "Wert \(counter)"
            }
        }
    }
}

/// Einfacher, reproduzierbarer Zufall (xorshift).
struct SeededRandom { var s: UInt64; init(_ seed: UInt64) { s = seed &* 2654435761 | 1 }; mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s } }

/// Zeichnet auf, was eine Antwort anzeigen wuerde (wie MessageView).
final class RecordingView: TurnView {
    let message: ChatMessage
    let lock = NSLock()
    var statuses = [String](), steps = [String](), notes = [(String, String)](), files = [String](), cards = [String]()
    var markdown = "", thoughts = "", error = ""
    var finished: String?
    var onStep: ((WorkStep) -> Void)?
    init(_ m: ChatMessage) { message = m }
    var currentText: String { lock.lock(); defer { lock.unlock() }; return message.content.isEmpty ? markdown : message.content }
    func setStatus(_ text: String?) { lock.lock(); if let t = text { statuses.append(t) }; lock.unlock() }
    func step(_ s: WorkStep) { lock.lock(); steps.append((s.done ? (s.failed ? "✕ " : "✓ ") : "… ") + s.text + (s.detail.isEmpty ? "" : " – " + s.detail)); lock.unlock(); onStep?(s) }
    func setMarkdown(_ md: String) { lock.lock(); markdown = md; lock.unlock() }
    func setThoughts(_ text: String) { lock.lock(); thoughts = text; lock.unlock() }
    func addNote(_ text: String, _ role: String) { lock.lock(); notes.append((text, role)); lock.unlock() }
    func addFile(_ path: String) { lock.lock(); files.append(path); lock.unlock() }
    func addCard(_ card: TurnCard) { lock.lock(); switch card { case .app(let p): cards.append("app:" + p.name); case .zip(let f, _): cards.append("zip:\(f.count)"); case .moves(let m, _, _): cards.append("moves:\(m.count)") }; lock.unlock() }
    func showSources() {}
    func startClock(_ eta: EtaTracker) {}
    func setError(_ text: String) { lock.lock(); error = text; message.error = text; lock.unlock() }
    func finish(_ meta: String) { lock.lock(); finished = meta; lock.unlock() }
}

extension TestEnv {
    static func assistant(_ engine: FakeEngine? = FakeEngine(), configure: ((Settings) -> Void)? = nil) -> KiAssistant {
        let a = KiAssistant(paths: paths(), small: nil, large: engine, pro: nil, engineError: nil)
        a.settings.set("bot.mode", "local"); a.settings.set("work.webmode", "off"); a.settings.setBool("bot.preload", false); a.settings.setBool("bot.weblearn", false)
        configure?(a.settings)
        return a
    }
    @discardableResult
    static func ask(_ a: KiAssistant, _ text: String, in th: ChatThread? = nil, atts: [Attachment] = [], onStep: ((WorkStep) -> Void)? = nil) async -> (RecordingView, ChatThread) {
        let t = th ?? ChatThread()
        var view: RecordingView!
        await a.send(text, atts, in: t) { m in view = RecordingView(m); view.onStep = onStep; return view }
        return (view, t)
    }
}
