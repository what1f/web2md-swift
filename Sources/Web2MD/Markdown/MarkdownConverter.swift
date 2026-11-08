// Port of defuddle src/markdown.ts.
// Copyright (c) 2025 Steph Ango (@kepano), MIT License.

import Foundation

/// Converts cleaned article HTML into Markdown (Obsidian-flavoured: callouts,
/// footnotes, `==highlight==`, `$math$`).
public enum MarkdownConverter {
    public static func convert(_ html: String) -> String {
        DefuddleTurndown().convert(html)
    }
}

private let mathMLNodeNames: Set<String> = [
    "annotation", "maction", "math", "menclose", "merror", "mfenced", "mfrac", "mi", "mmultiscripts", "mn", "mo",
    "mover", "mpadded", "mphantom", "mprescripts", "mroot", "mrow", "ms", "mspace", "msqrt", "mstyle", "msub",
    "msubsup", "msup", "mtable", "mtd", "mtext", "mtr", "munder", "munderover", "none", "semantics",
]
private let complexMathMLNodeNames: Set<String> = [
    "menclose", "mfrac", "mmultiscripts", "mover", "mroot", "msqrt", "msub", "msubsup", "msup", "mtable", "mtd",
    "mtr", "munder", "munderover",
]
private let inertVoidElements: Set<String> = [
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
]

private enum Format {
    static func escapeEntityLike(_ value: String) -> String {
        value.jsReplace("&(?=#\\d+;|#x[\\da-f]+;|[a-z][\\da-z]*;)", "gi", "&amp;")
    }

    static func percentEncode(_ char: String) -> String {
        char.utf8.map { String(format: "%%%02X", $0) }.joined()
    }

    static func linkDestination(_ href: String) -> String {
        if Utils.isDangerousURL(href) { return "" }
        let escaped = JSRegex("[<>\\u0000-\\u001f\\u007f]", "g").replace(
            escapeEntityLike(href).replacingOccurrences(of: "\\", with: "\\\\")
        ) { percentEncode($0.value) }
        if !escaped.jsTest("\\s") { return escaped.jsReplace("([()])", "g", "\\$1") }
        return "<\(escaped)>"
    }

    static func linkTitle(_ title: String?) -> String {
        guard let title, !title.isEmpty else { return "" }
        let clean = Utils.escapeHTML(title.jsReplace("[\\r\\n]+", "g", " ")).replacingOccurrences(of: "\\", with: "\\\\")
        return " \"\(clean)\""
    }

    static func footnoteId(_ id: String) -> String {
        var out = ""
        for unit in id.lowercased().utf16 {
            let isSafe = (0x61...0x7A).contains(unit) || (0x30...0x39).contains(unit) || unit == 0x5F || unit == 0x2D
            if isSafe {
                out.unicodeScalars.append(Unicode.Scalar(unit)!)
            } else {
                let hex = String(unit, radix: 16)
                out += "%" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
            }
        }
        return out
    }

    static func longestBacktickRun(_ code: String) -> Int {
        JSRegex("`+", "g").allMatches(code).map { $0.value.utf16.count }.max() ?? 0
    }

