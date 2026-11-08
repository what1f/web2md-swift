// Port of defuddle src/removals/content-patterns.ts and src/content-boundary.ts.
// Copyright (c) 2025 Steph Ango (@kepano), MIT License.

import Foundation

enum ContentBoundary {
    private static let datePattern = JSRegex(
        "(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\\s+\\d{1,2}|\\d{1,2}(?:st|nd|rd|th)?\\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*|\\d{4}[-/]\\d{1,2}[-/]\\d{1,2})",
        "i")
    private static let candidateTags: Set<String> = ["P", "DIV", "SECTION", "ARTICLE", "BLOCKQUOTE", "FONT"]
    private static let leafCandidateTags: Set<String> = ["P", "BLOCKQUOTE", "FONT"]
    private static let dialogSelector = "[role=\"dialog\"], [role=\"alertdialog\"]"
    private static let skipAncestorSelector = "aside, nav, header, footer, form, " + dialogSelector

    private static func findTitleElement(_ mainContent: DOMElement, _ title: String) -> DOMElement? {
        let normalized = Utils.normalizeText(title)
        guard !normalized.isEmpty else { return nil }
        return mainContent.querySelectorAll("h1, h2").first { Utils.normalizeText($0.textContent) == normalized }
    }

    private static func linkTextLength(_ element: DOMElement) -> Int {
        element.querySelectorAll("a").reduce(0) { $0 + $1.textContent.jsLength }
    }

    static func isProseBlock(_ element: DOMElement) -> Bool {
        guard candidateTags.contains(element.tagName) else { return false }
        if element.closest(skipAncestorSelector) != nil { return false }
        if element.className.jsTest("\\b(?:isHidden(?:-[A-Za-z0-9_]+)?|is-hidden)\\b") { return false }
        if element.querySelector(dialogSelector) != nil { return false }
        if element.querySelector("script, style") != nil { return false }
        let text = element.textContent.trimmed
        if text.isEmpty { return false }
        let words = Utils.countWords(text)
        if words < 7 { return false }
        if !text.jsTest("[.!?]") { return false }
        if text.jsTest("^by\\s+\\S", "i") && words < 15 { return false }
        if datePattern.test(text) && words < 20 { return false }
        if Double(linkTextLength(element)) > Double(text.jsLength) * 0.7 { return false }
        if element.tagName == "DIV" && element.querySelector("p") == nil { return false }
        return true
    }

    static func findContentStart(_ mainContent: DOMElement, title: String) -> DOMElement? {
        let start = findTitleElement(mainContent, title)
        var leafHit: DOMElement?
        var containerHit: DOMElement?
        var node: DOMNode? = (start ?? mainContent).nextInTree(within: mainContent)
        while let current = node {
            if let element = current as? DOMElement, isProseBlock(element) {
                if leafCandidateTags.contains(element.tagName) {
                    leafHit = element
                    break
                }
                if containerHit == nil { containerHit = element }
            }
            node = current.nextInTree(within: mainContent)
        }
        if let leafHit { return leafHit }
        if var result = containerHit {
            while true {
                let qualifying = result.children.filter(isProseBlock)
                if qualifying.count == 1 { result = qualifying[0] } else { break }
            }
            return result
        }
        if start != nil { return findContentStart(mainContent, title: "") }
        return nil
    }

    static func isAboveContentStart(_ element: DOMElement, _ boundary: DOMElement?) -> Bool {
        guard let boundary else { return false }
        return Utils.isNodeBefore(element, boundary)
    }
}

