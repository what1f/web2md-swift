// Port of defuddle src/removals/{scoring,selectors,hidden,small-images,metadata-block}.ts.
// Copyright (c) 2025 Steph Ango (@kepano), MIT License.

import Foundation

/// Insertion-ordered set of DOM elements keyed by identity.
struct ElementSet {
    private(set) var items: [DOMElement] = []
    private var ids: Set<ObjectIdentifier> = []

    init(_ elements: [DOMElement] = []) { for element in elements { insert(element) } }

    @discardableResult
    mutating func insert(_ element: DOMElement) -> Bool {
        guard ids.insert(ObjectIdentifier(element)).inserted else { return false }
        items.append(element)
        return true
    }

    func contains(_ element: DOMElement) -> Bool { ids.contains(ObjectIdentifier(element)) }
    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }
}

// MARK: - Content scoring

enum ContentScorer {
    private static let contentIndicators = [
        "admonition", "article", "content", "entry", "image", "img", "font", "figure", "figcaption", "pre", "main",
        "post", "story", "table",
    ]

    private static let navigationIndicators = [
        "advertisement", "all rights reserved", "banner", "cookie", "comments", "copyright", "follow me", "follow us",
        "footer", "header", "homepage", "login", "menu", "more articles", "more like this", "most read", "nav",
        "navigation", "newsletter", "popular", "privacy", "recommended", "register", "related", "responses", "share",
        "sidebar", "sign in", "sign up", "signup", "social", "sponsored", "subscribe", "terms", "trending",
    ]

    static let socialProfilePattern = JSRegex(
        "\\b(linkedin\\.com\\/(in|company)\\/|twitter\\.com\\/(?!intent\\b)\\w|x\\.com\\/(?!intent\\b)\\w|facebook\\.com\\/(?!share\\b)\\w|instagram\\.com\\/\\w|threads\\.net\\/\\w|mastodon\\.\\w)",
        "i")
    private static let datePattern = JSRegex(
        "(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\\s+\\d{1,2}|\\d{1,2}(?:st|nd|rd|th)?\\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*)",
        "i")
    private static let bylinePattern = JSRegex("\\bBy\\s+[A-Z]")
    private static let navigationIndicatorRegexes = navigationIndicators.map {
        JSRegex("\\b" + $0.jsReplace("\\s+", "g", "\\s+") + "\\b")
    }
    private static let navigationHeadingPattern = JSRegex(
        navigationIndicators.map { $0.jsReplace("\\s+", "g", "\\s+") }.joined(separator: "|"), "i")
    private static let tocHeadingPattern = JSRegex(
        "^(?:table of )?contents$|^on this page$|^in this (?:article|guide|post)$", "i")
    private static let contentDatePattern = JSRegex(
        "\\b(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\\s+\\d{1,2},?\\s+\\d{4}|\\d{1,2}(?:st|nd|rd|th)?\\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*,?\\s+\\d{4})\\b",
        "i")
    private static let contentAuthorPattern = JSRegex("\\b(?:by|written by|author:)\\s+[A-Za-z\\s]+\\b", "i")
    private static let nonContentPatterns = [
        "advert", "ad-", "ads", "banner", "cookie", "copyright", "footer", "header", "homepage", "menu", "nav",
        "newsletter", "popular", "privacy", "recommended", "related", "rights", "share", "sidebar", "social",
        "sponsored", "subscribe", "terms", "trending", "widget",
    ]

    private static func commaCount(_ text: String) -> Int {
        text.reduce(0) { $0 + ($1 == "," ? 1 : 0) }
    }

    static func scoreElement(_ element: DOMElement) -> Double {
        var score = 0.0
        let text = element.textContent
        let words = Utils.countWords(text)
        score += Double(words)
        score += Double(element.getElementsByTagName("p").count * 10)
        score += Double(commaCount(text))

        let images = element.getElementsByTagName("img").count
        score -= Double(images) / Double(words == 0 ? 1 : words) * 3

        let style = element.getAttribute("style") ?? ""
        let align = element.getAttribute("align") ?? ""
        if style.contains("float: right") || style.contains("text-align: right") || align == "right" { score += 5 }

        if contentDatePattern.test(text) { score += 10 }
        if contentAuthorPattern.test(text) { score += 10 }

        let className = Utils.className(element).lowercased()
        if className.contains("content") || className.contains("article") || className.contains("post") { score += 15 }

        if element.querySelector(Constants.footnoteInlineReferences) != nil { score += 10 }
        if element.querySelector(Constants.footnoteListSelectors) != nil { score += 10 }

        score -= Double(element.getElementsByTagName("table").count * 5)

        if element.tagName == "TD", let table = element.closest("table") {
            let width = jsParseInt(table.getAttribute("width") ?? "0") ?? 0
            let tableAlign = table.getAttribute("align") ?? ""
            let tableClass = Utils.className(table).lowercased()
            if width > 400 || tableAlign == "center" || tableClass.contains("content") || tableClass.contains("article") {
                let cells = table.getElementsByTagName("td")
                if let index = cells.firstIndex(where: { $0 === element }), index > 0, index < cells.count - 1 {
                    score += 10
                }
            }
        }

        var linkTextLength = 0
        for link in element.getElementsByTagName("a") { linkTextLength += link.textContent.jsLength }
        let textLength = text.jsLength == 0 ? 1 : text.jsLength
        let linkDensity = min(Double(linkTextLength) / Double(textLength), 0.5)
        score *= (1 - linkDensity)
        return score
    }