    static func fencedCode(_ code: String, language: String = "") -> String {
        let clean = code.trimmed
        let safeLanguage = (language.trimmed.jsSplit("\\s").first ?? "").replacingOccurrences(of: "`", with: "")
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(clean) + 1))
        return "\n\(fence)\(safeLanguage)\n\(clean)\n\(fence)\n"
    }

    static func codeSpan(_ code: String) -> String {
        let text = code.jsReplace("\\s*\\n\\s*", "g", " ").trimmed
        let fence = String(repeating: "`", count: longestBacktickRun(text) + 1)
        return "\(fence) \(text) \(fence)"
    }

    static let literalMathCommand = JSRegex(
        "\\\\(?:text[a-z]*|mbox|hbox|vbox|verb|url|href|operatorname|tag|label|ref|eqref)(?![a-z])", "i")

    static func math(_ latex: String, block: Bool) -> String {
        let tag = block
            ? "<(?=[!?/]|[a-z][a-z0-9-]*(?:[\\s/>]|$)|[a-z][a-z0-9+.-]*:)"
            : "<(?=[!?/]|[a-z][a-z0-9-]*[\\s/>]|[a-z][a-z0-9+.-]*:)"
        let safe = latex.jsReplace("\\n\\s*\\n", "g", "\n").jsReplace(tag, "gi", "< ").jsReplace("\\](?=[(:\\[])", "g", "] ")
        if safe != latex && literalMathCommand.test(latex) {
            return block ? "\n\(fencedCode(latex))\n" : codeSpan(latex)
        }
        return block ? "\n$$\n\(safe)\n$$\n" : "$\(safe)$"
    }

    static func embed(_ url: String) -> String { "\n![](\(linkDestination(url)))\n" }

    static func bestImageSrc(_ el: DOMElement) -> String {
        if let srcset = el.getAttribute("srcset"), !srcset.isEmpty {
            var bestURL = ""
            var bestWidth = 0
            var urlParts: [String] = []
            for token in srcset.trimmed.jsSplit("\\s+") {
                if let match = token.jsMatch("^(\\d+)w,?$") {
                    let width = jsParseInt(match[1]) ?? 0
                    if !urlParts.isEmpty && width > bestWidth {
                        let url = urlParts.joined(separator: " ").jsReplace("^,\\s*", "", "")
                        if !url.isEmpty && !Utils.isDangerousURL(url) {
                            bestWidth = width
                            bestURL = url
                        }
                    }
                    urlParts = []
                } else if token.jsTest("^\\d+(?:\\.\\d+)?x,?$") {
                    urlParts = []
                } else {
                    urlParts.append(token)
                }
            }
            if !bestURL.isEmpty { return bestURL }
        }
        return el.getAttribute("src") ?? ""
    }

    static func encodeMarkdownUnsafe(_ value: String) -> String {
        JSRegex("[\\n\\r&<>\"'`\\\\\\[\\]]", "g").replace(value) { "&#\($0.value.utf16.first.map(Int.init) ?? 0);" }
    }

    static func serializeInert(_ node: DOMNode) -> String {
        if let text = node as? DOMText { return encodeMarkdownUnsafe(text.data) }
        guard let el = node as? DOMElement else { return "" }
        let localName = el.localName
        if localName == "noembed" || localName == "noframes" { return "" }
        let children = el.childNodes.map(serializeInert).joined()
        let name = (localName == "xmp" || localName == "plaintext") ? "pre" : localName
        if !name.jsTest("^[A-Za-z][A-Za-z0-9-]*$") { return children }
        let attributes = el.attributes.filter { $0.name.jsTest("^[A-Za-z_:][A-Za-z0-9_.:-]*$") }
            .map { " \($0.name)=\"\(encodeMarkdownUnsafe($0.value))\"" }.joined()
        return inertVoidElements.contains(name.lowercased()) ? "<\(name)\(attributes)>" : "<\(name)\(attributes)>\(children)</\(name)>"
    }

    static func sanitizedOuterHTML(_ el: DOMElement) -> String {
        let clone = el.clone()
        return Utils.stripUnsafeElements(clone) ? "" : serializeInert(clone)
    }
}

private final class DefuddleTurndown: Turndown {
    override init() {
        super.init()
        keepNames = ["iframe", "video", "audio", "sup", "sub", "svg", "math"]
        removeNames = ["style", "script"]
        rules = customRules() + Self.defaultRules
    }

