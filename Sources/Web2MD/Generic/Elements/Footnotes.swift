// Port of defuddle src/elements/footnotes.ts.
// Copyright (c) 2025 Steph Ango (@kepano), MIT License.

import Foundation

enum Footnotes {
    static let sectionPattern = JSRegex("^(foot\\s*notes?|end\\s*notes?|notes?|references?)$", "i")
    fileprivate static let backrefSymbols = JSRegex("^[\\^\\u21A9\\u21A5\\u2191\\u21B5\\u2934\\u2935\\u23CE]+$")
    fileprivate static let citeRef = JSRegex("^#cite_ref-")
    fileprivate static let marker = JSRegex("^\\[?\\(?(\\d{1,4})\\)?\\]?$")

    fileprivate static func hrefFragment(_ anchor: DOMElement?) -> String {
        let href = anchor?.getAttribute("href") ?? ""
        return (href.components(separatedBy: "#").last ?? "").lowercased()
    }

    fileprivate struct Extractor: Sendable {
        let selector: String
        let extract: @Sendable (DOMElement) -> String
    }

    fileprivate static let inlineRefExtractors: [Extractor] = [
        Extractor(selector: "sup.footnoteref") { el in
            el.querySelector("a[id^=\"footnoteref-\"]")?.id.jsMatch("^footnoteref-(\\d+)$")?[1] ?? ""
        },
        Extractor(selector: "a[id^=\"ref-link\"]") { $0.textContent.trimmed },
        Extractor(selector: "a[role=\"doc-biblioref\"]") { el in
            if let rid = el.getAttribute("data-xml-rid"), !rid.isEmpty { return rid }
            let href = el.getAttribute("href") ?? ""
            return href.hasPrefix("#core-R") ? href.replacingOccurrences(of: "#core-", with: "") : ""
        },
        Extractor(selector: "a.footnote-anchor, span.footnote-hovercard-target a") { el in
            el.id.jsReplace("footnote-anchor-", "", "").lowercased()
        },
        Extractor(selector: "sup.reference") { el in
            var id = ""
            for link in el.all("a") {
                let href = link.getAttribute("href") ?? ""
                if let match = (href.components(separatedBy: "/").last ?? "").jsMatch("(?:cite_note|cite_ref)-(.+)") {
                    id = (match[1] ?? "").lowercased()
                }
            }
            return id
        },
        Extractor(selector: "sup[id^=\"fnref:\"], span[id^=\"fnref:\"]") { $0.id.jsReplace("fnref:", "", "").lowercased() },
        Extractor(selector: "sup[id^=\"fnr\"]") { $0.id.jsReplace("fnr", "", "").lowercased() },
        Extractor(selector: "sup.footnote-reference") { hrefFragment($0.querySelector("a[href^=\"#\"]")) },
        Extractor(selector: "span.footnote-reference") { el in
            if let attr = el.getAttribute("data-footnote-id"), !attr.isEmpty { return attr }
            return el.id.hasPrefix("fnref") ? el.id.jsReplace("fnref", "", "").lowercased() : ""
        },
        Extractor(selector: "span.footnote-link") { $0.getAttribute("data-footnote-id") ?? "" },
        Extractor(selector: "a.citation") { $0.textContent.trimmed },
        Extractor(selector: "a[id^=\"fnref\"]") { $0.id.jsReplace("fnref", "", "").lowercased() },
        Extractor(selector: "a[data-type=\"noteref\"]") { hrefFragment($0) },
    ]

    static func standardize(_ element: DOMElement) {
        FootnoteHandler().standardizeFootnotes(element)
    }
}

private final class FootnoteData {
    var content: DOMElement
    var originalId: String
    var refs: [String]

    init(content: DOMElement, originalId: String, refs: [String] = []) {
        self.content = content
        self.originalId = originalId
        self.refs = refs
    }
}

private typealias FootnoteCollection = [Int: FootnoteData]

private final class CollectState {
    var footnotes: FootnoteCollection = [:]
    var processedIds = Set<String>()
    var count = 1
}

private final class FootnoteHandler {
    let doc = DOMDocument()
    var pendingRemovals: [DOMElement] = []

    private func makeRefId(_ number: String, _ refsCount: Int) -> String {
        refsCount > 0 ? "fnref:\(number)-\(refsCount + 1)" : "fnref:\(number)"
    }

    private func merge(_ target: inout FootnoteCollection, _ source: FootnoteCollection) {
        for (key, data) in source where target[key] == nil { target[key] = data }
    }

    @discardableResult
    private func addFootnote(_ state: CollectState, _ id: String, _ content: DOMElement, explicitNum: Int? = nil) -> Bool {
        if id.isEmpty || state.processedIds.contains(id) { return false }
        let key = explicitNum ?? state.count
        state.footnotes[key] = FootnoteData(content: content, originalId: id)
        state.processedIds.insert(id)
        if let explicitNum {
            if explicitNum >= state.count { state.count = explicitNum + 1 }
        } else {
            state.count += 1
        }
        return true
    }

