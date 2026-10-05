import AppKit
import AuthenticationServices
import CryptoKit
import Security
import SwiftUI

struct SlackStoredToken: Codable {
    let accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var clientID: String?
}

enum SlackCredential {
    static let service = "com.dorofeev.DockExtend.slack"
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "user-token"]
    }
    static func read() -> SlackStoredToken? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        if let stored = try? JSONDecoder().decode(SlackStoredToken.self, from: data) { return stored }
        return String(data: data, encoding: .utf8).map { SlackStoredToken(accessToken: $0) }
    }
    static func save(_ token: String) throws {
        try save(SlackStoredToken(accessToken: token))
    }
    static func save(_ token: SlackStoredToken) throws {
        let data = try JSONEncoder().encode(token)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(request as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    static func remove() { SecItemDelete(query as CFDictionary) }
}

private struct SlackPreviewMessage: Identifiable {
    let channel: String
    let timestamp: String
    let sender: String
    let text: String
    var id: String { channel + ":" + timestamp }
    var date: Date { Date(timeIntervalSince1970: Double(timestamp) ?? 0) }
}

@MainActor
final class SlackPreviewModel: ObservableObject {
    static let shared = SlackPreviewModel()
    @Published fileprivate var messages: [SlackPreviewMessage] = []
    @Published var status = "Connect Slack in Settings to preview unread DMs."
    @Published var loading = false
    @Published var connected = false
    private var lastRefresh = Date.distantPast
    private var retryAfter = Date.distantPast
    private var userNames: [String: String] = [:]
    private var generation = 0
    private let session = URLSession(configuration: .ephemeral)
    private var lastInfoRequest = Date.distantPast

    func reset() {
        generation += 1
        messages = []; connected = false; userNames = [:]; lastRefresh = .distantPast; retryAfter = .distantPast
        status = "Connect Slack in Settings to preview unread DMs."
    }

    private func api(_ method: String, token: String, parameters: [String: String] = [:]) async throws -> [String: Any] {
        let revision = generation
        if method == "conversations.info" {
            let delay = 1.3 - Date().timeIntervalSince(lastInfoRequest)
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            lastInfoRequest = Date()
        }
        try Task.checkCancellation()
        var components = URLComponents(string: "https://slack.com/api/" + method)!
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 15
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard revision == generation else { throw CancellationError() }
        if let response = response as? HTTPURLResponse, response.statusCode == 429 {
            retryAfter = Date().addingTimeInterval(Double(response.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60)
            throw failure("Slack rate limit reached. Try again shortly.")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw failure("Invalid Slack response.") }
        guard object["ok"] as? Bool == true else {
            let error = object["error"] as? String ?? "unknown_error"
            throw failure(error == "missing_scope" ? "Token needs im:read, im:history and users:read permissions." : "Slack: " + error)
        }
        return object
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "SlackPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }

    func refresh(force: Bool = false) async {
        guard !loading else { return }
        guard SlackCredential.read() != nil else { reset(); return }
        guard Date() >= retryAfter else { return }
        guard force || Date().timeIntervalSince(lastRefresh) >= 60 else { return }
        loading = true
        let revision = generation
        defer { loading = false }
        do {
            let token = try await SlackOAuth.shared.accessToken()
            guard revision == generation else { return }
            let auth = try await api("auth.test", token: token)
            let ownUser = auth["user_id"] as? String ?? ""
            connected = true
            var channels: [[String: Any]] = []
            var cursor = ""
            repeat {
                try Task.checkCancellation()
                guard revision == generation else { return }
                let page = try await api("conversations.list", token: token, parameters: ["types": "im", "exclude_archived": "true", "limit": "200", "cursor": cursor])
                channels += page["channels"] as? [[String: Any]] ?? []
                cursor = (page["response_metadata"] as? [String: Any])?["next_cursor"] as? String ?? ""
            } while !cursor.isEmpty
            var found: [SlackPreviewMessage] = []
            for (index, channel) in channels.enumerated() {
                try Task.checkCancellation()
                guard revision == generation else { return }
                status = "Checking DMs \(index + 1) of \(channels.count)…"
                guard let id = channel["id"] as? String else { continue }
                let info = try await api("conversations.info", token: token, parameters: ["channel": id])
                guard let detail = info["channel"] as? [String: Any],
                      let unread = detail["unread_count"] as? Int, unread > 0,
                      let lastRead = detail["last_read"] as? String else { continue }
                let history = try await api("conversations.history", token: token, parameters: ["channel": id, "oldest": lastRead, "limit": "15"])
                for message in history["messages"] as? [[String: Any]] ?? [] {
                    guard let timestamp = message["ts"] as? String, (Double(timestamp) ?? 0) > (Double(lastRead) ?? 0),
                          let text = message["text"] as? String, !text.isEmpty else { continue }
                    let user = message["user"] as? String ?? ""
                    guard user != ownUser else { continue }
                    if userNames[user] == nil, !user.isEmpty {
                        let result = try await api("users.info", token: token, parameters: ["user": user])
                        let person = result["user"] as? [String: Any] ?? [:]
                        let profile = person["profile"] as? [String: Any] ?? [:]
                        let display = profile["display_name"] as? String ?? ""
                        userNames[user] = display.isEmpty ? (person["real_name"] as? String ?? "Slack user") : display
                    }
                    found.append(SlackPreviewMessage(channel: id, timestamp: timestamp, sender: userNames[user] ?? "Slack", text: text))
                }
                guard revision == generation else { return }
                messages = Array(found.sorted { $0.date > $1.date }.prefix(30))
            }
            guard revision == generation else { return }
            messages = Array(found.sorted { $0.date > $1.date }.prefix(30))
            connected = true
            status = messages.isEmpty ? "No unread direct messages." : "Unread direct messages"
            lastRefresh = Date()
        } catch is CancellationError { }
        catch {
            guard revision == generation else { return }
            status = error.localizedDescription
            lastRefresh = Date()
        }
    }

    fileprivate func open(_ message: SlackPreviewMessage) async {
        do {
            let token = try await SlackOAuth.shared.accessToken()
            let response = try await api("chat.getPermalink", token: token, parameters: ["channel": message.channel, "message_ts": message.timestamp])
            guard let link = response["permalink"] as? String, let url = URL(string: link), url.scheme == "https",
                  let host = url.host, host == "slack.com" || host.hasSuffix(".slack.com") else { return }
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tinyspeck.slackmacgap") {
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } else { NSWorkspace.shared.open(url) }
        } catch { status = error.localizedDescription }
    }
}

struct SlackHoverPanel: View {
    @ObservedObject private var model = SlackPreviewModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Slack · unread DMs").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                else { Button { Task { await model.refresh(force: true) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Refresh unread DMs") }
            }
            Text(model.status).font(.system(size: 10)).foregroundStyle(.secondary)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(model.messages) { message in
                        Button { Task { await model.open(message) } } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(message.sender).fontWeight(.medium)
                                    Spacer()
                                    Text(message.date, style: .time).foregroundStyle(.secondary)
                                }.font(.system(size: 10))
                                Text(message.text).font(.system(size: 11)).lineLimit(3)
                            }
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.08), lineWidth: 0.75))
                        }.buttonStyle(.plain)
                    }
                }
            }
            if !model.connected {
                Button("Slack connection settings…") { NotificationCenter.default.post(name: Notification.Name("DockExtend.showDockSettings"), object: nil) }
                    .buttonStyle(.plain).font(.system(size: 11))
            }
        }
        .foregroundStyle(Color.black.opacity(0.85))
        .task { await model.refresh() }
    }
}

