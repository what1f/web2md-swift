import Foundation

/// A small, mutable, browser-like DOM. SwiftSoup only tokenizes and builds the
/// initial tree; everything else (queries, mutation, serialization) happens here
/// so the extraction code can mirror the original DOM-based logic closely.
public class DOMNode {
    public enum NodeType: Int, Sendable {
        case element = 1
        case text = 3
        case comment = 8
        case document = 9
        case fragment = 11
    }

    public let nodeType: NodeType
    public internal(set) weak var parentNode: DOMNode?
    public internal(set) var childNodes: [DOMNode] = []
    var siblingIndex = 0

    init(nodeType: NodeType) {
        self.nodeType = nodeType
    }

    // MARK: Identity

    public var nodeName: String {
        switch nodeType {
        case .element: (self as! DOMElement).tagName
        case .text: "#text"
        case .comment: "#comment"
        case .document: "#document"
        case .fragment: "#document-fragment"
        }
    }

    public var isElement: Bool { nodeType == .element }
    public var isText: Bool { nodeType == .text }
    public var asElement: DOMElement? { self as? DOMElement }

    // MARK: Tree navigation

    public var parentElement: DOMElement? { parentNode as? DOMElement }
    public var firstChild: DOMNode? { childNodes.first }
    public var lastChild: DOMNode? { childNodes.last }
    public var hasChildNodes: Bool { !childNodes.isEmpty }

    public var nextSibling: DOMNode? {
        guard let parent = parentNode else { return nil }
        let next = siblingIndex + 1
        return next < parent.childNodes.count ? parent.childNodes[next] : nil
    }

    public var previousSibling: DOMNode? {
        guard let parent = parentNode, siblingIndex > 0 else { return nil }
        return parent.childNodes[siblingIndex - 1]
    }

    public var nextElementSibling: DOMElement? {
        guard let parent = parentNode else { return nil }
        var index = siblingIndex + 1
        while index < parent.childNodes.count {
            if let element = parent.childNodes[index] as? DOMElement { return element }
            index += 1
        }
        return nil
    }

    public var previousElementSibling: DOMElement? {
        guard let parent = parentNode else { return nil }
        var index = siblingIndex - 1
        while index >= 0 {
            if let element = parent.childNodes[index] as? DOMElement { return element }
            index -= 1
        }
        return nil
    }

    public var children: [DOMElement] { childNodes.compactMap { $0 as? DOMElement } }
    public var firstElementChild: DOMElement? {
        for node in childNodes { if let element = node as? DOMElement { return element } }
        return nil
    }
    public var lastElementChild: DOMElement? {
        for node in childNodes.reversed() { if let element = node as? DOMElement { return element } }
        return nil
    }
    public var childElementCount: Int { childNodes.reduce(0) { $0 + ($1.nodeType == .element ? 1 : 0) } }

    /// The root of the tree this node belongs to.
    public var rootNode: DOMNode {
        var node = self
        while let parent = node.parentNode { node = parent }
        return node
    }

    public var ownerDocument: DOMDocument? { rootNode as? DOMDocument }

    /// True if `other` is this node or one of its descendants.
    public func contains(_ other: DOMNode?) -> Bool {
        var node = other
        while let current = node {
            if current === self { return true }
            node = current.parentNode
        }
        return false
    }

    // MARK: Text

    public var textContent: String {
        get {
            switch nodeType {
            case .text: return (self as! DOMText).data
            case .comment: return (self as! DOMComment).data
            default:
                var result = ""
                appendText(into: &result)
                return result
            }
        }
        set {
            switch nodeType {
            case .text: (self as! DOMText).data = newValue
            case .comment: (self as! DOMComment).data = newValue
            default:
                removeAllChildren()
                if !newValue.isEmpty { appendChild(DOMText(newValue)) }
            }
        }
    }

    func appendText(into result: inout String) {
        for child in childNodes {
            switch child.nodeType {
            case .text: result += (child as! DOMText).data
            case .element, .fragment: child.appendText(into: &result)
            default: break
            }
        }
    }

    // MARK: Mutation

    func reindexChildren(from start: Int = 0) {
        var index = start
        while index < childNodes.count {
            childNodes[index].siblingIndex = index
            index += 1
        }
    }

