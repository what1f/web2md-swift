import Foundation

/// A CSS selector engine covering the subset of Selectors Level 4 used by the
/// extraction rules: type/universal, #id, .class, attribute operators with
/// `i`/`s` flags, `:not` `:is` `:where` `:has` `:scope`, structural pseudo-classes
/// and all four combinators. Semantics follow css-select (as used by linkedom).
final class SelectorList: @unchecked Sendable {
    let selectors: [ComplexSelector]
    init(_ selectors: [ComplexSelector]) { self.selectors = selectors }

    func matches(_ element: DOMElement, scope: DOMElement?) -> Bool {
        for selector in selectors where selector.matches(element, scope: scope) { return true }
        return false
    }
}

enum Combinator { case descendant, child, adjacent, sibling }

struct ComplexSelector {
    /// Left to right; `combinators[i]` joins `compounds[i]` and `compounds[i + 1]`.
    var compounds: [CompoundSelector]
    var combinators: [Combinator]

    func matches(_ element: DOMElement, scope: DOMElement?, leftmost: ((DOMElement) -> Bool)? = nil) -> Bool {
        match(element, index: compounds.count - 1, scope: scope, leftmost: leftmost)
    }

    private func match(_ element: DOMElement, index: Int, scope: DOMElement?, leftmost: ((DOMElement) -> Bool)?) -> Bool {
        guard compounds[index].matches(element, scope: scope) else { return false }
        if index == 0 { return leftmost?(element) ?? true }
        switch combinators[index - 1] {
        case .descendant:
            var ancestor = element.parentElement
            while let current = ancestor {
                if match(current, index: index - 1, scope: scope, leftmost: leftmost) { return true }
                ancestor = current.parentElement
            }
            return false
        case .child:
            guard let parent = element.parentElement else { return false }
            return match(parent, index: index - 1, scope: scope, leftmost: leftmost)
        case .adjacent:
            guard let previous = element.previousElementSibling else { return false }
            return match(previous, index: index - 1, scope: scope, leftmost: leftmost)
        case .sibling:
            var sibling = element.previousElementSibling
            while let current = sibling {
                if match(current, index: index - 1, scope: scope, leftmost: leftmost) { return true }
                sibling = current.previousElementSibling
            }
            return false
        }
    }
}

struct RelativeSelector {
    var leading: Combinator
    var selector: ComplexSelector
}

struct CompoundSelector {
    var tag: String?
    var simples: [SimpleSelector] = []

    func matches(_ element: DOMElement, scope: DOMElement?) -> Bool {
        if let tag, tag != element.localName { return false }
        for simple in simples where !simple.matches(element, scope: scope) { return false }
        return true
    }
}

enum AttributeOperator { case exists, equals, includes, dashMatch, prefix, suffix, substring }

/// Attribute values css-select compares case-insensitively in HTML.
private let caseInsensitiveAttributes: Set<String> = [
    "accept", "accept-charset", "align", "alink", "axis", "bgcolor", "charset", "checked", "clear",
    "codetype", "color", "compact", "declare", "defer", "dir", "direction", "disabled", "enctype",
    "face", "frame", "hreflang", "http-equiv", "lang", "language", "link", "media", "method",
    "multiple", "nohref", "noresize", "noshade", "nowrap", "readonly", "rel", "rev", "rules",
    "scope", "scrolling", "selected", "shape", "target", "text", "type", "valign", "valuetype", "vlink",
]

