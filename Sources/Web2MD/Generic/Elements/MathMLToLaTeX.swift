import Foundation

/// A small MathML → LaTeX converter covering presentation MathML that shows up
/// on article pages (KaTeX/MathJax output without a TeX annotation).
enum MathMLToLaTeX {
    static func convert(_ math: DOMElement) -> String {
        if let annotation = math.querySelector("annotation[encoding=\"application/x-tex\"]") {
            return annotation.textContent.trimmed
        }
        return render(children(math)).jsReplace(" {2,}", "g", " ").trimmed
    }

    private static func children(_ el: DOMElement) -> [DOMElement] { el.children }

    private static func render(_ nodes: [DOMElement]) -> String {
        var out = ""
        for node in nodes {
            let piece = render(node)
            if piece.isEmpty { continue }
            // Keep commands from fusing with following letters (\alpha x, not \alphax).
            if out.jsTest("\\\\[a-zA-Z]+$") && piece.jsTest("^[a-zA-Z]") { out += " " }
            out += piece
        }
        return out
    }

    private static func group(_ el: DOMElement?) -> String {
        guard let el else { return "{}" }
        let inner = render(el)
        return "{\(inner)}"
    }

    private static func script(_ el: DOMElement?) -> String {
        guard let el else { return "{}" }
        let inner = render(el)
        if inner.jsLength == 1 { return inner }
        return "{\(inner)}"
    }

    private static func render(_ el: DOMElement) -> String {
        let kids = children(el)
        switch el.localName {
        case "semantics":
            return kids.first.map(render) ?? ""
        case "annotation", "annotation-xml":
            return ""
        case "mi":
            let text = el.textContent.trimmed
            if text.jsLength > 1 && text.jsTest("^[a-zA-Z]+$") {
                return knownFunctions.contains(text) ? "\\\(text)" : "\\mathrm{\(text)}"
            }
            return symbol(text)
        case "mn":
            return el.textContent.trimmed
        case "mo":
            let text = el.textContent.trimmed
            return symbol(text)
        case "mtext":
            let text = el.textContent.jsReplace("\\s+", "g", " ")
            return text.trimmed.isEmpty ? "\\ " : "\\text{\(text)}"
        case "mspace":
            return "\\ "
        case "mfrac":
            if el.getAttribute("linethickness") == "0" {
                return "\\binom\(group(kids.first))\(group(kids.dropFirst().first))"
            }
            return "\\frac\(group(kids.first))\(group(kids.dropFirst().first))"
        case "msqrt":
            return "\\sqrt{\(render(kids))}"
        case "mroot":
            return "\\sqrt[\(kids.dropFirst().first.map(render) ?? "")]\(group(kids.first))"
        case "msup":
            return base(kids.first) + "^" + script(kids.dropFirst().first)
        case "msub":
            return base(kids.first) + "_" + script(kids.dropFirst().first)
        case "msubsup":
            return base(kids.first) + "_" + script(kids.dropFirst().first) + "^" + script(kids.dropFirst(2).first)
        case "munder":
            let under = kids.dropFirst().first
            if let b = kids.first, isLargeOperator(b) { return render(b) + "_" + script(under) }
            return "\\underset\(group(under))\(group(kids.first))"
        case "mover":
            let over = kids.dropFirst().first
            if let accent = over.map({ $0.textContent.trimmed }), let command = accents[accent] {
                return "\\\(command)\(group(kids.first))"
            }
            if let b = kids.first, isLargeOperator(b) { return render(b) + "^" + script(over) }
            return "\\overset\(group(over))\(group(kids.first))"
        case "munderover":
            return render(kids.first.map { [$0] } ?? []) + "_" + script(kids.dropFirst().first) + "^" + script(kids.dropFirst(2).first)
        case "mfenced":
            let open = el.getAttribute("open") ?? "("
            let close = el.getAttribute("close") ?? ")"
            let separator = el.getAttribute("separators") ?? ","
            return "\\left\(fence(open))" + kids.map(render).joined(separator: separator) + "\\right\(fence(close))"
        case "mtable":
            let rows = kids.filter { $0.localName == "mtr" || $0.localName == "mlabeledtr" }.map { row in
                row.children.filter { $0.localName == "mtd" }.map { render($0) }.joined(separator: " & ")
            }
            return "\\begin{matrix}" + rows.joined(separator: " \\\\ ") + "\\end{matrix}"
        case "menclose":
            return "\\boxed{\(render(kids))}"
        case "mphantom":
            return "\\phantom{\(render(kids))}"
        default:
            return render(kids)
        }
    }

