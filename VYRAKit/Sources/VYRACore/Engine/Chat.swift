import Foundation

public final class ChatTurn {
    public var role: String
    public var content: String
    public init(_ role: String, _ content: String) { self.role = role; self.content = content }
}

/// Einstellungen fuer eine einzelne Antwort. Werte nach den Empfehlungen fuer Qwen3-Instruct-2507 (wie Windows).
public final class GenOptions {
    public var maxTokens = 1200
    public var temperature = 0.7, topP = 0.8, minP = 0.0, presencePenalty = 0.0
    public var topK = 20
    /// gesetzt = Antwort wird per Grammatik auf gueltiges JSON gezwungen (nur lokales Modell)
    public var jsonSchema: Any?
    public init() {}
    public static func chat(_ max: Int) -> GenOptions { let g = GenOptions(); g.maxTokens = max; return g }
    public static func precise(_ max: Int) -> GenOptions { let g = GenOptions(); g.maxTokens = max; g.temperature = 0.35; g.topP = 0.85; g.topK = 20; return g }
    public static func structured(_ schema: Any, _ max: Int) -> GenOptions { let g = GenOptions(); g.maxTokens = max; g.temperature = 0.15; g.topP = 0.9; g.topK = 20; g.jsonSchema = schema; return g }
}

/// Gemeinsame Schnittstelle fuer das lokale Modell und die optionalen Online-Anbieter (wie `IChatBrain`).
public protocol ChatBrain: AnyObject {
    var name: String { get }
    var contextChars: Int { get }
    var local: Bool { get }
    /// "length" = Antwort wurde wegen der Laengengrenze abgeschnitten
    var lastFinish: String { get }
    func complete(_ system: String, _ messages: [ChatTurn], _ onText: ((String) -> Void)?, _ opt: GenOptions, _ token: CancelToken) async throws -> String
}

/// Das lokale Modell aus Sicht des KI-Kerns (umgesetzt in VYRALlama mit llama.cpp/Metal).
public protocol LocalEngine: AnyObject {
    var model: ModelInfo { get }
    var contextTokens: Int { get }
    var lastFinish: String { get }
    var lastTokensPerSecond: Double { get }
    /// true = das Modell rechnet vollstaendig auf der Grafikeinheit (Metal)
    var gpuFull: Bool { get }
    var fullContext: Bool { get }
    var cpuContextChars: Int { get }
    func complete(_ system: String, _ turns: [ChatTurn], _ onText: ((String) -> Void)?, _ opt: GenOptions, _ token: CancelToken) async throws -> String
}

public final class LocalBrain: ChatBrain {
    let engine: LocalEngine
    public init(_ e: LocalEngine) { engine = e }
    public var name: String { "VYRA KI (" + engine.model.name + ")" }
    public var local: Bool { true }
    public var lastFinish: String { engine.lastFinish }
    /// Auf dem Prozessor ist das Einlesen langer Texte langsam: dann bewusst weniger Kontext, damit die Antwort schnell beginnt.
    public var contextChars: Int {
        let full = Int(max(5000, Double(engine.contextTokens) * 2.9))
        if engine.fullContext { return full } // 4.15 Pro: ganzer Kontext
        if !engine.gpuFull { return min(full, max(7000, min(10000, engine.cpuContextChars))) }
        return full
    }
    public func complete(_ system: String, _ messages: [ChatTurn], _ onText: ((String) -> Void)?, _ opt: GenOptions, _ token: CancelToken) async throws -> String {
        try await engine.complete(system, messages, onText, opt, token)
    }
}

/// Textregeln des lokalen Modells (aus `AiEngine`).
public enum EngineText {
    /// Entfernt <think>…</think>-Bloecke (auch unvollstaendige am Ende).
    public static func clean(_ s0: String?) -> String {
        guard var s = s0 else { return "" }
        var a = s.indexOf("<think>")
        while a >= 0 {
            let b = s.indexOf("</think>", from: a)
            if b < 0 { s = s.sub(0, a); break }
            s = s.sub(0, a) + s.sub(b + 8)
            a = s.indexOf("<think>")
        }
        return s
    }
    /// Passt den Verlauf in das Kontextfenster: aelteste Nachrichten zuerst kuerzen, dann entfernen.
    public static func fitContext(_ system: String, _ turns: [ChatTurn], _ ctxTokens: Int, _ maxTokens: Int) -> (turns: [ChatTurn], outTokens: Int) {
        let cpt = 2.9 // Zeichen je Token (deutsch, vorsichtig)
        let budget = Int(Double(ctxTokens - 64) * cpt) - system.len
        var outTokens = maxTokens
        var list = turns.filter { $0.role == "user" || $0.role == "assistant" }.map { ChatTurn($0.role, $0.content) }
        func used() -> Int { list.reduce(0) { $0 + $1.content.len + 12 } }
        let minOut = min(maxTokens, 256)
        // Antwortlaenge darf schrumpfen, bevor Inhalt verloren geht (aber nie unter 256 Token).
        while Double(used()) + Double(outTokens) * cpt > Double(budget) && outTokens > minOut { outTokens = max(minOut, outTokens - 128) }
        let avail = budget - Int(Double(outTokens) * cpt)
        while list.count > 1 && used() > avail {
            list.removeFirst()
            while list.count > 1 && list[0].role != "user" { list.removeFirst() }
        }
        if let last = list.last, used() > avail {
            let keep = max(500, avail - 24)
            if last.content.len > keep {
                // Anfang (Aufgabe/Quellen) und Ende (eigentliche Frage) behalten.
                let head = keep * 2 / 3, tail = keep - head - 20
                last.content = last.content.sub(0, head) + "\n[…]\n" + last.content.sub(last.content.len - max(0, tail))
            }
        }
        return (list, outTokens)
    }
}
