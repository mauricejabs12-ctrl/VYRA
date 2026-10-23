import Foundation

/// Textnormalisierung und Suchwoerter (aus `Knowledge` in VYRA.GXCore.cs). Wird von der Relevanzbewertung (BM25),
/// dem Gedaechtnis, dem Wissens-Booster und der Aufgabenerkennung genutzt.
public enum Knowledge {
    static let stop: Set<String> = Set("der die das den dem des ein eine einer eines einem einen und oder aber auch als am an auf aus bei bin bis bist da dann darf dass dein deine dem den denn der des dich dir doch du durch er es euch fuer gibt hab habe hat hatte ich ihr im in ist ja kann kannst mich mir mit muss nach nicht noch nur ob oft schon sehr sein sich sie sind so soll ueber um und uns unter viel vom von vor war was weil welche welcher welches wenn wer wie wieso warum wird wo wurde zu zum zur mein meine meinen meinem meiner mache machen bitte gerne hallo hey hi mal etwas jetzt immer man einfach geht gehen tun tut kriege kriegen bekomme bekommen moechte will wollen was's".split(separator: " ").map(String.init))
    static let synonyms: [String: String] = [
        "ruckelt": "stotter ruckel frametime", "ruckeln": "stotter ruckel frametime", "stottern": "stotter ruckel frametime", "lag": "ping netzwerk latenz eingabe", "lagt": "ping netzwerk latenz eingabe stotter",
        "laggy": "ping netzwerk latenz", "ping": "ping netzwerk latenz", "fps": "fps bild booster", "frames": "fps bild", "einbrueche": "stotter fps frametime", "drops": "stotter fps",
        "zielkreuz": "crosshair fadenkreuz", "fadenkreuz": "crosshair", "crosshairs": "crosshair", "overlay": "hud", "anzeige": "hud", "design": "design themes farbe", "farbe": "design farbe", "themes": "design",
        "browser": "browser web tab", "internet": "browser web", "werbung": "werbeblocker filter browser", "ki": "nova ki modell", "nova": "nova ki", "neustart": "neustart anmelden", "abmelden": "anmelden neustart",
        "rueckgaengig": "backup sicherung zuruecksetzen", "zuruecksetzen": "backup sicherung", "konto": "konto anmelden passwort", "passwort": "konto passwort", "maus": "eingabe maus", "tastatur": "eingabe",
        "nvidia": "nvidia grafik treiber", "grafikkarte": "nvidia grafik gpu", "speicher": "speicher ram bereinigung", "aufraeumen": "bereinigung temp", "automatisch": "automatik", "optimieren": "optimierung automatik"
    ]
    /// Kleinbuchstaben, Umlaute als ae/oe/ue/ss, alles andere ausser Buchstaben/Ziffern wird Leerzeichen.
    public static func norm(_ s: String) -> String {
        var b = String.UnicodeScalarView()
        for ch in s.lowercased().unicodeScalars {
            switch ch {
            case "ä": b.append("a"); b.append("e")
            case "ö": b.append("o"); b.append("e")
            case "ü": b.append("u"); b.append("e")
            case "ß": b.append("s"); b.append("s")
            default:
                if ch.properties.isAlphabetic || ch.properties.generalCategory == .decimalNumber { b.append(ch) } else { b.append(" ") }
            }
        }
        return String(b)
    }
    public static func stem(_ w: String) -> String {
        if w.len <= 4 { return w }
        for suf in ["ungen", "ung", "heiten", "heit", "keiten", "keit", "ern", "en", "er", "es", "em", "e", "n", "s"] {
            if w.len - suf.len >= 4 && w.hasSuffix(suf) { return String(w.dropLast(suf.count)) }
        }
        return w
    }
    public static func tokens(_ s: String, expand: Bool) -> [String] {
        var r = [String]()
        for w0 in norm(s).split(separator: " ").map(String.init) {
            if stop.contains(w0) || w0.len < 2 { continue }
            r.append(stem(w0))
            if expand, let syn = synonyms[w0] { for x in syn.split(separator: " ") { r.append(stem(String(x))) } }
        }
        return r
    }
}