enum ContentPatterns {
    private static let contentDatePattern = JSRegex(
        "(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\\s+\\d{1,2}|\\d{1,2}(?:st|nd|rd|th)?\\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*|\\d{4}[-/]\\d{1,2}[-/]\\d{1,2})",
        "i")
    private static let relativeTimePattern = JSRegex("\\b\\d+\\s+(?:second|minute|hour|day|week|month|year)s?\\s+ago\\b", "i")
    private static let readTimePattern = JSRegex(
        "\\d+\\s*min(?:ute)?s?\\s+read\\b|(?:read(?:ing)?\\s+time)\\s*:?\\s*\\d+\\s*min(?:ute)?s?\\b", "i")
    private static let bylineUppercasePattern = JSRegex("^\\p{Lu}", "u")
    private static let startsWithByPattern = JSRegex("^(?:posted\\s+)?by\\s+\\S", "i")
    private static let metadataLabelPattern = JSRegex("^(?:date|published|updated|posted|from|to|subject)\\s*:", "i")
    private static let boilerplatePatterns = [
        JSRegex("^This (?:article|story|piece) (?:appeared|was published|originally appeared) in\\b", "i"),
        JSRegex("^A version of this (?:article|story) (?:appeared|was published) in\\b", "i"),
        JSRegex("^Originally (?:published|appeared) (?:in|on|at)\\b", "i"),
        JSRegex("^Any re-?use permitted\\b", "i"),
        JSRegex("^©\\s*(?:Copyright\\s+)?\\d{4}", "i"),
        JSRegex("^Comments?$", "i"),
        JSRegex("^Leave a (?:comment|reply)$", "i"),
        JSRegex("^Loading\\.{3}$"),
        JSRegex("^Affiliate links\\b.*\\b(?:earn|commission)", "i"),
        JSRegex("\\bRead our Comment Policy\\b", "i"),
        JSRegex("^Thank you for (?:being part of|joining) our community\\b", "i"),
    ]
    private static let newsletterPattern = JSRegex(
        "\\bsubscribe\\b[\\s\\S]{0,40}\\bnewsletter\\b|\\bnewsletter\\b[\\s\\S]{0,40}\\bsubscribe\\b|\\bsign[- ]up\\b[\\s\\S]{0,80}\\b(?:newsletter|email alert)|\\b(?:don[\\u2019']?t (?:want to )?miss|never miss)\\b[\\s\\S]{0,80}\\b(?:latest|best|exclusive|reports?|updates?|source)",
        "i")
    private static let socialCounterPattern = JSRegex(
        "^\\d+\\s+(?:Likes?|Comments?|Shares?|Retweets?|Reposts?|Restacks?)$", "i")
    private static let timezoneWidgetPattern = JSRegex("^current time in$", "i")
    private static let pinnedLabelPattern = JSRegex("^pinned$", "i")
    private static let authorContactLabelPattern = JSRegex(
        "^(?:written by|(?:author|contact|reporter|correspondent)s?)$", "i")
    private static let shareAuthorLabel = JSRegex("^(?:share|follow|authors?|written\\s+by)$", "i")
    private static let contentElementNoImgSelector = Constants.contentElementSelector.jsReplace("img, picture, ", "", "")
    private static let emailPattern = JSRegex("[\\w.-]+@[\\w.-]+\\.\\w+")
    private static let phonePattern = JSRegex("\\(?\\d{3}\\)?[\\s.‑–-]?\\d{3}[\\s.‑–-]?\\d{4}")
    private static let headingSelector = "h1, h2, h3, h4, h5, h6"
    private static let relatedHeadingPattern = JSRegex(
        "^(?:related (?:posts?|articles?|content|stories|reads?|reading)|you (?:might|may|could) (?:also )?(?:like|enjoy|be interested in)|read (?:next|more|also)|further reading|see also|more (?:from .*|from|articles?|posts?|like this)|more to (?:read|explore)|explore more|about (?:the )?author|latest (?:news|events?|posts?|articles?|stories)(?:\\s*[&+]\\s*(?:news|events?|posts?|articles?|stories))?)$",
        "i")
    private static let ctaHeadingPattern = JSRegex(
        "^(?:subscribe|sign up|follow us|share this|stay (?:updated|connected)|join (?:us|our)|search (?:the |our )?(?:site|blog|archives?|newsroom|website|catalog|store|shop|database))$",
        "i")
    private static let relatedIntroPattern = JSRegex("^for more (?:on|about)\\b", "i")

    private static let metadataStripBase = [
        JSRegex("\\b(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\\b", "gi"),
        JSRegex("\\b(?:Mon(?:day)?|Tue(?:s(?:day)?)?|Wed(?:nesday)?|Thu(?:rs(?:day)?)?|Fri(?:day)?|Sat(?:urday)?|Sun(?:day)?)\\b", "gi"),
        JSRegex("\\b\\d+(?:st|nd|rd|th)?\\b", "g"),
        JSRegex("\\d{4}[-/]\\d{1,2}[-/]\\d{1,2}", "g"),
    ]
    private static let readTimeStripPatterns = metadataStripBase + [
        JSRegex("\\bmin(?:ute)?s?\\b", "gi"),
        JSRegex("\\bread(?:ing)?\\b", "gi"),
        JSRegex("\\btime\\b", "gi"),
        JSRegex("\\bestimated\\b", "gi"),
        JSRegex("[/|·•—–\\-,:.\\s]+", "g"),
    ]
    private static let bylineStripPatterns = metadataStripBase + [
        JSRegex("\\bby\\b", "gi"),
        JSRegex("[/|·•—–\\-,]+", "g"),
    ]

    private static func strip(_ text: String, _ patterns: [JSRegex]) -> String {
        patterns.reduce(text) { $1.replace($0, "") }
    }

    private static func isOrContainsHeading(_ element: DOMElement) -> Bool {
        element.tagName.jsTest("^H[1-6]$") || element.querySelector(headingSelector) != nil
    }

