// Port of defuddle src/elements/math.base.ts and math.full.ts.
// Copyright (c) 2025 Steph Ango (@kepano), MIT License.
//
// LaTeX → MathML (temml) is not ported: LaTeX-only math keeps its source as text,
// which is all the Markdown output needs.

import Foundation

enum MathElements {
    struct MathData {
        var math: DOMElement
        var latex: String?
        var isBlock: Bool
    }

    // MARK: MathJax CHTML reconstruction

    private static let tokenTags: Set<String> = ["mi", "mo", "mn", "mtext", "ms", "mspace", "mglyph"]
    private static let structuralTags: Set<String> = [
        "mrow", "mstyle", "mpadded", "mphantom", "menclose", "merror", "mtable", "mtr", "mtd", "mlabeledtr",
    ]
    private static let dropTags: Set<String> = [
        "mjx-nstrut", "mjx-dstrut", "mjx-strut", "mjx-line", "mjx-spacer", "mjx-break", "mjx-mark",
    ]

    private static func normalizeGlyphs(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.jsReplace("[\\u2061\\u2062\\u2063\\u2064]", "g", "")
    }

    private static func mathElement(_ name: String, _ children: [DOMNode] = []) -> DOMElement {
        let el = DOMElement(name, namespace: .mathml)
        for child in children { el.appendChild(child) }
        return el
    }

    private static func directChild(_ node: DOMElement, _ tag: String) -> DOMElement? {
        node.children.first { $0.localName == tag }
    }

    private static func flattenMjx(_ node: DOMElement?, skip: DOMElement? = nil) -> [DOMNode] {
        guard let node else { return [] }
        return node.children.filter { $0 !== skip }.flatMap(convertMjx)
    }

    private static func wrap(_ parts: [DOMNode]) -> DOMNode {
        parts.count == 1 ? parts[0] : mathElement("mrow", parts)
    }

    private static func convertMjx(_ node: DOMElement) -> [DOMNode] {
        let tag = node.localName
        if tag == "mjx-c" {
            let text = normalizeGlyphs(node.textContent)
            return text.isEmpty ? [] : [DOMText(text)]
        }
        if dropTags.contains(tag) || !tag.hasPrefix("mjx-") { return [] }
        let name = String(tag.dropFirst(4))
        if tokenTags.contains(name) {
            let text = normalizeGlyphs(node.textContent)
            if text.isEmpty && name != "mspace" { return [] }
            let el = mathElement(name)
            if !text.isEmpty { el.textContent = text }
            return [el]
        }
        if structuralTags.contains(name) { return [mathElement(name, flattenMjx(node))] }
        switch name {
        case "mfrac":
            return [mathElement("mfrac", [wrap(flattenMjx(node.querySelector("mjx-num"))), wrap(flattenMjx(node.querySelector("mjx-den")))])]
        case "msqrt":
            return [mathElement("msqrt", flattenMjx(node.querySelector("mjx-box") ?? node))]
        case "msub", "msup":
            let script = directChild(node, "mjx-script")
            return [mathElement(name, [wrap(flattenMjx(node, skip: script)), wrap(flattenMjx(script))])]
        case "msubsup":
            let script = directChild(node, "mjx-script")
            let base = wrap(flattenMjx(node, skip: script))
            let parts = flattenMjx(script)
            let sub = parts.count > 1 ? parts[parts.count - 1] : (parts.first ?? mathElement("mrow"))
            let sup = parts.count > 1 ? parts[0] : mathElement("mrow")
            return [mathElement("msubsup", [base, sub, sup])]
        case "munder", "mover", "munderover":
            let base = wrap(flattenMjx(node.querySelector("mjx-base")))
            let under = wrap(flattenMjx(node.querySelector("mjx-under")))
            let over = wrap(flattenMjx(node.querySelector("mjx-over")))
            if name == "munder" { return [mathElement("munder", [base, under])] }
            if name == "mover" { return [mathElement("mover", [base, over])] }
            return [mathElement("munderover", [base, under, over])]
        default:
            return flattenMjx(node)
        }
    }

