import Foundation

public final class ChatMessage {
    public var role = "user", content = "", thoughts = "", meta = "", error = ""
    public var time = Date()
    public var sources = [SearchHit]()
    public var files = [String]()
    public var attachments = [String]()
    public var steps = [String]()
    public init(_ role: String = "user", _ content: String = "") { self.role = role; self.content = content }
}
public final class ChatThread {
    public var id = FS.newId(), title = "Neuer Chat", mode = ""
    public var created = Date(), updated = Date()
    public var pinned = false
    public var recall = true
    /// Ordner der zuletzt gebauten App
    public var project = ""
    public var messages = [ChatMessage]()
    public init() {}
    /// Verlauf fuer das Modell (nur abgeschlossene Nachrichten ohne Fehler).
    public func turns() -> [ChatTurn] {
        messages.filter { $0.error.isEmpty && !$0.content.trimmed.isEmpty && ($0.role == "user" || $0.role == "assistant") }.map { ChatTurn($0.role, $0.content) }
    }
}

/// Mehrere Chats, je Chat eine JSON-Datei (Format "vyra-chat-1", identisch zu Windows – Chats lassen sich uebertragen).
public final class ChatStore {
    public let folder: String
    public init(_ folder: String) { self.folder = folder }
    static func validId(_ id: String) -> Bool { Rx.isMatch(id, "^[0-9a-f]{32}$") }
    func pathOf(_ id: String) throws -> String {
        if !ChatStore.validId(id) { throw VyraError("Ungültige Chat-ID.", .argument) }
        return FS.join(folder, id + ".json")
    }
    public func loadAll() -> [ChatThread] {
        var list = [ChatThread]()
        if !FS.isDir(folder) { return list }
        for f in FS.files(folder) where f.hasSuffix(".json") {
            if FS.size(f) > 8_000_000 { continue }
            if let o = try? Json.parse(FS.readText(f)), let t = ChatStore.fromJson(o), ChatStore.validId(t.id) { list.append(t) }
        }
        return list.stableSorted { a, b in a.pinned != b.pinned ? a.pinned : a.updated > b.updated }
    }
    public func save(_ t: ChatThread) throws {
        if t.messages.isEmpty { return }
        try FS.mkdir(folder)
        try FS.writeAtomic(try pathOf(t.id), text: Json.serialize(ChatStore.toJson(t)))
    }
    public func delete(_ id: String) { if let p = try? pathOf(id) { FS.delete(p) } }
    @discardableResult public func deleteAll() -> Int {
        var n = 0
        for f in FS.files(folder) where f.hasSuffix(".json") && ChatStore.validId(FS.stem(f)) { FS.delete(f); n += 1 }
        return n
    }
    static func d(_ date: Date) -> String { ISO.string(date) }
    static func pd(_ s: String) -> Date { ISO.parse(s) ?? Date() }
    public static func toJson(_ t: ChatThread) -> JObject {
        var msgs = [Any]()
        for m in t.messages {
            let src = m.sources.map { Json.obj(("id", Double($0.id)), ("title", $0.title), ("url", $0.url)) as Any }
            msgs.append(Json.obj(("role", m.role), ("content", m.content), ("thoughts", m.thoughts), ("meta", m.meta), ("error", m.error), ("time", d(m.time)), ("sources", src), ("files", m.files as [Any]), ("attachments", m.attachments as [Any]), ("steps", m.steps as [Any])))
        }
        return Json.obj(("format", "vyra-chat-1"), ("id", t.id), ("title", t.title), ("mode", t.mode), ("pinned", t.pinned), ("recall", t.recall), ("project", t.project), ("created", d(t.created)), ("updated", d(t.updated)), ("messages", msgs))
    }
    public static func fromJson(_ o: Any) -> ChatThread? {
        if Json.str(o, "format") != "vyra-chat-1" { return nil }
        let t = ChatThread()
        t.id = Json.str(o, "id"); t.title = Json.str(o, "title"); t.mode = Json.str(o, "mode")
        t.created = pd(Json.str(o, "created")); t.updated = pd(Json.str(o, "updated"))
        t.pinned = Json.bool(o, "pinned") ?? false
        t.recall = Json.bool(o, "recall") ?? true
        t.project = Json.str(o, "project")
        for x in Json.arr(o, "messages") {
            let m = ChatMessage(Json.str(x, "role"), Json.str(x, "content"))
            m.thoughts = Json.str(x, "thoughts"); m.meta = Json.str(x, "meta"); m.error = Json.str(x, "error"); m.time = pd(Json.str(x, "time"))
            for s in Json.arr(x, "sources") { let h = SearchHit(); h.id = Int(Json.num(s, "id", 0)); h.title = Json.str(s, "title"); h.url = Json.str(s, "url"); m.sources.append(h) }
            for s in Json.arr(x, "files") { m.files.append(Json.text(s)) }
            for s in Json.arr(x, "attachments") { m.attachments.append(Json.text(s)) }
            for s in Json.arr(x, "steps") { m.steps.append(Json.text(s)) }
            if m.role == "user" || m.role == "assistant" { t.messages.append(m) }
        }
        if t.title.isEmpty { t.title = "Chat" }
        return t
    }
    public static func makeTitle(_ text: String) -> String {
        var t = Rx.replace(text.trimmed, "\\s+", " ")
        t = Rx.replace(t, "^(hallo|hi|hey|moin|servus)[,!. ]+", "", .i)
        t = Rx.replace(t, "^(kannst du( mir)?|könntest du( mir)?|bitte|ich möchte|ich will|ich brauche)\\s+", "", .i)
        if t.isEmpty { return "Neuer Chat" }
        t = t.capitalizedFirst
        if t.len > 46 {
            let cut = t.lastIndexOf(" ", before: 46)
            t = t.sub(0, cut > 20 ? cut : 46).trimEnd(",.;:") + " …"
        }
        return t.trimEnd("?!.")
    }
}
