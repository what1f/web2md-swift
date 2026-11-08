import Foundation

/// URL parsing that approximates the WHATWG URL standard (`new URL(input, base)`),
/// built on Foundation's RFC 3986 resolver.
struct WebURL {
    var href: String
    var scheme: String
    var host: String
    var port: Int?
    var pathname: String
    var search: String
    var hash: String

    var `protocol`: String { scheme + ":" }
    var hostname: String { host }
    var origin: String {
        guard Self.specialSchemes.contains(scheme), scheme != "file" else { return "null" }
        return "\(scheme)://\(host)\(port.map { ":\($0)" } ?? "")"
    }

    static let specialSchemes: Set<String> = ["http", "https", "ws", "wss", "ftp", "file"]
    private static let defaultPorts = ["http": 80, "https": 443, "ws": 80, "wss": 443, "ftp": 21]

    static func parse(_ input: String, base: String?) -> WebURL? {
        var text = input.trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}"..."\u{20}"))
        text = text.replacingOccurrences(of: "\t", with: "").replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")

        let schemeMatch = text.jsMatch("^([a-zA-Z][a-zA-Z0-9+.-]*):")
        let inputScheme = schemeMatch?[1]?.lowercased()
        var baseURL: URL?
        if let base, let parsedBase = parse(base, base: nil) { baseURL = URL(string: parsedBase.href) }

        let effectiveScheme = inputScheme ?? baseURL?.scheme?.lowercased()
        if let scheme = effectiveScheme, specialSchemes.contains(scheme) {
            // Special URLs treat backslashes as slashes (outside query/fragment).
            let cut = text.firstIndex { $0 == "?" || $0 == "#" } ?? text.endIndex
            text = text[..<cut].replacingOccurrences(of: "\\", with: "/") + text[cut...]
            // "http:example.com" relative to an http base, or "https:/x" → authority form.
            if let inputScheme, let match = text.jsMatch("^[a-zA-Z][a-zA-Z0-9+.-]*:/*") {
                let rest = text.jsSlice(match.length)
                if baseURL?.scheme?.lowercased() == inputScheme, !text.jsSlice(inputScheme.count + 1).hasPrefix("/") {
                    text = rest
                } else {
                    text = "\(inputScheme)://" + rest
                }
            }
        }

        if inputScheme == nil && baseURL == nil { return nil }
        let resolved: URL?
        if let baseURL, inputScheme == nil || text.jsMatch("^[a-zA-Z][a-zA-Z0-9+.-]*:") == nil {
            resolved = URL(string: text, relativeTo: baseURL)?.absoluteURL
        } else {
            resolved = URL(string: text)
        }
        guard let url = resolved, let scheme = url.scheme?.lowercased() else { return nil }
        return from(url, scheme: scheme)
    }

    private static func from(_ url: URL, scheme: String) -> WebURL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.scheme = scheme
        let special = specialSchemes.contains(scheme)
        if special && scheme != "file" && (components.host ?? "").isEmpty { return nil }
        if let host = components.percentEncodedHost { components.percentEncodedHost = host.lowercased() }
        if let port = components.port, defaultPorts[scheme] == port { components.port = nil }
        var path = components.percentEncodedPath
        if special && path.isEmpty { path = "/" }
        if special { path = normalizeDotSegments(path) }
        components.percentEncodedPath = path
        guard let href = components.string else { return nil }
        let query = components.percentEncodedQuery
        let fragment = components.percentEncodedFragment
        return WebURL(
            href: href,
            scheme: scheme,
            host: components.percentEncodedHost ?? "",
            port: components.port,
            pathname: path,
            search: query.map { $0.isEmpty ? "" : "?" + $0 } ?? "",
            hash: fragment.map { $0.isEmpty ? "" : "#" + $0 } ?? ""
        )
    }

    private static func normalizeDotSegments(_ path: String) -> String {
        guard path.contains("/.") else { return path }
        var output: [String] = []
        let segments = path.components(separatedBy: "/")
        for (index, segment) in segments.enumerated() {
            let lower = segment.lowercased()
            if segment == "." || lower == "%2e" {
                if index == segments.count - 1 { output.append("") }
            } else if segment == ".." || lower == ".%2e" || lower == "%2e." || lower == "%2e%2e" {
                if output.count > 1 { output.removeLast() }
                if index == segments.count - 1 { output.append("") }
            } else {
                output.append(segment)
            }
        }
        let joined = output.joined(separator: "/")
        return joined.hasPrefix("/") ? joined : "/" + joined
    }

    /// `new URL(input, base).href`, or nil when it would throw.
    static func resolve(_ input: String, base: String?) -> String? {
        parse(input, base: base)?.href
    }

    static func hostname(_ input: String) -> String? {
        parse(input, base: nil)?.host
    }
}
