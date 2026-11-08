import Foundation

/// Loosely-typed JSON for reading third-party API payloads and schema.org data
/// without breaking when a field changes type or disappears.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue], keys: [String])

    public init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) }
            else { self = .number(number.doubleValue) }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map { JSONValue(any: $0) })
        case let dict as [String: Any]:
            var object: [String: JSONValue] = [:]
            for (key, value) in dict { object[key] = JSONValue(any: value) }
            self = .object(object, keys: dict.keys.sorted())
        default: self = .null
        }
    }

    /// Parses JSON keeping object key order like JavaScript (integer keys
    /// ascending first, then insertion order).
    public static func parse(_ data: Data) -> JSONValue? {
        var parser = OrderedJSONParser(bytes: [UInt8](data))
        return parser.parseDocument()
    }

    public static func parse(_ text: String) -> JSONValue? { parse(Data(text.utf8)) }

    public var orderedEntries: [(String, JSONValue)] {
        guard case .object(let dict, let keys) = self else { return [] }
        return keys.compactMap { key in dict[key].map { (key, $0) } }
    }

    public subscript(key: String) -> JSONValue {
        if case .object(let dict, _) = self { return dict[key] ?? .null }
        return .null
    }

    public subscript(index: Int) -> JSONValue {
        if case .array(let items) = self, index >= 0, index < items.count { return items[index] }
        return .null
    }

    public var isNull: Bool { if case .null = self { return true }; return false }
    public var exists: Bool { !isNull }

    public var string: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        default: nil
        }
    }

    /// The value as a string, or "" when absent.
    public var text: String { string ?? "" }

    public var int: Int? {
        switch self {
        case .number(let value): Int(value)
        case .string(let value): Int(value)
        default: nil
        }
    }

    public var double: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }

    public var bool: Bool? { if case .bool(let value) = self { return value }; return nil }

    public var array: [JSONValue]? { if case .array(let items) = self { return items }; return nil }
    /// Array items, or empty when not an array.
    public var items: [JSONValue] { array ?? [] }

    public var object: [String: JSONValue]? { if case .object(let dict, _) = self { return dict }; return nil }
    public var keys: [String] { if case .object(_, let keys) = self { return keys }; return [] }

    public var isString: Bool { if case .string = self { return true }; return false }
    public var isArray: Bool { if case .array = self { return true }; return false }
    public var isObject: Bool { if case .object = self { return true }; return false }

    /// Truthiness, like JavaScript.
    public var truthy: Bool {
        switch self {
        case .null: false
        case .bool(let value): value
        case .number(let value): value != 0 && !value.isNaN
        case .string(let value): !value.isEmpty
        case .array, .object: true
        }
    }

    public func map(_ transform: (JSONValue) -> JSONValue) -> JSONValue {
        switch self {
        case .array(let items): .array(items.map { $0.map(transform) })
        case .object(let dict, let keys):
            .object(dict.mapValues { $0.map(transform) }, keys: keys)
        default: transform(self)
        }
    }
}

private struct OrderedJSONParser {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
    }

    mutating func parseDocument() -> JSONValue? {
        guard let value = parseValue() else { return nil }
        skipWhitespace()
        return index == bytes.count ? value : nil
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private mutating func parseValue() -> JSONValue? {
        skipWhitespace()
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "{"): return parseObject()
        case UInt8(ascii: "["): return parseArray()
        case UInt8(ascii: "\""): return parseString().map(JSONValue.string)
        case UInt8(ascii: "t"): return literal("true", .bool(true))
        case UInt8(ascii: "f"): return literal("false", .bool(false))
        case UInt8(ascii: "n"): return literal("null", .null)
        default: return parseNumber()
        }
    }

    private mutating func literal(_ word: String, _ value: JSONValue) -> JSONValue? {
        let utf8 = Array(word.utf8)
        guard index + utf8.count <= bytes.count, Array(bytes[index..<index + utf8.count]) == utf8 else { return nil }
        index += utf8.count
        return value
    }

    private mutating func parseNumber() -> JSONValue? {
        let start = index
        while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
        guard index > start, let text = String(bytes: bytes[start..<index], encoding: .ascii), let number = Double(text) else { return nil }
        return .number(number)
    }

    private mutating func parseString() -> String? {
        index += 1
        var scalars = String.UnicodeScalarView()
        var chunkStart = index
        func flush(_ end: Int) {
            if end > chunkStart { scalars.append(contentsOf: String(decoding: bytes[chunkStart..<end], as: UTF8.self).unicodeScalars) }
        }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                flush(index)
                index += 1
                return String(scalars)
            }
            if byte == UInt8(ascii: "\\") {
                flush(index)
                index += 1
                guard index < bytes.count else { return nil }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "u"):
                    guard let high = hex4() else { return nil }
                    if (0xD800...0xDBFF).contains(high), index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        index += 2
                        guard let low = hex4() else { return nil }
                        if (0xDC00...0xDFFF).contains(low), let scalar = Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)) {
                            scalars.append(scalar)
                        } else {
                            scalars.append("\u{FFFD}")
                            if let scalar = Unicode.Scalar(low) { scalars.append(scalar) } else { scalars.append("\u{FFFD}") }
                        }
                    } else if let scalar = Unicode.Scalar(high) {
                        scalars.append(scalar)
                    } else {
                        scalars.append("\u{FFFD}")
                    }
                default: scalars.append(Unicode.Scalar(escape))
                }
                chunkStart = index
                continue
            }
            index += 1
        }
        return nil
    }

    private mutating func hex4() -> UInt32? {
        guard index + 4 <= bytes.count, let text = String(bytes: bytes[index..<index + 4], encoding: .ascii),
              let value = UInt32(text, radix: 16) else { return nil }
        index += 4
        return value
    }

    private mutating func parseArray() -> JSONValue? {
        index += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
        while true {
            guard let value = parseValue() else { return nil }
            items.append(value)
            skipWhitespace()
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            return nil
        }
    }

    private mutating func parseObject() -> JSONValue? {
        index += 1
        var dict: [String: JSONValue] = [:]
        var keys: [String] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(dict, keys: keys) }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let key = parseString() else { return nil }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            index += 1
            guard let value = parseValue() else { return nil }
            if dict[key] == nil { keys.append(key) }
            dict[key] = value
            skipWhitespace()
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(dict, keys: Self.jsKeyOrder(keys))
            }
            return nil
        }
    }

    /// JavaScript enumerates array-index-like keys first, ascending.
    private static func jsKeyOrder(_ keys: [String]) -> [String] {
        func arrayIndex(_ key: String) -> UInt32? {
            guard let value = UInt32(key), value < UInt32.max, String(value) == key else { return nil }
            return value
        }
        let numeric = keys.compactMap { key in arrayIndex(key).map { ($0, key) } }
        guard !numeric.isEmpty else { return keys }
        return numeric.sorted { $0.0 < $1.0 }.map(\.1) + keys.filter { arrayIndex($0) == nil }
    }
}