    func convert(_ html: String) -> String {
        var markdown = turndown(html.jsReplace("<wbr\\s*\\/?>", "gi", ""))
        if let match = markdown.jsMatch("^# .+\\n+") { markdown = markdown.jsSlice(match.length) }
        markdown = markdown.jsReplace("\\n*(?<!!)\\[\\]\\([^)]+\\)\\n*", "g", "")
        markdown = markdown.jsReplace("!(?=!\\[|\\[!\\[)", "g", "! ")
        markdown = markdown.jsReplace("\\n{3,}", "g", "\n\n")
        markdown = markdown.jsReplace("^([ \\t]*>[ \\t>]*)(?:\\n[ \\t]*>[ \\t>]*)+$", "gm", "$1")
        return markdown.trimmed
    }

    override func escape(_ text: String) -> String {
        let escaped = Turndown.escapeMarkdown(text)
        if !escaped.contains("<") { return escaped }
        let step = escaped
            .jsReplace("<(?=\\/?[A-Za-z][A-Za-z0-9-]*(?:\\s|\\/?>))", "g", "\\<")
            .jsReplace("<(?=[^<>\\s]*$)", "", "\\<")
        return JSRegex("<([^<>\\s]+)>", "g").replace(step) { match in
            Utils.isDangerousURL(match[1] ?? "", allowInlineImage: false) ? "\\" + match.value : match.value
        }
    }

    override func keepReplacement(_ el: DOMElement) -> String {
        let html = Format.sanitizedOuterHTML(el)
        return Turndown.isBlock(el) ? "\n\n" + html + "\n\n" : html
    }

    private func escapeInlineText(_ value: String) -> String {
        Format.escapeEntityLike(Turndown.escapeMarkdown(value.jsReplace("[\\r\\n]+", "g", " ")).replacingOccurrences(of: "<", with: "\\<"))
    }

    // MARK: - Default CommonMark rules (turndown)

    private static var defaultRules: [Rule] {
        var rules: [Rule] = []
        rules.append(Rule(["p"]) { content, _ in "\n\n" + content + "\n\n" })
        rules.append(Rule(["br"]) { _, _ in "  \n" })
        rules.append(Rule(["h1", "h2", "h3", "h4", "h5", "h6"]) { content, el in
            let level = Int(String(el.localName.dropFirst())) ?? 1
            return "\n\n" + String(repeating: "#", count: level) + " " + content + "\n\n"
        })
        rules.append(Rule(["blockquote"]) { content, _ in
            "\n\n" + Turndown.trimNewlines(content).jsReplace("^", "gm", "> ") + "\n\n"
        })
        rules.append(Rule(filter: isFencedCodeBlock) { _, el in fencedCodeBlock(el) })
        rules.append(Rule(["hr"]) { _, _ in "\n\n---\n\n" })
        rules.append(Rule(["em", "i"]) { content, _ in content.trimmed.isEmpty ? "" : "*" + content + "*" })
        rules.append(Rule(["strong", "b"]) { content, _ in content.trimmed.isEmpty ? "" : "**" + content + "**" })
        rules.append(Rule(filter: isInlineCode) { content, _ in inlineCode(content) })
        return rules
    }

    private static func isFencedCodeBlock(_ el: DOMElement) -> Bool {
        guard Turndown.isHTML(el, "pre"), let code = el.firstChild as? DOMElement else { return false }
        return Turndown.isHTML(code, "code")
    }

    private static func fencedCodeBlock(_ el: DOMElement) -> String {
        guard let code = el.firstElementChild else { return "" }
        let language = (code.getAttribute("class") ?? "").jsMatch("language-(\\S+)")?[1] ?? ""
        let text = code.textContent
        var fenceSize = 3
        for match in JSRegex("^`{3,}", "gm").allMatches(text) where match.length >= fenceSize { fenceSize = match.length + 1 }
        let fence = String(repeating: "`", count: fenceSize)
        return "\n\n" + fence + language + "\n" + text.jsReplace("\\n$", "", "") + "\n" + fence + "\n\n"
    }

