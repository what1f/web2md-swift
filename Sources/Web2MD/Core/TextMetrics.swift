import Foundation

public enum TextMetrics {
    /// Word count where each CJK character counts as one word.
    public static func countWords(_ text: String) -> Int {
        var cjk = 0
        var words = 0
        var inWord = false
        for code in text.utf16 {
            if (0x3040...0x309F).contains(code) || (0x30A0...0x30FF).contains(code)
                || (0x3400...0x4DBF).contains(code) || (0x4E00...0x9FFF).contains(code)
                || (0xF900...0xFAFF).contains(code) || (0xAC00...0xD7AF).contains(code) {
                cjk += 1
                inWord = false
            } else if code <= 32 {
                inWord = false
            } else if !inWord {
                words += 1
                inWord = true
            }
        }
        return cjk + words
    }

    /// Word count of an HTML string without building a DOM.
    public static func countHTMLWords(_ html: String) -> Int {
        let text = html
            .jsReplace("<[^>]*>", "g", " ")
            .jsReplace("&nbsp;", "gi", " ")
            .jsReplace("&amp;", "gi", "&")
            .jsReplace("&lt;", "gi", "<")
            .jsReplace("&gt;", "gi", ">")
            .jsReplace("&quot;", "gi", "\"")
            .jsReplace("&#\\d+;", "g", " ")
            .jsReplace("&\\w+;", "g", " ")
        return countWords(text)
    }
}