    func detach() {
        guard let parent = parentNode else { return }
        let index = siblingIndex
        if index < parent.childNodes.count, parent.childNodes[index] === self {
            parent.childNodes.remove(at: index)
        } else if let found = parent.childNodes.firstIndex(where: { $0 === self }) {
            parent.childNodes.remove(at: found)
        }
        parent.reindexChildren(from: max(0, index))
        parentNode = nil
        siblingIndex = 0
    }

    /// Nodes that would be inserted for `node`: a fragment contributes its children.
    private func insertionList(_ node: DOMNode) -> [DOMNode] {
        if node.nodeType == .fragment {
            let nodes = node.childNodes
            for child in nodes { child.parentNode = nil }
            node.childNodes.removeAll()
            return nodes
        }
        node.detach()
        return [node]
    }

    @discardableResult
    public func appendChild(_ node: DOMNode) -> DOMNode {
        let nodes = insertionList(node)
        let start = childNodes.count
        for child in nodes { child.parentNode = self }
        childNodes.append(contentsOf: nodes)
        reindexChildren(from: start)
        return node
    }

    @discardableResult
    public func insertBefore(_ node: DOMNode, _ reference: DOMNode?) -> DOMNode {
        guard let reference, reference.parentNode === self else { return appendChild(node) }
        if node === reference { return node }
        let nodes = insertionList(node)
        let index = reference.siblingIndex
        for child in nodes { child.parentNode = self }
        childNodes.insert(contentsOf: nodes, at: index)
        reindexChildren(from: index)
        return node
    }

    @discardableResult
    public func removeChild(_ node: DOMNode) -> DOMNode {
        if node.parentNode === self { node.detach() }
        return node
    }

    @discardableResult
    public func replaceChild(_ newNode: DOMNode, _ oldNode: DOMNode) -> DOMNode {
        guard oldNode.parentNode === self else { return oldNode }
        if newNode === oldNode { return oldNode }
        insertBefore(newNode, oldNode)
        oldNode.detach()
        return oldNode
    }

    public func remove() { detach() }

    public func removeAllChildren() {
        for child in childNodes {
            child.parentNode = nil
            child.siblingIndex = 0
        }
        childNodes.removeAll()
    }

    /// Replaces children with `nodes` (like `replaceChildren`).
    public func replaceChildren(_ nodes: [DOMNode]) {
        removeAllChildren()
        for node in nodes { appendChild(node) }
    }

    public func before(_ nodes: DOMNode...) { before(nodes) }
    public func before(_ nodes: [DOMNode]) {
        guard let parent = parentNode else { return }
        for node in nodes where node !== self { parent.insertBefore(node, self) }
    }

    public func after(_ nodes: DOMNode...) { after(nodes) }
    public func after(_ nodes: [DOMNode]) {
        guard let parent = parentNode else { return }
        let next = nextSibling
        for node in nodes where node !== self { parent.insertBefore(node, next) }
    }

    public func replaceWith(_ nodes: DOMNode...) { replaceWith(nodes) }
    public func replaceWith(_ nodes: [DOMNode]) {
        guard let parent = parentNode else { return }
        let next = nextSibling
        detach()
        for node in nodes { parent.insertBefore(node, next) }
    }

    public func prepend(_ nodes: DOMNode...) {
        let first = firstChild
        for node in nodes { insertBefore(node, first) }
    }

    public func append(_ nodes: DOMNode...) {
        for node in nodes { appendChild(node) }
    }

    /// Merges adjacent text nodes and drops empty ones, recursively.
    public func normalize() {
        var index = 0
        var changed = false
        while index < childNodes.count {
            let child = childNodes[index]
            if let text = child as? DOMText {
                if text.data.isEmpty {
                    child.parentNode = nil
                    childNodes.remove(at: index)
                    changed = true
                    continue
                }
                while index + 1 < childNodes.count, let next = childNodes[index + 1] as? DOMText {
                    text.data += next.data
                    next.parentNode = nil
                    childNodes.remove(at: index + 1)
                    changed = true
                }
            } else if child.nodeType == .element {
                child.normalize()
            }
            index += 1
        }
        if changed { reindexChildren() }
    }

