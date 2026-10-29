import CryptoKit
import Foundation

/// "Sign in with OpenRouter": OpenRouter's OAuth PKCE flow, which gives the app a key on the
/// person's own account, billed to their credits. The person approves in a browser, where they
/// can also cap the key's spending and set it to expire.
///
/// OpenRouter only calls back to an https page (custom URL schemes are refused, checked October
/// 2026), so the callback is a small web page you host that forwards its query to your app's
/// URL scheme. HybridRouter's is `site/openrouter/index.html`, served by GitHub Pages.
///
/// 1. ``authorization(callbackURL:keyLabel:)`` makes the URL to open, with a fresh verifier.
/// 2. Open it with `WebAuthenticationSession` (SwiftUI) or `ASWebAuthenticationSession`,
///    listening for your app's scheme.
/// 3. ``code(from:expectedState:)`` reads the code from the callback URL.
/// 4. ``exchange(code:codeVerifier:session:)`` trades it for the key.
public enum OpenRouterAuth {
    public static let authorizeURL = URL(string: "https://openrouter.ai/auth")!
    public static let exchangeURL = URL(string: "https://openrouter.ai/api/v1/auth/keys")!

    /// One sign-in attempt: the URL to open, and what's needed to finish it.
    public struct Authorization: Sendable {
        public let url: URL
        /// Kept in memory only; sent once, to exchange the code.
        public let codeVerifier: String
        /// Returned unchanged on the callback, so a stray callback can't complete this sign-in.
        public let state: String
    }

    public enum AuthError: Error, Equatable, LocalizedError {
        case missingCode
        case stateMismatch
        case exchangeFailed(status: Int, message: String)

        public var errorDescription: String? {
            switch self {
            case .missingCode: "OpenRouter didn't return a sign-in code. Did you deny access?"
            case .stateMismatch: "That sign-in response doesn't match this sign-in. Try again."
            case .exchangeFailed(_, let message): "OpenRouter didn't issue a key: \(message)"
            }
        }
    }

    /// - Parameters:
    ///   - callbackURL: your https page that forwards to the app.
    ///   - keyLabel: prefills the key's name in the person's OpenRouter account.
    public static func authorization(callbackURL: URL, keyLabel: String? = nil) -> Authorization {
        let verifier = randomURLSafe(bytes: 32)
        let state = randomURLSafe(bytes: 16)
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "callback_url", value: callbackURL.absoluteString),
            URLQueryItem(name: "code_challenge", value: codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ] + (keyLabel.map { [URLQueryItem(name: "key_label", value: $0)] } ?? [])
        return Authorization(url: components.url!, codeVerifier: verifier, state: state)
    }

    /// The code from the URL the callback page forwarded to the app.
    public static func code(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == expectedState else { throw AuthError.stateMismatch }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw AuthError.missingCode }
        return code
    }

    /// Trades the code for a key on the person's account. Codes are single-use and expire after
    /// 10 minutes.
    public static func exchange(code: String, codeVerifier: String, session: URLSession = .shared) async throws -> String {
        var request = URLRequest(url: exchangeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "code": code, "code_verifier": codeVerifier, "code_challenge_method": "S256",
        ])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let key = try? JSONDecoder().decode(KeyResponse.self, from: data).key, !key.isEmpty else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error.message) ?? "HTTP \(status)"
            throw AuthError.exchangeFailed(status: status, message: message)
        }
        return key
    }

    /// base64url(SHA-256(verifier)), as PKCE's S256 method defines it.
    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func randomURLSafe(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private struct KeyResponse: Decodable { var key: String }
    private struct ErrorResponse: Decodable {
        struct Detail: Decodable { var message: String }
        var error: Detail
    }
}
