import Foundation

/// The result of converting a web page.
public struct Web2MDDocument: Sendable, Equatable {
    public var url: URL
    public var title: String
    public var author: String
    public var site: String
    /// ISO 8601 date or date-time, empty when unknown.
    public var published: String
    public var description: String
    /// Cover or lead image URL, empty when there is none.
    public var image: String
    public var language: String
    public var favicon: String
    public var markdown: String
    /// Cleaned article HTML when the parser produced HTML first.
    public var html: String?
    public var wordCount: Int
    /// Name of the parser that produced this document.
    public var parser: String
    /// Parser-specific values (e.g. `authorHandle` for X).
    public var extras: [String: String]

    public init(
        url: URL,
        title: String = "",
        author: String = "",
        site: String = "",
        published: String = "",
        description: String = "",
        image: String = "",
        language: String = "",
        favicon: String = "",
        markdown: String,
        html: String? = nil,
        wordCount: Int? = nil,
        parser: String,
        extras: [String: String] = [:]
    ) {
        self.url = url
        self.title = title
        self.author = author
        self.site = site
        self.published = published
        self.description = description
        self.image = image
        self.language = language
        self.favicon = favicon
        self.markdown = markdown
        self.html = html
        self.wordCount = wordCount ?? TextMetrics.countWords(markdown)
        self.parser = parser
        self.extras = extras
    }
}

public struct Web2MDOptions: Sendable {
    /// Preferred content language (BCP 47), sent as `Accept-Language`.
    public var language: String?
    /// Include replies and comments from site-specific parsers.
    public var includeReplies: Bool
    /// Drop images from the generic pipeline output.
    public var removeImages: Bool
    /// Put the cover image at the top of the Markdown when a parser knows it.
    public var includeCoverImage: Bool
    /// Request timeout in seconds.
    public var timeout: TimeInterval
    /// Maximum page size in bytes.
    public var maxPageBytes: Int
    /// User agent for page requests; per-host overrides apply when nil.
    public var userAgent: String?

    public init(
        language: String? = nil,
        includeReplies: Bool = false,
        removeImages: Bool = false,
        includeCoverImage: Bool = true,
        timeout: TimeInterval = 20,
        maxPageBytes: Int = 5 * 1024 * 1024,
        userAgent: String? = nil
    ) {
        self.language = language
        self.includeReplies = includeReplies
        self.removeImages = removeImages
        self.includeCoverImage = includeCoverImage
        self.timeout = timeout
        self.maxPageBytes = maxPageBytes
        self.userAgent = userAgent
    }
}

public enum Web2MDError: Error, Sendable, Equatable, LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case notHTML(String)
    case tooLarge
    case decodingFailed
    case noContent
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid URL"
        case .httpStatus(let code): "Request failed with HTTP \(code)"
        case .notHTML(let type): "Not an HTML page (\(type))"
        case .tooLarge: "Page too large"
        case .decodingFailed: "Could not decode page"
        case .noContent: "No readable content"
        case .unavailable(let reason): reason
        }
    }
}
