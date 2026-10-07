import Foundation

enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func encoded(pretty: Bool = true) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }

    var isNull: Bool { if case .null = self { true } else { false } }
    var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    var number: Double? { if case .number(let n) = self { n } else { nil } }

    /// The number as an Int pinned to `range`, since converting an out-of-range Double traps.
    func int(in range: ClosedRange<Int>) -> Int? {
        guard let n = number, !n.isNaN else { return nil }
        return Int(min(max(n.rounded(), Double(range.lowerBound)), Double(range.upperBound)))
    }
    var string: String? { if case .string(let s) = self { s } else { nil } }
    var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    var object: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }

    var numbers: [Double]? {
        guard let a = array else { return nil }
        let n = a.compactMap(\.number)
        return n.count == a.count ? n : nil
    }

    subscript(key: String) -> JSONValue? {
        object?[key]
    }

    var kindName: String {
        switch self {
        case .null: "null"
        case .bool: "a boolean"
        case .number: "a number"
        case .string: "a string"
        case .array: "an array"
        case .object: "an object"
        }
    }

    /// Short human form for UI and diagnostics.
    var display: String {
        switch self {
        case .null: "none"
        case .bool(let b): b ? "on" : "off"
        case .number(let n): n == n.rounded() && abs(n) < 1e9 ? String(Int(n)) : String(format: "%.3g", n)
        case .string(let s): s
        case .array(let a): "[" + a.map(\.display).joined(separator: ", ") + "]"
        case .object: "{…}"
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(nilLiteral: ()) { self = .null }
}

extension JSONValue {
    init(_ values: [Double]) { self = .array(values.map { .number($0) }) }
}
