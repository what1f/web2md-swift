import Foundation

/// Transport used for every request the SDK makes. Swap it to add caching,
/// proxies, cookies or test doubles.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Web2MDError.unavailable("No HTTP response") }
        return (data, http)
    }
}

/// A fetched HTML page.
public struct FetchedPage: Sendable {
    /// URL after redirects.
    public var url: URL
    public var html: String
    public var contentType: String
}

enum UserAgents {
    static let browser =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    static let reader = "Mozilla/5.0 (compatible; Web2MD/1.0; +https://github.com/what1f/web2md-swift)"
    /// Hosts that serve complete server-rendered pages to crawlers.
    static let readerHosts = ["github.com"]

    static func forURL(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if readerHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return reader }
        return browser
    }
}

struct PageFetcher {
    let client: HTTPClient
    let options: Web2MDOptions

    func fetch(_ url: URL) async throws -> FetchedPage {
        var request = URLRequest(url: url, timeoutInterval: options.timeout)
        request.setValue(options.userAgent ?? UserAgents.forURL(url), forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let language = options.language { request.setValue(language, forHTTPHeaderField: "Accept-Language") }
        let (data, response) = try await client.data(for: request)
        guard (200..<300).contains(response.statusCode) else { throw Web2MDError.httpStatus(response.statusCode) }
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? ""
        let lowered = contentType.lowercased()
        if !lowered.isEmpty, !lowered.contains("html"), !lowered.contains("xml") {
            throw Web2MDError.notHTML(contentType)
        }
        guard data.count <= options.maxPageBytes else { throw Web2MDError.tooLarge }
        guard let html = HTMLDecoding.decode(data, contentType: contentType) else { throw Web2MDError.decodingFailed }
        return FetchedPage(url: response.url ?? url, html: html, contentType: contentType)
    }
}

/// Turns raw page bytes into text, honoring BOMs, the Content-Type charset and `<meta charset>`.
public enum HTMLDecoding {
    public static func decode(_ data: Data, contentType: String) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data, encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16BigEndian) }
        let charset = charset(fromContentType: contentType) ?? sniffMetaCharset(data)
        if let charset, let encoding = encoding(for: charset), encoding != .utf8,
           let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    static func charset(fromContentType value: String) -> String? {
        guard let match = value.jsMatch("charset=[\"']?([\\w.:-]+)", "i") else { return nil }
        return match[1]
    }

    static func sniffMetaCharset(_ data: Data) -> String? {
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        if let match = head.jsMatch("<meta[^>]+charset\\s*=\\s*[\"']?\\s*([\\w.:-]+)", "i") { return match[1] }
        return nil
    }

    static func encoding(for charset: String) -> String.Encoding? {
        let name = charset.lowercased()
        switch name {
        case "utf-8", "utf8": return .utf8
        case "iso-8859-1", "latin1", "us-ascii", "ascii", "windows-1252", "cp1252": return .windowsCP1252
        case "gb2312", "gbk", "gb18030", "x-gbk":
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard cf != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }
}
