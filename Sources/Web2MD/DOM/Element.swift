import Foundation

public struct DOMAttribute: Sendable, Equatable {
    public var name: String
    public var value: String
}

public final class DOMElement: DOMNode {
    public enum Namespace: Sendable { case html, svg, mathml }

    /// Lowercased tag name for HTML elements.
    public internal(set) var localName: String
    public var namespace: Namespace
    public internal(set) var attributes: [DOMAttribute]

    public init(_ localName: String, namespace: Namespace = .html, attributes: [DOMAttribute] = []) {
        self.localName = localName.lowercased()
        self.namespace = namespace
        self.attributes = attributes
        super.init(nodeType: .element)
    }

    override func shallowCopy() -> DOMNode {
        DOMElement(localName, namespace: namespace, attributes: attributes)
    }

    public func clone(deep: Bool = true) -> DOMElement { cloneNode(deep) as! DOMElement }

    /// Uppercased, like `Element.tagName` in an HTML document.
    public var tagName: String { localName.uppercased() }

    public var namespaceURI: String {
        switch namespace {
        case .html: "http://www.w3.org/1999/xhtml"
        case .svg: "http://www.w3.org/2000/svg"
        case .mathml: "http://www.w3.org/1998/Math/MathML"
        }
    }

    /// Renames the element in place (used when swapping tags keeps children).
    public func setLocalName(_ name: String) { localName = name.lowercased() }

    // MARK: Attributes

    public func getAttribute(_ name: String) -> String? {
        for attribute in attributes where attribute.name == name { return attribute.value }
        return nil
    }

    public func hasAttribute(_ name: String) -> Bool {
        attributes.contains { $0.name == name }
    }

    public func setAttribute(_ name: String, _ value: String) {
        if let index = attributes.firstIndex(where: { $0.name == name }) {
            attributes[index].value = value
        } else {
            attributes.append(DOMAttribute(name: name, value: value))
        }
    }

    public func removeAttribute(_ name: String) {
        attributes.removeAll { $0.name == name }
    }

    public func removeAllAttributes() { attributes.removeAll() }

    public var attributeNames: [String] { attributes.map(\.name) }

    public var id: String {
        get { getAttribute("id") ?? "" }
        set { setAttribute("id", newValue) }
    }

    public var className: String {
        get { getAttribute("class") ?? "" }
        set { setAttribute("class", newValue) }
    }

    public var classList: [String] {
        className.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\u{0C}" }).map(String.init)
    }

    public func hasClass(_ name: String) -> Bool { classList.contains(name) }

    public func addClass(_ name: String) {
        guard !hasClass(name) else { return }
        let current = className
        className = current.isEmpty ? name : current + " " + name
    }

    public func removeClass(_ name: String) {
        guard hasClass(name) else { return }
        className = classList.filter { $0 != name }.joined(separator: " ")
    }

    // MARK: HTML

    public var innerHTML: String {
        get { HTMLSerializer.serializeChildren(of: self) }
        set {
            removeAllChildren()
            for node in HTMLParser.parseFragment(newValue, context: localName) { appendChild(node) }
        }
    }

    public var outerHTML: String { HTMLSerializer.serialize(self) }

    public var isSVG: Bool { namespace == .svg || closest("svg") != nil }
}

extension DOMNode {
    /// `innerHTML` for any container node (elements, fragments, documents).
    public var serializedChildren: String { HTMLSerializer.serializeChildren(of: self) }
}
