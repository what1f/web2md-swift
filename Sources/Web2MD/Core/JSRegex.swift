import Foundation

/// A regular expression with JavaScript-like helpers (`test`, `replace`, `match`),
/// backed by ICU so lookbehind and Unicode classes work like the upstream code.
struct JSRegex: @unchecked Sendable {
    let regex: NSRegularExpression
    let global: Bool

    init(_ pattern: String, _ flags: String = "") {
        var options: NSRegularExpression.Options = []
        if flags.contains("i") { options.insert(.caseInsensitive) }
        if flags.contains("m") { options.insert(.anchorsMatchLines) }
        if flags.contains("s") { options.insert(.dotMatchesLineSeparators) }
        global = flags.contains("g")
        regex = RegexCache.shared.regex(pattern, options)
    }

    struct Match {
        let source: NSString
        let result: NSTextCheckingResult

        /// Whole match.
        var value: String { source.substring(with: result.range) }
        /// UTF-16 offset of the match.
        var index: Int { result.range.location }
        var length: Int { result.range.length }
        var end: Int { result.range.location + result.range.length }

        subscript(_ group: Int) -> String? {
            guard group < result.numberOfRanges else { return nil }
            let range = result.range(at: group)
            return range.location == NSNotFound ? nil : source.substring(with: range)
        }

        func named(_ name: String) -> String? {
            let range = result.range(withName: name)
            return range.location == NSNotFound ? nil : source.substring(with: range)
        }
    }

    func test(_ text: String) -> Bool {
        let ns = text as NSString
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil
    }

    func firstMatch(_ text: String, from offset: Int = 0) -> Match? {
        let ns = text as NSString
        guard offset <= ns.length,
              let result = regex.firstMatch(in: text, range: NSRange(location: offset, length: ns.length - offset)) else { return nil }
        return Match(source: ns, result: result)
    }

    func allMatches(_ text: String) -> [Match] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { Match(source: ns, result: $0) }
    }

    /// `String.prototype.match`: with `g` returns all whole matches, otherwise the first match's groups.
    func match(_ text: String) -> Match? { firstMatch(text) }

    func replace(_ text: String, _ template: String) -> String {
        replace(text) { match in Self.expand(template, match) }
    }

    func replace(_ text: String, using transform: (Match) -> String) -> String {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let results: [NSTextCheckingResult]
        if global {
            results = regex.matches(in: text, range: full)
        } else if let first = regex.firstMatch(in: text, range: full) {
            results = [first]
        } else {
            results = []
        }
        guard !results.isEmpty else { return text }
        var output = ""
        var last = 0
        for result in results {
            output += ns.substring(with: NSRange(location: last, length: result.range.location - last))
            output += transform(Match(source: ns, result: result))
            last = result.range.location + result.range.length
        }
        output += ns.substring(from: last)
        return output
    }

    /// `String.prototype.split` with a regex separator (capture groups are not spliced in).
    func split(_ text: String) -> [String] {
        let ns = text as NSString
        let results = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !results.isEmpty else { return [text] }
        var parts: [String] = []
        var last = 0
        for result in results {
            if result.range.length == 0 && result.range.location == last && last != 0 { continue }
            if result.range.length == 0 && result.range.location >= ns.length { continue }
            parts.append(ns.substring(with: NSRange(location: last, length: result.range.location - last)))
            last = result.range.location + result.range.length
        }
        parts.append(ns.substring(from: last))
        return parts
    }

    private static func expand(_ template: String, _ match: Match) -> String {
        guard template.contains("$") else { return template }
        var output = ""
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "$", i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "$" { output.append("$"); i += 2; continue }
                if next == "&" { output += match.value; i += 2; continue }
                if next.isNumber {
                    var digits = String(next)
                    if i + 2 < chars.count, chars[i + 2].isNumber,
                       let two = Int(digits + String(chars[i + 2])), two < match.result.numberOfRanges {
                        digits.append(chars[i + 2])
                    }
                    if let group = Int(digits), group > 0, group < match.result.numberOfRanges {
                        output += match[group] ?? ""
                        i += 1 + digits.count
                        continue
                    }
                }
            }
            output.append(c)
            i += 1
        }
        return output
    }
}

final class RegexCache: @unchecked Sendable {
    static let shared = RegexCache()
    private var cache: [String: NSRegularExpression] = [:]
    private let lock = NSLock()

