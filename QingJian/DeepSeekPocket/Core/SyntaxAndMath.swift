import Foundation

/// Lightweight, zero-dependency syntax tokenizer for code blocks in answers.
enum CodeSyntaxTokenizer {
    enum TokenKind: Equatable, Sendable {
        case plain, keyword, typeName, stringLiteral, numberLiteral, comment
    }

    struct Token: Equatable, Sendable {
        let text: String
        let kind: TokenKind
    }

    private static let keywords: Set<String> = [
        "func", "let", "var", "struct", "class", "enum", "protocol", "extension",
        "import", "return", "if", "else", "guard", "switch", "case", "default",
        "for", "while", "in", "break", "continue", "try", "catch", "throw", "throws",
        "async", "await", "private", "fileprivate", "internal", "public", "static",
        "final", "override", "mutating", "self", "Self", "nil", "true", "false",
        "def", "from", "as", "with", "yield", "lambda", "pass", "raise", "None", "True", "False",
        "const", "function", "export", "new", "this", "null", "undefined", "interface", "type",
        "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "DELETE", "JOIN", "ON", "GROUP", "BY", "ORDER"
    ]

    static func parseHeaderAndBody(_ segment: String) -> (language: String?, body: String) {
        guard let newline = segment.firstIndex(of: "\n") else { return (nil, segment) }
        let first = segment[..<newline].trimmingCharacters(in: .whitespaces)
        if first.isEmpty || (!first.contains(" ") && first.count < 24) {
            let lang = first.isEmpty ? nil : first.uppercased()
            return (lang, String(segment[segment.index(after: newline)...]))
        }
        return (nil, segment)
    }

    static func tokenize(_ code: String, language: String?) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(code)
        let n = chars.count
        var i = 0
        let hashCommentLangs: Set<String> = ["PY", "PYTHON", "SH", "BASH", "ZSH", "YAML", "YML", "RUBY", "RB"]
        let usesHashComment = language.map { hashCommentLangs.contains($0.uppercased()) } ?? false

        func flushPlain(_ buf: inout String) {
            if !buf.isEmpty {
                tokens.append(Token(text: buf, kind: .plain))
                buf = ""
            }
        }

        var plain = ""
        while i < n {
            let c = chars[i]
            // Line comment // or #
            if (c == "/" && i + 1 < n && chars[i + 1] == "/") || (usesHashComment && c == "#") {
                flushPlain(&plain)
                let start = i
                while i < n && chars[i] != "\n" { i += 1 }
                tokens.append(Token(text: String(chars[start..<i]), kind: .comment))
                continue
            }
            // Block comment /* ... */
            if c == "/" && i + 1 < n && chars[i + 1] == "*" {
                flushPlain(&plain)
                let start = i
                i += 2
                while i + 1 < n && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i = min(n, i + 2)
                tokens.append(Token(text: String(chars[start..<i]), kind: .comment))
                continue
            }
            // String literal "..." or '...'
            if c == "\"" || c == "'" {
                flushPlain(&plain)
                let quote = c
                let start = i
                i += 1
                while i < n {
                    if chars[i] == "\\" && i + 1 < n {
                        i += 2
                        continue
                    }
                    if chars[i] == quote {
                        i += 1
                        break
                    }
                    if chars[i] == "\n" { break }
                    i += 1
                }
                tokens.append(Token(text: String(chars[start..<i]), kind: .stringLiteral))
                continue
            }
            // Number
            if c.isNumber && (i == 0 || !isIdentChar(chars[i - 1])) {
                flushPlain(&plain)
                let start = i
                while i < n && (chars[i].isNumber || chars[i] == "." || chars[i] == "x" || chars[i] == "_" || (chars[i] >= "a" && chars[i] <= "f") || (chars[i] >= "A" && chars[i] <= "F")) {
                    i += 1
                }
                tokens.append(Token(text: String(chars[start..<i]), kind: .numberLiteral))
                continue
            }
            // Identifier / keyword / Type
            if isIdentStart(c) {
                flushPlain(&plain)
                let start = i
                while i < n && isIdentChar(chars[i]) { i += 1 }
                let word = String(chars[start..<i])
                if keywords.contains(word) {
                    tokens.append(Token(text: word, kind: .keyword))
                } else if let first = word.first, first.isUppercase, word.count > 1 {
                    tokens.append(Token(text: word, kind: .typeName))
                } else {
                    tokens.append(Token(text: word, kind: .plain))
                }
                continue
            }
            plain.append(c)
            i += 1
        }
        flushPlain(&plain)
        return tokens
    }

    private static func isIdentStart(_ c: Character) -> Bool {
        c == "_" || c.isLetter
    }

    private static func isIdentChar(_ c: Character) -> Bool {
        c == "_" || c.isLetter || c.isNumber
    }
}