    private static func isInlineCode(_ el: DOMElement) -> Bool {
        guard Turndown.isHTML(el, "code") else { return false }
        let hasSiblings = el.previousSibling != nil || el.nextSibling != nil
        let inPre = el.parentElement.map { Turndown.isHTML($0, "pre") } ?? false
        return !(inPre && !hasSiblings)
    }

    private static func inlineCode(_ content: String) -> String {
        if content.isEmpty { return "" }
        let text = content.jsReplace("\\r?\\n|\\r", "g", " ")
        let extraSpace = text.jsTest("^`|^ .*?[^ ].* $|`$") ? " " : ""
        let runs = Set(JSRegex("`+", "gm").allMatches(text).map(\.value))
        var delimiter = "`"
        while runs.contains(delimiter) { delimiter += "`" }
        return delimiter + extraSpace + text + extraSpace + delimiter
    }

    // MARK: - Defuddle rules (highest priority first)

    private func customRules() -> [Rule] {
        [
            Rule(filter: { $0.hasAttribute("data-callout") && $0.hasClass("callout") }) { [unowned self] in callout($1) },
            Rule(filter: { $0.hasClass("math") || $0.hasClass("katex") }) { _, el in Self.katex(el) },
            Rule(filter: { el in
                el.localName == "math" || el.hasClass("mwe-math-element") || el.hasClass("mwe-math-fallback-image-inline")
                    || el.hasClass("mwe-math-fallback-image-display")
            }) { _, el in Self.math(el) },
            Rule(filter: { Turndown.isHTML($0, "pre") }) { content, el in
                guard let code = el.querySelector("code") else { return content }
                let language = code.getAttribute("data-lang") ?? code.getAttribute("data-language")
                    ?? (code.getAttribute("class") ?? "").jsMatch("language-(\\w+)")?[1]
                    ?? el.getAttribute("data-language") ?? ""
                return Format.fencedCode(code.textContent, language: language)
            },
            Rule(filter: { ($0.getAttribute("href") ?? "").contains("#fnref") || $0.hasClass("footnote-backref") }) { _, _ in "" },
            Rule(filter: { Turndown.isHTML($0, "ol") && $0.parentElement?.getAttribute("id") == "footnotes" }) { [unowned self] in
                footnotesList($1)
            },
            Rule(filter: { Turndown.isHTML($0, "sup") && ($0.getAttribute("id") ?? "").hasPrefix("fnref:") }) { _, el in
                Self.citation(el)
            },
            Rule(filter: { Turndown.isHTML($0, "ol") && $0.hasClass("ltx_enumerate") }) { [unowned self] _, el in
                let items = el.children.enumerated().map { index, item in
                    let html = item.innerHTML.jsReplace("^<span class=\"ltx_tag ltx_tag_item\">\\d+\\.<\\/span>\\s*", "", "")
                    return "\(index + 1). \(turndown(html))"
                }
                return "\n\n" + items.joined(separator: "\n\n") + "\n\n"
            },
            Rule(filter: { el in
                Turndown.isHTML(el, "a") && el.childNodes.count > 1
                    && el.childNodes.contains { ($0 as? DOMElement).map { $0.localName.jsTest("^h[1-6]$") } ?? false }
            }) { [unowned self] _, el in
                let heading = el.querySelector("h1, h2, h3, h4, h5, h6")
                let headingContent = heading.map { turndown($0.outerHTML) } ?? ""
                heading?.remove()
                let remaining = turndown(el.innerHTML)
                var markdown = "\(headingContent)\n\n\(remaining)\n\n"
                let destination = Format.linkDestination(el.getAttribute("href") ?? "")
                if !destination.isEmpty {
                    markdown += "[View original](\(destination)\(Format.linkTitle(el.getAttribute("title"))))"
                }
                return markdown
            },
            Rule(["a"]) { content, el in
                guard let href = el.getAttribute("href"), !href.isEmpty else { return content }
                let destination = Format.linkDestination(href)
                if destination.isEmpty { return content }
                return "[\(content)](\(destination)\(Format.linkTitle(el.getAttribute("title"))))"
            },
            Rule(["del", "s", "strike"]) { content, _ in "~~" + content + "~~" },
            Rule(["mark"]) { content, _ in "==" + content + "==" },
            Rule(filter: { el in
                guard let src = el.getAttribute("src"), !src.isEmpty else { return false }
                return src.jsTest("(?:youtube\\.com|youtube-nocookie\\.com|youtu\\.be)") || src.jsTest("(?:twitter\\.com|x\\.com)")
            }) { content, el in Self.embed(content, el) },
            Rule(["img"]) { [unowned self] _, el in
                let alt = escapeInlineText(el.getAttribute("alt") ?? "")
                let src = Format.linkDestination(Format.bestImageSrc(el))
                return src.isEmpty ? "" : "![\(alt)](\(src)\(Format.linkTitle(el.getAttribute("title"))))"
            },
            Rule(["figure"]) { [unowned self] in figure($0, $1) },
            Rule(["li"]) { content, el in Self.listItem(content, el) },
            Rule(["ul", "ol"]) { content, el in
                let parentName = el.parentElement?.localName
                let isTopLevel = !(parentName == "ul" || parentName == "ol")
                return (isTopLevel ? "\n" : "") + content.trimmed + "\n"
            },
            Rule(["button"]) { content, _ in content },
            Rule(["table"]) { [unowned self] in table($0, $1) },
        ]
    }

