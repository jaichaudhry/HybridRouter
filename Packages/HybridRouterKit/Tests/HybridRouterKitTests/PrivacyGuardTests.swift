import Foundation
import Testing
@testable import HybridRouterKit

struct PrivacyFixture: Decodable, Sendable, CustomTestStringConvertible {
    let text: String
    let reason: PrivacyGuard.Reason?

    var testDescription: String { "\(reason?.rawValue ?? "none"): \(text)" }

    static let all: [PrivacyFixture] = {
        guard let url = Bundle.module.url(forResource: "privacy_fixtures", withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PrivacyFixture].self, from: data)) ?? []
    }()
}

struct PrivacyGuardTests {
    private let privacy = PrivacyGuard()

    @Test func fixturesLoad() {
        #expect(PrivacyFixture.all.count >= 20)
    }

    @Test(arguments: PrivacyFixture.all)
    func detectsTheFixture(_ fixture: PrivacyFixture) {
        #expect(privacy.assess(fixture.text) == fixture.reason)
    }

    @Test func userToggleAndScansWinOverDetection() {
        #expect(privacy.assess("Hello", markedPrivate: true) == .markedPrivate)
        #expect(privacy.assess("Hello", fromScan: true) == .scannedDocument)
        #expect(privacy.assess("Call (206) 555-0143", markedPrivate: true) == .markedPrivate)
    }

    @Test func luhnRejectsNearMisses() {
        #expect(PrivacyGuard.luhn([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]))
        #expect(!PrivacyGuard.luhn([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2]))
    }

    @Test func everyReasonHasALabel() {
        #expect(Set(PrivacyGuard.Reason.allCases.map(\.label)).count == PrivacyGuard.Reason.allCases.count)
    }
}
