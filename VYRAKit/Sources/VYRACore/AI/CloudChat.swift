import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Online-KI (optional, mit eigenem API-Schluessel): OpenAI und Claude – unveraendert aus `CloudChat`.
public final class CloudChat {
    /// Systemprompt aus dem VYRA-Bot-Code des Nutzers (unveraendert uebernommen).
    public static let vyraBotPrompt = "Du bist VYRA Bot, ein hilfreicher, intelligenter KI-Assistent.\nDu antwortest standardmäßig auf Deutsch.\nDu erklärst komplizierte Dinge verständlich.\nDu hilfst beim Lernen, Programmieren, Schreiben,\nRecherchieren und kreativen Denken.\nDu bist freundlich, ehrlich und strukturiert.\nWenn du etwas nicht weißt, sagst du das offen.\nDu nennst dich VYRA Bot und nicht ChatGPT."
    public static let genericError = "Die KI-Anfrage ist fehlgeschlagen. Prüfe API-Schlüssel, Guthaben und Modellzugriff."
    public static let openAiModels = ["gpt-4.1-mini", "gpt-5-mini", "gpt-5", "gpt-4.1", "gpt-5-nano", "gpt-4.1-nano"]
    public static let claudeModels = ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"]
    public var provider = "openai" // openai | claude
    public var model = "gpt-4.1-mini"
    public var apiKey = ""
    public var webSearch = false
    public var maxTokens = 4096
    public var baseUrl: String? // nur fuer Tests
    public private(set) var lastStop = ""
    public init() {}