struct SlackConnectionSettings: View {
    @AppStorage("slack.oauth.clientID", store: .standard) private var clientID = ""
    @ObservedObject private var oauth = SlackOAuth.shared
    @State private var token = ""
    @State private var feedback = ""
    @ObservedObject private var model = SlackPreviewModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hover over Slack to preview unread direct messages. Messages are fetched when connecting or opening the preview.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            TextField("Slack app Client ID", text: $clientID)
            HStack {
                Button("Connect with Slack") { oauth.connect(clientID: clientID) }
                    .disabled(clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || oauth.authorizing)
                if oauth.authorizing { Button("Cancel") { oauth.cancel() } }
            }
            Text("Enable PKCE in your Slack app and add redirect URL dockextend-slack://oauth. No client secret is needed.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if !oauth.status.isEmpty { Text(oauth.status).font(.system(size: 10)) }
            SecureField("Slack user token (xoxp-…)", text: $token)
            HStack {
                Button("Connect") {
                    let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard value.hasPrefix("xoxp-") else { feedback = "Use a Slack user OAuth token beginning with xoxp-."; return }
                    do {
                        oauth.cancel()
                        try SlackCredential.save(value)
                        token = ""; model.reset(); feedback = "Saved in Keychain."
                        Task { await model.refresh(force: true) }
                    } catch { feedback = "Could not save the token in Keychain." }
                }.disabled(token.isEmpty)
                Button("Disconnect") { oauth.cancel(); SlackCredential.remove(); model.reset(); token = ""; feedback = "Disconnected."; oauth.status = "" }
                Link("Create a Slack app", destination: URL(string: "https://api.slack.com/apps")!)
            }
            Text("Install a personal Slack app with user scopes im:read, im:history and users:read. Workspace approval may be required. Tokens stay in macOS Keychain.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if !feedback.isEmpty { Text(feedback).font(.system(size: 10)) }
            Text(model.loading ? "Connecting…" : model.status).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
