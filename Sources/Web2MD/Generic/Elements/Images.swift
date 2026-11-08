// Port of defuddle src/elements/images.ts.
// Copyright (c) 2025 Steph Ango (@kepano), MIT License.

import Foundation

enum ImageElements {
    private static let lazyAttributes: [(String, [String])] = [
        ("src", ["data-src", "data-original", "data-lazy-src"]),
        ("srcset", ["data-srcset", "data-lazy-srcset"]),
    ]

    static let rules: [StandardizationRule] = [
        StandardizationRule(selector: "picture") { el, doc in
            let sources = el.all("source")
            guard let img = el.querySelector("img") else {
                if let best = selectBestSource(sources), let srcset = best.getAttribute("srcset") {
                    let newImg = doc.createElement("img")
                    applySrcset(srcset, to: newImg)
                    el.replaceChildren([newImg])
                }
                return el
            }
            var bestSrcset: String?
            var bestSrc: String?
            if let best = selectBestSource(sources), let srcset = best.getAttribute("srcset"), !srcset.isEmpty {
                bestSrcset = srcset
                bestSrc = firstURL(fromSrcset: srcset)
            }
            if let bestSrcset { img.setAttribute("srcset", bestSrcset) }
            if let bestSrc, isValidImageURL(bestSrc) {
                img.setAttribute("src", bestSrc)
            } else if !img.hasAttribute("src") || !isValidImageURL(img.getAttribute("src") ?? "") {
                let srcset = img.getAttribute("srcset").flatMap { $0.isEmpty ? nil : $0 } ?? bestSrcset ?? ""
                if let first = firstURL(fromSrcset: srcset), isValidImageURL(first) { img.setAttribute("src", first) }
            }
            for source in sources { source.remove() }
            return el
        },

        StandardizationRule(selector: "uni-image-full-width") { el, doc in
            let figure = doc.createElement("figure")
            let img = doc.createElement("img")
            guard let original = el.querySelector("img") else { return figure }
            var bestSrc = original.getAttribute("src")
            if let loading = original.getAttribute("data-loading"),
               let json = try? JSONSerialization.jsonObject(with: Data(loading.utf8)) as? [String: Any],
               let desktop = json["desktop"] as? String, isValidImageURL(desktop) {
                bestSrc = desktop
            }
            guard let src = bestSrc, isValidImageURL(src) else { return figure }
            img.setAttribute("src", src)
            if let alt = original.getAttribute("alt").flatMap({ $0.isEmpty ? nil : $0 }) ?? el.getAttribute("alt-text"), !alt.isEmpty {
                img.setAttribute("alt", alt)
            }
            figure.appendChild(img)
            if let caption = el.querySelector("figcaption") {
                let text = caption.textContent.trimmed
                if text.jsLength > 5 {
                    let figcaption = doc.createElement("figcaption")
                    if let richText = caption.querySelector(".rich-text p") {
                        Utils.transferContent(richText, figcaption)
                    } else {
                        figcaption.textContent = text
                    }
                    figure.appendChild(figcaption)
                }
            }
            return figure
        },

        StandardizationRule(
            selector: (lazyAttributes.flatMap { $0.1.map { "img[\($0)]" } } + ["img[data-image-loader]"]).joined(separator: ", ")
        ) { el, _ in
            for (target, attributes) in lazyAttributes {
                let source = attributes.compactMap { el.getAttribute($0)?.trimmed }
                    .first { !$0.isEmpty && !Utils.isDangerousURL($0) }
                if let source { el.setAttribute(target, source) }
                for attribute in attributes { el.removeAttribute(attribute) }
            }
            let src = el.getAttribute("src") ?? ""
            if let loader = el.getAttribute("data-image-loader")?.trimmed, !loader.isEmpty, !Utils.isDangerousURL(loader),
               src.isEmpty || SmallImages.isBase64Placeholder(src) || isSVGDataURL(src) {
                el.setAttribute("src", loader)
            }
            el.removeAttribute("data-image-loader")
            el.removeClass("lazy")
            el.removeClass("lazyload")
            el.removeAttribute("data-ll-status")
            el.removeAttribute("loading")
            return el
        },

        StandardizationRule(selector: "span:has(img)") { el, doc in
            guard containsImage(el) else { return el }
            if el.children.contains(where: { Constants.blockLevelElements.contains($0.localName) }) { return el }
            guard let main = findMainImage(el) else { return el }
            let caption = findCaption(el)
            let processed = processImageElement(main, doc)
            if let caption, hasMeaningfulCaption(caption) {
                let figure = createFigure(processed, caption: caption, doc)
                caption.remove()
                return figure
            }
            return processed
        },

        StandardizationRule(selector: "figure, p:has([class*=\"caption\"])") { el, doc in
            guard containsImage(el), let main = findMainImage(el) else { return el }
            guard let caption = findCaption(el), hasMeaningfulCaption(caption) else { return el }
            let image = findMainImage(el) ?? processImageElement(main, doc)
            return createFigure(image, caption: caption, doc)
        },
    ]

