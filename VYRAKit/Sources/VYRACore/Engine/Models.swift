import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Modellbeschreibung aus KI-Modell*.json – unveraendert aus dem Windows-Paket uebernommen
/// (Dateiname, Download-Quelle, SHA-256, Groesse, Kontext, Schichten, Pro-Kennzeichnung).
public final class ModelInfo {
    public var file = "", name = "", url = "", sha256 = "", license = "", source = "", runtime = ""
    public var bytes: Int64 = 0
    public var thinking = true
    public var ctx = 4096
    public var layers = 36
    public var kvPerToken: Int64 = 147456
    /// 4.15: "tier":"pro" kennzeichnet VYRA Pro; "max_ctx" ist der groesste erlaubte Kontext (Standard: ctx).
    public var tier = ""
    public var maxCtx = 0
    public var isPro: Bool { tier == "pro" }
    /// Kurzkennung wie in den Einstellungen unter Windows (bot.localModel): small | large | pro.
    public var key = ""
    public init() {}

    public static func load(_ path: String) throws -> ModelInfo {
        try parse(Json.readFile(path, maxBytes: 16384))
    }
    public static func parse(_ o: Any) throws -> ModelInfo {
        let m = ModelInfo()
        m.file = Json.str(o, "model"); m.name = Json.str(o, "name"); m.url = Json.str(o, "url"); m.sha256 = Json.str(o, "sha256").lowercased()
        m.license = Json.str(o, "license"); m.source = Json.str(o, "source"); m.runtime = Json.str(o, "runtime"); m.bytes = Int64(Json.num(o, "bytes", 0))
        if let th = Json.get(o, "thinking") as? Bool { m.thinking = th }
        m.ctx = max(2048, min(32768, Int(Json.num(o, "ctx", 4096))))
        m.layers = max(1, min(200, Int(Json.num(o, "layers", 36))))
        m.kvPerToken = max(1024, Int64(Json.num(o, "kv_bytes_per_token", 147456)))
        m.tier = Json.str(o, "tier").trimmed.lowercased()
        m.maxCtx = max(m.ctx, min(32768, Int(Json.num(o, "max_ctx", Double(m.ctx)))))
        guard let u = URL(string: m.url), u.scheme == "https", u.host == "huggingface.co" else {
            throw VyraError("KI-Modell.json: nur https-Downloads von huggingface.co sind erlaubt.", .invalidData)
        }
        if m.file.isEmpty || m.file.contains("/") || m.file.contains("\\") || m.file.contains(":") || !m.file.lowercased().hasSuffix(".gguf") {
            throw VyraError("KI-Modell.json: ungültiger Dateiname.", .invalidData)
        }
        if m.sha256.len != 64 || m.bytes < 1_000_000 { throw VyraError("KI-Modell.json: Prüfsumme oder Größe fehlt.", .invalidData) }
        return m
    }
    /// Die drei mitgelieferten Modelle (Mini, Standard, Pro) aus dem App-Paket.
    public static func catalog() throws -> [ModelInfo] {
        var list = [ModelInfo]()
        for (key, file) in [("small", "KI-Modell"), ("large", "KI-Modell-4B"), ("pro", "KI-Modell-8B")] {
            guard let url = Bundle.module.url(forResource: file, withExtension: "json", subdirectory: "Resources/Modelle") else {
                throw VyraError("Modellbeschreibung fehlt im App-Paket: \(file).json", .io)
            }
            let m = try load(url.path); m.key = key; list.append(m)
        }
        return list
    }
    public var sizeText: String { bytes >= 1_000_000_000 ? DE.fixed(Double(bytes) / 1e9, 1) + " GB" : DE.n0(Double(bytes) / 1e6) + " MB" }
}