    static func findBestElement(_ elements: [DOMElement], minScore: Double = 50) -> DOMElement? {
        var best: DOMElement?
        var bestScore = 0.0
        for element in elements {
            let score = scoreElement(element)
            if score > bestScore {
                bestScore = score
                best = element
            }
        }
        return bestScore > minScore ? best : nil
    }

    static func scoreAndRemove(_ root: DOMNode, mainContent: DOMElement?) {
        var toRemove = ElementSet()
        for element in root.querySelectorAll(Constants.blockElementsSelector) {
            if toRemove.contains(element) { continue }
            if let mainContent, element.contains(mainContent) { continue }
            if element.closest("pre") != nil { continue }
            if element.closest("[data-defuddle]") != nil { continue }
            if element.closest("td, th") != nil { continue }
            if isLikelyContent(element) { continue }
            if scoreNonContentBlock(element) < 0 { toRemove.insert(element) }
        }
        for element in toRemove.items { element.remove() }
    }

    private static func isLikelyContent(_ element: DOMElement) -> Bool {
        if let role = element.getAttribute("role"), ["article", "main", "contentinfo"].contains(role) { return true }
        let className = Utils.className(element).lowercased()
        let id = element.id.lowercased()
        for indicator in contentIndicators where className.contains(indicator) || id.contains(indicator) { return true }
        if element.querySelector("pre, table, figure, picture") != nil { return true }

        let text = element.textContent
        let words = Utils.countWords(text)

        if let heading = element.querySelector("h1, h2, h3, h4, h5, h6") {
            let headingText = heading.textContent.trimmed
            if !headingText.isEmpty && headingText == text.trimmed {
                let lower = headingText.lowercased()
                if !navigationHeadingPattern.test(lower) && !tocHeadingPattern.test(lower) { return true }
            }
        }

        if words < 1000 {
            let hasNavigationHeading = element.querySelectorAll("h1, h2, h3, h4, h5, h6").contains {
                navigationHeadingPattern.test($0.textContent.lowercased().trimmed)
            }
            if hasNavigationHeading {
                if words < 200 { return false }
                let linkCount = element.getElementsByTagName("a").count
                if Double(linkCount) / Double(words == 0 ? 1 : words) > 0.2 { return false }
            }
        }

        if isCardGrid(element, words: words) { return false }

        if words < 80 {
            for link in element.getElementsByTagName("a")
            where socialProfilePattern.test((link.getAttribute("href") ?? "").lowercased()) {
                return false
            }
        }

        let contentBlocks = element.getElementsByTagName("p").count + element.getElementsByTagName("li").count
        if words > 50 && contentBlocks > 1 { return true }
        if words > 100 { return true }
        if words > 30 && contentBlocks > 0 { return true }
        if words >= 10 && text.jsTest("[.?!]") {
            let linkCount = element.getElementsByTagName("a").count
            if Double(linkCount) / Double(words) < 0.1 { return true }
        }
        return false
    }

