import Foundation

/// 16-Bit-Mono-Audio eines gesprochenen Satzes mit Huellkurve fuer die Kugel (aus `PcmClip`).
public final class PcmClip {
    public var samples = [Int16]()
    public var rate = 22050
    public var env = [Float]()
    public var text = ""
    public init() {}
}

/// Klangbearbeitung fuer eine angenehme, weiche Stimme (aus `SoftVoice`): sanfter Tiefpass gegen scharfe S-Laute,
/// gleichmaessige Lautstaerke, weiches Ein- und Ausblenden. Liefert ausserdem die Huellkurve fuer die Kugel.
public enum SoftVoice {
    public static func process(_ pcm: [Int16], _ rate: Int, _ softness: Double) -> PcmClip {
        let n = pcm.count
        var outp = [Int16](repeating: 0, count: n)
        let c = PcmClip(); c.rate = rate
        if n == 0 { c.samples = outp; return c }
        let cutoff: Double = rate >= 22000 ? 6800 : 5600
        let dt = 1.0 / Double(rate), rc = 1.0 / (2 * Double.pi * cutoff), alpha = dt / (rc + dt)
        var x = [Double](repeating: 0, count: n)
        var y = 0.0
        for i in 0..<n { let v = Double(pcm[i]) / 32768.0; y += alpha * (v - y); x[i] = v * (1 - softness) + y * softness }
        // Lautheit angleichen (Ziel-RMS), Spitzen weich begrenzen.
        var sum = 0.0
        for v in x { sum += v * v }
        let rms = (sum / Double(n)).squareRoot()
        let gain = rms > 1e-4 ? min(4.0, 0.11 / rms) : 1.0
        let fadeIn = min(n / 4, rate * 8 / 1000), fadeOut = min(n / 4, rate * 30 / 1000)
        for i in 0..<n {
            var v = x[i] * gain
            v = tanh(v * 1.15) / 1.15
            if i < fadeIn { v *= Double(i) / Double(fadeIn) }
            if i > n - fadeOut { v *= Double(n - i) / Double(fadeOut) }
            let s = Int((v * 32767 * 0.92).rounded(.toNearestOrEven))
            outp[i] = Int16(max(-32768, min(32767, s)))
        }
        c.samples = outp; c.env = envelope(outp, rate)
        return c
    }
    /// Pegel je 20 ms, 0..1, leicht komprimiert, damit die Kugel natuerlich mitschwingt.
    public static func envelope(_ pcm: [Int16], _ rate: Int) -> [Float] {
        let win = max(1, rate / 50)
        let frames = (pcm.count + win - 1) / win
        var env = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var s = 0.0
            let a = f * win, b = min(pcm.count, a + win)
            for i in a..<b { let v = Double(pcm[i]) / 32768.0; s += v * v }
            let r = (s / Double(max(1, b - a))).squareRoot()
            env[f] = Float(min(1, pow(r * 4.2, 0.7)))
        }
        return env
    }
    /// WAV (PCM 8/16 Bit, mono/stereo) lesen und in 16 Bit mono umwandeln.
    public static func readWav(_ wav: [UInt8], _ rate: inout Int) throws -> [Int16] {
        rate = 22050
        func ascii(_ o: Int) -> String { String(decoding: wav[o..<o + 4], as: UTF8.self) }
        func i32(_ o: Int) -> Int { Int(Int32(bitPattern: UInt32(wav[o]) | UInt32(wav[o + 1]) << 8 | UInt32(wav[o + 2]) << 16 | UInt32(wav[o + 3]) << 24)) }
        func i16(_ d: [UInt8], _ o: Int) -> Int { Int(Int16(bitPattern: UInt16(d[o]) | UInt16(d[o + 1]) << 8)) }
        if wav.count < 44 || ascii(0) != "RIFF" || ascii(8) != "WAVE" { throw VyraError("Keine WAV-Daten.", .invalidData) }
        var pos = 12, channels = 1, bits = 16
        var data: [UInt8]?
        while pos + 8 <= wav.count {
            let id = ascii(pos)
            var size = i32(pos + 4)
            let body = pos + 8
            if size < 0 || body + size > wav.count { size = wav.count - body }
            if id == "fmt " {
                let fmt = i16(wav, body)
                channels = max(1, i16(wav, body + 2)); rate = i32(body + 4); bits = i16(wav, body + 14)
                if fmt != 1 && fmt != -2 { throw VyraError("Nur PCM-WAV wird unterstützt.", .invalidData) }
            } else if id == "data" { data = Array(wav[body..<body + size]); break }
            pos = body + size + (size & 1)
        }
        guard let d = data else { throw VyraError("WAV ohne Audiodaten.", .invalidData) }
        let bytesPer = bits / 8
        let frames = d.count / (bytesPer * channels)
        var outp = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            var acc = 0
            for c in 0..<channels { let o = (i * channels + c) * bytesPer; acc += bits == 16 ? i16(d, o) : (Int(d[o]) - 128) << 8 }
            outp[i] = Int16(acc / channels)
        }
        return outp
    }
    /// Text fuer das Vorlesen: Abkuerzungen ausschreiben, Symbole und Markdown entfernen.
    public static func speakable(_ text: String?) -> String {
        var s = text ?? ""
        s = Rx.replace(s, "[\\u2600-\\u27bf]|[\\x{1F000}-\\x{1FFFF}]|[\\ufe0f\\u200d]", " ")
        s = s.rep("**", "").rep("__", "").rep("`", "").rep("#", "").rep("|", " ").rep("\u{2192}", " ").rep("=>", " ").rep("->", " ")
        let ab: [(String, String)] = [("z. B.", "zum Beispiel"), ("z.B.", "zum Beispiel"), ("d. h.", "das heißt"), ("d.h.", "das heißt"), ("u. a.", "unter anderem"), ("usw.", "und so weiter"), ("bzw.", "beziehungsweise"), ("ca.", "circa"), ("inkl.", "inklusive"), ("ggf.", "gegebenenfalls"), ("evtl.", "eventuell"), ("vgl.", "vergleiche"), ("Nr.", "Nummer"), ("Std.", "Stunden"), ("Min.", "Minuten"), ("Sek.", "Sekunden"), ("max.", "maximal"), ("min.", "mindestens"), ("etc.", "et cetera"), ("&", " und "), ("€", " Euro"), ("%", " Prozent"), ("°C", " Grad Celsius"), ("°", " Grad"), ("·", ", "), ("…", ".")]
        for (a, b) in ab { s = s.rep(a, b) }
        s = Rx.replace(s, #"\b(\d+(?:[.,]\d+)?)\s?(GB|GiB)\b"#, "$1 Gigabyte"); s = Rx.replace(s, #"\b(\d+(?:[.,]\d+)?)\s?(MB|MiB)\b"#, "$1 Megabyte")
        s = Rx.replace(s, #"\b(\d+)\s?ms\b"#, "$1 Millisekunden"); s = Rx.replace(s, #"\b(\d+)\s?Hz\b"#, "$1 Hertz")
        s = Rx.replace(s, #"\bFPS\b"#, "F P S"); s = Rx.replace(s, #"\bKI\b"#, "K I"); s = Rx.replace(s, #"\bVYRA\b"#, "Wira")
        s = Rx.replace(s, #"\[(\d{1,2})\]"#, "")
        s = Rx.replace(s, #"\s+"#, " ")
        return s.trimmed
    }
    public static func sentences(_ plain: String?) -> [String] {
        var l = [String]()
        guard let plain = plain, !plain.trimmed.isEmpty else { return l }
        for part in Rx.split(plain, #"(?<=[.!?:;])\s+(?=[A-ZÄÖÜ0-9„"])"#) {
            var p = part.trimmed
            if p.isEmpty { continue }
            // Sehr lange Saetze an Kommas teilen, damit die Stimme frueher beginnt.
            while p.len > 240 {
                var c = p.lastIndexOf(", ", start: 220, count: 221)
                if c < 60 { c = p.lastIndexOf(" ", start: 220, count: 221) }
                if c < 40 { break }
                l.append(p.sub(0, c + 1).trimmed); p = p.sub(c + 1).trimmed
            }
            if !p.isEmpty { l.append(p) }
        }
        return l
    }
}

/// Text, den der Sprachmodus vorliest (aus `SpeechSession.SpokenText`).
public enum SpeechText {
    public static func spokenText(_ text: String?) -> String {
        var s = Rx.replace(text ?? "", #"```[\s\S]*?(?:```|$)"#, " Der Code steht im Chat. ")
        s = Rx.replace(s, #"https?://\S+"#, " Link im Chat. ")
        s = MdBlocks.plain(s)
        return s.len > 3200 ? s.sub(0, 3200) + " Den Rest findest du im Chat." : s
    }
}

/// Steuert das Vorlesen (aus `VoiceOut`): Text – auch waehrend er noch entsteht – in Saetze teilen und der Reihe nach
/// an die Stimme geben. Die eigentliche Sprachausgabe (iOS: AVSpeechSynthesizer) haengt an `onSentence`/`onStop`.
public final class VoiceFeeder {
    let lock = NSLock()
    var fed = 0
    var streaming = false
    var spokenChars = 0
    public private(set) var generation = 0
    public var maxChars = 1600
    /// Satz zum Sprechen (mit der Generation; aeltere Generationen verwerfen).
    public var onSentence: ((String, Int) -> Void)?
    public var onStop: (() -> Void)?
    public init() {}
    public var isStreaming: Bool { lock.lock(); defer { lock.unlock() }; return streaming }
    func push(_ plain: String) {
        for s in SoftVoice.sentences(plain) {
            lock.lock()
            if spokenChars >= maxChars { lock.unlock(); return }
            if spokenChars + s.len > maxChars {
                spokenChars = maxChars
                let g = generation
                lock.unlock()
                onSentence?("Den Rest findest du im Chat.", g)
                return
            }
            spokenChars += s.len
            let g = generation
            lock.unlock()
            onSentence?(s, g)
        }
    }
    public func stop() {
        lock.lock(); generation += 1; streaming = false; fed = 0; spokenChars = 0; lock.unlock()
        onStop?()
    }
    public func speak(_ markdown: String) { stop(); push(SoftVoice.speakable(SpeechText.spokenText(markdown))) }
    public func speakPlain(_ text: String) { stop(); push(SoftVoice.speakable(text)) }
    /// Waehrend die KI schreibt: fertige Saetze sofort sprechen.
    public func beginStream() { stop(); lock.lock(); streaming = true; fed = 0; lock.unlock() }
    public func feed(_ markdown: String?) {
        let md = Array((markdown ?? "").utf16)
        lock.lock()
        if !streaming { lock.unlock(); return }
        let start = fed
        lock.unlock()
        if md.count <= start { return }
        let mdStr = markdown ?? ""
        var fences = 0
        var p = 0
        while true { p = mdStr.indexOf("```", from: p); if p < 0 { break }; fences += 1; p += 3 }
        var limit = md.count
        if fences % 2 == 1 { limit = mdStr.lastIndexOf("```") }
        var end = -1
        var i = limit - 1
        let enders: Set<UInt16> = [46, 33, 63, 58]
        while i > start {
            let c = md[i]
            if c == 10 && i > 0 && md[i - 1] == 10 { end = i; break }
            if (c == 32 || c == 10) && i > 0 && enders.contains(md[i - 1]) && !VoiceFeeder.abbrev(md, i - 1) { end = i; break }
            i -= 1
        }
        if end <= start { return }
        let piece = String(utf16CodeUnits: Array(md[start..<end]), count: end - start)
        lock.lock(); fed = end; lock.unlock()
        push(SoftVoice.speakable(SpeechText.spokenText(piece)))
    }
    static func abbrev(_ s: [UInt16], _ dot: Int) -> Bool {
        if s[dot] != 46 { return false }
        var a = dot - 1
        func letterOrDigit(_ u: UInt16) -> Bool { guard let sc = Unicode.Scalar(u) else { return false }; return sc.properties.isAlphabetic || (u >= 48 && u <= 57) }
        while a >= 0 && letterOrDigit(s[a]) { a -= 1 }
        let w = String(utf16CodeUnits: Array(s[(a + 1)..<dot]), count: dot - a - 1).lowercased()
        if w.isEmpty { return false }
        if w.allSatisfy({ $0.isASCII && $0.isNumber }) { return w.len <= 2 }
        return w.len <= 2 || ["bzw", "usw", "ca", "inkl", "ggf", "evtl", "vgl", "etc", "nr", "min", "max", "std", "sek", "bspw", "dr", "prof", "str"].contains(w)
    }
    public func endStream(_ finalMarkdown: String?) {
        let md = finalMarkdown ?? ""
        lock.lock()
        if !streaming { lock.unlock(); return }
        let start = min(fed, md.len)
        streaming = false; fed = md.len
        lock.unlock()
        if md.len > start { push(SoftVoice.speakable(SpeechText.spokenText(md.sub(start)))) }
    }
}
