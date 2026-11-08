import Foundation

/// X (Twitter) posts, threads and long-form articles.
///
/// X pages render client-side, so HTML extraction picks up UI chrome (author
/// names, like counts) instead of content. This parser reads structured data
/// from the FxTwitter API instead and never falls back to the generic parser.
public struct XParser: Web2MDParser {
    public let name = "x"

    public init() {}

    public static let hosts = [
        "x.com", "twitter.com", "fxtwitter.com", "fixupx.com", "vxtwitter.com", "fixvx.com",
        "twittpr.com", "nitter.net", "xcancel.com",
    ]

    public static var rule: ParserRule {
        ParserRule(
            "x",
            url: URLMatcher.hosts(hosts).and(URLMatcher { XParser.postReference($0) != nil }),
            exclusive: true,
            parser: XParser()
        )
    }

    struct PostReference: Equatable {
        var user: String?
        var id: String
    }

    /// `/{user}/status/{id}`, `/i/status/{id}`, `/i/web/status/{id}`, `/{user}/article/{id}`.
    static func postReference(_ url: URL) -> PostReference? {
        guard let match = url.path.jsMatch("^/(?:i/web/|i/|([A-Za-z0-9_]{1,20})/)(?:status|statuses|article)/(\\d{1,25})", "i") else {
            return nil
        }
        let user = match[1].flatMap { $0.lowercased() == "i" ? nil : $0 }
        return PostReference(user: user, id: match[2] ?? "")
    }

    public func parse(_ context: ParseContext) async throws -> Web2MDDocument? {
        guard let reference = Self.postReference(context.url) else { return nil }
        let api = FxTwitterAPI(context: context)
        let conversation = try await api.conversation(id: reference.id, user: reference.user)
        let status = conversation.status
        let author = status["author"]
        let handle = author["screen_name"].text
        let canonical = URL(string: status["url"].text) ?? context.url

        var extras: [String: String] = ["authorHandle": handle, "postID": status["id"].text]
        if let avatar = author["avatar_url"].string { extras["authorAvatar"] = avatar }

        let article = status["article"]
        if article.isObject, article["content"]["blocks"].isArray || article["title"].exists {
            extras["type"] = "article"
            return try await articleDocument(article, status: status, url: canonical, api: api, extras: extras)
        }

        extras["type"] = conversation.thread.count > 1 ? "thread" : "post"
        let posts = Self.ownThread(conversation, authorID: author["id"].text)
        let markdown = posts.map { XPostRenderer.body($0, quoteDepth: 0) }
            .filter { !$0.trimmed.isEmpty }
            .joined(separator: "\n\n")
        let first = posts.first ?? status
        return Web2MDDocument(
            url: canonical,
            title: XPostRenderer.title(first),
            author: author["name"].string ?? handle,
            site: "X",
            published: XPostRenderer.isoDate(status),
            description: XPostRenderer.plainText(first).prefix(300).description,
            image: XPostRenderer.firstImage(first) ?? "",
            language: status["lang"].string.flatMap { ["und", "zxx", "qme", "qam"].contains($0) ? nil : $0 } ?? "",
            favicon: "https://abs.twimg.com/favicons/twitter.3.ico",
            markdown: markdown,
            parser: name,
            extras: extras
        )
    }

    private func articleDocument(
        _ article: JSONValue,
        status: JSONValue,
        url: URL,
        api: FxTwitterAPI,
        extras: [String: String]
    ) async throws -> Web2MDDocument {
        let author = status["author"]
        let embeds = await embeddedPosts(XArticleRenderer.embeddedTweetIDs(article), api: api)
        var body = XArticleRenderer(article: article, embeds: embeds).render()
        if body.trimmed.isEmpty {
            body = MarkdownText.escape(article["preview_text"].text)
        }

        let cover = article["cover_media"]["media_info"]["original_img_url"].string
            ?? article["cover_media"]["original_img_url"].string
            ?? ""
        let options = api.context.options
        var markdown = body
        if options.includeCoverImage, !cover.isEmpty {
            markdown = MarkdownText.image(cover) + "\n\n" + body
        }

        var extras = extras
        if let width = article["cover_media"]["media_info"]["original_img_width"].int,
           let height = article["cover_media"]["media_info"]["original_img_height"].int {
            extras["imageWidth"] = String(width)
            extras["imageHeight"] = String(height)
        }
        if let id = article["id"].string { extras["articleID"] = id }

        let title = article["title"].text.trimmed
        return Web2MDDocument(
            url: url,
            title: title.isEmpty ? XPostRenderer.title(status) : title,
            author: author["name"].string ?? author["screen_name"].text,
            site: "X",
            published: article["created_at"].string.map(XPostRenderer.normalizeISO) ?? XPostRenderer.isoDate(status),
            description: article["preview_text"].text.trimmed,
            image: cover,
            language: status["lang"].string.flatMap { ["und", "zxx", "qme", "qam"].contains($0) ? nil : $0 } ?? "",
            favicon: "https://abs.twimg.com/favicons/twitter.3.ico",
            markdown: markdown,
            wordCount: TextMetrics.countWords(body),
            parser: name,
            extras: extras
        )
    }

