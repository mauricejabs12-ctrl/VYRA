import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Security)
import Security
#endif

/// Ersatz fuer `SecretStore` (Windows: DPAPI fuer den Windows-Benutzer).
/// iOS: API-Schluessel liegen im Schluesselbund (nur dieses Geraet, nach dem ersten Entsperren). Gedaechtnis, Notizen und
/// Lernmodule werden mit AES-GCM verschluesselt; der 256-Bit-Schluessel dafuer liegt ebenfalls im Schluesselbund.
public enum SecretStore {
    static let service = "VYRA KI"
    static let dataKeyAccount = "vyra.datakey"

    // ------------------------------------------------ Schluesselbund
    public static func get(_ account: String) -> String {
        #if canImport(Security) && !os(Linux)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data { return String(decoding: d, as: UTF8.self) }
        return ""
        #else
        return memoryStore[account] ?? ""
        #endif
    }
    @discardableResult
    public static func set(_ account: String, _ value: String) -> Bool {
        #if canImport(Security) && !os(Linux)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        if value.isEmpty { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        #else
        memoryStore[account] = value.isEmpty ? nil : value
        return true
        #endif
    }
    #if !(canImport(Security) && !os(Linux))
    nonisolated(unsafe) static var memoryStore = [String: String]()
    #endif

    // ------------------------------------------------ Datenschluessel fuer verschluesselte Dateien
    static let keyLock = NSLock()
    nonisolated(unsafe) static var cachedKey: Data?
    static func dataKey() -> Data? {
        keyLock.lock(); defer { keyLock.unlock() }
        if let k = cachedKey { return k }
        let stored = get(dataKeyAccount)
        if let d = Data(base64Encoded: stored), d.count == 32 { cachedKey = d; return d }
        var bytes = [UInt8](repeating: 0, count: 32)
        #if canImport(Security) && !os(Linux)
        if SecRandomCopyBytes(kSecRandomDefault, 32, &bytes) != errSecSuccess { return nil }
        #else
        for i in 0..<32 { bytes[i] = UInt8.random(in: 0...255) }
        #endif
        let d = Data(bytes)
        if !set(dataKeyAccount, d.base64EncodedString()) { return nil }
        cachedKey = d
        return d
    }
    /// Verschluesselt Text (AES-GCM, Base64 mit Praefix "v1:"). nil = nicht moeglich (z. B. Schluesselbund gesperrt).
    public static func protect(_ plain: String) -> String? {
        #if canImport(CryptoKit)
        guard let k = dataKey() else { return nil }
        guard let box = try? CryptoKit.AES.GCM.seal(Data(plain.utf8), using: SymmetricKey(data: k)), let c = box.combined else { return nil }
        return "v1:" + c.base64EncodedString()
        #else
        // Nur fuer die Linux-Tests des Kerns (kein CryptoKit): keine echte Verschluesselung.
        return "t0:" + Data(plain.utf8).base64EncodedString()
        #endif
    }
    public static func unprotect(_ cipher: String) -> String? {
        #if canImport(CryptoKit)
        guard cipher.hasPrefix("v1:"), let k = dataKey(), let c = Data(base64Encoded: String(cipher.dropFirst(3))),
              let box = try? CryptoKit.AES.GCM.SealedBox(combined: c), let p = try? CryptoKit.AES.GCM.open(box, using: SymmetricKey(data: k)) else { return nil }
        return String(decoding: p, as: UTF8.self)
        #else
        guard cipher.hasPrefix("t0:"), let d = Data(base64Encoded: String(cipher.dropFirst(3))) else { return nil }
        return String(decoding: d, as: UTF8.self)
        #endif
    }
}