    // MARK: Cloning

    public func cloneNode(_ deep: Bool = false) -> DOMNode {
        let copy = shallowCopy()
        if deep {
            copy.childNodes.reserveCapacity(childNodes.count)
            for (index, child) in childNodes.enumerated() {
                let childCopy = child.cloneNode(true)
                childCopy.parentNode = copy
                childCopy.siblingIndex = index
                copy.childNodes.append(childCopy)
            }
        }
        return copy
    }

    func shallowCopy() -> DOMNode { fatalError("subclass") }

    // MARK: Traversal

    /// All descendant elements in document order (excluding self).
    public func descendantElements() -> [DOMElement] {
        var result: [DOMElement] = []
        collectElements(into: &result)
        return result
    }

    func collectElements(into result: inout [DOMElement]) {
        for child in childNodes where child.nodeType == .element {
            let element = child as! DOMElement
            result.append(element)
            element.collectElements(into: &result)
        }
    }

    /// All descendant nodes in document order (excluding self).
    public func descendantNodes() -> [DOMNode] {
        var result: [DOMNode] = []
        collectNodes(into: &result)
        return result
    }

    func collectNodes(into result: inout [DOMNode]) {
        for child in childNodes {
            result.append(child)
            child.collectNodes(into: &result)
        }
    }

    /// Next node in document order, optionally staying inside `root`.
    public func nextInTree(within root: DOMNode? = nil, skipChildren: Bool = false) -> DOMNode? {
        if !skipChildren, let first = childNodes.first { return first }
        var node: DOMNode? = self
        while let current = node, current !== root {
            if let next = current.nextSibling { return next }
            node = current.parentNode
        }
        return nil
    }

    public func getElementsByTagName(_ name: String) -> [DOMElement] {
        let wanted = name.lowercased()
        if wanted == "*" { return descendantElements() }
        var result: [DOMElement] = []
        func walk(_ node: DOMNode) {
            for child in node.childNodes where child.nodeType == .element {
                let element = child as! DOMElement
                if element.localName == wanted { result.append(element) }
                walk(element)
            }
        }
        walk(self)
        return result
    }

    public func getElementById(_ id: String) -> DOMElement? {
        func walk(_ node: DOMNode) -> DOMElement? {
            for child in node.childNodes where child.nodeType == .element {
                let element = child as! DOMElement
                if element.getAttribute("id") == id { return element }
                if let found = walk(element) { return found }
            }
            return nil
        }
        return walk(self)
    }
}

public final class DOMText: DOMNode {
    public var data: String

    public init(_ data: String) {
        self.data = data
        super.init(nodeType: .text)
    }

    override func shallowCopy() -> DOMNode { DOMText(data) }
}

public final class DOMComment: DOMNode {
    public var data: String

    public init(_ data: String) {
        self.data = data
        super.init(nodeType: .comment)
    }

    override func shallowCopy() -> DOMNode { DOMComment(data) }
}

public final class DOMFragment: DOMNode {
    public init() { super.init(nodeType: .fragment) }
    override func shallowCopy() -> DOMNode { DOMFragment() }
}

public final class DOMDocument: DOMNode {
    /// The page URL, used for resolving relative links.
    public var url: String

    public init(url: String = "") {
        self.url = url
        super.init(nodeType: .document)
    }

    override func shallowCopy() -> DOMNode { DOMDocument(url: url) }

    public var documentElement: DOMElement? { firstElementChild }

    public var head: DOMElement? {
        documentElement?.children.first { $0.localName == "head" }
    }

    public var body: DOMElement? {
        documentElement?.children.first { $0.localName == "body" }
    }

    public var title: String {
        querySelector("title")?.textContent.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public func createElement(_ tag: String) -> DOMElement { DOMElement(tag) }
    public func createTextNode(_ text: String) -> DOMText { DOMText(text) }
    public func createDocumentFragment() -> DOMFragment { DOMFragment() }
    public func createComment(_ text: String) -> DOMComment { DOMComment(text) }

    public func cloneDocument() -> DOMDocument { cloneNode(true) as! DOMDocument }
}
