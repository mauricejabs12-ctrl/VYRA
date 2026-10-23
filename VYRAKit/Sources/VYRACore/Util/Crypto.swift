import Foundation

/// Kleine, gepruefte Krypto-Bausteine fuer verschluesselte ZIP-Archive (WinZip-AES): SHA-1, HMAC-SHA1, PBKDF2, AES.
/// (Unter Windows uebernimmt das 7-Zip; auf dem iPhone gibt es kein 7-Zip.)
public enum Crypto {
    public static func sha1(_ msg: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x67452301, h1: UInt32 = 0xEFCDAB89, h2: UInt32 = 0x98BADCFE, h3: UInt32 = 0x10325476, h4: UInt32 = 0xC3D2E1F0
        var m = msg
        let ml = UInt64(msg.count) * 8
        m.append(0x80)
        while m.count % 64 != 56 { m.append(0) }
        for i in (0..<8).reversed() { m.append(UInt8((ml >> (UInt64(i) * 8)) & 0xFF)) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: m.count, by: 64) {
            for t in 0..<16 { w[t] = UInt32(m[chunk + t * 4]) << 24 | UInt32(m[chunk + t * 4 + 1]) << 16 | UInt32(m[chunk + t * 4 + 2]) << 8 | UInt32(m[chunk + t * 4 + 3]) }
            for t in 16..<80 { let x = w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16]; w[t] = (x << 1) | (x >> 31) }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for t in 0..<80 {
                let f: UInt32, k: UInt32
                switch t {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let tmp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[t]
                e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = tmp
            }
            h0 &+= a; h1 &+= b; h2 &+= c; h3 &+= d; h4 &+= e
        }
        var out = [UInt8]()
        for h in [h0, h1, h2, h3, h4] { out += [UInt8(h >> 24), UInt8((h >> 16) & 0xFF), UInt8((h >> 8) & 0xFF), UInt8(h & 0xFF)] }
        return out
    }
    public static func hmacSHA1(_ key0: [UInt8], _ msg: [UInt8]) -> [UInt8] {
        var key = key0.count > 64 ? sha1(key0) : key0
        key += [UInt8](repeating: 0, count: 64 - key.count)
        let ipad = key.map { $0 ^ 0x36 }, opad = key.map { $0 ^ 0x5C }
        return sha1(opad + sha1(ipad + msg))
    }
    public static func pbkdf2SHA1(_ password: [UInt8], _ salt: [UInt8], _ rounds: Int, _ length: Int) -> [UInt8] {
        var out = [UInt8]()
        var block: UInt32 = 1
        while out.count < length {
            var u = hmacSHA1(password, salt + [UInt8(block >> 24), UInt8((block >> 16) & 0xFF), UInt8((block >> 8) & 0xFF), UInt8(block & 0xFF)])
            var t = u
            if rounds > 1 { for _ in 1..<rounds { u = hmacSHA1(password, u); for i in 0..<t.count { t[i] ^= u[i] } } }
            out += t
            block += 1
        }
        return Array(out.prefix(length))
    }
}

/// AES-Verschluesselung eines 16-Byte-Blocks (FIPS-197), Schluessel 128/192/256 Bit. Fuer CTR reicht die Verschluesselungsrichtung.
public final class AES {
    static let sbox: [UInt8] = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76, 0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15, 0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84, 0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8, 0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73, 0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79, 0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a, 0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf, 0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16]
    let rounds: Int
    var w: [UInt8]
    public init(key: [UInt8]) {
        let nk = key.count / 4
        rounds = nk + 6
        let total = 16 * (rounds + 1)
        w = key + [UInt8](repeating: 0, count: total - key.count)
        var rcon: UInt8 = 1
        var i = nk
        while i * 4 < total {
            var t = Array(w[(i - 1) * 4..<i * 4])
            if i % nk == 0 {
                t = [AES.sbox[Int(t[1])] ^ rcon, AES.sbox[Int(t[2])], AES.sbox[Int(t[3])], AES.sbox[Int(t[0])]]
                rcon = AES.xtime(rcon)
            } else if nk > 6 && i % nk == 4 {
                t = t.map { AES.sbox[Int($0)] }
            }
            for k in 0..<4 { w[i * 4 + k] = w[(i - nk) * 4 + k] ^ t[k] }
            i += 1
        }
    }
    static func xtime(_ x: UInt8) -> UInt8 { (x << 1) ^ ((x & 0x80) != 0 ? 0x1B : 0) }
    public func encrypt(_ input: [UInt8]) -> [UInt8] {
        var s = input
        for k in 0..<16 { s[k] ^= w[k] }
        for r in 1...rounds {
            for k in 0..<16 { s[k] = AES.sbox[Int(s[k])] }
            // ShiftRows
            var t = s
            for c in 0..<4 { for row in 0..<4 { t[c * 4 + row] = s[((c + row) % 4) * 4 + row] } }
            s = t
            if r != rounds {
                for c in 0..<4 {
                    let a0 = s[c * 4], a1 = s[c * 4 + 1], a2 = s[c * 4 + 2], a3 = s[c * 4 + 3]
                    let all = a0 ^ a1 ^ a2 ^ a3
                    s[c * 4] ^= all ^ AES.xtime(a0 ^ a1)
                    s[c * 4 + 1] ^= all ^ AES.xtime(a1 ^ a2)
                    s[c * 4 + 2] ^= all ^ AES.xtime(a2 ^ a3)
                    s[c * 4 + 3] ^= all ^ AES.xtime(a3 ^ a0)
                }
            }
            for k in 0..<16 { s[k] ^= w[r * 16 + k] }
        }
        return s
    }
}
