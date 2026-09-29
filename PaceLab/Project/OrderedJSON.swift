import Foundation

/// JSON mit stabiler Schlüssel-Reihenfolge und unveränderten Zahlen. Damit ändert die App einzelne
/// Stellen in analysis.json oder plan.json, ohne dass sich der Rest der Datei verschiebt — wichtig für
/// lesbare Stände im Verlauf und für den Coach, der dieselben Dateien bearbeitet.
enum OrderedJSON: Equatable, Sendable {
    case object([Member])
    case array([OrderedJSON])
    case string(String)
    /// Zahl im Originaltext, z. B. "21.13" — wird nie umgerechnet.
    case number(String)
    case bool(Bool)
    case null

    struct Member: Equatable, Sendable {
        var key: String
        var value: OrderedJSON
    }

    /// Wie die Datei geschrieben wird.
    enum Style: Sendable {
        /// Wie Pythons `json.dumps(indent=2, ensure_ascii=False)` — so sieht analysis.json aus.
        case python
        /// Kurze Objekte und Listen einzeilig, solange die Zeile nicht breiter als `width` wird (plan.json).
        case compact(width: Int)
    }
}

// MARK: - Zugriff

extension OrderedJSON {
    subscript(key: String) -> OrderedJSON? {
        get {
            guard case .object(let members) = self else { return nil }
            return members.first { $0.key == key }?.value
        }
        set {
            guard case .object(var members) = self else { return }
            if let i = members.firstIndex(where: { $0.key == key }) {
                if let newValue { members[i].value = newValue } else { members.remove(at: i) }
            } else if let newValue {
                members.append(Member(key: key, value: newValue))
            }
            self = .object(members)
        }
    }

    var arrayValue: [OrderedJSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .number(let raw): Double(raw)
        case .string(let s): Double(s)
        default: nil
        }
    }

    var isNull: Bool { self == .null }

    /// Objekt aus Schlüssel/Wert-Paaren in genau dieser Reihenfolge; `nil`-Werte werden ausgelassen.
    static func object(_ pairs: [(String, OrderedJSON?)]) -> OrderedJSON {
        .object(pairs.compactMap { key, value in value.map { Member(key: key, value: $0) } })
    }

    static func int(_ value: Double?) -> OrderedJSON? {
        guard let value, value.isFinite else { return nil }
        return .number(String(Int(value.rounded())))
    }

    /// Dezimalzahl mit höchstens `digits` Nachkommastellen, wie Python sie schreibt ("5.02", "5.0").
    static func decimal(_ value: Double?, digits: Int) -> OrderedJSON? {
        guard let value, value.isFinite else { return nil }
        var text = String(format: "%.\(digits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text += "0" }
        }
        return .number(text)
    }
}

// MARK: - Lesen

extension OrderedJSON {
    struct SyntaxError: LocalizedError {
        let offset: Int
        let reason: String

        var errorDescription: String? { "Ungültiges JSON an Position \(offset): \(reason)" }
    }

    static func parse(_ text: String) throws -> OrderedJSON {
        try parse(Data(text.utf8))
    }

    static func parse(_ data: Data) throws -> OrderedJSON {
        var parser = Parser(bytes: [UInt8](data))
        return try parser.document()
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func document() throws -> OrderedJSON {
            skipWhitespace()
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3; skipWhitespace() }
            let value = try self.value()
            skipWhitespace()
            guard i == bytes.count else { throw fail("Text nach dem Ende") }
            return value
        }

        private func fail(_ reason: String) -> SyntaxError { SyntaxError(offset: i, reason: reason) }

        private mutating func skipWhitespace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        private mutating func value() throws -> OrderedJSON {
            guard i < bytes.count else { throw fail("unerwartetes Ende") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try number()
            default: throw fail("unerwartetes Zeichen")
            }
        }

