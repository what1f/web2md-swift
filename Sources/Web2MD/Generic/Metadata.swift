// Port of defuddle src/metadata.ts.
// Copyright (c) 2025 Steph Ango (@kepano), MIT License.

import Foundation

struct MetaTag {
    var name: String?
    var property: String?
    var content: String?
}

struct PageMetadata {
    var title = ""
    var description = ""
    var domain = ""
    var favicon = ""
    var image = ""
    var language = ""
    var published = ""
    var author = ""
    var site = ""
    var schemaOrgData: JSONValue = .null
}

enum MetadataExtractor {
    static func extract(_ doc: DOMDocument, schema: JSONValue, metaTags: [MetaTag], pageURL: String) -> PageMetadata {
        var domain = ""
        var url = [pageURL, doc.url].first { !$0.isEmpty && $0 != "about:blank" } ?? ""
        if url.isEmpty {
            url = firstNonEmpty([
                metaContent(metaTags, "property", "og:url"),
                metaContent(metaTags, "property", "twitter:url"),
                schemaProperty(schema, "url"),
                schemaProperty(schema, "mainEntityOfPage.url"),
                schemaProperty(schema, "mainEntity.url"),
                schemaProperty(schema, "WebSite.url"),
                doc.querySelector("link[rel=\"canonical\"]")?.getAttribute("href") ?? "",
            ])
        }
        if !url.isEmpty, let host = WebURL.hostname(url) {
            domain = host.jsReplace("^www\\.", "", "")
        }

        let siteName = siteName(schema, metaTags)
        let (title, detectedSiteName) = cleanTitle(bestTitle(doc, schema, metaTags, domain: domain, siteName: siteName), siteName: siteName)
        let author = author(doc, schema, metaTags)
        let authorAsSite = !author.isEmpty && !author.contains(",") ? author : ""
        let site = firstNonEmpty([siteName, detectedSiteName, authorAsSite, domain])

        var metadata = PageMetadata()
        metadata.title = title
        metadata.description = description(schema, metaTags)
        metadata.domain = domain
        metadata.favicon = favicon(doc, baseURL: url, metaTags)
        metadata.image = image(schema, metaTags)
        metadata.language = language(doc, schema, metaTags)
        metadata.published = published(doc, schema, metaTags, url: url)
        metadata.author = author
        metadata.site = site
        metadata.schemaOrgData = schema
        return metadata
    }

    private static func firstNonEmpty(_ values: [String]) -> String {
        values.first { !$0.isEmpty } ?? ""
    }

    static func isPlaceholderValue(_ s: String) -> Bool {
        if s.jsTest("[{}]") || s.jsTest("^#[a-zA-Z]") { return true }
        if !s.jsTest("[\\p{L}\\p{N}]") { return true }
        return false
    }

    private static func firstValid(_ thunks: [() -> String]) -> String {
        for thunk in thunks {
            let value = thunk()
            if !value.isEmpty && !isPlaceholderValue(value) { return value }
        }
        return ""
    }

    // MARK: Author

