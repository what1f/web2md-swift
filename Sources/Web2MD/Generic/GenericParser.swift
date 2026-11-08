import Foundation

/// The fallback parser: defuddle's article extraction followed by Markdown conversion.
public struct GenericParser: Web2MDParser {
    public let name = "generic"

    public init() {}

    public func parse(_ context: ParseContext) async throws -> Web2MDDocument? {
        let page = try await context.page()
        let box = UncheckedBox(try await context.document().cloneDocument())
        let options = context.options
        let url = page.url
        return try await Self.onLargeStack {
            Self.convert(box.value, url: url, options: options)
        }
    }

    static func convert(_ document: DOMDocument, url: URL, options: Web2MDOptions) -> Web2MDDocument? {
        var engineOptions = DefuddleOptions()
        engineOptions.removeImages = options.removeImages
        let result = DefuddleEngine(document: document, url: url.absoluteString, options: engineOptions).parse()
        var markdown = MarkdownConverter.convert(result.content)
        let meta = result.metadata
        if options.includeCoverImage, result.coverRemoved, !meta.image.isEmpty, !options.removeImages {
            markdown = "![](\(meta.image))\n\n" + markdown
        }
        if markdown.trimmed.isEmpty { return nil }
        return Web2MDDocument(
            url: url,
            title: meta.title,
            author: meta.author,
            site: meta.site,
            published: meta.published,
            description: meta.description,
            image: meta.image,
            language: meta.language,
            favicon: meta.favicon,
            markdown: markdown,
            html: result.content,
            parser: "generic"
        )
    }

    /// The DOM passes are recursive; deeply nested pages overflow the default
    /// 512 KB secondary-thread stack.
    static func onLargeStack<T: Sendable>(_ work: @escaping @Sendable () -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: work())
            }
            thread.stackSize = 64 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}

/// Hands a value that is only touched by one thread at a time across an isolation boundary.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
