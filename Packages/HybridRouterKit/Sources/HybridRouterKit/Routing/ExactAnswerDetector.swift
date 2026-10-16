import Foundation

/// Spots questions with one exact answer that the on-device model often gets wrong: counting
/// letters or words, arithmetic, date and time maths, and unit conversions. It reads only the
/// prompt's wording, so it runs in microseconds and needs no model.
///
/// Tuned on the 175 development prompts in Evals/quality_benchmark.json: it fires on 12% of
/// them, the on-device answer fails on 52% of those (36% elsewhere), and it catches 7 of the
/// 11 prompts the classifier kept on-device that then failed.
public enum ExactAnswerDetector {
    public enum Kind: String, CaseIterable, Sendable {
        case counting, arithmetic, datesAndTimes, conversions

        /// For the route badge, after "Needs an exact answer".
        public var label: String {
            switch self {
            case .counting: "counting"
            case .arithmetic: "arithmetic"
            case .datesAndTimes: "dates and times"
            case .conversions: "conversion"
            }
        }

        fileprivate var pattern: String {
            switch self {
            case .counting:
                #"\bhow many (letters|words|characters|vowels|syllables|times)\b|\bhow many [a-z]'?s\b|\bcount (the )?(letters|words|characters)\b|\bspell\b.*\bbackwards?\b|\b(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|\d+(st|nd|rd|th)) (word|letter)\b"#
            case .arithmetic:
                #"\d\s*[×x*/+]\s*\d|\d\s*-\s*\d+\s*=|\bwhat(?:'s| is) \d+(\.\d+)?\s*%\s*of\b|\bcompound(ed|ing)?\b|\b(add|adds) up\b|\bcalculate\b|\bper person\b|\bsplit(ting)? (the |a )?(bill|cost|total|trip)|\btotal (for|cost|comes)\b|\bhow much (will|would|do|does) .* (cost|be|have|pay|save)\b"#
            case .datesAndTimes:
                #"\b\d+ days? (after|before|from)\b|\bday of the week\b|\bwhat time (is it|will it be|do i|does it|would)\b|\btime (difference|zone)\b|\bhow many (days|nights|weeks|hours|minutes|seconds)\b|\b(land|lands|arrive|arrives|arrival)\b.*\b(local time|what time)\b|\bvacation days\b|\blocal time\b"#
            case .conversions:
                #"\bconvert \d|\bconvert\b.*\b(to|into) (celsius|fahrenheit|miles|km|kilometers|kg|pounds|cm|inches|feet|dollars|euros|usd|yen)\b|\b(scale|double|halve) (this|the|a) recipe\b|\bfrom \d+ to \d+ servings\b|\bfor \d+ (people|servings|guests)\b.*\b(how much|scale)\b|\b\d+(\.\d+)?\s*(km|kilometers|miles|kg|pounds|lbs|°?[cf]|celsius|fahrenheit|cm|inches|feet|yen|euros?|dollars)\b.*\bin (miles|km|kilometers|kg|pounds|celsius|fahrenheit|cm|inches|feet|dollars|euros|usd)\b"#
            }
        }
    }

    private static let expressions: [(Kind, NSRegularExpression)] = Kind.allCases.map { kind in
        // The patterns are constants; a typo would fail every test that routes a prompt.
        (kind, try! NSRegularExpression(pattern: kind.pattern, options: [.caseInsensitive]))
    }

    /// What kind of exact answer the prompt asks for, or nil if none.
    public static func kind(of prompt: String) -> Kind? {
        let range = NSRange(prompt.startIndex..., in: prompt)
        return expressions.first { $0.1.firstMatch(in: prompt, range: range) != nil }?.0
    }
}