    private static func author(_ doc: DOMDocument, _ schema: JSONValue, _ metaTags: [MetaTag]) -> String {
        let authorsString = firstValid([
            { metaContent(metaTags, "name", "sailthru.author") },
            { metaContent(metaTags, "property", "article:author") },
            { metaContent(metaTags, "property", "author") },
            { metaContent(metaTags, "name", "author") },
            { metaContent(metaTags, "name", "byl") },
            { metaContent(metaTags, "name", "authorList") },
        ])
        if !authorsString.isEmpty {
            let cleaned = cleanAuthorString(authorsString)
            if !cleaned.isEmpty { return cleaned }
        }

        var strings = metaContents(metaTags, "name", "citation_author").filter { !isPlaceholderValue($0) }
        if strings.isEmpty {
            strings = metaContents(metaTags, "property", "dc.creator").filter { !isPlaceholderValue($0) }
        }
        if !strings.isEmpty {
            return strings.map { s in
                if !s.contains(",") { return s.trimmed }
                if let parts = s.jsMatch("(.*),\\s(.*)"), let first = parts[1], let second = parts[2] {
                    return "\(second) \(first)"
                }
                return s.trimmed
            }.joined(separator: ", ")
        }

        var schemaAuthors = schemaProperty(schema, "author.name")
        if schemaAuthors.isEmpty { schemaAuthors = schemaProperty(schema, "author.[].name") }
        if !schemaAuthors.isEmpty {
            let parts = schemaAuthors.components(separatedBy: ",")
                .map { $0.trimmed.jsReplace(",$", "", "").trimmed }
                .filter { !$0.isEmpty && !isPlaceholderValue($0) }
            if !parts.isEmpty {
                return Array(parts.uniqued().prefix(10)).joined(separator: ", ")
            }
        }

        let relAuthors = doc.querySelectorAll("a[rel~=\"author\"], address[rel~=\"author\"]")
        if !relAuthors.isEmpty && relAuthors.count <= 3 {
            var names: [String] = []
            for element in relAuthors {
                let text = visibleText(element)
                let lower = text.lowercased()
                if !text.isEmpty && text.jsLength < 100 && lower != "author" && lower != "authors" && !isPlaceholderValue(text) {
                    names.append(text)
                }
            }
            let unique = names.uniqued()
            if !unique.isEmpty { return unique.joined(separator: ", ") }
        }

        var collected: [String] = []
        func addDOMAuthor(_ value: String) {
            guard !value.isEmpty else { return }
            for part in value.components(separatedBy: ",") {
                let cleaned = part.jsReplace("\\s+", "g", " ").trimmed.jsReplace(",$", "", "").trimmed
                let lower = cleaned.lowercased()
                if !cleaned.isEmpty && lower != "author" && lower != "authors" && !isPlaceholderValue(cleaned) {
                    collected.append(cleaned)
                }
            }
        }
        let selectors: [(String, Int?)] = [
            ("[itemprop=\"author\"]", nil), (".author", 3), ("[href*=\"/author/\"]", 3), (".authors a", 3),
        ]
        for (selector, maxMatches) in selectors {
            let matches = doc.querySelectorAll(selector)
            if let maxMatches, matches.count > maxMatches { continue }
            for element in matches { addDOMAuthor(authorName(element)) }
        }
        if !collected.isEmpty {
            var unique = collected.map(\.trimmed).filter { !$0.isEmpty }.uniqued()
            if unique.count > 1 {
                let all = unique
                unique = all.filter { a in !all.contains { b in b != a && a.contains(b) } }
            }
            if !unique.isEmpty { return Array(unique.prefix(10)).joined(separator: ", ") }
        }

        if let h1 = doc.querySelector("h1") {
            var sibling = h1.nextElementSibling
            var i = 0
            while i < 3, let current = sibling {
                let siblingText = current.textContent.trimmed
                let childElements = current.querySelectorAll("p, time")
                let hasDateChild = childElements.contains { !parseDateText($0.textContent.trimmed).isEmpty }
                let hasSiblingDate = !parseDateText(siblingText).isEmpty || hasDateChild
                if hasSiblingDate {
                    let links = current.querySelectorAll("a")
                    if links.count == 1 {
                        let linkText = links[0].textContent.trimmed.replacingOccurrences(of: "\u{00A0}", with: " ")
                        if linkText.jsLength > 0 && linkText.jsLength < 100 && parseDateText(linkText).isEmpty {
                            return linkText
                        }
                    }
                    if hasDateChild && siblingText.jsLength < 300 {
                        for p in childElements where p.tagName == "P" {
                            let text = p.textContent.trimmed.replacingOccurrences(of: "\u{00A0}", with: " ")
                            if text.jsLength > 0 && text.jsLength < 150 && parseDateText(text).isEmpty {
                                return text
                            }
                        }
                    }
                }
                sibling = current.nextElementSibling
                i += 1
            }

            var scope: DOMElement? = h1
            var depth = 0
            while depth < 3, let currentScope = scope {
                var candidate = currentScope.previousElementSibling
                var j = 0
                while j < 3, let c = candidate {
                    if let byline = extractByline(c) { return byline }
                    candidate = c.previousElementSibling
                    j += 1
                }
                candidate = currentScope.nextElementSibling
                j = 0
                while j < 3, let c = candidate {
                    if let byline = extractByline(c) { return byline }
                    candidate = c.nextElementSibling
                    j += 1
                }
                scope = currentScope.parentElement
                depth += 1
            }
        }
        return ""
    }

