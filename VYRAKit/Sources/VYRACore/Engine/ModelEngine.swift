import Foundation

/// Das lokale Modell mit Verwaltung (Start, Status, Einstellungen) – umgesetzt von `LlamaEngine` (VYRALlama).
/// Entspricht den Teilen von `AiEngine`, die das KI-Fenster unter Windows benutzt.
public protocol KiModelEngine: LocalEngine {
    var modelInstalled: Bool { get }
    var running: Bool { get }
    var starting: Bool { get }
    var statusText: String { get }
    var onStatus: ((String) -> Void)? { get set }
    var contextNote: String? { get }
    var gpuNote: String? { get }
    /// "Grafikeinheit" / "GPU + CPU" / "Prozessor" (nil = nicht geladen)
    var processorLabel: String? { get }
    var useGpu: Bool { get set }
    var cpuContextChars: Int { get set }
    var loraPath: String { get set }
    var contextOverride: Int { get set }
    var fullContext: Bool { get set }
    func ensureStarted(_ token: CancelToken) async throws
    func unload() async
}