    // MARK: Rule implementations

    private static func embed(_ content: String, _ el: DOMElement) -> String {
        let src = el.getAttribute("src") ?? ""
        if let id = src.jsMatch("(?:https?:\\/\\/)?(?:www\\.)?(?:youtube\\.com|youtube-nocookie\\.com|youtu\\.be)\\/(?:embed\\/|watch\\?v=)?([a-zA-Z0-9_-]+)")?[1] {
            return Format.embed("https://www.youtube.com/watch?v=\(id)")
        }
        if let match = src.jsMatch("(?:https?:\\/\\/)?(?:www\\.)?(?:twitter\\.com|x\\.com)\\/([A-Za-z0-9_]+)\\/status\\/([0-9]+)") {
            return Format.embed("https://x.com/\(match[1] ?? "")/status/\(match[2] ?? "")")
        }
        if let id = src.jsMatch("(?:https?:\\/\\/)?(?:platform\\.)?twitter\\.com\\/embed\\/Tweet\\.html\\?.*?id=([0-9]+)")?[1] {
            return Format.embed("https://x.com/i/status/\(id)")
        }
        return content
    }

    private static func listItem(_ input: String, _ el: DOMElement) -> String {
        var content = input
        var taskMarker = ""
        if el.hasClass("task-list-item"), let checkbox = el.querySelector("input[type=\"checkbox\"]") {
            content = content.jsReplace("<input[^>]*>", "", "")
            taskMarker = checkbox.hasAttribute("checked") ? "[x] " : "[ ] "
        }
        content = content.jsReplace("\\n+$", "", "").components(separatedBy: "\n").filter { !$0.isEmpty }.joined(separator: "\n\t")

        var level = 0
        var current = el.parentElement
        while let parent = current {
            if parent.localName == "ul" || parent.localName == "ol" {
                level += 1
            } else if parent.localName != "li" {
                break
            }
            current = parent.parentElement
        }
        var prefix = String(repeating: "\t", count: max(0, level - 1)) + "- "
        if let parent = el.parentElement, Turndown.isHTML(parent, "ol") {
            let index = (parent.children.firstIndex { $0 === el } ?? 0) + 1
            let start = parent.getAttribute("start").flatMap { Double($0.trimmed) }
            let number = start.map { String(Int($0) + index - 1) } ?? String(index)
            prefix = String(repeating: "\t", count: max(0, level - 1)) + number + ". "
        }
        let trailing = el.nextSibling != nil && !content.hasSuffix("\n") ? "\n" : ""
        return prefix + taskMarker + content.trimmed + trailing
    }

