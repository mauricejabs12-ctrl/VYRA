import Foundation

/// ZIP lesen und schreiben (ersetzt System.IO.Compression und den 7-Zip-Helfer unter Windows):
/// gespeicherte und Deflate-Eintraege, ZIP64, UTF-8- und DOS-Namen (Codepage 850 wie 7-Zip),
/// klassische ZIP-Verschluesselung (ZipCrypto) und WinZip-AES (AES-128/192/256) beim Lesen.
public final class ZipEntry {
    public var name = ""
    public var method: UInt16 = 0
    public var flags: UInt16 = 0
    public var crc: UInt32 = 0
    public var compressedSize: Int64 = 0
    public var size: Int64 = 0
    public var localOffset: Int64 = 0
    public var externalAttributes: UInt32 = 0
    public var modified = Date()
    var aesStrength = 0
    var aesMethod: UInt16 = 0
    public var isDirectory: Bool { name.hasSuffix("/") }
    public var isSymlink: Bool { ((externalAttributes >> 16) & 0xF000) == 0xA000 }
    public var encrypted: Bool { flags & 1 != 0 }
}

public final class ZipReader {
    public let path: String
    public private(set) var entries: [ZipEntry] = []
    let fh: FileHandle
    let fileSize: Int64
    public var password: String?

    public init(_ path: String, password: String? = nil) throws {
        self.path = path
        self.password = password
        guard let h = FileHandle(forReadingAtPath: path) else { throw VyraError("Archiv nicht lesbar: \(FS.fileName(path))", .io) }
        fh = h
        fileSize = FS.size(path)
        try readDirectory()
    }
    deinit { try? fh.close() }