    private static func base(_ el: DOMElement?) -> String {
        guard let el else { return "{}" }
        let text = render(el)
        if el.localName == "mrow" && kidsCount(el) > 1 { return "{\(text)}" }
        return text
    }

    private static func kidsCount(_ el: DOMElement) -> Int { el.children.count }

    private static func isLargeOperator(_ el: DOMElement) -> Bool {
        el.localName == "mo" && ["∑", "∏", "∫", "⋃", "⋂", "lim", "max", "min"].contains(el.textContent.trimmed)
    }

    private static func fence(_ text: String) -> String {
        switch text {
        case "{": "\\{"
        case "}": "\\}"
        case "": "."
        case "⟨": "\\langle"
        case "⟩": "\\rangle"
        case "|": "|"
        case "‖": "\\|"
        default: text
        }
    }

    private static let knownFunctions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "log", "ln", "exp", "lim", "max", "min", "sup", "inf", "det",
        "arg", "deg", "dim", "gcd", "hom", "ker", "Pr", "sinh", "cosh", "tanh", "arcsin", "arccos", "arctan",
    ]

    private static let accents: [String: String] = [
        "^": "hat", "ˆ": "hat", "~": "tilde", "˜": "tilde", "¯": "bar", "‾": "overline", "→": "vec", "˙": "dot",
        "¨": "ddot", "ˇ": "check",
    ]

    private static let symbols: [String: String] = [
        "α": "\\alpha", "β": "\\beta", "γ": "\\gamma", "δ": "\\delta", "ε": "\\epsilon", "ϵ": "\\epsilon",
        "ζ": "\\zeta", "η": "\\eta", "θ": "\\theta", "ι": "\\iota", "κ": "\\kappa", "λ": "\\lambda", "μ": "\\mu",
        "ν": "\\nu", "ξ": "\\xi", "π": "\\pi", "ρ": "\\rho", "σ": "\\sigma", "τ": "\\tau", "υ": "\\upsilon",
        "φ": "\\phi", "ϕ": "\\phi", "χ": "\\chi", "ψ": "\\psi", "ω": "\\omega", "Γ": "\\Gamma", "Δ": "\\Delta",
        "Θ": "\\Theta", "Λ": "\\Lambda", "Ξ": "\\Xi", "Π": "\\Pi", "Σ": "\\Sigma", "Φ": "\\Phi", "Ψ": "\\Psi",
        "Ω": "\\Omega", "∞": "\\infty", "∑": "\\sum", "∏": "\\prod", "∫": "\\int", "∮": "\\oint", "∂": "\\partial",
        "∇": "\\nabla", "±": "\\pm", "∓": "\\mp", "×": "\\times", "÷": "\\div", "·": "\\cdot", "⋅": "\\cdot",
        "∘": "\\circ", "≤": "\\leq", "≥": "\\geq", "≠": "\\neq", "≈": "\\approx", "≡": "\\equiv", "∼": "\\sim",
        "≅": "\\cong", "∝": "\\propto", "∈": "\\in", "∉": "\\notin", "⊂": "\\subset", "⊆": "\\subseteq",
        "⊃": "\\supset", "⊇": "\\supseteq", "∪": "\\cup", "∩": "\\cap", "∅": "\\emptyset", "∀": "\\forall",
        "∃": "\\exists", "¬": "\\neg", "∧": "\\wedge", "∨": "\\vee", "→": "\\to", "←": "\\leftarrow",
        "↔": "\\leftrightarrow", "⇒": "\\Rightarrow", "⇐": "\\Leftarrow", "⇔": "\\Leftrightarrow", "↦": "\\mapsto",
        "…": "\\ldots", "⋯": "\\cdots", "⋮": "\\vdots", "⋱": "\\ddots", "′": "'", "″": "''", "ℝ": "\\mathbb{R}",
        "ℕ": "\\mathbb{N}", "ℤ": "\\mathbb{Z}", "ℚ": "\\mathbb{Q}", "ℂ": "\\mathbb{C}", "ℓ": "\\ell", "ℏ": "\\hbar",
        "⟨": "\\langle", "⟩": "\\rangle", "∥": "\\parallel", "⊥": "\\perp", "√": "\\surd", "⊗": "\\otimes",
        "⊕": "\\oplus", "{": "\\{", "}": "\\}", "%": "\\%", "#": "\\#", "&": "\\&", "_": "\\_",
        "−": "-", "\u{2061}": "", "\u{2062}": "", "\u{2063}": "", "\u{2064}": "",
    ]

    private static func symbol(_ text: String) -> String {
        if let mapped = symbols[text] { return mapped }
        if text.unicodeScalars.count > 1 { return text.map { symbols[String($0)] ?? String($0) }.joined() }
        return text
    }
}
