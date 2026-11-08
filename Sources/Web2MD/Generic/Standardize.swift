// Port of defuddle src/standardize.ts.
// Copyright (c) 2025 Steph Ango (@kepano), MIT License.

import Foundation

struct StandardizationRule: Sendable {
    let selector: String
    var fastCheck: String? = nil
    let transform: @Sendable (DOMElement, DOMDocument) -> DOMElement
}

enum Standardize {
    static let elementRules: [StandardizationRule] = MathElements.rules + CodeElements.rules + HeadingElements.rules
        + ImageElements.rules + roleRules

    private static func paragraphifyRoleDivs(in content: DOMElement, _ doc: DOMDocument) {
        for div in content.all("div[role=\"paragraph\"]") {
            let p = doc.createElement("p")
            Utils.transferContent(div, p)
            div.replaceWith(p)
        }
    }

    private static func isOrderedRoleList(_ list: DOMElement) -> Bool {
        let label = list.querySelector("div[role=\"listitem\"] .label")?.textContent.trimmed ?? ""
        return label.jsTest("^\\d+\\)")
    }

    private static let roleRules: [StandardizationRule] = [
        StandardizationRule(selector: "div[data-testid^=\"paragraph\"], div[role=\"paragraph\"]") { el, doc in
            let p = doc.createElement("p")
            Utils.transferContent(el, p)
            for attribute in el.attributes where Constants.allowedAttributes.contains(attribute.name) {
                p.setAttribute(attribute.name, attribute.value)
            }
            return p
        },
        StandardizationRule(selector: "div[role=\"list\"]") { el, doc in
            let list = doc.createElement(isOrderedRoleList(el) ? "ol" : "ul")
            for item in el.all("div[role=\"listitem\"]") {
                let li = doc.createElement("li")
                if let content = item.querySelector(".content") {
                    paragraphifyRoleDivs(in: content, doc)
                    for nested in content.all("div[role=\"list\"]") {
                        let newNested = doc.createElement(isOrderedRoleList(nested) ? "ol" : "ul")
                        for nestedItem in nested.all("div[role=\"listitem\"]") {
                            let nestedLi = doc.createElement("li")
                            if let nestedContent = nestedItem.querySelector(".content") {
                                paragraphifyRoleDivs(in: nestedContent, doc)
                                Utils.transferContent(nestedContent, nestedLi)
                            }
                            newNested.appendChild(nestedLi)
                        }
                        nested.replaceWith(newNested)
                    }
                    Utils.transferContent(content, li)
                }
                list.appendChild(li)
            }
            return list
        },
        StandardizationRule(selector: "div[role=\"listitem\"]") { el, doc in
            guard let content = el.querySelector(".content") else { return el }
            paragraphifyRoleDivs(in: content, doc)
            return content
        },
    ]

    static func standardizeContent(_ element: DOMElement, title: String, doc: DOMDocument, hasMathLibrary: Bool) {
        standardizeDropCaps(element)
        standardizeSpaces(element)
        removeHTMLComments(element)
        standardizeHeadings(element, title: title, doc)
        wrapPreformattedCode(element, doc)
        standardizeElements(element, doc, hasMathLibrary: hasMathLibrary)

        replaceCustomElements(element, doc)
        convertDataAsSpans(element, doc)
        convertBlockSpans(element, doc)
        unwrapLayoutTables(element)
        flattenWrapperElements(element, doc)
        HeadingElements.removePermalinkAnchors(element)
        stripUnwantedAttributes(element)
        unwrapBareSpans(element)

        // Links inside inline code can't render in Markdown.
        for link in element.all("code a") { unwrap(link) }
        for link in element.all("a[href^=\"javascript:\"]") { unwrap(link) }
        // <a href><h2>Title</h2><p>…</p></a> → <h2><a href>Title</a></h2><p>…</p>
        for link in element.all("a") {
            guard let href = link.getAttribute("href"), !href.hasPrefix("#") else { continue }
            guard let heading = link.children.first(where: { $0.tagName.jsTest("^H[1-6]$") }) else { continue }
            let inner = doc.createElement("a")
            inner.setAttribute("href", href)
            while let child = heading.firstChild { inner.appendChild(child) }
            heading.appendChild(inner)
            unwrap(link)
        }
        for link in element.all("a[href^=\"#\"]") where link.querySelector("h1, h2, h3, h4, h5, h6") != nil {
            unwrap(link)
        }

        for el in element.all("object, embed, applet") { el.remove() }
        removeEmptyElements(element)
        removeTrailingHeadings(element)
        removeOrphanedDividers(element)
        flattenWrapperElements(element, doc)
        removeOrphanedDividers(element)
        stripExtraBrElements(element)
        removeEmptyLines(element, doc)
    }

