import Foundation

/// Reads posts through the public FxTwitter API (https://github.com/FxEmbed/FxEmbed),
/// which returns X articles as raw Draft.js content.
struct FxTwitterAPI {
    static let host = "https://api.fxtwitter.com"
    static let userAgent = "Mozilla/5.0 (compatible; Web2MD/1.0; +https://github.com/what1f/web2md-swift)"

    let context: ParseContext

    struct Conversation {
        var status: JSONValue
        /// The author's own thread, oldest first. Contains `status` itself.
        var thread: [JSONValue]
    }

    func conversation(id: String, user: String?) async throws -> Conversation {
        var lastError: Error?
        do {
            if let json = try await get("/2/thread/\(id)"), json["status"].isObject {
                let thread = json["thread"].items.filter(\.isObject)
                return Conversation(status: json["status"], thread: thread.isEmpty ? [json["status"]] : thread)
            }
        } catch {
            if error is CancellationError { throw error }
            lastError = error
        }
        if let status = try await status(id: id, user: user) {
            return Conversation(status: status, thread: [status])
        }
        throw lastError ?? Web2MDError.unavailable("This post is unavailable")
    }

    /// A single post (v2, then v1).
    func status(id: String, user: String? = nil) async throws -> JSONValue? {
        if let json = try? await get("/2/status/\(id)"), json["status"].isObject {
            return json["status"]
        }
        if let json = try await get("/\(user ?? "i")/status/\(id)"), json["tweet"].isObject {
            return json["tweet"]
        }
        return nil
    }

    private func get(_ path: String) async throws -> JSONValue? {
        guard let url = URL(string: Self.host + path) else { return nil }
        var headers = ["User-Agent": Self.userAgent]
        if let language = context.options.language { headers["Accept-Language"] = language }
        return try await context.json(url, headers: headers)
    }
}
