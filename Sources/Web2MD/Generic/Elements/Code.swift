// Port of defuddle src/elements/code.ts.
// Copyright (c) 2025 Steph Ango (@kepano), MIT License.

import Foundation

enum CodeElements {
    private static let highlighterPatterns: [JSRegex] = [
        JSRegex("^language-(\\w+)$"),
        JSRegex("^lang-(\\w+)$"),
        JSRegex("^(\\w+)-code$"),
        JSRegex("^code-(\\w+)$"),
        JSRegex("^syntax-(\\w+)$"),
        JSRegex("^code-snippet__(\\w+)$"),
        JSRegex("^highlight-(\\w+)$"),
        JSRegex("^(\\w+)-snippet$"),
        JSRegex("(?:^|\\s)(?:language|lang|brush|syntax)-(\\w+)(?:\\s|$)", "i"),
    ]

    static let codeLanguages: Set<String> = [
        "abap", "actionscript", "ada", "adoc", "agda", "antlr4", "applescript", "arduino", "armasm", "asciidoc",
        "aspnet", "atom", "bash", "batch", "c", "clojure", "cmake", "cobol", "coffeescript", "cpp", "c++", "crystal",
        "csharp", "cs", "dart", "django", "dockerfile", "dotnet", "elixir", "elm", "erlang", "fortran", "fsharp",
        "gdscript", "gitignore", "glsl", "golang", "gradle", "graphql", "groovy", "haskell", "hs", "haxe", "hlsl",
        "html", "idris", "java", "javascript", "js", "jsx", "jsdoc", "json", "jsonp", "julia", "kotlin", "latex",
        "lean", "lean4", "lisp", "elisp", "livescript", "lua", "makefile", "markdown", "md", "markup", "masm",
        "mathml", "matlab", "mongodb", "mysql", "nasm", "nginx", "nim", "nix", "objc", "ocaml", "pascal", "perl",
        "php", "postgresql", "powershell", "prolog", "puppet", "python", "regex", "rss", "ruby", "rb", "rust",
        "scala", "scheme", "shell", "sh", "solidity", "sparql", "sql", "ssml", "svg", "swift", "tcl", "terraform",
        "tex", "toml", "typescript", "ts", "tsx", "unrealscript", "verilog", "vhdl", "webassembly", "wasm", "xml",
        "yaml", "yml", "zig",
    ]

    static let selector = [
        "pre", "div[class*=\"prismjs\"]", ".syntaxhighlighter", ".highlight", ".highlight-source",
        ".wp-block-syntaxhighlighter-code", ".wp-block-code", "div[class*=\"language-\"]", ".code-block[data-lang]",
        "code.hl.block",
    ].joined(separator: ", ")

    private static let lineSelector = "div[class*=\"line\"], span[class*=\"line\"], .ec-line, [data-line-number], [data-line]"

    static func language(of element: DOMElement) -> String {
        if let dataLang = element.getAttribute("data-lang") ?? element.getAttribute("data-language") ?? element.getAttribute("language"),
           !dataLang.isEmpty {
            return dataLang.lowercased()
        }
        let classNames = element.classList
        if element.hasClass("syntaxhighlighter"),
           let langClass = classNames.first(where: { $0 != "syntaxhighlighter" && $0 != "nogutter" }),
           codeLanguages.contains(langClass.lowercased()) {
            return langClass.lowercased()
        }
        for className in classNames {
            for pattern in highlighterPatterns {
                if let match = pattern.firstMatch(className.lowercased()), let lang = match[1], !lang.isEmpty,
                   codeLanguages.contains(lang.lowercased()) {
                    return lang.lowercased()
                }
            }
        }
        for className in classNames where codeLanguages.contains(className.lowercased()) {
            return className.lowercased()
        }
        return ""
    }

    private static func extractWordPressContent(_ element: DOMElement) -> String {
        if let container = element.querySelector(".syntaxhighlighter table .code .container") {
            return container.children.map { line in
                let parts = line.all("code").map { code -> String in
                    let text = code.textContent
                    return code.hasClass("spaces") ? String(repeating: " ", count: text.jsLength) : text
                }.joined()
                return parts.isEmpty ? line.textContent : parts
            }.joined(separator: "\n")
        }
        let lines = element.all(".code .line")
        if !lines.isEmpty {
            return lines.map { line in
                let parts = line.all("code").map(\.textContent).joined()
                return parts.isEmpty ? line.textContent : parts
            }.joined(separator: "\n")
        }
        return ""
    }

