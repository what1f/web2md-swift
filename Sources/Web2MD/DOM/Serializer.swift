import Foundation

/// Serializes the DOM the way linkedom does, which is what upstream Defuddle's
/// expected output was produced with.
enum HTMLSerializer {
    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "keygen", "link",
        "menuitem", "meta", "param", "source", "track", "wbr",
    ]
    static let rawTextElements: Set<String> = ["script", "style"]
    /// Attributes printed without a value when empty.
    static let emptyAttributes: Set<String> = [
        "allowfullscreen", "allowpaymentrequest", "async", "autofocus", "autoplay", "checked",
        "class", "contenteditable", "controls", "default", "defer", "disabled", "draggable",
        "formnovalidate", "hidden", "id", "ismap", "itemscope", "loop", "multiple", "muted",
        "nomodule", "novalidate", "open", "playsinline", "readonly", "required", "reversed",
        "selected", "style", "truespeed",
    ]

    static func serialize(_ node: DOMNode) -> String {
        var out = ""
        write(node, into: &out)
        return out
    }

    static func serializeChildren(of node: DOMNode) -> String {
        var out = ""
        for child in node.childNodes { write(child, into: &out) }
        return out
    }

    static func write(_ node: DOMNode, into out: inout String) {
        switch node.nodeType {
        case .text:
            let text = node as! DOMText
            if let parent = node.parentNode as? DOMElement, rawTextElements.contains(parent.localName) {
                out += text.data
            } else {
                out += escapeText(text.data)
            }
        case .comment:
            out += "<!--" + (node as! DOMComment).data + "-->"
        case .element:
            let element = node as! DOMElement
            out += "<" + element.localName
            for attribute in element.attributes {
                if attribute.value.isEmpty, emptyAttributes.contains(attribute.name) {
                    if attribute.name == "id" || attribute.name == "class" || attribute.name == "style" { continue }
                    out += " " + attribute.name
                } else {
                    out += " " + attribute.name + "=\"" + attribute.value.replacingOccurrences(of: "\"", with: "&quot;") + "\""
                }
            }
            if element.childNodes.isEmpty {
                if element.namespace == .svg {
                    out += " />"
                } else if voidElements.contains(element.localName) {
                    out += ">"
                } else {
                    out += "></" + element.localName + ">"
                }
                return
            }
            out += ">"
            for child in element.childNodes { write(child, into: &out) }
            out += "</" + element.localName + ">"
        case .document, .fragment:
            for child in node.childNodes { write(child, into: &out) }
        }
    }

    static func escapeText(_ text: String) -> String {
        guard text.contains(where: { $0 == "&" || $0 == "<" || $0 == ">" || $0 == "\u{A0}" }) else { return text }
        var result = ""
        result.reserveCapacity(text.utf8.count + 16)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\u{A0}": result += "&#160;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