    /// Fetches posts embedded in an article, a few at a time.
    private func embeddedPosts(_ ids: [String], api: FxTwitterAPI) async -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        var results: [String: String] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 6).map({ Array(ids[$0..<min($0 + 6, ids.count)]) }) {
            await withTaskGroup(of: (String, String?).self) { group in
                for id in chunk {
                    group.addTask {
                        guard let status = try? await api.status(id: id) else { return (id, nil) }
                        return (id, XPostRenderer.quote(status))
                    }
                }
                for await (id, markdown) in group {
                    if let markdown { results[id] = markdown }
                }
            }
        }
        return results
    }

    /// The thread posts by the original author, from the first post up to the
    /// requested one and the author's continuation after it.
    static func ownThread(_ conversation: FxTwitterAPI.Conversation, authorID: String) -> [JSONValue] {
        let own = conversation.thread.filter { authorID.isEmpty || $0["author"]["id"].text == authorID }
        return own.isEmpty ? [conversation.status] : own
    }
}

/// Renders posts (not articles) to Markdown.
enum XPostRenderer {
    /// Post text with links, mentions and hashtags, followed by media, poll and quoted post.
    static func body(_ status: JSONValue, quoteDepth: Int) -> String {
        var parts: [String] = []
        let text = richText(status)
        if !text.isEmpty { parts.append(text) }

        if status["article"].isObject, quoteDepth > 0 || parts.isEmpty {
            let title = status["article"]["title"].text.trimmed
            if !title.isEmpty { parts.append("**" + MarkdownText.link(MarkdownText.escape(title, atLineStart: false), status["url"].text) + "**") }
        }

        let media = status["media"]["all"].items
        parts.append(contentsOf: media.compactMap(XMedia.markdown(postMedia:)))
        if media.isEmpty, let photos = status["media"]["photos"].array {
            parts.append(contentsOf: photos.compactMap(XMedia.markdown(postMedia:)))
        }

        let choices = status["poll"]["choices"].items
        if !choices.isEmpty {
            parts.append(choices.map { choice in
                let percentage = choice["percentage"].double.map { " (\(Self.percent($0)))" } ?? ""
                return "- " + MarkdownText.escape(choice["label"].text, atLineStart: false) + percentage
            }.joined(separator: "\n"))
        }

        let card = status["card"]
        if parts.isEmpty || (media.isEmpty && card.isObject) {
            if let url = card["url"].string, let title = card["title"].string, !title.isEmpty {
                parts.append(MarkdownText.link(MarkdownText.escape(title, atLineStart: false), url))
            }
        }

        if quoteDepth == 0, status["quote"].isObject {
            parts.append(quote(status["quote"]))
        }
        return parts.joined(separator: "\n\n")
    }

    /// A post rendered as a block quote with an attribution line.
    static func quote(_ status: JSONValue) -> String {
        let author = status["author"]
        let name = author["name"].string ?? author["screen_name"].text
        let handle = author["screen_name"].text
        let url = status["url"].string ?? "https://x.com/\(handle)/status/\(status["id"].text)"
        let label = handle.isEmpty ? MarkdownText.escape(name, atLineStart: false) : "\(MarkdownText.escape(name, atLineStart: false)) (@\(MarkdownText.escape(handle, atLineStart: false)))"
        var content = MarkdownText.link(label, url)
        let body = body(status, quoteDepth: 1)
        if !body.isEmpty { content += "\n\n" + body }
        return MarkdownText.quote(content)
    }

