import Foundation

/// 4.15: Grenzen nur fuer VYRA Pro. Standard und Mini behalten ihre Werte. (unveraendert aus VYRA.GXCore.cs)
public enum ProLimits {
    public static let contextDefault = 16384, contextMax = 32768
    public static let contextChoices = [8192, 16384, 32768]
    public static let continuationsPro = 8, continuationsStandard = 3
    public static let thinkTokensPro = 2048, codeMinTokensPro = 4000
    public static let webPagesPro = 8, webPagesProThink = 12, webSecondsPro = 40
    public static let appFilesPro = 20, appRepairsPro = 8, appMaxOutPro = 8192, appWriteContinuationsPro = 6
    public static let chatMinutesDefault = 60, chatMinutesMin = 10, chatMinutesMax = 240
    public static let workMinutesDefault = 180, workMinutesMin = 30, workMinutesMax = 1440
    public static let bookMinutesDefault = 720, bookMinutesMin = 60, bookMinutesMax = 2880
    public static let extendMinutesPro = 60
    public static let chatMinuteChoices = [10, 20, 30, 60, 120, 240]
    public static let workMinuteChoices = [30, 60, 120, 180, 240, 480, 720, 1440]
    public static let bookMinuteChoices = [120, 240, 480, 720, 1440, 2880]
    /// Antwortlaenge in Token. Der verfuegbare Kontext kann sie weiter begrenzen (FitContext).
    public static func answerTokens(_ style: String, _ local: Bool, _ pro: Bool) -> Int {
        if !pro || !local { return Researcher.styleTokens(style, local) }
        if style == "short" { return 900 }
        if style == "long" { return 7000 }
        return 3600
    }
    public static func context(_ requested: Int) -> Int {
        if requested <= 0 { return contextDefault }
        var best = contextChoices[0]
        for c in contextChoices where c <= requested { best = c }
        return best
    }
    public static func minutes(_ m: Int) -> String {
        if m < 60 { return "\(m) Minuten" }
        if m % 60 == 0 { return "\(m / 60)" + (m == 60 ? " Stunde" : " Stunden") }
        return "\(m / 60) h \(m % 60) min"
    }
    /// Zusatz zum Systemtext, wenn VYRA Pro antwortet.
    public static let persona =
        "Pro-Modus: Du arbeitest auf Expertenniveau – gründlich, genau und vollständig. " +
        "Bei Code denkst du wie ein Senior-Entwickler: erst kurz Aufbau und Datenfluss klären, dann vollständigen, lauffähigen Code ohne Platzhalter schreiben, Randfälle und Fehlerbehandlung einbauen und den Code vor der Antwort gedanklich ausführen. " +
        "Bei Texten achtest du auf roten Faden, Stil und Stimmigkeit. Bei Fakten trennst du Sicheres von Unsicherem. " +
        "Lange Aufgaben erledigst du vollständig statt sie abzukürzen."
    public static let codeCraft =
        "Pro-Qualität: Kläre zuerst Datenmodell, Zustände und Abläufe. Setze jede geplante Funktion vollständig um – keine Platzhalter, kein TODO, keine »vereinfachte Version«. " +
        "Prüfe gedanklich jeden Klick- und Eingabepfad und Randfälle (leere Eingaben, ungültige Zahlen, fehlende Dateien, sehr große Werte). " +
        "Jeder Name, jede ID und jede Methode, die du benutzt, muss auch definiert sein. Benutze nur Funktionen, die es in der Plattform wirklich gibt."
    public static let windowsRules =
        "Technik: Windows-Programm in C# für .NET Framework 4.8 mit Windows Forms. VYRA übersetzt es mit dem Windows-eigenen C#-Compiler, der NUR C# 5 kennt.\n" +
        "Verboten (erst ab C# 6): $\"…\"-Zeichenketten (String.Format oder + nutzen), ?. und ?[ , => bei Methoden oder Eigenschaften (Lambdas wie (s, e) => … sind erlaubt), nameof, Eigenschafts-Initialisierer ({ get; set; } = …), { get; } ohne set, Tupel, out var, Muster wie »x is Typ name«, switch-Ausdrücke, lokale Funktionen, await in catch/finally, using static, »default« ohne Typ, ?? throw, Zahlen mit _.\n" +
        "Aufbau: namespace mit dem App-Namen; static class Program mit [STAThread] static void Main(): Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false); Application.ThreadException += … und AppDomain.CurrentDomain.UnhandledException += … (Fehler verständlich per MessageBox zeigen); Application.Run(new MainForm()).\n" +
        "Oberfläche: Steuerelemente im Code anlegen (kein Designer). Layout mit TableLayoutPanel, FlowLayoutPanel, Dock und Anchor, damit das Fenster skalierbar bleibt; MinimumSize setzen. Schrift Segoe UI 10, modernes dunkles Design (BackColor 30,31,38; ForeColor WhiteSmoke; Buttons mit FlatStyle.Flat und Akzentfarbe), klare Abstände (Padding/Margin), Tastaturkürzel (AcceptButton, &Beschriftung) und ToolTips, wo sie helfen.\n" +
        "Qualität: Eingaben prüfen (TryParse, leere Felder), Datei- und Netzwerkzugriffe in try/catch mit verständlicher Meldung. Daten im Ordner Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData)\\<AppName> speichern. Lange Arbeiten mit Task.Run, Ergebnisse per Invoke/BeginInvoke anzeigen – die Oberfläche darf nie einfrieren. Für Spiele und Animationen DoubleBuffered = true und System.Windows.Forms.Timer.\n" +
        "Verfügbar sind nur .NET-Framework-Bibliotheken: System, System.Core (LINQ), System.Drawing, System.Windows.Forms, System.Data, System.Xml, System.Xml.Linq, System.Net.Http, System.IO.Compression, System.Web.Extensions (JavaScriptSerializer für JSON), System.Windows.Forms.DataVisualization (Diagramme), System.Management, Microsoft.VisualBasic. Keine NuGet-Pakete.\n" +
        "Beim Start nichts löschen, nichts herunterladen und keine Systemeinstellungen ändern: VYRA startet das Programm zum Test kurz automatisch."
    // Platzhalter, die ein Profi nie ausliefert.
    static let rxPlaceholder = "(\\bTODO\\b|\\bFIXME\\b|NotImplementedException|raise NotImplementedError|hier (kommt|folgt|steht|den|deinen|ihren|eigenen) (der |dein |ihr )?(code|logik|implementierung)|(code|logik|implementierung) (hier )?(einfügen|ergaenzen|ergänzen|folgt)|rest (des|der) (codes?|logik|implementierung)|implement (this|me|here)|your code here|add (your )?(logic|code) here)"
    static let rxEllipsisComment = "^\\s*(//|#|<!--|/\\*)\\s*(\\.\\.\\.|…)\\s*(-->|\\*/)?\\s*$"
    /// Liefert Fehlermeldungen im Format "Datei Zeile N: ...".
    public static func placeholders(_ p: AppProject?) -> [String] {
        var found = [String]()
        guard let p = p else { return found }
        for f in p.files {
            if f.content.isEmpty { continue }
            let ext = FS.ext(f.path).lowercased()
            if ext == ".md" || ext == ".txt" || ext == ".json" { continue }
            let lines = f.content.rep("\r", "").splitKeep("\n")
            for (i, l) in lines.enumerated() where found.count < 8 {
                if l.len > 400 { continue }
                if Rx.isMatch(l, rxPlaceholder, .i) || Rx.isMatch(l, rxEllipsisComment) {
                    let t = l.trimmed
                    found.append(f.path + " Zeile \(i + 1): Platzhalter statt fertigem Code (»" + (t.len > 80 ? t.sub(0, 80) + "…" : t) + "«) – vollständig umsetzen.")
                    break
                }
            }
        }
        return found
    }
}