    private func figure(_ content: String, _ el: DOMElement) -> String {
        guard let img = el.querySelector("img") else { return content }
        let figcaption = el.querySelector("figcaption")
        let hasOutsideParagraphs = el.all("p").contains { p in
            var ancestor = p.parentElement
            while let a = ancestor, a !== el {
                if a.localName == "figcaption" { return false }
                ancestor = a.parentElement
            }
            return true
        }
        if hasOutsideParagraphs { return content }
        let alt = escapeInlineText(img.getAttribute("alt") ?? "")
        let src = Format.linkDestination(Format.bestImageSrc(img))
        var caption = ""
        if let figcaption {
            let tag = figcaption.querySelector(".ltx_tag_figure")?.textContent.trimmed ?? ""
            caption = "\(escapeInlineText(tag)) \(turndown(figcaption.innerHTML))".trimmed
        }
        return "\(src.isEmpty ? alt : "![\(alt)](\(src))")\n\n\(caption)\n\n"
    }

    private func callout(_ el: DOMElement) -> String {
        let rawType = el.getAttribute("data-callout") ?? "note"
        let type = rawType.jsTest("^[a-z0-9_-]+$", "i") ? rawType : "note"
        let fold = el.getAttribute("data-callout-fold")
        let foldIndicator = fold == "-" || fold == "+" ? fold! : ""
        var titleText = el.querySelector(".callout-title-inner")?.textContent.trimmed ?? ""
        if titleText.isEmpty { titleText = type.prefix(1).uppercased() + type.dropFirst() }
        let title = escapeInlineText(titleText)
        el.querySelector(".callout-title")?.remove()
        let body = turndown((el.querySelector(".callout-content") ?? el).innerHTML)
        let quoted = body.trimmed.components(separatedBy: "\n").map { "> \($0)" }.joined(separator: "\n")
        return "\n\n> [!\(type)]\(foldIndicator) \(title)\n\(quoted)\n\n"
    }

    private func footnotesList(_ el: DOMElement) -> String {
        let references = el.children.map { li -> String in
            var id: String?
            if let liId = li.getAttribute("id") {
                if liId.hasPrefix("fn:") {
                    id = String(liId.dropFirst(3))
                } else {
                    id = (liId.components(separatedBy: "/").last ?? "").jsMatch("cite_note-(.+)")?[1] ?? liId
                }
            }
            if let sup = li.querySelector("sup"), sup.textContent.trimmed == id { sup.remove() }
            let content = turndown(li.innerHTML).jsReplace("\\s*↩︎$", "", "").trimmed
            return "[^\(Format.footnoteId(id ?? ""))]: \(content)"
        }
        return "\n\n" + references.joined(separator: "\n\n") + "\n\n"
    }

    private static func citation(_ el: DOMElement) -> String {
        let referenceId = String((el.getAttribute("id") ?? "").dropFirst("fnref:".count))
        let href = el.querySelector("a[href^=\"#fn:\"]")?.getAttribute("href") ?? ""
        let fragment = String(href.dropFirst("#fn:".count))
        let linkedId = fragment.removingPercentEncoding ?? fragment
        let primaryId: String
        if !linkedId.isEmpty {
            primaryId = linkedId
        } else if el.ownerDocument?.getElementById("fn:\(referenceId)") != nil {
            primaryId = referenceId
        } else {
            primaryId = referenceId.jsReplace("-\\d+$", "", "")
        }
        return "[^\(Format.footnoteId(primaryId))]"
    }

