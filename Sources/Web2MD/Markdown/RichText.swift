import Foundation

/// Plain text plus style and link ranges, rendered to inline Markdown.
///
/// Offsets are Unicode scalar offsets, which is what Draft.js raw content and
/// Twitter entity indices use.
struct RichText {
    struct Style {
        var offset: Int
        var length: Int
        var style: String
    }

    struct Link {
        var from: Int
        var to: Int
        var href: String
    }

    var text: String
    var styles: [Style] = []
    var links: [Link] = []

    private static let styleOrder = ["Bold", "Italic", "Strikethrough", "Code"]
    private static let markers = ["Bold": "**", "Italic": "*", "Strikethrough": "~~", "Code": "`"]

    private struct Segment {
        var text: String
        var styles: Set<String>
        var link: Int?
    }

    /// Converts UTF-16 offsets to scalar offsets when the ranges only make sense
    /// as UTF-16 (some producers count that way).
    private func normalizedRanges() -> (styles: [Style], links: [Link]) {
        let scalarCount = text.unicodeScalars.count
        let utf16Count = text.utf16.count
        guard utf16Count > scalarCount else { return (styles, links) }
        let ends = styles.map { $0.offset + $0.length } + links.map(\.to)
        guard ends.contains(where: { $0 > scalarCount && $0 <= utf16Count }) else { return (styles, links) }
        var map: [Int] = []
        map.reserveCapacity(utf16Count + 1)
        for (index, scalar) in text.unicodeScalars.enumerated() {
            map.append(index)
            if scalar.value > 0xFFFF { map.append(index + 1) }
        }
        map.append(scalarCount)
        func convert(_ offset: Int) -> Int { map[max(0, min(offset, utf16Count))] }
        return (
            styles.map { Style(offset: convert($0.offset), length: convert($0.offset + $0.length) - convert($0.offset), style: $0.style) },
            links.map { Link(from: convert($0.from), to: convert($0.to), href: $0.href) }
        )
    }

    private func segments() -> [Segment] {
        let scalars = Array(text.unicodeScalars)
        let count = scalars.count
        let (styles, links) = normalizedRanges()
        func slice(_ start: Int, _ end: Int) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[start..<end])
            return String(view)
        }

        enum Kind: Int { case styleEnd = 0, linkEnd = 1, linkStart = 2, styleStart = 3 }
        struct Event {
            var position: Int
            var kind: Kind
            var style: String = ""
            var link: Int = -1
        }

        var events: [Event] = []
        for range in styles where Self.markers[range.style] != nil && range.length > 0 {
            let start = max(0, min(range.offset, count))
            let end = max(start, min(range.offset + range.length, count))
            events.append(Event(position: start, kind: .styleStart, style: range.style))
            events.append(Event(position: end, kind: .styleEnd, style: range.style))
        }
        // Drop links that overlap an earlier one.
        var lastEnd = -1
        for (index, link) in links.enumerated().sorted(by: { $0.element.from < $1.element.from }) {
            let start = max(0, min(link.from, count))
            let end = max(start, min(link.to, count))
            guard end > start, start >= lastEnd else { continue }
            lastEnd = end
            events.append(Event(position: start, kind: .linkStart, link: index))
            events.append(Event(position: end, kind: .linkEnd, link: index))
        }
        events.sort { $0.position != $1.position ? $0.position < $1.position : $0.kind.rawValue < $1.kind.rawValue }

        var result: [Segment] = []
        var active: [String: Int] = [:]
        var link: Int?
        var start = 0
        for event in events {
            if event.position > start {
                result.append(Segment(text: slice(start, event.position), styles: Set(active.filter { $0.value > 0 }.keys), link: link))
                start = event.position
            }
            switch event.kind {
            case .styleStart: active[event.style, default: 0] += 1
            case .styleEnd: active[event.style, default: 0] -= 1
            case .linkStart: link = event.link
            case .linkEnd: if link == event.link { link = nil }
            }
        }
        if start < count {
            result.append(Segment(text: slice(start, count), styles: Set(active.filter { $0.value > 0 }.keys), link: link))
        }
        return result
    }

    /// Inline Markdown. Markers hug the text: surrounding whitespace moves outside
    /// so `**bold **` never happens.
    func markdown() -> String {
        var result = ""
        var open: [String] = []
        var inLink: Int?

        func close(_ marker: String) {
            var trailing = ""
            while let last = result.last, last == " " || last == "\t" || last == "\n" || last == "\u{A0}" {
                trailing.insert(result.removeLast(), at: trailing.startIndex)
            }
            result += marker + trailing
        }
        func closeStyle() {
            guard let style = open.popLast() else { return }
            close(Self.markers[style] ?? "")
        }
        func closeLink() {
            while !open.isEmpty { closeStyle() }
            if let index = inLink {
                close("](\(MarkdownText.escapeURL(links[index].href)))")
                inLink = nil
            }
        }

        for segment in segments() {
            if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result += segment.text
                continue
            }
            if segment.link != inLink { closeLink() }
            if let firstInactive = open.firstIndex(where: { !segment.styles.contains($0) }) {
                while open.count > firstInactive { closeStyle() }
            }
            let body = segment.text.trimmingLeadingWhitespace()
            let leading = String(segment.text.prefix(segment.text.count - body.count))
            result += leading
            if let link = segment.link, inLink == nil {
                result += "["
                inLink = link
            }
            for style in Self.styleOrder where segment.styles.contains(style) && !open.contains(style) {
                result += Self.markers[style] ?? ""
                open.append(style)
            }
            let atLineStart = result.isEmpty || result.hasSuffix("\n")
            result += open.contains("Code") ? body : MarkdownText.escape(body, atLineStart: atLineStart)
        }
        closeLink()
        return result
    }
}