    func read(_ offset: Int64, _ count: Int) throws -> [UInt8] {
        if offset < 0 || offset > fileSize { throw VyraError("Das ZIP-Archiv ist beschädigt.", .invalidData) }
        try fh.seek(toOffset: UInt64(offset))
        let d = fh.readData(ofLength: count)
        return [UInt8](d)
    }
    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 { o + 1 < b.count ? UInt16(b[o]) | UInt16(b[o + 1]) << 8 : 0 }
    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 { o + 3 < b.count ? UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 : 0 }
    static func u64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(b, o)) | UInt64(u32(b, o + 4)) << 32 }

    func readDirectory() throws {
        // Ende des zentralen Verzeichnisses suchen (max. 64 KB Kommentar).
        let tailLen = Int(min(fileSize, 65_557))
        let tail = try read(fileSize - Int64(tailLen), tailLen)
        var eocd = -1
        var i = tail.count - 22
        while i >= 0 { if tail[i] == 0x50 && tail[i + 1] == 0x4B && tail[i + 2] == 0x05 && tail[i + 3] == 0x06 { eocd = i; break }; i -= 1 }
        if eocd < 0 { throw VyraError("Die Datei ist kein gültiges ZIP-Archiv.", .invalidData) }
        var count = Int64(ZipReader.u16(tail, eocd + 10))
        var cdSize = Int64(ZipReader.u32(tail, eocd + 12))
        var cdOffset = Int64(ZipReader.u32(tail, eocd + 16))
        // ZIP64
        if eocd >= 20 && ZipReader.u32(tail, eocd - 20) == 0x07064B50 {
            let z64 = Int64(ZipReader.u64(tail, eocd - 20 + 8))
            let rec = try read(z64, 56)
            if ZipReader.u32(rec, 0) == 0x06064B50 {
                count = Int64(ZipReader.u64(rec, 32)); cdSize = Int64(ZipReader.u64(rec, 40)); cdOffset = Int64(ZipReader.u64(rec, 48))
            }
        }
        if count > Int64(ArchiveTools.maxEntries) { throw VyraError("ZIP hat mehr als 200000 Einträge.", .invalidData) }
        if cdOffset < 0 || cdSize < 0 || cdOffset + cdSize > fileSize || cdSize > 512 * 1_048_576 { throw VyraError("Das ZIP-Verzeichnis ist beschädigt.", .invalidData) }
        let cd = try read(cdOffset, Int(cdSize))
        var p = 0
        var list = [ZipEntry]()
        while p + 46 <= cd.count && ZipReader.u32(cd, p) == 0x02014B50 {
            let e = ZipEntry()
            e.flags = ZipReader.u16(cd, p + 8)
            e.method = ZipReader.u16(cd, p + 10)
            let dosTime = ZipReader.u16(cd, p + 12), dosDate = ZipReader.u16(cd, p + 14)
            e.crc = ZipReader.u32(cd, p + 16)
            e.compressedSize = Int64(ZipReader.u32(cd, p + 20))
            e.size = Int64(ZipReader.u32(cd, p + 24))
            let nameLen = Int(ZipReader.u16(cd, p + 28)), extraLen = Int(ZipReader.u16(cd, p + 30)), commentLen = Int(ZipReader.u16(cd, p + 32))
            e.externalAttributes = ZipReader.u32(cd, p + 38)
            e.localOffset = Int64(ZipReader.u32(cd, p + 42))
            if p + 46 + nameLen + extraLen > cd.count { break }
            let nameBytes = Array(cd[(p + 46)..<(p + 46 + nameLen)])
            e.name = (e.flags & 0x800 != 0) ? String(decoding: nameBytes, as: UTF8.self) : ZipReader.dosName(nameBytes)
            e.name = e.name.rep("\\", "/")
            var x = p + 46 + nameLen
            let xe = x + extraLen
            while x + 4 <= xe {
                let id = ZipReader.u16(cd, x), len = Int(ZipReader.u16(cd, x + 2))
                var q = x + 4
                if id == 0x0001 { // ZIP64
                    if e.size == 0xFFFFFFFF && q + 8 <= x + 4 + len { e.size = Int64(ZipReader.u64(cd, q)); q += 8 }
                    if e.compressedSize == 0xFFFFFFFF && q + 8 <= x + 4 + len { e.compressedSize = Int64(ZipReader.u64(cd, q)); q += 8 }
                    if e.localOffset == 0xFFFFFFFF && q + 8 <= x + 4 + len { e.localOffset = Int64(ZipReader.u64(cd, q)); q += 8 }
                } else if id == 0x9901 && len >= 7 { // WinZip AES
                    e.aesStrength = Int(cd[x + 4 + 4]); e.aesMethod = ZipReader.u16(cd, x + 4 + 5)
                } else if id == 0x7075 && len >= 5 { // Info-ZIP Unicode-Pfad
                    let n = Array(cd[(x + 9)..<(x + 4 + len)])
                    e.name = String(decoding: n, as: UTF8.self).rep("\\", "/")
                }
                x += 4 + len
            }
            e.modified = ZipReader.dosDate(dosDate, dosTime)
            list.append(e)
            p += 46 + nameLen + extraLen + commentLen
        }
        entries = list
    }
    /// Namen ohne UTF-8-Kennzeichen: Codepage 850 (DOS) wie 7-Zip; sind die Bytes gueltiges UTF-8, wird UTF-8 genommen.
    static func dosName(_ b: [UInt8]) -> String {
        if b.allSatisfy({ $0 < 0x80 }) { return String(decoding: b, as: UTF8.self) }
        if let s = String(bytes: b, encoding: .utf8) { return s }
        var out = String.UnicodeScalarView()
        for c in b { out.append(c < 0x80 ? Unicode.Scalar(c) : (Unicode.Scalar(TextCodec.cp850High[Int(c) - 0x80]) ?? "?")) }
        return String(out)
    }
    static func dosDate(_ d: UInt16, _ t: UInt16) -> Date {
        var c = DateComponents()
        c.year = Int(d >> 9) + 1980; c.month = max(1, Int((d >> 5) & 0xF)); c.day = max(1, Int(d & 0x1F))
        c.hour = Int(t >> 11); c.minute = Int((t >> 5) & 0x3F); c.second = Int(t & 0x1F) * 2
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }
    public func entry(_ name: String) -> ZipEntry? {
        entries.first { $0.name == name } ?? entries.first { $0.name.lowercased() == name.lowercased() }
    }
    /// Liest den Inhalt eines Eintrags (mit Groessengrenze und CRC-Pruefung).
    public func data(_ e: ZipEntry, limit: Int64 = 512 * 1_048_576) throws -> Data {
        if e.size > limit { throw VyraError("Eintrag zu groß: \(e.name)", .invalidData) }
        let lh = try read(e.localOffset, 30)
        if ZipReader.u32(lh, 0) != 0x04034B50 { throw VyraError("Das ZIP-Archiv ist beschädigt (\(e.name)).", .invalidData) }
        let start = e.localOffset + 30 + Int64(ZipReader.u16(lh, 26)) + Int64(ZipReader.u16(lh, 28))
        if e.compressedSize > 2_147_483_000 { throw VyraError("Eintrag zu groß: \(e.name)", .invalidData) }
        var raw = Data(try read(start, Int(e.compressedSize)))
        var method = e.method
        if e.encrypted {
            guard let pw = password, !pw.isEmpty else { throw VyraError("Das Archiv ist verschlüsselt. Bitte das Passwort angeben.", .invalidData) }
            if e.method == 99 {
                raw = try ZipCrypto.decryptAES(raw, pw, e.aesStrength)
                method = e.aesMethod
            } else {
                raw = try ZipCrypto.decryptTraditional(raw, pw, check: (e.flags & 8 != 0) ? UInt8((ZipReader.u16(lh, 10) >> 8) & 0xFF) : UInt8(e.crc >> 24))
            }
        }
        var out: Data
        switch method {
        case 0: out = raw
        case 8: out = try Zlib.inflate(raw, .raw, limit: Int(min(limit, Int64(Int32.max))))
        default: throw VyraError("Komprimierungsverfahren \(method) wird nicht unterstützt (\(e.name)).", .notSupported)
        }
        if Int64(out.count) != e.size { throw VyraError("ZIP-Größenangabe stimmt nicht (\(e.name)).", .invalidData) }
        if e.method != 99 || e.aesMethod == 0 || true {
            // AE-2 speichert keine CRC; dann 0
            if e.crc != 0 && Zlib.crc32(out) != e.crc { throw VyraError(e.encrypted ? "Falsches Passwort oder beschädigte Datei (\(e.name))." : "Prüfsumme stimmt nicht (\(e.name)).", .invalidData) }
        }
        return out
    }
    public func text(_ name: String) throws -> String? {
        guard let e = entry(name) else { return nil }
        return TextCodec.decodeText(try data(e, limit: 60_000_000))
    }
}

