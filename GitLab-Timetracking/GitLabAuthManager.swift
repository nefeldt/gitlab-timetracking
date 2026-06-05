//
//  GitLabAuthManager.swift
//  My GitLab Timetracking
//

import Foundation
import CryptoKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
import AuthenticationServices
#endif

struct GitLabOAuthToken: Codable {
    let accessToken: String
    let tokenType: String
    let refreshToken: String
    let expiresIn: Int
    let createdAt: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case createdAt = "created_at"
    }

    var expirationDate: Date {
        Date(timeIntervalSince1970: TimeInterval(createdAt + expiresIn))
    }

    var needsRefresh: Bool {
        expirationDate.timeIntervalSinceNow < 60
    }
}

enum GitLabAuthError: LocalizedError {
    case callbackStateMismatch
    case missingAuthorizationCode
    case invalidBaseURL(String)
    case browserLaunchFailed(URL)
    case authorizationFailed(code: String, description: String?)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .callbackStateMismatch:
            return "The reply from GitLab didn’t match the request this app sent. This can happen if you finished sign-in from a different browser session — please try again."
        case .missingAuthorizationCode:
            return "GitLab redirected back to the app without an authorization code. Open GitLab’s applications page and confirm the OAuth app is configured as a public client with scope “api” and the callback URL shown above."
        case let .invalidBaseURL(value):
            return value.isEmpty
                ? "Enter your GitLab URL in Settings before connecting (e.g. https://gitlab.com)."
                : "“\(value)” isn’t a valid GitLab URL. Include the scheme and host, e.g. https://gitlab.com."
        case let .browserLaunchFailed(url):
            return "Couldn’t open \(url.absoluteString) in a browser. Check that your default browser is set and try again."
        case let .authorizationFailed(code, description):
            if let description, !description.isEmpty {
                return "GitLab refused the sign-in request (\(code)): \(description)"
            }
            return "GitLab refused the sign-in request (\(code)). Double-check the OAuth application ID and that the callback URL in GitLab exactly matches \(GitLabAuthManager.redirectURI.absoluteString)."
        case .cancelled:
            return "Sign-in cancelled."
        }
    }
}

@MainActor
@Observable
final class GitLabAuthManager: NSObject {
#if os(macOS)
    nonisolated static let redirectURI = URL(string: "http://127.0.0.1:45873/oauth/callback")!
    nonisolated static let redirectPort: UInt16 = 45873
#else
    nonisolated static let redirectURI = URL(string: "gitlab-timetracking://oauth/callback")!
    private var webAuthSession: ASWebAuthenticationSession?
#endif

    private(set) var currentUser: GitLabUser?
    private(set) var isAuthenticating = false
    private(set) var authError: String?

    let settings: AppSettings

    private let api = GitLabAPI()
    private let keychain = KeychainStore()
    private var token: GitLabOAuthToken?
    private var signInTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        token = loadToken()

        if token != nil {
            Task {
                await refreshCurrentUser()
            }
        }
    }

    var isAuthenticated: Bool {
        token != nil
    }

    func signIn() async {
        guard !isAuthenticating else { return }

        guard let configuration = settings.configuration else {
            authError = GitLabAPIError.missingConfiguration.localizedDescription
            return
        }

        if let urlError = baseURLValidationError(configuration.baseURL, rawInput: settings.gitLabBaseURL) {
            authError = urlError.localizedDescription
            return
        }

        isAuthenticating = true
        authError = nil

        let task = Task {
            await self.performSignIn(configuration: configuration)
        }
        signInTask = task
        await task.value
        signInTask = nil
    }

    func cancelSignIn() {
        signInTask?.cancel()
    }

    private func performSignIn(configuration: GitLabConfiguration) async {
        defer { isAuthenticating = false }

        do {
            let state = Self.randomURLSafeString(length: 32)
            let codeVerifier = Self.randomCodeVerifier()
            let codeChallenge = Self.codeChallenge(for: codeVerifier)

            let authURL = try makeAuthorizationURL(
                configuration: configuration,
                state: state,
                codeChallenge: codeChallenge
            )

#if os(macOS)
            let callbackServer = OAuthCallbackServer(port: Self.redirectPort)
            let callbackTask = Task {
                try await callbackServer.waitForCallback()
            }

            guard NSWorkspace.shared.open(authURL) else {
                callbackTask.cancel()
                throw GitLabAuthError.browserLaunchFailed(authURL)
            }

            let callbackURL = try await withTaskCancellationHandler {
                try await callbackTask.value
            } onCancel: {
                callbackTask.cancel()
            }
#else
            let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(
                    url: authURL,
                    callbackURLScheme: "gitlab-timetracking"
                ) { [weak self] url, error in
                    self?.webAuthSession = nil
                    if let error {
                        let asError = error as? ASWebAuthenticationSessionError
                        if asError?.code == .canceledLogin {
                            continuation.resume(throwing: GitLabAuthError.cancelled)
                        } else {
                            continuation.resume(throwing: error)
                        }
                        return
                    }
                    guard let url else {
                        continuation.resume(throwing: GitLabAuthError.missingAuthorizationCode)
                        return
                    }
                    continuation.resume(returning: url)
                }
                session.presentationContextProvider = self
                webAuthSession = session
                session.start()
            }
#endif

            let queryItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []

            if let errorCode = queryItems.first(where: { $0.name == "error" })?.value {
                let description = queryItems.first(where: { $0.name == "error_description" })?.value
                throw GitLabAuthError.authorizationFailed(code: errorCode, description: description)
            }

            let returnedState = queryItems.first(where: { $0.name == "state" })?.value
            let code = queryItems.first(where: { $0.name == "code" })?.value

            guard returnedState == state else {
                throw GitLabAuthError.callbackStateMismatch
            }

            guard let code, !code.isEmpty else {
                throw GitLabAuthError.missingAuthorizationCode
            }

            let token = try await exchangeCodeForToken(
                configuration: configuration,
                code: code,
                codeVerifier: codeVerifier
            )

            try saveToken(token)
            self.token = token
            await refreshCurrentUser()
        } catch is CancellationError {
            authError = GitLabAuthError.cancelled.localizedDescription
        } catch {
            authError = error.localizedDescription
        }
    }