    public static func fullPrompt(_ vyraContext: String, _ deviceInfo: String, _ custom: String = "") -> String {
        var b = vyraBotPrompt
        b += Platform.cloudContext
        b += "\nFormatiere mit Markdown. Schreibe Formeln als normalen Text, ohne LaTeX.\n" + Researcher.answerStyle
        b += Platform.cloudFiles
        b += "\nHeute ist " + Researcher.today() + "."
        if !deviceInfo.trimmed.isEmpty { b += "\n" + Platform.deviceLabel + deviceInfo.trimmed }
        if !custom.trimmed.isEmpty { b += "\nHinweise des Nutzers (bitte beachten): " + custom.trimmed }
        if !vyraContext.trimmed.isEmpty { b += "\nWenn die Frage VYRA betrifft, nutze diese Anleitungen:\n" + vyraContext.trimmed }
        return b
    }
    /// Wie im Code des Nutzers: nur user/assistant, letzte 30 Nachrichten, je max. 12.000 Zeichen, letzte Nachricht vom Nutzer.
    public static func cleanMessages(_ history: [ChatTurn], _ prompt: String) throws -> [ChatTurn] {
        var all = [ChatTurn]()
        for h in history where h.role == "user" || h.role == "assistant" { all.append(ChatTurn(h.role, h.content.len > 12000 ? h.content.sub(0, 12000) : h.content)) }
        if !prompt.isEmpty { all.append(ChatTurn("user", prompt.len > 12000 ? prompt.sub(0, 12000) : prompt)) }
        var last = Array(all.suffix(30))
        while let f = last.first, f.role != "user" { last.removeFirst() } // Verlauf beginnt immer mit einer Nutzernachricht
        if last.isEmpty || last.last!.role != "user" { throw VyraError("Ungültige Nachricht.", .argument) }
        return last
    }
    public func ask(_ history: [ChatTurn], _ prompt: String, _ system: String, _ onText: ((String) -> Void)?, _ token: CancelToken) async throws -> String {
        if apiKey.trimmed.isEmpty { throw VyraError(provider == "claude" ? "API-Schlüssel fehlt. Bitte deinen Claude-Schlüssel in den Einstellungen eintragen." : "API-Schlüssel fehlt. Bitte deinen OpenAI-Schlüssel in den Einstellungen eintragen.", .invalidOperation) }
        let msgs = try CloudChat.cleanMessages(history, prompt)
        let list = msgs.map { Json.obj(("role", $0.role), ("content", $0.content)) as Any }
        var req: URLRequest
        if provider == "claude" {
            let body = Json.obj(("model", model), ("max_tokens", Double(max(256, maxTokens))), ("system", [Json.obj(("type", "text"), ("text", system), ("cache_control", Json.obj(("type", "ephemeral"))))] as [Any]), ("messages", list), ("stream", true))
            if webSearch { body["tools"] = [Json.obj(("type", "web_search_20250305"), ("name", "web_search"), ("max_uses", 3.0))] as [Any] }
            req = URLRequest(url: URL(string: (baseUrl ?? "https://api.anthropic.com") + "/v1/messages")!)
            req.httpBody = Data(Json.serialize(body).utf8)
            req.setValue(apiKey.trimmed, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            let body = Json.obj(("model", model), ("instructions", system), ("input", list), ("stream", true), ("max_output_tokens", Double(max(256, maxTokens))))
            req = URLRequest(url: URL(string: (baseUrl ?? "https://api.openai.com") + "/v1/responses")!)
            req.httpBody = Data(Json.serialize(body).utf8)
            req.setValue("Bearer " + apiKey.trimmed, forHTTPHeaderField: "Authorization")
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 600
        var all = ""
        var streamError: String?
        lastStop = ""
        let streamer = DownloadStreamer(request: req, token: token)
        let head = try await streamer.start()
        if !(200...299).contains(head.statusCode) {
            var err = Data()
            while let c = try? await streamer.next(stall: 30) { err.append(c); if err.count > 100_000 { break } }
            throw VyraError(CloudChat.explain(head.statusCode, String(decoding: err, as: UTF8.self)), .io)
        }
        var pending = ""
        loop: while let chunk = try await streamer.next(stall: 300) {
            pending += String(decoding: chunk, as: UTF8.self)
            while let nl = pending.firstIndex(of: "\n") {
                let line = String(pending[..<nl]).trimEnd()
                pending = String(pending[pending.index(after: nl)...])
                try token.check()
                if !line.hasPrefix("data:") { continue }
                let data = line.sub(5).trimmed
                if data.isEmpty || data == "[DONE]" { continue }
                guard let o = try? Json.parse(data) else { continue }
                let type = Json.str(o, "type")
                var piece = ""
                if type == "content_block_delta" { let d = Json.get(o, "delta"); if Json.str(d, "type") == "text_delta" { piece = Json.str(d, "text") } }
                else if type == "response.output_text.delta" { piece = Json.str(o, "delta") }
                else if type == "error" { let e = Json.get(o, "error"); var m = Json.str(e, "message"); if m.isEmpty { m = Json.str(o, "message") }; streamError = m; break loop }
                else if type == "response.failed" { streamError = Json.str(Json.get(Json.get(o, "response"), "error"), "message"); break loop }
                else if type == "message_delta" { if Json.str(Json.get(o, "delta"), "stop_reason") == "max_tokens" { lastStop = "length" } }
                else if type == "response.incomplete" { lastStop = "length"; break loop }
                else if type == "message_stop" || type == "response.completed" { break loop }
                if !piece.isEmpty { all += piece; onText?(all) }
            }
        }
        streamer.cancel()
        if let e = streamError { throw VyraError(CloudChat.genericError + " (" + e + ")", .io) }
        let answer = all.trimmed
        if answer.isEmpty { throw VyraError("Die KI hat keine Antwort geliefert. Bitte erneut fragen.", .invalidData) }
        return answer
    }
    public static func explain(_ status: Int, _ body: String) -> String {
        var msg = ""
        if let o = try? Json.parse(body) { msg = Json.str(Json.get(o, "error"), "message") }
        let low = msg.lowercased()
        let head: String
        if status == 401 { head = "Der API-Schlüssel ist ungültig." }
        else if status == 403 { head = "Kein Zugriff auf dieses Modell oder diesen Dienst." }
        else if status == 404 { head = "Das Modell wurde nicht gefunden. Bitte ein anderes Modell wählen." }
        else if status == 429 && (low.contains("quota") || low.contains("credit") || low.contains("billing")) { head = "Das Guthaben bzw. Kontingent ist aufgebraucht." }
        else if status == 429 { head = "Zu viele Anfragen – bitte kurz warten." }
        else if status == 400 && (low.contains("credit") || low.contains("billing") || low.contains("balance")) { head = "Das Guthaben ist aufgebraucht." }
        else if status == 400 && low.contains("max_output_tokens") { head = "Dieses Modell unterstützt die gewählte Antwortlänge nicht." }
        else if [529, 503, 500, 502].contains(status) { head = "Der KI-Dienst ist gerade überlastet. Bitte gleich nochmal versuchen." }
        else { head = genericError }
        return head + (msg.isEmpty ? " (HTTP \(status))" : " (" + (msg.len > 200 ? msg.sub(0, 200) : msg) + ")")
    }
}

public final class CloudBrain: ChatBrain {
    let chat: CloudChat
    public init(_ c: CloudChat) { chat = c }
    public var name: String { chat.model }
    public var local: Bool { false }
    public var lastFinish: String { chat.lastStop }
    public var contextChars: Int { 90000 }
    public func complete(_ system: String, _ messages: [ChatTurn], _ onText: ((String) -> Void)?, _ opt: GenOptions, _ token: CancelToken) async throws -> String {
        let hist = Array(messages.dropLast())
        let last = messages.last?.content ?? ""
        chat.maxTokens = max(1024, opt.maxTokens >= 4000 ? min(32000, opt.maxTokens * 3) : opt.maxTokens * 2)
        return try await chat.ask(hist, last, system, onText, token)
    }
}
