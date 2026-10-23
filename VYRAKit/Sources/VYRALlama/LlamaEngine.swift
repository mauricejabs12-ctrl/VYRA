import Foundation
import VYRACore
import llama
#if os(iOS)
import os
#endif

/// Startvariante (wie `LaunchConfig` unter Windows): Schichten auf der Grafikeinheit, kompakter Zwischenspeicher,
/// Flash-Attention und Kontextgroesse.
public struct LaunchConfig: Equatable {
    public var gpuLayers: Int
    public var quantKv: Bool
    public var flash: Bool
    public var ctx: Int
    public var key: String { "\(gpuLayers)|\(quantKv ? "q8" : "f16")|\(flash ? "on" : "auto")|\(ctx)" }
    public func describe(_ layers: Int) -> String {
        if gpuLayers <= 0 { return "Prozessor" }
        if gpuLayers >= layers { return "Apple-Grafik (Metal)" }
        return "Apple-Grafik + Prozessor (\(gpuLayers)/\(layers) Schichten)"
    }
}

/// Protokollzeilen von llama.cpp (fuer verstaendliche Fehlermeldungen).
final class LlamaLog {
    static let shared = LlamaLog()
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) {
        let t = s.trimmed
        if t.isEmpty { return }
        lock.lock(); lines.append(t.clip(300, ellipsis: "")); if lines.count > 24 { lines.removeFirst(lines.count - 24) }; lock.unlock()
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
    func clear() { lock.lock(); lines.removeAll(); lock.unlock() }
}

private let llamaBackendOnce: Void = {
    llama_backend_init()
    llama_log_set({ level, text, _ in
        guard let text = text else { return }
        // Nur Warnungen und Fehler merken (Info-Meldungen sind sehr zahlreich).
        if level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue || String(cString: text).contains("failed") { LlamaLog.shared.add(String(cString: text)) }
    }, nil)
}()

/// Das lokale VYRA-Modell direkt in der App: llama.cpp b7380 mit Metal (Apple-Grafik), ohne Server-Prozess.
/// Ersetzt `AiEngine` (llama-server.exe) und uebernimmt dessen Regeln: Pruefsumme, Kontextplanung mit Rueckfall,
/// Thinking aus (/no_think), Sampling-Werte, Grammatik fuer JSON, Prompt-Zwischenspeicher, Streaming und Abbruch.
public final class LlamaEngine: KiModelEngine {
    public let model: ModelInfo
    public let modelPath: String
    let paths: VyraPaths
    public var useGpu = true
    public var cpuContextChars = 7000
    public var loraPath = ""
    /// 4.15 Pro: groesserer Kontext (0 = Wert aus KI-Modell.json). Passt er nicht in den Speicher, startet VYRA mit dem Grundkontext.
    public var contextOverride = 0
    public var fullContext = false
    /// Speicherpruefung vor dem Laden (kann der Nutzer bewusst abschalten).
    public var memoryCheck = true
    public private(set) var contextNote: String?
    public private(set) var gpuNote: String?
    public private(set) var active: LaunchConfig?
    public private(set) var lastTokensPerSecond: Double = 0
    public private(set) var lastFinish = ""
    public private(set) var lastPromptTokens = 0
    /// Wie viele Prompt-Token beim letzten Aufruf aus dem Zwischenspeicher wiederverwendet wurden.
    public private(set) var lastReusedTokens = 0
    public private(set) var statusText = ""
    public var onStatus: ((String) -> Void)?

    private let queue = DispatchQueue(label: "vyra.llama", qos: .userInitiated)
    private let gate = AsyncGate()
    private var lmodel: OpaquePointer?
    private var lctx: OpaquePointer?
    private var lora: OpaquePointer?
    private var cached: [llama_token] = []
    private var verified = false
    private let stateLock = NSLock()
    private var loading: Task<Void, Error>?

    public init(model: ModelInfo, paths: VyraPaths) {
        _ = llamaBackendOnce
        self.model = model
        self.paths = paths
        self.modelPath = FS.join(paths.models, model.file)
    }
    deinit { unloadNow() }