    private static func reconstructFromMjx(_ mjxMath: DOMElement) -> MathData? {
        let math = mathElement("math")
        for child in mjxMath.children { for node in convertMjx(child) { math.appendChild(node) } }
        if !math.hasChildNodes { return nil }
        let isBlock = mjxMath.getAttribute("display") == "true"
        return MathData(math: math, latex: nil, isBlock: isBlock)
    }

    private static func flattenTaggedEquationTables(_ math: DOMElement) {
        for table in math.all("mtable") {
            let rows = table.children.filter { $0.localName == "mtr" || $0.localName == "mlabeledtr" }
            guard rows.count == 1, rows[0].localName == "mlabeledtr" else { continue }
            let cells = rows[0].children.filter { $0.localName == "mtd" }
            guard cells.count >= 2 else { continue }
            let replacement = mathElement("mrow")
            for cell in cells.dropFirst() { while let child = cell.firstChild { replacement.appendChild(child) } }
            if cells[0].hasChildNodes {
                let spacer = mathElement("mspace")
                spacer.setAttribute("width", "2em")
                replacement.appendChild(spacer)
                while let child = cells[0].firstChild { replacement.appendChild(child) }
            }
            table.replaceWith(replacement)
        }
    }

    private static func normalized(_ math: DOMElement) -> DOMElement {
        let clone = math.clone()
        flattenTaggedEquationTables(clone)
        return clone
    }

    static func mathML(from el: DOMElement) -> MathData? {
        if el.localName == "math" {
            return MathData(math: normalized(el), latex: el.getAttribute("alttext").flatMap { $0.isEmpty ? nil : $0 },
                            isBlock: el.getAttribute("display") == "block")
        }
        if let mathml = el.getAttribute("data-mathml"), !mathml.isEmpty, let math = Utils.parseHTML(mathml).querySelector("math") {
            return MathData(math: normalized(math), latex: math.getAttribute("alttext").flatMap { $0.isEmpty ? nil : $0 },
                            isBlock: math.getAttribute("display") == "block")
        }
        if let container = el.querySelector(".MJX_Assistive_MathML, mjx-assistive-mml"), let math = container.querySelector("math") {
            let isBlock = math.getAttribute("display") == "block" || container.getAttribute("display") == "block"
            return MathData(math: normalized(math), latex: math.getAttribute("alttext").flatMap { $0.isEmpty ? nil : $0 }, isBlock: isBlock)
        }
        if let katex = el.querySelector(".katex-mathml math") {
            return MathData(math: normalized(katex), latex: nil, isBlock: false)
        }
        if let mjxMath = el.localName == "mjx-math" ? el : el.querySelector("mjx-math"), let data = reconstructFromMjx(mjxMath) {
            return data
        }
        return nil
    }

    static func basicLatex(from el: DOMElement) -> String? {
        if let value = el.getAttribute("data-latex"), !value.isEmpty { return value }
        if let value = el.getAttribute("data-math"), !value.isEmpty { return value }
        if let parent = el.parentElement, parent.hasClass("hurmet-tex"), let entry = parent.getAttribute("data-entry"), !entry.isEmpty {
            return entry
        }
        if el.localName == "img" && el.hasClass("latex") {
            if let alt = el.getAttribute("alt"), !alt.isEmpty { return alt }
            if let src = el.getAttribute("src"), let raw = src.jsMatch("latex\\.php\\?latex=([^&]+)")?[1],
               let decoded = raw.removingPercentEncoding {
                return decoded.replacingOccurrences(of: "+", with: " ").replacingOccurrences(of: "%5C", with: "\\")
            }
        }
        if let annotation = el.querySelector("annotation[encoding=\"application/x-tex\"]"), !annotation.textContent.isEmpty {
            return annotation.textContent.trimmed
        }
        if el.matches(".katex"), let annotation = el.querySelector(".katex-mathml annotation[encoding=\"application/x-tex\"]"),
           !annotation.textContent.isEmpty {
            return annotation.textContent.trimmed
        }
        if el.matches("script[type=\"math/tex\"]") || el.matches("script[type=\"math/tex; mode=display\"]") {
            let text = el.textContent.trimmed
            return text.isEmpty ? nil : text
        }
        if let parent = el.parentElement,
           let script = parent.querySelector("script[type=\"math/tex\"], script[type=\"math/tex; mode=display\"]") {
            let text = script.textContent.trimmed
            return text.isEmpty ? nil : text
        }
        if el.localName == "math" && !el.textContent.trimmed.isEmpty { return el.textContent.trimmed }
        return el.getAttribute("alt").flatMap { $0.isEmpty ? nil : $0 }
    }

