import Foundation

// ---------------------------------------------------------------- App-Studio: Apps planen, schreiben, selbst pruefen und Fehler beheben
public final class AppFile {
    public var path = "", purpose = "", content = ""
    public init(_ path: String = "", _ content: String = "", _ purpose: String = "") { self.path = path; self.content = content; self.purpose = purpose }
}
public final class AppProject {
    public var name = "", kind = "web", folder = "", entry = "", summary = "", built = ""
    public var files = [AppFile]()
    public init() {}
    public var entryPath: String { FS.join(folder, entry) }
    public func get(_ path: String) -> AppFile? { files.first { $0.path.lowercased() == path.lowercased() } }
    public static func kindName(_ k: String) -> String {
        k == "windows" ? "Windows-Programm (C#, .exe)" : k == "python" ? "Python-Programm" : k == "source" ? "Quellcode-Projekt (Plattform-Build erforderlich)" : "Web-App (HTML/JavaScript)"
    }
    public func save() throws { try save(true) }
    public func save(_ writeFiles: Bool) throws {
        try FS.mkdir(folder)
        if writeFiles {
            for f in files {
                guard let p = AppBuilder.insideFolder(folder, f.path) else { continue }
                try FS.mkdir(FS.dirName(p))
                if !FS.exists(p) || FS.size(p) > 2_000_000 || (try? DocReader.readTextFile(p)) != f.content { try FS.write(p, text: f.content) }
            }
        }
        let m = Json.obj(("format", "vyra-app-1"), ("name", name), ("kind", kind), ("entry", entry), ("summary", summary), ("built", built), ("files", files.map { Json.obj(("path", $0.path), ("purpose", $0.purpose)) as Any }))
        try FS.write(FS.join(folder, "vyra-app.json"), text: Json.serialize(m))
    }
    public static func load(_ folder: String) -> AppProject? {
        let mf = FS.join(folder, "vyra-app.json")
        if !FS.isFile(mf) || FS.size(mf) > 2_000_000 { return nil }
        guard let o = try? Json.parse(FS.readText(mf)), Json.str(o, "format") == "vyra-app-1" else { return nil }
        let p = AppProject()
        p.folder = folder; p.name = Json.str(o, "name"); p.kind = Json.str(o, "kind"); p.entry = Json.str(o, "entry"); p.summary = Json.str(o, "summary"); p.built = Json.str(o, "built")
        if !["web", "python", "windows", "source"].contains(p.kind) { return nil }
        guard let entryPath = AppBuilder.insideFolder(folder, p.entry), FS.isFile(entryPath) else { return nil }
        // Gebaute Datei nur innerhalb des Projektordners
        if !p.built.isEmpty {
            let rel = p.built.hasPrefix("/") ? (FS.isInside(p.built, folder) ? FS.relative(p.built, to: folder) : "") : p.built
            p.built = rel.isEmpty ? "" : AppBuilder.insideFolder(folder, rel) ?? ""
        }
        var loadBudget = 6_000_000
        let list = Json.arr(o, "files").stableSorted { (Json.str($0, "path") == p.entry ? 0 : 1) < (Json.str($1, "path") == p.entry ? 0 : 1) }.prefix(1000)
        for x in list {
            if loadBudget <= 0 { break }
            let rel = Json.str(x, "path")
            guard let full = AppBuilder.insideFolder(folder, rel), FS.isFile(full), FS.size(full) <= Int64(min(1_000_000, loadBudget)) else { continue }
            guard let body = try? FS.readText(full), body.len <= loadBudget else { continue }
            loadBudget -= body.len
            p.files.append(AppFile(rel, body, Json.str(x, "purpose")))
        }
        return p.get(p.entry) != nil ? p : nil
    }
}
public final class AppResult {
    public var project: AppProject!
    public var answer = ""
    public var problems = [String]()
    public var remaining = [String]()
    public var fixed = 0
    public var checked = false
    public var checkInfo = ""
}

