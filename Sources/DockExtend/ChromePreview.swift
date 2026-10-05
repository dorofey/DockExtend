import AppKit
import SwiftUI

private struct ChromeTab: Identifiable, Sendable {
    let windowID: Int
    let tabID: Int
    let title: String
    let url: String
    var id: String { "\(windowID):\(tabID)" }
    var site: String { URL(string: url)?.host ?? url }
}

@MainActor
private final class ChromePreviewModel: ObservableObject {
    @Published var tabs: [ChromeTab] = []
    @Published var status = ""
    @Published var loading = false
    @Published var needsPermission = false
    private static let queue = DispatchQueue(label: "DockExtend.chromeScripts", qos: .userInitiated)

    func refresh() async {
        guard !loading else { return }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty else {
            tabs = []; status = "Chrome is not running."; return
        }
        loading = true
        defer { loading = false }
        let result: ([ChromeTab], Int) = await withCheckedContinuation { continuation in
            Self.queue.async {
                let source = """
                with timeout of 10 seconds
                    tell application id "com.google.Chrome"
                        set results to {}
                        repeat with w in windows
                            if mode of w is "normal" then
                                repeat with t in tabs of w
                                    set end of results to {id of w, id of t, title of t, URL of t}
                                end repeat
                            end if
                        end repeat
                        return results
                    end tell
                end timeout
                """
                var error: NSDictionary?
                let response = NSAppleScript(source: source)?.executeAndReturnError(&error)
                var tabs: [ChromeTab] = []
                if let response, error == nil, response.numberOfItems > 0 {
                    for index in 1...response.numberOfItems {
                        guard let row = response.atIndex(index), row.numberOfItems == 4,
                              let window = row.atIndex(1)?.stringValue.flatMap(Int.init),
                              let tab = row.atIndex(2)?.stringValue.flatMap(Int.init) else { continue }
                        tabs.append(ChromeTab(windowID: window, tabID: tab, title: row.atIndex(3)?.stringValue ?? "Untitled tab", url: row.atIndex(4)?.stringValue ?? ""))
                    }
                }
                continuation.resume(returning: (tabs, (error?["NSAppleScriptErrorNumber"] as? Int) ?? 0))
            }
        }
        guard !Task.isCancelled else { return }
        tabs = result.0
        needsPermission = result.1 == -1743
        status = needsPermission ? "Allow DockExtend to control Google Chrome in System Settings → Privacy & Security → Automation, then refresh." :
            (result.1 != 0 ? "Could not read Chrome tabs. Refresh to try again." : (tabs.isEmpty ? "No open tabs in regular Chrome windows." : ""))
    }

    func focus(_ tab: ChromeTab, reveal: () async -> Void) async {
        await reveal()
        // Resolve stable tab IDs at click time so reordered tabs still focus correctly.
        let source = """
        with timeout of 10 seconds
            tell application id "com.google.Chrome"
                set targetWindow to window id \(tab.windowID)
                set tabIndex to 1
                repeat with t in tabs of targetWindow
                    if (id of t as string) is "\(tab.tabID)" then
                        set active tab index of targetWindow to tabIndex
                        set minimized of targetWindow to false
                        set index of targetWindow to 1
                        activate
                        return true
                    end if
                    set tabIndex to tabIndex + 1
                end repeat
                return false
            end tell
        end timeout
        """
        let success: Bool = await withCheckedContinuation { continuation in
            Self.queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                continuation.resume(returning: error == nil && result?.booleanValue == true)
            }
        }
        if !success { status = "This tab may have closed. Refresh and try again." }
    }
}

struct ChromeHoverPanel: View {
    let reveal: () async -> Void
    let makeKey: () -> Void
    @StateObject private var model = ChromePreviewModel()
    @State private var search = ""
    private var filtered: [ChromeTab] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.tabs.filter { query.isEmpty || $0.title.localizedStandardContains(query) || $0.url.localizedStandardContains(query) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.08))
                    if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().scaledToFit().frame(width: 20, height: 20)
                    }
                }.frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Chrome tabs").font(.custom("JetBrainsMono Nerd Font", size: 12).weight(.medium))
                        Text("\(model.tabs.count)").font(.custom("JetBrainsMono Nerd Font", size: 8))
                            .foregroundStyle(.teal).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Text("Open tabs · click to switch").font(.custom("JetBrainsMono Nerd Font", size: 8)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                else { Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Refresh Chrome tabs") }
            }
            if !model.status.isEmpty { Text(model.status).font(.system(size: 10)).foregroundStyle(.secondary) }
            if model.needsPermission {
                Button("Open Automation Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    if !search.isEmpty, filtered.isEmpty { Text("No matching tabs").font(.system(size: 10)).foregroundStyle(.secondary).padding(.vertical, 16) }
                    ForEach(filtered) { tab in
                        Button { Task { await model.focus(tab, reveal: reveal) } } label: {
                            HStack(spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 5).fill(Color.blue.opacity(0.10))
                                    Image(systemName: "globe").foregroundStyle(.blue)
                                }.frame(width: 26, height: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tab.title).font(.system(size: 11)).lineLimit(1)
                                    Text(tab.site).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.forward").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.055), lineWidth: 0.75))
                        }.buttonStyle(.plain).help(tab.url)
                    }
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(.secondary)
                TextField("Filter tabs by title or URL…", text: $search).textFieldStyle(.plain)
                    .font(.custom("JetBrainsMono Nerd Font", size: 8)).accessibilityLabel("Filter Chrome tabs")
                    .onTapGesture { makeKey() }
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Clear filter")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(Color.black.opacity(0.025), in: Capsule())
            .overlay { Capsule().stroke(Color.black.opacity(0.08), lineWidth: 0.75) }
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