    public var requestedContext: Int { contextOverride > 0 ? max(2048, min(model.maxCtx, contextOverride)) : model.ctx }
    public var contextTokens: Int { active?.ctx ?? model.ctx }
    public var gpuFull: Bool { (active?.gpuLayers ?? 0) >= model.layers }
    public var modelInstalled: Bool { FS.isFile(modelPath) && FS.size(modelPath) == model.bytes }
    public var running: Bool { stateLock.lock(); defer { stateLock.unlock() }; return lctx != nil }
    public var downloading: Bool { FS.exists(modelPath + ".download") }
    /// Wird gerade geladen (Pruefen, Speicher, Laden auf die Grafikeinheit).
    public var starting: Bool { stateLock.lock(); defer { stateLock.unlock() }; return loading != nil && lctx == nil }
    public var processorLabel: String? {
        guard running, let a = active else { return nil }
        return a.gpuLayers <= 0 ? "Prozessor" : a.gpuLayers >= model.layers ? "Grafikeinheit" : "GPU + CPU"
    }
    var verifiedMarker: String { modelPath + ".ok" }

    func say(_ s: String) { statusText = s; onStatus?(s) }

    // ------------------------------------------------ Installation
    /// Merkt sich eine erfolgreiche Pruefung (Groesse + Aenderungszeit), damit der Hash nicht bei jedem Start neu laeuft.
    func verifiedBefore() -> Bool {
        guard FS.isFile(modelPath), let t = try? FS.readText(verifiedMarker) else { return false }
        return t.trimmed == markerText()
    }
    func markerText() -> String { "\(model.sha256)|\(FS.size(modelPath))|\(Int64(FS.modified(modelPath).timeIntervalSince1970 * 1000))" }
    func markVerified() { try? FS.write(verifiedMarker, text: markerText()) }

    public func download(progress: ModelDownload.Progress?, token: CancelToken) async throws {
        try await ModelDownload.transfer(model, modelPath, progress: progress, token: token)
        verified = true
        markVerified()
    }
    public func deleteModel() {
        unloadNow()
        FS.delete(modelPath); FS.delete(verifiedMarker); FS.delete(modelPath + ".download")
        verified = false
    }
    /// Prueft die installierte Datei vollstaendig (SHA-256).
    public func verify(token: CancelToken, progress: ((Double) -> Void)? = nil) throws -> Bool {
        let ok = try ModelDownload.digest(modelPath, token, progress: progress) == model.sha256
        if ok { verified = true; markVerified() } else { FS.delete(verifiedMarker) }
        return ok
    }