    func createFootnoteItem(_ number: Int, _ content: DOMElement, _ refs: [String]) -> DOMElement {
        let item = doc.createElement("li")
        item.setAttribute("class", "footnote")
        item.setAttribute("id", "fn:\(number)")
        let children = content.children
        let hasParagraphs = children.contains { $0.localName == "p" }
        let hasBlocks = children.contains { Constants.blockLevelElements.contains($0.localName) }
        if !hasParagraphs && !hasBlocks {
            let p = doc.createElement("p")
            Utils.transferContent(content, p)
            removeBackrefs(p)
            item.appendChild(p)
        } else if !hasParagraphs {
            for child in children where !isBackrefLink(child) {
                let clone = child.clone()
                removeBackrefs(clone)
                item.appendChild(clone)
            }
        } else {
            for child in children where !isBackrefLink(child) {
                if child.localName == "p" {
                    if child.textContent.trimmed.isEmpty && child.querySelector("img, br") == nil { continue }
                    let p = doc.createElement("p")
                    Utils.transferContent(child, p)
                    removeBackrefs(p)
                    item.appendChild(p)
                } else {
                    let clone = child.clone()
                    removeBackrefs(clone)
                    item.appendChild(clone)
                }
            }
        }
        let lastParagraph = item.querySelector("p:last-of-type") ?? item
        for (index, refId) in refs.enumerated() {
            let backlink = doc.createElement("a")
            backlink.setAttribute("href", "#\(refId)")
            backlink.setAttribute("title", "return to article")
            backlink.setAttribute("class", "footnote-backref")
            backlink.textContent = index < refs.count - 1 ? "↩ " : "↩"
            lastParagraph.appendChild(backlink)
        }
        return item
    }

    func collectFootnotes(_ element: DOMElement) -> FootnoteCollection {
        let state = CollectState()
        for list in element.all(Constants.footnoteListSelectors) {
            if list.matches("div.footnotes-footer") {
                for div in list.all("div.footnote-footer") {
                    guard let id = div.id.jsMatch("^footnote-(\\d+)$")?[1], !state.processedIds.contains(id) else { continue }
                    let clone = div.clone()
                    clone.querySelector("a")?.remove()
                    let text = clone.innerHTML.jsReplace("^\\s*\\.\\s*", "", "")
                    let contentDiv = doc.createElement("div")
                    contentDiv.appendChild(Utils.parseHTML(text.trimmed))
                    addFootnote(state, id, contentDiv)
                }
                continue
            }
            if list.matches("div.footnote-definition") && !(list.parentElement?.matches("div.footnote-definitions") ?? false) {
                let clone = list.clone()
                clone.querySelector("sup.footnote-definition-label")?.remove()
                addFootnote(state, list.id.lowercased(), clone)
                continue
            }
            if list.matches("div.footnote-definitions") {
                for def in list.all("div.footnote-definition") {
                    guard let sup = def.querySelector("sup[id]"), let body = def.querySelector(".footnote-body") else { continue }
                    addFootnote(state, sup.id.lowercased(), body.clone())
                }
                if let parent = list.parentElement, parent !== element, parent.hasClass("footnotes") {
                    pendingRemovals.append(parent)
                }
                continue
            }
            if list.matches("ol.easy-footnotes-wrapper") {
                for li in list.all("li.easy-footnote-single") {
                    guard let idSpan = li.querySelector("span[id^=\"easy-footnote-bottom-\"]") else { continue }
                    let clone = li.clone()
                    clone.querySelector("span[id^=\"easy-footnote-bottom-\"]")?.remove()
                    clone.querySelector("a.easy-footnote-to-top")?.remove()
                    addFootnote(state, idSpan.id.lowercased(), clone)
                }
                pendingRemovals.append(contentsOf: element.all("span.easy-footnote-margin-adjust"))
                continue
            }
            if list.matches("div.footnotes-segment") {
                for heading in list.all("h5.footnote-body-heading") {
                    let id = (heading.querySelector("a[id]")?.id ?? "").lowercased()
                    if id.isEmpty { continue }
                    let contentDiv = doc.createElement("div")
                    var sibling = heading.nextElementSibling
                    while let s = sibling, !(s.localName == "h5" && s.hasClass("footnote-body-heading")) {
                        if !s.textContent.trimmed.isEmpty || s.querySelector("img, br") != nil { contentDiv.appendChild(s.clone()) }
                        sibling = s.nextElementSibling
                    }
                    addFootnote(state, id, contentDiv)
                }
                pendingRemovals.append(list)
                continue
            }
            if list.matches("div.footnote[data-component-name=\"FootnoteToDOM\"]") {
                if let anchor = list.querySelector("a.footnote-number"), let content = list.querySelector(".footnote-content") {
                    addFootnote(state, anchor.id.jsReplace("footnote-", "", "").lowercased(), content)
                }
                continue
            }
            for li in list.all("li, div[role=\"listitem\"]") {
                let (id, content) = extractListItemIdAndContent(li)
                addFootnote(state, id, content ?? li)
            }
        }

        let fallbacks: [(DOMElement, CollectState) -> Void] = [
            tryDataTypeFootnotes, tryGenericIdDetection, tryWordExport, tryGoogleDocs, tryLabeledSection,
            tryLooseFootnotes, tryClassFootnote, tryBrSeparatedFootnotes,
        ]
        for fallback in fallbacks {
            if state.count > 1 { break }
            fallback(element, state)
        }
        return state.footnotes
    }

