import Foundation

/// Converts one kind of page into a document.
///
/// Return `nil` to decline (the next matching rule, then the generic parser, gets a turn).
/// Throw to report a failure; whether the router falls through depends on the rule.
public protocol Web2MDParser: Sendable {
    var name: String { get }
    func parse(_ context: ParseContext) async throws -> Web2MDDocument?
}

// MARK: - Matchers

/// Decides from the URL alone, before anything is downloaded.
public struct URLMatcher: Sendable {
    public let test: @Sendable (URL) -> Bool

    public init(_ test: @escaping @Sendable (URL) -> Bool) {
        self.test = test
    }

    /// Matches hosts exactly or as a parent domain (`x.com` matches `mobile.x.com`).
    public static func hosts(_ hosts: [String]) -> URLMatcher {
        let hosts = hosts.map { $0.lowercased() }
        return URLMatcher { url in
            guard let host = url.host?.lowercased() else { return false }
            return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }

    /// Regex tested against the URL path.
    public static func path(_ pattern: String) -> URLMatcher {
        URLMatcher { url in url.path.jsTest(pattern) }
    }

    /// Regex tested against the full URL string.
    public static func pattern(_ pattern: String, flags: String = "i") -> URLMatcher {
        URLMatcher { url in url.absoluteString.jsTest(pattern, flags) }
    }

    public func and(_ other: URLMatcher) -> URLMatcher {
        URLMatcher { url in test(url) && other.test(url) }
    }

    public func or(_ other: URLMatcher) -> URLMatcher {
        URLMatcher { url in test(url) || other.test(url) }
    }
}

/// Decides from the downloaded page, for sites that can't be recognized by URL
/// (self-hosted Discourse, Substack custom domains, ...).
public struct PageMatcher: Sendable {
    public let test: @Sendable (DOMDocument) -> Bool

    public init(_ test: @escaping @Sendable (DOMDocument) -> Bool) {
        self.test = test
    }

    /// Matches when the selector finds at least one element.
    public static func selector(_ selector: String) -> PageMatcher {
        PageMatcher { document in document.querySelector(selector) != nil }
    }

    /// Matches a `<meta name|property=... content=...>` whose content contains the given text.
    public static func meta(_ name: String, contains text: String) -> PageMatcher {
        PageMatcher { document in
            document.querySelectorAll("meta[name=\"\(name)\"], meta[property=\"\(name)\"]").contains {
                ($0.getAttribute("content") ?? "").range(of: text, options: .caseInsensitive) != nil
            }
        }
    }

    public func and(_ other: PageMatcher) -> PageMatcher {
        PageMatcher { document in test(document) && other.test(document) }
    }

    public func or(_ other: PageMatcher) -> PageMatcher {
        PageMatcher { document in test(document) || other.test(document) }
    }
}

// MARK: - Rules

/// Routes matching requests to a parser.
///
/// A rule with only a URL matcher runs before the page is downloaded, so API-based
/// parsers never fetch HTML. A rule with a page matcher runs after the download,
/// and both matchers must pass when both are set.
public struct ParserRule: Sendable {
    public var name: String
    public var url: URLMatcher?
    public var page: PageMatcher?
    public var parser: any Web2MDParser
    /// When true, a failure from this parser is final instead of falling back to
    /// the next rule and the generic parser. Use it when the generic output for
    /// that site is known to be wrong (e.g. X pages, where it picks up UI chrome).
    public var exclusive: Bool

    public init(
        _ name: String? = nil,
        url: URLMatcher? = nil,
        page: PageMatcher? = nil,
        exclusive: Bool = false,
        parser: any Web2MDParser
    ) {
        precondition(url != nil || page != nil, "A rule needs a URL or page matcher")
        self.name = name ?? parser.name
        self.url = url
        self.page = page
        self.parser = parser
        self.exclusive = exclusive
    }

    var needsPage: Bool { page != nil }
}

// MARK: - Context

/// Everything a parser needs. The page is downloaded at most once and shared.
public final class ParseContext: @unchecked Sendable {
    public let url: URL
    public let options: Web2MDOptions
    public let client: HTTPClient

    private let lock = NSLock()
    private var cachedPage: FetchedPage?
    private var cachedDocument: DOMDocument?
    private var pageTask: Task<FetchedPage, Error>?

    init(url: URL, options: Web2MDOptions, client: HTTPClient, page: FetchedPage? = nil) {
        self.url = url
        self.options = options
        self.client = client
        self.cachedPage = page
    }

    /// Whether the HTML has already been downloaded or supplied.
    public var hasPage: Bool {
        lock.withLock { cachedPage != nil }
    }

