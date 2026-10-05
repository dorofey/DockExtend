import AppKit
import AuthenticationServices
import CryptoKit
import SwiftUI

@MainActor
final class SlackOAuth: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = SlackOAuth()
    static let redirect = "dockextend-slack://oauth"
    @Published var status = ""
    @Published var authorizing = false
    private var browser: ASWebAuthenticationSession?
    private var refreshTask: Task<String, Error>?
    private var generation = 0

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "SlackOAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw failure("Could not start secure authentication.") }
        return encode(Data(bytes))
    }
    private func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    func cancel() {
        generation += 1
        browser?.cancel(); browser = nil; authorizing = false
        refreshTask?.cancel(); refreshTask = nil
    }
    func connect(clientID: String) {
        cancel()
        let client = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !client.isEmpty else { status = "Enter your Slack app Client ID first."; return }
        do {
            let verifier = try random(), state = try random(), revision = generation
            let started = Date()
            var url = URLComponents(string: "https://slack.com/oauth/v2/authorize")!
            url.queryItems = ["client_id": client, "user_scope": "im:read,im:history,users:read", "redirect_uri": Self.redirect,
                             "state": state, "code_challenge": encode(Data(SHA256.hash(data: Data(verifier.utf8)))), "code_challenge_method": "S256"]
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            let session = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: "dockextend-slack") { callback, error in
                Task { @MainActor in
                    guard revision == self.generation else { return }
                    self.browser = nil
                    defer { self.authorizing = false }
                    do {
                        guard error == nil, let callback else { throw self.failure("Slack authorization was cancelled or could not finish.") }
                        guard callback.scheme == "dockextend-slack", callback.host == "oauth", callback.path.isEmpty,
                              Date().timeIntervalSince(started) < 600 else { throw self.failure("Invalid or expired Slack callback. Connect again.") }
                        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
                        guard items.filter({ $0.name == "state" }).count == 1,
                              items.first(where: { $0.name == "state" })?.value == state else { throw self.failure("Slack authorization could not be verified. Connect again.") }
                        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw self.failure("Slack did not grant access. Check workspace approval and app settings.") }
                        let token = try await self.exchange(["client_id": client, "code": code, "code_verifier": verifier, "redirect_uri": Self.redirect], clientID: client)
                        guard revision == self.generation else { return }
                        try SlackCredential.save(token)
                        self.status = "Connected. Credentials saved in Keychain."
                        SlackPreviewModel.shared.reset()
                        await SlackPreviewModel.shared.refresh(force: true)
                    } catch { if revision == self.generation { self.status = error.localizedDescription } }
                }
            }
            session.presentationContextProvider = self
            browser = session; authorizing = true; status = "Approve access in your browser…"
            if !session.start() { browser = nil; authorizing = false; status = "Could not open Slack authentication." }
        } catch { status = error.localizedDescription }
    }
    private func exchange(_ parameters: [String: String], clientID: String) async throws -> SlackStoredToken {
        var request = URLRequest(url: URL(string: "https://slack.com/api/oauth.v2.access")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(parameters.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], result["ok"] as? Bool == true else {
            throw failure("Slack authorization failed. Check PKCE, redirect URL and permissions, or reconnect if your refresh token expired.")
        }
        let user = result["authed_user"] as? [String: Any] ?? result
        guard let access = user["access_token"] as? String, !access.isEmpty,
              let refresh = user["refresh_token"] as? String,
              let seconds = user["expires_in"] as? Double else { throw failure("Slack did not return a rotating user token.") }
        return SlackStoredToken(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(seconds), clientID: clientID)
    }
    func accessToken() async throws -> String {
        guard let stored = SlackCredential.read() else { throw failure("Connect Slack in Settings.") }
        guard let expiry = stored.expiresAt, expiry.timeIntervalSinceNow < 120 else { return stored.accessToken }
        if let refreshTask { return try await refreshTask.value }
        guard let refresh = stored.refreshToken, let client = stored.clientID else { throw failure("Reconnect Slack in Settings.") }
        let revision = generation
        let task = Task { @MainActor in
            let updated = try await self.exchange(["client_id": client, "grant_type": "refresh_token", "refresh_token": refresh], clientID: client)
            guard revision == self.generation else { throw CancellationError() }
            try SlackCredential.save(updated)
            return updated.accessToken
        }
        refreshTask = task
        defer { if revision == generation { refreshTask = nil } }
        return try await task.value
    }
}
