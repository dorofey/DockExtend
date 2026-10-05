import AppKit
import Combine
import Foundation

struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let body: String?
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case draft
        case prerelease
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var message = "Check GitHub for the latest DockExtend release."
    @Published private(set) var latestRelease: GitHubRelease?
    @Published private(set) var isChecking = false

    private let repository = "dorofey/DockExtend"

    var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        latestRelease = nil
        defer { isChecking = false }

        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            message = "Could not create the GitHub release URL."
            return
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("DockExtend/\(installedVersion)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                message = "GitHub returned an invalid response."
                return
            }
            guard response.statusCode == 200 else {
                message = response.statusCode == 404
                    ? "No public release is available yet."
                    : "GitHub could not check releases (HTTP \(response.statusCode))."
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard !release.draft, !release.prerelease else {
                message = "No stable public release is available yet."
                return
            }
            latestRelease = release
            let latestVersion = Self.normalizedVersion(release.tagName)
            if Self.version(latestVersion, isNewerThan: Self.normalizedVersion(installedVersion)) {
                message = "Version \(latestVersion) is available (you have \(installedVersion))."
            } else {
                message = "You’re up to date (version \(installedVersion))."
            }
        } catch {
            message = "Update check failed: \(error.localizedDescription)"
        }
    }

    func openLatestRelease() {
        guard let latestRelease else { return }
        NSWorkspace.shared.open(latestRelease.htmlURL)
    }

    private static func normalizedVersion(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
    }

    private static func version(_ candidate: String, isNewerThan current: String) -> Bool {
        let candidateParts = candidate.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        guard !candidateParts.isEmpty, candidateParts.count == candidate.split(separator: ".").count,
              !currentParts.isEmpty, currentParts.count == current.split(separator: ".").count else {
            return candidate.compare(current, options: .numeric) == .orderedDescending
        }

        for index in 0..<max(candidateParts.count, currentParts.count) {
            let newPart = index < candidateParts.count ? candidateParts[index] : 0
            let oldPart = index < currentParts.count ? currentParts[index] : 0
            if newPart != oldPart { return newPart > oldPart }
        }
        return false
    }
}
