// Port of defuddle src/defuddle.ts (main content pipeline).
// Copyright (c) 2025 Steph Ango (@kepano), MIT License.

import Foundation

struct DefuddleOptions {
    var removeExactSelectors = true
    var removePartialSelectors = true
    var removeHiddenElements = true
    var removeLowScoring = true
    var removeSmallImages = true
    var removeContentPatterns = true
    var standardize = true
    var removeImages = false
    var contentSelector: String?
}

struct DefuddleResult {
    var content: String
    var metadata: PageMetadata
    var wordCount: Int
    /// The metadata image also appeared in the article and was removed from it.
    var coverRemoved = false
}

/// Generic article extraction: finds the main content of a page, strips clutter
/// and normalizes the HTML so it converts cleanly to Markdown.
final class DefuddleEngine {
    private var doc: DOMDocument
    private let url: String
    private let baseOptions: DefuddleOptions
    private var schemaOrgData: JSONValue?
    private var metaTags: [MetaTag]?
    private var metadata: PageMetadata?
    private var smallImages: Set<String>?

    /// The document is mutated (images normalized, possibly removed); pass a copy.
    init(document: DOMDocument, url: String, options: DefuddleOptions = DefuddleOptions()) {
        self.doc = document
        self.url = url.isEmpty ? document.url : url
        self.baseOptions = options
    }

    func parse() -> DefuddleResult {
        parseWithRetries() ?? fallbackResponse()
    }

    // MARK: - Retries

    private func parseWithRetries() -> DefuddleResult? {
        // Template content is inert and outside the document tree in browsers and
        // linkedom; only declarative shadow roots are hoisted into the page.
        for template in doc.all("template") where !template.hasAttribute("shadowrootmode") && !template.hasAttribute("shadowroot") {
            template.removeAllChildren()
        }
        if let body = doc.body {
            normalizeAttributes(body)
            resolveNoscriptImages(body)
        }

        var result = parseInternal { _ in }

        if (result?.wordCount ?? 0) < 200 {
            let retry = parseInternal { $0.removePartialSelectors = false }
            if let retry, result == nil || retry.wordCount > result!.wordCount * 2 { result = retry }
        }

        if (result?.wordCount ?? 0) < 50 {
            let hiddenRetry = parseInternal { $0.removeHiddenElements = false }
            if let hiddenRetry, result == nil || hiddenRetry.wordCount > result!.wordCount * 2 { result = hiddenRetry }

            if let selector = findLargestHiddenContentSelector() {
                let retry = parseInternal {
                    $0.removeHiddenElements = false
                    $0.removePartialSelectors = false
                    $0.contentSelector = selector
                }
                if let retry {
                    if let current = result {
                        if retry.wordCount > current.wordCount
                            || (Double(retry.wordCount) > max(20, Double(current.wordCount) * 0.7)
                                && retry.content.utf16.count < current.content.utf16.count) {
                            result = retry
                        }
                    } else {
                        result = retry
                    }
                }
            }
        }

        if (result?.wordCount ?? 0) < 50 {
            let indexRetry = parseInternal {
                $0.removeLowScoring = false
                $0.removePartialSelectors = false
                $0.removeContentPatterns = false
            }
            if let indexRetry, result == nil || indexRetry.wordCount > result!.wordCount { result = indexRetry }
        }

        let schemaText = Self.schemaText(result?.metadata.schemaOrgData ?? metadata?.schemaOrgData ?? .null)
        if !schemaText.isEmpty && Double(TextMetrics.countHTMLWords(schemaText)) > Double(result?.wordCount ?? 0) * 1.5 {
            let liveDoc = doc
            defer { doc = liveDoc }
            let safeDoc = liveDoc.cloneDocument()
            if let body = safeDoc.body { Utils.stripUnsafeElements(body) }
            doc = safeDoc
            if let body = doc.body, let match = findElementBySchemaText(body, schemaText) {
                let selector = elementSelector(match)
                if let retry = parseInternal({ $0.contentSelector = selector }) { result = retry }
            } else {
                let safeHTML = sanitizeHTML(schemaText)
                if result != nil {
                    result!.content = safeHTML
                    result!.wordCount = TextMetrics.countHTMLWords(safeHTML)
                } else {
                    result = metadataResponse(safeHTML)
                }
            }
        }
        return result
    }

