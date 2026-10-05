import AppKit
import SwiftUI

private struct HerdrSpace: Identifiable, Decodable {
    let workspaceID: String
    let label: String
    let agentStatus: String
    let paneCount: Int
    let tabCount: Int
    var id: String { workspaceID }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case label, agentStatus = "agent_status", paneCount = "pane_count", tabCount = "tab_count"
    }
}

private struct HerdrSpaceResponse: Decodable {
    struct Result: Decodable { let workspaces: [HerdrSpace] }
    let result: Result
}

@MainActor
private final class HerdrSpacesModel: ObservableObject {
    @Published var spaces: [HerdrSpace] = []
    @Published var status = ""
    @Published var loading = false
    private var generation = 0

    func refresh() async {
        guard !loading else { return }
        loading = true; let revision = generation
        defer { loading = false }
        do {
            let data = try await Self.command(["workspace", "list"])
            let response = try JSONDecoder().decode(HerdrSpaceResponse.self, from: data)
            guard revision == generation else { return }
            spaces = response.result.workspaces
            status = spaces.isEmpty ? "No Herdr spaces available." : ""
        } catch {
            guard revision == generation else { return }
            status = "Herdr is unavailable."
        }
    }

    func focus(_ space: HerdrSpace) async {
        generation += 1
        do {
            _ = try await Self.command(["workspace", "focus", space.workspaceID])
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") else { return }
            let config = NSWorkspace.OpenConfiguration(); config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { application, _ in
                DispatchQueue.main.async {
                    application?.unhide()
                    application?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
                }
            }
        } catch { status = "Could not focus this Herdr space." }
    }

    private nonisolated static func command(_ arguments: [String]) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/herdr")
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(["HERDR_ENV": "1"]) { _, new in new }
            process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NSError(domain: "HerdrSpaces", code: Int(process.terminationStatus)) }
            return output.fileHandleForReading.readDataToEndOfFile()
        }.value
    }
}

struct HerdrSpacesHoverPanel: View {
    @StateObject private var model = HerdrSpacesModel()
    @State private var search = ""
    private var filtered: [HerdrSpace] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.spaces.filter { query.isEmpty || $0.label.localizedStandardContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.08))
                    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().scaledToFit().frame(width: 20, height: 20)
                    } else { Image(systemName: "terminal").foregroundStyle(.teal) }
                }.frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Herdr spaces").font(.custom("JetBrainsMono Nerd Font", size: 12).weight(.medium))
                        Text("\(model.spaces.count)").font(.custom("JetBrainsMono Nerd Font", size: 8))
                            .foregroundStyle(.teal).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Text("Click to focus").font(.custom("JetBrainsMono Nerd Font", size: 8)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                else { Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain) }
            }
            if !model.status.isEmpty { Text(model.status).font(.system(size: 10)).foregroundStyle(.secondary) }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(filtered) { space in
                        Button { Task { await model.focus(space) } } label: {
                            HStack(spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 5).fill(Color.teal.opacity(0.10))
                                    Image(systemName: "rectangle.3.group").foregroundStyle(.teal)
                                }.frame(width: 26, height: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(space.label).font(.system(size: 11, weight: .medium))
                                    Text("\(space.paneCount) panes · \(space.tabCount) tabs")
                                        .font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Circle().fill(space.agentStatus == "blocked" ? .red : space.agentStatus == "working" ? .orange : .green).frame(width: 5, height: 5)
                            }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.055), lineWidth: 0.75))
                        }.buttonStyle(.plain).help(space.workspaceID)
                    }
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(.secondary)
                TextField("Filter spaces by name…", text: $search).textFieldStyle(.plain).font(.custom("JetBrainsMono Nerd Font", size: 8))
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            }.padding(.horizontal, 8).padding(.vertical, 7).background(Color.black.opacity(0.025), in: Capsule()).overlay { Capsule().stroke(Color.black.opacity(0.08), lineWidth: 0.75) }
        }
        .foregroundStyle(Color.black.opacity(0.85))
        .task {
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
            }
        }
    }
}