    static func extractStructuredText(_ node: DOMNode) -> String {
        if node.isText {
            if let parent = node.parentElement, parent.querySelector("[data-line], .line") != nil, node.textContent.trimmed.isEmpty {
                return ""
            }
            return node.textContent
        }
        guard let element = node as? DOMElement else { return "" }
        if element.matches(".hover-info, .hover-container") { return "" }
        if element.tagName == "BUTTON" || element.tagName == "STYLE" { return "" }
        if element.tagName == "BR" {
            if let prev = element.previousElementSibling, prev.matches(lineSelector) { return "" }
            return "\n"
        }
        if element.matches("span.lnt") || element.matches("span.lineno")
            || element.matches(".react-syntax-highlighter-line-number") || element.matches(".rouge-gutter") {
            return ""
        }
        if element.tagName == "DIV" || element.tagName == "SPAN", element.children.count == 2 {
            let gutter = element.children[0].textContent.trimmed
            if gutter.jsTest("^\\d+$") {
                return extractStructuredText(element.children[1]).jsReplace("\\n$", "", "") + "\n"
            }
        }
        if element.matches(lineSelector) {
            if let container = element.querySelector(".code:not(.token), .content:not(.token), [class*=\"code-\"], [class*=\"content-\"]") {
                return container.textContent.jsReplace("\\n$", "", "") + "\n"
            }
            if let lineNumber = element.querySelector(".line-number, .gutter, [class*=\"line-number\"], [class*=\"gutter\"]") {
                let text = element.childNodes.filter { !lineNumber.contains($0) }.map(extractStructuredText).joined()
                return text.jsReplace("\\n$", "", "") + "\n"
            }
            return element.textContent.jsReplace("\\n$", "", "") + "\n"
        }
        return element.childNodes.map(extractStructuredText).joined()
    }

    static func dedent(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var minIndent = Int.max
        let nonSpace = JSRegex("\\S")
        for line in lines {
            if let match = nonSpace.firstMatch(line) { minIndent = min(minIndent, match.index) }
        }
        if minIndent == Int.max || minIndent == 0 { return text }
        return lines.map { $0.jsSlice(minIndent) }.joined(separator: "\n")
    }

    static let rules: [StandardizationRule] = [
        StandardizationRule(selector: selector) { el, doc in
            for button in el.all("button, [class*=\"codeblock-button\"]") { button.remove() }
            for chrome in el.all("[class*=\"header\"], [class*=\"toolbar\"], [class*=\"titlebar\"], [class*=\"title-bar\"]") {
                guard chrome.tagName == "DIV" || chrome.tagName == "SPAN" else { continue }
                if let lineAncestor = chrome.closest("[data-line], .line"), el.contains(lineAncestor) { continue }
                if chrome.querySelector("[data-line], .line, pre") != nil { continue }
                if Utils.countWords(chrome.textContent.trimmed) <= 5 { chrome.remove() }
            }

            var lang = ""
            var current: DOMElement? = el
            while let element = current, lang.isEmpty {
                lang = language(of: element)
                if lang.isEmpty && element === el,
                   let codeEl = element.querySelector("code[data-lang], code[class*=\"language-\"]") ?? element.querySelector("code") {
                    lang = language(of: codeEl)
                }
                current = element.parentElement
            }

            let cmContent = el.querySelector(".cm-content")
            if let cmContent, lang.isEmpty {
                for div in el.all("div") where !div.contains(cmContent) {
                    let text = div.textContent.trimmed.lowercased()
                    if !text.isEmpty && codeLanguages.contains(text) {
                        lang = text
                        break
                    }
                }
            }

            var content = ""
            if el.matches(".syntaxhighlighter, .wp-block-syntaxhighlighter-code") { content = extractWordPressContent(el) }
            if content.isEmpty, let cmContent {
                content = extractStructuredText(cmContent)
            } else if content.isEmpty {
                var target = el
                if el.tagName != "PRE" && el.tagName != "CODE" {
                    let pres = el.all("pre")
                    if let codePre = pres.first(where: { $0.querySelector("code[data-lang], code[class*=\"language-\"], .line, [data-line]") != nil })
                        ?? pres.first(where: { $0.querySelector("span[class]") != nil && !$0.hasClass("lineno") }) {
                        target = codePre
                    }
                }
                content = extractStructuredText(target)
            }

            if el.matches("code.hl.block") {
                content = content
                    .jsReplace("^[ \\t]+|[ \\t]+$", "g", "")
                    .replacingOccurrences(of: "\t", with: "    ")
                    .replacingOccurrences(of: "\u{00A0}", with: " ")
                    .jsReplace("^\\n+", "", "")
            } else {
                content = content.replacingOccurrences(of: "\t", with: "    ").replacingOccurrences(of: "\u{00A0}", with: " ")
                content = dedent(content)
                content = content
                    .jsReplace("^\\s+|\\s+$", "g", "")
                    .jsReplace("\\n{3,}", "g", "\n\n")
                    .jsReplace("^\\n+", "", "")
                    .jsReplace("\\n+$", "", "")
            }

            var ancestor: DOMElement? = el
            for _ in 0..<3 {
                guard let a = ancestor, let container = a.parentElement, container.tagName != "BODY" else { break }
                if container.children.count > 5 { break }
                if container.closest("[data-callout]") != nil { break }
                for sibling in container.children where !sibling.contains(el) {
                    guard sibling.tagName == "DIV" || sibling.tagName == "SPAN" else { continue }
                    if Utils.countWords(sibling.textContent.trimmed) <= 5
                        && sibling.querySelector("pre, code, img, svg, table, h1, h2, h3, h4, h5, h6, p, blockquote, ul, ol, hr") == nil {
                        sibling.remove()
                    }
                }
                ancestor = container
            }

            let pre = doc.createElement("pre")
            if el.matches("code.hl.block, pre.hl.lean.lean-output") { pre.setAttribute("data-verso-code", "true") }
            let code = doc.createElement("code")
            if !lang.isEmpty {
                code.setAttribute("data-lang", lang)
                code.setAttribute("class", "language-\(lang)")
            }
            code.textContent = content
            pre.appendChild(code)
            return pre
        },
    ]
}