    // ------------------------------------------------ Speicher
    /// Frei verfuegbarer Arbeitsspeicher fuer die App (iOS: os_proc_available_memory), sonst nil.
    public static func availableMemory() -> Int64? {
        #if os(iOS)
        let v = os_proc_available_memory()
        return v > 0 ? Int64(v) : nil
        #else
        return nil
        #endif
    }
    public static var physicalMemory: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }
    /// Geschaetzter Speicherbedarf (Gewichte + Zwischenspeicher + Rechenpuffer) in Bytes.
    public func estimatedBytes(ctx: Int, quantKv: Bool) -> Int64 {
        let kv = Double(model.kvPerToken) * Double(ctx) * (quantKv ? 0.53 : 1.0)
        return model.bytes + Int64(kv) + Int64(380 * 1_048_576 + ctx * 40_000)
    }
    /// Startvarianten fuer das iPhone: zuerst alles auf der Apple-Grafik (Metal, kompakter Zwischenspeicher),
    /// dann ohne kompakten Speicher, zuletzt Prozessor. Fuer Pro mit grossem Kontext folgt der Grundkontext als Rueckfall.
    public func plan() -> [LaunchConfig] {
        func variants(_ ctx: Int) -> [LaunchConfig] {
            var l = [LaunchConfig]()
            if useGpu { l.append(LaunchConfig(gpuLayers: 99, quantKv: true, flash: true, ctx: ctx)); l.append(LaunchConfig(gpuLayers: 99, quantKv: false, flash: false, ctx: ctx)) }
            l.append(LaunchConfig(gpuLayers: 0, quantKv: true, flash: true, ctx: ctx))
            l.append(LaunchConfig(gpuLayers: 0, quantKv: false, flash: false, ctx: ctx))
            return l
        }
        let ctx = requestedContext
        var list = variants(ctx)
        if ctx > model.ctx { list += variants(model.ctx) }
        return list
    }

    // ------------------------------------------------ Laden
    /// Laedt das Modell genau einmal; parallele Aufrufe warten auf denselben Ladevorgang.
    public func ensureStarted(_ token: CancelToken) async throws {
        if running { return }
        let t = loadingTask()
        defer { clearLoading(t) }
        let id = token.register { t.cancel() }
        defer { token.unregister(id) }
        try await t.value
        try token.check()
    }
    private func loadingTask() -> Task<Void, Error> {
        stateLock.lock(); defer { stateLock.unlock() }
        if let l = loading { return l }
        let t = Task<Void, Error>.detached(priority: .userInitiated) { [weak self] in guard let self = self else { return }; try await self.startAll() }
        loading = t
        return t
    }
    private func clearLoading(_ t: Task<Void, Error>) {
        stateLock.lock(); if loading == t { loading = nil }; stateLock.unlock()
    }

    private func startAll() async throws {
        if !modelInstalled { throw VyraError("Das KI-Modell ist noch nicht installiert.", .invalidOperation) }
        if !verified {
            if verifiedBefore() { verified = true } else {
                say("Modell wird einmalig geprüft …")
                let tok = CancelToken()
                if try ModelDownload.digest(modelPath, tok) != model.sha256 {
                    throw VyraError("Das Modell ist beschädigt. Bitte »Modell löschen« und neu herunterladen.", .invalidData)
                }
                verified = true; markVerified()
            }
        }
        let wanted = requestedContext
        contextNote = nil; gpuNote = nil
        var first: Error?
        var memoryRefusal: String?
        for cfg in plan() {
            try Task.checkCancellation()
            if memoryCheck, let avail = LlamaEngine.availableMemory() {
                let need = estimatedBytes(ctx: cfg.ctx, quantKv: cfg.quantKv)
                if need > avail {
                    if memoryRefusal == nil {
                        memoryRefusal = "\(model.name) braucht mit \(DE.n0(cfg.ctx)) Token Kontext etwa \(DE.fixed(Double(need) / 1_073_741_824, 1)) GB Arbeitsspeicher; frei sind gerade \(DE.fixed(Double(avail) / 1_073_741_824, 1)) GB."
                    }
                    continue
                }
            }
            do {
                try await loadCore(cfg)
                active = cfg
                if useGpu && cfg.gpuLayers == 0 { gpuNote = "Apple-Grafik (Metal) nicht nutzbar" + (first != nil ? " (\(first!.vyraMessage))" : "") + " – VYRA KI läuft auf dem Prozessor (langsamer)." }
                if cfg.ctx < wanted { contextNote = "\(model.name) nutzt gerade \(DE.n0(cfg.ctx)) statt \(DE.n0(wanted)) Token Kontext, weil der größere Kontext nicht in den Arbeitsspeicher passte." }
                say("VYRA KI ist bereit · " + cfg.describe(model.layers))
                return
            } catch let e where e is CancellationError {
                throw e
            } catch {
                if first == nil { first = error }
                unloadNow()
            }
        }
        if let m = memoryRefusal, first == nil {
            throw VyraError(m + " Bitte andere Apps schließen und erneut senden – oder in den Einstellungen ein kleineres Modell wählen. VYRA wechselt nicht automatisch.", .invalidOperation)
        }
        throw VyraError(first?.vyraMessage ?? "Die KI konnte nicht gestartet werden.", .invalidOperation)
    }

    private final class LoadBox { var cancelled = false; var onProgress: ((Float) -> Void)? }

    private func loadCore(_ cfg: LaunchConfig) async throws {
        LlamaLog.shared.clear()
        say(cfg.gpuLayers > 0 ? "VYRA KI wird geladen (Apple-Grafik) …" : "VYRA KI wird geladen (Prozessor) …")
        let path = modelPath
        let lora = loraPath
        let sha = model.sha256
        let threads = LlamaEngine.threads()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    var mp = llama_model_default_params()
                    mp.n_gpu_layers = Int32(cfg.gpuLayers)
                    mp.use_mmap = true
                    mp.use_mlock = false
                    let box = LoadBox()
                    var lastPct = -1
                    box.onProgress = { [weak self] p in
                        let pct = Int(p * 100)
                        if pct / 10 != lastPct / 10 { lastPct = pct; self?.say("Modell wird in den Speicher geladen … \(pct) %") }
                    }
                    let unmanaged = Unmanaged.passRetained(box)
                    defer { unmanaged.release() }
                    mp.progress_callback = { progress, user in
                        guard let user = user else { return true }
                        let b = Unmanaged<LoadBox>.fromOpaque(user).takeUnretainedValue()
                        b.onProgress?(progress)
                        return !b.cancelled
                    }
                    mp.progress_callback_user_data = unmanaged.toOpaque()
                    guard let m = llama_model_load_from_file(path, mp) else {
                        throw VyraError(LlamaEngine.explainLoadFailure(), .io)
                    }
                    var cp = llama_context_default_params()
                    cp.n_ctx = UInt32(cfg.ctx)
                    cp.n_batch = 512
                    cp.n_ubatch = 512
                    cp.n_seq_max = 1
                    cp.n_threads = Int32(threads)
                    cp.n_threads_batch = Int32(max(threads, min(8, ProcessInfo.processInfo.activeProcessorCount)))
                    cp.flash_attn_type = cfg.flash ? LLAMA_FLASH_ATTN_TYPE_AUTO : LLAMA_FLASH_ATTN_TYPE_DISABLED
                    if cfg.quantKv { cp.type_k = GGML_TYPE_Q8_0; cp.type_v = GGML_TYPE_Q8_0 }
                    cp.offload_kqv = cfg.gpuLayers > 0
                    cp.no_perf = false
                    guard let ctx = llama_init_from_model(m, cp) else {
                        llama_model_free(m)
                        throw VyraError(LlamaEngine.explainLoadFailure(), .io)
                    }
                    var adapter: OpaquePointer?
                    if !lora.isEmpty {
                        try LoraAdapter.validate(lora, sha)
                        guard let a = llama_adapter_lora_init(m, lora) else {
                            llama_free(ctx); llama_model_free(m)
                            throw VyraError("Der LoRA-Adapter konnte nicht geladen werden (passt nicht zu diesem Modell).", .invalidData)
                        }
                        if llama_set_adapter_lora(ctx, a, 1.0) != 0 {
                            llama_free(ctx); llama_model_free(m)
                            throw VyraError("Der LoRA-Adapter konnte nicht aktiviert werden.", .invalidData)
                        }
                        adapter = a
                    }
                    self.stateLock.lock()
                    self.lmodel = m; self.lctx = ctx; self.lora = adapter; self.cached = []
                    self.stateLock.unlock()
                    c.resume()
                } catch {
                    c.resume(throwing: error)
                }
            }
        }
    }

    static func explainLoadFailure() -> String {
        let l = LlamaLog.shared.text
        if l.containsIgnoreCase("out of memory") || l.containsIgnoreCase("failed to allocate") || l.containsIgnoreCase("insufficient memory") {
            return "Zu wenig Arbeitsspeicher für diese Einstellung."
        }
        if l.containsIgnoreCase("error loading model") || l.containsIgnoreCase("failed to load model") || l.containsIgnoreCase("invalid magic") {
            return "Das Modell konnte nicht geladen werden. Bitte »Modell löschen« und neu herunterladen."
        }
        return "Das Modell konnte nicht geladen werden." + (l.isEmpty ? "" : " Letzte Meldung: " + (l.split(separator: "\n").last.map(String.init) ?? ""))
    }

    /// Erzeugung: Leistungskerne; iPhone: alle bis auf zwei Kerne, hoechstens 8 (wie `AiEngine.Threads`).
    public static func threads() -> Int { max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)) }

    /// Entlaedt das Modell (gibt den Arbeitsspeicher frei). Laufende Antworten werden vorher abgebrochen.
    public func unload() async {
        await gate.enter()
        unloadNow()
        await gate.leave()
    }
    func unloadNow() {
        stateLock.lock()
        let c = lctx, m = lmodel
        lctx = nil; lmodel = nil; lora = nil; cached = []
        stateLock.unlock()
        queue.sync {
            if let c = c { llama_free(c) }
            if let m = m { llama_model_free(m) }
        }
        active = nil
    }

    // ------------------------------------------------ Antworten
    /// Allgemeiner Aufruf mit eigenem Verlauf (fuer Chat, Recherche und Arbeitsmodus). Immer nur eine Antwort gleichzeitig.
    public func complete(_ system: String, _ turns: [ChatTurn], _ onText: ((String) -> Void)?, _ opt: GenOptions, _ token: CancelToken) async throws -> String {
        await gate.enter()
        do {
            let r = try await completeCore(system, turns, onText, opt, token)
            await gate.leave()
            return r
        } catch {
            await gate.leave()
            throw error
        }
    }

    /// Baut den Qwen3-Chat-Text genau wie die Chatvorlage des Modells (ChatML). Bei Modellen mit Denkmodus wird
    /// das Nachdenken wie unter Windows abgeschaltet: " /no_think" an der letzten Nutzernachricht und ein leerer
    /// Denkblock (entspricht `chat_template_kwargs: enable_thinking=false`).
    public static func prompt(system: String, turns: [ChatTurn], thinkingModel: Bool) -> String {
        var b = "<|im_start|>system\n" + system + "<|im_end|>\n"
        for (i, t) in turns.enumerated() {
            var c = t.content
            if i == turns.count - 1 && t.role == "user" && thinkingModel { c += " /no_think" }
            b += "<|im_start|>" + t.role + "\n" + c + "<|im_end|>\n"
        }
        b += "<|im_start|>assistant\n"
        if thinkingModel { b += "<think>\n\n</think>\n\n" }
        return b
    }

    private func completeCore(_ system: String, _ turns: [ChatTurn], _ onText: ((String) -> Void)?, _ opt: GenOptions, _ token: CancelToken) async throws -> String {
        if !running { try await ensureStarted(token) }
        guard running else { throw VyraError("VYRA KI ist nicht gestartet.", .invalidOperation) }
        let fit = EngineText.fitContext(system, turns, contextTokens, opt.maxTokens)
        let text = LlamaEngine.prompt(system: system, turns: fit.turns, thinkingModel: model.thinking)
        let grammar = try opt.jsonSchema.map { try JsonGrammar.gbnf($0) }
        lastFinish = ""
        let answer: String = try await withCheckedThrowingContinuation { c in
            queue.async {
                do { c.resume(returning: try self.generate(text, fit.outTokens, opt, grammar, onText, token)) }
                catch { c.resume(throwing: error) }
            }
        }
        if answer.isEmpty { throw VyraError("Das Modell hat keine Antwort geliefert. Bitte die Frage anders formulieren.", .invalidData) }
        return answer
    }

    private func tokenize(_ vocab: OpaquePointer, _ text: String) -> [llama_token] {
        let utf8 = Array(text.utf8)
        var n = Int32(utf8.count + 16)
        var out = [llama_token](repeating: 0, count: Int(n))
        var r = utf8.withUnsafeBufferPointer { p in
            p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: utf8.count) { cs in
                llama_tokenize(vocab, cs, Int32(utf8.count), &out, n, true, true)
            }
        }
        if r < 0 {
            n = -r
            out = [llama_token](repeating: 0, count: Int(n))
            r = utf8.withUnsafeBufferPointer { p in
                p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: utf8.count) { cs in
                    llama_tokenize(vocab, cs, Int32(utf8.count), &out, n, true, true)
                }
            }
        }
        return Array(out.prefix(Int(max(0, r))))
    }
    private func piece(_ vocab: OpaquePointer, _ t: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, t, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n) + 8)
            n = llama_token_to_piece(vocab, t, &buf, Int32(buf.count), 0, false)
        }
        return buf.prefix(Int(max(0, n))).map { UInt8(bitPattern: $0) }
    }
    /// Laenge des vollstaendigen UTF-8-Anfangs (unvollstaendige Zeichen am Ende werden zurueckgehalten).
    static func completeUTF8(_ b: [UInt8]) -> Int {
        var i = b.count
        var back = 0
        while i > 0 && back < 4 {
            let c = b[i - 1]
            if c & 0x80 == 0 { return b.count }
            if c & 0xC0 == 0xC0 {
                let need = c & 0xE0 == 0xC0 ? 2 : c & 0xF0 == 0xE0 ? 3 : c & 0xF8 == 0xF0 ? 4 : 1
                return back + 1 >= need ? b.count : i - 1
            }
            i -= 1; back += 1
        }
        return b.count
    }

    private func decodeBatch(_ ctx: OpaquePointer, _ tokens: ArraySlice<llama_token>, startPos: Int, wantLast: Bool) -> Int32 {
        let n = tokens.count
        var batch = llama_batch_init(Int32(n), 0, 1)
        defer { llama_batch_free(batch) }
        for (k, t) in tokens.enumerated() {
            batch.token[k] = t
            batch.pos[k] = llama_pos(startPos + k)
            batch.n_seq_id[k] = 1
            batch.seq_id[k]![0] = 0
            batch.logits[k] = (wantLast && k == n - 1) ? 1 : 0
        }
        batch.n_tokens = Int32(n)
        return llama_decode(ctx, batch)
    }

    /// Laeuft auf der Modell-Warteschlange: Prompt einlesen (mit Wiederverwendung des gemeinsamen Anfangs), dann Token fuer Token erzeugen.
    private func generate(_ text: String, _ maxTokens: Int, _ opt: GenOptions, _ grammar: String?, _ onText: ((String) -> Void)?, _ token: CancelToken) throws -> String {
        stateLock.lock()
        guard let ctx = lctx, let m = lmodel else { stateLock.unlock(); throw VyraError("VYRA KI ist nicht gestartet.", .invalidOperation) }
        stateLock.unlock()
        let vocab = llama_model_get_vocab(m)!
        let nCtx = Int(llama_n_ctx(ctx))
        let tokens = tokenize(vocab, text)
        if tokens.isEmpty { throw VyraError("Leere Anfrage.", .argument) }
        if tokens.count >= nCtx - 8 {
            throw VyraError("Zu viel Text für das lokale Modell. Bitte die Aufgabe kürzer fassen oder weniger Dateien wählen.", .invalidOperation)
        }
        lastPromptTokens = tokens.count
        let mem = llama_get_memory(ctx)
        // Gemeinsamen Anfang mit dem letzten Aufruf wiederverwenden (wie cache_prompt/cache-reuse unter Windows).
        var common = 0
        let limit = min(cached.count, tokens.count)
        while common < limit && cached[common] == tokens[common] { common += 1 }
        if common >= tokens.count { common = tokens.count - 1 }
        if common < cached.count {
            if !llama_memory_seq_rm(mem, 0, llama_pos(common), -1) { llama_memory_clear(mem, true); common = 0 }
            cached = Array(cached.prefix(common))
        }
        lastReusedTokens = common
        var pos = common
        let nBatch = 512
        while pos < tokens.count {
            if token.isCancelled { throw VyraError.cancelled }
            let end = min(tokens.count, pos + nBatch)
            let rc = decodeBatch(ctx, tokens[pos..<end], startPos: pos, wantLast: end == tokens.count)
            if rc != 0 {
                llama_memory_clear(mem, true); cached = []
                throw VyraError(rc == 1 ? "Zu viel Text für das lokale Modell. Bitte die Aufgabe kürzer fassen." : "Das Modell konnte den Text nicht verarbeiten (Fehler \(rc)). " + LlamaEngine.explainLoadFailure(), .io)
            }
            cached.append(contentsOf: tokens[pos..<end])
            pos = end
        }
        // Sampler wie llama-server: Strafen -> top_k -> top_p -> min_p -> Temperatur -> Zufall; Grammatik getrennt.
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        defer { llama_sampler_free(chain) }
        if opt.presencePenalty > 0 { llama_sampler_chain_add(chain, llama_sampler_init_penalties(64, 1.0, 0.0, Float(opt.presencePenalty))) }
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(Int32(opt.topK)))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(Float(opt.topP), 1))
        if opt.minP > 0 { llama_sampler_chain_add(chain, llama_sampler_init_min_p(Float(opt.minP), 1)) }
        llama_sampler_chain_add(chain, llama_sampler_init_temp(Float(opt.temperature)))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 1...UInt32.max - 1)))
        var gram: UnsafeMutablePointer<llama_sampler>?
        if let g = grammar {
            gram = llama_sampler_init_grammar(vocab, g, "root")
            if gram == nil { throw VyraError("Interne Grammatik für strukturierte Antwort ist ungültig.", .invalidData) }
        }
        defer { if let g = gram { llama_sampler_free(g) } }
        let nVocab = Int(llama_vocab_n_tokens(vocab))
        var candidates = [llama_token_data](repeating: llama_token_data(id: 0, logit: 0, p: 0), count: nVocab)
        var bytes = [UInt8]()
        var produced = 0
        let maxNew = min(maxTokens, nCtx - tokens.count - 1)
        var finish = "length"
        let clock = Date()
        var firstAt: Date?
        var lastPaint = Date.distantPast
        while produced < maxNew {
            if token.isCancelled { throw VyraError.cancelled }
            var next: llama_token
            if let g = gram {
                // Erst ohne Grammatik waehlen und pruefen (schnell); nur bei Verstoss auf allen Kandidaten mit Grammatik.
                let logits = llama_get_logits_ith(ctx, -1)!
                next = llama_sampler_sample(chain, ctx, -1)
                var single = llama_token_data(id: next, logit: 1, p: 0)
                var ok = true
                withUnsafeMutablePointer(to: &single) { sp in
                    var arr = llama_token_data_array(data: sp, size: 1, selected: -1, sorted: false)
                    llama_sampler_apply(g, &arr)
                    ok = sp.pointee.logit.isFinite
                }
                if !ok {
                    for i in 0..<nVocab { candidates[i] = llama_token_data(id: llama_token(i), logit: logits[i], p: 0) }
                    candidates.withUnsafeMutableBufferPointer { cp in
                        var arr = llama_token_data_array(data: cp.baseAddress, size: nVocab, selected: -1, sorted: false)
                        llama_sampler_apply(g, &arr)
                        llama_sampler_apply(chain, &arr)
                        if arr.selected >= 0 && arr.selected < arr.size { next = arr.data[Int(arr.selected)].id }
                    }
                    llama_sampler_accept(chain, next)
                }
                llama_sampler_accept(g, next)
            } else {
                next = llama_sampler_sample(chain, ctx, -1)
            }
            if llama_vocab_is_eog(vocab, next) { finish = "stop"; break }
            bytes.append(contentsOf: piece(vocab, next))
            produced += 1
            if firstAt == nil { firstAt = Date() }
            let one: [llama_token] = [next]
            let rc = decodeBatch(ctx, one[0..<1], startPos: cached.count, wantLast: true)
            if rc != 0 { finish = "length"; break }
            cached.append(next)
            if let onText = onText, Date().timeIntervalSince(lastPaint) >= 0.06 {
                lastPaint = Date()
                let s = String(decoding: bytes.prefix(LlamaEngine.completeUTF8(bytes)), as: UTF8.self)
                onText(EngineText.clean(s).trimStart())
            }
        }
        if let f = firstAt, produced > 3 {
            let s = Date().timeIntervalSince(f)
            if s > 0.2 { lastTokensPerSecond = Double(produced - 1) / s }
        }
        _ = clock
        lastFinish = finish
        let answer = EngineText.clean(String(decoding: bytes, as: UTF8.self)).trimmed
        onText?(answer)
        return answer
    }
}

