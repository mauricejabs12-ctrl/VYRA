import Foundation

// ---------------------------------------------------------------- Einheiten umrechnen (aus `UnitTools`)
public enum UnitTools {
    final class Unit { let group: String, symbol: String, scale: Double, offset: Double; init(_ g: String, _ s: String, _ sc: Double, _ o: Double) { group = g; symbol = s; scale = sc; offset = o } }
    static let units: [String: Unit] = {
        var d = [String: Unit]()
        func add(_ names: String, _ group: String, _ symbol: String, _ scale: Double, _ offset: Double) { let u = Unit(group, symbol, scale, offset); for n in names.split(separator: "|") { d[String(n).lowercased()] = u } }
        add("mm|millimeter", "length", "mm", 0.001, 0); add("cm|zentimeter", "length", "cm", 0.01, 0); add("m|meter", "length", "m", 1, 0); add("km|kilometer", "length", "km", 1000, 0); add("in|inch|zoll", "length", "Zoll", 0.0254, 0); add("ft|fuss|foot", "length", "ft", 0.3048, 0); add("mi|meilen|mile", "length", "mi", 1609.344, 0)
        add("mg|milligramm", "mass", "mg", 0.000001, 0); add("g|gramm", "mass", "g", 0.001, 0); add("kg|kilogramm", "mass", "kg", 1, 0); add("t|tonnen|tonne", "mass", "t", 1000, 0); add("lb|lbs|pfund", "mass", "lb", 0.45359237, 0)
        add("ms|millisekunden", "time", "ms", 0.001, 0); add("s|sekunden|sekunde", "time", "s", 1, 0); add("min|minuten|minute", "time", "min", 60, 0); add("h|stunden|stunde", "time", "h", 3600, 0); add("d|tage|tag", "time", "Tage", 86400, 0)
        add("b|byte|bytes", "data", "Byte", 1, 0); add("kb", "data", "KB", 1000, 0); add("mb", "data", "MB", 1e6, 0); add("gb", "data", "GB", 1e9, 0); add("tb", "data", "TB", 1e12, 0); add("kib", "data", "KiB", 1024, 0); add("mib", "data", "MiB", 1048576, 0); add("gib", "data", "GiB", 1073741824, 0)
        add("c|celsius|°c", "temperature", "°C", 1, 273.15); add("f|fahrenheit|°f", "temperature", "°F", 5.0 / 9, 255.3722222222222); add("k|kelvin", "temperature", "K", 1, 0)
        return d
    }()
    public static func tryAnswer(_ question: String?) -> String? {
        guard let q = question, !q.trimmed.isEmpty, q.len <= 180 else { return nil }
        guard let m = Rx.match(q.trimmed, #"^(?:(?:bitte\s+)?(?:rechne|berechne|wandle|wie\s+viel(?:e)?\s+sind)\s+)?(?<n>[+-]?[0-9]+(?:[.,][0-9]+)?)\s*(?<a>[a-zA-Z°]+)\s+(?:in|zu|nach)\s+(?<b>[a-zA-Z°]+)(?:\s+um)?\s*[?.!]?$"#, .i) else { return nil }
        guard let from = units[m.group("a").lowercased()], let to = units[m.group("b").lowercased()], from.group == to.group else { return nil }
        guard let n = Double(m.group("n").rep(",", ".")) else { return nil }
        let baseValue = n * from.scale + from.offset
        if from.group == "temperature" && baseValue < 0 { return "Die Temperatur liegt unter dem absoluten Nullpunkt." }
        let result = (baseValue - to.offset) / to.scale
        if result.isInfinite || result.isNaN { return nil }
        return Calc.format(n) + " " + from.symbol + " = **" + Calc.format(result) + " " + to.symbol + "**"
    }
}

// ---------------------------------------------------------------- Rechnen (kleine Modelle rechnen unzuverlaessig) – aus `Calc`
public enum Calc {
    public static func looksLikeMath(_ s0: String?) -> Bool {
        let s = (s0 ?? "").trimmed
        if s.len < 3 || s.len > 120 { return false }
        return Rx.isMatch(s, #"^(was (ist|ergibt|sind)|rechne|berechne|wie ?viel (ist|sind))?\s*([-+*/^%().,\d\s]|sqrt|wurzel|pi|x|mal|plus|minus|geteilt durch|durch|hoch|von|prozent|aus)+[=?]?$"#, .i)
            && Rx.isMatch(s, #"\d\s*([-+*/^%x]|mal|plus|minus|geteilt|durch|hoch|% von|prozent von)\s*(\d|sqrt|wurzel|\()"#, .i)
    }
    public static func eval(_ expr: String?) throws -> Double {
        var s = (expr ?? "").lowercased()
        s = Rx.replace(s, "^(was (ist|ergibt|sind)|rechne|berechne|wie ?viel (ist|sind))", "")
        for (a, b) in [("wurzel aus", "sqrt"), ("% von", "%*"), ("prozent von", "%*"), ("geteilt durch", "/"), ("durch", "/"), ("mal", "*"), ("plus", "+"), ("minus", "-"), ("hoch", "^"), ("wurzel", "sqrt"), ("x", "*"), ("=", ""), ("?", "")] { s = s.rep(a, b) }
        if s.contains(",") { s = Rx.replace(s, #"(?<=\d)\.(?=\d{3}(?:\D|$))"#, "") }
        s = s.rep(",", ".")
        let u = Array(s.utf16)
        var i = 0
        let v = try sum(u, &i)
        skip(u, &i)
        if i < u.count { throw VyraError("Unerwartetes Zeichen: " + String(utf16CodeUnits: [u[i]], count: 1), .invalidData) }
        if v.isNaN || v.isInfinite { throw VyraError("Ergebnis ist nicht definiert.", .invalidData) }
        return v
    }
    static func isWs(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 0xA0 || (c >= 0x2000 && c <= 0x200A) }
    static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    static func skip(_ s: [UInt16], _ i: inout Int) { while i < s.count && isWs(s[i]) { i += 1 } }
    static func sum(_ s: [UInt16], _ i: inout Int) throws -> Double {
        var v = try prod(s, &i)
        while true {
            skip(s, &i)
            if i < s.count && (s[i] == 43 || s[i] == 45) { let op = s[i]; i += 1; let r = try prod(s, &i); v = op == 43 ? v + r : v - r } else { return v }
        }
    }
    static func prod(_ s: [UInt16], _ i: inout Int) throws -> Double {
        var v = try unary(s, &i)
        while true {
            skip(s, &i)
            if i < s.count && (s[i] == 42 || s[i] == 47) {
                let op = s[i]; i += 1
                let r = try unary(s, &i)
                if op == 47 && r == 0 { throw VyraError("Division durch null.", .invalidData) }
                v = op == 42 ? v * r : v / r
            } else { return v }
        }
    }
    static func pow_(_ s: [UInt16], _ i: inout Int) throws -> Double {
        var b = try atom(s, &i)
        skip(s, &i)
        while i < s.count && s[i] == 37 { i += 1; b /= 100; skip(s, &i) }
        skip(s, &i)
        if i < s.count && s[i] == 94 { i += 1; let e = try unary(s, &i); return Foundation.pow(b, e) }
        return b
    }
    static func unary(_ s: [UInt16], _ i: inout Int) throws -> Double {
        skip(s, &i)
        if i < s.count && s[i] == 45 { i += 1; return -(try unary(s, &i)) }
        if i < s.count && s[i] == 43 { i += 1; return try unary(s, &i) }
        return try pow_(s, &i)
    }
    static func at(_ s: [UInt16], _ i: Int, _ w: String) -> Bool { let w16 = Array(w.utf16); return i + w16.count <= s.count && Array(s[i..<i + w16.count]) == w16 }
    static func atom(_ s: [UInt16], _ i: inout Int) throws -> Double {
        skip(s, &i)
        if i >= s.count { throw VyraError("Ausdruck unvollständig.", .invalidData) }
        if s[i] == 40 {
            i += 1
            let v = try sum(s, &i)
            skip(s, &i)
            if i >= s.count || s[i] != 41 { throw VyraError("Klammer fehlt.", .invalidData) }
            i += 1; return v
        }
        if at(s, i, "sqrt") { i += 4; let v = try atom(s, &i); if v < 0 { throw VyraError("Wurzel aus negativer Zahl.", .invalidData) }; return v.squareRoot() }
        if at(s, i, "pi") { i += 2; return Double.pi }
        let st = i
        while i < s.count && (isDigit(s[i]) || s[i] == 46) { i += 1 }
        if st == i { throw VyraError("Zahl erwartet.", .invalidData) }
        guard let v = Double(String(utf16CodeUnits: Array(s[st..<i]), count: i - st)) else { throw VyraError("Zahl erwartet.", .invalidData) }
        return v
    }
    public static func format(_ v: Double) -> String {
        abs(v - v.rounded()) < 1e-9 && abs(v) < 1e15 ? DE.n0(v.rounded(.toNearestOrEven)) : DE.flexible(v, maxDigits: 10)
    }
}

// ---------------------------------------------------------------- Zeitschaetzung (aus `TaskTimes`/`EtaTracker`)
/// Lernt, wie lange Aufgaben auf diesem Geraet dauern (Datei KI/VYRA-KI-Zeiten.json).
public final class TaskTimes {
    let path: String?
    let gate = NSLock()
    var secs = [String: Double](), chars = [String: Double]()
    public init(_ dataRoot: String?) {
        path = dataRoot.map { FS.join($0, "KI", "VYRA-KI-Zeiten.json") }
        if let p = path, FS.isFile(p), let o = try? Json.parse(FS.readText(p)) as? JObject {
            TaskTimes.read(o, "zeiten", &secs); TaskTimes.read(o, "laengen", &chars)
        }
    }
    static func read(_ o: JObject, _ name: String, _ into: inout [String: Double]) {
        guard let d = o[name] as? JObject else { return }
        for k in d.keys { if let x = d[k] as? Double, x > 0, x < 100000 { into[k] = x } }
    }
    public static func key(_ local: Bool, _ kind: String?) -> String { (local ? "lokal" : "cloud") + ":" + (kind ?? "chat") }
    /// Startwerte, bis VYRA echte Zeiten von diesem Geraet kennt.
    public static func defaultSeconds(_ key: String) -> Double {
        let local = key.hasPrefix("lokal:")
        let k = key.sub(key.indexOf(":") + 1)
        switch k {
        case "start": return local ? 25 : 0
        case "web": return local ? 45 : 20
        case "think": return local ? 55 : 25
        case "work": return local ? 150 : 70
        case "app": return local ? 240 : 120
        case "werk": return local ? 200 : 100
        case "script": return local ? 45 : 20
        default: return local ? 18 : 8
        }
    }
    public func seconds(_ key: String) -> Double { gate.lock(); defer { gate.unlock() }; return secs[key] ?? TaskTimes.defaultSeconds(key) }
    public func chars(_ key: String) -> Double { gate.lock(); defer { gate.unlock() }; return chars[key] ?? 1600 }
    public func known(_ key: String) -> Bool { gate.lock(); defer { gate.unlock() }; return secs[key] != nil }
    /// Neue Messung einrechnen: die ersten Werte zaehlen voll, danach gleitend (juengere Messungen wiegen mehr).
    public func record(_ key: String, _ seconds: Double, _ answerChars: Int, _ charsKey: String?) {
        if seconds <= 0.2 || seconds > 7200 { return }
        gate.lock()
        secs[key] = secs[key].map { $0 * 0.65 + seconds * 0.35 } ?? seconds
        if let ck = charsKey, answerChars > 40 { chars[ck] = chars[ck].map { $0 * 0.65 + Double(answerChars) * 0.35 } ?? Double(answerChars) }
        gate.unlock()
        save()
    }
    func save() {
        guard let p = path else { return }
        gate.lock()
        let z = JObject(), l = JObject()
        for (k, v) in secs.sorted(by: { $0.key < $1.key }) { z[k] = (v * 10).rounded() / 10 }
        for (k, v) in chars.sorted(by: { $0.key < $1.key }) { l[k] = v.rounded(.toNearestOrEven) }
        gate.unlock()
        let o = Json.obj(("zeiten", z), ("laengen", l))
        try? FS.mkdir(FS.dirName(p))
        try? FS.write(p, text: Json.serialize(o))
    }
}

/// Restzeit einer laufenden Aufgabe. Vor dem Schreiben: Erfahrungswert minus bisherige Zeit.
/// Sobald die Antwort Wort fuer Wort erscheint: aus der Schreibgeschwindigkeit und der ueblichen Antwortlaenge.
public final class EtaTracker {
    public var now: () -> Date = { Date() }
    var start = Date()
    var expected = 10.0, expectedChars = 1600.0
    var streamFinal = false
    var streamAt = -1.0
    var streamFrom = 0, chars = 0
    var smooth = -1.0
    public private(set) var kind = "chat"
    public init() {}
    public func restart() { start = now(); smooth = -1; streamAt = -1; chars = 0 }
    /// expected = erwartete Gesamtdauer ab Start; streamFinal = der gestreamte Text ist die endgueltige Antwort.
    public func plan(_ kind: String, _ expectedSeconds: Double, _ expectedAnswerChars: Double, _ streamIsAnswer: Bool) {
        self.kind = kind; expected = max(1, expectedSeconds); expectedChars = max(200, expectedAnswerChars); streamFinal = streamIsAnswer; smooth = -1
    }
    public var elapsed: Double { max(0, now().timeIntervalSince(start)) }
    public func text(_ length: Int) {
        let e = elapsed
        if length < chars { streamAt = -1 } // neuer Durchgang (z. B. nach dem Nachdenken)
        if streamAt < 0 && length > 0 { streamAt = e; streamFrom = length }
        chars = length
    }
    public var writing: Bool { streamFinal && streamAt >= 0 && chars > 0 }
    /// Geschaetzte Restzeit in Sekunden (geglaettet, damit die Anzeige nicht springt).
    public func remaining() -> Double {
        let e = elapsed
        var raw: Double
        let ws = streamAt >= 0 ? e - streamAt : 0
        if streamFinal && streamAt >= 0 && ws >= 1.2 && chars - streamFrom >= 60 {
            let rate = Double(chars - streamFrom) / ws
            let left = Double(chars) < expectedChars * 0.92 ? expectedChars - Double(chars) : Double(chars) * 0.12
            raw = left / max(1, rate)
        } else {
            raw = expected - e
            if raw < expected * 0.08 { raw = max(3, e * 0.15) } // dauert laenger als sonst
        }
        raw = max(0, raw)
        smooth = smooth < 0 ? raw : smooth * 0.6 + raw * 0.4
        return smooth
    }
    /// Anteil 0..1 fuer den Fortschrittsbalken.
    public func fraction(_ r: Double) -> Double { let e = elapsed; return e + r <= 0 ? 0 : max(0.02, min(0.98, e / (e + r))) }
    public static func formatElapsed(_ s: Double) -> String { let t = Int(s.rounded(.down)); return t < 60 ? "\(t) s" : "\(t / 60):" + String(t % 60).padLeft(2, "0") + " min" }
    public static func formatRemaining(_ s: Double) -> String {
        if s < 4 { return "gleich fertig" }
        if s < 60 { let r = s < 15 ? Int(s.rounded(.up)) : Int((s / 5).rounded(.up) * 5); return "noch ca. \(r) s" }
        var m = Int((s / 60).rounded(.toNearestOrEven)); if m < 1 { m = 1 }
        return "noch ca. \(m) min"
    }
}

// ---------------------------------------------------------------- Codebloecke pruefen (aus `CodeCheck`)
public final class CodeCheckResult { public var blocks = 0, checked = 0; public var problems = [String](); public var kinds = [String]() }
public enum CodeCheck {
    public static func blocks(_ md: String?) -> [(String, String)] {
        Rx.matches(md ?? "", "```([A-Za-z0-9+#._-]*)[^\\n]*\\n([\\s\\S]*?)```").map { ($0.group(1).lowercased(), $0.group(2)) }
    }
    static func kind(_ lang: String, _ code: String) -> String? {
        switch lang {
        case "py", "python", "python3": return "python"
        case "js", "javascript", "mjs", "jsx", "node": return "javascript"
        case "ts", "typescript", "tsx": return "typescript"
        case "json": return "json"
        case "ps1", "powershell", "pwsh": return "powershell"
        case "html", "htm": return "html"
        case "xml", "svg", "xaml", "csproj": return "xml"
        case "css", "scss": return "css"
        default: break
        }
        if lang.isEmpty {
            let t = code.trimStart()
            if t.hasPrefix("{") || t.hasPrefix("[") { return "json" }
            if t.lowercased().hasPrefix("<!doctype html") || t.lowercased().hasPrefix("<html") { return "html" }
        }
        return nil
    }
    public static func kindName(_ k: String) -> String { k == "python" ? "Python" : k == "javascript" ? "JavaScript" : k == "typescript" ? "TypeScript (Klammern)" : k == "json" ? "JSON" : k == "powershell" ? "PowerShell" : k == "html" ? "HTML/JavaScript" : k == "xml" ? "XML/SVG" : k == "css" ? "CSS" : k }
    /// Liefert echte Fehler (keine Stilhinweise). iOS: Python- und PowerShell-Bloecke werden nicht geprueft (kein Interpreter auf dem iPhone) –
    /// wie unter Windows, wenn Python fehlt.
    public static func run(_ md: String?, _ token: CancelToken) throws -> CodeCheckResult {
        let r = CodeCheckResult()
        let bl = blocks(md)
        r.blocks = bl.count
        var n = 0
        for b in bl {
            try token.check()
            n += 1
            let code = b.1
            guard let k = kind(b.0, code), code.components(separatedBy: "\n").count >= 3 else { continue }
            if k != "python" && Rx.isMatch(code, #"^\s*(?:\.\.\.|…|//\s*\.\.\.|#\s*\.\.\.)\s*$"#, .m) { continue } // bewusst gekuerzte Ausschnitte
            if k == "powershell" || k == "python" { continue }
            var err: String?
            do {
                if k == "json" { _ = try Json.parse(code) }
                else if k == "javascript" || k == "typescript" { err = AppChecks.jsSyntax(code, 0) }
                else if k == "html" {
                    if code.containsIgnoreCase("<html") && !code.containsIgnoreCase("</html>") { err = "Die Seite endet ohne </html> (abgeschnitten)." }
                    for m in Rx.matches(code, "<script\\b(?![^>]*\\bsrc=)[^>]*>(.*?)</script>", [.i, .s]) {
                        if err != nil { break }
                        err = AppChecks.jsSyntax(m.group(1), code.sub(0, m.groupIndex(1)).filter { $0 == "\n" }.count)
                    }
                }
                else if k == "xml" { _ = try XmlDom.parse(Data(code.utf8)) }
                else if k == "css" { let bal = code.filter { $0 == "{" }.count - code.filter { $0 == "}" }.count; if bal != 0 { err = "Geschweifte Klammern im CSS sind nicht ausgeglichen." } }
            } catch {
                if error.isCancellation { throw error }
                err = error.vyraMessage
            }
            r.checked += 1
            if !r.kinds.contains(kindName(k)) { r.kinds.append(kindName(k)) }
            if let e = err, !e.isEmpty { r.problems.append("Codeblock \(n) (" + kindName(k) + "): " + e) }
        }
        return r
    }
}

// ---------------------------------------------------------------- Buchhaltungs-Starter (aus `AccountingStarter`)
public enum AccountingStarter {
    public static func create(_ appsRoot: String) throws -> AppProject {
        let p = AppProject()
        p.name = "Buchhaltungs-Starter"; p.kind = "python"; p.entry = "main.py"; p.summary = "Lokales Entwicklungsbeispiel: SQLite, Soll/Haben, Storno, CSV und Tests. Keine Konformitaetszusage."
        p.folder = FS.join(appsRoot, "Buchhaltung-" + DE.stamp(Date(), "yyyyMMdd-HHmmss") + "-" + FS.newId().sub(0, 6))
        for name in ["main.py", "ledger.py", "test_ledger.py", "README.md"] {
            let stem = FS.stem(name), ext = FS.ext(name).trimStart(".")
            guard let url = Bundle.module.url(forResource: stem, withExtension: ext, subdirectory: "Resources/Vorlagen/Buchhaltung") else { throw VyraError("Vorlage fehlt: " + name, .io) }
            p.files.append(AppFile(name, try FS.readText(url.path), "Buchhaltungs-Vorlage"))
        }
        try p.save()
        return p
    }
}

/// Bildschirm-Sperre verhindern, solange VYRA arbeitet (unter Windows: kein Energiesparmodus). Die App setzt `apply`
/// (iOS: `UIApplication.shared.isIdleTimerDisabled`).
public enum KeepAwake {
    public static var apply: ((Bool) -> Void)?
    static var depth = 0
    public static var current: Int { depth }
    public static func enter() { depth += 1; if depth == 1 { apply?(true) } }
    public static func exit() { if depth <= 0 { return }; depth -= 1; if depth == 0 { apply?(false) } }
}