    private static func scoreNonContentBlock(_ element: DOMElement) -> Double {
        if element.matches(Constants.footnoteListSelectors)
            || element.querySelector(Constants.footnoteListSelectors) != nil
            || element.closest(Constants.footnoteListSelectors) != nil {
            return 0
        }
        var score = 0.0
        let text = element.textContent
        let words = Utils.countWords(text)
        if words < 3 { return 0 }
        score += Double(commaCount(text))

        let lower = text.lowercased()
        let matches = navigationIndicatorRegexes.reduce(0) { $0 + ($1.test(lower) ? 1 : 0) }
        score -= Double(matches * 10)

        let linkElements = element.getElementsByTagName("a")
        let links = linkElements.count
        if Double(links) / Double(words) > 0.5 { score -= 15 }

        if links > 1 && words < 80 {
            let linkTextLength = linkElements.reduce(0) { $0 + $1.textContent.jsLength }
            let total = text.jsLength
            if total > 0 && Double(linkTextLength) / Double(total) > 0.8 { score -= 15 }
        }

        let lists = element.getElementsByTagName("ul").count + element.getElementsByTagName("ol").count
        if lists > 0 && links > lists * 3 { score -= 10 }

        if words < 80 {
            if linkElements.contains(where: { socialProfilePattern.test(($0.getAttribute("href") ?? "").lowercased()) }) {
                score -= 15
            }
        }

        if words < 15 && bylinePattern.test(text) && datePattern.test(text) { score -= 10 }
        if isCardGrid(element, words: words) { score -= 15 }

        let className = Utils.className(element).lowercased()
        let id = element.id.lowercased()
        for pattern in nonContentPatterns where className.contains(pattern) || id.contains(pattern) { score -= 8 }
        return score
    }

    private static func isCardGrid(_ element: DOMElement, words: Int) -> Bool {
        if words < 3 || words >= 500 { return false }
        let headings = element.querySelectorAll("h2, h3, h4")
        if headings.count < 3 { return false }
        if element.querySelectorAll("img").count < 2 { return false }
        let headingWords = headings.reduce(0) { $0 + Utils.countWords($1.textContent) }
        return Double(words - headingWords) / Double(headings.count) < 20
    }
}

// MARK: - Selector removal

enum SelectorRemoval {
    private static let screenReaderLinkTextSelector = ["sr-only", "visually-hidden", "screen-reader-text"]
        .map { "a [class*=\"\($0)\"]" }.joined(separator: ", ")
    private static let linkAnnotation = JSRegex(
        "^[\\s,(–-]*(?:(?:link )?opens in (?:a )?new (?:window|tab)|new (?:window|tab)|external(?: link| site| website)?)[\\s).]*$",
        "i")
    private static let partialRegex = JSRegex(Constants.partialSelectorsPattern, "i")
    private static let partialAnchoredRegex = JSRegex(Constants.partialSelectorsAnchoredPattern, "i")

    static func remove(
        _ root: DOMNode, removeExact: Bool = true, removePartial: Bool = true, mainContent: DOMElement?,
        skipHiddenExactSelectors: Bool = false
    ) {
        var toRemove = ElementSet()

        if removeExact {
            for element in root.querySelectorAll(Constants.exactSelectorsJoined) where element.parentNode != nil {
                if skipHiddenExactSelectors {
                    let hiddenAncestor = element.closest(Constants.hiddenExactSkipSelector)
                    let role = (element.getAttribute("role") ?? "").lowercased()
                    if element.matches(Constants.hiddenExactSelector) || (hiddenAncestor != nil && role == "dialog") {
                        continue
                    }
                }
                if element.closest("pre, code") != nil { continue }
                if element.matches(Constants.hiddenExactSelector)
                    && Utils.hasResponsiveShowClass(Utils.className(element)) {
                    continue
                }
                toRemove.insert(element)
            }
        }

        if removePartial {
            var candidates = ElementSet(root.querySelectorAll(Constants.testAttributesSelector))
            if let mainContent {
                for element in mainContent.querySelectorAll(Constants.testAttributesSelector) { candidates.insert(element) }
            }
            for element in candidates.items {
                if toRemove.contains(element) { continue }
                if element.closest("[data-defuddle]") != nil { continue }
                let tag = element.tagName
                if tag == "CODE" || tag == "PRE" || element.querySelector("pre") != nil
                    || element.closest("code, pre") != nil {
                    continue
                }
                let isHeading = tag.jsTest("^H[1-6]$")
                let attrs: String
                if isHeading {
                    attrs = Utils.className(element).lowercased()
                } else {
                    attrs = [
                        Utils.className(element),
                        element.getAttribute("data-component") ?? "",
                        element.getAttribute("data-test") ?? "",
                        element.getAttribute("data-testid") ?? "",
                        element.getAttribute("data-test-id") ?? "",
                        element.getAttribute("data-qa") ?? "",
                        element.getAttribute("data-cy") ?? "",
                    ].joined(separator: " ").lowercased()
                }
                let id = isHeading ? "" : element.id.lowercased()
                let hasAttrs = !attrs.trimmed.isEmpty
                if !hasAttrs && id.isEmpty { continue }
                let attrsMatch = hasAttrs && partialRegex.test(attrs)
                var idMatch = false
                if !id.isEmpty {
                    idMatch = id.jsTest("[\\s_\\-:.]") ? partialRegex.test(id) : partialAnchoredRegex.test(id)
                }
                if attrsMatch || idMatch { toRemove.insert(element) }
            }

            var annotations = ElementSet(root.querySelectorAll(screenReaderLinkTextSelector))
            if let mainContent {
                for element in mainContent.querySelectorAll(screenReaderLinkTextSelector) { annotations.insert(element) }
            }
            for element in annotations.items {
                guard let link = element.closest("a"), !toRemove.contains(element),
                      element.closest("code, pre, [data-defuddle]") == nil,
                      linkAnnotation.test(element.textContent),
                      hasVisibleText(link, hidden: annotations, removing: toRemove)
                else { continue }
                toRemove.insert(element)
            }
        }

        for element in toRemove.items {
            if let mainContent, element.contains(mainContent) { continue }
            if element.tagName == "A" && element.closest("h1, h2, h3, h4, h5, h6") != nil { continue }
            if element.matches(Constants.footnoteListSelectors)
                || element.querySelector(Constants.footnoteListSelectors) != nil {
                continue
            }
            if let parent = element.parentElement, parent.matches(Constants.footnoteListSelectors) { continue }
            if element.hasClass("footnote-backref") && element.closest("#footnotes") != nil { continue }
            if element.tagName == "BUTTON" && element.querySelector("img, picture, video") != nil {
                if let parent = element.parentElement {
                    for media in element.querySelectorAll("img, picture, video") { parent.insertBefore(media, element) }
                    element.remove()
                }
                continue
            }
            if element.tagName == "BUTTON" && element.closest("p, li, td, th, span, h1, h2, h3, h4, h5, h6") != nil {
                element.replaceWith(element.childNodes)
                continue
            }
            element.remove()
        }
    }