    /// The page HTML, downloading it on first use.
    public func page() async throws -> FetchedPage {
        let task: Task<FetchedPage, Error> = lock.withLock {
            if let cachedPage { return Task { cachedPage } }
            if let pageTask { return pageTask }
            let fetcher = PageFetcher(client: client, options: options)
            let url = self.url
            let task = Task { try await fetcher.fetch(url) }
            pageTask = task
            return task
        }
        let page = try await task.value
        lock.withLock { cachedPage = page }
        return page
    }

    /// The parsed page, shared between matchers and parsers. Don't mutate it;
    /// call `cloneDocument()` on it first.
    public func document() async throws -> DOMDocument {
        if let document = lock.withLock({ cachedDocument }) { return document }
        let page = try await page()
        let document = HTMLParser.parseDocument(page.html, url: page.url.absoluteString)
        lock.withLock { if cachedDocument == nil { cachedDocument = document } }
        return lock.withLock { cachedDocument! }
    }

    /// GET a URL and decode JSON. Returns nil on non-2xx or invalid JSON.
    public func json(_ url: URL, headers: [String: String] = [:]) async throws -> JSONValue? {
        var request = URLRequest(url: url, timeoutInterval: options.timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await client.data(for: request)
        guard (200..<300).contains(response.statusCode) else { return nil }
        return JSONValue.parse(data)
    }
}

// MARK: - Engine

/// Converts web pages to Markdown.
///
/// Requests go through `rules` in order; the first rule whose matchers pass gets
/// the request. When no rule matches, or a non-exclusive parser declines or
/// fails, `fallback` (the generic article extractor) handles the page.
public struct Web2MD: Sendable {
    public var rules: [ParserRule]
    public var fallback: any Web2MDParser
    public var client: HTTPClient
    public var options: Web2MDOptions

    /// Built-in site rules.
    public static var defaultRules: [ParserRule] { [XParser.rule] }

    public init(
        rules: [ParserRule] = Web2MD.defaultRules,
        fallback: any Web2MDParser = GenericParser(),
        client: HTTPClient = URLSessionHTTPClient(),
        options: Web2MDOptions = Web2MDOptions()
    ) {
        self.rules = rules
        self.fallback = fallback
        self.client = client
        self.options = options
    }

    /// Adds a rule ahead of the built-in ones.
    public mutating func register(_ rule: ParserRule) {
        rules.insert(rule, at: 0)
    }

    public func convert(_ url: URL) async throws -> Web2MDDocument {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
            throw Web2MDError.invalidURL
        }
        return try await route(ParseContext(url: url, options: options, client: client))
    }

    public func convert(_ string: String) async throws -> Web2MDDocument {
        guard let url = URL(string: string.trimmed) else { throw Web2MDError.invalidURL }
        return try await convert(url)
    }

    /// Converts HTML you already have. URL-only rules still apply, so an X URL
    /// with its HTML still goes to the X parser.
    public func convert(html: String, url: URL) async throws -> Web2MDDocument {
        let page = FetchedPage(url: url, html: html, contentType: "text/html")
        return try await route(ParseContext(url: url, options: options, client: client, page: page))
    }

    /// Name of the parser the URL would be routed to before downloading, or nil
    /// when routing depends on page content.
    public func parserName(for url: URL) -> String? {
        rules.first { !$0.needsPage && $0.url?.test(url) == true }?.parser.name
    }

    private func route(_ context: ParseContext) async throws -> Web2MDDocument {
        var lastError: Error?
        var tried = Set<Int>()

        func attempt(_ index: Int) async throws -> Web2MDDocument? {
            let rule = rules[index]
            tried.insert(index)
            do {
                if let document = try await rule.parser.parse(context), !document.markdown.trimmed.isEmpty {
                    return document
                }
                if rule.exclusive { throw lastError ?? Web2MDError.noContent }
            } catch {
                if error is CancellationError { throw error }
                if rule.exclusive { throw error }
                lastError = error
            }
            return nil
        }

        // URL-only rules first: they may avoid downloading the page at all.
        for (index, rule) in rules.enumerated() where !rule.needsPage {
            if rule.url?.test(context.url) == true, let document = try await attempt(index) {
                return document
            }
        }

        // Page rules need the DOM.
        if rules.contains(where: { $0.needsPage }) {
            let document = try await context.document()
            for (index, rule) in rules.enumerated() where rule.needsPage && !tried.contains(index) {
                guard rule.url?.test(context.url) ?? true, rule.page?.test(document) == true else { continue }
                if let result = try await attempt(index) { return result }
            }
        }

        do {
            if let document = try await fallback.parse(context), !document.markdown.trimmed.isEmpty {
                return document
            }
        } catch {
            if error is CancellationError { throw error }
            throw lastError ?? error
        }
        throw lastError ?? Web2MDError.noContent
    }
}
