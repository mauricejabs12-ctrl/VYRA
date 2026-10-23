import Foundation
import XCTest
@testable import VYRACore

/// Gemeinsame Hilfen fuer die Tests: temporaere Ordner, Testmodell, lokaler Download-Server.
enum TestEnv {
    static var repoRoot: String {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { u.deleteLastPathComponent() }
        return u.path
    }
    static var testModel: String? {
        let p = ProcessInfo.processInfo.environment["VYRA_TEST_MODEL"] ?? "/home/claude/testmodel/vyra-test-qwen3.gguf"
        return FS.isFile(p) ? p : nil
    }
    static let testModelSha = "33256078a7e3e54d6bc6dbab1d463ea2815b788f3aadb1cbcd4ee70eafae4871"
    static func tempDir(_ name: String = "t") -> String {
        let p = FS.join(NSTemporaryDirectory(), "vyra-tests-" + name + "-" + FS.newId())
        try? FS.mkdir(p)
        return p
    }
    static func paths() -> VyraPaths {
        let r = tempDir("paths")
        return VyraPaths(dataRoot: FS.join(r, "data"), documents: FS.join(r, "docs"))
    }
    static func testModelInfo(sha: String = testModelSha, url: String = "https://huggingface.co/test/vyra-test-qwen3.gguf") -> ModelInfo {
        let m = ModelInfo()
        m.file = "vyra-test-qwen3.gguf"; m.name = "VYRA Test"; m.url = url; m.sha256 = sha
        m.bytes = FS.size(testModel ?? "") ; m.thinking = true; m.ctx = 2048; m.maxCtx = 4096; m.layers = 2; m.kvPerToken = 2048; m.key = "test"
        return m
    }
}

/// Startet scripts/range-server.py fuer Download-Tests.
final class RangeServer {
    let process = Process()
    let port: Int
    init?(file: String, dropAfter: Int = 0) {
        port = Int.random(in: 20000...40000)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", FS.join(TestEnv.repoRoot, "scripts", "range-server.py"), file, String(port), String(dropAfter)]
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let line = pipe.fileHandleForReading.availableData
        if !String(decoding: line, as: UTF8.self).contains("ready") { process.terminate(); return nil }
    }
    var url: String { "http://127.0.0.1:\(port)/model.gguf" }
    deinit { process.terminate() }
}
