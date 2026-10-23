import Foundation

/// Abbruchsignal wie `CancellationTokenSource`/`CancellationToken` unter Windows: kann manuell, per Frist
/// (`cancelAfter`) oder ueber verknuepfte Quellen ausgeloest werden. Die Modellschleife von llama.cpp prueft es
/// zwischen jedem Token, damit »Stopp« sofort wirkt.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [Int: () -> Void] = [:]
    private var nextId = 0
    private var timer: DispatchSourceTimer?
    private var deadline: Date?
    private var links: [(CancelToken, Int)] = []
    public init() {}
    /// Neues Signal, das auch ausloest, wenn eines der `parents` ausloest.
    public static func linked(_ parents: CancelToken?...) -> CancelToken {
        let t = CancelToken()
        for p in parents.compactMap({ $0 }) {
            let id = p.register { [weak t] in t?.cancel() }
            t.lock.lock(); t.links.append((p, id)); t.lock.unlock()
        }
        return t
    }
    public static let none = CancelToken()
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func cancel() {
        lock.lock()
        if cancelled { lock.unlock(); return }
        cancelled = true
        let hs = handlers.values
        handlers.removeAll()
        timer?.cancel(); timer = nil
        lock.unlock()
        for h in hs { h() }
    }
    /// Loest nach `seconds` Sekunden aus (wie `CancelAfter`). Ein neuer Aufruf ersetzt die alte Frist.
    public func cancelAfter(_ seconds: Double) {
        lock.lock()
        timer?.cancel()
        if cancelled { lock.unlock(); return }
        deadline = Date().addingTimeInterval(seconds)
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        t.schedule(deadline: .now() + max(0, seconds))
        t.setEventHandler { [weak self] in self?.cancel() }
        timer = t
        lock.unlock()
        t.resume()
    }
    public var remaining: Double? { lock.lock(); defer { lock.unlock() }; return deadline.map { $0.timeIntervalSinceNow } }
    @discardableResult
    public func register(_ h: @escaping () -> Void) -> Int {
        lock.lock()
        if cancelled { lock.unlock(); h(); return -1 }
        nextId += 1
        let id = nextId
        handlers[id] = h
        lock.unlock()
        return id
    }
    public func unregister(_ id: Int) { lock.lock(); handlers.removeValue(forKey: id); lock.unlock() }
    /// Wirft `VyraError.cancelled`, wenn ausgeloest (wie `ThrowIfCancellationRequested`).
    public func check() throws { if isCancelled { throw VyraError.cancelled } }
    deinit {
        timer?.cancel()
        for (p, id) in links { p.unregister(id) }
    }
}

/// Wartet `seconds` Sekunden, bricht bei Abbruch sofort ab.
public func delay(_ seconds: Double, _ token: CancelToken) async throws {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        try token.check()
        try await Task.sleep(nanoseconds: UInt64(min(0.1, max(0.001, end.timeIntervalSinceNow)) * 1_000_000_000))
    }
    try token.check()
}

/// Kleiner asynchroner Mutex (wie `SemaphoreSlim(1,1)`), damit immer nur eine Antwort gleichzeitig erzeugt wird.
public actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}
    public func enter() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    public func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
