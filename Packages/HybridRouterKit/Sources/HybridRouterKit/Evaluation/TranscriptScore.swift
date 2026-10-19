import Foundation

/// How closely a speech-to-text transcript matches what the speaker read out, for checking
/// voice input before it reaches the router.
public struct TranscriptScore: Equatable, Sendable {
    /// Words the transcript got wrong, inserted or dropped, compared with the reference.
    public var wordErrors: Int
    /// Words in the reference.
    public var referenceWords: Int

    /// Word error rate: errors per reference word. 0 is perfect; it can exceed 1.
    public var wordErrorRate: Double {
        referenceWords == 0 ? 0 : Double(wordErrors) / Double(referenceWords)
    }

    /// Scores `transcript` against `reference`, ignoring case and punctuation.
    public init(reference: String, transcript: String) {
        let expected = Self.words(reference)
        let heard = Self.words(transcript)
        wordErrors = Self.editDistance(expected, heard)
        referenceWords = expected.count
    }

    /// Lowercased words without punctuation, with equivalent forms written one way, so only
    /// real mistakes count: speech-to-text writes "17 times 24" as "17×24", "72 degrees
    /// Fahrenheit" as "72°F" and "250 dollars" as "$250", and may spell "summarize" the
    /// British way. Apostrophes inside a word stay ("r's", "don't").
    static func words(_ text: String) -> [String] {
        let normalized = Self.spelledOut(text.lowercased().replacingOccurrences(of: "’", with: "'"))
            .map { character -> Character in
                character.isLetter || character.isNumber || "'.".contains(character) ? character : " "
            }
        return String(normalized)
            .split(separator: " ")
            .map { word in
                // Keep decimal points ("2.5") but drop sentence-ending periods and stray quotes.
                word.trimmingCharacters(in: CharacterSet(charactersIn: ".'"))
            }
            .filter { !$0.isEmpty }
    }

    /// Symbols, units and currencies as words; number words up to twenty as digits; British
    /// "-ise", "-our" and "-tre" spellings as American. Applied to both texts, so a
    /// rewrite can never turn a difference into a match it shouldn't.
    static func spelledOut(_ text: String) -> String {
        var text = text
        for (pattern, template) in rewrites {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        return text.split(separator: " ", omittingEmptySubsequences: false)
            .map { numberWords[String($0)] ?? String($0) }
            .joined(separator: " ")
    }

    private static let rewrites: [(NSRegularExpression, String)] = [
        (#"(\d)\s*[×x*]\s*(\d)"#, "$1 times $2"),
        (#"(\d)\s*÷\s*(\d)"#, "$1 divided by $2"),
        (#"(\d)\s*\+\s*(\d)"#, "$1 plus $2"),
        (#"(\d)\s*=\s*"#, "$1 equals "),
        (#"(\d)\s*%"#, "$1 percent"),
        (#"°\s*f\b"#, " degrees fahrenheit"),
        (#"°\s*c\b"#, " degrees celsius"),
        (#"°"#, " degrees"),
        (#"\$\s*(\d[\d,.]*)"#, "$1 dollars"),
        (#"€\s*(\d[\d,.]*)"#, "$1 euros"),
        (#"£\s*(\d[\d,.]*)"#, "$1 pounds"),
        (#"(\d),(\d{3})\b"#, "$1$2"),
        (#"\b(\w{2,})is(e|es|ed|ing|ation|ations)\b"#, "$1iz$2"),
        (#"\b(\w{2,})our(s|ed|ing|ite|ites)?\b"#, "$1or$2"),
        (#"\b(\w{3,})tre(s)?\b"#, "$1ter$2"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    private static let numberWords: [String: String] = Dictionary(uniqueKeysWithValues: [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty",
    ].enumerated().map { ($0.element, String($0.offset)) })

    /// Word-level Levenshtein distance.
    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for (i, word) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, other) in b.enumerated() {
                current[j + 1] = min(
                    previous[j + 1] + 1,                       // dropped
                    current[j] + 1,                            // inserted
                    previous[j] + (word == other ? 0 : 1)      // replaced
                )
            }
            previous = current
        }
        return previous[b.count]
    }
}
