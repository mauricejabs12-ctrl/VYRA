import Foundation
import CZlib
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Deflate/Inflate ueber zlib (auf iOS und Linux vorhanden) – fuer ZIP, DOCX/XLSX/PPTX/ODT, PDF und GZIP.
public enum Zlib {
    public enum Format { case raw, zlib, gzip, auto }
    static func windowBits(_ f: Format) -> Int32 {
        switch f { case .raw: return -15; case .zlib: return 15; case .gzip: return 15 + 16; case .auto: return 15 + 32 }
    }
    /// Entpackt; `limit` begrenzt die Ausgabe (Schutz vor Zip-Bomben). Liefert die bis zum Fehler entpackten Daten,
    /// wenn `partialOK` gesetzt ist (wie die tolerante PDF-Entpackung unter Windows).
    public static func inflate(_ input: Data, _ format: Format, limit: Int = Int(Int32.max), partialOK: Bool = false) throws -> Data {
        var stream = z_stream()
        var status = inflateInit2_(&stream, windowBits(format), ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw VyraError("zlib konnte nicht starten.", .io) }
        defer { inflateEnd(&stream) }
        var out = Data()
        let chunk = 1 << 16
        var buffer = [UInt8](repeating: 0, count: chunk)
        let src = [UInt8](input)
        if src.isEmpty { return out }
        try src.withUnsafeBufferPointer { inPtr in
            stream.next_in = UnsafeMutablePointer(mutating: inPtr.baseAddress)
            stream.avail_in = uInt(inPtr.count)
            repeat {
                status = buffer.withUnsafeMutableBufferPointer { outPtr -> Int32 in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(chunk)
                    return CZlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk - Int(stream.avail_out)
                if produced > 0 { out.append(contentsOf: buffer[0..<produced]) }
                if out.count > limit { throw VyraError("Entpackte Daten sind größer als erlaubt.", .invalidData) }
                if status == Z_STREAM_END { break }
                if status != Z_OK && status != Z_BUF_ERROR {
                    if partialOK && !out.isEmpty { return }
                    throw VyraError("Die komprimierten Daten sind beschädigt.", .invalidData)
                }
                if status == Z_BUF_ERROR && stream.avail_in == 0 {
                    if partialOK { return }
                    throw VyraError("Die komprimierten Daten sind unvollständig.", .invalidData)
                }
            } while true
        }
        return out
    }
    public static func deflate(_ input: Data, _ format: Format, level: Int32 = 6) throws -> Data {
        var stream = z_stream()
        var status = deflateInit2_(&stream, level, Z_DEFLATED, windowBits(format == .auto ? .zlib : format), 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw VyraError("zlib konnte nicht starten.", .io) }
        defer { deflateEnd(&stream) }
        var out = Data()
        let chunk = 1 << 16
        var buffer = [UInt8](repeating: 0, count: chunk)
        var src = [UInt8](input)
        if src.isEmpty { src = [] }
        src.withUnsafeMutableBufferPointer { inPtr in
            stream.next_in = inPtr.baseAddress
            stream.avail_in = uInt(inPtr.count)
            repeat {
                status = buffer.withUnsafeMutableBufferPointer { outPtr -> Int32 in
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(chunk)
                    return CZlib.deflate(&stream, Z_FINISH)
                }
                let produced = chunk - Int(stream.avail_out)
                if produced > 0 { out.append(contentsOf: buffer[0..<produced]) }
            } while status == Z_OK
        }
        guard status == Z_STREAM_END else { throw VyraError("Komprimieren fehlgeschlagen.", .io) }
        return out
    }
    public static func crc32(_ data: Data, _ start: UInt32 = 0) -> UInt32 {
        var c = uLong(start)
        data.withUnsafeBytes { p in
            if let b = p.bindMemory(to: Bytef.self).baseAddress { c = CZlib.crc32(c, b, uInt(p.count)) }
        }
        return UInt32(truncatingIfNeeded: c)
    }
}

/// SHA-256 fuer Modellpruefsummen: auf Apple-Geraeten ueber CryptoKit (schnell), sonst eine eigene, gepruefte Umsetzung.
public struct SHA256Hasher {
    #if canImport(CryptoKit)
    private var h = CryptoKit.SHA256()
    public init() {}
    public mutating func update(_ d: Data) { h.update(data: d) }
    public mutating func finalize() -> String { h.finalize().map { String(format: "%02x", $0) }.joined() }
    #else
    private var core = SHA256Core()
    public init() {}
    public mutating func update(_ d: Data) { core.update(d) }
    public mutating func finalize() -> String { core.finalize() }
    #endif
    public static func hex(_ d: Data) -> String { var s = SHA256Hasher(); s.update(d); return s.finalize() }
    public static func hex(_ s: String) -> String { hex(Data(s.utf8)) }
    /// Pruefsumme einer (auch sehr grossen) Datei in 4-MB-Bloecken; `progress` 0...1, `cancelled` fuer Abbruch.
    public static func file(_ path: String, progress: ((Double) -> Void)? = nil, cancelled: (() -> Bool)? = nil) throws -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { throw VyraError("Datei nicht lesbar: \(FS.fileName(path))", .io) }
        defer { try? fh.close() }
        let total = max(1, FS.size(path))
        var done: Int64 = 0
        var h = SHA256Hasher()
        while true {
            if cancelled?() == true { throw VyraError.cancelled }
            let d = autoreleasepool { fh.readData(ofLength: 4 << 20) }
            if d.isEmpty { break }
            h.update(d); done += Int64(d.count)
            progress?(Double(done) / Double(total))
        }
        return h.finalize()
    }
}

#if !canImport(ObjectiveC)
@inline(__always) func autoreleasepool<T>(_ body: () throws -> T) rethrows -> T { try body() }
#endif

/// Reine Swift-Umsetzung von SHA-256 (FIPS 180-4), nur verwendet, wo CryptoKit fehlt (Tests unter Linux).
public struct SHA256Core {
    static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]
    var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    var buffer = [UInt8]()
    var length: UInt64 = 0
    public init() {}
    public mutating func update(_ d: Data) {
        length += UInt64(d.count)
        var local = buffer
        local.append(contentsOf: d)
        var off = 0
        var w = [UInt32](repeating: 0, count: 64)
        var hh = h
        local.withUnsafeBufferPointer { p in
            while local.count - off >= 64 {
                SHA256Core.block(p.baseAddress! + off, &w, &hh)
                off += 64
            }
        }
        h = hh
        buffer = off > 0 ? Array(local[off...]) : local
    }
    @inline(__always) static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    static func block(_ p: UnsafePointer<UInt8>, _ w: inout [UInt32], _ h: inout [UInt32]) {
        for t in 0..<16 { w[t] = UInt32(p[t * 4]) << 24 | UInt32(p[t * 4 + 1]) << 16 | UInt32(p[t * 4 + 2]) << 8 | UInt32(p[t * 4 + 3]) }
        for t in 16..<64 {
            let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for t in 0..<64 {
            let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ S1 &+ ch &+ k[t] &+ w[t]
            let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = S0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }
    public mutating func finalize() -> String {
        let bits = length * 8
        var tail = buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for i in (0..<8).reversed() { tail.append(UInt8((bits >> (UInt64(i) * 8)) & 0xff)) }
        var w = [UInt32](repeating: 0, count: 64)
        var hh = h
        tail.withUnsafeBufferPointer { p in
            var off = 0
            while off < tail.count { SHA256Core.block(p.baseAddress! + off, &w, &hh); off += 64 }
        }
        h = hh
        return h.map { String(format: "%08x", $0) }.joined()
    }
}
