import Foundation

/// Renders an X article (Draft.js raw content) to Markdown.
///
/// Block types: unstyled, header-one…six, blockquote, ordered/unordered list
/// items (with depth), code-block and atomic. Atomic blocks carry MEDIA,
/// TWEET, MARKDOWN (code), DIVIDER and LaTeX entities. Inline: Bold, Italic,
/// Strikethrough, Code styles, LINK entities, and urls/mentions/hashtags/cashtags
/// from block data.
struct XArticleRenderer {
    let article: JSONValue
    /// Rendered embedded posts by id.
    let embeds: [String: String]

    /// Ids of posts embedded in the article.
    static func embeddedTweetIDs(_ article: JSONValue) -> [String] {
        let entities = EntityMap(article["content"]["entityMap"])
        var ids: [String] = []
        for block in article["content"]["blocks"].items {
            for range in block["entityRanges"].items {
                guard let entity = entities[range["key"]], entity["type"].text.uppercased() == "TWEET" else { continue }
                let id = entity["data"]["tweetId"].text
                if !id.isEmpty, !ids.contains(id) { ids.append(id) }
            }
        }
        return ids
    }

    // MARK: - Items

    private enum Item {
        case paragraph(String)
        case heading(level: Int, String)
        case quote(String)
        case listItem(ordered: Bool, depth: Int, String)
        case code(String)
        case raw(String)
    }

    func render() -> String {
        let entities = EntityMap(article["content"]["entityMap"])
        let media = mediaIndex()
        var items: [Item] = []
        var codeLines: [String]?

        func flushCode() {
            if let lines = codeLines { items.append(.code(MarkdownText.fence(lines.joined(separator: "\n")))) }
            codeLines = nil
        }

        for block in article["content"]["blocks"].items {
            let type = block["type"].text
            if type == "code-block" {
                codeLines = (codeLines ?? []) + [block["text"].text]
                continue
            }
            flushCode()

            let ranges = block["entityRanges"].items
            let blockEntities = ranges.compactMap { entities[$0["key"]] }

            if let markdown = blockEntities.first(where: { $0["type"].text.uppercased() == "MARKDOWN" })?["data"]["markdown"].string {
                items.append(.raw(markdown.trimmed))
                continue
            }

            if type == "atomic" || blockEntities.contains(where: { ["MEDIA", "TWEET", "DIVIDER", "LATEX", "TEX"].contains($0["type"].text.uppercased()) }) {
                let rendered = blockEntities.compactMap { atomic($0, media: media) }
                if !rendered.isEmpty {
                    items.append(contentsOf: rendered.map(Item.raw))
                    continue
                }
                if type == "atomic" {
                    let text = block["text"].text.trimmed
                    if !text.isEmpty { items.append(.paragraph(MarkdownText.escape(text))) }
                    continue
                }
            }

            let inline = richText(block, entities: entities)
            let markdown = inline.markdown()
            guard !markdown.trimmed.isEmpty else { continue }

            switch type {
            case "header-one": items.append(.heading(level: 2, markdown))
            case "header-two": items.append(.heading(level: 3, markdown))
            case "header-three": items.append(.heading(level: 4, markdown))
            case "header-four", "header-five", "header-six": items.append(.heading(level: 5, markdown))
            case "blockquote": items.append(.quote(markdown))
            case "ordered-list-item": items.append(.listItem(ordered: true, depth: block["depth"].int ?? 0, markdown))
            case "unordered-list-item": items.append(.listItem(ordered: false, depth: block["depth"].int ?? 0, markdown))
            default: items.append(.paragraph(markdown))
            }
        }
        flushCode()
        return assemble(items)
    }