    private func table(_ content: String, _ el: DOMElement) -> String {
        if el.hasClass("ltx_equation") || el.hasClass("ltx_eqn_table") || el.hasClass("numblk") {
            return Self.nestedEquations(el)
        }
        let hasNestedTables = !el.all("table").isEmpty
        let directCells = el.all("td, th").filter { Utils.isDirectTableChild($0, el) }
        if hasNestedTables || directCells.count <= 1 {
            let directRows = el.all("tr").filter { Utils.isDirectTableChild($0, el) }
            let cellCounts = directRows.map { row in directCells.filter { $0.parentNode === row }.count }
            let isSingleColumn = !directRows.isEmpty && Set(cellCounts).count == 1 && cellCounts[0] <= 1
            if isSingleColumn || hasNestedTables {
                return "\n\n" + turndown(directCells.map(\.innerHTML).joined()) + "\n\n"
            }
        }
        if el.all("td, th").contains(where: { $0.hasAttribute("colspan") || $0.hasAttribute("rowspan") }) {
            return "\n\n" + Self.cleanupTableHTML(el) + "\n\n"
        }
        let rows: [[String]] = el.all("tr").filter { Utils.isDirectTableChild($0, el) }.map { row in
            row.children.filter { $0.localName == "td" || $0.localName == "th" }.map { cell in
                turndown(cell.innerHTML).replacingOccurrences(of: "\n", with: " ").trimmed
                    .replacingOccurrences(of: "|", with: "\\|")
            }
        }
        if rows.isEmpty { return content }
        let columns = rows.map(\.count).max() ?? 0
        if columns == 0 { return content }
        func format(_ cells: [String]) -> String {
            "| " + (cells + Array(repeating: "", count: max(0, columns - cells.count))).joined(separator: " | ") + " |"
        }
        let separator = "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |"
        let lines = [format(rows[0]), separator] + rows.dropFirst().map(format)
        return "\n\n" + lines.joined(separator: "\n") + "\n\n"
    }

    private static func cleanupTableHTML(_ el: DOMElement) -> String {
        let allowed: Set<String> = [
            "src", "href", "style", "align", "width", "height", "rowspan", "colspan", "bgcolor", "scope", "valign", "headers",
        ]
        let clone = el.clone()
        for node in [clone] + clone.descendantElements() {
            for name in node.attributeNames where !allowed.contains(name) { node.removeAttribute(name) }
        }
        return Utils.stripUnsafeElements(clone) ? "" : Format.serializeInert(clone)
    }

    private static func nestedEquations(_ el: DOMElement) -> String {
        el.all("math").map { math -> String in
            let annotation = math.querySelector("annotation[encoding=\"application/x-tex\"]")?.textContent.trimmed
            let latex = (annotation?.isEmpty == false ? annotation : nil) ?? math.getAttribute("alttext")?.trimmed
            guard let latex, !latex.isEmpty else { return "" }
            let isInline = math.closest(".ltx_eqn_inline, .mwe-math-element-inline") != nil
            return Format.math(latex, block: !isInline)
        }.joined(separator: "\n\n")
    }

    private static func katex(_ el: DOMElement) -> String {
        var latex = el.getAttribute("data-latex") ?? ""
        if latex.isEmpty {
            latex = el.querySelector(".katex-mathml annotation[encoding=\"application/x-tex\"]")?.textContent ?? ""
        }
        if latex.isEmpty { latex = el.textContent.trimmed }
        let mathElement = el.querySelector(".katex-mathml math")
        let isInline = el.hasClass("math-inline") || (mathElement != nil && mathElement?.getAttribute("display") != "block")
        return Format.math(latex, block: !isInline)
    }