    private static func hasVisibleText(_ node: DOMNode, hidden: ElementSet, removing: ElementSet) -> Bool {
        node.childNodes.contains { child in
            if child.nodeType == .text { return !child.textContent.trimmed.isEmpty }
            guard let element = child as? DOMElement else { return false }
            return !hidden.contains(element) && !removing.contains(element)
                && hasVisibleText(element, hidden: hidden, removing: removing)
        }
    }
}

// MARK: - Hidden elements

enum HiddenRemoval {
    private static let hiddenStylePattern = JSRegex(
        "(?:^|;\\s*)(?:display\\s*:\\s*none|visibility\\s*:\\s*hidden|opacity\\s*:\\s*0)(?:\\s*;|\\s*$)", "i")

    static func remove(_ root: DOMNode) {
        var toRemove = ElementSet()
        for element in root.querySelectorAll("*") {
            if element.localName == "math" || element.querySelector("math, [data-mathml], .katex-mathml") != nil {
                continue
            }
            if let style = element.getAttribute("style"), hiddenStylePattern.test(style) {
                toRemove.insert(element)
                continue
            }
            let className = element.getAttribute("class") ?? ""
            guard !className.isEmpty else { continue }
            if Utils.hasResponsiveShowClass(className) { continue }
            for token in className.jsSplit("\\s+") {
                let exact = token == "hidden" || token == "invisible"
                let variant = !token.contains("[") && (token.hasSuffix(":hidden") || token.hasSuffix(":invisible"))
                if exact || variant {
                    toRemove.insert(element)
                    break
                }
            }
        }
        for element in toRemove.items { element.remove() }
    }
}

// MARK: - Small images

enum SmallImages {
    private static let minDimension = 33
    static let urlWidthPattern = JSRegex("(?:width[=:/]|[/,?&]w[_:=])(\\d+)")
    static let looksLikeLatex = JSRegex("\\\\[a-zA-Z]{2,}")

    static func identifier(_ element: DOMElement) -> String? {
        if element.localName == "img" {
            if let dataSrc = element.getAttribute("data-src"), !dataSrc.isEmpty { return "src:\(dataSrc)" }
            let src = element.getAttribute("src") ?? ""
            let srcset = element.getAttribute("srcset") ?? ""
            if !src.isEmpty { return "src:\(src)" }
            if !srcset.isEmpty { return "srcset:\(srcset)" }
            if let dataSrcset = element.getAttribute("data-srcset"), !dataSrcset.isEmpty { return "srcset:\(dataSrcset)" }
        }
        let id = element.id
        let className = Utils.className(element)
        let viewBox = element.localName == "svg" ? element.getAttribute("viewBox") ?? "" : ""
        if !id.isEmpty { return "id:\(id)" }
        if !viewBox.isEmpty { return "viewBox:\(viewBox)" }
        if !className.isEmpty { return "class:\(className)" }
        return nil
    }