    private static func isNewsletterElement(_ element: DOMElement, maxWords: Int) -> Bool {
        let text = element.textContent.trimmed
        let words = Utils.countWords(text)
        if words < 2 || words > maxWords { return false }
        if element.querySelector(Constants.contentElementSelector) != nil { return false }
        let normalized = text.jsReplace("([a-z])([A-Z])", "g", "$1 $2").jsReplace("[\\u2018\\u2019]", "g", "'")
        return newsletterPattern.test(normalized)
    }

    private static func hasFollowingProse(_ element: DOMElement, minWords: Int = 25) -> Bool {
        var sibling = element.nextElementSibling
        while let current = sibling {
            if current.tagName == "P" && Utils.countWords(current.textContent) >= minWords { return true }
            if current.querySelectorAll("p").contains(where: { Utils.countWords($0.textContent) >= minWords }) { return true }
            sibling = current.nextElementSibling
        }
        return false
    }

    private static func precedingProseWords(_ element: DOMElement, _ mainContent: DOMElement) -> Int {
        var words = 0
        var node: DOMElement? = element
        while let current = node, current !== mainContent {
            var sibling = current.previousElementSibling
            while let s = sibling {
                if s.tagName == "P" {
                    words += Utils.countWords(s.textContent)
                } else {
                    for p in s.querySelectorAll("p") { words += Utils.countWords(p.textContent) }
                }
                sibling = s.previousElementSibling
            }
            node = current.parentElement
        }
        return words
    }

    private static func walkUpToWrapper(_ element: DOMElement, _ text: String, _ mainContent: DOMElement) -> DOMElement {
        var target = element
        while let parent = target.parentElement, parent !== mainContent {
            if parent.textContent.trimmed != text { break }
            target = parent
        }
        return target
    }

    private static func isLabeledMetadata(_ element: DOMElement, _ mainContent: DOMElement) -> Bool {
        var current: DOMElement? = element
        while let node = current, node !== mainContent {
            let text = node.textContent.trimmed
            if Utils.countWords(text) > 15 { break }
            if metadataLabelPattern.test(text) { return true }
            current = node.parentElement
        }
        return false
    }

    private static func removeTrailingSiblings(_ element: DOMElement, removeSelf: Bool) {
        var sibling = element.nextElementSibling
        while let current = sibling {
            let next = current.nextElementSibling
            if current.id != "footnotes" { current.remove() }
            sibling = next
        }
        if removeSelf { element.remove() }
    }

    private static func removeTrailingWithCascade(_ target: DOMElement, _ mainContent: DOMElement) {
        var ancestors: [DOMElement] = []
        var ancestor = target.parentElement
        while let a = ancestor, a !== mainContent {
            ancestors.append(a)
            ancestor = a.parentElement
        }
        removeTrailingSiblings(target, removeSelf: true)
        for a in ancestors { removeTrailingSiblings(a, removeSelf: false) }
    }

    private static func walkUpIsolated(_ element: DOMElement, _ mainContent: DOMElement) -> DOMElement {
        var target = element
        while let parent = target.parentElement, parent !== mainContent {
            var precedingWords = 0
            var sibling = target.previousElementSibling
            while let s = sibling {
                precedingWords += Utils.countWords(s.textContent)
                if precedingWords > 10 { break }
                sibling = s.previousElementSibling
            }
            if precedingWords > 10 { break }
            target = parent
        }
        return target
    }

    private static func removeThinPrecedingSection(_ target: DOMElement) {
        guard let previous = target.previousElementSibling else { return }
        if Utils.countWords(previous.textContent) >= 50 { return }
        if previous.querySelector(Constants.contentElementSelector) != nil { return }
        if let beforePrevious = previous.previousElementSibling, isOrContainsHeading(beforePrevious) { return }
        previous.remove()
    }

    private static func removeHeroHeader(_ mainContent: DOMElement, _ contentStart: DOMElement?) {
        let times = mainContent.querySelectorAll("time")
        for time in times {
            if !ContentBoundary.isAboveContentStart(time, contentStart) { continue }
            var best: DOMElement?
            var current = time.parentElement
            while let node = current, node !== mainContent {
                if node.querySelector("h1, h2") != nil && node.querySelector("time") != nil {
                    let totalWords = Utils.countWords(node.textContent.trimmed)
                    var metadataElements: [DOMElement] = []
                    for element in node.querySelectorAll("h1, h2, h3, time, [aria-label]")
                    where !metadataElements.contains(where: { $0.contains(element) }) {
                        metadataElements.append(element)
                    }
                    let metadataWords = metadataElements.reduce(0) { $0 + Utils.countWords($1.textContent) }
                    if totalWords - metadataWords < 30 { best = node } else { break }
                }
                current = node.parentElement
            }
            if let best {
                best.remove()
                return
            }
        }
    }