    func regex(_ pattern: String, _ options: NSRegularExpression.Options) -> NSRegularExpression {
        let key = "\(options.rawValue)|\(pattern)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let compiled: NSRegularExpression
        do {
            compiled = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            assertionFailure("Invalid regex: \(pattern)")
            compiled = try! NSRegularExpression(pattern: "(?!)")
        }
        cache[key] = compiled
        return compiled
    }
}

extension String {
    /// Length in UTF-16 code units, like JavaScript's `length`.
    var jsLength: Int { utf16.count }

    /// `slice(start, end)` in UTF-16 units (negative indexes count from the end).
    func jsSlice(_ start: Int, _ end: Int? = nil) -> String {
        let ns = self as NSString
        let length = ns.length
        let s = start < 0 ? max(0, length + start) : min(start, length)
        let e = end.map { $0 < 0 ? max(0, length + $0) : min($0, length) } ?? length
        guard e > s else { return "" }
        return ns.substring(with: NSRange(location: s, length: e - s))
    }

    /// `substring(start, end)` in UTF-16 units (clamped, swapped when reversed).
    func jsSubstring(_ start: Int, _ end: Int? = nil) -> String {
        let ns = self as NSString
        let length = ns.length
        var s = min(max(0, start), length)
        var e = min(max(0, end ?? length), length)
        if s > e { swap(&s, &e) }
        return ns.substring(with: NSRange(location: s, length: e - s))
    }

    /// JavaScript `trim()`.
    var trimmed: String { trimmingCharacters(in: .jsWhitespace) }
    var trimmedStart: String {
        guard let index = firstIndex(where: { !$0.unicodeScalars.allSatisfy(CharacterSet.jsWhitespace.contains) }) else { return "" }
        return String(self[index...])
    }
    var trimmedEnd: String {
        guard let index = lastIndex(where: { !$0.unicodeScalars.allSatisfy(CharacterSet.jsWhitespace.contains) }) else { return "" }
        return String(self[...index])
    }

    func replacingAll(_ target: String, _ replacement: String) -> String {
        replacingOccurrences(of: target, with: replacement)
    }

    func jsReplace(_ pattern: String, _ flags: String = "g", _ template: String) -> String {
        JSRegex(pattern, flags).replace(self, template)
    }

    func jsTest(_ pattern: String, _ flags: String = "") -> Bool {
        JSRegex(pattern, flags).test(self)
    }

    func jsMatch(_ pattern: String, _ flags: String = "") -> JSRegex.Match? {
        JSRegex(pattern, flags).firstMatch(self)
    }

    func jsSplit(_ pattern: String, _ flags: String = "") -> [String] {
        JSRegex(pattern, flags).split(self)
    }
}

extension CharacterSet {
    /// Characters removed by JavaScript's `String.prototype.trim`.
    static let jsWhitespace: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\u{FEFF}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{0B}\u{0C}")
        return set
    }()
}

/// JavaScript `parseInt(text)` (base 10); nil stands for NaN.
func jsParseInt(_ text: String?) -> Int? {
    guard let text, let match = text.jsMatch("^\\s*([+-]?\\d+)") else { return nil }
    return Int(match[1] ?? "") ?? (match[1]?.hasPrefix("-") == true ? Int.min : Int.max)
}

/// JavaScript `parseFloat(text)`; nil stands for NaN.
func jsParseFloat(_ text: String?) -> Double? {
    guard let text, let match = text.jsMatch("^\\s*([+-]?(?:\\d+\\.?\\d*(?:[eE][+-]?\\d+)?|\\.\\d+(?:[eE][+-]?\\d+)?|Infinity))") else { return nil }
    let value = match[1] ?? ""
    if value.hasSuffix("Infinity") { return value.hasPrefix("-") ? -.infinity : .infinity }
    return Double(value)
}

extension String {
    /// JavaScript `indexOf(search)` in UTF-16 units, -1 when missing.
    func jsIndexOf(_ search: String, from: Int = 0) -> Int {
        let ns = self as NSString
        let start = min(max(0, from), ns.length)
        if search.isEmpty { return start }
        let range = ns.range(of: search, options: .literal, range: NSRange(location: start, length: ns.length - start))
        return range.location == NSNotFound ? -1 : range.location
    }

    /// JavaScript `lastIndexOf(search)` in UTF-16 units, -1 when missing.
    func jsLastIndexOf(_ search: String) -> Int {
        let ns = self as NSString
        if search.isEmpty { return ns.length }
        let range = ns.range(of: search, options: [.literal, .backwards])
        return range.location == NSNotFound ? -1 : range.location
    }
}