    private static func extractByline(_ element: DOMElement) -> String? {
        for candidate in [element] + element.querySelectorAll("p, span, address") {
            let text = candidate.textContent.trimmed.replacingOccurrences(of: "\u{00A0}", with: " ")
            if text.jsLength > 0 && text.jsLength < 50, let match = text.jsMatch("^By\\s+([A-Z].+)$", "i"), let name = match[1] {
                return name.trimmed
            }
        }
        return nil
    }

    private static func cleanAuthorString(_ input: String) -> String {
        var s = input.jsReplace("^by\\s+", "i", "")
        s = s.jsReplace("\\(?\\s*https?://\\S+\\s*\\)?", "gi", "")
        s = s.jsReplace(",?\\s+and\\s+", "gi", ", ")
        s = s.jsReplace("\\s*[-–—|]\\s*$", "g", "")
        return s.trimmed
    }

    // MARK: Site and title

    private static func siteName(_ schema: JSONValue, _ metaTags: [MetaTag]) -> String {
        let candidate = firstValid([
            { schemaProperty(schema, "publisher.name") },
            { metaContent(metaTags, "property", "og:site_name") },
            { metaContent(metaTags, "name", "og:site_name") },
            { schemaProperty(schema, "WebSite.name") },
            { schemaProperty(schema, "sourceOrganization.name") },
            { metaContent(metaTags, "name", "copyright") },
            { schemaProperty(schema, "copyrightHolder.name") },
            { schemaProperty(schema, "isPartOf.name") },
            { metaContent(metaTags, "name", "application-name") },
        ])
        if !candidate.isEmpty && TextMetrics.countWords(candidate) > 6 { return "" }
        return candidate
    }

    private static func bestTitle(_ doc: DOMDocument, _ schema: JSONValue, _ metaTags: [MetaTag], domain: String, siteName: String) -> String {
        let candidates = [
            metaContent(metaTags, "property", "og:title"),
            metaContent(metaTags, "name", "twitter:title"),
            schemaProperty(schema, "headline"),
            metaContent(metaTags, "name", "title"),
            metaContent(metaTags, "name", "sailthru.title"),
            doc.querySelector("title")?.textContent.trimmed ?? "",
            doc.querySelector("h1")?.textContent.trimmed ?? "",
        ].filter { !$0.isEmpty && !isPlaceholderValue($0) }
        guard let first = candidates.first else { return "" }

        let authorMeta = firstNonEmpty([metaContent(metaTags, "property", "author"), metaContent(metaTags, "name", "author")])
        let authorNorm = authorMeta.trimmed.lowercased()
        let siteNorm = siteName.trimmed.lowercased()
        let domainNorm = domain.isEmpty ? "" : domain.jsReplace("\\.[^.]+$", "", "").lowercased().jsReplace("[^a-z0-9]", "g", "")
        return candidates.first { !isSiteIdentifier($0, authorNorm, siteNorm, domainNorm) } ?? first
    }

    private static func isSiteIdentifier(_ candidate: String, _ authorNorm: String, _ siteNorm: String, _ domainNorm: String) -> Bool {
        let norm = candidate.trimmed.lowercased()
        if !authorNorm.isEmpty && norm == authorNorm { return true }
        if !siteNorm.isEmpty && norm == siteNorm { return true }
        if !domainNorm.isEmpty && norm.jsReplace("[^a-z0-9]", "g", "") == domainNorm { return true }
        return false
    }

