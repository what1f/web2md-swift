// Port of defuddle src/utils.ts and src/utils/dom.ts.
// Copyright (c) 2025 Steph Ango (@kepano), MIT License.

import Foundation
import SwiftSoup

enum Utils {
    static let cjkCharRanges = "\\u3040-\\u309f\\u30a0-\\u30ff\\u3400-\\u4dbf\\u4e00-\\u9fff\\uf900-\\ufaff\\uac00-\\ud7af"

    static func textPreview(_ element: DOMElement) -> String {
        element.textContent.trimmed.jsSubstring(0, 200)
    }

    static func normalizeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .jsReplace("[\\u2018\\u2019\\u201A\\u201B]", "g", "'")
            .jsReplace("[\\u2012\\u2013\\u2014\\u2015]", "g", "-")
            .jsReplace("[\\u201C\\u201D\\u201E\\u201F]", "g", "\"")
            .replacingOccurrences(of: "\u{2026}", with: "...")
            .jsReplace("\\s+", "g", " ")
            .trimmed
            .lowercased()
    }

    static func countWords(_ text: String) -> Int { TextMetrics.countWords(text) }

    static func transferContent(_ source: DOMNode, _ target: DOMNode) {
        target.removeAllChildren()
        while let child = source.firstChild { target.appendChild(child) }
    }

    /// Decodes HTML entities (`&amp;` → `&`).
    static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return (try? Entities.unescape(text)) ?? text
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func className(_ element: DOMElement) -> String { element.getAttribute("class") ?? "" }

    static func hasResponsiveShowClass(_ className: String) -> Bool {
        className.jsSplit("\\s+").contains {
            $0.jsTest("^(sm|md|lg|xl|2xl|min-\\[|max-\\[):(?:block|flex|grid|inline|table|contents)")
        }
    }

    static func isDangerousURL(_ url: String, allowInlineImage: Bool = true) -> Bool {
        let normalized = url.jsReplace("[\\s\\u0000-\\u001F]+", "g", "").lowercased()
        if normalized.hasPrefix("javascript:") || normalized.hasPrefix("blob:") { return true }
        if normalized.hasPrefix("data:") { return !(allowInlineImage && normalized.hasPrefix("data:image/")) }
        return false
    }

    private static let unsafeTags: Set<String> = [
        "SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "FRAME", "FRAMESET", "OBJECT", "EMBED", "APPLET", "BASE",
        "ANIMATE", "SET", "ANIMATEMOTION", "ANIMATETRANSFORM", "ANIMATECOLOR", "DISCARD",
    ]
    private static let unsafeSelector =
        "script:not([type^=\"math/\"]), style, noscript, template, frame, frameset, object, embed, applet, base, "
        + "animate, set, animatemotion, animatetransform, animatecolor, discard, "
        + "animateMotion, animateTransform, animateColor"
    private static let urlAttributes: Set<String> = ["href", "src", "action", "formaction", "xlink:href"]

    private static func isUnsafe(_ element: DOMElement) -> Bool {
        let tag = element.tagName
        if tag == "SCRIPT" { return !(element.getAttribute("type") ?? "").lowercased().hasPrefix("math/") }
        return unsafeTags.contains(tag)
    }

    /// Removes scripts, styles, event handlers and dangerous URLs. Returns true
    /// when the root itself is unsafe and must not be serialized.
    @discardableResult
    static func stripUnsafeElements(_ root: DOMElement) -> Bool {
        let unsafeRoot = isUnsafe(root)
        if unsafeRoot {
            root.removeAllAttributes()
            root.removeAllChildren()
        }
        for element in root.querySelectorAll(unsafeSelector) { element.remove() }
        for element in [root] + root.querySelectorAll("*") {
            for attribute in element.attributes {
                let name = attribute.name.lowercased()
                if name.hasPrefix("on") || name == "srcdoc" {
                    element.removeAttribute(attribute.name)
                } else if urlAttributes.contains(name) {
                    let allowInlineImage = !(name == "src" && element.tagName == "IFRAME")
                    if isDangerousURL(attribute.value, allowInlineImage: allowInlineImage) {
                        element.removeAttribute(attribute.name)
                    }
                }
            }
        }
        return unsafeRoot
    }

    static func isDirectTableChild(_ node: DOMNode, _ ancestor: DOMNode) -> Bool {
        var parent = node.parentNode
        while let current = parent, current !== ancestor {
            if current.nodeName == "TABLE" { return false }
            parent = current.parentNode
        }
        return parent === ancestor
    }

    static func isNodeBefore(_ node: DOMNode, _ other: DOMNode) -> Bool {
        if node === other { return false }
        func ancestors(_ current: DOMNode) -> [DOMNode] {
            var path: [DOMNode] = []
            var node: DOMNode? = current
            while let n = node { path.append(n); node = n.parentNode }
            return path
        }
        var left = ancestors(node)
        var right = ancestors(other)
        if left.last !== right.last { return false }
        while let l = left.last, let r = right.last, l === r {
            left.removeLast()
            right.removeLast()
        }
        guard let leftTop = left.last else { return true }
        guard let rightTop = right.last else { return false }
        var sibling = leftTop.nextSibling
        while let s = sibling {
            if s === rightTop { return true }
            sibling = s.nextSibling
        }
        return false
    }

    static func parseHTML(_ html: String, context: String = "template") -> DOMFragment {
        guard !html.isEmpty else { return DOMFragment() }
        return HTMLParser.fragment(html, context: context == "template" ? "body" : context)
    }

    static func classOrIdSelector(_ attribute: String, _ value: String) -> String? {
        if value.isEmpty || value.jsTest("\\u0000|[^\\S\\t\\n\\f\\r ]") { return nil }
        if value.jsTest("^(?:--|-?[a-zA-Z_])[a-zA-Z0-9_-]*$") { return (attribute == "class" ? "." : "#") + value }
        var escaped = value.jsReplace("[\"\\\\]", "g", "\\$&")
        escaped = JSRegex("[\\x01-\\x1f\\x7f]", "g").replace(escaped) { match in
            "\\" + String(match.value.utf16.first ?? 0, radix: 16) + " "
        }
        return "[\(attribute)\(attribute == "class" ? "~" : "")=\"\(escaped)\"]"
    }
}

extension DOMNode {
    /// `Array.from(querySelectorAll(...))` shorthand.
    func all(_ selector: String) -> [DOMElement] { querySelectorAll(selector) }
}