indirect enum SimpleSelector {
    case id(String)
    case className(String)
    case attribute(name: String, op: AttributeOperator, value: String, caseInsensitive: Bool?)
    case not(SelectorList)
    case `is`(SelectorList)
    case has([RelativeSelector])
    case scope
    case root
    case empty
    case nth(a: Int, b: Int, ofType: Bool, fromEnd: Bool)
    case onlyChild(ofType: Bool)
    case never

    func matches(_ element: DOMElement, scope: DOMElement?) -> Bool {
        switch self {
        case .id(let id):
            return element.getAttribute("id") == id
        case .className(let name):
            guard let value = element.getAttribute("class"), value.contains(name) else { return false }
            return element.classList.contains(name)
        case let .attribute(name, op, expected, flag):
            guard let actual = element.getAttribute(name) else { return false }
            if op == .exists { return true }
            let insensitive = flag ?? caseInsensitiveAttributes.contains(name)
            let value = insensitive ? actual.lowercased() : actual
            let wanted = insensitive ? expected.lowercased() : expected
            switch op {
            case .exists: return true
            case .equals: return value == wanted
            case .includes:
                guard !wanted.isEmpty, !wanted.contains(where: \.isWhitespace) else { return false }
                return value.split(whereSeparator: \.isWhitespace).contains { $0 == wanted }
            case .dashMatch: return value == wanted || value.hasPrefix(wanted + "-")
            case .prefix: return !wanted.isEmpty && value.hasPrefix(wanted)
            case .suffix: return !wanted.isEmpty && value.hasSuffix(wanted)
            case .substring: return !wanted.isEmpty && value.contains(wanted)
            }
        case .not(let list):
            return !list.matches(element, scope: scope)
        case .is(let list):
            return list.matches(element, scope: scope)
        case .has(let relatives):
            for relative in relatives where Self.hasMatch(element, relative, scope: scope) { return true }
            return false
        case .scope:
            if let scope { return element === scope }
            return element.parentNode is DOMDocument
        case .root:
            return element.parentNode is DOMDocument
        case .empty:
            return element.childNodes.allSatisfy { $0.nodeType == .comment }
        case let .nth(a, b, ofType, fromEnd):
            guard let parent = element.parentNode else { return false }
            var position = 0
            if fromEnd {
                for sibling in parent.childNodes.reversed() {
                    guard let sibling = sibling as? DOMElement else { continue }
                    if !ofType || sibling.localName == element.localName { position += 1 }
                    if sibling === element { break }
                }
            } else {
                for sibling in parent.childNodes {
                    guard let sibling = sibling as? DOMElement else { continue }
                    if !ofType || sibling.localName == element.localName { position += 1 }
                    if sibling === element { break }
                }
            }
            if a == 0 { return position == b }
            let diff = position - b
            return diff % a == 0 && diff / a >= 0
        case .onlyChild(let ofType):
            guard let parent = element.parentNode else { return false }
            for sibling in parent.childNodes {
                guard let sibling = sibling as? DOMElement, sibling !== element else { continue }
                if !ofType || sibling.localName == element.localName { return false }
            }
            return true
        case .never:
            return false
        }
    }

    private static func hasMatch(_ anchor: DOMElement, _ relative: RelativeSelector, scope: DOMElement?) -> Bool {
        let leftmost: (DOMElement) -> Bool
        switch relative.leading {
        case .descendant: leftmost = { $0 !== anchor && anchor.contains($0) }
        case .child: leftmost = { $0.parentNode === anchor }
        case .adjacent: leftmost = { $0.previousElementSibling === anchor }
        case .sibling:
            leftmost = { candidate in
                var sibling = candidate.previousElementSibling
                while let current = sibling {
                    if current === anchor { return true }
                    sibling = current.previousElementSibling
                }
                return false
            }
        }
        switch relative.leading {
        case .descendant, .child:
            var found = false
            anchor.forEachDescendantElement { candidate in
                if relative.selector.matches(candidate, scope: scope, leftmost: leftmost) {
                    found = true
                    return false
                }
                return true
            }
            return found
        case .adjacent, .sibling:
            var sibling = anchor.nextElementSibling
            while let current = sibling {
                if relative.selector.matches(current, scope: scope, leftmost: leftmost) { return true }
                var found = false
                current.forEachDescendantElement { candidate in
                    if relative.selector.matches(candidate, scope: scope, leftmost: leftmost) {
                        found = true
                        return false
                    }
                    return true
                }
                if found { return true }
                sibling = current.nextElementSibling
            }
            return false
        }
    }
}

extension DOMNode {
    /// Visits descendant elements in document order; return false to stop.
    @discardableResult
    func forEachDescendantElement(_ body: (DOMElement) -> Bool) -> Bool {
        for child in childNodes where child.nodeType == .element {
            let element = child as! DOMElement
            if !body(element) { return false }
            if !element.forEachDescendantElement(body) { return false }
        }
        return true
    }
}

// MARK: - Parsing

struct SelectorParser {
    private let chars: [Character]
    private var position = 0

    init(_ text: String) { chars = Array(text) }

    static func parse(_ text: String) -> SelectorList? {
        var parser = SelectorParser(text)
        guard let list = parser.parseList(), parser.atEnd else { return nil }
        return list
    }

    private var atEnd: Bool { position >= chars.count }
    private var current: Character? { position < chars.count ? chars[position] : nil }

    private mutating func skipWhitespace() {
        while let c = current, c.isWhitespace { position += 1 }
    }

    mutating func parseList(relative: Bool = false) -> SelectorList? {
        var selectors: [ComplexSelector] = []
        repeat {
            skipWhitespace()
            guard let selector = parseComplex() else { return nil }
            selectors.append(selector)
            skipWhitespace()
        } while consume(",")
        return SelectorList(selectors)
    }