/// 4.14.1: Prueft, ob eine Fortsetzung wirklich neuen Text bringt (sonst Endlosschleife vermeiden).
public enum ContinuationGuard {
    public static func hasNewText(_ previous: String, _ next: String) -> Bool {
        if next.trimmed.isEmpty { return false }
        func norm(_ s: String) -> String { Rx.replace(s, #"\s+"#, " ").trimmed }
        let p = norm(previous), n = norm(next)
        return n.len > 0 && p.indexOf(n) < 0
    }
}

/// Modelldownload wie unter Windows: setzt unterbrochene Downloads fort (HTTP-Range), prueft Groesse und SHA-256
/// und uebernimmt die Datei erst nach erfolgreicher Pruefung. Bis zu drei Versuche, 60 s ohne Daten = Abbruch.
public enum ModelDownload {
    public typealias Progress = (Double, String) -> Void
    static func partSize(_ part: String) -> Int64 { FS.isFile(part) ? FS.size(part) : 0 }
    static func report(_ p: Progress?, _ v: Double, _ t: String) { p?(v, t) }

    public static func digest(_ path: String, _ token: CancelToken, progress: ((Double) -> Void)? = nil) throws -> String {
        try SHA256Hasher.file(path, progress: progress, cancelled: { token.isCancelled })
    }
    static func verified(_ part: String, _ model: ModelInfo, _ progress: Progress?, _ token: CancelToken) throws -> Bool {
        if partSize(part) != model.bytes { return false }
        report(progress, 99, "Download vollständig. Prüfsumme wird geprüft …")
        return try digest(part, token) == model.sha256
    }
    /// Nur diese Fehler werden automatisch wiederholt (Netz, Zeitueberschreitung); Datenfehler nicht.
    static func retryable(_ error: Error, _ token: CancelToken) -> Bool {
        if token.isCancelled { return false }
        if let v = error as? VyraError { return v.kind == .io || v.kind == .timeout }
        return (error as NSError).domain == NSURLErrorDomain
    }

    public static func transfer(_ model: ModelInfo, _ destination: String, progress: Progress?, token: CancelToken, session: URLSession = .shared) async throws {
        let part = destination + ".download"
        try FS.mkdir(FS.dirName(destination))
        // Sperre: verhindert, dass zwei Downloads dieselbe Teildatei schreiben.
        let lockPath = part + ".lock"
        let lock = DownloadLock(lockPath)
        guard lock.acquire() else { throw VyraError("Dieses Modell wird bereits geladen. Bitte den anderen Download abwarten oder beenden.", .io) }
        defer { lock.release() }
        try token.check()
        if partSize(part) > model.bytes { FS.delete(part) }
        // Akzeptiert auch eine vollstaendige, gepruefte Datei aus einem frueheren, unterbrochenen Schritt.
        let completeVerified = partSize(part) == model.bytes ? try verified(part, model, progress, token) : false
        if partSize(part) == model.bytes && !completeVerified { FS.delete(part) }
        var attempt = 0
        while partSize(part) < model.bytes {
            try token.check()
            let offset = partSize(part)
            let free = FS.freeSpace(FS.dirName(destination))
            if free < model.bytes - offset + 200 * 1_048_576 {
                throw VyraError("Zu wenig freier Speicher auf dem iPhone. Für den restlichen Download und Reserve werden etwa \(DE.n0(Double((model.bytes - offset) / 1_048_576 + 200))) MB benötigt.", .invalidData)
            }
            report(progress, Double(offset) * 99.0 / Double(model.bytes), (offset > 0 ? "Download wird fortgesetzt: " : "Download startet: ") + "\(offset / 1_048_576) von \(model.bytes / 1_048_576) MB")
            var retry = false
            do {
                try await receive(model, part, session, progress, token)
                if partSize(part) != model.bytes { throw VyraError("Download unvollständig. Bereits geladene Daten bleiben gespeichert.", .io) }
            } catch {
                if !retryable(error, token) || attempt >= 2 {
                    if token.isCancelled { throw VyraError.cancelled }
                    if let v = error as? VyraError, v.kind == .timeout { throw VyraError("Der Download antwortet zu lange nicht. Bereits geladene Daten bleiben erhalten; erneut auf Herunterladen tippen.", .io) }
                    throw error
                }
                report(progress, Double(partSize(part)) * 99.0 / Double(model.bytes), "Verbindung unterbrochen. Neuer Versuch \(attempt + 2) von 3; bisherige Daten bleiben erhalten.")
                retry = true
            }
            if retry { try await delay(Double(attempt + 1), token) }
            attempt += 1
        }
        if !completeVerified {
            if !(try verified(part, model, progress, token)) {
                FS.delete(part)
                throw VyraError("Die Modell-Prüfsumme stimmt nicht. Die ungültige Download-Datei wurde entfernt; ein vorhandenes Modell bleibt erhalten. Bitte erneut laden.", .invalidData)
            }
        }
        try token.check()
        if FS.exists(destination) { FS.delete(destination) }
        try FS.fm.moveItem(atPath: part, toPath: destination)
        excludeFromBackup(destination)
        report(progress, 100, "Modell geprüft und installiert.")
    }

    /// Modelle sind gross und jederzeit neu ladbar: nicht ins iCloud-Backup aufnehmen.
    public static func excludeFromBackup(_ path: String) {
        #if os(iOS)
        var url = URL(fileURLWithPath: path)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? url.setResourceValues(v)
        #endif
    }

    static func receive(_ model: ModelInfo, _ part: String, _ session: URLSession, _ progress: Progress?, _ token: CancelToken) async throws {
        var offset = partSize(part)
        guard let url = URL(string: model.url) else { throw VyraError("Ungültige Download-Adresse.", .invalidData) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        req.setValue("VYRA-KI-iOS/4.15", forHTTPHeaderField: "User-Agent")
        if offset > 0 { req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let streamer = DownloadStreamer(request: req, session: session, token: token)
        let head = try await streamer.start()
        let code = head.statusCode
        if !(200...299).contains(code) {
            streamer.cancel()
            let hint = code == 401 || code == 403 ? " Zugriff abgewiesen; Verbindung, VPN/Proxy und Filter prüfen." : code == 404 ? " Modelldatei nicht gefunden." : ""
            if code == 408 || code == 429 || code >= 500 { throw VyraError("Download-Server: HTTP \(code).\(hint)", .io) }
            throw VyraError("Download-Server: HTTP \(code).\(hint)", .invalidData)
        }
        if code == 206 {
            let range = head.value(forHTTPHeaderField: "Content-Range") ?? ""
            // bytes 100-999/1000
            let m = Rx.match(range, #"^bytes\s+(\d+)-(\d+)/(\d+)$"#)
            if m == nil || Int64(m!.group(1)) != offset || Int64(m!.group(3)) != model.bytes || Int64(m!.group(2)) != model.bytes - 1 {
                streamer.cancel()
                throw VyraError("Der Server liefert einen ungültigen Download-Bereich. Die vorhandene Teildatei bleibt erhalten.", .invalidData)
            }
        } else if code == 200 {
            // Server ignoriert Range: neu beginnen statt eine ganze Datei an eine Teildatei anzuhaengen.
            offset = 0
        } else {
            streamer.cancel()
            throw VyraError("Unerwarteter HTTP-Status beim Modelldownload.", .invalidData)
        }
        let remaining = model.bytes - offset
        if head.expectedContentLength > 0 && head.expectedContentLength != remaining {
            streamer.cancel()
            throw VyraError("Unerwartete Modellgröße: \(head.expectedContentLength) statt \(remaining) Bytes.", .invalidData)
        }
        if offset == 0 { FS.delete(part); _ = FS.fm.createFile(atPath: part, contents: nil) }
        guard let out = FileHandle(forWritingAtPath: part) else { streamer.cancel(); throw VyraError("Teildatei nicht beschreibbar.", .io) }
        defer { try? out.close() }
        out.seekToEndOfFile()
        var total = offset
        let start = Date()
        var lastReport = Date.distantPast
        do {
            while let chunk = try await streamer.next(stall: 60) {
                if Int64(chunk.count) > model.bytes - total { throw VyraError("Der Download ist größer als erwartet. Die Datei wurde nicht installiert.", .invalidData) }
                out.write(chunk)
                total += Int64(chunk.count)
                if Date().timeIntervalSince(lastReport) >= 0.25 {
                    lastReport = Date()
                    let speed = Double(total - offset) / 1_048_576.0 / max(0.5, Date().timeIntervalSince(start))
                    report(progress, Double(total) * 99.0 / Double(model.bytes), "Lade Modell: \(DE.n0(Double(total) / 1_048_576.0)) von \(DE.n0(Double(model.bytes) / 1_048_576.0)) MB | \(DE.fixed(speed, 1)) MB/s")
                }
            }
        } catch {
            streamer.cancel()
            try? out.synchronize()
            throw error
        }
        try? out.synchronize()
    }
}

/// Einfache Dateisperre (nur innerhalb der App relevant; verhindert doppelte Downloads).
final class DownloadLock {
    let path: String
    static let lock = NSLock()
    static var held = Set<String>()
    init(_ p: String) { path = p }
    func acquire() -> Bool {
        DownloadLock.lock.lock(); defer { DownloadLock.lock.unlock() }
        if DownloadLock.held.contains(path) { return false }
        DownloadLock.held.insert(path)
        return true
    }
    func release() { DownloadLock.lock.lock(); DownloadLock.held.remove(path); DownloadLock.lock.unlock() }
}

/// Liefert die Antwort eines HTTP-Aufrufs Stueck fuer Stueck (fuer grosse Downloads und Streaming-Antworten).
public final class DownloadStreamer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let request: URLRequest
    let token: CancelToken
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var finished = false
    private var failure: Error?
    private var response: HTTPURLResponse?
    private var headWaiter: CheckedContinuation<HTTPURLResponse, Error>?
    private var dataWaiter: CheckedContinuation<Void, Never>?
    private var cancelId = -1

    public init(request: URLRequest, session: URLSession = .shared, token: CancelToken) {
        self.request = request
        self.token = token
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = max(30, request.timeoutInterval)
        cfg.timeoutIntervalForResource = 7 * 24 * 3600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1
        self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: q)
    }
    /// Startet den Aufruf und wartet auf die Kopfzeilen.
    public func start() async throws -> HTTPURLResponse {
        try token.check()
        cancelId = token.register { [weak self] in self?.cancel() }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<HTTPURLResponse, Error>) in
            lock.lock()
            if let r = response { lock.unlock(); c.resume(returning: r); return }
            if let f = failure { lock.unlock(); c.resume(throwing: f); return }
            headWaiter = c
            lock.unlock()
            let t = session.dataTask(with: request)
            task = t
            t.resume()
        }
    }
    /// Naechstes Datenstueck; nil = fertig. `stall`: Sekunden ohne Daten bis zur Zeitueberschreitung.
    public func next(stall: Double) async throws -> Data? {
        let begin = Date()
        while true {
            switch poll() {
            case .data(let d): return d
            case .failed(let f): throw f
            case .done: return nil
            case .waiting: break
            }
            if token.isCancelled { cancel(); throw VyraError.cancelled }
            if Date().timeIntervalSince(begin) > stall {
                cancel()
                throw VyraError("Keine Daten vom Server seit \(Int(stall)) Sekunden.", .timeout)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    private enum Poll { case data(Data), failed(Error), done, waiting }
    private func poll() -> Poll {
        lock.lock(); defer { lock.unlock() }
        if !chunks.isEmpty {
            var d = Data()
            for c in chunks { d.append(c) }
            chunks.removeAll()
            return .data(d)
        }
        if let f = failure { return .failed(f) }
        if finished { return .done }
        return .waiting
    }
    public func cancel() {
        task?.cancel()
        lock.lock()
        if failure == nil && !finished { failure = token.isCancelled ? VyraError.cancelled : VyraError("Abgebrochen.", .cancelled) }
        let w = headWaiter; headWaiter = nil
        lock.unlock()
        w?.resume(throwing: failure ?? VyraError.cancelled)
        session.invalidateAndCancel()
    }
    deinit { if cancelId >= 0 { token.unregister(cancelId) } }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let http = response as? HTTPURLResponse
        self.response = http
        let w = headWaiter; headWaiter = nil
        lock.unlock()
        if let h = http { w?.resume(returning: h) } else { w?.resume(throwing: VyraError("Keine HTTP-Antwort.", .io)) }
        completionHandler(.allow)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); chunks.append(data); lock.unlock()
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if let e = error {
            if failure == nil { failure = (e as NSError).code == NSURLErrorCancelled ? VyraError.cancelled : VyraError((e as NSError).localizedDescription.isEmpty ? "Netzwerkfehler." : e.vyraMessage, .io) }
        } else { finished = true }
        let w = headWaiter; headWaiter = nil
        let f = failure
        lock.unlock()
        if let w = w { w.resume(throwing: f ?? VyraError("Keine HTTP-Antwort.", .io)) }
        session.finishTasksAndInvalidate()
    }
}
