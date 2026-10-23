import XCTest
@testable import VYRACore

final class SmokeTests: XCTestCase {
    func testCatalogLoads() throws {
        let c = try ModelInfo.catalog()
        XCTAssertEqual(c.map { $0.file }, ["Qwen3-0.6B-Q8_0.gguf", "Qwen3-4B-Instruct-2507-Q4_K_M.gguf", "Qwen3-8B-Q4_K_M.gguf"])
    }
}
