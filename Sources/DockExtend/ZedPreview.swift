import AppKit
import ApplicationServices
import SwiftUI

private struct ZedProjectWindow: Identifiable {
    let id: Int
    let title: String
    let element: AXUIElement
    let pid: pid_t
}

@MainActor
private final class ZedPreviewModel: ObservableObject {
    @Published var windows: [ZedProjectWindow] = []
    @Published var projects: [ZedSidebarProject] = []
    @Published var status = ""
    @Published var needsPermission = false

    func refresh() {
        windows = []
        projects = []
        needsPermission = false
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.zed.Zed")
        guard !apps.isEmpty else { status = "Zed is not running."; return }
        projects = ZedProjectStore.read()
        if !projects.isEmpty {
            status = "Open sidebar projects · click to switch"
            return
        }
        needsPermission = !AXIsProcessTrusted()
        guard !needsPermission else { status = "Sidebar state unavailable. Enable DockExtend in Accessibility to show windows instead."; return }
        for app in apps {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 1)
            var result: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &result) == .success,
                  let items = result as? [AXUIElement] else { continue }
            for window in items {
                var title: CFTypeRef?, subrole: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
                guard subrole as? String == kAXStandardWindowSubrole else { continue }
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
                windows.append(ZedProjectWindow(id: windows.count, title: (title as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled Zed window", element: window, pid: app.processIdentifier))
            }
        }
        status = !projects.isEmpty ? "Open sidebar projects · click to switch" : (windows.isEmpty ? "No Zed project windows available." : "Sidebar unavailable · showing windows")
    }

    func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        status = "Enable DockExtend in System Settings → Privacy & Security → Accessibility. If missing, use + to add DockExtend.app, then return and refresh."
    }

    func focus(_ window: ZedProjectWindow, reveal: () async -> Void) async {
        await reveal()
        guard let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated else { refresh(); return }
        app.unhide()
        AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        app.activate(options: [.activateIgnoringOtherApps])
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let raised = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        if raised != .success { status = "Could not focus this window. Refresh the list and try again." }
    }

    func focus(_ project: ZedSidebarProject, reveal: () async -> Void) async {
        await reveal()
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.zed.Zed") else { return }
        let cli = app.appendingPathComponent("Contents/MacOS/cli")
        let success = await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = cli
            process.arguments = project.paths
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning, Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
            if process.isRunning { process.terminate(); return false }
            return process.terminationStatus == 0
        }.value
        if !success { status = "Could not switch projects in Zed." }
    }
}

struct ZedHoverPanel: View {
    let reveal: () async -> Void
    @StateObject private var model = ZedPreviewModel()
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    private var filteredProjects: [ZedSidebarProject] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.projects.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
    }
    private var filteredWindows: [ZedProjectWindow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.windows.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
    }
    private var projectCount: Int { model.projects.isEmpty ? model.windows.count : model.projects.count }
    private var zedIcon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.zed.Zed")
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.08))
                    if let icon = zedIcon {
                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "app").foregroundStyle(.teal)
                    }
                }.frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Zed projects").font(.custom("JetBrainsMono Nerd Font", size: 12).weight(.medium))
                        Text("\(projectCount)")
                            .font(.custom("JetBrainsMono Nerd Font", size: 8))
                            .foregroundStyle(.teal).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                            .accessibilityLabel("\(projectCount) open projects")
                    }
                    Text("Open projects · click to switch")
                        .font(.custom("JetBrainsMono Nerd Font", size: 8)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh Zed windows")
            }
            if model.status != "Open sidebar projects · click to switch" {
                Text(model.status).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if model.needsPermission {
                Button("Open Accessibility Settings…") { model.requestPermission() }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    if !search.isEmpty, filteredProjects.isEmpty, (!model.projects.isEmpty || filteredWindows.isEmpty) {
                        Text("No matching projects").font(.system(size: 10)).foregroundStyle(.secondary).padding(.vertical, 16)
                    }
                    ForEach(filteredProjects) { project in
                        Button { Task { await model.focus(project, reveal: reveal) } } label: {
                            HStack(spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 5).fill(Color.teal.opacity(0.10))
                                    Image(systemName: "folder").foregroundStyle(.teal)
                                }.frame(width: 26, height: 26)
                                Text(project.title).font(.system(size: 11)).lineLimit(2)
                                Spacer()
                                Image(systemName: "arrow.up.forward").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.055), lineWidth: 0.75))
                        }.buttonStyle(.plain).help(project.paths.joined(separator: "\n"))
                    }
                    ForEach(model.projects.isEmpty ? filteredWindows : []) { window in
                        Button { Task { await model.focus(window, reveal: reveal) } } label: {
                            HStack(spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 5).fill(Color.teal.opacity(0.10))
                                    Image(systemName: "folder").foregroundStyle(.teal)
                                }.frame(width: 26, height: 26)
                                Text(window.title).font(.system(size: 11)).lineLimit(2)
                                Spacer()
                                Image(systemName: "arrow.up.forward").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.055), lineWidth: 0.75))
                        }.buttonStyle(.plain).help(window.title)
                    }
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(.secondary)
                TextField("Filter projects by name…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.custom("JetBrainsMono Nerd Font", size: 8))
                    .focused($searchFocused)
                    .accessibilityLabel("Filter projects by name")
                if !search.isEmpty {
                    Button { search = ""; searchFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain).help("Clear filter").accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(Color.black.opacity(0.025), in: Capsule())
            .overlay { Capsule().stroke(Color.black.opacity(0.08), lineWidth: 0.75) }
        }
        .foregroundStyle(Color.black.opacity(0.85))
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
        .task {
            while !Task.isCancelled {
                model.refresh()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
            }
        }
    }
}