/// Pruefungen: Web statisch (Klammern, Zeichenketten, abgeschnittene Dateien, fehlende IDs) und – auf dem iPhone –
/// im echten Browser-Modul (WKWebView). Windows-C#-Uebersetzung und Python gibt es auf dem iPhone nicht.
public enum AppChecks {
    /// Vom App-Modul gesetzt (WKWebView): laedt die Startseite und liefert JavaScript-Fehler; nil = nicht verfuegbar.
    public static var webRuntime: ((String, CancelToken) async throws -> [String]?)?
    public static func webStatic(_ p: AppProject) -> [String] {
        var errs = [String]()
        let html = p.files.filter { $0.path.lowercased().hasSuffix(".html") || $0.path.lowercased().hasSuffix(".htm") }
        if html.isEmpty { errs.append("Es gibt keine HTML-Datei (index.html) als Startseite.") }
        let allText = p.files.map { $0.content }.joined(separator: "\n")
        let ids = Set(Rx.matches(allText, "\\bid\\s*=\\s*[\"']([^\"']+)[\"']").map { $0.group(1) })
        for f in html {
            let c = f.content
            if !c.containsIgnoreCase("</html>") && c.containsIgnoreCase("<html") { errs.append(f.path + ": Die Datei endet ohne </html> – sie ist vermutlich abgeschnitten.") }
            let open = Rx.count(c, "<script\\b", .i), close = Rx.count(c, "</script>", .i)
            if open != close { errs.append(f.path + ": <script>-Bereiche sind nicht geschlossen (\(open) geöffnet, \(close) geschlossen).") }
            for m in Rx.matches(c, "<script\\b(?![^>]*\\bsrc=)[^>]*>(.*?)</script>", [.i, .s]) {
                let line = c.sub(0, m.groupIndex(1)).filter { $0 == "\n" }.count
                if let e = jsSyntax(m.group(1), line) { errs.append(f.path + ": " + e) }
            }
            for m in Rx.matches(c, "<style\\b[^>]*>(.*?)</style>", [.i, .s]) {
                let g = m.group(1)
                let bal = g.filter { $0 == "{" }.count - g.filter { $0 == "}" }.count
                if bal != 0 { errs.append(f.path + ": Im CSS fehlen geschweifte Klammern (" + (bal > 0 ? "\(bal) × '}'" : "\(-bal) × '{'") + ").") }
            }
            for m in Rx.matches(c, "<(?:script|link)\\b[^>]*(?:src|href)\\s*=\\s*[\"']([^\"':]+\\.(?:js|css))[\"']", .i) {
                let rel = m.group(1).trimStart("./")
                if p.get(rel) == nil { errs.append(f.path + ": verweist auf »" + rel + "«, diese Datei gibt es aber nicht.") }
            }
        }
        for f in p.files where f.path.lowercased().hasSuffix(".js") { if let e = jsSyntax(f.content, 0) { errs.append(f.path + ": " + e) } }
        for f in p.files where f.path.lowercased().hasSuffix(".css") {
            let bal = f.content.filter { $0 == "{" }.count - f.content.filter { $0 == "}" }.count
            if bal != 0 { errs.append(f.path + ": Es fehlen geschweifte Klammern im CSS.") }
        }
        for m in Rx.matches(allText, "getElementById\\(\\s*[\"']([^\"']+)[\"']\\s*\\)|querySelector\\(\\s*[\"']#([A-Za-z][\\w-]*)[\"']\\s*\\)") {
            let id = m.success(1) && !m.group(1).isEmpty ? m.group(1) : m.group(2)
            if !id.isEmpty && !ids.contains(id) && !allText.contains(".id='" + id + "'") && !allText.contains(".id=\"" + id + "\"") && !allText.contains(".id = '" + id + "'") && !allText.contains(".id = \"" + id + "\"") {
                let msg = "Das JavaScript sucht ein Element mit id=\"" + id + "\", das im HTML nicht vorkommt."
                if !errs.contains(msg) { errs.append(msg) }
            }
        }
        return errs
    }
    /// Kleiner JavaScript-Pruefer: Klammern, Zeichenketten, Template-Strings, Kommentare und regulaere Ausdruecke.
    public static func jsSyntax(_ code0: String?, _ lineOffset: Int) -> String? {
        guard let code0 = code0 else { return nil }
        let code = Array(code0.utf16)
        var stack = [(UInt16, Int)]()
        var line = 1 + lineOffset
        var i = 0
        let n = code.count
        var lastSig: UInt16 = 0
        var lastWord = ""
        func ch(_ u: UInt16) -> String { String(UnicodeScalar(UInt8(u))) }
        func isLetter(_ u: UInt16) -> Bool { guard let s = UnicodeScalar(u) else { return false }; return s.properties.isAlphabetic }
        func isLetterOrDigit(_ u: UInt16) -> Bool { guard let s = UnicodeScalar(u) else { return false }; return s.properties.isAlphabetic || s.properties.numericType != nil }
        func isWs(_ u: UInt16) -> Bool { u == 32 || u == 9 || u == 13 || u == 11 || u == 12 || u == 0xA0 || u == 0xFEFF || u == 0x2028 || u == 0x2029 }
        let regexBefore: Set<UInt16> = Set("(,=:[!&|?{};+-*%<>~^".utf16)
        while i < n {
            let c = code[i]
            if c == 10 { line += 1; i += 1; continue }
            if isWs(c) { i += 1; continue }
            if c == 47 && i + 1 < n && code[i + 1] == 47 { while i < n && code[i] != 10 { i += 1 }; continue }
            if c == 47 && i + 1 < n && code[i + 1] == 42 {
                var e = -1
                var k = i + 2
                while k + 1 < n { if code[k] == 42 && code[k + 1] == 47 { e = k; break }; k += 1 }
                if e < 0 { return "Zeile \(line): Kommentar /* wird nicht geschlossen – Datei vermutlich abgeschnitten." }
                line += code[i..<e].filter { $0 == 10 }.count
                i = e + 2; continue
            }
            if c == 34 || c == 39 {
                let start = line
                i += 1
                while i < n && code[i] != c {
                    if code[i] == 92 { i += 2; continue }
                    if code[i] == 10 { return "Zeile \(start): Zeichenkette mit " + ch(c) + " wird nicht geschlossen." }
                    i += 1
                }
                if i >= n { return "Zeile \(start): Zeichenkette wird nicht geschlossen – Datei vermutlich abgeschnitten." }
                i += 1; lastSig = 97; lastWord = ""; continue
            }
            if c == 96 {
                let start = line
                i += 1
                var depth = 0
                while i < n {
                    let d = code[i]
                    if d == 92 { i += 2; continue }
                    if d == 10 { line += 1 }
                    if depth == 0 && d == 96 { break }
                    if d == 36 && i + 1 < n && code[i + 1] == 123 { depth += 1; i += 2; continue }
                    if depth > 0 && d == 123 { depth += 1 }
                    if depth > 0 && d == 125 { depth -= 1 }
                    i += 1
                }
                if i >= n { return "Zeile \(start): Template-String (`) wird nicht geschlossen." }
                i += 1; lastSig = 97; lastWord = ""; continue
            }
            if c == 47 {
                let regex = regexBefore.contains(lastSig) || lastSig == 0 || lastWord == "return" || lastWord == "typeof" || lastWord == "case"
                if regex {
                    i += 1
                    var cls = false
                    while i < n {
                        let d = code[i]
                        if d == 92 { i += 2; continue }
                        if d == 10 { return "Zeile \(line): Regulärer Ausdruck wird nicht geschlossen." }
                        if d == 91 { cls = true } else if d == 93 { cls = false } else if d == 47 && !cls { break }
                        i += 1
                    }
                    i += 1
                    while i < n && isLetter(code[i]) { i += 1 }
                    lastSig = 97; lastWord = ""; continue
                }
            }
            if c == 40 || c == 91 || c == 123 { stack.append((c, line)); lastSig = c; lastWord = ""; i += 1; continue }
            if c == 41 || c == 93 || c == 125 {
                guard let top = stack.popLast() else { return "Zeile \(line): überzähliges '" + ch(c) + "'." }
                let want: UInt16 = c == 41 ? 40 : c == 93 ? 91 : 123
                if top.0 != want { return "Zeile \(line): '" + ch(c) + "' passt nicht zu '" + ch(top.0) + "' aus Zeile \(top.1)." }
                lastSig = c; lastWord = ""; i += 1; continue
            }
            if isLetterOrDigit(c) || c == 95 || c == 36 {
                let s = i
                while i < n && (isLetterOrDigit(code[i]) || code[i] == 95 || code[i] == 36) { i += 1 }
                lastWord = String(decoding: code[s..<i], as: UTF16.self); lastSig = 97; continue
            }
            lastSig = c; lastWord = ""; i += 1
        }
        if let t = stack.last { return "Datei endet, aber '" + ch(t.0) + "' aus Zeile \(t.1) wird nie geschlossen – vermutlich abgeschnitten." }
        return nil
    }
}

public enum CodePlatform {
    public static func needsToolchain(_ request: String) -> Bool {
        let n = Knowledge.norm(request)
        return Rx.isMatch(n, "\\b(?:in|mit)\\s+go\\b|\\bgo\\s+(?:sprache|app|programm|tool)\\b") || request.contains("c++") || Rx.isMatch(n, "\\b(?:swift|swiftui|ios|iphone|ipad|kotlin|android|flutter|dart|rust|golang|go-sprache|java|typescript|c\\+\\+|cpp)\\b")
    }
    public static func entry(_ request: String) -> String {
        let q = Knowledge.norm(request)
        if Rx.isMatch(q, "\\b(?:flutter|dart)\\b") { return "lib/main.dart" }
        if Rx.isMatch(q, "\\b(?:kotlin|android)\\b") { return q.contains("java") && !q.contains("kotlin") ? "MainActivity.java" : "MainActivity.kt" }
        if Rx.isMatch(q, "\\b(?:swift|swiftui|ios|iphone|ipad)\\b") { return "VYRAApp.swift" }
        if q.contains("typescript") { return "src/main.ts" }
        if q.contains("rust") { return "src/main.rs" }
        if q.contains("golang") || q.contains("go-sprache") || Rx.isMatch(q, "\\b(?:in|mit)\\s+go\\b|\\bgo\\s+(?:sprache|app|programm|tool)\\b") { return "main.go" }
        if Rx.isMatch(q, "\\bjava\\b") { return "Main.java" }
        return "main.cpp"
    }
    public static func discoverEntry(_ folder: String) -> String? {
        let priority = ["main.dart", "MainActivity.kt", "MainActivity.java", "VYRAApp.swift", "main.swift", "main.rs", "main.go", "Main.java", "main.cpp"]
        let files = FS.allFiles(folder)
        for name in priority { if let f = files.first(where: { FS.fileName($0).lowercased() == name.lowercased() }) { return FS.relative(f, to: folder) } }
        return nil
    }
}