    mutating func parseRelativeList() -> [RelativeSelector]? {
        var result: [RelativeSelector] = []
        repeat {
            skipWhitespace()
            var leading = Combinator.descendant
            if let c = current, let combinator = combinatorFor(c) {
                leading = combinator
                position += 1
                skipWhitespace()
            }
            guard let selector = parseComplex() else { return nil }
            result.append(RelativeSelector(leading: leading, selector: selector))
            skipWhitespace()
        } while consume(",")
        return result
    }

    private func combinatorFor(_ c: Character) -> Combinator? {
        switch c {
        case ">": .child
        case "+": .adjacent
        case "~": .sibling
        default: nil
        }
    }

    private mutating func consume(_ c: Character) -> Bool {
        if current == c { position += 1; return true }
        return false
    }

    private mutating func parseComplex() -> ComplexSelector? {
        var compounds: [CompoundSelector] = []
        var combinators: [Combinator] = []
        guard let first = parseCompound() else { return nil }
        compounds.append(first)
        while true {
            var sawWhitespace = false
            while let c = current, c.isWhitespace { position += 1; sawWhitespace = true }
            guard let c = current, c != ",", c != ")" else { break }
            var combinator = Combinator.descendant
            if let explicit = combinatorFor(c) {
                combinator = explicit
                position += 1
                skipWhitespace()
            } else if !sawWhitespace {
                return nil
            }
            guard let next = parseCompound() else { return nil }
            combinators.append(combinator)
            compounds.append(next)
        }
        return ComplexSelector(compounds: compounds, combinators: combinators)
    }

    private mutating func parseCompound() -> CompoundSelector? {
        var compound = CompoundSelector()
        var any = false
        if current == "*" {
            position += 1
            any = true
        } else if let c = current, isIdentStart(c) {
            compound.tag = readIdentifier().lowercased()
            any = true
        }
        loop: while let c = current {
            switch c {
            case "#":
                position += 1
                let name = readIdentifier()
                guard !name.isEmpty else { return nil }
                compound.simples.append(.id(name))
            case ".":
                position += 1
                let name = readIdentifier()
                guard !name.isEmpty else { return nil }
                compound.simples.append(.className(name))
            case "[":
                position += 1
                guard let attribute = parseAttribute() else { return nil }
                compound.simples.append(attribute)
            case ":":
                position += 1
                if current == ":" { return nil } // pseudo-elements never match elements
                guard let pseudo = parsePseudo() else { return nil }
                compound.simples.append(pseudo)
            default:
                break loop
            }
            any = true
        }
        return any ? compound : nil
    }

    private mutating func parseAttribute() -> SimpleSelector? {
        skipWhitespace()
        let name = readIdentifier()
        guard !name.isEmpty else { return nil }
        skipWhitespace()
        var op = AttributeOperator.exists
        if current == "]" {
            position += 1
            return .attribute(name: name, op: .exists, value: "", caseInsensitive: nil)
        }
        switch current {
        case "=": op = .equals; position += 1
        case "~": op = .includes; position += 2
        case "|": op = .dashMatch; position += 2
        case "^": op = .prefix; position += 2
        case "$": op = .suffix; position += 2
        case "*": op = .substring; position += 2
        default: return nil
        }
        skipWhitespace()
        var value = ""
        if let quote = current, quote == "\"" || quote == "'" {
            position += 1
            while let c = current, c != quote {
                if c == "\\" {
                    position += 1
                    if let escaped = readEscape() { value.append(escaped) }
                    continue
                }
                value.append(c)
                position += 1
            }
            guard consume(quote) else { return nil }
        } else {
            value = readIdentifier()
        }
        skipWhitespace()
        var flag: Bool?
        if let c = current, c == "i" || c == "I" || c == "s" || c == "S" {
            flag = (c == "i" || c == "I")
            position += 1
            skipWhitespace()
        }
        guard consume("]") else { return nil }
        return .attribute(name: name, op: op, value: value, caseInsensitive: flag)
    }

    private mutating func parsePseudo() -> SimpleSelector? {
        let name = readIdentifier().lowercased()
        guard !name.isEmpty else { return nil }
        if consume("(") {
            skipWhitespace()
            var result: SimpleSelector?
            switch name {
            case "not":
                if let list = parseList() { result = .not(list) }
            case "is", "where", "matches", "any":
                if let list = parseList() { result = .is(list) }
            case "has":
                if let list = parseRelativeList() { result = .has(list) }
            case "nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type":
                let argument = readUntilParen()
                guard let (a, b) = Self.parseNth(argument) else { return nil }
                result = .nth(a: a, b: b, ofType: name.hasSuffix("of-type"), fromEnd: name.contains("last"))
            case "lang", "contains", "dir":
                _ = readUntilParen()
                result = .never
            default:
                return nil
            }
            skipWhitespace()
            guard result != nil, consume(")") else { return nil }
            return result
        }
        switch name {
        case "scope": return .scope
        case "root": return .root
        case "empty": return .empty
        case "first-child": return .nth(a: 0, b: 1, ofType: false, fromEnd: false)
        case "last-child": return .nth(a: 0, b: 1, ofType: false, fromEnd: true)
        case "first-of-type": return .nth(a: 0, b: 1, ofType: true, fromEnd: false)
        case "last-of-type": return .nth(a: 0, b: 1, ofType: true, fromEnd: true)
        case "only-child": return .onlyChild(ofType: false)
        case "only-of-type": return .onlyChild(ofType: true)
        case "checked", "disabled", "enabled", "hover", "focus", "active", "visited", "link",
             "any-link", "target", "focus-within", "focus-visible", "defined":
            return name == "defined" ? .is(SelectorList([ComplexSelector(compounds: [CompoundSelector()], combinators: [])])) : .never
        default: return nil
        }
    }

