// Port of turndown 7.2.5 (https://github.com/mixmark-io/turndown), MIT License.
// Copyright (c) 2017+ Dom Christie. collapseWhitespace adapted from
// collapse-whitespace, Copyright (c) 2014 Luc Thevenard.

import Foundation

/// HTML → Markdown converter core. Rules are tried in order; the first whose
/// filter matches an element produces its Markdown.
class Turndown {
    struct Rule {
        let filter: (DOMElement) -> Bool
        let replacement: (String, DOMElement) -> String

        init(_ names: Set<String>, _ replacement: @escaping (String, DOMElement) -> String) {
            filter = { names.contains($0.localName) }
            self.replacement = replacement
        }

        init(filter: @escaping (DOMElement) -> Bool, _ replacement: @escaping (String, DOMElement) -> String) {
            self.filter = filter
            self.replacement = replacement
        }
    }

    static let blockElements: Set<String> = [
        "address", "article", "aside", "audio", "blockquote", "body", "canvas", "center", "dd", "dir", "div", "dl",
        "dt", "fieldset", "figcaption", "figure", "footer", "form", "frameset", "h1", "h2", "h3", "h4", "h5", "h6",
        "header", "hgroup", "hr", "html", "isindex", "li", "main", "menu", "nav", "noframes", "noscript", "ol",
        "output", "p", "pre", "section", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
    ]
    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "command", "embed", "hr", "img", "input", "keygen", "link", "meta", "param",
        "source", "track", "wbr",
    ]
    static let meaningfulWhenBlank: Set<String> = [
        "a", "table", "thead", "tbody", "tfoot", "th", "td", "iframe", "script", "audio", "video",
    ]

    /// Custom rules first, then the CommonMark defaults.
    var rules: [Rule] = []
    var keepNames: Set<String> = []
    var removeNames: Set<String> = []

    // MARK: Element classification (HTML elements only, like nodeName checks in the DOM)

    static func isHTML(_ el: DOMElement, _ name: String) -> Bool { el.namespace == .html && el.localName == name }
    static func isBlock(_ node: DOMNode) -> Bool { inSet(node, blockElements) }
    static func isVoid(_ node: DOMNode) -> Bool { inSet(node, voidElements) }
    private static func inSet(_ node: DOMNode, _ set: Set<String>) -> Bool {
        guard let el = node as? DOMElement, el.namespace == .html else { return false }
        return set.contains(el.localName)
    }
    private static func hasDescendant(_ el: DOMElement, in set: Set<String>) -> Bool {
        el.descendantElements().contains { $0.namespace == .html && set.contains($0.localName) }
    }
    static func isPreOrCode(_ node: DOMNode) -> Bool {
        guard let el = node as? DOMElement, el.namespace == .html else { return false }
        return el.localName == "pre" || el.localName == "code"
    }

    func isBlank(_ el: DOMElement) -> Bool {
        !Self.isVoid(el) && !Self.inSet(el, Self.meaningfulWhenBlank) && el.textContent.trimmed.isEmpty
            && !Self.hasDescendant(el, in: Self.voidElements) && !Self.hasDescendant(el, in: Self.meaningfulWhenBlank)
    }

    // MARK: Overridable behavior

    func escape(_ text: String) -> String { Self.escapeMarkdown(text) }

    func keepReplacement(_ el: DOMElement) -> String {
        Self.isBlock(el) ? "\n\n" + el.outerHTML + "\n\n" : el.outerHTML
    }

    // MARK: Conversion

    func turndown(_ html: String) -> String {
        if html.isEmpty { return "" }
        let doc = HTMLParser.parseDocument("<x-turndown id=\"turndown-root\">" + html + "</x-turndown>")
        guard let root = doc.getElementById("turndown-root") else { return "" }
        Self.collapseWhitespace(root)
        let output = process(root, parentIsCode: false)
        return output.joined().jsReplace("^[\\t\\r\\n]+", "", "").jsReplace("[\\t\\r\\n\\s]+$", "", "")
    }

    private func process(_ parent: DOMNode, parentIsCode: Bool) -> [String] {
        var output: [String] = []
        for node in parent.childNodes {
            var replacement = ""
            if let text = node as? DOMText {
                replacement = parentIsCode ? text.data : escape(text.data)
            } else if let el = node as? DOMElement {
                replacement = replacementForNode(el, isCode: el.localName == "code" || parentIsCode)
            }
            Self.join(&output, replacement)
        }
        return output
    }

    private func replacementForNode(_ el: DOMElement, isCode: Bool) -> String {
        let block = Self.isBlock(el)
        let blank = isBlank(el)
        let whitespace = flankingWhitespace(el, isBlock: block, isCode: isCode)
        let rule: ((String, DOMElement) -> String)? = blank ? nil : ruleFor(el)
        var content = process(el, parentIsCode: isCode).joined()
        if !whitespace.leading.isEmpty || !whitespace.trailing.isEmpty { content = content.trimmed }
        let replaced: String
        if let rule {
            replaced = rule(content, el)
        } else {
            replaced = block ? "\n\n" : ""
        }
        return whitespace.leading + replaced + whitespace.trailing
    }

    private func ruleFor(_ el: DOMElement) -> (String, DOMElement) -> String {
        if let rule = rules.first(where: { $0.filter(el) }) { return rule.replacement }
        if keepNames.contains(el.localName) { return { [unowned self] _, node in self.keepReplacement(node) } }
        if removeNames.contains(el.localName) { return { _, _ in "" } }
        return { content, node in Self.isBlock(node) ? "\n\n" + content + "\n\n" : content }
    }

    static func join(_ output: inout [String], _ replacement: String) {
        let tail = output.popLast() ?? ""
        let s1 = trimTrailingNewlines(tail)
        let s2 = trimLeadingNewlines(replacement)
        let newlines = max(tail.utf16.count - s1.utf16.count, replacement.utf16.count - s2.utf16.count)
        let separator = String("\n\n".prefix(newlines))
        if !s1.isEmpty { output.append(s1) }
        if !separator.isEmpty { output.append(separator) }
        if !s2.isEmpty { output.append(s2) }
    }

    static func trimLeadingNewlines(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let index = scalars.firstIndex(where: { $0 != "\n" }) else { return "" }
        return String(scalars[index...])
    }

    static func trimTrailingNewlines(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let index = scalars.lastIndex(where: { $0 != "\n" }) else { return "" }
        return String(scalars[...index])
    }

    static func trimNewlines(_ text: String) -> String { trimTrailingNewlines(trimLeadingNewlines(text)) }

    // MARK: Whitespace

    private struct Flanking { var leading = ""; var trailing = "" }

    private func flankingWhitespace(_ el: DOMElement, isBlock: Bool, isCode: Bool) -> Flanking {
        if isBlock || isCode { return Flanking() }
        let edges = Self.edgeWhitespace(el.textContent)
        var result = Flanking(leading: edges.leading, trailing: edges.trailing)
        if !edges.leadingAscii.isEmpty && isFlankedByWhitespace(left: true, el) { result.leading = edges.leadingNonAscii }
        if !edges.trailingAscii.isEmpty && isFlankedByWhitespace(left: false, el) { result.trailing = edges.trailingNonAscii }
        return result
    }

    private struct Edges {
        var leading = "", leadingAscii = "", leadingNonAscii = ""
        var trailing = "", trailingNonAscii = "", trailingAscii = ""
    }

    private static func isASCIISpace(_ s: Unicode.Scalar) -> Bool { s == " " || s == "\t" || s == "\r" || s == "\n" }
    private static func isSpace(_ s: Unicode.Scalar) -> Bool { CharacterSet.jsWhitespace.contains(s) }

    private static func edgeWhitespace(_ text: String) -> Edges {
        let scalars = Array(text.unicodeScalars)
        var edges = Edges()
        var leadEnd = 0
        while leadEnd < scalars.count && isSpace(scalars[leadEnd]) { leadEnd += 1 }
        var asciiEnd = 0
        while asciiEnd < leadEnd && isASCIISpace(scalars[asciiEnd]) { asciiEnd += 1 }
        func string(_ range: Range<Int>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[range])
            return String(view)
        }
        edges.leading = string(0..<leadEnd)
        edges.leadingAscii = string(0..<asciiEnd)
        edges.leadingNonAscii = string(asciiEnd..<leadEnd)
        if leadEnd == scalars.count { return edges }
        var trailStart = scalars.count
        while trailStart > leadEnd && isSpace(scalars[trailStart - 1]) { trailStart -= 1 }
        var asciiStart = scalars.count
        while asciiStart > trailStart && isASCIISpace(scalars[asciiStart - 1]) { asciiStart -= 1 }
        edges.trailing = string(trailStart..<scalars.count)
        edges.trailingNonAscii = string(trailStart..<asciiStart)
        edges.trailingAscii = string(asciiStart..<scalars.count)
        return edges
    }

    private func isFlankedByWhitespace(left: Bool, _ el: DOMElement) -> Bool {
        guard let sibling = left ? el.previousSibling : el.nextSibling else { return false }
        func test(_ text: String) -> Bool { left ? text.hasSuffix(" ") : text.hasPrefix(" ") }
        if let text = sibling as? DOMText { return test(text.data) }
        if let element = sibling as? DOMElement {
            if Self.isHTML(element, "code") { return false }
            if !Self.isBlock(element) { return test(element.textContent) }
        }
        return false
    }

    static func collapseWhitespace(_ element: DOMElement) {
        if element.firstChild == nil || isPreOrCode(element) { return }
        var prevText: DOMText?
        var keepLeadingWs = false
        var prev: DOMNode?
        var node: DOMNode? = next(prev, element)

        func remove(_ node: DOMNode) -> DOMNode? {
            let following = node.nextSibling ?? node.parentNode
            node.remove()
            return following
        }

        while let current = node, current !== element {
            if let text = current as? DOMText {
                var data = text.data.jsReplace("[ \\r\\n\\t]+", "g", " ")
                if (prevText == nil || prevText!.data.hasSuffix(" ")) && !keepLeadingWs && data.hasPrefix(" ") {
                    data.removeFirst()
                }
                if data.isEmpty {
                    node = remove(current)
                    continue
                }
                text.data = data
                prevText = text
            } else if let el = current as? DOMElement {
                if isBlock(el) || isHTML(el, "br") {
                    if let p = prevText, p.data.hasSuffix(" ") { p.data.removeLast() }
                    prevText = nil
                    keepLeadingWs = false
                } else if isVoid(el) || isPreOrCode(el) {
                    prevText = nil
                    keepLeadingWs = true
                } else if prevText != nil {
                    keepLeadingWs = false
                }
            } else {
                node = remove(current)
                continue
            }
            let nextNode = next(prev, current)
            prev = current
            node = nextNode
        }
        if let p = prevText {
            if p.data.hasSuffix(" ") { p.data.removeLast() }
            if p.data.isEmpty { p.remove() }
        }
    }

    private static func next(_ prev: DOMNode?, _ current: DOMNode) -> DOMNode? {
        if (prev != nil && prev!.parentNode === current) || isPreOrCode(current) {
            return current.nextSibling ?? current.parentNode
        }
        return current.firstChild ?? current.nextSibling ?? current.parentNode
    }

    // MARK: Escaping

    private static let markdownEscapes: [(JSRegex, String)] = [
        (JSRegex("\\\\", "g"), "\\\\"),
        (JSRegex("\\*", "g"), "\\*"),
        (JSRegex("^-", "g"), "\\-"),
        (JSRegex("^\\+ ", "g"), "\\+ "),
        (JSRegex("^(=+)", "g"), "\\$1"),
        (JSRegex("^(#{1,6}) ", "g"), "\\$1 "),
        (JSRegex("`", "g"), "\\`"),
        (JSRegex("^~~~", "g"), "\\~~~"),
        (JSRegex("\\[", "g"), "\\["),
        (JSRegex("\\]", "g"), "\\]"),
        (JSRegex("^>", "g"), "\\>"),
        (JSRegex("_", "g"), "\\_"),
        (JSRegex("^(\\d+)\\. ", "g"), "$1\\. "),
    ]

    static func escapeMarkdown(_ text: String) -> String {
        markdownEscapes.reduce(text) { $1.0.replace($0, $1.1) }
    }
}
