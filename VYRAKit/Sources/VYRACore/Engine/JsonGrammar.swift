import Foundation

/// Wandelt die JSON-Schemata von VYRA in eine GBNF-Grammatik fuer llama.cpp um.
/// Unter Windows erledigt das llama-server (`response_format: json_schema`); in der iPhone-App laeuft llama.cpp
/// direkt in der App, deshalb uebernimmt dieser Umsetzer dieselbe Aufgabe. Er deckt den Umfang ab, den VYRA nutzt:
/// object (properties, required), array (items, minItems, maxItems), string (enum, minLength, maxLength),
/// integer, number, boolean, null – mit derselben Feldreihenfolge wie im Schema.
public enum JsonGrammar {
    public static func gbnf(_ schema: Any) throws -> String {
        var b = Builder()
        let root = try b.rule(schema, "root")
        if root != "root" { b.add("root", root) }
        return b.render()
    }

    struct Builder {
        var rules: [(String, String)] = []
        var names = Set<String>()
        var counter = 0

        mutating func add(_ name: String, _ body: String) {
            if names.contains(name) { return }
            names.insert(name); rules.append((name, body))
        }
        mutating func fresh(_ base: String) -> String {
            let clean = Rx.replace(base, "[^a-zA-Z0-9-]+", "-").trim("-")
            var n = clean.isEmpty ? "r" : clean
            if names.contains(n) || n == "root" && names.contains("root") { counter += 1; n = "\(n)-\(counter)" }
            return n
        }
        func render() -> String {
            var lines = [String]()
            // root zuerst (fuer Lesbarkeit), dann die uebrigen Regeln
            for (n, b) in rules where n == "root" { lines.append("\(n) ::= \(b)") }
            for (n, b) in rules where n != "root" { lines.append("\(n) ::= \(b)") }
            return lines.joined(separator: "\n") + "\n"
        }
        static func literal(_ s: String) -> String {
            var out = "\""
            for u in s.unicodeScalars {
                switch u {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default: out.unicodeScalars.append(u)
                }
            }
            return out + "\""
        }
        mutating func prim() {
            add("space", "| \" \" | \"\\n\"{1,2} [ \\t]{0,20}")
            add("char", "[^\"\\\\\\x7F\\x00-\\x1F] | [\\\\] ([\"\\\\bfnrt] | \"u\" [0-9a-fA-F]{4})")
        }
        /// Liefert einen Ausdruck (Regelname oder Inline-Ausdruck) fuer `schema`; `hint` dient als Regelname.
        mutating func rule(_ schema: Any, _ hint: String) throws -> String {
            prim()
            guard let s = schema as? JObject else {
                // Kein Schema: beliebiger JSON-Wert
                return try rule(Json.obj(), hint)
            }
            if let en = s["enum"] as? [Any] {
                let alts = en.map { Builder.literal(Json.serialize($0)) }
                let name = hint == "root" ? "root" : fresh(hint)
                add(name, "(" + alts.joined(separator: " | ") + ") space")
                return name
            }
            let type = Json.str(s, "type")
            switch type {
            case "object":
                let props = s["properties"] as? JObject ?? JObject()
                let required = Set((s["required"] as? [Any] ?? []).map { Json.text($0) })
                var req = [(String, String)](), opt = [(String, String)]()
                for (k, v) in props.entries {
                    let valueRule = try rule(v, hint == "root" ? k : hint + "-" + k)
                    let kv = Builder.literal(Json.serialize(k)) + " space \":\" space " + valueRule
                    if required.contains(k) { req.append((k, kv)) } else { opt.append((k, kv)) }
                }
                var body = "\"{\" space "
                if !req.isEmpty {
                    body += req.map { $0.1 }.joined(separator: " \",\" space ")
                    for o in opt { body += " ( \",\" space " + o.1 + " )?" }
                } else if !opt.isEmpty {
                    // Ohne Pflichtfelder: optionale Felder in Reihenfolge, jeweils mit Komma danach verbunden
                    var chain = ""
                    for o in opt.reversed() {
                        chain = chain.isEmpty ? "( " + o.1 + " )" : "( " + o.1 + " ( \",\" space " + chain + " )? | " + chain + " )"
                    }
                    body += chain + "?"
                } else if props.count == 0 && s["properties"] == nil {
                    // beliebiges Objekt
                    add("value", "object | array | string | number | boolean | null")
                    add("object", "\"{\" space ( string \":\" space value (\",\" space string \":\" space value)* )? \"}\" space")
                    add("array", "\"[\" space ( value (\",\" space value)* )? \"]\" space")
                    addScalars()
                    let name = hint == "root" ? "root" : fresh(hint)
                    add(name, "object")
                    return name
                }
                body += " \"}\" space"
                let name = hint == "root" ? "root" : fresh(hint)
                add(name, body)
                return name
            case "array":
                let item = try rule(s["items"] ?? Json.obj(), hint + "-item")
                let mn = max(0, Int(Json.num(s, "minItems", 0)))
                let mxRaw = Json.get(s, "maxItems")
                let mx: Int? = mxRaw == nil ? nil : Int(Json.num(s, "maxItems", 0))
                var body = "\"[\" space "
                if let mx = mx, mx == 0 {
                    body += "\"]\" space"
                } else if mn == 0 {
                    let rest = mx.map { "( \",\" space \(item) ){0,\($0 - 1)}" } ?? "( \",\" space \(item) )*"
                    body += "( \(item) \(rest) )? \"]\" space"
                } else {
                    let rest = mx.map { "( \",\" space \(item) ){\(mn - 1),\($0 - 1)}" } ?? "( \",\" space \(item) ){\(mn - 1),}"
                    body += "\(item) \(rest) \"]\" space"
                }
                let name = hint == "root" ? "root" : fresh(hint)
                add(name, body)
                return name
            case "string":
                let mn = Int(Json.num(s, "minLength", 0))
                let mx = Json.get(s, "maxLength") == nil ? -1 : Int(Json.num(s, "maxLength", 0))
                if mn == 0 && mx < 0 { addScalars(); if hint == "root" { add("root", "string"); return "root" }; return "string" }
                let rep = mx < 0 ? "char{\(mn),}" : "char{\(mn),\(mx)}"
                let name = hint == "root" ? "root" : fresh(hint)
                add(name, "\"\\\"\" \(rep) \"\\\"\" space")
                return name
            case "integer":
                add("integer", "(\"-\"? ([0-9] | [1-9] [0-9]{0,15})) space")
                if hint == "root" { add("root", "integer"); return "root" }
                return "integer"
            case "number":
                addScalars()
                if hint == "root" { add("root", "number"); return "root" }
                return "number"
            case "boolean":
                add("boolean", "(\"true\" | \"false\") space")
                if hint == "root" { add("root", "boolean"); return "root" }
                return "boolean"
            case "null":
                add("null", "\"null\" space")
                if hint == "root" { add("root", "null"); return "root" }
                return "null"
            default:
                add("value", "object | array | string | number | boolean | null")
                add("object", "\"{\" space ( string \":\" space value (\",\" space string \":\" space value)* )? \"}\" space")
                add("array", "\"[\" space ( value (\",\" space value)* )? \"]\" space")
                addScalars()
                if hint == "root" { add("root", "value"); return "root" }
                return "value"
            }
        }
        mutating func addScalars() {
            add("string", "\"\\\"\" char* \"\\\"\" space")
            add("number", "(\"-\"? ([0-9] | [1-9] [0-9]{0,15})) (\".\" [0-9]+)? ([eE] [-+]? [0-9]+)? space")
            add("boolean", "(\"true\" | \"false\") space")
            add("null", "\"null\" space")
        }
    }
}
