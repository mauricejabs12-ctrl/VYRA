import Foundation
import XCTest
@testable import VYRACore
@testable import VYRALlama

/// Echte Tests der llama.cpp-Anbindung (llama.cpp b7380) mit einem winzigen Qwen3-Testmodell.
final class EngineTests: XCTestCase {
    func makeEngine() throws -> LlamaEngine {
        guard let src = TestEnv.testModel else { throw XCTSkip("Testmodell fehlt (scripts/make-test-model.py)") }
        let paths = TestEnv.paths()
        let info = TestEnv.testModelInfo()
        try FS.mkdir(paths.models)
        try FS.fm.copyItem(atPath: src, toPath: FS.join(paths.models, info.file))
        let e = LlamaEngine(model: info, paths: paths)
        e.markVerified() // Pruefsumme wird in testChecksumVerification echt geprueft
        return e
    }

    func testPromptMatchesQwen3TemplateWithThinkingOff() {
        let p = LlamaEngine.prompt(system: "SYS", turns: [ChatTurn("user", "Hallo"), ChatTurn("assistant", "Hi"), ChatTurn("user", "Wie geht's?")], thinkingModel: true)
        XCTAssertEqual(p, "<|im_start|>system\nSYS<|im_end|>\n<|im_start|>user\nHallo<|im_end|>\n<|im_start|>assistant\nHi<|im_end|>\n<|im_start|>user\nWie geht's? /no_think<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")
        let q = LlamaEngine.prompt(system: "S", turns: [ChatTurn("user", "X")], thinkingModel: false)
        XCTAssertEqual(q, "<|im_start|>system\nS<|im_end|>\n<|im_start|>user\nX<|im_end|>\n<|im_start|>assistant\n")
    }

    func testChecksumVerification() throws {
        let e = try makeEngine()
        XCTAssertTrue(e.modelInstalled)
        XCTAssertTrue(try e.verify(token: CancelToken()))
        let wrong = TestEnv.testModelInfo(sha: String(repeating: "0", count: 64))
        let e2 = LlamaEngine(model: wrong, paths: VyraPaths(dataRoot: FS.dirName(FS.dirName(FS.dirName(e.modelPath))), documents: TestEnv.tempDir()))
        XCTAssertFalse(try e2.verify(token: CancelToken()))
    }

    func testLoadStreamAndFinish() async throws {
        let e = try makeEngine()
        var updates = [String]()
        let box = UpdateBox()
        let answer = try await e.complete("Du bist VYRA.", [ChatTurn("user", "Sag Hallo")], { s in box.add(s) }, GenOptions.chat(40), CancelToken())
        updates = box.all
        XCTAssertFalse(answer.isEmpty)
        XCTAssertTrue(e.running)
        XCTAssertEqual(e.active?.ctx, 2048)
        XCTAssertGreaterThan(e.lastPromptTokens, 10)
        XCTAssertTrue(["length", "stop"].contains(e.lastFinish))
        let n = updates.count
        XCTAssertGreaterThanOrEqual(n, 1, "Streaming liefert Zwischenstaende")
        XCTAssertEqual(updates.last, answer)
    }

    func testCancelStopsGeneration() async throws {
        let e = try makeEngine()
        let token = CancelToken()
        var got = 0
        do {
            _ = try await e.complete("Du bist VYRA.", [ChatTurn("user", "Erzähl eine lange Geschichte")], { _ in got += 1; token.cancel() }, GenOptions.chat(2000), token)
            XCTFail("Abbruch erwartet")
        } catch {
            XCTAssertTrue(error.isCancellation, "\(error)")
        }
        // Danach ist das Modell weiter benutzbar
        let a = try await e.complete("Du bist VYRA.", [ChatTurn("user", "Nochmal")], nil, GenOptions.chat(8), CancelToken())
        XCTAssertFalse(a.isEmpty)
    }

    func testPromptCacheReusesCommonPrefix() async throws {
        let e = try makeEngine()
        let sys = String(repeating: "Du bist VYRA, eine hilfreiche KI. ", count: 20)
        _ = try await e.complete(sys, [ChatTurn("user", "Erste Frage")], nil, GenOptions.chat(4), CancelToken())
        let first = e.lastPromptTokens
        _ = try await e.complete(sys, [ChatTurn("user", "Zweite Frage")], nil, GenOptions.chat(4), CancelToken())
        XCTAssertGreaterThan(e.lastReusedTokens, first / 2, "langer gemeinsamer Systemtext wird nicht neu berechnet")
    }

    func testJsonSchemaGrammarForcesValidJson() async throws {
        let e = try makeEngine()
        let schema = Json.obj(("type", "object"), ("properties", Json.obj(("suchanfragen", Json.obj(("type", "array"), ("items", Json.obj(("type", "string"), ("maxLength", 12.0))), ("minItems", 1.0), ("maxItems", 2.0))), ("ok", Json.obj(("type", "boolean"))))), ("required", ["suchanfragen", "ok"] as [Any]))
        for _ in 0..<3 {
            let a = try await e.complete("JSON", [ChatTurn("user", "Gib Suchanfragen")], nil, GenOptions.structured(schema, 300), CancelToken())
            let o = try Json.parse(a)
            let arr = Json.arr(o, "suchanfragen")
            XCTAssertTrue((1...2).contains(arr.count), a)
            XCTAssertNotNil(Json.bool(o, "ok"), a)
        }
    }

    func testContextOverflowGivesClearMessage() async throws {
        let e = try makeEngine()
        let huge = String(repeating: "Wort ", count: 20000)
        // FitContext kuerzt den Verlauf, daher kommt eine Antwort statt eines Absturzes
        let a = try await e.complete("S", [ChatTurn("user", huge)], nil, GenOptions.chat(16), CancelToken())
        XCTAssertFalse(a.isEmpty)
    }
}

final class UpdateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items = [String]()
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