    private mutating func readUntilParen() -> String {
        var depth = 0
        var result = ""
        while let c = current {
            if c == "(" { depth += 1 }
            if c == ")" {
                if depth == 0 { break }
                depth -= 1
            }
            result.append(c)
            position += 1
        }
        return result
    }

    static func parseNth(_ raw: String) -> (Int, Int)? {
        let text = raw.lowercased().filter { !$0.isWhitespace }
        if text == "odd" { return (2, 1) }
        if text == "even" { return (2, 0) }
        if let n = text.firstIndex(of: "n") {
            let aPart = String(text[..<n])
            let bPart = String(text[text.index(after: n)...])
            let a: Int
            switch aPart {
            case "", "+": a = 1
            case "-": a = -1
            default: guard let value = Int(aPart) else { return nil }; a = value
            }
            let b = bPart.isEmpty ? 0 : (Int(bPart.hasPrefix("+") ? String(bPart.dropFirst()) : bPart) ?? Int.min)
            guard b != Int.min else { return nil }
            return (a, b)
        }
        guard let b = Int(text) else { return nil }
        return (0, b)
    }

    private func isIdentStart(_ c: Character) -> Bool {
        c.isLetter || c == "_" || c == "-" || c == "\\" || !c.isASCII
    }

    private func isIdentChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "-" || !c.isASCII
    }

    private mutating func readIdentifier() -> String {
        var result = ""
        while let c = current {
            if c == "\\" {
                position += 1
                if let escaped = readEscape() { result.append(escaped) }
            } else if isIdentChar(c) {
                result.append(c)
                position += 1
            } else {
                break
            }
        }
        return result
    }

    private mutating func readEscape() -> Character? {
        guard let c = current else { return nil }
        if c.isHexDigit {
            var hex = ""
            while let h = current, h.isHexDigit, hex.count < 6 {
                hex.append(h)
                position += 1
            }
            if current == " " { position += 1 }
            if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) { return Character(scalar) }
            return nil
        }
        position += 1
        return c
    }
}

final class SelectorCache: @unchecked Sendable {
    static let shared = SelectorCache()
    private var cache: [String: SelectorList?] = [:]
    private let lock = NSLock()

    func list(_ selector: String) -> SelectorList? {
        lock.lock()
        if let cached = cache[selector] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let parsed = SelectorParser.parse(selector)
        lock.lock()
        cache[selector] = .some(parsed)
        lock.unlock()
        return parsed
    }
}

// MARK: - Query API

extension DOMNode {
    private var queryScope: DOMElement? { self as? DOMElement }

    public func querySelectorAll(_ selector: String) -> [DOMElement] {
        guard let list = SelectorCache.shared.list(selector) else { return [] }
        let scope = queryScope
        var result: [DOMElement] = []
        forEachDescendantElement { element in
            if list.matches(element, scope: scope) { result.append(element) }
            return true
        }
        return result
    }

    public func querySelector(_ selector: String) -> DOMElement? {
        guard let list = SelectorCache.shared.list(selector) else { return nil }
        let scope = queryScope
        var found: DOMElement?
        forEachDescendantElement { element in
            if list.matches(element, scope: scope) {
                found = element
                return false
            }
            return true
        }
        return found
    }
}

extension DOMElement {
    public func matches(_ selector: String) -> Bool {
        guard let list = SelectorCache.shared.list(selector) else { return false }
        return list.matches(self, scope: self)
    }

    public func closest(_ selector: String) -> DOMElement? {
        guard let list = SelectorCache.shared.list(selector) else { return nil }
        var node: DOMElement? = self
        while let current = node {
            if list.matches(current, scope: self) { return current }
            node = current.parentElement
        }
        return nil
    }

    /// True if the selector string parses.
    public static func isValidSelector(_ selector: String) -> Bool {
        SelectorCache.shared.list(selector) != nil
    }
}
