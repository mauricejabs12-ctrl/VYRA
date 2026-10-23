import Foundation

/// Einfache Einstellungsdatei (Schluessel=Wert), Format identisch zu VYRA unter Windows (VYRA-NOVA.cfg).
public final class Settings {
    public let path: String
    private var values: [String: String] = [:]   // Schluessel klein geschrieben -> Wert (wie OrdinalIgnoreCase)
    private var display: [String: String] = [:]  // Originalschreibweise
    private let lock = NSLock()

    public init(_ file: String) {
        path = file
        if FS.isFile(path), FS.size(path) < 262_144, let text = try? FS.readText(path) {
            for line in text.splitKeep("\n") {
                let l = line.hasSuffix("\r") ? String(line.dropLast()) : line
                guard let p = l.firstIndex(of: "="), !l.hasPrefix("#") else { continue }
                let k = String(l[..<p]).trimmed
                if k.isEmpty { continue }
                values[k.lowercased()] = Settings.unescape(String(l[l.index(after: p)...]))
                display[k.lowercased()] = k
            }
        }
    }
    public func get(_ key: String, _ fallback: String) -> String { lock.lock(); defer { lock.unlock() }; return values[key.lowercased()] ?? fallback }
    public func has(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return values[key.lowercased()] != nil }
    public func getInt(_ key: String, _ fallback: Int, _ min: Int, _ max: Int) -> Int {
        guard let v = Int(get(key, "")) else { return fallback }
        return Swift.max(min, Swift.min(max, v))
    }
    public func getBool(_ key: String, _ fallback: Bool) -> Bool {
        let v = get(key, "")
        if v == "1" || v.lowercased() == "true" { return true }
        if v == "0" || v.lowercased() == "false" { return false }
        return fallback
    }
    public func set(_ key: String, _ value: String) {
        precondition(!key.contains("=") && !key.contains("\n") && !key.contains("\r"), "Ungültiger Schlüssel.")
        lock.lock(); values[key.lowercased()] = value; display[key.lowercased()] = key; lock.unlock()
    }
    public func setBool(_ key: String, _ v: Bool) { set(key, v ? "1" : "0") }
    public func setInt(_ key: String, _ v: Int) { set(key, String(v)) }
    public func remove(_ key: String) { lock.lock(); values.removeValue(forKey: key.lowercased()); display.removeValue(forKey: key.lowercased()); lock.unlock() }
    public var keys: [String] { lock.lock(); defer { lock.unlock() }; return values.keys.map { display[$0] ?? $0 } }
    public func save() throws {
        lock.lock()
        var b = "# VYRA Einstellungen\n"
        for k in values.keys.sorted() { b += (display[k] ?? k) + "=" + Settings.escape(values[k] ?? "") + "\n" }
        lock.unlock()
        try FS.writeAtomic(path, text: b)
    }
    public func trySave() { try? save() }
    static func escape(_ s: String) -> String { s.rep("\\", "\\\\").rep("\r", "\\r").rep("\n", "\\n") }
    static func unescape(_ s: String) -> String {
        var b = ""
        let it = Array(s)
        var i = 0
        while i < it.count {
            if it[i] == "\\", i + 1 < it.count { i += 1; let n = it[i]; b.append(n == "n" ? "\n" : n == "r" ? "\r" : n) } else { b.append(it[i]) }
            i += 1
        }
        return b
    }
}