    static func cleanTitle(_ title: String, siteName: String) -> (String, String) {
        if title.isEmpty { return (title, "") }
        let separators = "[|\\-–—/·]"

        if !siteName.isEmpty && siteName.lowercased() != title.lowercased() && TextMetrics.countWords(siteName) <= 6 {
            let siteLower = siteName.lowercased()
            let escaped = siteName.jsReplace("[.*+?^${}()|\\[\\]\\\\]", "g", "\\$&")
            for pattern in ["\\s*\(separators)\\s*\(escaped)\\s*$", "^\\s*\(escaped)\\s*\(separators)\\s*"] {
                let regex = JSRegex(pattern, "i")
                if regex.test(title) { return (regex.replace(title, "").trimmed, siteName) }
            }

            let positions = JSRegex("\\s+\(separators)\\s+", "g").allMatches(title).map { ($0.index, $0.length) }
            if let last = positions.last {
                let lastSegment = title.jsSubstring(last.0 + last.1).trimmed.lowercased()
                if !lastSegment.isEmpty && siteLower.contains(lastSegment) {
                    var cut = last.0
                    var i = positions.count - 2
                    while i >= 0 {
                        let pos = positions[i]
                        let segment = title.jsSubstring(pos.0 + pos.1, cut).trimmed
                        if TextMetrics.countWords(segment) > 3 { break }
                        cut = pos.0
                        i -= 1
                    }
                    return (title.jsSubstring(0, cut).trimmed, siteName)
                }
                let first = positions[0]
                let prefixSegment = title.jsSubstring(0, first.0).trimmed.lowercased()
                if !prefixSegment.isEmpty && siteLower.contains(prefixSegment) {
                    var cut = first.0 + first.1
                    for i in 1..<max(1, positions.count) where i < positions.count {
                        let pos = positions[i]
                        let segment = title.jsSubstring(cut, pos.0).trimmed
                        if TextMetrics.countWords(segment) > 3 { break }
                        cut = pos.0 + pos.1
                    }
                    return (title.jsSubstring(cut).trimmed, siteName)
                }
            }
        }

        if let result = trySeparatorSplit(title, "\\s+([|/·])\\s+", suffixOnly: false, guard: { t, s in s <= 3 && t >= 2 && t >= s * 2 }) {
            return result
        }
        if let result = trySeparatorSplit(title, "\\s+[-–—]\\s+", suffixOnly: true, guard: { t, s in s <= 2 && t >= 2 && t > s }) {
            return result
        }
        return (title.trimmed, "")
    }

    private static func trySeparatorSplit(_ title: String, _ pattern: String, suffixOnly: Bool, guard check: (Int, Int) -> Bool) -> (String, String)? {
        let positions = JSRegex(pattern, "g").allMatches(title).map { ($0.index, $0.length) }
        guard let last = positions.last else { return nil }
        let suffixTitle = title.jsSubstring(0, last.0).trimmed
        let suffixSite = title.jsSubstring(last.0 + last.1).trimmed
        if check(TextMetrics.countWords(suffixTitle), TextMetrics.countWords(suffixSite)) {
            return (suffixTitle, suffixSite)
        }
        if !suffixOnly {
            let first = positions[0]
            let prefixSite = title.jsSubstring(0, first.0).trimmed
            let prefixTitle = title.jsSubstring(first.0 + first.1).trimmed
            if check(TextMetrics.countWords(prefixTitle), TextMetrics.countWords(prefixSite)) {
                return (prefixTitle, prefixSite)
            }
        }
        return nil
    }

    // MARK: Other fields

    private static func description(_ schema: JSONValue, _ metaTags: [MetaTag]) -> String {
        firstValid([
            { metaContent(metaTags, "name", "description") },
            { metaContent(metaTags, "property", "description") },
            { metaContent(metaTags, "property", "og:description") },
            { schemaProperty(schema, "description") },
            { metaContent(metaTags, "name", "twitter:description") },
            { metaContent(metaTags, "name", "sailthru.description") },
        ])
    }

    private static func image(_ schema: JSONValue, _ metaTags: [MetaTag]) -> String {
        firstNonEmpty([
            metaContent(metaTags, "property", "og:image"),
            metaContent(metaTags, "name", "twitter:image"),
            schemaProperty(schema, "image.url"),
            metaContent(metaTags, "name", "sailthru.image.full"),
        ])
    }