    private static func isBreadcrumbList(_ list: DOMElement) -> Bool {
        let items = list.querySelectorAll("li")
        if items.count < 2 || items.count > 8 { return false }
        let links = list.querySelectorAll("a")
        if links.isEmpty || links.count >= items.count { return false }
        if list.querySelector("img, p, figure, blockquote") != nil { return false }
        for item in items where Utils.countWords(item.textContent) > 8 { return false }
        var allInternal = true
        var hasBreadcrumbLink = false
        var shortLinkTexts = true
        for link in links {
            let href = link.getAttribute("href") ?? ""
            if href.hasPrefix("http") || href.hasPrefix("//") {
                allInternal = false
                break
            }
            if href == "/" || href.jsTest("^\\/[a-zA-Z0-9_-]+\\/?$") { hasBreadcrumbLink = true }
            if link.textContent.trimmed.jsSplit("\\s+").filter({ !$0.isEmpty }).count > 5 { shortLinkTexts = false }
        }
        return allInternal && hasBreadcrumbLink && shortLinkTexts
    }

    static func removeEyebrowLabel(_ mainContent: DOMElement) {
        guard let firstHeading = mainContent.querySelector("h1") ?? mainContent.querySelector("h2") else { return }
        var current = firstHeading
        while let parent = current.parentElement, parent !== mainContent, current.previousElementSibling == nil {
            current = parent
        }
        guard let previous = current.previousElementSibling else { return }
        let text = previous.textContent.trimmed
        let words = Utils.countWords(text)
        if words < 1 || words > 6 { return }
        if text.jsLength > 40 { return }
        if text.jsTest("[.!?]") { return }
        if contentDatePattern.test(text) { return }
        if previous.querySelector(
            "img, picture, video, iframe, figure, table, pre, code, time, [datetime], h1, h2, h3, h4, h5, h6, ul, ol, blockquote"
        ) != nil {
            return
        }
        previous.remove()
    }

    private static func linkTextLength(_ links: [DOMElement]) -> Int {
        links.reduce(0) { $0 + $1.textContent.trimmed.jsLength }
    }