/// ZIP schreiben (Deflate, UTF-8-Namen, ZIP64 bei Bedarf).
public final class ZipWriter {
    let out: FileHandle
    let path: String
    var offset: Int64 = 0
    var central = Data()
    var count = 0
    var names = Set<String>()
    public init(_ path: String) throws {
        self.path = path
        try FS.mkdir(FS.dirName(path))
        FS.delete(path)
        guard FS.fm.createFile(atPath: path, contents: nil), let h = FileHandle(forWritingAtPath: path) else { throw VyraError("Datei nicht beschreibbar: \(FS.fileName(path))", .io) }
        out = h
    }
    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
    static func le64(_ v: UInt64) -> [UInt8] { le32(UInt32(v & 0xFFFFFFFF)) + le32(UInt32(v >> 32)) }
    static func dos(_ d: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        let date = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        return (time, date)
    }
    public func add(_ name0: String, _ data: Data, compress: Bool = true, modified: Date = Date()) throws {
        let name = name0.rep("\\", "/")
        if names.contains(name.lowercased()) { throw VyraError("Doppelter ZIP-Pfad: \(name)", .invalidData) }
        names.insert(name.lowercased())
        let crc = Zlib.crc32(data)
        var payload = data
        var method: UInt16 = 0
        if compress && data.count > 64, let d = try? Zlib.deflate(data, .raw, level: 6), d.count < data.count { payload = d; method = 8 }
        let nameBytes = Array(name.utf8)
        let (t, d) = ZipWriter.dos(modified)
        let big = Int64(data.count) >= 0xFFFFFFFF || Int64(payload.count) >= 0xFFFFFFFF || offset >= 0xFFFFFFFF
        var local = [UInt8]()
        local += ZipWriter.le32(0x04034B50) + ZipWriter.le16(big ? 45 : 20) + ZipWriter.le16(0x800) + ZipWriter.le16(method) + ZipWriter.le16(t) + ZipWriter.le16(d) + ZipWriter.le32(crc)
        var extra = [UInt8]()
        if big {
            local += ZipWriter.le32(0xFFFFFFFF) + ZipWriter.le32(0xFFFFFFFF)
            extra = ZipWriter.le16(1) + ZipWriter.le16(16) + ZipWriter.le64(UInt64(data.count)) + ZipWriter.le64(UInt64(payload.count))
        } else {
            local += ZipWriter.le32(UInt32(payload.count)) + ZipWriter.le32(UInt32(data.count))
        }
        local += ZipWriter.le16(UInt16(nameBytes.count)) + ZipWriter.le16(UInt16(extra.count)) + nameBytes + extra
        let localOffset = offset
        out.write(Data(local)); out.write(payload)
        offset += Int64(local.count + payload.count)
        var cd = [UInt8]()
        cd += ZipWriter.le32(0x02014B50) + ZipWriter.le16(0x031E) + ZipWriter.le16(big ? 45 : 20) + ZipWriter.le16(0x800) + ZipWriter.le16(method) + ZipWriter.le16(t) + ZipWriter.le16(d) + ZipWriter.le32(crc)
        var cdExtra = [UInt8]()
        if big {
            cd += ZipWriter.le32(0xFFFFFFFF) + ZipWriter.le32(0xFFFFFFFF)
            cdExtra = ZipWriter.le16(1) + ZipWriter.le16(24) + ZipWriter.le64(UInt64(data.count)) + ZipWriter.le64(UInt64(payload.count)) + ZipWriter.le64(UInt64(localOffset))
        } else {
            cd += ZipWriter.le32(UInt32(payload.count)) + ZipWriter.le32(UInt32(data.count))
        }
        let attrs: UInt32 = name.hasSuffix("/") ? (0o40755 << 16) | 0x10 : (0o100644 << 16)
        cd += ZipWriter.le16(UInt16(nameBytes.count)) + ZipWriter.le16(UInt16(cdExtra.count)) + ZipWriter.le16(0) + ZipWriter.le16(0) + ZipWriter.le16(0) + ZipWriter.le32(attrs)
        cd += ZipWriter.le32(big ? 0xFFFFFFFF : UInt32(localOffset)) + nameBytes + cdExtra
        central.append(contentsOf: cd)
        count += 1
    }
    public func add(_ name: String, text: String) throws { try add(name, Data(text.utf8)) }
    public func addFile(_ name: String, _ file: String) throws { try add(name, try FS.read(file), modified: FS.modified(file)) }
    public func close() throws {
        let cdOffset = offset
        out.write(central)
        offset += Int64(central.count)
        var tail = [UInt8]()
        let needs64 = count >= 0xFFFF || cdOffset >= 0xFFFFFFFF || central.count >= 0xFFFFFFFF
        if needs64 {
            let z64 = offset
            tail += ZipWriter.le32(0x06064B50) + ZipWriter.le64(44) + ZipWriter.le16(45) + ZipWriter.le16(45) + ZipWriter.le32(0) + ZipWriter.le32(0)
            tail += ZipWriter.le64(UInt64(count)) + ZipWriter.le64(UInt64(count)) + ZipWriter.le64(UInt64(central.count)) + ZipWriter.le64(UInt64(cdOffset))
            tail += ZipWriter.le32(0x07064B50) + ZipWriter.le32(0) + ZipWriter.le64(UInt64(z64)) + ZipWriter.le32(1)
        }
        tail += ZipWriter.le32(0x06054B50) + ZipWriter.le16(0) + ZipWriter.le16(0)
        tail += ZipWriter.le16(UInt16(min(count, 0xFFFF))) + ZipWriter.le16(UInt16(min(count, 0xFFFF)))
        tail += ZipWriter.le32(UInt32(min(Int64(central.count), 0xFFFFFFFF))) + ZipWriter.le32(UInt32(min(cdOffset, 0xFFFFFFFF))) + ZipWriter.le16(0)
        out.write(Data(tail))
        try out.close()
    }
}