enum MarkdownText {
    /// Escapes characters that would otherwise turn plain text into Markdown syntax.
    static func escape(_ text: String, atLineStart: Bool = true) -> String {
        var output = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "~~", with: "\\~\\~")
        output = output.jsReplace("<(?=[A-Za-z/!?])", "g", "\\<")
        // Underscores only start emphasis at word edges.
        output = output.jsReplace("(?<![\\p{L}\\p{N}])_|_(?![\\p{L}\\p{N}])", "gu", "\\_")

        // Block syntax at the start of a line.
        let lines = output.components(separatedBy: "\n")
        return lines.enumerated().map { index, line in
            guard index > 0 || atLineStart else { return line }
            return line
                .jsReplace("^(\\s*)(#{1,6})(?=\\s|$)", "", "$1\\$2")
                .jsReplace("^(\\s*)>", "", "$1\\>")
                .jsReplace("^(\\s*)([-+])(?=\\s|$)", "", "$1\\$2")
                .jsReplace("^(\\s*)(-{3,}|={2,}|_{3,})\\s*$", "", "$1\\$2")
                .jsReplace("^(\\s*)(\\d+)([.)])(?=\\s|$)", "", "$1$2\\$3")
        }.joined(separator: "\n")
    }

    /// Makes a URL safe as a Markdown link or image target.
    static func escapeURL(_ url: String) -> String {
        url.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
    }

    static func escapeAlt(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .trimmed
    }

    static func image(_ url: String, alt: String = "") -> String {
        "![\(escapeAlt(alt))](\(escapeURL(url)))"
    }

    static func link(_ label: String, _ url: String) -> String {
        "[\(label)](\(escapeURL(url)))"
    }

    /// Prefixes every line with `> `.
    static func quote(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    }

    /// A fenced code block whose fence is longer than any backtick run inside.
    static func fence(_ code: String, language: String = "") -> String {
        var longest = 0
        var run = 0
        for character in code {
            if character == "`" { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\(language)\n\(code)\n\(fence)"
    }
}

extension String {
    func trimmingLeadingWhitespace() -> String {
        guard let index = firstIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(self[index...])
    }
}
