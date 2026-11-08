import Foundation
import Web2MD

let usage = """
Usage:
  web2md <url>                      Convert a web page
  web2md <file.html> --url <url>    Convert a saved page
Options:
  --json        Print the document as JSON
  --html        Print cleaned HTML instead of Markdown (generic parser)
  --no-cover    Leave the cover image out of the Markdown
  --lang <tag>  Preferred language
  --replay <f>  Answer requests from a JSON file of {"<url>": <response body>}
"""

var arguments = Array(CommandLine.arguments.dropFirst())
@MainActor func flag(_ name: String) -> Bool {
    guard let index = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: index)
    return true
}
@MainActor func value(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

let asJSON = flag("--json")
let asHTML = flag("--html")
let noCover = flag("--no-cover")
let language = value("--lang")
let pageURL = value("--url")
let replayFile = value("--replay")

/// Serves saved responses; unknown URLs get a 404.
struct ReplayClient: HTTPClient {
    let responses: [String: Data]

    init(file: String) throws {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any] ?? [:]
        var responses: [String: Data] = [:]
        for (url, body) in object {
            if let text = body as? String { responses[url] = Data(text.utf8) }
            else { responses[url] = try JSONSerialization.data(withJSONObject: body) }
        }
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let body = responses[url.absoluteString]
        let type = body.map { $0.first == UInt8(ascii: "{") ? "application/json" : "text/html" } ?? "text/plain"
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: ["Content-Type": type])!
        return (body ?? Data(), response)
    }
}

guard let input = arguments.first else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}

var options = Web2MDOptions(language: language)
options.includeCoverImage = !noCover
let client: HTTPClient
if let replayFile {
    do { client = try ReplayClient(file: replayFile) } catch {
        FileHandle.standardError.write(Data("web2md: cannot read \(replayFile)\n".utf8))
        exit(2)
    }
} else {
    client = URLSessionHTTPClient()
}
let engine = Web2MD(client: client, options: options)

@MainActor func run() async -> Int32 {
    do {
        let document: Web2MDDocument
        if FileManager.default.fileExists(atPath: input) {
            let data = try Data(contentsOf: URL(fileURLWithPath: input))
            guard let html = HTMLDecoding.decode(data, contentType: "") else { throw Web2MDError.decodingFailed }
            let url = URL(string: pageURL ?? "https://example.com/") ?? URL(string: "https://example.com/")!
            document = try await engine.convert(html: html, url: url)
        } else {
            document = try await engine.convert(input)
        }
        if asJSON {
            var object: [String: Any] = [
                "url": document.url.absoluteString, "title": document.title, "author": document.author,
                "site": document.site, "published": document.published, "description": document.description,
                "image": document.image, "language": document.language, "favicon": document.favicon,
                "wordCount": document.wordCount, "parser": document.parser, "markdown": document.markdown,
                "extras": document.extras,
            ]
            if let html = document.html { object["html"] = html }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: data, as: UTF8.self))
        } else if asHTML {
            print(document.html ?? "")
        } else {
            print("---")
            for (key, value) in [("title", document.title), ("author", document.author), ("site", document.site),
                                 ("published", document.published), ("image", document.image), ("parser", document.parser)]
                where !value.isEmpty {
                print("\(key): \(value)")
            }
            print("---\n")
            print(document.markdown)
        }
        return 0
    } catch {
        FileHandle.standardError.write(Data("web2md: \(error.localizedDescription)\n".utf8))
        return 1
    }
}

exit(await run())