/// LoRA-Adapter (aus `LoraAdapter`): nur GGUF-Adapter mit .vyra.json-Zuordnung zu genau diesem Basismodell
/// und passender Pruefsumme.
public enum LoraAdapter {
    static let lock = NSLock()
    static var verified = Set<String>()
    public static func validate(_ path: String, _ baseSha: String) throws {
        if path.trimmed.isEmpty || path.contains("\"") || path.contains("\r") || path.contains("\n") || path.contains("\0") || !path.lowercased().hasSuffix(".gguf") {
            throw VyraError("Ungueltiger LoRA-Dateipfad.", .invalidData)
        }
        let manifest = path + ".vyra.json"
        let size = FS.size(path)
        if !FS.isFile(path) || size < 32 || size > 2_147_483_648 || !FS.isFile(manifest) || FS.size(manifest) > 32768 {
            throw VyraError("GGUF-Adapter oder .vyra.json-Zuordnung fehlt.", .invalidData)
        }
        let key = "\(FS.full(path))|\(size)|\(FS.modified(path).timeIntervalSince1970)|\(FS.size(manifest))|\(FS.modified(manifest).timeIntervalSince1970)|\(baseSha)"
        lock.lock(); defer { lock.unlock() }
        if verified.contains(key) { return }
        let o = try Json.readFile(manifest, maxBytes: 32768)
        if Json.str(o, "format") != "vyra-lora-1" || !Json.str(o, "base_sha256").equalsIgnoreCase(baseSha) {
            throw VyraError("Dieser Adapter ist einem anderen Basismodell zugeordnet.", .invalidData)
        }
        let expected = Json.str(o, "adapter_sha256")
        guard let fh = FileHandle(forReadingAtPath: path) else { throw VyraError("Adapter nicht lesbar.", .io) }
        let header = fh.readData(ofLength: 4)
        try? fh.close()
        if header != Data("GGUF".utf8) { throw VyraError("Kein GGUF-Adapter.", .invalidData) }
        let actual = try SHA256Hasher.file(path)
        if !actual.equalsIgnoreCase(expected) { throw VyraError("Die Adapterpruefsumme stimmt nicht.", .invalidData) }
        verified.insert(key)
    }
}