    static func latex(from el: DOMElement) -> String? {
        if let basic = basicLatex(from: el) { return basic }
        if let data = mathML(from: el) { return MathMLToLaTeX.convert(data.math) }
        return nil
    }

    static func isBlockDisplay(_ el: DOMElement) -> Bool {
        if el.getAttribute("display") == "block" { return true }
        let classNames = el.className.lowercased()
        if classNames.contains("display") || classNames.contains("block") { return true }
        if el.closest(".katex-display, .MathJax_Display, [data-display=\"block\"]") != nil { return true }
        if el.previousElementSibling?.localName == "p" { return true }
        if el.matches(".mwe-math-fallback-image-display") { return true }
        if el.matches(".katex") { return el.closest(".katex-display") != nil }
        if el.hasAttribute("display") { return el.getAttribute("display") == "true" }
        if el.matches("script[type=\"math/tex; mode=display\"]") { return true }
        if let parent = el.closest("[display]") { return parent.getAttribute("display") == "true" }
        return false
    }

    static let fastCheck = "math, mjx-container, .MathJax, .katex, img.latex, [data-math], [data-latex], script[type^=\"math/\"]"

    static let selectors = [
        "img.latex[src*=\"latex.php\"]", "span.MathJax", "mjx-container", "script[type=\"math/tex\"]",
        "script[type=\"math/tex; mode=display\"]", ".MathJax_Preview + script[type=\"math/tex\"]", ".MathJax_Display",
        ".MathJax_SVG", ".MathJax_MathML", ".mwe-math-element", ".mwe-math-fallback-image-inline",
        ".mwe-math-fallback-image-display", ".mwe-math-mathml-inline", ".mwe-math-mathml-display", ".katex",
        ".katex-display", ".katex-mathml", ".katex-html", "[data-katex]", "script[type=\"math/katex\"]", "math",
        "[data-math]", "[data-latex]", "[data-tex]", "script[type^=\"math/\"]", "annotation[encoding=\"application/x-tex\"]",
    ].joined(separator: ",")

    private static let latexParamPatterns = ["latex", "chl", "tex", "eq", "math"].map { JSRegex("[?&]\($0)=([^&#]+)", "i") }

    static func extractLatexFromImageSrc(_ src: String) -> String? {
        func decode(_ raw: String) -> String? {
            guard let decoded = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { return nil }
            return SmallImages.looksLikeLatex.test(decoded) ? decoded : nil
        }
        for pattern in latexParamPatterns {
            if let raw = pattern.firstMatch(src)?[1], let latex = decode(raw) { return latex }
        }
        if let query = src.jsMatch("\\?([^#]+)")?[1], let latex = decode(query) { return latex }
        let path = src.components(separatedBy: "?")[0]
        for segment in path.components(separatedBy: "/").reversed() where segment.jsTest("%5[Cc]") {
            if let latex = decode(segment) { return latex }
        }
        return nil
    }

    static func hasMathLibrary(_ doc: DOMDocument) -> Bool {
        for script in doc.all("script[src]") {
            let src = (script.getAttribute("src") ?? "").lowercased()
            if src.contains("mathjax") || src.contains("katex") { return true }
        }
        for script in doc.all("script:not([src])") {
            let text = script.textContent
            if text.jsTest("MathJax\\s*[.=]") || text.jsTest("katex", "i") { return true }
        }
        return false
    }

    private static let delimiterPattern = JSRegex(
        "\\$\\$([\\s\\S]+?)\\$\\$|\\\\\\[([\\s\\S]+?)\\\\\\]|\\$([^\\s$][^$]*[^\\s$]|[^\\s$])\\$|\\\\\\(([\\s\\S]+?)\\\\\\)", "g"
    )
    private static let skipTags: Set<String> = ["PRE", "CODE", "SCRIPT", "STYLE", "MATH", "SVG", "TEXTAREA"]

