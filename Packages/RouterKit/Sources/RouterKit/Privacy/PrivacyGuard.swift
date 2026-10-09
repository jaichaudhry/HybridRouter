import Foundation

/// Decides on-device whether a turn must stay off Claude (SPEC §8). Nothing it inspects
/// leaves the device.
public struct PrivacyGuard: Sendable {
    public enum Reason: String, Codable, Equatable, Sendable, CaseIterable {
        case markedPrivate
        case scannedDocument
        case cardNumber
        case governmentID
        case phoneNumber
        case email
        case address
        case health

        /// Shown after "Kept private:" on the badge.
        public var label: String {
            switch self {
            case .markedPrivate: "marked private"
            case .scannedDocument: "scanned document"
            case .cardNumber: "card number"
            case .governmentID: "ID number"
            case .phoneNumber: "phone number"
            case .email: "email address"
            case .address: "street address"
            case .health: "health information"
            }
        }
    }

    public init() {}

    /// The first reason the turn is private, or nil if it may leave the device.
    /// - Parameters:
    ///   - markedPrivate: the user turned on Private for this message.
    ///   - fromScan: the content came from the Document Helper scan flow.
    public func assess(_ text: String, markedPrivate: Bool = false, fromScan: Bool = false) -> Reason? {
        if markedPrivate { return .markedPrivate }
        if fromScan { return .scannedDocument }
        if Self.containsCardNumber(text) { return .cardNumber }
        if Self.containsGovernmentID(text) { return .governmentID }
        if Self.containsPhoneNumber(text) { return .phoneNumber }
        if Self.containsEmail(text) { return .email }
        if Self.containsAddress(text) { return .address }
        if Self.containsHealthTerm(text) { return .health }
        return nil
    }

    // MARK: Detectors

    /// 13–19 digits, optionally grouped with spaces or dashes, passing the Luhn check.
    static func containsCardNumber(_ text: String) -> Bool {
        matches(cardPattern, in: text).contains { candidate in
            let digits = candidate.compactMap(\.wholeNumberValue)
            return (13...19).contains(digits.count) && luhn(digits)
        }
    }

    /// US Social Security numbers, and numbers introduced as a passport, licence or national ID.
    static func containsGovernmentID(_ text: String) -> Bool {
        !matches(ssnPattern, in: text).isEmpty || !matches(labeledIDPattern, in: text).isEmpty
    }

    static func containsPhoneNumber(_ text: String) -> Bool {
        detects(.phoneNumber, in: text)
    }

    static func containsEmail(_ text: String) -> Bool {
        !matches(emailPattern, in: text).isEmpty
    }

    static func containsAddress(_ text: String) -> Bool {
        detects(.address, in: text)
    }

    static func containsHealthTerm(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return healthTerms.contains { term in
            lowered.range(of: "\\b\(NSRegularExpression.escapedPattern(for: term))\\b", options: .regularExpression) != nil
        }
    }

    // MARK: Helpers

    private static let cardPattern = #"\b(?:\d[ -]?){12,18}\d\b"#
    private static let ssnPattern = #"\b\d{3}-\d{2}-\d{4}\b"#
    private static let labeledIDPattern =
        #"(?i)\b(passport|driver'?s? licen[cs]e|national id|id number|social security)(?: number| no\.?| #)?[:\s#]*[A-Z0-9][A-Z0-9-]{5,}"#
    private static let emailPattern = #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#

    /// A small list on purpose: common enough to catch real health details, specific enough
    /// not to flag everyday words.
    static let healthTerms = [
        "diagnosis", "diagnosed", "prescription", "prescribed", "medication", "dosage", "symptoms",
        "lab results", "blood test", "biopsy", "mri", "ct scan", "x-ray", "chemotherapy", "insulin",
        "diabetes", "cancer", "tumor", "hiv", "pregnant", "pregnancy", "miscarriage", "therapy session",
        "therapist", "psychiatrist", "depression", "anxiety disorder", "antidepressant", "surgery",
        "medical record", "patient",
    ]

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func detects(_ type: NSTextCheckingResult.CheckingType, in text: String) -> Bool {
        guard let detector = try? NSDataDetector(types: type.rawValue) else { return false }
        return detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func luhn(_ digits: [Int]) -> Bool {
        let sum = digits.reversed().enumerated().reduce(0) { total, pair in
            let (index, digit) = pair
            guard index.isMultiple(of: 2) == false else { return total + digit }
            let doubled = digit * 2
            return total + (doubled > 9 ? doubled - 9 : doubled)
        }
        return sum.isMultiple(of: 10)
    }
}
