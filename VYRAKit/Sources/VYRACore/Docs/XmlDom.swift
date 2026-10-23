import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Kleines XML-Dokumentmodell (ersetzt System.Xml.XmlDocument fuer das Lesen von Office-Dateien).
/// Externe Entitaeten und DTDs werden nicht aufgeloest.
public final class XmlNode {
    public let name: String
    public var localName: String { name.split(separator: ":").last.map(String.init) ?? name }
    public var attributes: [String: String] = [:]
    public var children: [XmlNode] = []
    public var text = ""
    weak var parent: XmlNode?
    init(_ name: String) { self.name = name }
    /// Gesamter Text aller Unterknoten (wie InnerText).
    public var innerText: String {
        var b = text
        for c in children { b += c.innerText }
        return b
    }
    /// Alle Nachfahren mit Namen (wie GetElementsByTagName); "*" = alle.
    public func elements(_ n: String) -> [XmlNode] {
        var out = [XmlNode]()
        func walk(_ x: XmlNode) { for c in x.children { if n == "*" || c.name == n { out.append(c) }; walk(c) } }
        walk(self)
        return out
    }
    public func attr(_ k: String) -> String? { attributes[k] ?? attributes.first { $0.key.split(separator: ":").last.map(String.init) == k }?.value }
}

public enum XmlDom {
    final class Builder: NSObject, XMLParserDelegate {
        let root = XmlNode("#document")
        var cur: XmlNode
        override init() { cur = root }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let n = XmlNode(qName ?? elementName)
            n.attributes = attributeDict
            n.parent = cur
            cur.children.append(n)
            cur = n
        }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            cur = cur.parent ?? root
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            // Text als eigener Knoten, damit die Reihenfolge in innerText stimmt.
            let t = XmlNode("#text"); t.text = string; t.parent = cur; cur.children.append(t)
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            let t = XmlNode("#text"); t.text = String(decoding: CDATABlock, as: UTF8.self); t.parent = cur; cur.children.append(t)
        }
    }
    public static func parse(_ data: Data) throws -> XmlNode {
        let p = XMLParser(data: data)
        let b = Builder()
        p.delegate = b
        p.shouldProcessNamespaces = false
        p.shouldResolveExternalEntities = false
        if !p.parse() { throw VyraError("Ungültiges XML (Zeile \(p.lineNumber)).", .invalidData) }
        return b.root
    }
}