    static func unwrap(_ el: DOMElement) {
        while let child = el.firstChild { el.parentNode?.insertBefore(child, el) }
        el.remove()
    }

    private static func wrapPreformattedCode(_ element: DOMElement, _ doc: DOMDocument) {
        for code in element.all("code") {
            if code.closest("pre") != nil { continue }
            guard (code.getAttribute("style") ?? "").jsTest("white-space\\s*:\\s*pre") else { continue }
            let pre = doc.createElement("pre")
            code.parentNode?.insertBefore(pre, code)
            pre.appendChild(code)
        }
    }

    private static func standardizeSpaces(_ node: DOMNode) {
        if let el = node as? DOMElement {
            if el.localName == "pre" || el.localName == "code" || el.isSVG { return }
        }
        if let text = node as? DOMText, text.data.contains("\u{00A0}") {
            text.data = text.data.replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        for child in node.childNodes { standardizeSpaces(child) }
    }

    private static func removeTrailingHeadings(_ element: DOMElement) {
        func hasContentAfter(_ el: DOMElement) -> Bool {
            var next = ""
            var sibling = el.nextSibling
            while let s = sibling {
                if s.isText || s.isElement { next += s.textContent }
                sibling = s.nextSibling
            }
            if !next.trimmed.isEmpty { return true }
            if let parent = el.parentElement, parent !== element { return hasContentAfter(parent) }
            return false
        }
        for heading in element.all("h1, h2, h3, h4, h5, h6").reversed() {
            if hasContentAfter(heading) { break }
            heading.remove()
        }
    }

    static func removeOrphanedDividers(_ element: DOMElement) {
        func isBlankText(_ node: DOMNode) -> Bool { node.isText && node.textContent.trimmed.isEmpty }
        while true {
            var node = element.firstChild
            while let n = node, isBlankText(n) { node = n.nextSibling }
            if let hr = node as? DOMElement, hr.localName == "hr" { hr.remove() } else { break }
        }
        while true {
            var node = element.lastChild
            while let n = node, isBlankText(n) { node = n.previousSibling }
            if let hr = node as? DOMElement, hr.localName == "hr" { hr.remove() } else { break }
        }
        for hr in element.all("hr") {
            if hr.parentNode == nil { continue }
            var node = hr.nextSibling
            while let n = node {
                if isBlankText(n) { node = n.nextSibling; continue }
                if let el = n as? DOMElement, el.tagName == "HR" {
                    let next = el.nextSibling
                    el.remove()
                    node = next
                    continue
                }
                break
            }
        }
    }

    private static func standardizeHeadings(_ element: DOMElement, title: String, _ doc: DOMDocument) {
        for h1 in element.getElementsByTagName("h1") {
            let h2 = doc.createElement("h2")
            Utils.transferContent(h1, h2)
            for attribute in h1.attributes where Constants.allowedAttributes.contains(attribute.name) {
                h2.setAttribute(attribute.name, attribute.value)
            }
            h1.parentNode?.replaceChild(h2, h1)
        }
        guard let firstH2 = element.getElementsByTagName("h2").first else { return }
        var permalinkText = ""
        for a in firstH2.all("a") where HeadingElements.isPermalinkAnchor(a) { permalinkText += a.textContent }
        var text = firstH2.textContent
        if !permalinkText.isEmpty, let range = text.range(of: permalinkText) { text.replaceSubrange(range, with: "") }
        let normalizedTitle = Utils.normalizeText(title)
        if !normalizedTitle.isEmpty && normalizedTitle == Utils.normalizeText(text) { firstH2.remove() }
    }

    private static func removeHTMLComments(_ element: DOMElement) {
        for node in element.descendantNodes() where node.nodeType == .comment { node.remove() }
    }

    static func stripUnwantedAttributes(_ element: DOMElement) {
        for el in [element] + element.all("*") {
            if el.isSVG {
                el.removeAttribute("class")
                continue
            }
            let tag = el.localName
            for attribute in el.attributes {
                let name = attribute.name.lowercased()
                let value = attribute.value
                if name == "id" && (value.hasPrefix("fnref:") || value.hasPrefix("fn:") || value == "footnotes") { continue }
                if name == "class" && ((tag == "code" && value.hasPrefix("language-")) || value == "footnote-backref"
                    || value.jsTest("^callout(?:-|$)")) { continue }
                if !Constants.allowedAttributes.contains(name) { el.removeAttribute(attribute.name) }
            }
        }
    }

    private static func unwrapLayoutTables(_ element: DOMElement) {
        for table in element.all("table") {
            if table.parentNode == nil { continue }
            if table.querySelector("thead, tfoot, th, caption") != nil { continue }
            let cells = table.all(":scope > tbody > tr > td, :scope > tr > td")
            let nonEmpty = cells.filter { !$0.textContent.trimmed.isEmpty }
            guard nonEmpty.count == 1 else { continue }
            let children = nonEmpty[0].children.filter { !$0.textContent.trimmed.isEmpty }
            if children.count == 1 && Constants.blockLevelElements.contains(children[0].localName) {
                table.replaceWith(children[0])
            }
        }
    }

    private static func replaceCustomElements(_ element: DOMElement, _ doc: DOMDocument) {
        let custom = element.all("*").filter {
            $0.tagName.contains("-") && !Constants.inlineElements.contains($0.localName) && !$0.isSVG
        }
        for el in custom.reversed() {
            if el.parentNode == nil { continue }
            let div = doc.createElement("div")
            while let child = el.firstChild { div.appendChild(child) }
            el.replaceWith(div)
        }
    }

    private static func standardizeDropCaps(_ element: DOMElement) {
        let caps = element.all("span[data-caps=\"initial\"]")
        var count = 0
        for span in caps {
            guard let parent = span.parentNode else { continue }
            if let next = span.nextElementSibling, next.tagName == "SMALL" {
                parent.insertBefore(DOMText(span.textContent + next.textContent), span)
                next.remove()
                span.remove()
            } else {
                unwrap(span)
            }
            count += 1
        }
        if count > 0 { element.normalize() }
    }

    private static let dataAsAllowed: Set<String> = ["p", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote"]

    private static func convertDataAsSpans(_ element: DOMElement, _ doc: DOMDocument) {
        for span in element.all("span[data-as]") {
            if span.parentNode == nil { continue }
            let target = (span.getAttribute("data-as") ?? "").lowercased()
            guard dataAsAllowed.contains(target) else { continue }
            let replacement = doc.createElement(target)
            Utils.transferContent(span, replacement)
            span.replaceWith(replacement)
        }
    }

    private static func convertBlockSpans(_ element: DOMElement, _ doc: DOMDocument) {
        for span in element.all("span[class*=\"block\"], span[style*=\"block\"]") {
            if span.parentNode == nil { continue }
            let isBlock = span.className.jsTest("(?:^|\\s)block(?:\\s|$)")
                || (span.getAttribute("style") ?? "").jsTest("display\\s*:\\s*block", "i")
            guard isBlock, !span.textContent.trimmed.isEmpty else { continue }
            let p = doc.createElement("p")
            Utils.transferContent(span, p)
            span.replaceWith(p)
        }
    }

    private static func unwrapBareSpans(_ element: DOMElement) {
        var count = 0
        for span in element.all("span").reversed() {
            guard let parent = span.parentNode, span.attributes.isEmpty else { continue }
            while let child = span.firstChild { parent.insertBefore(child, span) }
            span.remove()
            count += 1
        }
        if count > 0 { element.normalize() }
    }

    static func removeEmptyElements(_ element: DOMElement) {
        func isEmpty(_ el: DOMElement) -> Bool {
            if Constants.allowedEmptyElements.contains(el.localName) { return false }
            if el.tagName == "DIV" {
                let children = el.children
                if !children.isEmpty && children.allSatisfy({ child in
                    let content = child.textContent.trimmed
                    return child.tagName == "SPAN" && (content == "," || content.isEmpty)
                }) { return true }
            }
            let text = el.textContent
            if !text.trimmed.isEmpty || text.contains("\u{00A0}") { return false }
            if !el.hasChildNodes { return true }
            for node in el.childNodes {
                if let child = node as? DOMElement, child.localName == "br" { continue }
                guard node.isText else { return false }
                let t = node.textContent
                if !t.trimmed.isEmpty || t.contains("\u{00A0}") { return false }
            }
            return true
        }
        for el in element.all("*").reversed() where el.parentNode != nil && isEmpty(el) { el.remove() }
    }

    static func stripExtraBrElements(_ element: DOMElement) {
        var consecutive: [DOMElement] = []
        func flush() {
            if consecutive.count > 2 { for br in consecutive[2...] { br.remove() } }
            consecutive = []
        }
        for br in element.getElementsByTagName("br") {
            if let last = consecutive.last, skipWhitespace(br, previous: true) === last {
                consecutive.append(br)
            } else {
                flush()
                consecutive = [br]
            }
        }
        flush()

        for br in element.getElementsByTagName("br") {
            guard let parent = br.parentElement else { continue }
            if br.closest("pre, code") != nil { continue }
            let parentTag = parent.localName
            if Constants.blockLevelElements.contains(parentTag) || parentTag == "body" {
                var group = [br]
                var scan = skipWhitespace(br, previous: false)
                while let el = scan as? DOMElement, el.localName == "br" {
                    group.append(el)
                    scan = skipWhitespace(el, previous: false)
                }
                let prev = skipWhitespace(group[0], previous: true)
                let next = skipWhitespace(group[group.count - 1], previous: false)
                let prevIsBlock = (prev as? DOMElement).map { Constants.blockLevelElements.contains($0.localName) } ?? false
                let nextIsBlock = (next as? DOMElement).map { Constants.blockLevelElements.contains($0.localName) } ?? false
                if (prevIsBlock && nextIsBlock) || (prevIsBlock && next == nil) || prev == nil {
                    for b in group { b.remove() }
                    continue
                }
            }
            if Constants.blockLevelElements.contains(parentTag) && skipWhitespace(br, previous: false) == nil {
                br.remove()
            }
        }
    }

    private static func skipWhitespace(_ node: DOMNode, previous: Bool) -> DOMNode? {
        var sibling = previous ? node.previousSibling : node.nextSibling
        while let s = sibling, s.isText, s.textContent.trimmed.isEmpty {
            sibling = previous ? s.previousSibling : s.nextSibling
        }
        return sibling
    }

    private static func moveWhitespaceOutside(_ node: DOMElement, leading: Bool) {
        guard let child = (leading ? node.firstChild : node.lastChild) as? DOMText, let parent = node.parentNode else { return }
        let text = child.data
        let trimmed = leading ? text.trimmedStart : text.trimmedEnd
        if trimmed == text { return }
        child.data = trimmed
        let neighbor = leading ? node.previousSibling : node.nextSibling
        let neighborHasSpace = (neighbor as? DOMText).map { leading ? $0.data.hasSuffix(" ") : $0.data.hasPrefix(" ") } ?? false
        if !neighborHasSpace {
            parent.insertBefore(DOMText(" "), leading ? node : node.nextSibling)
        }
    }

    private static func isFootnoteRef(_ node: DOMNode) -> Bool {
        guard let el = node as? DOMElement else { return false }
        return el.localName == "sup" && (el.getAttribute("id") ?? "").hasPrefix("fnref:")
    }

    private static func isTightInline(_ node: DOMNode) -> Bool {
        guard let el = node as? DOMElement else { return false }
        return ["sub", "sup", "code"].contains(el.localName) && !isFootnoteRef(node)
    }

    private static let zeroWidthOnly = JSRegex("^[\\u200C\\u200B\\u200D\\u200E\\u200F\\uFEFF]*$")
    private static let inlineWhitespace = JSRegex("^[\\n\\r\\t\\u200C\\u200B\\u200D\\u200E\\u200F\\uFEFF]*$")
    private static let startsWithPunctuation = JSRegex("^[,.!?:;)\\]\u{201D}\u{2019}\u{2014}\u{2013}]")
    private static let endsWithPunctuation = JSRegex("[,.!?:;(\\[\u{201C}\u{2018}\u{2014}\u{2013}]\\s*$")

    private static func removeEmptyLines(_ element: DOMElement, _ doc: DOMDocument) {
        func removeEmptyTextNodes(_ node: DOMNode) {
            if let el = node as? DOMElement, el.localName == "pre" || el.localName == "code" { return }
            for child in node.childNodes { removeEmptyTextNodes(child) }
            guard let text = node as? DOMText else { return }
            let value = text.data
            if value.isEmpty || zeroWidthOnly.test(value) {
                text.remove()
                return
            }
            let updated = value
                .jsReplace("[\\n\\r]+", "g", " ")
                .jsReplace("\\t+", "g", " ")
                .jsReplace(" {2,}", "g", " ")
                .jsReplace("^[ ]+$", "", " ")
                .jsReplace("\\s+([,.!?:;])", "g", "$1")
                .jsReplace("[\\u200B\\u200D\\u200E\\u200F\\uFEFF]+", "g", "")
                .jsReplace("(?:\\xA0){2,}", "g", "\u{00A0}")
            if updated != value { text.data = updated }
        }

        // getComputedStyle is unavailable outside browsers, so every element is treated as inline here.
        func cleanup(_ node: DOMElement) {
            let tag = node.localName
            if tag == "pre" || tag == "code" { return }
            for child in node.children { cleanup(child) }
            node.normalize()
            while let first = node.firstChild, first.isText, inlineWhitespace.test(first.textContent) { first.remove() }
            while let last = node.lastChild, last.isText, inlineWhitespace.test(last.textContent) { last.remove() }
            if Constants.inlineElements.contains(tag) && node.parentNode != nil {
                moveWhitespaceOutside(node, leading: true)
                moveWhitespaceOutside(node, leading: false)
            }
            let children = node.childNodes
            guard children.count > 1 else { return }
            for i in 0..<(children.count - 1) {
                let current = children[i]
                let next = children[i + 1]
                guard current.isElement || next.isElement else { continue }
                if isTightInline(current) || isTightInline(next) { continue }
                let hasSpace = ((current as? DOMText)?.data.hasSuffix(" ") ?? false)
                    || ((next as? DOMText)?.data.hasPrefix(" ") ?? false)
                if !isFootnoteRef(next) && !startsWithPunctuation.test(next.textContent)
                    && !endsWithPunctuation.test(current.textContent) && !hasSpace {
                    node.insertBefore(DOMText(" "), next)
                }
            }
        }

        removeEmptyTextNodes(element)
        cleanup(element)
    }

    private static func standardizeElements(_ element: DOMElement, _ doc: DOMDocument, hasMathLibrary: Bool) {
        MathElements.wrapRawLatexDelimiters(element, doc, hasLibrary: hasMathLibrary)

        for img in element.all("img[src]") {
            guard let src = img.getAttribute("src") else { continue }
            var latex = MathElements.extractLatexFromImageSrc(src)
            if latex == nil {
                let alt = img.getAttribute("alt") ?? ""
                if SmallImages.looksLikeLatex.test(alt) { latex = alt }
            }
            guard let latex else { continue }
            let isBlock = latex.jsTest("\\\\begin\\{")
                || (img.parentElement?.localName == "p" && img.parentElement?.childNodes.count == 1)
            img.replaceWith(MathElements.createCleanMathEl(latex: latex, isBlock: isBlock, doc))
        }

        for rule in elementRules {
            if let fastCheck = rule.fastCheck, element.querySelector(fastCheck) == nil { continue }
            for el in element.all(rule.selector) {
                let transformed = rule.transform(el, doc)
                if transformed !== el { el.replaceWith(transformed) }
            }
        }

        for pre in element.all("code > pre") {
            guard let outer = pre.parentElement, outer.tagName == "CODE" else { continue }
            outer.replaceWith(pre)
        }

        func hasPresentationalContent(_ node: DOMNode) -> Bool {
            if node.isText { return !node.textContent.trimmed.isEmpty }
            guard let el = node as? DOMElement else { return false }
            if el.localName == "annotation" || el.localName == "annotation-xml" { return false }
            if el.localName == "semantics" { return el.childNodes.contains(where: hasPresentationalContent) }
            return true
        }
        for table in element.all("table.ltx_equation, table.ltx_eqn_table, table.ltx_equationgroup") {
            let maths = table.all("math")
            if maths.isEmpty { continue }
            let fragment = DOMFragment()
            for math in maths {
                let latex = math.getAttribute("alttext")
                    ?? math.querySelector("annotation[encoding=\"application/x-tex\"]")?.textContent.trimmed ?? ""
                if latex.isEmpty { continue }
                let isBlock = math.getAttribute("display") == "block" || table.hasClass("ltx_equation") || table.hasClass("ltx_equationgroup")
                let clean = math.clone()
                clean.setAttribute("xmlns", "http://www.w3.org/1998/Math/MathML")
                clean.setAttribute("display", isBlock ? "block" : "inline")
                clean.setAttribute("data-latex", latex)
                if !clean.childNodes.contains(where: hasPresentationalContent) { clean.textContent = latex }
                fragment.appendChild(clean)
            }
            if fragment.hasChildNodes { table.replaceWith(fragment) }
        }

        for outer in element.all("span.ltx_note_outer") { outer.remove() }
        for link in element.all("a.ltx_ref") where link.querySelector("span.ltx_ref_tag, span.ltx_text.ltx_ref_tag") != nil {
            link.replaceWith(DOMText(link.textContent))
        }

        for table in element.all("table") {
            if table.parentNode == nil { continue }
            let cells = table.all("td, th")
            if !cells.isEmpty && cells.allSatisfy({ $0.textContent.trimmed.isEmpty })
                && table.querySelector("img, picture, video, audio, iframe, svg, math") == nil {
                table.remove()
            }
        }

        for table in element.all("table") {
            if table.parentNode == nil { continue }
            let cells = table.all("td, th").filter { Utils.isDirectTableChild($0, table) }
            if cells.contains(where: { $0.tagName == "TH" }) { continue }
            let rows = table.all("tr").filter { Utils.isDirectTableChild($0, table) }
            if rows.isEmpty { continue }
            let singleColumn = rows.allSatisfy { row in cells.filter { $0.parentNode === row }.count <= 1 }
            guard singleColumn else { continue }
            let fragment = DOMFragment()
            for cell in cells { while let child = cell.firstChild { fragment.appendChild(child) } }
            table.replaceWith(fragment)
        }

        for video in element.all("video:not([controls])") { video.setAttribute("controls", "") }

        for lite in element.all("lite-youtube") {
            guard let videoId = lite.getAttribute("videoid") else { continue }
            let iframe = doc.createElement("iframe")
            iframe.setAttribute("width", "560")
            iframe.setAttribute("height", "315")
            iframe.setAttribute("src", "https://www.youtube.com/embed/\(videoId)")
            iframe.setAttribute("title", lite.getAttribute("videotitle") ?? "YouTube video player")
            iframe.setAttribute("frameborder", "0")
            iframe.setAttribute("allowfullscreen", "")
            lite.replaceWith(iframe)
        }

        mergeAdjacentVersoCodeBlocks(element)
    }

    private static func mergeAdjacentVersoCodeBlocks(_ root: DOMElement) {
        func codeNode(_ pre: DOMElement) -> DOMElement? {
            var code: DOMElement?
            for child in pre.children {
                if child.localName != "code" || code != nil { return nil }
                code = child
            }
            return code
        }
        func language(_ code: DOMElement) -> String {
            let dataLang = (code.getAttribute("data-lang") ?? "").lowercased()
            if !dataLang.isEmpty { return dataLang }
            return code.className.jsMatch("(?:^|\\s)language-([a-z0-9_+-]+)(?:\\s|$)", "i")?[1]?.lowercased() ?? ""
        }
        var parents: [DOMElement] = []
        for candidate in root.all("pre[data-verso-code=\"true\"]") {
            if let parent = candidate.parentElement, !parents.contains(where: { $0 === parent }) { parents.append(parent) }
        }
        for container in parents {
            let children = container.childNodes
            var i = 0
            while i < children.count {
                defer { i += 1 }
                guard let start = children[i] as? DOMElement, start.localName == "pre",
                      start.getAttribute("data-verso-code") == "true", let startCode = codeNode(start) else { continue }
                let lang = language(startCode)
                guard lang == "lean" || lang == "lean4" else { continue }
                var run: [(DOMElement, DOMElement)] = [(start, startCode)]
                var between: [DOMNode] = []
                var j = i + 1
                while j < children.count {
                    let node = children[j]
                    if node.isText && node.textContent.trimmed.isEmpty { between.append(node); j += 1; continue }
                    guard let pre = node as? DOMElement, pre.localName == "pre", pre.getAttribute("data-verso-code") == "true",
                          let code = codeNode(pre), language(code) == lang else { break }
                    run.append((pre, code))
                    j += 1
                }
                if run.count <= 1 { continue }
                startCode.textContent = run.map { $0.1.textContent.jsReplace("\\r?\\n$", "", "") }
                    .joined(separator: "\n")
                    .jsReplace("\\n{3,}", "g", "\n\n")
                    .jsReplace("^\\n+|\\n+$", "g", "")
                for (pre, _) in run.dropFirst() { pre.remove() }
                for node in between { node.remove() }
                i = j - 1
            }
        }
    }

    private static let preserveClassPattern = JSRegex("(?:article|main|content|footnote|reference|bibliography)")

    private static func flattenWrapperElements(_ element: DOMElement, _ doc: DOMDocument) {
        func hasDirectInlineContent(_ el: DOMElement) -> Bool {
            el.childNodes.contains { child in
                if child.isText { return !child.textContent.trimmed.isEmpty }
                if let e = child as? DOMElement { return Constants.inlineElements.contains(e.localName) }
                return false
            }
        }
        func shouldPreserve(_ el: DOMElement) -> Bool {
            if el.isSVG { return true }
            if Constants.preserveElements.contains(el.localName) { return true }
            if !(el.getAttribute("data-callout") ?? "").isEmpty || el.closest("[data-callout]") != nil { return true }
            if let role = el.getAttribute("role"), ["article", "main", "navigation", "banner", "contentinfo"].contains(role) { return true }
            if preserveClassPattern.test(el.className.lowercased()) { return true }
            return el.children.contains { child in
                Constants.preserveElements.contains(child.localName) || child.getAttribute("role") == "article"
                    || preserveClassPattern.test(child.className.lowercased())
            }
        }
        func dissolve(_ el: DOMElement) {
            let fragment = DOMFragment()
            while let child = el.firstChild { fragment.appendChild(child) }
            el.replaceWith(fragment)
        }
        func process(_ el: DOMElement) -> Bool {
            if el.parentNode == nil || shouldPreserve(el) { return false }
            let tag = el.localName
            if !Constants.allowedEmptyElements.contains(tag) && el.children.isEmpty && el.textContent.trimmed.isEmpty {
                el.remove()
                return true
            }
            if el.parentElement === element {
                let children = el.children
                if !children.isEmpty && !children.contains(where: { Constants.inlineElements.contains($0.localName) }) {
                    dissolve(el)
                    return true
                }
            }
            if !hasDirectInlineContent(el) {
                dissolve(el)
                return true
            }
            let nodes = el.childNodes
            let onlyInline = !nodes.isEmpty && nodes.allSatisfy { child in
                child.isText || ((child as? DOMElement).map { Constants.inlineElements.contains($0.localName) } ?? false)
            }
            if onlyInline && !el.textContent.trimmed.isEmpty {
                let p = doc.createElement("p")
                while let child = el.firstChild { p.appendChild(child) }
                el.replaceWith(p)
                return true
            }
            if el.children.count == 1, let child = el.firstElementChild,
               Constants.blockElementsSet.contains(child.localName), !shouldPreserve(child) {
                el.replaceWith(child)
                return true
            }
            return false
        }
        func depth(_ el: DOMElement) -> Int {
            var count = 0
            var parent = el.parentElement
            while let p = parent {
                if Constants.blockElementsSet.contains(p.localName) { count += 1 }
                parent = p.parentElement
            }
            return count
        }

        var keepProcessing = true
        var guardCount = 0
        while keepProcessing && guardCount < 100 {
            guardCount += 1
            keepProcessing = false
            for el in element.children where Constants.blockElementsSet.contains(el.localName) {
                if process(el) { keepProcessing = true }
            }
            let remaining = element.all(Constants.blockElementsSelector)
                .map { ($0, depth($0)) }
                .enumerated()
                .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
                .map { $0.element.0 }
            for el in remaining where process(el) { keepProcessing = true }
            for el in element.all(Constants.blockElementsSelector) {
                let children = el.children
                let onlyParagraphs = !children.isEmpty && children.allSatisfy { $0.localName == "p" }
                if onlyParagraphs || (!shouldPreserve(el) && !hasDirectInlineContent(el)) {
                    dissolve(el)
                    keepProcessing = true
                }
            }
        }
    }
}
