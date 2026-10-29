import Foundation
import Testing
@testable import HybridRouterKit

struct OpenRouterAuthTests {
    static let callback = URL(string: "https://jaichaudhry.github.io/HybridRouter/openrouter/")!

    @Test func theChallengeIsBase64URLOfTheVerifiersSHA256() {
        // Computed independently with Python's hashlib and urlsafe_b64encode, padding removed.
        #expect(OpenRouterAuth.codeChallenge(for: "dBjftJeZ4CVP-mJ92IjqMw7QuhpFGMWXv0LtRdh4vPM") == "mKAdT13aAGSTUCrkMxYufHaXCPY7UoGEyxTtIVn9K_U")
    }

    @Test func theAuthorizationURLCarriesTheCallbackAndChallenge() throws {
        let auth = OpenRouterAuth.authorization(callbackURL: Self.callback, keyLabel: "HybridRouter")
        let items = try #require(URLComponents(url: auth.url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(auth.url.host() == "openrouter.ai" && auth.url.path() == "/auth")
        #expect(value("callback_url") == Self.callback.absoluteString)
        #expect(value("code_challenge") == OpenRouterAuth.codeChallenge(for: auth.codeVerifier))
        #expect(value("code_challenge_method") == "S256")
        #expect(value("state") == auth.state)
        #expect(value("key_label") == "HybridRouter")
        // PKCE verifiers are 43–128 URL-safe characters, and each sign-in gets new ones.
        #expect((43...128).contains(auth.codeVerifier.count))
        #expect(auth.codeVerifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        let again = OpenRouterAuth.authorization(callbackURL: Self.callback)
        #expect(again.codeVerifier != auth.codeVerifier && again.state != auth.state)
    }

    @Test func theCallbackGivesTheCodeOnlyForThisSignIn() throws {
        let url = URL(string: "hybridrouter://openrouter?code=abc123&state=s1")!
        #expect(try OpenRouterAuth.code(from: url, expectedState: "s1") == "abc123")
        #expect(throws: OpenRouterAuth.AuthError.stateMismatch) {
            try OpenRouterAuth.code(from: url, expectedState: "other")
        }
        #expect(throws: OpenRouterAuth.AuthError.missingCode) {
            try OpenRouterAuth.code(from: URL(string: "hybridrouter://openrouter?state=s1")!, expectedState: "s1")
        }
    }
}

/// The key exchange against a stubbed OpenRouter. Serialized: the stub is shared.
@Suite(.serialized)
struct OpenRouterExchangeTests {
    private func session(status: Int, body: String) -> URLSession {
        StubProtocol.response = (status, Data(body.utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func aCodeIsTradedForAKey() async throws {
        let key = try await OpenRouterAuth.exchange(code: "abc", codeVerifier: "verifier", session: session(status: 200, body: #"{"key":"sk-or-v1-test","user_id":"u1"}"#))
        #expect(key == "sk-or-v1-test")
        let request = try #require(StubProtocol.lastRequest)
        #expect(request.url == OpenRouterAuth.exchangeURL && request.httpMethod == "POST")
        let body = try JSONDecoder().decode([String: String].self, from: try #require(StubProtocol.lastBody))
        #expect(body == ["code": "abc", "code_verifier": "verifier", "code_challenge_method": "S256"])
    }

    @Test func anExpiredCodeSaysWhy() async {
        await #expect(throws: OpenRouterAuth.AuthError.exchangeFailed(status: 403, message: "Authorization code expired")) {
            try await OpenRouterAuth.exchange(code: "old", codeVerifier: "v",
                                              session: session(status: 403, body: #"{"error":{"code":403,"message":"Authorization code expired"}}"#))
        }
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (Int, Data) = (200, Data())
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
        let (status, body) = Self.response
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