    private func assemble(_ items: [Item]) -> String {
        struct Level { var ordered: Bool; var number: Int; var width: Int }
        var output = ""
        var levels: [Level] = []
        var previous: Item?

        for item in items {
            let separator: String
            switch (previous, item) {
            case (nil, _): separator = ""
            case (.listItem?, .listItem): separator = "\n"
            case (.quote?, .quote): separator = "\n>\n"
            default: separator = "\n\n"
            }

            var rendered: String
            switch item {
            case .paragraph(let text):
                rendered = Self.hardBreaks(text, indent: "")
            case .heading(let level, let text):
                rendered = String(repeating: "#", count: level) + " " + text.replacingOccurrences(of: "\n", with: " ").trimmed
            case .quote(let text):
                rendered = Self.hardBreaks(text, indent: "").components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
            case .listItem(let ordered, let depth, let text):
                if case .listItem = previous {} else { levels = [] }
                if levels.count > depth + 1 { levels.removeLast(levels.count - depth - 1) }
                while levels.count < depth { levels.append(Level(ordered: ordered, number: 1, width: ordered ? 3 : 2)) }
                if levels.count == depth + 1, levels[depth].ordered == ordered {
                    levels[depth].number += 1
                } else {
                    if levels.count == depth + 1 { levels.removeLast() }
                    levels.append(Level(ordered: ordered, number: 1, width: 0))
                }
                let marker = ordered ? "\(levels[depth].number). " : "- "
                levels[depth].width = marker.count
                let indent = String(repeating: " ", count: levels[..<depth].reduce(0) { $0 + $1.width })
                let continuation = indent + String(repeating: " ", count: marker.count)
                rendered = indent + marker + Self.hardBreaks(text, indent: continuation)
            case .code(let text), .raw(let text):
                rendered = text
            }
            if case .listItem = item {} else { levels = [] }
            output += separator + rendered
            previous = item
        }
        return output
    }

    /// Soft line breaks inside a block become Markdown hard breaks.
    private static func hardBreaks(_ text: String, indent: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > 1 else { return text }
        return lines.enumerated().map { index, line in
            index == 0 ? line : indent + line.trimmingLeadingWhitespace()
        }.joined(separator: "  \n")
    }

    // MARK: - Inline

    private func richText(_ block: JSONValue, entities: EntityMap) -> RichText {
        var rich = RichText(text: block["text"].text)
        rich.styles = block["inlineStyleRanges"].items.compactMap { range in
            guard let offset = range["offset"].int, let length = range["length"].int else { return nil }
            return RichText.Style(offset: offset, length: length, style: Self.styleName(range["style"].text))
        }
        for range in block["entityRanges"].items {
            guard let entity = entities[range["key"]], entity["type"].text.uppercased() == "LINK",
                  let offset = range["offset"].int, let length = range["length"].int else { continue }
            let href = entity["data"]["url"].string ?? entity["data"]["href"].text
            if !href.isEmpty { rich.links.append(.init(from: offset, to: offset + length, href: Self.absoluteLink(href))) }
        }
        let data = block["data"]
        for url in data["urls"].items {
            let href = url["url"].string ?? url["expanded_url"].string ?? url["text"].text
            add(url, href: Self.absoluteLink(href), to: &rich)
        }
        for mention in data["mentions"].items {
            add(mention, href: "https://x.com/\(Self.stripPrefix(mention["text"].text, "@"))", to: &rich)
        }
        for hashtag in data["hashtags"].items {
            let tag = Self.stripPrefix(hashtag["text"].text, "#")
            add(hashtag, href: "https://x.com/hashtag/\(tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag)", to: &rich)
        }
        for cashtag in data["cashtags"].items {
            add(cashtag, href: "https://x.com/search?q=%24\(Self.stripPrefix(cashtag["text"].text, "$"))", to: &rich)
        }
        return rich
    }

    private func add(_ span: JSONValue, href: String, to rich: inout RichText) {
        guard let from = span["fromIndex"].int, let to = span["toIndex"].int, to > from, !href.isEmpty else { return }
        rich.links.append(.init(from: from, to: to, href: href))
    }

    private static func styleName(_ raw: String) -> String {
        switch raw.uppercased() {
        case "BOLD": "Bold"
        case "ITALIC": "Italic"
        case "STRIKETHROUGH": "Strikethrough"
        case "CODE": "Code"
        default: raw
        }
    }

    private static func stripPrefix(_ text: String, _ prefix: String) -> String {
        text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }

    static func absoluteLink(_ href: String) -> String {
        let trimmed = href.trimmed
        if trimmed.isEmpty || trimmed.jsTest("^[a-z][a-z0-9+.-]*:", "i") || trimmed.hasPrefix("//") { return trimmed }
        if trimmed.hasPrefix("/") { return "https://x.com" + trimmed }
        return "https://" + trimmed
    }

    // MARK: - Atomic entities