    private func tryDataTypeFootnotes(_ element: DOMElement, _ state: CollectState) {
        for def in element.all("p[data-type=\"footnote\"][id]") {
            let id = def.id.lowercased()
            if id.isEmpty { continue }
            let contentDiv = doc.createElement("div")
            let clone = def.clone()
            if let marker = clone.firstElementChild, marker.localName == "sup", marker.querySelector("a[href*=\"#\"]") != nil {
                marker.remove()
                trimLeadingWhitespace(clone)
            }
            contentDiv.appendChild(clone)
            addFootnote(state, id, contentDiv)
            pendingRemovals.append(def)
        }
    }

    private func tryGenericIdDetection(_ element: DOMElement, _ state: CollectState) {
        var candidateRefs: [String: [DOMElement]] = [:]
        var order: [String] = []
        for a in element.all("a[href*=\"#\"]") {
            let fragment = Footnotes.hrefFragment(a)
            if fragment.isEmpty || !Footnotes.marker.test(a.textContent.trimmed) { continue }
            if candidateRefs[fragment] == nil { order.append(fragment) }
            candidateRefs[fragment, default: []].append(a)
        }
        if candidateRefs.count < 2 { return }
        let fragmentSet = Set(candidateRefs.keys)
        var best: DOMElement?
        var bestCount = 0
        for container in element.all("div, section, aside, footer, ol, ul") where container !== element {
            let count = findMatchingFootnoteElements(container, fragmentSet).count
            if count >= 2 && count >= bestCount {
                bestCount = count
                best = container
            }
        }
        guard var bestContainer = best else { return }
        let ordered = findMatchingFootnoteElements(bestContainer, fragmentSet)
        let footnoteFragments = Set(ordered.map(\.id))
        var externalTotal = 0
        var externalMatch = 0
        for fragment in order {
            let anchors = candidateRefs[fragment] ?? []
            if anchors.contains(where: { bestContainer.contains($0) }) { continue }
            externalTotal += 1
            if footnoteFragments.contains(fragment) { externalMatch += 1 }
        }
        var keepContainer = true
        if externalMatch < max(2, Int((Double(externalTotal) * 0.75).rounded(.up))) { keepContainer = false }

        for (el, id) in ordered {
            if state.processedIds.contains(id) { continue }
            let contentDiv = doc.createElement("div")
            let clone = el.clone()
            if let idAnchor = clone.all("a[id]").first(where: { $0.getAttribute("id") == id }) {
                let text = idAnchor.textContent.trimmed
                if text.isEmpty || text.jsTest("^\\d+[.)]*\\s*$") { idAnchor.remove() }
            }
            if let named = clone.querySelector("a[name]"), named.getAttribute("name")?.lowercased() == id { named.remove() }
            if let first = clone.childNodes.first as? DOMText {
                first.data = first.data.jsReplace("^\\d+\\.\\s*", "", "").jsReplace("^\\s+", "", "")
            }
            if clone.matches("li") { Utils.transferContent(clone, contentDiv) } else { contentDiv.appendChild(clone) }
            var sibling = el.nextElementSibling
            while let s = sibling, s.id.isEmpty {
                let anchorId = getChildAnchorId(s)
                if !anchorId.isEmpty && fragmentSet.contains(anchorId) { break }
                contentDiv.appendChild(s.clone())
                sibling = s.nextElementSibling
            }
            addFootnote(state, id, contentDiv)
        }
        if keepContainer { pendingRemovals.append(bestContainer) }
        bestContainer = element
    }

    private func tryWordExport(_ element: DOMElement, _ state: CollectState) {
        let backrefs = element.all("a[href*=\"#_ftnref\"]")
        if backrefs.count < 2 { return }
        var pairs: [(Int, DOMElement)] = []
        for anchor in backrefs {
            if let num = jsParseInt(Footnotes.hrefFragment(anchor).jsMatch("^_ftnref(\\d+)$")?[1]) { pairs.append((num, anchor)) }
        }
        pairs = pairs.enumerated().sorted { $0.element.0 != $1.element.0 ? $0.element.0 < $1.element.0 : $0.offset < $1.offset }.map(\.element)
        for (num, anchor) in pairs {
            let originalId = "_ftn\(num)"
            if state.processedIds.contains(originalId) { continue }
            var container = anchor.parentElement
            while let c = container, c !== element {
                if ["p", "div", "li"].contains(c.localName) { break }
                container = c.parentElement
            }
            guard let found = container, found !== element else { continue }
            let clone = found.clone()
            if let backref = clone.querySelector("a[href*=\"_ftnref\"]") {
                if let sup = backref.closest("sup") { sup.remove() } else { backref.remove() }
            }
            let contentDiv = doc.createElement("div")
            contentDiv.appendChild(clone)
            addFootnote(state, originalId, contentDiv, explicitNum: num)
            pendingRemovals.append(found)
        }
    }