/// Converts common LaTeX math expressions (`$$...$$`, `\(...\)`) into clean Unicode math notation
/// without requiring JavaScript/MathJax web views.
enum MathFormatter {
    private static let replacements: [(String, String)] = [
        ("\\Rightarrow", "⇒"), ("\\Leftarrow", "⇐"), ("\\Leftrightarrow", "⇔"),
        ("\\rightarrow", "→"), ("\\leftarrow", "←"), ("\\leftrightarrow", "↔"),
        ("\\to", "→"), ("\\mapsto", "↦"),
        ("\\infty", "∞"), ("\\partial", "∂"), ("\\nabla", "∇"),
        ("\\sum", "∑"), ("\\prod", "∏"), ("\\int", "∫"),
        ("\\approx", "≈"), ("\\neq", "≠"), ("\\ne", "≠"),
        ("\\leq", "≤"), ("\\le", "≤"), ("\\geq", "≥"), ("\\ge", "≥"),
        ("\\times", "×"), ("\\cdot", "·"), ("\\div", "÷"), ("\\pm", "±"), ("\\mp", "∓"),
        ("\\in", "∈"), ("\\notin", "∉"), ("\\subset", "⊂"), ("\\subseteq", "⊆"),
        ("\\cup", "∪"), ("\\cap", "∩"), ("\\emptyset", "∅"),
        ("\\forall", "∀"), ("\\exists", "∃"), ("\\neg", "¬"),
        ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"), ("\\delta", "δ"),
        ("\\epsilon", "ε"), ("\\varepsilon", "ε"), ("\\zeta", "ζ"), ("\\eta", "η"),
        ("\\theta", "θ"), ("\\iota", "ι"), ("\\kappa", "κ"), ("\\lambda", "λ"),
        ("\\mu", "μ"), ("\\nu", "ν"), ("\\xi", "ξ"), ("\\pi", "π"),
        ("\\rho", "ρ"), ("\\sigma", "σ"), ("\\tau", "τ"), ("\\phi", "φ"),
        ("\\varphi", "φ"), ("\\chi", "χ"), ("\\psi", "ψ"), ("\\omega", "ω"),
        ("\\Gamma", "Γ"), ("\\Delta", "Δ"), ("\\Theta", "Θ"), ("\\Lambda", "Λ"),
        ("\\Xi", "Ξ"), ("\\Pi", "Π"), ("\\Sigma", "Σ"), ("\\Phi", "Φ"),
        ("\\Psi", "Ψ"), ("\\Omega", "Ω"),
        ("\\sqrt", "√"), ("\\ldots", "…"), ("\\cdots", "⋯"),
        ("\\left", ""), ("\\right", "")
    ]

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "n": "ⁿ", "i": "ⁱ"
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "i": "ᵢ", "j": "ⱼ", "n": "ₙ", "k": "ₖ"
    ]

    static func format(_ latex: String) -> String {
        var s = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        // Simplify \frac{a}{b} -> (a)/(b)
        while let fracRange = s.range(of: "\\frac") {
            let afterFrac = s[fracRange.upperBound...].drop(while: { $0 == " " })
            if let (num, rest1) = readBraceGroup(afterFrac),
               let (den, rest2) = readBraceGroup(rest1.drop(while: { $0 == " " })) {
                let replacement = "(\(num))/(\(den))"
                s = String(s[..<fracRange.lowerBound]) + replacement + String(rest2)
            } else {
                break
            }
        }
        for (cmd, uni) in replacements {
            s = s.replacingOccurrences(of: cmd, with: uni)
        }
        s = applyScripts(s, trigger: "^", map: superscripts)
        s = applyScripts(s, trigger: "_", map: subscripts)
        return s
    }

    private static func readBraceGroup(_ slice: Substring) -> (String, Substring)? {
        guard slice.first == "{" else { return nil }
        var depth = 0
        var idx = slice.startIndex
        let contentStart = slice.index(after: idx)
        while idx < slice.endIndex {
            let ch = slice[idx]
            if ch == "{" { depth += 1 }
            else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return (String(slice[contentStart..<idx]), slice[slice.index(after: idx)...])
                }
            }
            idx = slice.index(after: idx)
        }
        return nil
    }

    private static func applyScripts(_ input: String, trigger: Character, map: [Character: Character]) -> String {
        var out = ""
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            if chars[i] == trigger && i + 1 < chars.count {
                if chars[i + 1] == "{" {
                    var j = i + 2
                    var group = ""
                    while j < chars.count && chars[j] != "}" {
                        group.append(chars[j])
                        j += 1
                    }
                    if j < chars.count && chars[j] == "}" && !group.isEmpty && group.allSatisfy({ map[$0] != nil }) {
                        out.append(contentsOf: group.compactMap { map[$0] })
                        i = j + 1
                        continue
                    }
                } else if let mapped = map[chars[i + 1]] {
                    out.append(mapped)
                    i += 2
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }
}