#if os(iOS)
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? UIWindow()
    }
#endif

    private func baseURLValidationError(_ url: URL, rawInput: String) -> GitLabAuthError? {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else {
            return .invalidBaseURL(rawInput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    func signOut() {
        token = nil
        currentUser = nil
        authError = nil
        keychain.deleteAll()
    }

    func currentAuthorization() async throws -> AuthorizedGitLabConfiguration {
        guard let configuration = settings.configuration else {
            throw GitLabAPIError.missingConfiguration
        }

        guard let token = try await validToken(configuration: configuration) else {
            throw GitLabAPIError.notAuthenticated
        }

        return AuthorizedGitLabConfiguration(
            baseURL: configuration.baseURL,
            accessToken: token.accessToken
        )
    }

    func refreshCurrentUser() async {
        do {
            guard let authorization = try? await currentAuthorization() else {
                currentUser = nil
                return
            }

            currentUser = try await api.fetchCurrentUser(configuration: authorization)
            authError = nil
        } catch {
            authError = error.localizedDescription
        }
    }

    private func validToken(configuration: GitLabConfiguration) async throws -> GitLabOAuthToken? {
        guard let token else {
            return nil
        }

        guard token.needsRefresh else {
            return token
        }

        // If refresh fails (e.g. offline), fall back to the existing token and let
        // the API call decide whether it's still accepted rather than blocking the user.
        if let refreshed = try? await refreshToken(configuration: configuration, refreshToken: token.refreshToken) {
            try? saveToken(refreshed)
            self.token = refreshed
            return refreshed
        }
        return token
    }

    private func makeAuthorizationURL(
        configuration: GitLabConfiguration,
        state: String,
        codeChallenge: String
    ) throws -> URL {
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
        components?.path = configuration.baseURL.path + "/oauth/authorize"
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: "api"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

        guard let url = components?.url else {
            throw GitLabAPIError.missingConfiguration
        }

        return url
    }

    private func exchangeCodeForToken(
        configuration: GitLabConfiguration,
        code: String,
        codeVerifier: String
    ) async throws -> GitLabOAuthToken {
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
        components?.path = configuration.baseURL.path + "/oauth/token"

        guard let url = components?.url else {
            throw GitLabAPIError.missingConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncodedData([
            "client_id": configuration.clientID,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": Self.redirectURI.absoluteString,
            "code_verifier": codeVerifier
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateOAuthResponse(response: response, data: data)
        return try JSONDecoder().decode(GitLabOAuthToken.self, from: data)
    }

    private func refreshToken(
        configuration: GitLabConfiguration,
        refreshToken: String
    ) async throws -> GitLabOAuthToken {
        var components = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
        components?.path = configuration.baseURL.path + "/oauth/token"

        guard let url = components?.url else {
            throw GitLabAPIError.missingConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncodedData([
            "client_id": configuration.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
            "redirect_uri": Self.redirectURI.absoluteString
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateOAuthResponse(response: response, data: data)
        return try JSONDecoder().decode(GitLabOAuthToken.self, from: data)
    }

    private func loadToken() -> GitLabOAuthToken? {
        guard !settings.normalizedBaseURLString.isEmpty else {
            return nil
        }

        guard let data = keychain.load(account: settings.normalizedBaseURLString) else {
            return nil
        }

        return try? JSONDecoder().decode(GitLabOAuthToken.self, from: data)
    }

    private func saveToken(_ token: GitLabOAuthToken) throws {
        let data = try JSONEncoder().encode(token)
        try keychain.save(data, account: settings.normalizedBaseURLString)
    }

    private func validateOAuthResponse(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitLabAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GitLabAPIError.serverError(statusCode: httpResponse.statusCode, message: message)
        }
    }

    private static func randomCodeVerifier() -> String {
        randomURLSafeString(length: 64)
    }

    private static func randomURLSafeString(length: Int) -> String {
        let bytes = (0..<length).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncodedData(_ fields: [String: String]) -> Data? {
        let value = fields
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .sorted()
            .joined(separator: "&")

        return value.data(using: .utf8)
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) ?? value
    }
}

#if os(iOS)
extension GitLabAuthManager: ASWebAuthenticationPresentationContextProviding {}
#endif