    private func tryGoogleDocs(_ element: DOMElement, _ state: CollectState) {
        var pairs: [(Int, DOMElement)] = []
        for p in element.all("p[id^=\"ftnt\"]") {
            if let num = jsParseInt(p.id.jsMatch("^ftnt(\\d+)$")?[1]) { pairs.append((num, p)) }
        }
        if pairs.count < 2 { return }
        pairs = pairs.enumerated().sorted { $0.element.0 != $1.element.0 ? $0.element.0 < $1.element.0 : $0.offset < $1.offset }.map(\.element)
        for (num, el) in pairs {
            let originalId = "ftnt\(num)"
            if state.processedIds.contains(originalId) { continue }
            let clone = el.clone()
            clone.querySelector("a[href*=\"#ftnt_ref\"]")?.remove()
            let contentDiv = doc.createElement("div")
            contentDiv.appendChild(clone)
            addFootnote(state, originalId, contentDiv, explicitNum: num)
            pendingRemovals.append(el)
            if let parent = el.parentElement, parent !== element, parent.localName == "div", parent.children.count == 1 {
                pendingRemovals.append(parent)
            }
        }
        let first = pairs[0].1
        let scanFrom: DOMElement
        if let parent = first.parentElement, parent !== element, parent.localName == "div" { scanFrom = parent } else { scanFrom = first }
        if let prev = scanFrom.previousElementSibling, prev.localName.jsTest("^h[1-6]$"),
           Footnotes.sectionPattern.test(prev.textContent.trimmed) {
            pendingRemovals.append(prev)
        }
    }

    private func tryLooseFootnotes(_ element: DOMElement, _ state: CollectState) {
        guard let (paragraphs, toRemove) = findLooseFootnoteParagraphs(element) else { return }
        for (index, entry) in paragraphs.enumerated() {
            let nextDef = index + 1 < paragraphs.count ? paragraphs[index + 1].1 : nil
            let contentDiv = stripMarkerAndWrap(entry.1)
            var sibling = entry.1.nextElementSibling
            while let s = sibling, s !== nextDef, toRemove.contains(where: { $0 === s }) {
                contentDiv.appendChild(s.clone())
                sibling = s.nextElementSibling
            }
            addFootnote(state, String(entry.0), contentDiv)
        }
        pendingRemovals.append(contentsOf: toRemove)
    }

    private func tryClassFootnote(_ element: DOMElement, _ state: CollectState) {
        var paragraphs: [(Int, DOMElement)] = []
        for p in element.all("p.footnote") {
            if let num = parseFootnoteNum(p) { paragraphs.append((num, p)) }
        }
        for (num, p) in paragraphs { addFootnote(state, String(num), stripMarkerAndWrap(p)) }
        pendingRemovals.append(contentsOf: paragraphs.map(\.1))
    }

    private func tryLabeledSection(_ element: DOMElement, _ state: CollectState) {
        for container in element.all("div, section, aside") {
            let className = container.className
            if !className.jsTest("footnote", "i") && !container.id.jsTest("footnote", "i") { continue }
            guard let heading = container.querySelector("h1, h2, h3, h4, h5, h6"),
                  Footnotes.sectionPattern.test(heading.textContent.trimmed) else { continue }
            if !collectSectionParagraphs(container, state) && !collectSectionList(container, state) { continue }
            pendingRemovals.append(container)
            break
        }
    }

    private func tryBrSeparatedFootnotes(_ element: DOMElement, _ state: CollectState) {
        var linked = Set<String>()
        for a in element.all("a[href^=\"#\"]") where Footnotes.marker.test(a.textContent.trimmed) {
            let fragment = Footnotes.hrefFragment(a)
            if !fragment.isEmpty { linked.insert(fragment) }
        }
        if linked.count < 2 { return }
        for block in element.all("p, div") {
            if block.querySelector("br") == nil { continue }
            var defs: [(String, [DOMNode])] = []
            for nodes in splitOnBreaks(block) {
                guard let anchor = leadingAnchor(nodes) else { continue }
                let id = (anchor.getAttribute("name") ?? (anchor.id.isEmpty ? "" : anchor.id)).lowercased()
                if id.isEmpty || !linked.contains(id) { continue }
                defs.append((id, nodes.filter { $0 !== anchor }))
            }
            if defs.count < 2 { continue }
            for (id, nodes) in defs {
                let contentDiv = doc.createElement("div")
                for node in nodes { contentDiv.appendChild(node.cloneNode(true)) }
                removeBackrefs(contentDiv)
                trimLeadingWhitespace(contentDiv)
                addFootnote(state, id, contentDiv)
            }
            pendingRemovals.append(block)
            if let prev = block.previousElementSibling, prev.localName == "hr" { pendingRemovals.append(prev) }
            return
        }
    }