    private func atomic(_ entity: JSONValue, media: [String: JSONValue]) -> String? {
        let data = entity["data"]
        switch entity["type"].text.uppercased() {
        case "MEDIA":
            let caption = data["caption"].text.trimmed
            let rendered = data["mediaItems"].items.compactMap { item -> String? in
                let id = item["mediaId"].string ?? item["media_id"].text
                guard let info = media[id] else { return nil }
                return XMedia.markdown(articleMedia: info, alt: caption)
            }
            guard !rendered.isEmpty else { return nil }
            var output = rendered.joined(separator: "\n\n")
            if !caption.isEmpty { output += "\n\n*" + MarkdownText.escape(caption, atLineStart: false) + "*" }
            return output
        case "TWEET":
            let id = data["tweetId"].text
            guard !id.isEmpty else { return nil }
            return embeds[id] ?? MarkdownText.quote(MarkdownText.link("https://x.com/i/status/\(id)", "https://x.com/i/status/\(id)"))
        case "DIVIDER":
            return "---"
        case "LATEX", "TEX":
            let tex = (data["markdown"].string ?? data["latex"].string ?? data["tex"].text).trimmed
            guard !tex.isEmpty else { return nil }
            return tex.hasPrefix("$") ? tex : "$$\n\(tex)\n$$"
        default:
            return nil
        }
    }

    private func mediaIndex() -> [String: JSONValue] {
        var index: [String: JSONValue] = [:]
        for entity in article["media_entities"].items {
            let id = entity["media_id"].string ?? entity["id"].text
            if !id.isEmpty { index[id] = entity["media_info"].exists ? entity["media_info"] : entity }
        }
        return index
    }
}

/// Draft.js entity maps come either as an object keyed by string or an array of `{key, value}`.
struct EntityMap {
    private var entries: [String: JSONValue] = [:]

    init(_ json: JSONValue) {
        if let array = json.array {
            for (index, item) in array.enumerated() {
                let key = item["key"].string ?? String(index)
                entries[key] = item["value"].exists ? item["value"] : item
            }
        } else if let object = json.object {
            for (key, value) in object { entries[key] = value["value"].exists && !value["type"].exists ? value["value"] : value }
        }
    }

    subscript(key: JSONValue) -> JSONValue? {
        guard let key = key.string else { return nil }
        return entries[key]
    }
}

enum XMedia {
    /// Article media (`media_entities[].media_info`).
    static func markdown(articleMedia info: JSONValue, alt: String) -> String? {
        let type = info["__typename"].text
        let alt = info["ext_alt_text"].string ?? alt
        if type == "ApiImage" || (info["original_img_url"].exists && !info["variants"].exists && !info["video_info"].exists) {
            let url = info["original_img_url"].string ?? info["media_url_https"].text
            return url.isEmpty ? nil : MarkdownText.image(url, alt: alt)
        }
        let variants = info["variants"].items + info["video_info"]["variants"].items
        let video = bestMP4(variants)
        let poster = info["preview_image"]["original_img_url"].string
            ?? info["media_url_https"].string
            ?? info["original_img_url"].string
            ?? ""
        return linkedPoster(poster: poster, video: video, alt: alt)
    }

    /// Post media (FxTwitter `media.all[]`).
    static func markdown(postMedia item: JSONValue) -> String? {
        let alt = item["altText"].string ?? item["alt_text"].text
        switch item["type"].text {
        case "photo":
            let url = item["url"].text
            return url.isEmpty ? nil : MarkdownText.image(url, alt: alt)
        case "video", "gif":
            let mp4 = bestMP4(item["formats"].items + item["variants"].items) ?? item["url"].string
            return linkedPoster(poster: item["thumbnail_url"].text, video: mp4, alt: alt)
        default:
            let url = item["url"].text
            return url.isEmpty ? nil : MarkdownText.image(url, alt: alt)
        }
    }

    private static func linkedPoster(poster: String, video: String?, alt: String) -> String? {
        switch (poster.isEmpty, video) {
        case (false, let video?): "[\(MarkdownText.image(poster, alt: alt))](\(MarkdownText.escapeURL(video)))"
        case (false, nil): MarkdownText.image(poster, alt: alt)
        case (true, let video?): MarkdownText.link(alt.isEmpty ? "Video" : MarkdownText.escapeAlt(alt), video)
        case (true, nil): nil
        }
    }

    static func bestMP4(_ variants: [JSONValue]) -> String? {
        variants
            .filter { variant in
                let type = (variant["content_type"].string ?? variant["container"].text).lowercased()
                let url = variant["url"].text
                return !url.isEmpty && !url.contains(".m3u8") && (type.isEmpty || type.contains("mp4"))
            }
            .max { ($0["bit_rate"].int ?? $0["bitrate"].int ?? 0) < ($1["bit_rate"].int ?? $1["bitrate"].int ?? 0) }?["url"].string
    }
}