    private static func language(_ doc: DOMDocument, _ schema: JSONValue, _ metaTags: [MetaTag]) -> String {
        if let lang = doc.documentElement?.getAttribute("lang")?.trimmed, !lang.isEmpty { return lang.replacingOccurrences(of: "_", with: "-") }
        let content = firstNonEmpty([metaContent(metaTags, "name", "content-language"), metaContent(metaTags, "property", "og:locale")])
        if !content.isEmpty { return content.replacingOccurrences(of: "_", with: "-") }
        if let lang = doc.querySelector("meta[http-equiv=\"Content-Language\" i]")?.getAttribute("content")?.trimmed, !lang.isEmpty {
            return lang.replacingOccurrences(of: "_", with: "-")
        }
        let schemaLang = schemaProperty(schema, "inLanguage")
        return schemaLang.replacingOccurrences(of: "_", with: "-")
    }

    private static func favicon(_ doc: DOMDocument, baseURL: String, _ metaTags: [MetaTag]) -> String {
        let meta = metaContent(metaTags, "property", "og:image:favicon")
        if !meta.isEmpty { return meta }
        if let icon = doc.querySelector("link[rel='icon']")?.getAttribute("href"), !icon.isEmpty { return icon }
        if let icon = doc.querySelector("link[rel='shortcut icon']")?.getAttribute("href"), !icon.isEmpty { return icon }
        if baseURL.jsTest("^https?://"), let resolved = WebURL.resolve("/favicon.ico", base: baseURL) { return resolved }
        return ""
    }

    private static func published(_ doc: DOMDocument, _ schema: JSONValue, _ metaTags: [MetaTag], url: String) -> String {
        let result = firstValid([
            { schemaProperty(schema, "datePublished") },
            { metaContent(metaTags, "name", "publishDate") },
            { metaContent(metaTags, "property", "article:published_time") },
            { doc.querySelector("abbr[itemprop=\"datePublished\"]")?.getAttribute("title")?.trimmed ?? "" },
            { timeElement(doc, url: url) },
            { metaContent(metaTags, "name", "sailthru.date") },
        ])
        if !result.isEmpty { return result }

        if let h1 = doc.querySelector("h1") {
            func scan(_ start: DOMElement?, forward: Bool, childrenOnly: Bool) -> String {
                var sibling = start
                var i = 0
                while i < 3, let current = sibling {
                    for child in current.querySelectorAll("p, time") {
                        let parsed = parseDateText(child.textContent.trimmed)
                        if !parsed.isEmpty { return parsed }
                    }
                    if !childrenOnly {
                        let parsed = parseDateText(current.textContent.trimmed)
                        if !parsed.isEmpty { return parsed }
                    }
                    sibling = forward ? current.nextElementSibling : current.previousElementSibling
                    i += 1
                }
                return ""
            }
            let found = firstValid([
                { scan(h1.nextElementSibling, forward: true, childrenOnly: false) },
                { scan(h1.previousElementSibling, forward: false, childrenOnly: true) },
            ])
            if !found.isEmpty { return found }
        }
        return ""
    }

    static func metaContent(_ metaTags: [MetaTag], _ attr: String, _ value: String) -> String {
        metaContents(metaTags, attr, value).first ?? ""
    }

    static func metaContents(_ metaTags: [MetaTag], _ attr: String, _ value: String) -> [String] {
        let lower = value.lowercased()
        return metaTags.filter { tag in
            let attributeValue = attr == "name" ? tag.name : tag.property
            return attributeValue?.lowercased() == lower
        }.map { $0.content?.trimmed ?? "" }
    }

    private static func timeElement(_ doc: DOMDocument, url: String) -> String {
        for element in doc.querySelectorAll("time") {
            if isLinkedToOtherPage(element, pageURL: url) { continue }
            let datetime = element.getAttribute("datetime")?.trimmed ?? ""
            let content = datetime.isEmpty ? element.textContent.trimmed : datetime
            if !content.isEmpty { return content }
        }
        return ""
    }

    private static func isLinkedToOtherPage(_ element: DOMElement, pageURL: String) -> Bool {
        guard !pageURL.isEmpty, let anchor = element.closest("a[href]") else { return false }
        let href = anchor.getAttribute("href")?.trimmed ?? ""
        if href.isEmpty || href.hasPrefix("#") { return false }
        guard let target = WebURL.parse(href, base: pageURL), let current = WebURL.parse(pageURL, base: nil) else { return false }
        if target.origin != current.origin { return false }
        return target.pathname.jsReplace("/+$", "", "") != current.pathname.jsReplace("/+$", "", "")
    }