    static func schemaText(_ data: JSONValue, depth: Int = 0) -> String {
        if data.isNull || depth > 10 { return "" }
        let items = data.isArray ? data.items : [data]
        for item in items {
            if item.isArray {
                let found = schemaText(item, depth: depth + 1)
                if !found.isEmpty { return found }
                continue
            }
            if case .string(let text) = item["text"], !text.isEmpty { return text }
            if case .string(let body) = item["articleBody"], !body.isEmpty { return body }
            if item["@graph"].isArray {
                let found = schemaText(item["@graph"], depth: depth + 1)
                if !found.isEmpty { return found }
            }
        }
        return ""
    }

    // MARK: - Metadata

    private func ensureMetadata() -> PageMetadata {
        if metaTags == nil { metaTags = collectMetaTags() }
        if schemaOrgData == nil { schemaOrgData = extractSchemaOrgData() }
        if metadata == nil {
            metadata = MetadataExtractor.extract(doc, schema: schemaOrgData ?? .null, metaTags: metaTags ?? [], pageURL: url)
        }
        return metadata!
    }

    private func collectMetaTags() -> [MetaTag] {
        doc.all("meta").compactMap { meta in
            guard let content = meta.getAttribute("content"), !content.isEmpty else { return nil }
            return MetaTag(name: meta.getAttribute("name"), property: meta.getAttribute("property"),
                           content: Utils.decodeHTMLEntities(content))
        }
    }

    private func extractSchemaOrgData() -> JSONValue {
        var items: [JSONValue] = []
        for script in doc.all("script[type=\"application/ld+json\"]") {
            let json = script.textContent
                .jsReplace("\\/\\*[\\s\\S]*?\\*\\/|^\\s*\\/\\/.*$", "gm", "")
                .jsReplace("^\\s*<!\\[CDATA\\[([\\s\\S]*?)\\]\\]>\\s*$", "", "$1")
                .jsReplace("^\\s*(\\*\\/|\\/\\*)\\s*|\\s*(\\*\\/|\\/\\*)\\s*$", "g", "")
                .trimmed
            guard let data = JSONValue.parse(json) else { continue }
            if data["@graph"].isArray { items.append(contentsOf: data["@graph"].items) } else { items.append(data) }
        }
        return .array(items.map(Self.decodeStrings))
    }

