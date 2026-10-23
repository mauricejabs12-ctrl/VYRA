import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class GeneratedPicture { public var path = "", kind = "", provider = "" }

/// Bilder erstellen (aus `ImageWork`): SVG-Vektorbilder mit dem gewaehlten Chatmodell (auch lokal) oder – optional –
/// PNG ueber den OpenAI-Bilddienst mit eigenem API-Schluessel. Keine vorgetaeuschten Fotos.
public enum ImageWork {
    public static let defaultModel = "gpt-image-2.5-flare"
    public static func wants(_ q: String) -> Bool {
        let n = Knowledge.norm(q)
        return !AppBuilder.wantsApp(q) && !BookWriter.wants(q) && Rx.isMatch(n, "^(?:bitte\\s+)?(?:erstelle|erstell|erzeuge|generiere|zeichne|male|mach|mache|entwirf)\\w*\\b.{0,100}\\b(?:bild|foto|portrait|portraet|illustration|vektorgrafik|svg|logo|icon|hintergrundbild)\\b")
    }
    public static func choose(_ setting: String, _ prompt: String, _ key: Bool) throws -> String {
        if setting == "openai" {
            if !key { throw VyraError("Fuer das Bildmodell einen eigenen OpenAI-API-Schluessel in den KI-Einstellungen hinterlegen. Vektorbilder funktionieren mit dem gewaehlten Chatmodell.", .invalidOperation) }
            return "openai"
        }
        if setting != "svg" && key && !Rx.isMatch(Knowledge.norm(prompt), "\\b(?:svg|vektor\\w*|logo|icon)\\b") { return "openai" }
        if Rx.isMatch(Knowledge.norm(prompt), "\\b(?:fotorealistisch\\w*|foto|fotografie|realistisches foto|png)\\b") {
            throw VyraError("Fuer Fotos und generierte PNG-Bilder fehlt ein angeschlossenes Bildmodell. In Einstellungen > Bilder OpenAI waehlen und einen eigenen API-Schluessel hinterlegen. Ohne Bildmodell kann VYRA eine echte SVG-Vektorzeichnung erstellen.", .invalidOperation)
        }
        return "svg"
    }
    static let tags: Set<String> = ["svg", "g", "rect", "circle", "ellipse", "line", "polyline", "polygon", "path", "text", "tspan", "defs", "linearGradient", "radialGradient", "stop", "clipPath", "title", "desc"]
    static let attributes: Set<String> = ["xmlns", "id", "viewBox", "width", "height", "x", "y", "x1", "x2", "y1", "y2", "cx", "cy", "r", "rx", "ry", "d", "points", "fill", "fill-rule", "fill-opacity", "stroke", "stroke-width", "stroke-linecap", "stroke-linejoin", "stroke-opacity", "opacity", "transform", "font-family", "font-size", "font-weight", "text-anchor", "dominant-baseline", "offset", "stop-color", "stop-opacity", "gradientUnits", "gradientTransform", "fx", "fy", "clip-path", "preserveAspectRatio"]
    /// Prueft und bereinigt ein SVG: nur erlaubte Elemente/Attribute, keine externen oder aktiven Inhalte.
    public static func safeSvg(_ text: String) throws -> String {
        if text.len > 200_000 { throw VyraError("SVG fehlt oder ist zu gross.", .invalidData) }
        let a = text.indexOf("<svg", ignoreCase: true), b = text.lastIndexOf("</svg>", ignoreCase: true)
        if a < 0 || b < a { throw VyraError("Die KI hat kein vollstaendiges SVG-Bild geliefert.", .invalidData) }
        let svg = text.sub(a, b + 6 - a)
        let root: XmlNode
        do { root = try XmlDom.parse(Data(svg.utf8)) } catch { throw VyraError("Das SVG-Bild ist kein gueltiges XML.", .invalidData) }
        guard let top = root.children.first(where: { $0.name != "#text" }), top.localName == "svg" else { throw VyraError("Kein SVG-Bild.", .invalidData) }
        if top.attributes["xmlns"] != "http://www.w3.org/2000/svg" { throw VyraError("SVG-Namensraum fehlt.", .invalidData) }
        var count = 0
        func check(_ n: XmlNode) throws {
            if n.name == "#text" { return }
            count += 1
            if count > 240 || !tags.contains(n.name) { throw VyraError("SVG enthaelt unzulaessige Elemente.", .invalidData) }
            for (k, v) in n.attributes {
                if !attributes.contains(k) || v.len > 20000 { throw VyraError("SVG enthaelt unzulaessige Attribute.", .invalidData) }
                let lv = v.lowercased()
                if k != "xmlns" && (lv.contains("http:") || lv.contains("https:") || lv.contains("data:") || lv.contains("javascript:") || lv.contains("expression") || v.contains("<")) { throw VyraError("Externe oder aktive SVG-Inhalte sind nicht erlaubt.", .invalidData) }
                if lv.contains("url(") && !Rx.isMatch(v, "^url\\(#[A-Za-z0-9_-]+\\)$") { throw VyraError("Nur interne SVG-Verweise sind erlaubt.", .invalidData) }
            }
            for c in n.children { try check(c) }
        }
        try check(top)
        return svg
    }
    public static func vector(_ brain: ChatBrain, _ prompt: String, _ folder: String, _ token: CancelToken) async throws -> GeneratedPicture {
        let o = GenOptions(); o.maxTokens = brain.local ? 3000 : 7000; o.temperature = 0.4
        let text = try await brain.complete("Du zeichnest eine saubere SVG-Vektorillustration zum Auftrag. Nur ein SVG-Codeblock. viewBox 0 0 1024 1024 und xmlns http://www.w3.org/2000/svg. Nutze geometrische Formen, Pfade und interne Farbverlaeufe; hoechstens 120 Elemente. Kein script, style, image, foreignObject, use, href, Ereignis, externer Font oder externe Ressource. Kein Fotorealismus behaupten. Setze alle sichtbaren Bestandteile vollstaendig um.", [ChatTurn("user", prompt)], nil, o, token)
        try token.check()
        if brain.lastFinish == "length" || brain.lastFinish == "max_tokens" { throw VyraError("Die Zeichnung wurde abgeschnitten. Es wurde keine unvollstaendige Bilddatei gespeichert.", .invalidData) }
        let svg = try safeSvg(text)
        let file = try DocWriter.uniquePath(folder, "VYRA-Bild-" + DE.stamp(Date(), "yyyyMMdd-HHmmss"), ".svg")
        try FS.write(file, text: svg)
        let g = GeneratedPicture(); g.path = file; g.kind = "SVG-Vektorbild"; g.provider = brain.name
        return g
    }
    public static func decodePng(_ json: String) throws -> Data {
        if json.len > 45_000_000 { throw VyraError("Bildantwort ist zu gross oder fehlt.", .invalidData) }
        let obj = try Json.parse(json)
        guard let value = Json.arr(obj, "data").map({ Json.str($0, "b64_json") }).first, !value.isEmpty, value.len <= 40_000_000, let bytes = Data(base64Encoded: value) else { throw VyraError("Der Bilddienst hat kein Bild geliefert.", .invalidData) }
        let b = [UInt8](bytes)
        if b.count < 33 || Array(b[0..<8]) != [137, 80, 78, 71, 13, 10, 26, 10] || String(decoding: b[12..<16], as: UTF8.self) != "IHDR" { throw VyraError("Der Bilddienst lieferte keine PNG-Datei.", .invalidData) }
        func number(_ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }
        let w = number(16), h = number(20)
        if w < 16 || h < 16 || w > 4096 || h > 4096 || Int64(w) * Int64(h) > 16_777_216 { throw VyraError("Unzulaessige Bildabmessungen.", .invalidData) }
        return bytes
    }
    public static func raster(_ prompt: String, _ key: String, _ model: String, _ folder: String, _ token: CancelToken) async throws -> GeneratedPicture {
        if key.trimmed.isEmpty { throw VyraError("OpenAI-API-Schluessel fehlt.", .invalidOperation) }
        if !Rx.isMatch(model, "^[a-zA-Z0-9._-]{3,100}$") { throw VyraError("Ungueltiger Bildmodellname.", .argument) }
        if prompt.trimmed.isEmpty || prompt.len > 12000 { throw VyraError("Bildauftrag fehlt oder ist zu lang.", .argument) }
        let body = Json.serialize(Json.obj(("model", model), ("prompt", prompt), ("n", 1.0), ("size", "1024x1024"), ("quality", "medium"), ("output_format", "png")))
        let r = try await Http.request(URL(string: "https://api.openai.com/v1/images/generations")!, method: "POST", body: Data(body.utf8), headers: ["Authorization": "Bearer " + key, "Content-Type": "application/json"], timeout: 180, maxBytes: 45_000_000, token: token)
        if !r.ok { throw VyraError("Bilddienst meldet HTTP \(r.status). API-Schluessel, Guthaben und Modellzugriff pruefen; der Auftrag wurde nicht automatisch wiederholt.", .io) }
        let png = try decodePng(r.text)
        try token.check()
        let file = try DocWriter.uniquePath(folder, "VYRA-Bild-" + DE.stamp(Date(), "yyyyMMdd-HHmmss"), ".png")
        try FS.write(file, png)
        let g = GeneratedPicture(); g.path = file; g.kind = "PNG-Bild"; g.provider = model
        return g
    }
}