    private static func math(_ el: DOMElement) -> String {
        var latex = extractLatex(el).trimmed
        let isInTable = el.closest("table") != nil
        let parent = el.parentElement
        let isBlock = !isInTable && (
            el.getAttribute("display") == "block"
                || el.hasClass("mwe-math-fallback-image-display")
                || isOnlyMathInParagraph(el)
                || (parent?.hasClass("mwe-math-element") == true
                    && (parent?.previousSibling as? DOMElement)?.localName == "p")
        )
        if isBlock {
            latex = formatBlockLatex(latex)
            return Format.math(latex, block: true)
        }
        let prev = el.previousSibling
        let next = el.nextSibling
        let prevChar = prev.map { String($0.textContent.suffix(1)) } ?? ""
        let nextChar = next.map { String($0.textContent.prefix(1)) } ?? ""
        let isStartOfLine = prev == nil || (prev!.isText && prev!.textContent.trimmed.isEmpty)
        let isEndOfLine = next == nil || (next!.isText && next!.textContent.trimmed.isEmpty)
        let text = el.textContent
        let left = !isStartOfLine && !text.jsTest("^\\s") && prevChar.jsTest("[\\p{L}\\p{N}]") ? " " : ""
        let right = !isEndOfLine && !text.jsTest("\\s$") && nextChar.jsTest("[\\p{L}\\p{N}]") ? " " : ""
        return left + Format.math(latex, block: false) + right
    }

    private static func extractLatex(_ el: DOMElement) -> String {
        if let annotation = el.querySelector("annotation[encoding=\"application/x-tex\"]")?.textContent.trimmed,
           !annotation.isEmpty {
            return annotation
        }
        let latex = el.getAttribute("data-latex")
        let alttext = el.getAttribute("alttext")
        let hasMathML = el.children.contains { $0.namespace == .mathml || mathMLNodeNames.contains($0.localName) }
        let hasComplex = hasComplexMathML(el)
        if let latex, !latex.isEmpty, !hasMathML || isTrustworthyLatex(latex, hasComplex) { return latex.trimmed }
        if let alttext, !alttext.isEmpty, !hasMathML || isTrustworthyLatex(alttext, hasComplex) { return alttext.trimmed }
        if el.localName == "math" && hasMathML {
            let converted = MathMLToLaTeX.convert(el)
            if !converted.isEmpty { return converted }
        }
        if let latex, !latex.isEmpty { return latex.trimmed }
        if let alttext, !alttext.isEmpty { return alttext.trimmed }
        return ""
    }

    private static func hasComplexMathML(_ el: DOMElement) -> Bool {
        complexMathMLNodeNames.contains(el.localName) || el.children.contains(where: hasComplexMathML)
    }

    private static func isTrustworthyLatex(_ value: String, _ hasComplex: Bool) -> Bool {
        if value.jsTest("\\\\[a-zA-Z]+|[_^{}]|[$&]|\\\\\\\\|\\\\begin\\{") { return true }
        let trimmed = value.trimmed
        if trimmed.isEmpty || hasComplex { return false }
        return !trimmed.jsTest("[a-zA-Z]{3,}-[a-zA-Z]{2,}")
    }

    private static func formatBlockLatex(_ value: String) -> String {
        let latex = value.trimmed
        if latex.isEmpty { return latex }
        let environment = "\\\\begin\\{[^}]+\\}"
        if let bare = latex.jsMatch("^\\\\begin\\{matrix\\}([\\s\\S]*?)\\\\end\\{matrix\\}$"), !(bare[1] ?? "").jsTest(environment) {
            return "\\begin{aligned}\n\((bare[1] ?? "").trimmed)\n\\end{aligned}"
        }
        if latex.jsTest(environment) { return latex }
        if latex.contains("\\\\") || latex.contains("&") { return "\\begin{aligned}\n\(latex)\n\\end{aligned}" }
        return latex
    }

    private static func isOnlyMathInParagraph(_ el: DOMElement) -> Bool {
        guard let parent = el.parentElement, parent.localName == "p" else { return false }
        guard parent.children.count == 1, parent.children[0] === el else { return false }
        return parent.childNodes.allSatisfy { $0 === el || ($0.isText && $0.textContent.trimmed.isEmpty) }
    }
}
