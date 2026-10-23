import Foundation

/// Plattformtexte: die wenigen Saetze in den Grundanweisungen, die unter Windows den PC, die Windows-App oder
/// Windows-only-Funktionen nennen. Alles andere an Persona, Antwortstil und Regeln ist woertlich uebernommen.
/// Jede Abweichung steht hier an einer Stelle (siehe docs/FUNKTIONSUEBERSICHT.md).
public enum Platform {
    /// Windows: "Du bist VYRA, die KI der Windows-App »VYRA Gaming Hub«. Du läufst lokal auf dem PC des Nutzers …"
    public static let personaIntro = "Du bist VYRA, die KI der iPhone-App »VYRA KI« (aus dem VYRA Gaming Hub). Du läufst lokal auf dem iPhone des Nutzers und sprichst Deutsch (oder die Sprache des Nutzers), freundlich, ruhig und direkt.\n"
    /// Windows: "- Du kannst nichts heimlich am PC ändern; für Einstellungen nennst du die passende VYRA-Seite. Empfiehl nie, den Virenschutz abzuschalten."
    public static let deviceRule = "- Du kannst nichts heimlich am iPhone ändern; für Einstellungen nennst du die passende Stelle in VYRA oder in den iOS-Einstellungen. Empfiehl nie, Schutzfunktionen (z. B. Virenschutz oder iOS-Sicherheitsfunktionen) abzuschalten.\n"
    /// Windows: "- Wünsche an VYRA selbst (Booster, HUD, Designs, Browser, KI) setzt die Werkstatt geprüft um (Sicherung + Rückgängig). …"
    public static let workshopRule = "- Die Werkstatt (VYRA passt sich selbst an) gibt es nur in der Windows-App; auf dem iPhone kann VYRA ihren eigenen Programmcode nicht ändern. Behaupte nie, etwas sei geändert worden.\n"
    /// Windows: "PC des Nutzers: …"
    public static let deviceLabel = "Gerät des Nutzers: "
    /// Windows (Online-Modelle): "Du bist in die Windows-App »VYRA Gaming Hub« eingebaut (Fortnite-Optimierung, FPS-Booster, HUD, Crosshairs, Webbrowser, Designs). …"
    public static let cloudContext = "\n\nDu bist in die iPhone-App »VYRA KI« eingebaut (die KI aus dem VYRA Gaming Hub). Du kannst nichts am iPhone des Nutzers ändern; für Änderungen nennst du die passende Stelle in VYRA. Empfiehl nie, Schutzfunktionen abzuschalten."
    /// Windows (Online-Modelle): "… programmiert Apps und kann sich auf Wunsch selbst anpassen (Werkstatt). …"
    public static let cloudFiles = "VYRA erstellt Dateien automatisch (Word, PDF, Excel, PowerPoint, SVG, Kalender, Code …) und programmiert Apps. Sag nie, dass du keine Dateien erstellen kannst."
    /// Beschreibung des Geraets fuer den Systemtext (statt PC-Daten unter Windows).
    public static var deviceInfo: String = ""
}

extension Platform {
    /// Ordnerangabe in Antworten: unter iOS als Weg in der Dateien-App (»VYRA KI › Bücher › Titel«) statt eines Windows-Pfads.
    public static func shownPath(_ p: String) -> String {
        let root = DocWriter.defaultFolder
        if FS.isInside(p, root) {
            let rel = FS.relative(p, to: root)
            return (["VYRA KI"] + rel.split(separator: "/").map(String.init)).joined(separator: " › ")
        }
        return p
    }
}

extension Platform {
    /// Schnellhilfe: Windows nennt die VYRA-Seite (»→ In VYRA: Seite »FPS-Booster««). Auf dem iPhone gibt es nur die KI;
    /// alle anderen Seiten gehoeren zur Windows-App und werden so benannt.
    public static func pagePointer(_ page: String) -> String {
        page == "VYRA KI" ? "→ In VYRA KI: Einstellungen und Chat." : "→ In der Windows-App VYRA Gaming Hub: Seite »" + page + "«."
    }
}