    static func remove(_ mainContent: DOMElement, url: String, title: String, description: String) {
        let contentStart = ContentBoundary.findContentStart(mainContent, title: title)
        func isPreContent(_ element: DOMElement) -> Bool { ContentBoundary.isAboveContentStart(element, contentStart) }
        let normalizedTitle = Utils.normalizeText(title)
        let normalizedDescription = Utils.normalizeText(description)

        if let firstList = mainContent.querySelector("ul, ol"), isBreadcrumbList(firstList) {
            var target = firstList
            while let parent = target.parentElement, parent !== mainContent, parent.children.count == 1 { target = parent }
            target.remove()
        }

        if let firstH1 = mainContent.querySelector("h1") {
            for link in mainContent.querySelectorAll("a[href]") where link.parentNode != nil {
                if !Utils.isNodeBefore(link, firstH1) { continue }
                if link.querySelector("div") == nil { continue }
                if link.querySelector("img, picture, video") != nil { continue }
                let text = link.textContent.trimmed
                if Utils.countWords(text) > 25 { continue }
                if text.jsTest("[.!?]\\s") { continue }
                link.remove()
            }
        }

        removeHeroHeader(mainContent, contentStart)

        for media in mainContent.querySelectorAll("audio, video") where media.parentNode != nil {
            if media.getAttribute("src") == nil && media.querySelector("source") == nil { continue }
            var container = media
            while let parent = container.parentElement, parent !== mainContent {
                if Utils.countWords(parent.textContent.trimmed) > 25 { break }
                container = parent
            }
            let containerText = container.textContent.trimmed
            let isListenWidget = containerText.jsTest(
                "\\blisten\\s+to\\s+(?:this\\s+)?(?:article|story|post|episode|podcast)\\b", "i")
            let isPreContentPlayer = !isListenWidget && isPreContent(container) && Utils.countWords(containerText) <= 25
            if isListenWidget || isPreContentPlayer { container.remove() }
        }

        let contentText = mainContent.textContent
        let contentLength = contentText.jsLength
        let pageURL = WebURL.parse(url, base: nil)

        // Table of contents near the top.
        for list in mainContent.querySelectorAll("ul, ol") where list.parentNode != nil {
            if list.closest("#footnotes") != nil { continue }
            let listText = list.textContent.trimmed
            let listPosition = contentText.jsIndexOf(listText.jsSubstring(0, 60))
            if listPosition < 0 || Double(listPosition) > Double(contentLength) * 0.3 { continue }
            let links = list.querySelectorAll("a[href]")
            if links.count < 3 { continue }
            if list.querySelector(Constants.contentElementSelector) != nil { continue }
            var anchors = 0
            for link in links {
                let href = link.getAttribute("href") ?? ""
                if href.hasPrefix("#") {
                    anchors += 1
                } else if let pageURL, href.contains("#"), let resolved = WebURL.parse(href, base: url),
                          resolved.pathname == pageURL.pathname, resolved.hostname == pageURL.hostname {
                    anchors += 1
                }
            }
            if anchors < 3 || Double(anchors) / Double(links.count) < 0.8 { continue }
            var target = list
            while let parent = target.parentElement, parent !== mainContent, parent.children.count == 1 { target = parent }
            if let previous = target.previousElementSibling, previous.tagName.jsTest("^H[1-6]$"),
               previous.textContent.trimmed.jsTest("^(?:table of )?contents$|^on this page$|^in this (?:article|guide|post)$", "i") {
                previous.remove()
            }
            let previous = target.previousElementSibling
            let next = target.nextElementSibling
            target.remove()
            if previous?.tagName == "HR" { previous?.remove() }
            if next?.tagName == "HR" { next?.remove() }
            break
        }

        var bylineFound = false
        var authorDateFound = false
        for element in mainContent.querySelectorAll("p, span, div, time") where element.parentNode != nil {
            let text = element.textContent.trimmed
            let words = Utils.countWords(text)
            if words > 15 || words == 0 { continue }
            if element.closest("pre, code") != nil { continue }
            let tag = element.tagName
            let hasDate = contentDatePattern.test(text)
            if hasDate && isLabeledMetadata(element, mainContent) { continue }

            if timezoneWidgetPattern.test(text) && contentText.jsIndexOf(text) <= 300 {
                var target = element
                if let parent = target.parentElement, parent !== mainContent { target = parent }
                target.remove()
                continue
            }

            if words == 1 && pinnedLabelPattern.test(text) {
                element.remove()
                continue
            }

            for normalized in [normalizedTitle, normalizedDescription]
            where !normalized.isEmpty && words >= 3 && isPreContent(element) && Utils.normalizeText(text) == normalized {
                element.remove()
                break
            }
            if element.parentNode == nil { continue }

            if (tag == "DIV" || tag == "P") && words >= 1 && words <= 10
                && (hasDate || relativeTimePattern.test(text)) && !metadataLabelPattern.test(text)
                && !text.jsTest("[.!?]") && isPreContent(element) {
                if !element.querySelectorAll("p, h1, h2, h3, h4, h5, h6").contains(where: { Utils.countWords($0.textContent) > 8 }) {
                    element.remove()
                    continue
                }
            }

            if tag == "DIV" && words >= 1 && words <= 5 && !text.jsTest("[.!?]") && isPreContent(element)
                && element.querySelector("img") != nil {
                let links = element.querySelectorAll("a[href]")
                if !links.isEmpty
                    && Double(linkTextLength(links)) / Double(text.jsLength == 0 ? 1 : text.jsLength) >= 0.8 {
                    element.remove()
                    continue
                }
            }

            if !bylineFound && startsWithByPattern.test(text) && words >= 2 && !text.jsTest("[.!?]$") && isPreContent(element) {
                walkUpToWrapper(element, text, mainContent).remove()
                bylineFound = true
                continue
            }

            if readTimePattern.test(text)
                && (hasDate ? element.querySelectorAll("p, div, section, article").isEmpty : words <= 5 && isPreContent(element)) {
                if strip(text, readTimeStripPatterns).trimmed.isEmpty {
                    (hasDate ? element : walkUpToWrapper(element, text, mainContent)).remove()
                    continue
                }
            }

            if !authorDateFound && words >= 2 && words <= 10 && hasDate && !metadataLabelPattern.test(text) && isPreContent(element) {
                let residual = strip(text, bylineStripPatterns).trimmed
                if !residual.isEmpty {
                    let nameWords = residual.jsSplit("\\s+").filter { !$0.isEmpty }
                    if nameWords.count >= 1 && nameWords.count <= 4 && nameWords.allSatisfy({ bylineUppercasePattern.test($0) }) {
                        walkUpToWrapper(element, text, mainContent).remove()
                        authorDateFound = true
                        continue
                    }
                }
            }

            if hasDate && words <= 5 && isPreContent(element) {
                let residual = strip(text, metadataStripBase).jsReplace("[,\\s/\\-]+", "g", "").trimmed
                if residual.isEmpty {
                    walkUpToWrapper(element, text, mainContent).remove()
                    continue
                }
            }
        }

        // Standalone <time> at the boundaries.
        for time in mainContent.querySelectorAll("time") where time.parentNode != nil {
            var target = time
            var targetText = target.textContent.trimmed
            while let parent = target.parentElement, parent !== mainContent {
                let parentTag = parent.localName
                let parentText = parent.textContent.trimmed
                if parentTag == "p" && parentText == targetText {
                    target = parent
                    break
                }
                if ["i", "em", "span", "b", "strong", "small"].contains(parentTag) && parentText == targetText {
                    target = parent
                    targetText = parentText
                    continue
                }
                break
            }
            let text = target.textContent.trimmed
            if Utils.countWords(text) > 10 { continue }
            let position = contentText.jsIndexOf(text)
            let distanceFromEnd = contentLength - (position + text.jsLength)
            if position > 200 && distanceFromEnd > 200 { continue }
            target.remove()
        }

        // Metadata lists at the boundaries.
        for list in mainContent.querySelectorAll("ul, ol, dl") where list.parentNode != nil {
            if list.closest("#footnotes") != nil { continue }
            let isDL = list.tagName == "DL"
            let items = list.children.filter { isDL ? $0.tagName == "DD" : $0.tagName == "LI" }
            if items.count < (isDL ? 1 : 2) || items.count > 8 { continue }
            let listText = list.textContent.trimmed
            let position = contentText.jsIndexOf(listText)
            let distanceFromEnd = contentLength - (position + listText.jsLength)
            if position > 500 && distanceFromEnd > 500 { continue }
            if let previous = list.previousElementSibling {
                if isOrContainsHeading(previous) { continue }
                if previous.textContent.trimmed.hasSuffix(":") { continue }
            }
            let isMetadata = items.allSatisfy { item in
                let text = item.textContent.trimmed
                return Utils.countWords(text) <= 8 && !text.jsTest("[.!?]$")
            }
            if !isMetadata { continue }
            if Utils.countWords(listText) > 30 { continue }
            walkUpToWrapper(list, listText, mainContent).remove()
        }

        // Section breadcrumbs and back links.
        let urlPath = pageURL?.pathname ?? ""
        let pageHost = pageURL?.hostname.jsReplace("^www\\.", "", "") ?? ""
        if !urlPath.isEmpty {
            let firstHeading = mainContent.querySelector("h1, h2, h3")
            for element in mainContent.querySelectorAll("div, span, p, a[href]") where element.parentNode != nil {
                let text = element.textContent.trimmed
                if Utils.countWords(text) > 10 { continue }
                if !element.querySelectorAll("p, div, section, article").isEmpty { continue }
                if element.matches("a[href]"), let parent = element.parentElement, parent !== mainContent {
                    if parent.textContent.trimmed != text {
                        if element.closest("p") != nil { continue }
                        guard let firstHeading else { continue }
                        if !Utils.isNodeBefore(element, firstHeading) { continue }
                    }
                }
                guard let link = element.matches("a[href]") ? element : element.querySelector("a[href]") else { continue }
                guard let linkPath = WebURL.parse(link.getAttribute("href") ?? "", base: url)?.pathname else { continue }
                let linkDirectory = linkPath.jsReplace("\\/[^/]*$", "", "/")
                let lastSegment = linkPath.components(separatedBy: "/").last ?? ""
                let isParentIndex = lastSegment.jsTest("^index\\.(html?|php)$", "i") && urlPath.hasPrefix(linkDirectory)
                if linkPath != "/" && linkPath != urlPath && (urlPath.hasPrefix(linkPath) || isParentIndex) {
                    element.remove()
                }
            }
        }

        // Trailing external link lists.
        if !pageHost.isEmpty {
            for heading in mainContent.querySelectorAll("h2, h3, h4, h5, h6") where heading.parentNode != nil {
                guard let list = heading.nextElementSibling, list.tagName == "UL" || list.tagName == "OL" else { continue }
                let items = list.children.filter { $0.tagName == "LI" }
                if items.count < 2 { continue }
                var trailingContent = false
                var check: DOMElement? = list
                while let node = check, node !== mainContent {
                    var sibling = node.nextElementSibling
                    while let s = sibling {
                        if !s.textContent.trimmed.isEmpty {
                            trailingContent = true
                            break
                        }
                        sibling = s.nextElementSibling
                    }
                    if trailingContent { break }
                    check = node.parentElement
                }
                if trailingContent { continue }
                var allExternal = true
                for item in items {
                    let links = item.querySelectorAll("a[href]")
                    if links.isEmpty {
                        allExternal = false
                        break
                    }
                    let itemText = item.textContent.trimmed
                    var linkLength = 0
                    for link in links {
                        linkLength += link.textContent.trimmed.jsLength
                        if let host = WebURL.parse(link.getAttribute("href") ?? "", base: url)?.hostname.jsReplace("^www\\.", "", ""),
                           host == pageHost {
                            allExternal = false
                            break
                        }
                    }
                    if !allExternal { break }
                    if Double(linkLength) < Double(itemText.jsLength) * 0.6 {
                        allExternal = false
                        break
                    }
                }
                if !allExternal { continue }
                list.remove()
                heading.remove()
            }
        }

        // Trailing related-posts block of link-dense paragraphs.
        var lastChild = mainContent.lastElementChild
        while let child = lastChild, ["HR", "BR"].contains(child.tagName) { lastChild = child.previousElementSibling }
        if let last = lastChild, ["SECTION", "DIV", "ASIDE"].contains(last.tagName) {
            var paragraphs: [DOMElement] = []
            var hasNonParagraph = false
            for child in last.children {
                if child.textContent.trimmed.isEmpty { continue }
                if child.tagName == "P" {
                    paragraphs.append(child)
                } else if child.tagName != "BR" {
                    hasNonParagraph = true
                    break
                }
            }
            if paragraphs.count >= 2 && !hasNonParagraph {
                let allLinkDense = paragraphs.allSatisfy { p in
                    let text = p.textContent.trimmed.jsReplace("\\s+", "g", " ")
                    let links = p.querySelectorAll("a[href]")
                    if links.isEmpty { return false }
                    if Double(linkTextLength(links)) / Double(text.jsLength == 0 ? 1 : text.jsLength) <= 0.6 { return false }
                    var nonLink = text
                    for link in links { nonLink = nonLink.components(separatedBy: link.textContent.trimmed).joined() }
                    return !nonLink.jsTest("[.!?]")
                }
                if allLinkDense { last.remove() }
            }
        }

        // Trailing thin sections.
        let totalWords = Utils.countWords(mainContent.textContent)
        if totalWords > 300 {
            var trailing: [DOMElement] = []
            var trailingWords = 0
            var child = mainContent.lastElementChild
            while let current = child {
                if current.id == "footnotes" {
                    child = current.previousElementSibling
                    continue
                }
                if current.tagName == "HR" {
                    trailing.append(current)
                    break
                }
                let svgWords = current.querySelectorAll("svg").reduce(0) { $0 + Utils.countWords($1.textContent) }
                let words = Utils.countWords(current.textContent.trimmed) - svgWords
                if words > 25 { break }
                trailingWords += words
                trailing.append(current)
                child = current.previousElementSibling
            }
            if !trailing.isEmpty && Double(trailingWords) < Double(totalWords) * 0.15 {
                let hasHeading = trailing.contains(where: isOrContainsHeading)
                let hasContent = trailing.contains { $0.querySelector(Constants.contentElementSelector) != nil }
                let proseParagraphs = trailing.filter { $0.tagName == "P" && Utils.countWords($0.textContent) > 5 }.count
                if hasHeading && !hasContent && proseParagraphs < 2 {
                    for element in trailing { element.remove() }
                }
            }
        }

        // Boilerplate sentences and everything after them.
        let fullText = mainContent.textContent
        for element in mainContent.querySelectorAll("p, div, span, section") where element.parentNode != nil {
            if element.closest("pre, code") != nil { continue }
            let text = element.textContent.trimmed
            let words = Utils.countWords(text)
            if words > 50 || words < 1 { continue }
            for pattern in boilerplatePatterns where pattern.test(text) {
                var target = element
                while let parent = target.parentElement, parent !== mainContent {
                    if target.nextElementSibling != nil { break }
                    target = parent
                }
                let targetPosition = fullText.jsIndexOf(target.textContent)
                if targetPosition < 200 {
                    if target !== element && element.nextElementSibling == nil { element.remove() }
                    continue
                }
                removeTrailingWithCascade(target, mainContent)
                break
            }
        }

        // "Related posts" / "Read next" sections by heading.
        for heading in mainContent.querySelectorAll("h2, h3, h4, h5, h6") where heading.parentNode != nil {
            let headingText = heading.textContent.trimmed
            let isCTA = ctaHeadingPattern.test(headingText)
            if !isCTA && !relatedHeadingPattern.test(headingText) { continue }
            if contentText.jsIndexOf(headingText) < 500 { continue }
            let target = walkUpIsolated(heading, mainContent)
            if hasFollowingProse(target) {
                if target === heading { continue }
                target.remove()
                continue
            }
            if target === heading {
                if !isCTA { continue }
                removeTrailingSiblings(heading, removeSelf: true)
            } else {
                removeThinPrecedingSection(target)
                removeTrailingWithCascade(target, mainContent)
            }
            break
        }

        for element in mainContent.querySelectorAll("p") where element.parentNode != nil {
            let text = element.textContent.trimmed
            if !relatedIntroPattern.test(text) { continue }
            if Utils.countWords(text) > 20 { continue }
            if element.querySelector(Constants.contentElementSelector) != nil { continue }
            element.remove()
        }

        // Related post card grids without a heading.
        let contentWordCount = Utils.countWords(contentText)
        for element in mainContent.querySelectorAll("div, ul, ol") where element.parentNode != nil {
            let children = element.children
            if children.count < 2 { continue }
            if element.querySelectorAll("img, picture").count < 2 { continue }
            let cards = children.filter {
                $0.querySelector("img, picture") != nil
                    && ($0.querySelector("h2, h3, h4") != nil || $0.querySelector("a[href]") != nil)
            }.count
            if cards < 2 || Double(cards) < Double(children.count) * 0.7 { continue }
            let firstText = children[0].textContent.trimmed.jsSubstring(0, 30)
            let followsContent = firstText.jsLength >= 5
                ? contentText.jsIndexOf(firstText) >= 500
                : children.allSatisfy({ $0.querySelector("a[href]") != nil }) && precedingProseWords(element, mainContent) >= 100
            if !followsContent { continue }
            let gridWords = Utils.countWords(element.textContent)
            if contentWordCount > 0 && Double(gridWords) / Double(contentWordCount) > 0.3 { continue }
            let target = walkUpIsolated(element, mainContent)
            if target === element { continue }
            if Utils.countWords(target.textContent) > gridWords * 2 + 15 { continue }
            if hasFollowingProse(target) { continue }
            removeThinPrecedingSection(target)
            removeTrailingSiblings(target, removeSelf: true)
            break
        }

        // Newsletter signup sections.
        for element in mainContent.querySelectorAll("div, section, aside") where element.parentNode != nil {
            if element.closest("pre, code") != nil { continue }
            if !isNewsletterElement(element, maxWords: 60) { continue }
            let elementWords = Utils.countWords(element.textContent.trimmed)
            var target = element
            while let parent = target.parentElement, parent !== mainContent {
                if Utils.countWords(parent.textContent.trimmed) > elementWords * 2 + 15 { break }
                target = parent
            }
            target.remove()
            break
        }

        for element in mainContent.querySelectorAll("ul") where element.parentNode != nil {
            if !isNewsletterElement(element, maxWords: 30) { continue }
            element.remove()
            break
        }

        // Author/contact blocks near the end.
        for element in mainContent.querySelectorAll("div, section") where element.parentNode != nil {
            let text = element.textContent.trimmed
            let words = Utils.countWords(text)
            if words < 2 || words > 40 { continue }
            let position = contentText.jsIndexOf(text.jsSubstring(0, 60))
            if position < 0 { continue }
            if contentLength - (position + text.jsLength) > 300 { continue }
            let hasLabel = element.querySelectorAll("div, span, p, dt, dd, li").contains {
                authorContactLabelPattern.test($0.textContent.trimmed)
            }
            if !hasLabel { continue }
            let hasContact = emailPattern.test(text) || phonePattern.test(text)
                || element.querySelector("a[href^=\"mailto:\"]") != nil
            if !hasContact { continue }
            walkUpIsolated(element, mainContent).remove()
            break
        }

        // Author/share widgets.
        for element in mainContent.querySelectorAll("p, span, div") where element.parentNode != nil {
            if !shareAuthorLabel.test(element.textContent.trimmed) { continue }
            var container = element
            while let parent = container.parentElement, parent !== mainContent {
                if Utils.countWords(parent.textContent.trimmed) > 15 { break }
                container = parent
            }
            if container.querySelector(contentElementNoImgSelector) != nil { continue }
            container.remove()
        }

        // Social engagement counters.
        for element in mainContent.querySelectorAll("a, p, div, span") where element.parentNode != nil {
            let text = element.textContent.trimmed
            if !socialCounterPattern.test(text) { continue }
            if element.tagName == "A" && !(element.getAttribute("href") ?? "").isEmpty { continue }
            if element.tagName != "A" {
                let position = contentText.jsIndexOf(text)
                if contentLength - (position + text.jsLength) > 200 { continue }
            }
            walkUpToWrapper(element, text, mainContent).remove()
        }

        // Trailing tag/category link blocks.
        for element in mainContent.querySelectorAll("div") where element.parentNode != nil {
            let text = element.textContent.trimmed
            let words = Utils.countWords(text)
            if words < 1 || words > 10 { continue }
            if text.jsTest("[.!?]") { continue }
            if element.querySelector(Constants.contentElementSelector) != nil { continue }
            let position = contentText.jsIndexOf(text)
            if position < 0 { continue }
            if contentLength - (position + text.jsLength) > 300 { continue }
            let links = element.querySelectorAll("a[href]")
            if links.isEmpty { continue }
            if Double(linkTextLength(links)) / Double(text.jsLength == 0 ? 1 : text.jsLength) < 0.8 { continue }
            element.remove()
        }
    }
}