        private mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard i + expected.count <= bytes.count, Array(bytes[i..<i + expected.count]) == expected else {
                throw fail("\(word) erwartet")
            }
            i += expected.count
        }

        private mutating func number() throws -> OrderedJSON {
            let start = i
            while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
            let raw = String(decoding: bytes[start..<i], as: UTF8.self)
            guard Double(raw) != nil else { throw SyntaxError(offset: start, reason: "ungültige Zahl") }
            return .number(raw)
        }

        private mutating func object() throws -> OrderedJSON {
            i += 1
            var members: [Member] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("Schlüssel erwartet") }
                let key = try string()
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("„:“ erwartet") }
                i += 1
                skipWhitespace()
                members.append(Member(key: key, value: try value()))
                skipWhitespace()
                guard i < bytes.count else { throw fail("unerwartetes Ende") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                throw fail("„,“ oder „}“ erwartet")
            }
        }

        private mutating func array() throws -> OrderedJSON {
            i += 1
            var items: [OrderedJSON] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try value())
                skipWhitespace()
                guard i < bytes.count else { throw fail("unerwartetes Ende") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw fail("„,“ oder „]“ erwartet")
            }
        }

        private mutating func string() throws -> String {
            i += 1
            var out: [UInt8] = []
            while i < bytes.count {
                let byte = bytes[i]
                if byte == UInt8(ascii: "\"") {
                    i += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if byte == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { break }
                    let escape = bytes[i]
                    i += 1
                    switch escape {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var scalar = try hex4()
                        if (0xD800...0xDBFF).contains(scalar), i + 1 < bytes.count,
                           bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                            i += 2
                            let low = try hex4()
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        }
                        out.append(contentsOf: Array(String(Unicode.Scalar(scalar) ?? "\u{FFFD}").utf8))
                    default:
                        throw fail("unbekannte Escape-Sequenz")
                    }
                    continue
                }
                out.append(byte)
                i += 1
            }
            throw fail("String ohne Ende")
        }

        private mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let value = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else {
                throw fail("\\u mit vier Hex-Ziffern erwartet")
            }
            i += 4
            return value
        }
    }
}

// MARK: - Schreiben

extension OrderedJSON {
    func rendered(_ style: Style) -> String {
        switch style {
        case .python: Self.python(self, level: 0)
        case .compact(let width): Self.compact(self, indent: 0, prefix: 0, width: width)
        }
    }

    private static func python(_ value: OrderedJSON, level: Int) -> String {
        let pad = String(repeating: "  ", count: level + 1)
        let close = String(repeating: "  ", count: level)
        switch value {
        case .object(let members) where !members.isEmpty:
            let lines = members.map { pad + quote($0.key) + ": " + python($0.value, level: level + 1) }
            return "{\n" + lines.joined(separator: ",\n") + "\n" + close + "}"
        case .array(let items) where !items.isEmpty:
            let lines = items.map { pad + python($0, level: level + 1) }
            return "[\n" + lines.joined(separator: ",\n") + "\n" + close + "]"
        default:
            return inline(value)
        }
    }

    private static func compact(_ value: OrderedJSON, indent: Int, prefix: Int, width: Int) -> String {
        let one = inline(value)
        let pad = String(repeating: " ", count: indent + 2)
        let close = String(repeating: " ", count: indent)
        switch value {
        case .object(let members) where !members.isEmpty && indent + prefix + one.unicodeScalars.count > width:
            let lines = members.map { member -> String in
                let key = quote(member.key) + ": "
                return pad + key + compact(member.value, indent: indent + 2, prefix: key.unicodeScalars.count, width: width)
            }
            return "{\n" + lines.joined(separator: ",\n") + "\n" + close + "}"
        case .array(let items) where !items.isEmpty && indent + prefix + one.unicodeScalars.count > width:
            let lines = items.map { pad + compact($0, indent: indent + 2, prefix: 0, width: width) }
            return "[\n" + lines.joined(separator: ",\n") + "\n" + close + "]"
        default:
            return one
        }
    }

    /// Einzeilig: `{ "a": 1, "b": [1, 2] }`
    private static func inline(_ value: OrderedJSON) -> String {
        switch value {
        case .object(let members):
            members.isEmpty ? "{}" : "{ " + members.map { quote($0.key) + ": " + inline($0.value) }.joined(separator: ", ") + " }"
        case .array(let items):
            items.isEmpty ? "[]" : "[" + items.map(inline).joined(separator: ", ") + "]"
        case .string(let s): quote(s)
        case .number(let raw): raw
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        }
    }

    /// Escaping wie Python mit `ensure_ascii=False`: nur Anführungszeichen, Backslash und Steuerzeichen.
    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

// MARK: - Datei

/// Eine JSON-Datei des Projekts, die beim Zurückschreiben ihr Format behält.
struct JSONDocument {
    var root: OrderedJSON
    var style: OrderedJSON.Style
    var trailingNewline: Bool

    init(root: OrderedJSON, style: OrderedJSON.Style, trailingNewline: Bool = true) {
        self.root = root
        self.style = style
        self.trailingNewline = trailingNewline
    }

    init(contentsOf url: URL, style: OrderedJSON.Style) throws {
        let data = try Data(contentsOf: url)
        root = try OrderedJSON.parse(data)
        self.style = style
        trailingNewline = data.last == 0x0A
    }

    var text: String { root.rendered(style) + (trailingNewline ? "\n" : "") }

    func write(to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
