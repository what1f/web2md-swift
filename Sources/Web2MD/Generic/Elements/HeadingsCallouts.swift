// Port of defuddle src/elements/headings.ts and callouts.ts.
// Copyright (c) 2025 Steph Ango (@kepano), MIT License.

import Foundation

enum HeadingElements {
    static func removePermalinkAnchors(_ element: DOMElement) {
        for link in element.all("h1 a, h2 a, h3 a, h4 a, h5 a, h6 a, a.permalink, a.anchor-link, a.heading-anchor")
        where isPermalinkAnchor(link) {
            link.remove()
        }
    }

    static func isPermalinkAnchor(_ node: DOMElement) -> Bool {
        guard node.localName == "a" else { return false }
        let href = node.getAttribute("href") ?? ""
        let title = (node.getAttribute("title") ?? "").lowercased()
        let className = node.className.lowercased()
        if href.hasPrefix("#") || title.contains("permalink") { return true }
        if className.contains("permalink") || className.contains("heading-anchor") || className.contains("anchor-link") { return true }
        return node.textContent.trimmed.jsTest("^(?:[#¶§\\uFEFF]|\u{1F517})$")
    }

    private static func isHeadingNavElement(_ node: DOMElement) -> Bool {
        let tag = node.localName
        if tag == "button" { return true }
        if tag == "a" && isPermalinkAnchor(node) { return true }
        if node.hasClass("anchor") || node.hasClass("permalink-widget") { return true }
        if (tag == "span" || tag == "div") && node.all("a").contains(where: isPermalinkAnchor) { return true }
        return false
    }

    static let rules: [StandardizationRule] = [
        StandardizationRule(selector: "h1, h2, h3, h4, h5, h6") { el, doc in
            let heading = doc.createElement(el.localName)
            for attribute in el.attributes where Constants.allowedAttributes.contains(attribute.name) {
                heading.setAttribute(attribute.name, attribute.value)
            }
            if el.children.isEmpty {
                heading.textContent = el.textContent.trimmed
                return heading
            }
            let clone = el.clone()
            var navigationText: [String] = []
            var toRemove: [DOMElement] = []
            for child in clone.all("*") where isHeadingNavElement(child) {
                let text = child.textContent.trimmed
                navigationText.append(text)
                toRemove.append(child)
            }
            for node in toRemove { node.remove() }
            var text = clone.textContent.trimmed
            if text.isEmpty, let first = navigationText.first { text = first }
            heading.textContent = text
            return heading
        },
    ]
}

enum CalloutElements {
    private static func createCallout(_ doc: DOMDocument, type: String, title: String, content: DOMElement) -> DOMElement {
        let callout = doc.createElement("div")
        callout.setAttribute("data-callout", type)
        callout.setAttribute("class", "callout")
        let titleDiv = doc.createElement("div")
        titleDiv.setAttribute("class", "callout-title")
        let titleInner = doc.createElement("div")
        titleInner.setAttribute("class", "callout-title-inner")
        titleInner.textContent = title
        titleDiv.appendChild(titleInner)
        callout.appendChild(titleDiv)
        let contentDiv = doc.createElement("div")
        contentDiv.setAttribute("class", "callout-content")
        Utils.transferContent(content, contentDiv)
        callout.appendChild(contentDiv)
        return callout
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    private static let admonitionTypes: Set<String> = [
        "info", "warning", "note", "tip", "danger", "caution", "important", "abstract", "success", "question",
        "failure", "bug", "example", "quote",
    ]

    static func standardize(_ element: DOMElement) {
        let doc = DOMDocument()
        for el in element.all(".callout.is-collapsed, .callout.is-collapsible") {
            let collapsed = el.hasClass("is-collapsed")
            el.removeClass("is-collapsed")
            el.removeClass("is-collapsible")
            if !el.hasAttribute("data-callout-fold") { el.setAttribute("data-callout-fold", collapsed ? "-" : "+") }
            el.querySelector(".callout-fold")?.remove()
            if let content = el.querySelector(".callout-content"), let style = content.getAttribute("style") {
                let cleaned = style.jsReplace("display\\s*:\\s*none\\s*;?", "gi", "").trimmed
                if cleaned.isEmpty { content.removeAttribute("style") } else { content.setAttribute("style", cleaned) }
            }
        }

        for el in element.all(".markdown-alert") {
            let typeClass = el.classList.first { $0.hasPrefix("markdown-alert-") }
            let type = typeClass.map { String($0.dropFirst("markdown-alert-".count)) } ?? "note"
            el.querySelector(".markdown-alert-title")?.remove()
            el.replaceWith(createCallout(doc, type: type, title: capitalized(type), content: el))
        }

        for el in element.all("aside[class*=\"callout\"]") {
            let typeClass = el.classList.first { $0.hasPrefix("callout-") }
            let type = typeClass.map { String($0.dropFirst("callout-".count)) } ?? "note"
            let content = el.querySelector(".callout-content") ?? el
            el.replaceWith(createCallout(doc, type: type, title: capitalized(type), content: content))
        }

        for el in element.all(".admonition") {
            if !(el.getAttribute("data-callout") ?? "").isEmpty { continue }
            let type = el.classList.first { admonitionTypes.contains($0) } ?? "note"
            let titleEl = el.querySelector(".admonition-title")
            let titleText = titleEl?.textContent.trimmed ?? ""
            let title = titleText.isEmpty ? capitalized(type) : titleText
            titleEl?.remove()
            let content = el.querySelector(".admonition-content") ?? el.querySelector(".details-content") ?? el
            el.replaceWith(createCallout(doc, type: type, title: title, content: content))
        }

        for el in element.all(".alert[class*=\"alert-\"]") {
            let typeClass = el.classList.first { $0.hasPrefix("alert-") && $0 != "alert-dismissible" }
            let type = typeClass.map { String($0.dropFirst("alert-".count)) } ?? "note"
            let titleEl = el.querySelector(".alert-heading, .alert-title")
            let titleText = titleEl?.textContent.trimmed ?? ""
            let title = titleText.isEmpty ? capitalized(type) : titleText
            titleEl?.remove()
            el.replaceWith(createCallout(doc, type: type, title: title, content: el))
        }
    }
}