    /// Text from `raw_text` with facets, or the plain `text`.
    static func richText(_ status: JSONValue) -> String {
        let raw = status["raw_text"]
        guard raw.isObject, let source = raw["text"].string else {
            return MarkdownText.escape(status["text"].text.trimmed)
        }
        let scalars = Array(source.unicodeScalars)
        let range = raw["display_text_range"].items.compactMap(\.int)
        let start = range.count == 2 ? max(0, min(range[0], scalars.count)) : 0
        let end = range.count == 2 ? max(start, min(range[1], scalars.count)) : scalars.count

        // Rebuild the visible text: expand t.co links, drop media links.
        var view = String.UnicodeScalarView()
        var rich = RichText(text: "")
        var cursor = start
        var mapped = 0
        let facets = raw["facets"].items
            .compactMap { facet -> (JSONValue, Int, Int)? in
                let indices = facet["indices"].items.compactMap(\.int)
                guard indices.count == 2 else { return nil }
                return (facet, indices[0], indices[1])
            }
            .sorted { $0.1 < $1.1 }
        let articleURL = status["article"]["id"].string.map { "x.com/i/article/\($0)" }

        func append(_ string: String) {
            view.append(contentsOf: string.unicodeScalars)
            mapped += string.unicodeScalars.count
        }

        // Original offset ranges and where they ended up, to move style facets.
        var replaced: [(from: Int, to: Int, newFrom: Int, newTo: Int)] = []
        for (facet, from, to) in facets where from >= cursor && to <= end && from < to {
            let type = facet["type"].text
            if type == "bold" || type == "italic" {
                continue
            }
            append(slice(scalars, cursor, from))
            cursor = to
            let newFrom = mapped
            defer { replaced.append((from, to, newFrom, mapped)) }
            switch type {
            case "media":
                break
            case "url":
                let target = facet["replacement"].string ?? facet["expanded"].string ?? facet["original"].text
                if let articleURL, target.contains(articleURL) { break }
                let display = facet["display"].string ?? target
                let begin = mapped
                append(display)
                rich.links.append(.init(from: begin, to: mapped, href: target))
            case "mention":
                let original = slice(scalars, from, to)
                let handle = original.hasPrefix("@") ? String(original.dropFirst()) : (facet["original"].string ?? original)
                let begin = mapped
                append(original)
                rich.links.append(.init(from: begin, to: mapped, href: "https://x.com/\(handle)"))
            case "hashtag":
                let original = slice(scalars, from, to)
                let tag = original.hasPrefix("#") || original.hasPrefix("＃") ? String(original.dropFirst()) : original
                let begin = mapped
                append(original)
                rich.links.append(.init(from: begin, to: mapped, href: "https://x.com/hashtag/\(tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag)"))
            case "cashtag", "symbol":
                let original = slice(scalars, from, to)
                let begin = mapped
                append(original)
                rich.links.append(.init(from: begin, to: mapped, href: "https://x.com/search?q=\(original.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? original)"))
            default:
                append(slice(scalars, from, to))
            }
        }
        append(slice(scalars, cursor, end))

        // Bold/italic facets (long posts) index into the original text.
        func position(_ original: Int) -> Int {
            guard let last = replaced.last(where: { $0.from < original }) else { return original - start }
            return original >= last.to ? last.newTo + (original - last.to) : last.newFrom
        }
        for (facet, from, to) in facets where ["bold", "italic"].contains(facet["type"].text) {
            let newFrom = position(max(from, start))
            let newTo = position(min(to, end))
            if newTo > newFrom {
                rich.styles.append(.init(offset: newFrom, length: newTo - newFrom, style: facet["type"].text == "bold" ? "Bold" : "Italic"))
            }
        }

        rich.text = String(view).replacingOccurrences(of: "\r\n", with: "\n")
        let trimmedEnd = rich.text.trimmedEnd
        if trimmedEnd.unicodeScalars.count < rich.text.unicodeScalars.count { rich.text = trimmedEnd }
        let markdown = rich.markdown()
        return Self.paragraphs(markdown).trimmed
    }

    /// Single newlines become hard breaks; blank lines stay paragraph breaks.
    private static func paragraphs(_ markdown: String) -> String {
        markdown
            .components(separatedBy: "\n\n")
            .map { $0.trimmed.components(separatedBy: "\n").joined(separator: "  \n") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private static func slice(_ scalars: [Unicode.Scalar], _ from: Int, _ to: Int) -> String {
        guard to > from else { return "" }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[from..<to])
        return String(view)
    }

    static func plainText(_ status: JSONValue) -> String {
        var text = status["text"].text
        // FxTwitter appends expanded media and article links to `text`.
        text = text.jsReplace("\\s*https?://(?:x|twitter)\\.com/(?:i/article/\\d+|\\w+/status/\\d+/(?:photo|video)/\\d+)\\s*", "g", " ")
        return text.trimmed
    }

    /// The first line of the post, shortened, so a post never gets titled with
    /// its author's name or engagement counts.
    static func title(_ status: JSONValue) -> String {
        let text = plainText(status)
            .jsReplace("https?://\\S+", "g", "")
            .jsReplace("^(?:@\\w+\\s+)+", "", "")
        let firstLine = text.components(separatedBy: "\n").map(\.trimmed).first { !$0.isEmpty } ?? ""
        if !firstLine.isEmpty { return shorten(firstLine, limit: 100) }
        if let title = status["article"]["title"].string, !title.trimmed.isEmpty { return title.trimmed }
        let author = status["author"]
        let handle = author["screen_name"].text
        let name = author["name"].string ?? handle
        return handle.isEmpty ? name : "\(name) (@\(handle))"
    }

    private static func shorten(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = String(text.prefix(limit))
        // Prefer a word boundary for space-separated scripts.
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[..<space]).trimmed + "…"
        }
        return cut.trimmed + "…"
    }

    static func firstImage(_ status: JSONValue) -> String? {
        for item in status["media"]["all"].items {
            if item["type"].text == "photo", let url = item["url"].string { return url }
            if let thumbnail = item["thumbnail_url"].string { return thumbnail }
        }
        return nil
    }

    static func isoDate(_ status: JSONValue) -> String {
        if let timestamp = status["created_timestamp"].double {
            return iso(Date(timeIntervalSince1970: timestamp))
        }
        let raw = status["created_at"].text
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        if let date = formatter.date(from: raw) { return iso(date) }
        return normalizeISO(raw)
    }

    static func normalizeISO(_ raw: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return iso(date) }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return iso(date) }
        return raw
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func percent(_ value: Double) -> String {
        value.rounded() == value ? "\(Int(value))%" : String(format: "%.1f%%", value)
    }
}