    static func find(_ root: DOMNode) -> Set<String> {
        var result = Set<String>()
        for element in root.querySelectorAll("img, svg") {
            let attrWidth = jsParseInt(element.getAttribute("width") ?? "0") ?? 0
            let attrHeight = jsParseInt(element.getAttribute("height") ?? "0") ?? 0
            var viewBoxWidth = 0.0
            var viewBoxHeight = 0.0
            if element.localName == "svg", let viewBox = element.getAttribute("viewBox") {
                let parts = viewBox.jsSplit("[\\s,]+")
                if parts.count == 4 {
                    viewBoxWidth = jsParseFloat(parts[2]) ?? 0
                    viewBoxHeight = jsParseFloat(parts[3]) ?? 0
                }
            }
            let style = element.getAttribute("style") ?? ""
            let styleWidth = jsParseInt(style.jsMatch("width\\s*:\\s*(\\d+)")?[1] ?? "0") ?? 0
            let styleHeight = jsParseInt(style.jsMatch("height\\s*:\\s*(\\d+)")?[1] ?? "0") ?? 0

            var widths = [Double(attrWidth), Double(styleWidth), viewBoxWidth].filter { $0 > 0 }
            let heights = [Double(attrHeight), Double(styleHeight), viewBoxHeight].filter { $0 > 0 }

            if widths.isEmpty && heights.isEmpty && element.localName == "img" {
                let srcset = element.getAttribute("srcset") ?? ""
                if let oneX = srcset.jsMatch("(\\S+)\\s+1x"), let url = oneX[1] {
                    let width = jsParseInt(urlWidthPattern.firstMatch(url)?[1] ?? "0") ?? 0
                    if width > 0 { widths.append(Double(width)) }
                }
            }

            guard !widths.isEmpty || !heights.isEmpty else { continue }
            let width = widths.min() ?? .infinity
            let height = heights.min() ?? .infinity
            guard width < Double(minDimension) || height < Double(minDimension) else { continue }
            if element.localName == "img" {
                if looksLikeLatex.test(element.getAttribute("alt") ?? "") { continue }
                if element.hasClass("latex") || element.hasClass("tex") { continue }
                if !(element.getAttribute("data-latex") ?? "").isEmpty || !(element.getAttribute("data-math") ?? "").isEmpty {
                    continue
                }
            }
            if let id = identifier(element) { result.insert(id) }
        }
        return result
    }

    static func remove(_ root: DOMNode, smallImages: Set<String>) {
        for tag in ["img", "svg"] {
            for element in root.getElementsByTagName(tag) {
                if tag == "img" {
                    let src = element.getAttribute("src") ?? ""
                    let hasAltSrc = ["srcset", "data-src", "data-srcset", "data-lazy-src", "data-original"]
                        .contains { !(element.getAttribute($0) ?? "").isEmpty }
                    if src.isEmpty && !hasAltSrc {
                        element.remove()
                        continue
                    }
                    if !hasAltSrc && element.closest("picture") == nil && isBase64Placeholder(src) {
                        element.remove()
                        continue
                    }
                }
                if let id = identifier(element), smallImages.contains(id) { element.remove() }
            }
        }
    }

    static func isBase64Placeholder(_ src: String) -> Bool {
        guard let match = src.jsMatch("^data:image\\/([^;]+);base64,") else { return false }
        if match[1] == "svg+xml" { return false }
        return src.jsLength - match.length < 133
    }
}

// MARK: - Metadata block

enum MetadataBlock {
    private static let dateRE = JSRegex(
        "\\b(?:(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\\s+\\d{1,2}[\\s,]+\\d{4}|\\d{1,2}(?:st|nd|rd|th)?\\s+(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\\s+\\d{4}|\\d{4}[-/]\\d{1,2}[-/]\\d{1,2})\\b",
        "i")

    static func remove(_ mainContent: DOMElement) {
        guard let h1 = mainContent.querySelector("h1") else { return }
        var sibling = h1.nextElementSibling
        var index = 0
        while index < 3, let current = sibling {
            let next = current.nextElementSibling
            let text = current.textContent.trimmed
            if !text.isEmpty && text.jsLength < 300 {
                var hasDate = dateRE.test(text)
                if !hasDate {
                    hasDate = current.querySelectorAll("p, time").contains { dateRE.test($0.textContent.trimmed) }
                }
                if hasDate {
                    current.remove()
                    break
                }
            }
            sibling = next
            index += 1
        }
    }
}
