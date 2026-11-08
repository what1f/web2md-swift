import Foundation
import SwiftSoup

/// Builds `DOMDocument` trees using SwiftSoup's HTML5 tree builder.
public enum HTMLParser {
    private static func makeParser() -> Parser {
        // Lowercase tag names, keep attribute case (like linkedom, e.g. `viewBox`, `srcSet`).
        Parser.htmlParser().settings(ParseSettings(false, true))
    }

    public static func parseDocument(_ html: String, url: String = "") -> DOMDocument {
        let document = DOMDocument(url: url)
        let html = emptyInertTemplates(html)
        guard let soup = try? makeParser().parseInput(html, url) else {
            let htmlElement = DOMElement("html")
            htmlElement.appendChild(DOMElement("head"))
            htmlElement.appendChild(DOMElement("body"))
            document.appendChild(htmlElement)
            return document
        }
        for child in soup.getChildNodes() {
            if let converted = convert(child, namespace: .html) { document.appendChild(converted) }
        }
        if document.documentElement == nil {
            let htmlElement = DOMElement("html")
            htmlElement.appendChild(DOMElement("head"))
            htmlElement.appendChild(DOMElement("body"))
            document.appendChild(htmlElement)
        }
        return document
    }

    /// Template content is inert and lives outside the document tree. SwiftSoup
    /// parses it inline, where a `<div>` inside the template closes an enclosing
    /// `<p>`, so drop it up front. Declarative shadow roots are kept.
    static func emptyInertTemplates(_ html: String) -> String {
        guard html.range(of: "<template", options: .caseInsensitive) != nil else { return html }
        return html.jsReplace("(<template\\b(?![^>]*\\bshadowroot)[^>]*>)[\\s\\S]*?(<\\/template\\s*>)", "gi", "$1$2")
    }

    /// Parses an HTML fragment as if it were assigned to `innerHTML` of an
    /// element named `context`.
    public static func parseFragment(_ html: String, context: String = "div") -> [DOMNode] {
        guard !html.isEmpty else { return [] }
        let leading = html.drop(while: { $0.isWhitespace }).prefix(10).lowercased()
        let wrapperPath: [String]
        let prefix: String
        let suffix: String
        if leading.hasPrefix("<tr") {
            prefix = "<table><tbody>"; suffix = "</tbody></table>"; wrapperPath = ["table", "tbody"]
        } else if leading.hasPrefix("<td") || leading.hasPrefix("<th") && !leading.hasPrefix("<thead") {
            prefix = "<table><tbody><tr>"; suffix = "</tr></tbody></table>"; wrapperPath = ["table", "tbody", "tr"]
        } else if ["<thead", "<tbody", "<tfoot", "<caption", "<colgroup", "<col"].contains(where: { leading.hasPrefix($0) }) {
            prefix = "<table>"; suffix = "</table>"; wrapperPath = ["table"]
        } else {
            prefix = ""; suffix = ""; wrapperPath = []
        }
        let source = "<html><head></head><body>" + prefix + html + suffix + "</body></html>"
        guard let soup = try? makeParser().parseInput(source, ""), let body = soup.body() else { return [] }
        var container: SwiftSoup.Element = body
        for tag in wrapperPath {
            guard let next = container.children().first(where: { $0.tagName() == tag }) else { break }
            container = next
        }
        let namespace: DOMElement.Namespace = context == "svg" ? .svg : context == "math" ? .mathml : .html
        return container.getChildNodes().compactMap { convert($0, namespace: namespace) }
    }

    /// Parses a fragment into a detached `DOMFragment`.
    public static func fragment(_ html: String, context: String = "div") -> DOMFragment {
        let fragment = DOMFragment()
        for node in parseFragment(html, context: context) { fragment.appendChild(node) }
        return fragment
    }

    private static func convert(_ node: SwiftSoup.Node, namespace parentNamespace: DOMElement.Namespace) -> DOMNode? {
        if let element = node as? SwiftSoup.Element {
            let tag = element.tagName()
            var namespace = parentNamespace
            if tag == "svg" { namespace = .svg }
            else if tag == "math" { namespace = .mathml }
            var attributes: [DOMAttribute] = []
            if let list = element.getAttributes()?.asList() {
                attributes.reserveCapacity(list.count)
                for attribute in list {
                    attributes.append(DOMAttribute(name: attribute.getKey(), value: attribute.getValue()))
                }
            }
            let result = DOMElement(tag, namespace: namespace, attributes: attributes)
            let childNamespace: DOMElement.Namespace =
                (namespace == .svg && tag == "foreignobject") ? .html : namespace
            let children = element.getChildNodes()
            result.childNodes.reserveCapacity(children.count)
            for child in children {
                if let converted = convert(child, namespace: childNamespace) {
                    converted.parentNode = result
                    converted.siblingIndex = result.childNodes.count
                    result.childNodes.append(converted)
                }
            }
            return result
        }
        if let data = node as? SwiftSoup.DataNode { return DOMText(data.getWholeData()) }
        if let text = node as? SwiftSoup.TextNode { return DOMText(text.getWholeText()) }
        if let comment = node as? SwiftSoup.Comment { return DOMComment(comment.getData()) }
        return nil
    }
}