    private static func createFigure(_ image: DOMElement, caption: DOMElement, _ doc: DOMDocument) -> DOMElement {
        let figure = doc.createElement("figure")
        figure.appendChild(image.clone())
        let figcaption = doc.createElement("figcaption")
        figcaption.appendChild(Utils.parseHTML(uniqueCaptionContent(caption)))
        figure.appendChild(figcaption)
        return figure
    }

    private static func applySrcset(_ srcset: String, to img: DOMElement) {
        img.setAttribute("srcset", srcset)
        if let first = firstURL(fromSrcset: srcset), isValidImageURL(first) { img.setAttribute("src", first) }
    }

    private static func copyAttributes(from source: DOMElement, to target: DOMElement, except excluded: [String]) {
        for attribute in source.attributes where !excluded.contains(attribute.name) {
            target.setAttribute(attribute.name, attribute.value)
        }
    }

    static func isSVGDataURL(_ src: String) -> Bool { src.hasPrefix("data:image/svg+xml") }

    static func isValidImageURL(_ src: String) -> Bool {
        if src.hasPrefix("data:") || src.trimmed.isEmpty { return false }
        return src.jsTest("\\.(jpg|jpeg|png|webp|gif|avif)(\\?.*)?$", "i") || src.contains("image") || src.contains("img")
            || src.contains("photo")
    }

    private static func isImageElement(_ el: DOMElement) -> Bool {
        ["img", "video", "picture", "source"].contains(el.localName)
    }

    private static func containsImage(_ el: DOMElement) -> Bool {
        isImageElement(el) || el.querySelector("img, video, picture, source") != nil
    }

    private static func findMainImage(_ el: DOMElement) -> DOMElement? {
        if isImageElement(el) { return el }
        if let picture = el.querySelector("picture") { return picture }
        let imgs = el.all("img")
        let filtered = imgs.filter { img in
            let src = img.getAttribute("src") ?? ""
            let alt = img.getAttribute("alt") ?? ""
            if isSVGDataURL(src) || SmallImages.isBase64Placeholder(src) { return false }
            if alt.trimmed.isEmpty && imgs.count > 1 { return false }
            return true
        }
        if let first = filtered.first { return first }
        if let video = el.querySelector("video") { return video }
        if let source = el.querySelector("source") { return source }
        return el.querySelector("img, picture, source, video")
    }

    private static let captionSelector = [
        "[class*=\"caption\"]", "[class*=\"description\"]", "[class*=\"alt\"]", "[class*=\"title\"]",
        "[class*=\"credit\"]", "[class*=\"text\"]", "[class*=\"post-thumbnail-text\"]", "[class*=\"image-caption\"]",
        "[class*=\"photo-caption\"]", "[aria-label]", "[title]",
    ].joined(separator: ", ")

    private static func findCaption(_ el: DOMElement) -> DOMElement? {
        if let figcaption = el.querySelector("figcaption") { return figcaption }
        for candidate in el.all(captionSelector) where !isImageElement(candidate) {
            if !candidate.textContent.trimmed.isEmpty { return candidate }
        }
        if let img = el.querySelector("img"), let alt = img.getAttribute("alt"), !alt.trimmed.isEmpty {
            let caption = DOMElement("div")
            caption.textContent = alt
            return caption
        }
        if let parent = el.parentElement {
            for sibling in parent.children where sibling !== el {
                let hasCaptionClass = sibling.classList.contains {
                    $0.contains("caption") || $0.contains("credit") || $0.contains("text") || $0.contains("description")
                }
                if hasCaptionClass && !sibling.textContent.trimmed.isEmpty { return sibling }
            }
        }
        let imgs = el.all("img")
        let textTags: Set<String> = ["EM", "STRONG", "SPAN", "I", "B", "SMALL", "CITE"]
        for img in imgs where img.parentElement != nil {
            var next = img.nextElementSibling
            while let n = next {
                if textTags.contains(n.tagName) && !n.textContent.trimmed.isEmpty { return n }
                next = n.nextElementSibling
            }
        }
        for img in imgs {
            guard let parent = img.parentElement else { continue }
            for text in parent.all("em, strong, span, i, b, small, cite") where text !== img {
                if !text.textContent.trimmed.isEmpty { return text }
            }
        }
        return nil
    }

    private static func uniqueCaptionContent(_ caption: DOMElement) -> String {
        var texts: [String] = []
        var seen = Set<String>()
        func process(_ node: DOMNode) {
            if node.isText {
                let text = node.textContent.trimmed
                if !text.isEmpty && !seen.contains(text) {
                    texts.append(text)
                    seen.insert(text)
                }
            } else if node.isElement {
                for child in node.childNodes { process(child) }
            }
        }
        for child in caption.childNodes { process(child) }
        // Text is re-parsed as HTML, so escape it.
        if !texts.isEmpty { return Utils.escapeHTML(texts.joined(separator: " ")) }
        return caption.innerHTML
    }