    private static let months = [
        "january": "01", "february": "02", "march": "03", "april": "04", "may": "05", "june": "06",
        "july": "07", "august": "08", "september": "09", "october": "10", "november": "11", "december": "12",
    ]
    private static let monthNames = "January|February|March|April|May|June|July|August|September|October|November|December"

    static func parseDateText(_ text: String) -> String {
        if let match = text.jsMatch("\\b(\\d{1,2})\\s+(\(monthNames))\\s+(\\d{4})\\b", "i"),
           let day = match[1], let month = match[2], let year = match[3] {
            return "\(year)-\(months[month.lowercased()] ?? "01")-\(day.count < 2 ? "0" + day : day)T00:00:00+00:00"
        }
        if let match = text.jsMatch("\\b(\(monthNames))\\s+(\\d{1,2}),?\\s+(\\d{4})\\b", "i"),
           let month = match[1], let day = match[2], let year = match[3] {
            return "\(year)-\(months[month.lowercased()] ?? "01")-\(day.count < 2 ? "0" + day : day)T00:00:00+00:00"
        }
        return ""
    }

    private static func visibleText(_ element: DOMElement) -> String {
        let clone = element.clone()
        for node in clone.querySelectorAll("script, style, noscript") { node.remove() }
        return clone.textContent.jsReplace("\\s+", "g", " ").trimmed
    }

    private static func authorName(_ element: DOMElement) -> String {
        let clone = element.clone()
        for node in clone.querySelectorAll("script, style, noscript") { node.remove() }
        let text = clone.textContent.jsReplace("\\s+", "g", " ").trimmed
        if text.isEmpty { return "" }
        for child in clone.querySelectorAll("span, a, p") {
            let childText = child.textContent.jsReplace("\\s+", "g", " ").trimmed
            if childText.jsLength >= 2 && childText.jsLength <= 50 && childText != text { return childText }
        }
        return text.jsLength <= 100 ? text : ""
    }

    // MARK: Schema.org

    static func schemaProperty(_ schema: JSONValue, _ property: String, default defaultValue: String = "") -> String {
        if !schema.truthy { return defaultValue }
        let props = property.components(separatedBy: ".")

        func search(_ data: JSONValue, _ props: ArraySlice<String>, exact: Bool) -> [String] {
            if case .string(let value) = data { return props.isEmpty ? [value] : [] }
            switch data {
            case .array(let items):
                if let current = props.first, current.jsTest("^\\[\\d+\\]$") {
                    let index = Int(current.dropFirst().dropLast()) ?? -1
                    if index >= 0, index < items.count, items[index].truthy {
                        return search(items[index], props.dropFirst(), exact: exact)
                    }
                    return []
                }
                if props.isEmpty && items.allSatisfy({ if case .string = $0 { return true }; if case .number = $0 { return true }; return false }) {
                    return items.compactMap(\.string)
                }
                return items.flatMap { search($0, props, exact: exact) }
            case .object(let dict, _):
                guard let current = props.first else {
                    if let name = dict["name"], name.truthy { return name.string.map { [$0] } ?? [] }
                    return []
                }
                if let value = dict[current] {
                    return search(value, props.dropFirst(), exact: true)
                }
                if !exact {
                    var nested: [String] = []
                    for (_, value) in data.orderedEntries where value.isObject || value.isArray || value.isNull {
                        nested.append(contentsOf: search(value, props, exact: false))
                    }
                    if !nested.isEmpty { return nested }
                }
                return []
            default:
                return []
            }
        }

        var results = search(schema, props[...], exact: true)
        if results.isEmpty { results = search(schema, props[...], exact: false) }
        let unique = results.filter { !$0.isEmpty }.uniqued()
        return unique.isEmpty ? defaultValue : unique.joined(separator: ", ")
    }
}

extension Array where Element: Hashable {
    /// Removes duplicates, keeping first occurrences (like `[...new Set(array)]`).
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