/// ZIP-Verschluesselung beim Lesen: klassisch (PKWARE) und WinZip-AES.
public enum ZipCrypto {
    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    public static func decryptTraditional(_ data: Data, _ password: String, check: UInt8) throws -> Data {
        var k0: UInt32 = 0x12345678, k1: UInt32 = 0x23456789, k2: UInt32 = 0x34567890
        func update(_ c: UInt8) {
            k0 = crcTable[Int((k0 ^ UInt32(c)) & 0xFF)] ^ (k0 >> 8)
            k1 = (k1 &+ (k0 & 0xFF)) &* 134775813 &+ 1
            k2 = crcTable[Int((k2 ^ (k1 >> 24)) & 0xFF)] ^ (k2 >> 8)
        }
        func decrypt(_ c: UInt8) -> UInt8 { let t = UInt16(k2 | 2); let p = c ^ UInt8((t &* (t ^ 1)) >> 8 & 0xFF); update(p); return p }
        for b in Array(password.utf8) { update(b) }
        let bytes = [UInt8](data)
        if bytes.count < 12 { throw VyraError("Verschlüsselter Eintrag ist beschädigt.", .invalidData) }
        var header = [UInt8]()
        for i in 0..<12 { header.append(decrypt(bytes[i])) }
        if header[11] != check { throw VyraError("Falsches Passwort.", .invalidData) }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count - 12)
        for i in 12..<bytes.count { out.append(decrypt(bytes[i])) }
        return Data(out)
    }
    /// WinZip-AES (AE-1/AE-2): PBKDF2-HMAC-SHA1 (1000 Runden), AES-CTR (Little-Endian-Zaehler), HMAC-SHA1-Pruefung.
    public static func decryptAES(_ data: Data, _ password: String, _ strength: Int) throws -> Data {
        let keyLen = strength == 1 ? 16 : strength == 2 ? 24 : 32
        let saltLen = keyLen / 2
        let b = [UInt8](data)
        if b.count < saltLen + 2 + 10 { throw VyraError("Verschlüsselter Eintrag ist beschädigt.", .invalidData) }
        let salt = Array(b[0..<saltLen])
        let verify = Array(b[saltLen..<(saltLen + 2)])
        let body = Array(b[(saltLen + 2)..<(b.count - 10)])
        let mac = Array(b[(b.count - 10)...])
        let derived = Crypto.pbkdf2SHA1(Array(password.utf8), salt, 1000, keyLen * 2 + 2)
        let aesKey = Array(derived[0..<keyLen]), macKey = Array(derived[keyLen..<(keyLen * 2)]), pv = Array(derived[(keyLen * 2)...])
        if pv != verify { throw VyraError("Falsches Passwort.", .invalidData) }
        let calc = Array(Crypto.hmacSHA1(macKey, body).prefix(10))
        if calc != mac { throw VyraError("Falsches Passwort oder beschädigte Datei.", .invalidData) }
        let aes = AES(key: aesKey)
        var out = [UInt8](repeating: 0, count: body.count)
        var counter = [UInt8](repeating: 0, count: 16)
        var i = 0
        var n: UInt64 = 1
        while i < body.count {
            for k in 0..<8 { counter[k] = UInt8((n >> (8 * UInt64(k))) & 0xFF) }
            let ks = aes.encrypt(counter)
            let m = min(16, body.count - i)
            for k in 0..<m { out[i + k] = body[i + k] ^ ks[k] }
            i += 16; n += 1
        }
        return Data(out)
    }
}