    private static func hasMeaningfulCaption(_ caption: DOMElement) -> Bool {
        let text = caption.textContent.trimmed
        if text.jsLength < 10 || text.hasPrefix("http://") || text.hasPrefix("https://") { return false }
        if text.jsTest("^[\\w\\-\\.\\/\\\\]+\\.(jpg|jpeg|png|gif|webp|svg)$", "i") { return false }
        if text.jsTest("^\\d+$") || text.jsTest("^\\d{4}-\\d{2}-\\d{2}$") { return false }
        return true
    }

    private static func processImageElement(_ el: DOMElement, _ doc: DOMDocument) -> DOMElement {
        switch el.localName {
        case "img": return processImg(el, doc)
        case "picture": return el.querySelector("img").map { processImg($0, doc) } ?? el.clone()
        case "source": return processSource(el, doc)
        default: return el.clone()
        }
    }

    private static func processImg(_ el: DOMElement, _ doc: DOMDocument) -> DOMElement {
        let src = el.getAttribute("src") ?? ""
        if SmallImages.isBase64Placeholder(src) || isSVGDataURL(src), let parent = el.parentElement {
            let sources = parent.all("source").filter { !($0.getAttribute("data-srcset") ?? "").isEmpty }
            if !sources.isEmpty {
                let img = doc.createElement("img")
                if let dataSrc = el.getAttribute("data-src"), !isSVGDataURL(dataSrc) { img.setAttribute("src", dataSrc) }
                copyAttributes(from: el, to: img, except: ["src"])
                return img
            }
        }
        return el.clone()
    }

    private static func processSource(_ el: DOMElement, _ doc: DOMDocument) -> DOMElement {
        let img = doc.createElement("img")
        if let srcset = el.getAttribute("srcset"), !srcset.isEmpty { applySrcset(srcset, to: img) }
        guard let parent = el.parentElement else { return img }
        let candidates = parent.all("img").filter { img in
            let src = img.getAttribute("src") ?? ""
            return !SmallImages.isBase64Placeholder(src) && !isSVGDataURL(src) && !src.isEmpty
        }
        if let first = candidates.first {
            copyAttributes(from: first, to: img, except: ["src", "srcset"])
            if !img.hasAttribute("src") || !isValidImageURL(img.getAttribute("src") ?? ""),
               let src = first.getAttribute("src"), isValidImageURL(src) {
                img.setAttribute("src", src)
            }
        } else if let dataSrcImg = parent.querySelector("img[data-src]") {
            copyAttributes(from: dataSrcImg, to: img, except: ["src", "srcset"])
            if !img.hasAttribute("src") || !isValidImageURL(img.getAttribute("src") ?? ""),
               let dataSrc = dataSrcImg.getAttribute("data-src"), isValidImageURL(dataSrc) {
                img.setAttribute("src", dataSrc)
            }
        }
        return img
    }

    static func srcsetEntries(_ srcset: String) -> [(url: String, descriptor: String)] {
        var entries: [(String, String)] = []
        for (index, match) in JSRegex("(.+?)\\s+(\\d+(?:\\.\\d+)?[wx])", "g").allMatches(srcset).enumerated() {
            var url = (match[1] ?? "").trimmed
            if index > 0 { url = url.jsReplace("^,\\s*", "", "") }
            entries.append((url, match[2] ?? ""))
        }
        return entries
    }

    static func firstURL(fromSrcset srcset: String) -> String? {
        let trimmed = srcset.trimmed
        if trimmed.isEmpty { return nil }
        for entry in srcsetEntries(trimmed) where !entry.url.isEmpty && !isSVGDataURL(entry.url) {
            return entry.url
        }
        if let first = trimmed.jsMatch("^([^\\s]+)")?[1], !isSVGDataURL(first) { return first }
        return nil
    }

    private static func selectBestSource(_ sources: [DOMElement]) -> DOMElement? {
        if sources.count <= 1 { return sources.first }
        if let noMedia = sources.first(where: { !$0.hasAttribute("media") }) { return noMedia }
        var best: DOMElement?
        var maxResolution = 0.0
        for source in sources {
            guard let srcset = source.getAttribute("srcset"), let width = jsParseInt(srcset.jsMatch("\\s(\\d+)w")?[1]) else { continue }
            let dpr = jsParseFloat(srcset.jsMatch("dpr=(\\d+(?:\\.\\d+)?)")?[1]) ?? 1
            let resolution = Double(width) * dpr
            if resolution > maxResolution {
                maxResolution = resolution
                best = source
            }
        }
        return best ?? sources.first
    }
}