    private static func decodeStrings(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text): .string(Utils.decodeHTMLEntities(text))
        case .array(let items): .array(items.map(decodeStrings))
        case .object(let dict, let keys): .object(dict.mapValues(decodeStrings), keys: keys)
        default: value
        }
    }

    private func metadataResponse(_ content: String) -> DefuddleResult {
        DefuddleResult(content: content, metadata: ensureMetadata(), wordCount: TextMetrics.countHTMLWords(content))
    }

    private func fallbackResponse() -> DefuddleResult {
        guard let body = doc.body else { return metadataResponse("") }
        let safeBody = body.clone()
        Utils.stripUnsafeElements(safeBody)
        resolveRelativeUrls(safeBody)
        return metadataResponse(safeBody.innerHTML)
    }

    private func sanitizeHTML(_ html: String) -> String {
        if html.isEmpty { return html }
        let container = doc.createElement("div")
        container.appendChild(Utils.parseHTML(html))
        Utils.stripUnsafeElements(container)
        resolveRelativeUrls(container)
        return container.innerHTML
    }

    // MARK: - Pipeline

    private func parseInternal(_ override: (inout DefuddleOptions) -> Void) -> DefuddleResult? {
        var options = baseOptions
        override(&options)
        guard doc.documentElement != nil else {
            return DefuddleResult(content: "", metadata: PageMetadata(domain: WebURL.hostname(url) ?? ""), wordCount: 0)
        }
        var metadata = ensureMetadata()
        let schema = schemaOrgData ?? .null

        if options.removeImages {
            for img in doc.getElementsByTagName("img") { img.remove() }
        }
        if smallImages == nil { smallImages = SmallImages.find(doc) }
        let smallImages = smallImages ?? []

        let clone = doc.cloneDocument()
        clone.body?.normalize()
        flattenDeclarativeShadowRoots(clone)
        resolveStreamedContent(clone)

        var found: DOMElement?
        if let selector = options.contentSelector { found = clone.querySelector(selector) }
        if found == nil { found = findMainContent(clone) }
        if let f = found, let ancestor = f.closest("[data-defuddle]") { found = ancestor }
        if let f = found, f.localName == "body" {
            let text = Self.schemaText(schema)
            if !text.isEmpty, let body = clone.body, let element = findElementBySchemaText(body, text) { found = element }
        }
        guard let mainContent = found else { return nil }

        if !metadata.published.isEmpty || !metadata.author.isEmpty { MetadataBlock.remove(mainContent) }
        for wbr in mainContent.all("wbr") { wbr.remove() }

        if options.standardize {
            adoptExternalFootnotes(mainContent, clone)
            Footnotes.standardize(mainContent)
            CalloutElements.standardize(mainContent)
        }
        if options.removeSmallImages { SmallImages.remove(clone, smallImages: smallImages) }
        if options.removeHiddenElements { HiddenRemoval.remove(clone) }
        if options.removeContentPatterns { ContentPatterns.removeEyebrowLabel(mainContent) }
        if options.removeExactSelectors || options.removePartialSelectors {
            SelectorRemoval.remove(clone, removeExact: options.removeExactSelectors,
                                   removePartial: options.removePartialSelectors, mainContent: mainContent,
                                   skipHiddenExactSelectors: !options.removeHiddenElements)
        }
        if options.removeLowScoring { ContentScorer.scoreAndRemove(clone, mainContent: mainContent) }
        if options.removeContentPatterns {
            ContentPatterns.remove(mainContent, url: url, title: metadata.title, description: metadata.description)
        }
        if options.standardize {
            Standardize.standardizeContent(mainContent, title: metadata.title, doc: clone,
                                           hasMathLibrary: MathElements.hasMathLibrary(doc))
        }
        resolveRelativeUrls(mainContent)
        deduplicateImages(mainContent)
        let imageCountBefore = mainContent.all("img").count
        if let best = removeCoverImage(mainContent, metadata.image), !best.isEmpty {
            metadata.image = best
            self.metadata?.image = best
        }
        let coverRemoved = mainContent.all("img").count < imageCountBefore
        let unsafeRoot = Utils.stripUnsafeElements(mainContent)
        let content = unsafeRoot ? "" : mainContent.outerHTML
        return DefuddleResult(content: content, metadata: metadata, wordCount: TextMetrics.countHTMLWords(content),
                              coverRemoved: coverRemoved)
    }

    // MARK: - Finding content

    private func findMainContent(_ doc: DOMDocument) -> DOMElement? {
        struct Candidate { let element: DOMElement; let score: Double; let selectorIndex: Int }
        var candidates: [Candidate] = []
        let entryPoints = Constants.entryPointElements
        for (index, selector) in entryPoints.enumerated() {
            for element in doc.querySelectorAll(selector) {
                let score = Double((entryPoints.count - index) * 40) + ContentScorer.scoreElement(element)
                candidates.append(Candidate(element: element, score: score, selectorIndex: index))
            }
        }
        if candidates.isEmpty { return findContentByScoring(doc) }
        candidates = candidates.enumerated().sorted {
            $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset
        }.map(\.element)

        if candidates.count == 1 && candidates[0].element.localName == "body",
           let table = findTableBasedContent(doc) {
            return table
        }

        let top = candidates[0]
        var best = top
        for child in candidates.dropFirst() {
            let words = TextMetrics.countWords(child.element.textContent)
            if child.selectorIndex < best.selectorIndex && best.element.contains(child.element) && words > 50 {
                var siblings = 0
                for c in candidates where c.selectorIndex == child.selectorIndex && top.element.contains(c.element) {
                    siblings += 1
                    if siblings > 1 { break }
                }
                if siblings > 1 { continue }
                best = child
            }
        }
        return best.element
    }

    private func findTableBasedContent(_ doc: DOMDocument) -> DOMElement? {
        let tables = doc.getElementsByTagName("table")
        let hasTableLayout = tables.contains { table in
            let className = Utils.className(table).lowercased()
            return (jsParseInt(table.getAttribute("width") ?? "0") ?? 0) > 400
                || table.getAttribute("align") == "center"
                || className.contains("content") || className.contains("article")
                || table.getElementsByTagName("tr").contains { row in
                    let cells = row.children.filter { $0.tagName == "TD" }
                    return cells.count >= 2 && cells.contains { $0.hasAttribute("width") }
                }
        }
        if !hasTableLayout { return nil }
        guard let bestCell = ContentScorer.findBestElement(doc.getElementsByTagName("td")) else { return nil }
        let cellWords = TextMetrics.countWords(bestCell.textContent)
        let bodyWords = TextMetrics.countWords((doc.body ?? doc.documentElement)?.textContent ?? "")
        return cellWords * 2 < bodyWords ? nil : bestCell
    }

    private func findContentByScoring(_ doc: DOMDocument) -> DOMElement? {
        var best: (DOMElement, Double)?
        for element in doc.querySelectorAll(Constants.blockElementsSelector) {
            let score = ContentScorer.scoreElement(element)
            if score > 0 && score > (best?.1 ?? 0) { best = (element, score) }
        }
        return best?.0
    }

    private func findElementBySchemaText(_ root: DOMElement, _ schemaText: String) -> DOMElement? {
        let firstParagraph = schemaText.jsSplit("\\n\\s*\\n").first?.trimmed ?? ""
        let phrase = firstParagraph.jsSubstring(0, 100).trimmed
        if phrase.isEmpty { return nil }
        let schemaWords = TextMetrics.countWords(schemaText)
        var bestMatch: DOMElement?
        var bestSize = Int.max
        for element in root.descendantElements() {
            let text = element.textContent
            if !text.contains(phrase) { continue }
            let words = TextMetrics.countWords(text)
            if Double(words) >= Double(schemaWords) * 0.8 && words < bestSize {
                bestSize = words
                bestMatch = element
            }
        }
        return bestMatch
    }

    private func findLargestHiddenContentSelector() -> String? {
        let clone = doc.cloneDocument()
        flattenDeclarativeShadowRoots(clone)
        resolveStreamedContent(clone)
        guard let body = clone.body else { return nil }
        var best: DOMElement?
        var bestWords = 0
        for element in body.querySelectorAll(Constants.hiddenExactSkipSelector)
        where !(element.getAttribute("class") ?? "").contains("math") {
            let words = TextMetrics.countWords(element.textContent)
            if words > bestWords {
                best = element
                bestWords = words
            }
        }
        guard let best, bestWords >= 30 else { return nil }
        return elementSelector(best)
    }

    private func elementSelector(_ element: DOMElement) -> String {
        var parts: [String] = []
        var current: DOMElement? = element
        while let el = current, el.localName != "html" {
            var selector = el.localName
            let idSelector = el.id.isEmpty ? nil : Utils.classOrIdSelector("id", el.id)
            let classNames = idSelector != nil ? [] : Utils.className(el).jsSplit("[\\t\\n\\f\\r ]+")
                .filter { Utils.classOrIdSelector("class", $0) != nil }
            selector += idSelector ?? classNames.compactMap { Utils.classOrIdSelector("class", $0) }.joined()
            if idSelector == nil, let parent = el.parentElement {
                let sameTag = parent.children.filter { $0.localName == el.localName }
                if sameTag.filter({ sibling in classNames.allSatisfy { sibling.hasClass($0) } }).count > 1,
                   let index = sameTag.firstIndex(where: { $0 === el }) {
                    selector += ":nth-of-type(\(index + 1))"
                }
            }
            parts.insert(selector, at: 0)
            current = el.parentElement
        }
        return parts.joined(separator: " > ")
    }

    private func adoptExternalFootnotes(_ mainContent: DOMElement, _ root: DOMDocument) {
        guard let body = root.body, mainContent !== body else { return }
        for el in body.all("div, section, aside") {
            let className = Utils.className(el)
            if !className.jsTest("footnote", "i") && !el.id.jsTest("footnote", "i") { continue }
            if mainContent.contains(el) || el.contains(mainContent) { continue }
            guard let heading = el.querySelector("h1, h2, h3, h4, h5, h6"),
                  Footnotes.sectionPattern.test(heading.textContent.trimmed) else { continue }
            mainContent.appendChild(el)
        }
    }

    // MARK: - Pre-processing

    private func normalizeAttributes(_ body: DOMElement) {
        for el in body.all("img, source") {
            if el.attributes.contains(where: { $0.name == "srcSet" }), let value = el.getAttribute("srcSet") {
                el.removeAttribute("srcSet")
                el.setAttribute("srcset", value)
            }
        }
    }

    private func resolveNoscriptImages(_ body: DOMElement) {
        for noscript in body.all("noscript") {
            var noscriptImg = noscript.querySelector("img")
            if noscriptImg == nil {
                var html = noscript.innerHTML
                if !html.contains("<img") { html = noscript.textContent }
                if !html.contains("<img") { continue }
                noscriptImg = Utils.parseHTML(html).querySelector("img")
            }
            guard let realImg = noscriptImg else { continue }
            let realSrc = realImg.getAttribute("src") ?? ""
            if realSrc.isEmpty || realSrc.hasPrefix("data:") { continue }
            let alt = realImg.getAttribute("alt")
            guard let parent = noscript.parentElement else { continue }

            var matched = false
            for img in parent.all(":scope > img") {
                guard (img.getAttribute("src") ?? "").hasPrefix("data:"), let alt, !alt.isEmpty,
                      img.getAttribute("alt") == alt else { continue }
                img.setAttribute("src", realSrc)
                if let srcset = realImg.getAttribute("srcset"), !srcset.isEmpty { img.setAttribute("srcset", srcset) }
                matched = true
                break
            }
            if !matched && isLazyImageContext(noscript) {
                let container = noscript.closest("figure") ?? parent
                let hasRealImage = container.all("img").contains { img in
                    if img.closest("noscript") != nil { return false }
                    let src = img.getAttribute("src") ?? ""
                    return !src.isEmpty && !src.hasPrefix("data:")
                }
                if !hasRealImage { parent.insertBefore(realImg.clone(), noscript) }
            }
        }
    }

    private func isLazyImageContext(_ noscript: DOMElement) -> Bool {
        if noscript.closest("figure") != nil { return true }
        guard let parent = noscript.parentElement else { return false }
        if parent.children.contains(where: { $0 !== noscript && Utils.className($0).lowercased().contains("lazy") }) {
            return true
        }
        let parentClass = Utils.className(parent).lowercased()
        return ["image", "img", "picture", "photo", "media"].contains { parentClass.contains($0) }
    }

    private func flattenDeclarativeShadowRoots(_ clone: DOMDocument) {
        guard let body = clone.body else { return }
        for _ in 0..<10 {
            let templates = body.all("template[shadowrootmode], template[shadowroot]").filter { template in
                let mode = (template.getAttribute("shadowrootmode") ?? template.getAttribute("shadowroot") ?? "").lowercased()
                return mode == "open" || mode == "closed"
            }
            if templates.isEmpty { return }
            for template in templates {
                guard let host = template.parentNode else { continue }
                while let child = template.firstChild { host.insertBefore(child, template) }
                template.remove()
            }
        }
    }

    private func resolveStreamedContent(_ doc: DOMDocument) {
        var swaps: [(String, String)] = []
        let pattern = JSRegex("\\$RC\\(\"(B:\\d+)\",\"(S:\\d+)\"\\)", "g")
        for script in doc.all("script") {
            let text = script.textContent
            if !text.contains("$RC(") { continue }
            for match in pattern.allMatches(text) { swaps.append((match[1] ?? "", match[2] ?? "")) }
        }
        for (templateId, contentId) in swaps {
            guard let template = doc.getElementById(templateId), let content = doc.getElementById(contentId),
                  let parent = template.parentNode else { continue }
            var next = template.nextSibling
            var foundMarker = false
            while let node = next {
                let following = node.nextSibling
                if let comment = node as? DOMComment, comment.data == "/$" {
                    node.remove()
                    foundMarker = true
                    break
                }
                node.remove()
                next = following
            }
            if !foundMarker { continue }
            while let child = content.firstChild { parent.insertBefore(child, template) }
            template.remove()
            content.remove()
        }
    }

    // MARK: - URLs

    private func resolveRelativeUrls(_ element: DOMElement) {
        if url.isEmpty { return }
        var baseURL = url
        if let baseHref = doc.querySelector("base[href]")?.getAttribute("href"), !baseHref.isEmpty,
           let resolved = WebURL.resolve(baseHref, base: url) {
            baseURL = resolved
        }
        func resolve(_ value: String) -> String {
            let normalized = value.trimmed.jsReplace("^\\\\?[\"']+", "", "").jsReplace("\\\\?[\"']+$", "", "")
            if normalized.hasPrefix("#") { return normalized }
            return WebURL.resolve(normalized, base: baseURL) ?? (normalized.isEmpty ? value : normalized)
        }
        for el in element.all("[href]") {
            if let href = el.getAttribute("href"), !href.isEmpty { el.setAttribute("href", resolve(href)) }
        }
        for el in element.all("[src]") {
            if let src = el.getAttribute("src"), !src.isEmpty { el.setAttribute("src", resolve(src)) }
        }
        for el in element.all("[srcset]") {
            guard let srcset = el.getAttribute("srcset"), !srcset.isEmpty else { continue }
            let entries = ImageElements.srcsetEntries(srcset)
            if !entries.isEmpty {
                el.setAttribute("srcset", entries.map { "\(resolve($0.url)) \($0.descriptor)" }.joined(separator: ", "))
            } else {
                let resolved = srcset.components(separatedBy: ",").map { entry -> String in
                    var parts = entry.trimmed.jsSplit("\\s+")
                    if let first = parts.first, !first.isEmpty { parts[0] = resolve(first) }
                    return parts.joined(separator: " ")
                }.joined(separator: ", ")
                el.setAttribute("srcset", resolved)
            }
        }
        for el in element.all("[poster]") {
            if let poster = el.getAttribute("poster"), !poster.isEmpty { el.setAttribute("poster", resolve(poster)) }
        }
    }

    // MARK: - Images

    private func deduplicateImages(_ body: DOMElement) {
        for figure in body.all("figure") {
            let images = figure.all("img").filter { $0.closest("noscript") == nil && $0.parentElement != nil }
            if images.count < 2 { continue }
            var groups: [(key: String?, images: [DOMElement])] = []
            for img in images {
                let src = img.getAttribute("src") ?? ""
                if src.isEmpty || src.hasPrefix("data:") { continue }
                let alt = (img.getAttribute("alt") ?? "").trimmed
                let key: String? = alt.isEmpty ? nil : alt
                if let index = groups.firstIndex(where: { $0.key == key }) {
                    groups[index].images.append(img)
                } else {
                    groups.append((key, [img]))
                }
            }
            for group in groups where group.images.count >= 2 {
                let firstSrc = group.images[0].getAttribute("src")
                if group.key != nil && group.images.allSatisfy({ $0.getAttribute("src") == firstSrc }) { continue }
                keepBestImage(group.images)
            }
        }

        let images = body.all("img")
        if images.count > 1 {
            for i in 0..<(images.count - 1) {
                let img = images[i]
                let other = images[i + 1]
                if img.parentElement == nil || img.closest("noscript") != nil || img.closest("figure") != nil { continue }
                let alt = (img.getAttribute("alt") ?? "").trimmed
                let src = img.getAttribute("src") ?? ""
                if alt.isEmpty || src.isEmpty || src.hasPrefix("data:") { continue }
                if other.parentElement == nil || other.closest("noscript") != nil || other.closest("figure") != nil { continue }
                if (other.getAttribute("alt") ?? "").trimmed != alt { continue }
                let otherSrc = other.getAttribute("src") ?? ""
                if otherSrc.isEmpty || otherSrc.hasPrefix("data:") || otherSrc == src { continue }
                if !noVisibleContentBetween(img, other) { continue }
                keepBestImage([img, other])
            }
        }

        for img in body.all("img") {
            guard let parent = img.parentElement, img.closest("a, figure, noscript") == nil else { continue }
            let src = img.getAttribute("src") ?? ""
            if src.isEmpty || src.hasPrefix("data:") { continue }
            let normalized = normalizeSrc(src)
            for link in parent.all(":scope > a[href]") where link.querySelector("img") != nil {
                if normalized == normalizeSrc(link.getAttribute("href") ?? "") {
                    img.remove()
                    break
                }
            }
        }
    }

    private func keepBestImage(_ group: [DOMElement]) {
        var best = group[0]
        for candidate in group.dropFirst() {
            let winner = pickBestImage(best, candidate)
            (winner === best ? candidate : best).remove()
            best = winner
        }
    }

    private func noVisibleContentBetween(_ a: DOMNode, _ b: DOMNode) -> Bool {
        func next(_ node: DOMNode) -> DOMNode? {
            if let first = node.firstChild { return first }
            var n: DOMNode? = node
            while let current = n {
                if let sibling = current.nextSibling { return sibling }
                n = current.parentNode
            }
            return nil
        }
        var node = next(a)
        while let current = node, current !== b {
            if current.isText && !current.textContent.trimmed.isEmpty { return false }
            node = next(current)
        }
        return true
    }

    private func normalizeSrc(_ url: String) -> String {
        url.jsReplace("^https?:\\/\\/", "", "").components(separatedBy: "?")[0]
    }

    private func removeCoverImage(_ body: DOMElement, _ metadataImage: String) -> String? {
        if metadataImage.isEmpty { return nil }
        let metaNorm = normalizeSrc(metadataImage)
        for img in body.all("img") {
            let src = img.getAttribute("src") ?? ""
            if src.isEmpty || src.hasPrefix("data:") || normalizeSrc(src) != metaNorm { continue }
            let bestURL = largestImageSrc(img)
            if let figure = img.closest("figure"), figure.querySelector("figcaption") != nil { return bestURL }
            img.remove()
            return bestURL
        }
        return nil
    }

    private static let urlWidthPattern = JSRegex("(?:width[=:/]|[/,?&]w[_:=])(\\d+)")

    private func pickBestImage(_ a: DOMElement, _ b: DOMElement) -> DOMElement {
        func tier(_ img: DOMElement) -> Int {
            !(img.getAttribute("srcset") ?? "").isEmpty ? 2 : img.closest("picture") != nil ? 1 : 0
        }
        func width(_ img: DOMElement) -> Int {
            jsParseInt(Self.urlWidthPattern.firstMatch(img.getAttribute("src") ?? "")?[1]) ?? 0
        }
        if tier(a) != tier(b) { return tier(a) > tier(b) ? a : b }
        if width(a) != width(b) { return width(a) > width(b) ? a : b }
        return a
    }

    private func largestImageSrc(_ img: DOMElement) -> String {
        let srcset = img.getAttribute("srcset") ?? ""
        if srcset.isEmpty { return img.getAttribute("src") ?? "" }
        var bestURL = ""
        var bestWidth = 0.0
        for (index, match) in JSRegex("(.+?)\\s+(\\d+(?:\\.\\d+)?)w", "g").allMatches(srcset).enumerated() {
            var candidate = (match[1] ?? "").trimmed
            if index > 0 { candidate = candidate.jsReplace("^,\\s*", "", "") }
            let width = jsParseFloat(match[2]) ?? 0
            if !candidate.isEmpty && width > bestWidth {
                bestWidth = width
                bestURL = candidate
            }
        }
        let result = bestURL.isEmpty ? (img.getAttribute("src") ?? "") : bestURL
        return result.jsReplace(",w_\\d+", "g", "").jsReplace(",c_\\w+", "g", "")
    }
}
