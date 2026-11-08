# Web2MD

Turn web pages into clean Markdown, on device, in Swift.

- **Generic extractor** — a port of [Defuddle](https://github.com/kepano/defuddle): finds the main content, strips clutter, standardizes footnotes, code, math, callouts and images, then converts to Markdown with Turndown's semantics. It matches Defuddle's output on 204 of its 226 test fixtures; the rest are site-specific extractors this package leaves to rules.
- **Site parsers through rules** — requests are routed by URL or page content to dedicated parsers, with the generic extractor as the fallback.
- **X (Twitter)** — posts, threads, quotes, media and long-form Articles with their cover image, headings, lists, quotes, code, embedded media and links.

Requires iOS 17 / macOS 14, Swift 6.

## Install

```swift
.package(url: "https://github.com/what1f/web2md-swift.git", from: "0.1.0")
```

## Use

```swift
import Web2MD

let web2md = Web2MD()
let doc = try await web2md.convert("https://x.com/sermakarevich/status/2106453816757354947")
print(doc.title, doc.author, doc.image)
print(doc.markdown)

// HTML you already have
let saved = try await web2md.convert(html: html, url: pageURL)
```

`Web2MDDocument` carries `title`, `author`, `site`, `published`, `description`, `image`, `language`, `favicon`, `markdown`, `html`, `wordCount`, the `parser` that produced it, and parser-specific `extras`.

## Routing

```
URL rules ──▶ (download) ──▶ page rules ──▶ generic extractor
```

1. Rules with only a URL matcher run first, before anything is downloaded — API-based parsers never fetch HTML.
2. Rules with a page matcher run on the downloaded DOM (for sites without a recognizable URL, like self-hosted Discourse).
3. If no rule matches, or a parser returns `nil` or throws, the generic extractor takes the page. Mark a rule `exclusive` to make its parser's failure final.

The page is downloaded and parsed at most once per request and shared by all matchers and parsers.

### Adding a parser

```swift
struct DiscourseParser: Web2MDParser {
    let name = "discourse"

    func parse(_ context: ParseContext) async throws -> Web2MDDocument? {
        let document = try await context.document()   // shared — clone before mutating
        guard let post = document.querySelector(".topic-post .cooked") else { return nil } // decline
        return Web2MDDocument(
            url: context.url,
            title: document.querySelector("title")?.textContent ?? "",
            markdown: MarkdownConverter.convert(post.innerHTML),
            parser: name
        )
    }
}

var web2md = Web2MD()
web2md.register(ParserRule(
    page: .meta("generator", contains: "Discourse"),
    parser: DiscourseParser()
))
```

Matchers compose with `and` / `or`:

| URL matcher | Page matcher |
| --- | --- |
| `.hosts(["x.com", "twitter.com"])` — host or subdomain | `.selector("article.post")` |
| `.path("^/\\w+/status/\\d+")` — regex on the path | `.meta("og:site_name", contains: "Substack")` |
| `.pattern("…")` — regex on the full URL | `PageMatcher { doc in … }` |
| `URLMatcher { url in … }` | |

`register` puts a rule ahead of the built-ins; pass `rules:` to `Web2MD(…)` to replace them entirely. `ParseContext.json(_:)` fetches JSON APIs through the same client. Supply your own `HTTPClient` for caching, proxies or tests.

## CLI

```sh
swift run web2md https://example.com/post
swift run web2md saved.html --url https://example.com/post --json
```

Options: `--json`, `--html` (cleaned HTML), `--no-cover`, `--lang <tag>`, `--replay <file>`.

## Conformance

`Tools/conformance/compare.py` runs the CLI over Defuddle's fixtures and compares the output with Defuddle's expected Markdown:

```sh
swift build -c release
python3 Tools/conformance/compare.py ~/path/to/defuddle [filter] [--diff]
```

## License

MIT. The generic extractor and Markdown conversion are derived from Defuddle by Steph Ango.