    /// Raw `$…$` scanning only runs when the page loads MathJax or KaTeX.
    static func wrapRawLatexDelimiters(_ element: DOMElement, _ doc: DOMDocument, hasLibrary: Bool) {
        guard hasLibrary else { return }
        if element.querySelector(fastCheck) != nil { return }
        var textNodes: [DOMText] = []
        func walk(_ node: DOMNode) {
            if let el = node as? DOMElement, skipTags.contains(el.tagName) { return }
            if let text = node as? DOMText { textNodes.append(text); return }
            for child in node.childNodes { walk(child) }
        }
        walk(element)

        enum Part { case text(String), math(String, Bool) }
        for textNode in textNodes {
            let text = textNode.data
            if !text.contains("$") && !text.contains("\\(") && !text.contains("\\[") { continue }
            var parts: [Part] = []
            var lastIndex = 0
            var hasBlock = false
            for match in delimiterPattern.allMatches(text) {
                let block = match[1] ?? match[2]
                let inline = match[3] ?? match[4]
                let isBlock = block != nil
                let latex = (block ?? inline ?? "").trimmed
                let isBackslash = match[2] != nil || match[4] != nil
                if !isBackslash && !(latex.jsTest("\\\\[a-zA-Z]") || latex.jsTest("[_^{}]")) { continue }
                if lastIndex < match.index { parts.append(.text(text.jsSlice(lastIndex, match.index))) }
                if isBlock { hasBlock = true }
                parts.append(.math(latex, isBlock))
                lastIndex = match.end
            }
            if parts.isEmpty { continue }
            if lastIndex < text.jsLength { parts.append(.text(text.jsSlice(lastIndex))) }
            if hasBlock {
                let surrounding = parts.contains { if case .text(let t) = $0 { return !t.trimmed.isEmpty } else { return false } }
                let parentHasOther = textNode.parentElement?.childNodes.contains { n in
                    n !== textNode && ((n.isText && !n.textContent.trimmed.isEmpty) || n.isElement)
                } ?? false
                if surrounding || parentHasOther {
                    parts = parts.map { if case .math(let l, _) = $0 { return .math(l, false) } else { return $0 } }
                }
            }
            let fragment = DOMFragment()
            for part in parts {
                switch part {
                case .text(let t): fragment.appendChild(DOMText(t))
                case .math(let latex, let isBlock):
                    let math = mathElement("math")
                    math.setAttribute("xmlns", "http://www.w3.org/1998/Math/MathML")
                    math.setAttribute("display", isBlock ? "block" : "inline")
                    math.setAttribute("data-latex", latex)
                    math.textContent = latex
                    fragment.appendChild(math)
                }
            }
            textNode.replaceWith(fragment)
        }
    }

    static func createCleanMathEl(_ data: MathData? = nil, latex: String?, isBlock: Bool, _ doc: DOMDocument) -> DOMElement {
        let math = mathElement("math")
        math.setAttribute("xmlns", "http://www.w3.org/1998/Math/MathML")
        math.setAttribute("display", isBlock ? "block" : "inline")
        math.setAttribute("data-latex", latex ?? "")
        if let data {
            Utils.transferContent(data.math.clone(), math)
        } else if let latex {
            math.textContent = latex
        }
        return math
    }

    private static let scriptCleanupSelector = "script[type^=\"math/\"], .MathJax_Preview, script[type=\"text/javascript\"][src*=\"mathjax\"], script[type=\"text/javascript\"][src*=\"katex\"]"

    static let rules: [StandardizationRule] = [
        StandardizationRule(selector: selectors, fastCheck: fastCheck) { el, doc in
            let data = mathML(from: el)
            let latex = latex(from: el)
            let isBlock = isBlockDisplay(el)
            let clean = createCleanMathEl(data, latex: latex, isBlock: isBlock, doc)
            if let parent = el.parentElement, !el.matches("script[type^=\"math/\"]") {
                for script in parent.all(scriptCleanupSelector) { script.remove() }
            }
            return clean
        },
    ]
}