public final class AppBuilder {
    let brain: ChatBrain
    let sys: String
    let appsRoot: String
    var stepNo = 0
    public var onStep: ((WorkStep) -> Void)?
    public var checkOverride: ((AppProject, CancelToken) async throws -> [String])? // fuer Tests
    /// 4.15 Pro: mehr Dateien, laengere Dateien, mehr Reparaturrunden, Funktions-Pruefung.
    public var pro = false
    public var startTest = false
    public var reviewOverride: ((AppProject, CancelToken) async throws -> [String])? // fuer Tests
    var fileCap: Int { pro ? ProLimits.appFilesPro : 12 }
    public init(_ brain: ChatBrain, _ system: String?, _ appsRoot: String) { self.brain = brain; sys = system ?? ""; self.appsRoot = appsRoot }
    public static var defaultRoot: String { FS.join(DocWriter.defaultFolder, "Apps") }
    func begin(_ kind: String, _ text: String) -> WorkStep { stepNo += 1; let s = WorkStep(); s.kind = kind; s.text = text; s.index = stepNo; onStep?(s); return s }
    func end(_ s: WorkStep, _ detail: String?, _ failed: Bool) { s.done = true; s.failed = failed; if let d = detail { s.detail = d }; onStep?(s) }
    static func one(_ t: String) -> [ChatTurn] { [ChatTurn("user", t)] }
    static func obj(_ pairs: (String, Any)...) -> JObject { let o = JObject(); for (k, v) in pairs { o[k] = v }; return o }
    // Erkennt, ob jemand eine App/ein Programm gebaut haben moechte.
    static let rxApp = "\\b(bau|baue|erstell|erstelle|programmier|programmiere|programier|progamier|entwickel|entwickle|schreib|schreibe|mach|mache|code|coden|bastel)\\w*\\b.{0,40}\\b(app|apps|anwendung|programm|tool|spiel|game|webseite|website|homepage|rechner|taschenrechner|timer|stoppuhr|quiz|generator|editor|dashboard|browser|bot|kalender|buchhaltung|exe|gui|oberfläche|snake|tetris|pong)\\b"
    public static func wantsApp(_ q: String) -> Bool {
        let t = q.lowercased()
        if t.len < 10 { return false }
        if Rx.isMatch(t, "\\b(wie|was|warum|welche)\\b.{0,20}\\b(app|programm)\\b.*\\?$") { return false }
        if Rx.isMatch(t, "^\\s*(?:erklaer|erklär|was (?:ist|bedeutet)|wie (?:funktioniert|programmiert|erstellt|baut)|zeige mir wie)") { return false }
        return Rx.isMatch(t, rxApp, .i) || Rx.isMatch(t, "\\b(?:app|anwendung|programm|tool|spiel|game|webseite|website|dashboard|buchhaltungssystem|buchhaltungsprogramm|rechnungsprogramm)\\b.{0,65}\\b(?:bau\\w*|erstell\\w*|programmier\\w*|entwickel\\w*|entwickl\\w*|schreib\\w*|coden)\\b") || Rx.isMatch(t, "\\b(?:bau\\w*|erstell\\w*|programmier\\w*|entwickel\\w*|entwickl\\w*|schreib\\w*)\\b.{0,65}\\b(?:buchhaltungssystem|buchhaltungsprogramm|rechnungsprogramm)\\b")
    }
    public static func wantsEdit(_ q: String) -> Bool {
        Rx.isMatch(q.lowercased(), "\\b(änder|aender|füg|fueg|hinzu|mach|entfern|lösch|loesch|ersetz|verbesser|erweiter|button|knopf|farbe|größer|groesser|kleiner|fehler|bug|geht nicht|funktioniert nicht|klappt nicht|kaputt|dark ?mode|design|sound|level|punkte|speicher|neu)\\w*")
    }
    public static func kindHint(_ q: String) -> String? {
        let t = q.lowercased()
        if CodePlatform.needsToolchain(t) { return "source" }
        if Rx.isMatch(t, "\\bpython\\b|\\.py\\b") { return "python" }
        if Rx.isMatch(t, "\\.exe\\b|\\bexe\\b|windows-?(app|programm|anwendung)|desktop-?(app|programm)|\\bc#|csharp|winforms|\\bwpf\\b") { return "windows" }
        if Rx.isMatch(t, "\\b(webseite|website|html|javascript|browser|homepage|web-?app)\\b") { return "web" }
        return nil
    }
    public static func insideFolder(_ folder: String, _ rel0: String) -> String? {
        if rel0.trimmed.isEmpty || folder.trimmed.isEmpty { return nil }
        guard let rel = try? ArchiveTools.safeRelative(rel0) else { return nil }
        let root = FS.full(folder).trimEnd("/")
        let full = FS.full(FS.join(root, rel))
        if !full.hasPrefix(root + "/") { return nil }
        var cursor = root
        if FS.isSymlink(cursor) { return nil }
        for part in rel.splitKeep("/") where !part.isEmpty {
            cursor = FS.join(cursor, part)
            if FS.exists(cursor) && FS.isSymlink(cursor) { return nil }
        }
        return full
    }
    static let allowed = [".html", ".htm", ".css", ".js", ".json", ".svg", ".txt", ".md", ".cs", ".py", ".csv", ".xml", ".swift", ".kt", ".kts", ".java", ".dart", ".go", ".rs", ".cpp", ".c", ".h", ".hpp", ".toml", ".yaml", ".yml", ".gradle", ".properties", ".ts", ".tsx", ".jsx", ".csproj", ".xaml", ".sln", ".sql", ".sh"]
    static func cleanPath(_ p0: String) -> String? {
        var p = p0.trimmed.trim("`\"'").rep("\\", "/")
        while p.hasPrefix("./") { p = p.sub(2) }
        p = p.trimStart("/")
        if p.isEmpty || p.contains("..") || p.contains(":") || p.len > 80 { return nil }
        if !allowed.contains(FS.ext(p).lowercased()) { return nil }
        return p
    }
    static func lang(_ path: String) -> String {
        let e = FS.ext(path).lowercased()
        switch e {
        case ".html", ".htm": return "html"
        case ".js": return "javascript"
        case ".css": return "css"
        case ".cs": return "csharp"
        case ".py": return "python"
        case ".json": return "json"
        case ".swift": return "swift"
        case ".kt", ".kts": return "kotlin"
        case ".dart": return "dart"
        case ".rs": return "rust"
        case ".go": return "go"
        case ".java": return "java"
        case ".ts": return "typescript"
        case ".cpp", ".h": return "cpp"
        default: return "text"
        }
    }
    func rules(_ kind: String) -> String {
        if pro && kind == "windows" { return ProLimits.windowsRules }
        if kind == "source" { return "Technik: Nutze exakt die vom Nutzer angeforderte Sprache und Plattform. Liefere passende Projektdateien und Abhaengigkeiten, keine Web-Ersatzapp fuer Swift/Kotlin/Dart/Rust/Go/C++. Fuer mobile Apps erforderliche Manifeste und Build-Konfigurationen einplanen. Der Host fuehrt hier keinen SDK-/Plattform-Build aus. Behaupte keine fertige APK/IPA oder bestandene Laufzeittests. Dokumentiere Setup, Build-Befehle und verbleibende Anforderungen. Verwende keine erfundenen APIs." }
        if kind == "windows" { return "Technik: C# 5 für .NET Framework 4.8 mit Windows Forms (System.Windows.Forms, System.Drawing). WICHTIG – nur C# 5: KEINE $\"...\"-Strings (nutze String.Format), KEIN ?. oder ?? auf Methoden, KEINE =>-Methoden oder -Eigenschaften, KEIN nameof, KEINE Tupel (a,b), KEIN out var, KEINE lokalen Funktionen. Eine Datei Program.cs mit namespace, [STAThread] static void Main(), Application.EnableVisualStyles() und Application.Run(new MainForm()). Steuerelemente im Code anlegen (kein Designer). Moderne, dunkle Optik (BackColor dunkel, Segoe UI), sinnvolle Abstände, Fenster skalierbar (Anchor/Dock)." }
        if kind == "python" { return "Technik: Python 3 nur mit der Standardbibliothek (für Oberflächen tkinter). Eine Datei main.py mit if __name__ == \"__main__\":. Klare Funktionen, Fehlerbehandlung, deutsche Texte." }
        return "Technik: Web-App, die offline im Browser läuft. Am besten EINE Datei index.html mit eingebettetem <style> und <script> (bei sehr großen Apps zusätzlich style.css und app.js). Keine externen Bibliotheken, keine CDNs, keine Bilder aus dem Netz. Modernes, responsives Design (CSS-Variablen, Flexbox/Grid, dunkles Farbschema, abgerundete Ecken), deutsche Texte, Daten bei Bedarf in localStorage. JavaScript sauber und vollständig (\"use strict\", Ereignisse per addEventListener, alle IDs im HTML vorhanden)."
    }
    var maxOut: Int { brain.local ? (pro ? ProLimits.appMaxOutPro : 5200) : 16000 }
    /// Ganze Datei schreiben lassen; abgeschnittene Antworten werden automatisch fortgesetzt.
    func writeFile(_ context: String, _ path: String, _ instruction: String, _ show: ((String) -> Void)?, _ token: CancelToken) async throws -> String {
        let prompt = context + "\n\n" + instruction + "\n\nAntworte NUR mit dem vollständigen Inhalt der Datei " + path + " in EINEM Codeblock (```" + AppBuilder.lang(path) + " … ```). Keine Erklärungen davor oder danach, keine Platzhalter wie »…« oder »hier Code einfügen«."
        let opt = GenOptions(); opt.maxTokens = maxOut; opt.temperature = 0.25; opt.topP = 0.9; opt.topK = 20
        let text = try await brain.complete(sys, AppBuilder.one(prompt), show, opt, token)
        var code = AppBuilder.extractCode(text)
        var k = 0
        while k < (pro ? ProLimits.appWriteContinuationsPro : 3) && brain.lastFinish == "length" {
            let tail = code.len > 1500 ? code.sub(code.len - 1500) : code
            let soFar = code
            let more = try await brain.complete(sys, AppBuilder.one("Du schreibst die Datei " + path + ". Die Antwort wurde wegen der Längengrenze abgeschnitten. Das bisherige Ende lautet:\n```\n" + tail + "\n```\nSchreibe GENAU ab dieser Stelle weiter (nichts wiederholen). Nur Code in einem Codeblock."), { s in show?(soFar + AppBuilder.extractCode(s)) }, opt, token)
            code = code + AppBuilder.extractCode(more)
            k += 1
        }
        return code.trimEnd() + "\n"
    }
    public static func extractCode(_ text: String?) -> String {
        guard let text = text else { return "" }
        var best: String?
        for m in Rx.matches(text, "```[^\\n]*\\n(.*?)(?:```|$)", .s) { if best == nil || m.group(1).len > best!.len { best = m.group(1) } }
        if let b = best { return b.trimEnd() }
        return text.trimmed
    }
    /// Sucht find in content und ignoriert dabei Leerraum (collapse=true: Leerraum-Folgen = ein Leerzeichen, false: Leerraum ganz entfernen).
    public static func findLoose(_ content: String, _ find: String, _ collapse: Bool) -> (Int, Int)? {
        if content.isEmpty || find.trimmed.isEmpty { return nil }
        var norm = [UInt16]()
        var map = [Int]()
        var ws = false
        let cu = Array(content.utf16)
        for (i, c) in cu.enumerated() {
            let isWs = c == 32 || c == 9 || c == 10 || c == 13 || c == 11 || c == 12 || c == 0xA0
            if isWs { if collapse && !ws && !norm.isEmpty { norm.append(32); map.append(i) }; ws = true }
            else { norm.append(c); map.append(i); ws = false }
        }
        let nf = collapse ? Rx.replace(find.trimmed, "\\s+", " ") : Rx.replace(find, "\\s+", "")
        if nf.len < (collapse ? 12 : 40) { return nil }
        let ns = String(decoding: norm, as: UTF16.self)
        let at = ns.indexOf(nf)
        if at < 0 || ns.indexOf(nf, from: at + 1) >= 0 { return nil }
        let start = map[at], end = map[at + nf.len - 1]
        return (start, end - start + 1)
    }
    static func stripFence(_ t: String) -> String {
        var l = t.rep("\r", "").splitKeep("\n")
        if let f = l.first, f.trimmed.hasPrefix("```") { l.removeFirst() }
        if let f = l.last, f.trimmed.hasPrefix("```") { l.removeLast() }
        return l.joined(separator: "\n")
    }
    /// Suchen/Ersetzen-Bloecke anwenden (wie ein Editor; spart bei grossen Dateien viel Zeit).
    public static func applyEdits(_ content0: String, _ response: String) -> (String, Int) {
        var content = content0
        var applied = 0
        for m in Rx.matches(response, "<<<<<<< ?SUCHEN\\s*\\n(.*?)\\n=======\\s*\\n(.*?)\\n>>>>>>> ?ERSETZEN", .s) {
            let find = stripFence(m.group(1)), repl = stripFence(m.group(2))
            if find.trimmed.isEmpty { continue }
            let at = content.indexOf(find)
            if at >= 0 && content.indexOf(find, from: at + find.len) >= 0 { continue }
            if at < 0 { // tolerant: Leerzeichen am Zeilenanfang/-ende ignorieren
                let lines = content.splitKeep("\n")
                let f = find.splitKeep("\n").map { $0.trimmed }
                var match = -1, matches = 0
                var i = 0
                while i + f.count <= lines.count {
                    var ok = true
                    for j in 0..<f.count where lines[i + j].trimmed != f[j] { ok = false; break }
                    if ok { match = i; matches += 1 }
                    i += 1
                }
                if matches == 1 {
                    let start = lines.prefix(match).reduce(0) { $0 + $1.len + 1 }
                    let len = lines.dropFirst(match).prefix(f.count).reduce(0) { $0 + $1.len + 1 } - 1
                    content = content.sub(0, start) + repl + content.sub(min(content.len, start + len))
                    applied += 1; continue
                }
                // 4.14: noch toleranter – Leerzeichen ganz ignorieren. Nur bei eindeutigem Treffer.
                var la = findLoose(content, find, true)
                if la == nil { la = findLoose(content, find, false) }
                if let (s, l) = la { content = content.sub(0, s) + repl + content.sub(s + l); applied += 1 }
                continue
            }
            content = content.sub(0, at) + repl + content.sub(at + find.len)
            applied += 1
        }
        return (content, applied)
    }
    func check(_ p: AppProject, _ res: AppResult, _ token: CancelToken) async throws -> [String] {
        if let o = checkOverride { res.checked = true; return try await o(p, token) }
        var errs = [String]()
        if p.kind == "web" {
            errs += AppChecks.webStatic(p); res.checked = true; res.checkInfo = "Code geprüft"
            if errs.isEmpty, let rt = AppChecks.webRuntime {
                do { if let r = try await rt(p.entryPath, token) { errs += r; res.checkInfo = "im Browser getestet" } }
                catch { if error.isCancellation { throw error } }
            }
        } else if p.kind == "windows" {
            // iOS: kein C#-Compiler. Ehrlich melden statt einen Build vorzutaeuschen.
            res.checkInfo = "C#-Compiler gibt es auf dem iPhone nicht – Quellcode gespeichert, nicht übersetzt und nicht gestartet (auf einem Windows-PC mit VYRA übersetzbar)"
            return errs
        } else if p.kind == "python" {
            res.checkInfo = "Python gibt es auf dem iPhone nicht – nicht geprüft und nicht gestartet"
            return errs
        }
        if p.kind == "source" { res.checked = false; res.checkInfo = "Quellcodedateien gespeichert; kein SDK-/Plattform-Build ausgefuehrt" }
        return errs
    }
    func filesContext(_ p: AppProject, _ budget: Int, _ focus: [String]?) -> String {
        let foc = Set((focus ?? []).map { $0.lowercased() })
        var b = "Projekt »" + p.name + "« (" + AppProject.kindName(p.kind) + "), Start: " + p.entry + "\n"
        if !p.summary.isEmpty { b += "Beschreibung: " + p.summary + "\n" }
        b += "Dateien: " + p.files.map { $0.path + " (\($0.content.len) Zeichen)" }.joined(separator: ", ") + "\n\n"
        for f in p.files.stableSorted(by: { (foc.contains($0.path.lowercased()) ? 0 : 1) < (foc.contains($1.path.lowercased()) ? 0 : 1) }) {
            if b.len + f.content.len + 60 > budget && !foc.contains(f.path.lowercased()) { continue }
            var c = f.content
            if b.len + c.len + 60 > budget { c = c.sub(0, max(0, budget - b.len - 200)) + "\n[… gekürzt]" }
            b += "### " + f.path + "\n```" + AppBuilder.lang(f.path) + "\n" + c + "\n```\n\n"
        }
        return b
    }
    // 4.15: Sicherung einer gepruefbaren Fassung, damit eine schlechtere Reparatur nie das Ergebnis wird.
    final class Snapshot { var files: [AppFile]; var built: String; var errors: Int; var errs: [String]
        init(_ f: [AppFile], _ b: String, _ e: [String]) { files = f; built = b; errors = e.count; errs = e } }
    static func take(_ p: AppProject, _ errs: [String]) -> Snapshot { Snapshot(p.files.map { AppFile($0.path, $0.content, $0.purpose) }, p.built, errs) }
    static func restore(_ p: AppProject, _ s: Snapshot) { p.files = s.files.map { AppFile($0.path, $0.content, $0.purpose) }; p.built = s.built }
    func checkAll(_ p: AppProject, _ res: AppResult, _ token: CancelToken) async throws -> [String] {
        var found = try await check(p, res, token)
        if pro && res.checked { found += ProLimits.placeholders(p) }
        return found
    }
    /// Reparaturrunden. review=true: Luecken aus der Pro-Funktionspruefung ergaenzen (zaehlt nicht als behobener Fehler).
    func repair(_ p: AppProject, _ res: AppResult, _ errs0: [String], _ rounds: Int, _ budget: Int, _ review: Bool, _ token: CancelToken) async throws -> [String] {
        var errs = errs0
        var repairStates = Set<String>()
        var best: Snapshot? = res.checked && !review ? AppBuilder.take(p, errs) : nil
        var round = 1
        while round <= rounds && !errs.isEmpty && res.checked {
            try token.check()
            let state = SHA256Hasher.hex(errs.sorted().joined(separator: "\n") + "\n" + p.files.map { $0.path + "\n" + $0.content }.joined(separator: "\n"))
            if !repairStates.insert(state).inserted {
                let unchanged = begin("check", "Keine Fortschritte bei der Reparatur")
                end(unchanged, "Gleicher Code und gleiche Fehler; weitere identische Versuche gestoppt", true)
                res.problems.append("Wiederholte Reparaturen ohne Fortschritt wurden gestoppt.")
                break
            }
            let sf = begin("fix", review ? "Fehlende Funktionen ergänzen" : "Fehler beheben (Runde \(round)" + (rounds > 5 ? "/\(rounds)" : "") + ")")
            let before = errs.count
            // Fehler den Dateien zuordnen
            var byFile = [(AppFile, [String])]()
            for e in errs {
                var f = p.files.first { e.lowercased().hasPrefix($0.path.lowercased()) || e.lowercased().hasPrefix(FS.fileName($0.path).lowercased()) }
                if f == nil { f = p.get(p.entry) ?? p.files[0] }
                if let i = byFile.firstIndex(where: { $0.0 === f! }) { byFile[i].1.append(e) } else { byFile.append((f!, [e])) }
            }
            for (f, items) in byFile {
                let list = items.map { "- " + $0 }.joined(separator: "\n")
                let ctx = filesContext(p, budget, [f.path])
                var instr = review ? "Bei der Prüfung gegen die Anforderungen fehlt in " + f.path + " noch:\n" + list + "\n\nErgänze das vollständig und korrekt. Alles, was schon funktioniert, bleibt unverändert erhalten.\n" + rules(p.kind)
                    : "Beim automatischen Test von " + f.path + " wurden diese Fehler gefunden:\n" + list + "\n\nBehebe ALLE Fehler. Ändere sonst nichts am Verhalten.\n" + rules(p.kind)
                if pro { instr += "\nLies jede Meldung genau: Zeilennummern beziehen sich auf die aktuelle Datei. Behebe die Ursache, nicht nur das Symptom." }
                if f.content.len > 7000 {
                    let o = GenOptions(); o.maxTokens = min(maxOut, pro ? 5000 : 3000); o.temperature = 0.15; o.topP = 0.9
                    let resp = try await brain.complete(sys, AppBuilder.one(ctx + "\n\n" + instr + "\n\nAntworte NUR mit Änderungsblöcken:\n<<<<<<< SUCHEN\nalter Code\n=======\nneuer Code\n>>>>>>> ERSETZEN"), nil, o, token)
                    let (nc, applied) = AppBuilder.applyEdits(f.content, resp)
                    if applied > 0 { f.content = nc; continue }
                }
                f.content = try await writeFile(ctx, f.path, instr, nil, token)
            }
            try p.save()
            do { errs = try await checkAll(p, res, token) }
            catch { if error.isCancellation { throw error }; errs = ["Pruefung fehlgeschlagen: " + error.vyraMessage]; res.checked = false; res.checkInfo = errs[0] }
            if res.checked && !review { res.fixed += max(0, before - errs.count) }
            end(sf, !res.checked ? res.checkInfo : errs.isEmpty ? (review ? "ergänzt, keine Fehler" : "alle Fehler behoben") : "\(errs.count) Fehler übrig", !errs.isEmpty)
            if let b = best, res.checked && errs.count < b.errors { best = AppBuilder.take(p, errs) }
            round += 1
        }
        if let b = best, res.checked && errs.count > b.errors {
            let sb = begin("check", "Beste geprüfte Fassung wiederherstellen")
            AppBuilder.restore(p, b); try p.save()
            do { errs = try await checkAll(p, res, token) } catch { if error.isCancellation { throw error }; errs = b.errs }
            res.problems.append("Eine Reparatur hätte mehr Fehler verursacht; die beste geprüfte Fassung wurde wiederhergestellt.")
            end(sb, errs.isEmpty ? "keine Fehler" : "\(errs.count) Fehler", !errs.isEmpty)
        }
        return errs
    }
    /// Pro: prueft die fertige, fehlerfreie App gegen die geplanten Funktionen und ergaenzt echte Luecken.
    func review(_ p: AppProject, _ res: AppResult, _ request: String, _ budget: Int, _ token: CancelToken) async throws -> [String] {
        let sr = begin("check", "Funktionen prüfen (Pro)")
        var missing = [String]()
        do {
            if let ro = reviewOverride { missing = try await ro(p, token) }
            else {
                let schema = AppBuilder.obj(("type", "object"), ("properties", AppBuilder.obj(("fehlend", AppBuilder.obj(("type", "array"), ("maxItems", 6.0), ("items", AppBuilder.obj(("type", "object"), ("properties", AppBuilder.obj(("datei", AppBuilder.obj(("type", "string"))), ("funktion", AppBuilder.obj(("type", "string"))), ("was", AppBuilder.obj(("type", "string"))))), ("required", ["datei", "funktion", "was"] as [Any]))))))), ("required", ["fehlend"] as [Any]))
                let prompt = filesContext(p, budget, [p.entry]) + "\nAnforderung des Nutzers: " + request + "\n" + (p.summary.isEmpty ? "" : "Geplant: " + p.summary + "\n") + "\nPrüfe den Code wie ein strenger Senior-Entwickler: Welche geforderten oder geplanten Funktionen fehlen oder sind nur angedeutet (leere Methoden, Platzhalter, Knöpfe ohne Wirkung, nie aufgerufener Code, nicht gespeicherte Daten)? Nenne NUR echte, eindeutige Lücken mit Datei – keine Stilfragen und keine neuen Wunschideen. Wenn alles umgesetzt ist, gib eine leere Liste zurück. Antworte NUR mit JSON: {\"fehlend\":[{\"datei\":\"index.html\",\"funktion\":\"…\",\"was\":\"was genau fehlt\"}]}"
                let o = Researcher.jsonIn(try await brain.complete(sys, AppBuilder.one(prompt), nil, GenOptions.structured(schema, 900), token))
                for x in Json.arr(o, "fehlend").prefix(6) {
                    let path = AppBuilder.cleanPath(Json.str(x, "datei"))
                    var f = path != nil ? p.get(path!) : nil
                    if f == nil { f = p.get(p.entry) }
                    let what = (Json.str(x, "funktion").trimmed + " – " + Json.str(x, "was").trimmed).trim(" –")
                    if what.len < 4 || f == nil { continue }
                    missing.append(f!.path + ": Fehlende oder unvollständige Funktion: " + what)
                }
            }
        } catch {
            if error.isCancellation { throw error }
            end(sr, "übersprungen (" + error.vyraMessage + ")", false); return []
        }
        if missing.isEmpty { end(sr, "alle geplanten Funktionen vorhanden", false); return [] }
        end(sr, "\(missing.count)" + (missing.count == 1 ? " Lücke" : " Lücken") + " gefunden", false)
        let before = AppBuilder.take(p, [])
        var errs = try await repair(p, res, missing, 1, budget, true, token)
        if res.checked && !errs.isEmpty { errs = try await repair(p, res, errs, 3, budget, false, token) }
        if !res.checked || !errs.isEmpty {
            let sb = begin("check", "Ergänzung verwerfen")
            AppBuilder.restore(p, before); try p.save()
            do { errs = try await checkAll(p, res, token) } catch { if error.isCancellation { throw error }; errs = []; res.problems.append(error.vyraMessage) }
            res.problems.append("Pro-Funktionsprüfung: Die Ergänzung hätte neue Fehler verursacht und wurde verworfen; die fehlerfreie Fassung bleibt.")
            end(sb, "fehlerfreie Fassung behalten", false)
            return errs
        }
        res.checkInfo += ", Pro-Funktionsprüfung: \(missing.count)" + (missing.count == 1 ? " Lücke" : " Lücken") + " ergänzt"
        return errs
    }
    public func build(_ request: String, _ existing: AppProject?, _ onText: ((String) -> Void)?, _ token: CancelToken) async throws -> AppResult {
        let res = AppResult()
        let edit = existing != nil && !existing!.files.isEmpty
        let p = edit ? existing! : AppProject()
        var budget = max(4000, brain.contextChars - Int(Double(maxOut) * 2.9) - sys.len - 800)
        if !brain.local { budget = max(budget, 60000) }
        var live = ""
        func showFile(_ path: String, _ code: String) { onText?(live + "### " + path + "\n```" + AppBuilder.lang(path) + "\n" + code + "\n```\n") }
        var toWrite = [AppFile]()
        var changeNotes = [String: String]()
        // 1. Planen
        let sp = begin("plan", edit ? "Änderungen planen" : "App planen")
        do {
            if !edit {
                let hint = AppBuilder.kindHint(request)
                let fileItem = AppBuilder.obj(("type", "object"), ("properties", AppBuilder.obj(("pfad", AppBuilder.obj(("type", "string"))), ("zweck", AppBuilder.obj(("type", "string"))))), ("required", ["pfad", "zweck"] as [Any]))
                let schema = AppBuilder.obj(("type", "object"), ("properties", AppBuilder.obj(("name", AppBuilder.obj(("type", "string"))), ("art", AppBuilder.obj(("type", "string"), ("enum", ["web", "windows", "python", "source"] as [Any]))), ("beschreibung", AppBuilder.obj(("type", "string"))), ("funktionen", AppBuilder.obj(("type", "array"), ("items", AppBuilder.obj(("type", "string"))), ("maxItems", Double(pro ? 20 : 12)))),
                    ("dateien", AppBuilder.obj(("type", "array"), ("minItems", 1.0), ("maxItems", Double(fileCap)), ("items", fileItem))))), ("required", ["name", "art", "beschreibung", "dateien"] as [Any]))
                let ask = "Der Nutzer möchte eine App: " + request + "\n\nPlane die App wie ein erfahrener Entwickler. Wähle die Art: »web« (HTML/CSS/JavaScript im Browser – Standard für Apps, Spiele, Rechner und Tools mit Oberfläche), »windows« (nur wenn ausdrücklich ein Windows-Programm/.exe/C# gewünscht ist), »python« (nur wenn Python gewünscht ist)." + (hint != nil ? " Der Nutzer hat ausdrücklich »" + hint! + "« gemeint. Bei source: verwende die angeforderte native Sprache, die passenden Projektdateien und Build-Konfigurationen; kein Ersatz durch HTML." : "") + " Lege so WENIGE Dateien wie möglich an (web: meist nur index.html; windows: Program.cs; python: main.py). Liste die wichtigsten Funktionen auf. " + (pro ? " Pro: Plane wie ein Senior-Entwickler – alle Funktionen, die der Nutzer erwartet (auch naheliegende wie Speichern, Fehlermeldungen, Tastaturbedienung), konkret und prüfbar formuliert." : "") + " Antworte NUR mit JSON: {\"name\":\"kurzer App-Name\",\"art\":\"web\",\"beschreibung\":\"ein Satz\",\"funktionen\":[\"…\"],\"dateien\":[{\"pfad\":\"index.html\",\"zweck\":\"…\"}]}"
                let plan = try await brain.complete(sys, AppBuilder.one(ask), nil, GenOptions.structured(schema, pro ? 1200 : 600), token)
                let o = Researcher.jsonIn(plan)
                p.name = Json.str(o, "name").trimmed
                if p.name.isEmpty { p.name = ChatStore.makeTitle(request) }
                p.kind = hint ?? Json.str(o, "art")
                if !["windows", "python", "source"].contains(p.kind) { p.kind = "web" }
                let feats = Json.arr(o, "funktionen").map { Json.text($0) }.filter { !$0.trimmed.isEmpty }
                p.summary = Json.str(o, "beschreibung").trimmed + (feats.isEmpty ? "" : " Funktionen: " + feats.prefix(pro ? 20 : 12).joined(separator: "; ") + ".")
                for x in Json.arr(o, "dateien").prefix(fileCap) {
                    guard let path = AppBuilder.cleanPath(Json.str(x, "pfad")), !toWrite.contains(where: { $0.path.lowercased() == path.lowercased() }) else { continue }
                    if p.kind == "windows" && !path.hasSuffix(".cs") { continue }
                    if p.kind == "python" && !path.hasSuffix(".py") { continue }
                    toWrite.append(AppFile(path, "", Json.str(x, "zweck")))
                }
                var sourceEntry = CodePlatform.entry(request)
                if let sf = toWrite.first(where: { $0.path.lowercased().hasSuffix(FS.ext(sourceEntry).lowercased()) }) { sourceEntry = sf.path }
                let entry = p.kind == "source" ? sourceEntry : p.kind == "windows" ? "Program.cs" : p.kind == "python" ? "main.py" : "index.html"
                if !toWrite.contains(where: { $0.path.lowercased() == entry.lowercased() }) {
                    if toWrite.count >= fileCap { toWrite.removeLast() }
                    toWrite.insert(AppFile(entry, "", "Startdatei"), at: 0)
                }
                // Startdatei zuerst, damit weitere Dateien dazu passen; Web: HTML zuletzt, wenn eigene CSS/JS-Dateien existieren
                if p.kind == "web" && toWrite.count > 1, let i = toWrite.firstIndex(where: { $0.path.lowercased() == entry.lowercased() }) { let h = toWrite.remove(at: i); toWrite.append(h) }
                p.entry = entry
                p.files += toWrite
                let baseFolder = FS.join(appsRoot, DocWriter.safeName(p.name))
                var folder = baseFolder
                var k = 2
                while FS.isDir(folder) { folder = baseFolder + " (\(k))"; k += 1 }
                p.folder = folder
                end(sp, AppProject.kindName(p.kind) + " · \(toWrite.count)" + (toWrite.count == 1 ? " Datei" : " Dateien"), false)
            } else {
                let item = AppBuilder.obj(("type", "object"), ("properties", AppBuilder.obj(("pfad", AppBuilder.obj(("type", "string"))), ("was", AppBuilder.obj(("type", "string"))))), ("required", ["pfad", "was"] as [Any]))
                let schema = AppBuilder.obj(("type", "object"), ("properties", AppBuilder.obj(("zusammenfassung", AppBuilder.obj(("type", "string"))), ("aenderungen", AppBuilder.obj(("type", "array"), ("maxItems", Double(fileCap)), ("items", item))))), ("required", ["aenderungen"] as [Any]))
                let plan = try await brain.complete(sys, AppBuilder.one(filesContext(p, min(budget, 9000), nil) + "\nWunsch des Nutzers: " + request + "\n\nWelche Dateien müssen geändert oder neu angelegt werden? Antworte NUR mit JSON: {\"zusammenfassung\":\"…\",\"aenderungen\":[{\"pfad\":\"index.html\",\"was\":\"genaue Beschreibung der Änderung\"}]}"), nil, GenOptions.structured(schema, pro ? 1000 : 500), token)
                let o = Researcher.jsonIn(plan)
                for x in Json.arr(o, "aenderungen").prefix(fileCap) {
                    guard let path = AppBuilder.cleanPath(Json.str(x, "pfad")) else { continue }
                    var f = p.get(path)
                    if f == nil { f = AppFile(path, "", Json.str(x, "was")); p.files.append(f!) }
                    if !toWrite.contains(where: { $0 === f! }) { toWrite.append(f!) }
                    changeNotes[path.lowercased()] = Json.str(x, "was")
                }
                if toWrite.isEmpty { let f = p.get(p.entry) ?? p.files[0]; toWrite.append(f); changeNotes[f.path.lowercased()] = request }
                end(sp, "\(toWrite.count)" + (toWrite.count == 1 ? " Datei" : " Dateien") + " ändern", false)
            }
        } catch {
            if error.isCancellation { throw error }
            end(sp, error.vyraMessage, true)
            if !edit {
                p.name = ChatStore.makeTitle(request); p.kind = AppBuilder.kindHint(request) ?? "web"
                p.entry = p.kind == "source" ? CodePlatform.entry(request) : p.kind == "windows" ? "Program.cs" : p.kind == "python" ? "main.py" : "index.html"
                let f = AppFile(p.entry, "", "Startdatei"); p.files.append(f); toWrite.append(f)
                p.folder = FS.join(appsRoot, DocWriter.safeName(p.name) + " " + DE.stamp(Date(), "HHmmss"))
            } else { let f = p.get(p.entry) ?? p.files[0]; toWrite.append(f); changeNotes[f.path.lowercased()] = request }
        }
        // 2. Dateien schreiben
        for f in toWrite {
            try token.check()
            let sw = begin("write", (edit && !f.content.isEmpty ? "Ändere " : "Schreibe ") + f.path)
            let note = changeNotes[f.path.lowercased()]
            let ctx = filesContext(p, budget, [f.path])
            let goal = edit ? "Wunsch des Nutzers: " + request + "\nÄnderung an " + f.path + ": " + (note ?? request) : "Aufgabe des Nutzers: " + request + "\nApp: " + p.name + " – " + p.summary + "\nDiese Datei: " + f.path + " (" + f.purpose + ")"
            let instr = goal + "\n\n" + rules(p.kind) + "\nSchreibe produktionsreifen, vollständigen Code wie ein Profi: durchdachte Bedienung, alle genannten Funktionen wirklich umgesetzt, Fehlerfälle abgefangen, kurze Kommentare." + (pro ? "\n" + ProLimits.codeCraft : "")
            if edit && f.content.len > 7000 {
                // grosse Datei: nur Suchen/Ersetzen-Bloecke
                let o = GenOptions(); o.maxTokens = maxOut; o.temperature = 0.2; o.topP = 0.9
                let liveNow = live
                let resp = try await brain.complete(sys, AppBuilder.one(ctx + "\n\n" + instr + "\n\nDie Datei ist groß. Antworte NUR mit Änderungsblöcken in genau diesem Format (SUCHEN muss exakt im aktuellen Code vorkommen):\n<<<<<<< SUCHEN\nalter Code\n=======\nneuer Code\n>>>>>>> ERSETZEN"), { s in onText?(liveNow + "### " + f.path + " (Änderungen)\n```\n" + s + "\n```\n") }, o, token)
                let (nc, applied) = AppBuilder.applyEdits(f.content, resp)
                if applied > 0 { f.content = nc; end(sw, "\(applied) Stellen geändert", false); live += "### " + f.path + "\n*\(applied) Stellen geändert.*\n\n"; continue }
            }
            let code = try await writeFile(ctx, f.path, instr, { s in showFile(f.path, AppBuilder.extractCode(s)) }, token)
            f.content = code
            end(sw, "\(code.splitKeep("\n").count) Zeilen", false)
            live += "### " + f.path + "\n```" + AppBuilder.lang(f.path) + "\n" + (code.len > 6000 ? code.sub(0, 6000) + "\n…" : code) + "\n```\n\n"
            onText?(live)
        }
        try p.save()
        // 3. Pruefen und Fehler beheben (Standard bis zu 5, Pro bis zu 8 Runden, mit Fortschrittspruefung und Rueckfall auf die beste Fassung)
        let sc = begin("check", "Selbst prüfen")
        var errs: [String]
        do {
            errs = try await check(p, res, token)
            if pro && res.checked { errs += ProLimits.placeholders(p) }
        } catch {
            if error.isCancellation { throw error }
            errs = ["Pruefung fehlgeschlagen: " + error.vyraMessage]; res.checked = false; res.checkInfo = errs[0]; res.problems.append(error.vyraMessage)
        }
        end(sc, res.checked ? (errs.isEmpty ? "keine Fehler (" + res.checkInfo + ")" : "\(errs.count) Fehler gefunden") : res.checkInfo, !errs.isEmpty)
        errs = try await repair(p, res, errs, pro ? ProLimits.appRepairsPro : 5, budget, false, token)
        // 3b. Pro: gegen die Anforderungen pruefen und Luecken ergaenzen – nur behalten, wenn danach alles fehlerfrei bleibt.
        if pro && res.checked && errs.isEmpty { errs = try await review(p, res, request, budget, token) }
        res.remaining = errs; res.project = p
        // 4. Ergebnis
        var a = "## " + p.name + "\n\n" + (p.summary.isEmpty ? AppProject.kindName(p.kind) : p.summary) + "\n\n"
        a += "**Art:** " + AppProject.kindName(p.kind) + "  \n**Ordner:** VYRA KI › Apps › " + FS.fileName(p.folder) + "\n\n"
        if res.checked {
            a += errs.isEmpty ? "✅ **Selbst geprüft:** keine Fehler gefunden (" + res.checkInfo + ")" + (res.fixed > 0 ? ", dabei \(res.fixed) Fehler automatisch behoben" : "") + ".\n\n"
                : "⚠️ **Noch \(errs.count) Problem(e):**\n" + errs.prefix(6).map { "- " + $0 }.joined(separator: "\n") + "\n\nSchreib mir einfach »Behebe die Fehler«, dann versuche ich es weiter.\n\n"
        } else { a += "ℹ️ " + res.checkInfo + ".\n\n" }
        var seen = Set<String>()
        for problem in res.problems where seen.insert(problem).inserted && seen.count <= 4 { a += "Hinweis: " + problem + "\n\n" }
        for f in (edit ? toWrite : p.files) {
            let c = f.content
            a += "### " + f.path + "\n```" + AppBuilder.lang(f.path) + "\n" + (c.len > 14000 ? c.sub(0, 14000) + "\n… (vollständig in der Datei)" : c.trimEnd()) + "\n```\n\n"
        }
        a += edit ? "Die Aenderungen liegen im Projektordner." : (p.kind == "web" ? "Starte die App mit dem Knopf unten. Weitere Aenderungen kannst du im selben Chat beschreiben." : "Die Dateien liegen im Projektordner (teilen oder als ZIP exportieren). Weitere Aenderungen kannst du im selben Chat beschreiben.")
        res.answer = a
        return res
    }
}

// ---------------------------------------------------------------- Aufgaben erkennen (wie ein Assistent, der selbst entscheidet, was zu tun ist)
public enum TaskRouter {
    /// "app" = App-Studio, "doc:pdf"/"doc:docx"/"doc:md" = Dokument mit Recherche, "book" = Buch-Studio, sonst nil (normaler Chat)
    public static func route(_ q: String) -> String? {
        // 4.15: Ganze Buecher (auch "als PDF") gehen ins Buch-Studio.
        if BookWriter.wants(q) { return "book" }
        let f = FileFormats.detect(q)
        // Ausdruecklich gewuenschte Dateien (Excel, PowerPoint, PDF, JSON ...) haben Vorrang vor dem App-Studio.
        if let f = f, FileFormats.kind(f) != "raw" || !AppBuilder.wantsApp(q) { return "doc:" + f }
        if AppBuilder.wantsApp(q) { return "app" }
        return nil
    }
}