    private func splitOnBreaks(_ block: DOMElement) -> [[DOMNode]] {
        var segments: [[DOMNode]] = []
        var current: [DOMNode] = []
        for node in block.childNodes {
            if let el = node as? DOMElement, el.localName == "br" {
                if !current.isEmpty { segments.append(current) }
                current = []
            } else {
                current.append(node)
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    private func leadingAnchor(_ nodes: [DOMNode]) -> DOMElement? {
        for node in nodes {
            if node.isText {
                if !node.textContent.trimmed.isEmpty { return nil }
                continue
            }
            guard let el = node as? DOMElement else { continue }
            if el.localName != "a" { return nil }
            return el.hasAttribute("name") || !el.id.isEmpty ? el : nil
        }
        return nil
    }

    private func collectSectionParagraphs(_ container: DOMElement, _ state: CollectState) -> Bool {
        var paragraphs: [(Int, DOMElement)] = []
        for p in container.all("p") {
            if let num = parseFootnoteNum(p) { paragraphs.append((num, p)) }
        }
        if paragraphs.isEmpty { return false }
        let numbered = paragraphs.map(\.1)
        for (num, p) in paragraphs {
            let contentDiv = stripMarkerAndWrap(p)
            var sibling = p.nextElementSibling
            while let s = sibling, !numbered.contains(where: { $0 === s }) {
                if !s.textContent.trimmed.isEmpty { contentDiv.appendChild(s.clone()) }
                pendingRemovals.append(s)
                sibling = s.nextElementSibling
            }
            addFootnote(state, String(num), contentDiv)
            pendingRemovals.append(p)
        }
        return true
    }

    private func collectSectionList(_ container: DOMElement, _ state: CollectState) -> Bool {
        guard let list = container.querySelector("ol") else { return false }
        let items = list.children.filter { $0.localName == "li" }
        if items.isEmpty { return false }
        for (index, li) in items.enumerated() {
            addFootnote(state, li.id.isEmpty ? String(index + 1) : li.id.lowercased(), li.clone())
        }
        return true
    }

    private func trimLeadingWhitespace(_ parent: DOMElement) {
        if let first = parent.firstChild as? DOMText { first.data = first.data.trimmedStart }
    }

    private func isBoldWrappedSup(_ el: DOMElement) -> Bool {
        (el.localName == "b" || el.localName == "strong") && el.firstChild === el.firstElementChild
            && el.firstElementChild?.localName == "sup"
    }

    func stripMarkerAndWrap(_ el: DOMElement) -> DOMElement {
        let contentDiv = doc.createElement("div")
        let clone = el.clone()
        if let marker = clone.firstElementChild {
            if isBoldWrappedSup(marker) {
                marker.firstElementChild?.remove()
                trimLeadingWhitespace(marker)
            } else {
                marker.remove()
                trimLeadingWhitespace(clone)
            }
        }
        contentDiv.appendChild(clone)
        return contentDiv
    }

    func parseFootnoteNum(_ el: DOMElement) -> Int? {
        guard el.firstChild != nil, var first = el.firstElementChild, first === el.firstChild else { return nil }
        var tag = first.localName
        if isBoldWrappedSup(first), let sup = first.firstElementChild {
            first = sup
            tag = "sup"
        }
        guard tag == "sup" || tag == "strong" else { return nil }
        let text = first.textContent.trimmed
        guard let num = jsParseInt(text), num >= 1, String(num) == text else { return nil }
        return num
    }

    func crossValidate(_ element: DOMElement, _ paragraphs: [(Int, DOMElement)]) -> Bool {
        let nums = Set(paragraphs.map(\.0))
        var matched = Set<Int>()
        for sup in element.all("sup") {
            if paragraphs.contains(where: { $0.1.contains(sup) }) { continue }
            if sup.querySelector("a") != nil { continue }
            let text = sup.textContent.trimmed
            if let n = jsParseInt(text), n >= 1, String(n) == text, nums.contains(n) { matched.insert(n) }
        }
        return matched.count >= 2
    }

    func findLooseFootnoteParagraphs(_ element: DOMElement) -> ([(Int, DOMElement)], [DOMElement])? {
        let allPs = element.all("p")
        let container = allPs.last?.parentElement ?? element
        let children = container.children

        if let hrIndex = children.lastIndex(where: { $0.localName == "hr" }) {
            var paragraphs: [(Int, DOMElement)] = []
            for child in children[(hrIndex + 1)...] {
                if let num = parseFootnoteNum(child) { paragraphs.append((num, child)) }
            }
            if paragraphs.count >= 2 && crossValidate(element, paragraphs) {
                return (paragraphs, Array(children[hrIndex...]))
            }
        }

        var trailing: [(Int, DOMElement)] = []
        var firstIndex = -1
        var i = children.count - 1
        while i >= 0 {
            let child = children[i]
            let tag = child.localName
            if tag == "p" {
                if let num = parseFootnoteNum(child) {
                    trailing.insert((num, child), at: 0)
                    firstIndex = i
                    i -= 1
                    continue
                }
                break
            }
            if tag == "ul" || tag == "ol" || tag == "blockquote" { i -= 1; continue }
            break
        }
        if trailing.count >= 2 && crossValidate(element, trailing) {
            var toRemove = Array(children[firstIndex...])
            if let prev = trailing[0].1.previousElementSibling, prev.localName.jsTest("^h[1-6]$"),
               Footnotes.sectionPattern.test(prev.textContent.trimmed) {
                toRemove.insert(prev, at: 0)
            }
            return (trailing, toRemove)
        }

        var scattered: [(Int, DOMElement)] = []
        for p in allPs[(allPs.count / 2)...] {
            if let num = parseFootnoteNum(p) { scattered.append((num, p)) }
        }
        if scattered.count >= 2 && crossValidate(element, scattered) {
            return (scattered, scattered.map(\.1))
        }
        return nil
    }

    func isBackrefLink(_ el: DOMElement) -> Bool {
        guard el.localName == "a" else { return false }
        let text = el.textContent.trimmed.jsReplace("\\uFE0E|\\uFE0F", "g", "")
        if Footnotes.backrefSymbols.test(text) || el.hasClass("footnote-backref") { return true }
        return Footnotes.citeRef.test(el.getAttribute("href") ?? "")
    }

    func removeBackrefs(_ el: DOMElement) {
        for a in el.all("a") where isBackrefLink(a) {
            if let parent = a.parentElement, parent.localName == "sup", parent.children.count == 1 {
                parent.remove()
            } else {
                a.remove()
            }
        }
        while let first = el.firstChild as? DOMText {
            if first.data.jsTest("^[\\s\\^,.;]*$") && first.data.contains("^") { first.remove() } else { break }
        }
        while let last = el.lastChild as? DOMText {
            if last.data.jsTest("^\\s*$") { last.remove() } else { break }
        }
    }

    func getChildAnchorId(_ el: DOMElement) -> String {
        guard let anchor = el.querySelector("a[id], a[name]") else { return "" }
        return (anchor.id.isEmpty ? (anchor.getAttribute("name") ?? "") : anchor.id).lowercased()
    }

    private func extractListItemIdAndContent(_ li: DOMElement) -> (String, DOMElement?) {
        if let citations = li.querySelector(".citations"), citations.id.lowercased().hasPrefix("r") {
            return (citations.id.lowercased(), citations.querySelector(".citation-content"))
        }
        let rawId = li.id.lowercased()
        for prefix in ["bib.bib", "fn:", "fn"] where rawId.hasPrefix(prefix) {
            return (String(rawId.dropFirst(prefix.count)), li)
        }
        if li.hasAttribute("data-counter") {
            return ((li.getAttribute("data-counter") ?? "").jsReplace("\\.$", "", "").lowercased(), li)
        }
        let last = rawId.components(separatedBy: "/").last ?? ""
        if let match = last.jsMatch("cite_note-(.+)") { return (match[1] ?? "", li) }
        return (rawId, li)
    }

    func findMatchingFootnoteElements(_ container: DOMElement, _ fragments: Set<String>) -> [(el: DOMElement, id: String)] {
        var results: [(DOMElement, String)] = []
        var seen = Set<String>()
        for el in container.all("li, p, div") {
            var id = ""
            if !el.id.isEmpty && fragments.contains(el.id.lowercased()) {
                id = el.id.lowercased()
            } else if el.id.isEmpty {
                let anchorId = getChildAnchorId(el)
                if !anchorId.isEmpty && fragments.contains(anchorId) { id = anchorId }
            }
            if !id.isEmpty && !seen.contains(id) {
                results.append((el, id))
                seen.insert(id)
            }
        }
        return results
    }

    func replaceContainerPreservingText(_ container: DOMElement, _ ref: DOMElement) {
        var directText = ""
        var hasChildElements = false
        for node in container.childNodes {
            if node.isText { directText += node.textContent } else if node.isElement { hasChildElements = true }
        }
        directText = directText.trimmed
        if !directText.isEmpty && hasChildElements {
            container.replaceWith([DOMText(directText), ref])
        } else {
            container.replaceWith(ref)
        }
    }

    func findOuterContainer(_ el: DOMElement) -> DOMElement {
        var current = el
        var parent = el.parentElement
        while let p = parent {
            let tag = p.localName
            if tag != "span" && tag != "sup" { break }
            if tag == "span" {
                let hasOther = p.childNodes.contains { child in
                    if child === current { return false }
                    if child.isText { return !child.textContent.trimmed.isEmpty }
                    if let e = child as? DOMElement { return e.localName != "sup" }
                    return false
                }
                if hasOther { break }
            }
            current = p
            parent = p.parentElement
        }
        return current
    }

    func createFootnoteReference(_ number: String, _ refId: String) -> DOMElement {
        let sup = doc.createElement("sup")
        sup.setAttribute("id", refId)
        let link = doc.createElement("a")
        link.setAttribute("href", "#fn:\(number)")
        link.textContent = number
        sup.appendChild(link)
        return sup
    }

    func collectInlineSidenotes(_ element: DOMElement) -> FootnoteCollection {
        var footnotes: FootnoteCollection = [:]
        let containers = element.all("span.footnote-container, span.sidenote-container, span.inline-footnote")
        if containers.isEmpty {
            let footrefs = element.all("label.footref")
            if !footrefs.isEmpty {
                var count = 1
                for label in footrefs {
                    var sibling = label.nextElementSibling
                    if let s = sibling, s.tagName == "INPUT", s.hasClass("footref-toggle") { sibling = s.nextElementSibling }
                    guard let sidenote = sibling, sidenote.tagName == "SPAN", sidenote.hasClass("sidenote") else { continue }
                    let content = sidenote.clone()
                    if let leading = content.querySelector("sup"), content.firstChild === leading { leading.remove() }
                    footnotes[count] = FootnoteData(content: content, originalId: String(count), refs: ["fnref:\(count)"])
                    let ref = createFootnoteReference(String(count), "fnref:\(count)")
                    if let input = label.nextElementSibling, input.tagName == "INPUT", input.hasClass("footref-toggle") { input.remove() }
                    sidenote.remove()
                    label.replaceWith(ref)
                    count += 1
                }
                for footer in element.all("footer") where footer.querySelector(".footdef") != nil { footer.remove() }
                return footnotes
            }
            for sidenote in element.all("span.sidenote") { sidenote.remove() }
            return footnotes
        }
        var count = 1
        for container in containers {
            guard let content = container.querySelector("span.footnote, span.sidenote, span.footnoteContent") else { continue }
            footnotes[count] = FootnoteData(content: content.clone(), originalId: String(count), refs: ["fnref:\(count)"])
            container.replaceWith(createFootnoteReference(String(count), "fnref:\(count)"))
            count += 1
        }
        return footnotes
    }

    func collectSidenotesColumn(_ element: DOMElement) -> FootnoteCollection {
        var footnotes: FootnoteCollection = [:]
        var columns = element.all(".sidenotes-column")
        if columns.isEmpty {
            var ancestor = element.parentElement
            var i = 0
            while i < 3, let a = ancestor, columns.isEmpty {
                columns = a.all(":scope > .sidenotes-column")
                ancestor = a.parentElement
                i += 1
            }
        }
        if columns.isEmpty { return footnotes }
        var count = 1
        for column in columns {
            for sidenote in column.all(".sidenote[id]") {
                let id = sidenote.id
                if id.isEmpty { continue }
                let num = sidenote.querySelector(".sidenote__id")?.textContent.jsReplace("\\D", "g", "") ?? ""
                let number = jsParseInt(num) ?? count
                let contentDiv = doc.createElement("div")
                for node in sidenote.childNodes {
                    if let el = node as? DOMElement,
                       el.hasClass("sidenote__id") || el.hasClass("sidenote__label") || el.hasClass("sn-backref") { continue }
                    contentDiv.appendChild(node.cloneNode(true))
                }
                removeBackrefs(contentDiv)
                footnotes[number] = FootnoteData(content: contentDiv, originalId: id.lowercased())
                count += 1
            }
            column.remove()
        }
        return footnotes
    }

    func collectAsideFootnotes(_ element: DOMElement) -> FootnoteCollection {
        var footnotes: FootnoteCollection = [:]
        for ol in element.all("aside > ol[start]") {
            guard let aside = ol.parentElement, let number = jsParseInt(ol.getAttribute("start")), number >= 1 else { continue }
            let items = ol.all("li")
            if items.isEmpty { continue }
            let contentDiv = doc.createElement("div")
            if items.count == 1 {
                Utils.transferContent(items[0].clone(), contentDiv)
            } else {
                for li in items {
                    let p = doc.createElement("p")
                    Utils.transferContent(li.clone(), p)
                    contentDiv.appendChild(p)
                }
            }
            footnotes[number] = FootnoteData(content: contentDiv, originalId: String(number))
            aside.remove()
        }
        return footnotes
    }

    func collectHiddenAsideFootnotes(_ element: DOMElement) -> FootnoteCollection {
        var footnotes: FootnoteCollection = [:]
        let refs = element.all("span[data-definition]")
        if refs.isEmpty { return footnotes }
        var asides: [String: DOMElement] = [:]
        for aside in element.all("aside[id]") { asides[aside.id] = aside }
        var count = 1
        for ref in refs {
            guard let defId = ref.getAttribute("data-definition"), !defId.isEmpty, let aside = asides[defId] else { continue }
            let contentDiv = doc.createElement("div")
            Utils.transferContent(aside, contentDiv)
            aside.remove()
            let refId = "fnref:\(count)"
            footnotes[count] = FootnoteData(content: contentDiv, originalId: defId.lowercased(), refs: [refId])
            ref.replaceWith(createFootnoteReference(String(count), refId))
            count += 1
        }
        return footnotes
    }

    func standardizeFootnotes(_ element: DOMElement) {
        let sidenotes = collectInlineSidenotes(element)
        var footnotes = collectHiddenAsideFootnotes(element)
        merge(&footnotes, collectFootnotes(element))
        merge(&footnotes, collectSidenotesColumn(element))
        merge(&footnotes, collectAsideFootnotes(element))

        var byOriginalId: [String: (String, FootnoteData)] = [:]
        for key in footnotes.keys.sorted() {
            let data = footnotes[key]!
            byOriginalId[data.originalId.lowercased()] = (String(key), data)
        }

        var supGroups: [(container: DOMElement, refs: [(String, String)])] = []
        func groupIndex(_ container: DOMElement) -> Int? { supGroups.firstIndex { $0.container === container } }

        for el in element.all(Constants.footnoteInlineReferences) {
            if el.parentNode == nil || el.textContent.trimmed.isEmpty { continue }
            if el.matches("cite.ltx_cite") {
                var refs: [DOMElement] = []
                for link in el.all("a") {
                    guard let href = link.getAttribute("href"),
                          let num = (href.components(separatedBy: "/").last ?? "").jsMatch("bib\\.bib(\\d+)")?[1],
                          let (fnNum, data) = byOriginalId[num.lowercased()] else { continue }
                    let refId = makeRefId(fnNum, data.refs.count)
                    data.refs.append(refId)
                    refs.append(createFootnoteReference(fnNum, refId))
                }
                if !refs.isEmpty {
                    var nodes: [DOMNode] = []
                    for (index, ref) in refs.enumerated() {
                        if index > 0 { nodes.append(DOMText(" ")) }
                        nodes.append(ref)
                    }
                    findOuterContainer(el).replaceWith(nodes)
                }
                continue
            }

            var footnoteId = ""
            for extractor in Footnotes.inlineRefExtractors where el.matches(extractor.selector) {
                footnoteId = extractor.extract(el)
                break
            }
            if footnoteId.isEmpty, let href = el.getAttribute("href"), !href.isEmpty {
                footnoteId = href.jsReplace("^[#]", "", "").lowercased()
            }
            guard !footnoteId.isEmpty, let (number, data) = byOriginalId[footnoteId.lowercased()] else { continue }
            let container = findOuterContainer(el)
            let isSup = container.localName == "sup"
            if isSup, let index = groupIndex(container), supGroups[index].refs.contains(where: { $0.0 == number }) { continue }
            let refId = makeRefId(number, data.refs.count)
            data.refs.append(refId)
            if isSup {
                if let index = groupIndex(container) {
                    supGroups[index].refs.append((number, refId))
                } else {
                    supGroups.append((container, [(number, refId)]))
                }
            } else {
                replaceContainerPreservingText(container, createFootnoteReference(number, refId))
            }
        }

        let unmatched = footnotes.keys.sorted().filter { footnotes[$0]!.refs.isEmpty }
        if !unmatched.isEmpty {
            var idMap: [String: (String, FootnoteData)] = [:]
            var numMap: [String: (String, FootnoteData)] = [:]
            for key in unmatched {
                let data = footnotes[key]!
                idMap[data.originalId] = (String(key), data)
                numMap[String(key)] = (String(key), data)
            }
            let pending = pendingRemovals
            func isInsideFootnotes(_ el: DOMElement) -> Bool {
                el.closest("[id^=\"fnref:\"]") != nil || el.closest("#footnotes") != nil || pending.contains { $0.contains(el) }
            }
            func assign(_ el: DOMElement, _ entry: (String, FootnoteData)) {
                let refId = makeRefId(entry.0, entry.1.refs.count)
                entry.1.refs.append(refId)
                replaceContainerPreservingText(findOuterContainer(el), createFootnoteReference(entry.0, refId))
            }
            for link in element.all("a[href*=\"#\"]") {
                if link.parentNode == nil || isInsideFootnotes(link) { continue }
                let fragment = Footnotes.hrefFragment(link)
                guard !fragment.isEmpty, let entry = idMap[fragment], Footnotes.marker.test(link.textContent.trimmed) else { continue }
                assign(link, entry)
            }
            if footnotes.values.contains(where: { $0.refs.isEmpty }) {
                for el in element.all("sup, span.footnote-ref") {
                    if el.parentNode == nil || el.id.hasPrefix("fnref:") || el.closest("#footnotes") != nil { continue }
                    guard let num = Footnotes.marker.firstMatch(el.textContent.trimmed)?[1],
                          let entry = numMap[num] ?? idMap[num], entry.1.refs.isEmpty else { continue }
                    assign(el, entry)
                }
            }
        }

        for group in supGroups {
            group.container.replaceWith(group.refs.map { createFootnoteReference($0.0, $0.1) })
        }

        let newList = doc.createElement("div")
        newList.setAttribute("id", "footnotes")
        let ordered = doc.createElement("ol")
        var all = sidenotes
        for (key, data) in footnotes { all[key] = data }
        for key in all.keys.sorted() {
            let data = all[key]!
            ordered.appendChild(createFootnoteItem(key, data.content, data.refs))
        }

        for list in element.all(Constants.footnoteListSelectors) { list.remove() }
        for el in pendingRemovals where el.parentNode != nil { el.remove() }
        Standardize.removeOrphanedDividers(element)
        if !ordered.children.isEmpty {
            newList.appendChild(ordered)
            element.appendChild(newList)
        }
    }
}
