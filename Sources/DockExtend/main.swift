import AppKit
import CoreLocation
import EventKit
import SwiftUI
import UniformTypeIdentifiers

private extension Notification.Name {
    static let showDockSettings = Notification.Name("DockExtend.showDockSettings")
    static let dismissExpandedWidget = Notification.Name("DockExtend.dismissExpandedWidget")
    static let dockWidthChanged = Notification.Name("DockExtend.dockWidthChanged")
}

private final class DockWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var dockWindows: [String: DockWindow] = [:]
    private var orientations: [String: DockOrientation] = [:]
    private var placingWindows = false
    private var settingsWindow: NSWindow?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.dorofeev.DockExtend")
            .first(where: { $0.processIdentifier != currentPID }) {
            existing.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        synchronizeDockWindows()
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            NotificationCenter.default.post(name: .dismissExpandedWidget, object: nil)
        }
        NotificationCenter.default.addObserver(forName: .dockWidthChanged, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
            guard let self, let id = notification.userInfo?["dockID"] as? String,
                  let window = self.dockWindows[id],
                  let width = notification.userInfo?["width"] as? CGFloat,
                  let height = notification.userInfo?["height"] as? CGFloat else { return }
            guard abs(window.frame.width - width) > 1 || abs(window.frame.height - height) > 1 else { return }
            self.placingWindows = true
            window.setContentSize(NSSize(width: width, height: height))
            self.placingWindows = false
            self.placeDock(id)
            }
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard self != nil else { return }
            if !NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(NSEvent.mouseLocation) }) {
                NotificationCenter.default.post(name: .dismissExpandedWidget, object: nil)
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dockWindows.keys.forEach { self?.placeDock($0) } } }
        NotificationCenter.default.addObserver(
            forName: .showDockSettings,
            object: nil,
            queue: .main
        ) { [weak self] notification in MainActor.assumeIsolated { self?.showSettings(dockID: notification.userInfo?["dockID"] as? String) } }
        NotificationCenter.default.addObserver(forName: .dockProfilesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.synchronizeDockWindows() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    }

    private func synchronizeDockWindows() {
        let profiles = DockProfiles.shared.profiles
        let liveIDs = Set(profiles.map(\.id))
        for id in Array(dockWindows.keys) where !liveIDs.contains(id) {
            dockWindows.removeValue(forKey: id)?.close(); orientations.removeValue(forKey: id)
        }
        for profile in profiles {
            let window: DockWindow
            if let existing = dockWindows[profile.id] { window = existing }
            else {
                window = DockWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 70), styleMask: [.borderless], backing: .buffered, defer: false)
                window.identifier = NSUserInterfaceItemIdentifier(profile.id)
                window.delegate = self; window.isOpaque = false; window.backgroundColor = .clear
                window.hasShadow = false; window.level = .popUpMenu
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenNone]
                window.isMovableByWindowBackground = false; window.isReleasedWhenClosed = false
                dockWindows[profile.id] = window
            }
            if orientations[profile.id] != profile.orientation {
                NotificationCenter.default.post(name: .dismissExpandedWidget, object: nil)
                let defaults = DockProfiles.shared.defaults(for: profile.id)
                window.contentView = NSHostingView(rootView: DockView(dockID: profile.id, orientation: profile.orientation, dockDefaults: defaults).defaultAppStorage(defaults))
                orientations[profile.id] = profile.orientation
            }
            placeDock(profile.id); window.orderFrontRegardless()
        }
    }

    private func placeDock(_ id: String) {
        guard let window = dockWindows[id], let profile = DockProfiles.shared.profiles.first(where: { $0.id == id }),
              let screen = NSScreen.screens.first(where: { DockProfiles.displayID($0) == profile.displayID }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.frame, displayID = DockProfiles.displayID(screen)
        let saved = profile.positions[displayID]
        let index = DockProfiles.shared.profiles.firstIndex(where: { $0.id == id }) ?? 0
        let initial = CGPoint(x: frame.midX - window.frame.width / 2 + CGFloat(index * 24), y: frame.minY + CGFloat(index * 80))
        let origin = CGPoint(x: min(max(saved?.x ?? initial.x, frame.minX), max(frame.minX, frame.maxX - window.frame.width)),
                             y: min(max(saved?.y ?? initial.y, frame.minY), max(frame.minY, frame.maxY - window.frame.height)))
        placingWindows = true; window.setFrameOrigin(origin); placingWindows = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !placingWindows, let window = notification.object as? DockWindow,
              let id = window.identifier?.rawValue, let screen = window.screen,
              var profile = DockProfiles.shared.profiles.first(where: { $0.id == id }) else { return }
        let display = DockProfiles.displayID(screen)
        profile.displayID = display
        profile.positions[display] = DockPosition(x: window.frame.minX, y: window.frame.minY)
        DockProfiles.shared.update(profile, notify: false)
    }

    private func showSettings(dockID: String? = nil) {
        if let settingsWindow {
            settingsWindow.contentView = NSHostingView(rootView: DockSettingsRoot(initialID: dockID ?? DockProfiles.shared.profiles.first!.id))
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settings = NSHostingView(rootView: DockSettingsRoot(initialID: dockID ?? DockProfiles.shared.profiles.first!.id))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 650),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Dock Extend Settings"
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = settings
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}

private enum WidgetKind: String, CaseIterable, Identifiable {
    case focus
    case weather
    case note
    case music
    case herdr
    case calendar
    case usage
    case runningApps
    case flashspace

    var id: String { rawValue }
    var name: String {
        switch self {
        case .focus: "Focus timer"
        case .weather: "Weather"
        case .note: "Quick note"
        case .music: "Music controls"
        case .herdr: "Herdr agents"
        case .calendar: "Calendar"
        case .usage: "LLM usage"
        case .runningApps: "Running apps"
        case .flashspace: "Spaces"
        }
    }
}

private struct WidgetBoundsKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct DockView: View {
    let dockID: String
    let orientation: DockOrientation
    let dockDefaults: UserDefaults
    @State private var barSize = CGSize(width: 400, height: 70)
    private var availableSize: CGSize {
        let display = DockProfiles.shared.profiles.first(where: { $0.id == dockID })?.displayID
        let screen = NSScreen.screens.first(where: { DockProfiles.displayID($0) == display }) ?? NSScreen.main
        return CGSize(width: (screen?.frame.width ?? 1200) - 16, height: (screen?.visibleFrame.height ?? 800) - 16)
    }
    private var dockLayout: AnyLayout {
        orientation == .horizontal ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
    }
    @State private var showSlackPreview = false
    @State private var showZedPreview = false
    @State private var showChromePreview = false
    @State private var showHerdrSpacesPreview = false
    @State private var herdrSpacesHoverTask: Task<Void, Never>?
    @State private var showFinderSpacesPreview = false
    @State private var finderSpacesHoverTask: Task<Void, Never>?
    @State private var chromeHoverTask: Task<Void, Never>?
    @State private var zedHoverTask: Task<Void, Never>?
    @State private var slackHoverTask: Task<Void, Never>?
    @AppStorage("dock.backdropOpacity") private var backdropOpacity = 0.45
    @AppStorage("dock.horizontalPadding") private var horizontalPadding = 6.0
    @AppStorage("dock.verticalPadding") private var verticalPadding = 4.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedWidget: WidgetKind?
    @State private var selectedFolderID: String?
    @State private var draggedDockItemID: String?
    @ObservedObject private var herdrState = HerdrStatusModel.shared
    @ObservedObject private var flashspaceState = FlashSpaceModel.shared
    @ObservedObject private var runningAppsState = LauncherRunningAppsModel.shared
    @AppStorage("dock.displayMode") private var displayModeRaw = DisplayMode.compact.rawValue
    @AppStorage("dock.itemOrder") private var itemOrderRaw = DockOrder.defaultRaw
    @AppStorage("launcher.apps") private var appsRaw = AppCatalog.defaultJSON
    @AppStorage("launcher.folders") private var foldersRaw = "[]"
    @AppStorage("widget.focus.visible") private var showFocus = true
    @AppStorage("widget.weather.visible") private var showWeather = true
    @AppStorage("widget.note.visible") private var showNote = false
    @AppStorage("widget.music.visible") private var showMusic = true
    @AppStorage("widget.herdr.visible") private var showHerdr = true
    @AppStorage("widget.calendar.visible") private var showCalendar = true
    @AppStorage("widget.usage.visible") private var showUsage = true
    @AppStorage("widget.runningApps.visible") private var showRunningApps = true
    @AppStorage("widget.flashspace.visible") private var showFlashSpace = true

    private var isExpanded: Bool {
        displayModeRaw == DisplayMode.expanded.rawValue
    }

    private var launcherApps: [LauncherApp] { AppCatalog.decode(appsRaw) }
    private var folders: [AppFolder] { FolderCatalog.decode(foldersRaw) }

    private var visibleDockItemIDs: [String] {
        var visible = launcherApps.map { "app:\($0.id)" }
        visible.append(contentsOf: folders.map { "folder:\($0.id)" })
        if showFocus { visible.append("widget:focus") }
        if showWeather { visible.append("widget:weather") }
        if showNote { visible.append("widget:note") }
        if showMusic { visible.append("widget:music") }
        if showHerdr { visible.append("widget:herdr") }
        if showCalendar { visible.append("widget:calendar") }
        if showUsage { visible.append("widget:usage") }
        if showRunningApps { visible.append("widget:runningApps") }
        if showFlashSpace { visible.append("widget:flashspace") }
        return visible
    }

    private var orderedDockItemIDs: [String] {
        let visible = Set(visibleDockItemIDs)
        let saved = DockOrder.decode(itemOrderRaw)
        return saved.filter { visible.contains($0) } + visibleDockItemIDs.filter { !saved.contains($0) }
    }

    var body: some View {
        ScrollView(orientation == .horizontal ? .horizontal : .vertical, showsIndicators: false) {
        dockLayout {
            DockMoveHandle().frame(width: 14, height: 24).help("Drag to move dock")
            ForEach(orderedDockItemIDs, id: \.self) { itemID in
                dockItem(itemID)
                    .modifier(DockHoverModifier(isApp: itemID.hasPrefix("app:"), isDragging: draggedDockItemID != nil))
            }

            Menu {
                Button("Customize widgets…") {
                    NotificationCenter.default.post(name: .showDockSettings, object: nil, userInfo: ["dockID": dockID])
                }
                Divider()
                Button("Quit Dock Extend") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "plus")
                    .font(.custom("JetBrainsMono Nerd Font", size: 13).weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 27, height: 27)
                    .background(Color.ink, in: Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Customize dock")
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .modifier(DockGlassBackdrop(opacity: backdropOpacity))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.18 * backdropOpacity), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.20 * backdropOpacity), radius: 20, y: 10)
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { dismissPanels() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dismissExpandedWidget)) { _ in
            dismissPanels()
        }
        .animation(.easeOut(duration: 0.2), value: isExpanded)
        .environment(\.controlActiveState, .active)
        .fixedSize()
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { reportSize(proxy.size) }
                    .onChange(of: proxy.size) { size in reportSize(size) }
            }
        }
        }
        .frame(width: min(barSize.width, availableSize.width), height: min(barSize.height, availableSize.height))
        .background {
            Color.clear.contentShape(Rectangle()).onTapGesture { dismissPanels() }
        }
        .overlayPreferenceValue(WidgetBoundsKey.self) { anchors in
            GeometryReader { proxy in
                if showFinderSpacesPreview, let finder = launcherApps.first(where: { $0.bundleIdentifier == "com.apple.finder" }), let anchor = anchors["app:\(finder.id)"] {
                    let bounds = proxy[anchor]
                    detailPanel(FlashSpaceExpandedView(showFinderHeader: true).modifier(FloatingPanelSurface(width: 330, height: 590)), width: 330, height: 590, anchor: bounds, hoverID: finder.id)
                } else if showHerdrSpacesPreview, let ghostty = launcherApps.first(where: { $0.bundleIdentifier == "com.mitchellh.ghostty" }), let anchor = anchors["app:\(ghostty.id)"] {
                    let bounds = proxy[anchor]
                    detailPanel(HerdrSpacesHoverPanel().modifier(FloatingPanelSurface(width: 340, height: 590)), width: 340, height: 590, anchor: bounds, hoverID: ghostty.id)
                } else if showSlackPreview, let slack = launcherApps.first(where: { $0.bundleIdentifier == "com.tinyspeck.slackmacgap" }), let anchor = anchors["app:\(slack.id)"] {
                    let bounds = proxy[anchor]
                    detailPanel(SlackHoverPanel().modifier(FloatingPanelSurface(width: 330, height: 590)), width: 330, height: 590, anchor: bounds, hoverID: slack.id)
                } else if showChromePreview, let chrome = launcherApps.first(where: { $0.bundleIdentifier == "com.google.Chrome" }), let anchor = anchors["app:\(chrome.id)"] {
                    let bounds = proxy[anchor]
                    detailPanel(ChromeHoverPanel(reveal: { await FlashSpaceModel.shared.revealApplication("com.google.Chrome") }, makeKey: {
                        NSApp.activate(ignoringOtherApps: true)
                    })
                        .modifier(FloatingPanelSurface(width: 360, height: 590))
                        , width: 360, height: 590, anchor: bounds, hoverID: chrome.id)
                } else if showZedPreview, let zed = launcherApps.first(where: { $0.bundleIdentifier == "dev.zed.Zed" }), let anchor = anchors["app:\(zed.id)"] {
                    let bounds = proxy[anchor]
                    detailPanel(ZedHoverPanel(reveal: { await FlashSpaceModel.shared.revealApplication("dev.zed.Zed") })
                        .modifier(FloatingPanelSurface(width: 330, height: 590))
                        , width: 330, height: 590, anchor: bounds, hoverID: zed.id)
                } else if let folder = folders.first(where: { $0.id == selectedFolderID }), let anchor = anchors["folder:\(folder.id)"] {
                    let bounds = proxy[anchor]
                    detailPanel(FolderExpandedView(folder: folder)
                        .modifier(FloatingPanelSurface(width: 250, height: FolderExpandedView.panelHeight(for: folder)))
                        .id(folder.id)
                        , width: 250, height: FolderExpandedView.panelHeight(for: folder), anchor: bounds)
                } else if let kind = selectedWidget, let anchor = anchors["widget:\(kind.rawValue)"] {
                    let bounds = proxy[anchor]
                    detailPanel(ExpandedWidget(kind: kind)
                        .id(kind)
                        , width: ExpandedWidget.panelWidth(for: kind), height: ExpandedWidget.panelHeight(for: kind), anchor: bounds)
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.86), value: selectedWidget)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.86), value: selectedFolderID)
        }
        .onAppear { synchronizeOrder() }
        .onDisappear { dismissPanels() }
        .onChange(of: visibleDockItemIDs) { _ in synchronizeOrder() }
        .onChange(of: draggedDockItemID) { item in if item != nil { dismissPanels() } }
        .onExitCommand { dismissPanels() }
    }

    private func reportSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        barSize = size
        NotificationCenter.default.post(name: .dockWidthChanged, object: nil, userInfo: ["dockID": dockID, "width": min(size.width, availableSize.width), "height": min(size.height, availableSize.height)])
    }

    private func detailPanel<Content: View>(_ content: Content, width: CGFloat, height: CGFloat, anchor: CGRect, hoverID: String? = nil) -> some View {
        DockDetailPanel(content: AnyView(content), size: CGSize(width: width, height: height), vertical: orientation == .vertical, defaults: dockDefaults, hoverID: hoverID, onHoverDismiss: hoverID == nil ? nil : { dismissPanels() })
            .frame(width: anchor.width, height: anchor.height)
            .position(x: anchor.midX, y: anchor.midY)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func widgetCard(for widget: WidgetKind) -> some View {
        switch widget {
        case .focus:
            WidgetCard(icon: "circle.lefthalf.filled", tint: .blue, title: "Focus", value: "Deep work", detail: "48 min left", isExpanded: isExpanded)
        case .weather:
            WeatherWidget(isExpanded: isExpanded)
        case .note:
            WidgetCard(icon: "note.text", tint: .purple, title: "Quick note", value: "Ship it.", detail: "Take a walk.", isExpanded: isExpanded)
        case .music:
            MusicWidget(isExpanded: isExpanded)
        case .herdr:
            HerdrWidget(isExpanded: isExpanded)
        case .calendar:
            CalendarWidget()
        case .usage:
            UsageWidget()
        case .runningApps:
            RunningAppsWidget(isExpanded: isExpanded)
        case .flashspace:
            FlashSpaceWidget(isExpanded: isExpanded)
        }
    }

    @ViewBuilder
    private func dockItem(_ itemID: String) -> some View {
        if itemID.hasPrefix("widget:"), let kind = WidgetKind(rawValue: String(itemID.dropFirst("widget:".count))) {
            if [.calendar, .usage, .runningApps].contains(kind) {
                expandableWidget(kind)
                    .overlay(alignment: .top) {
                        if selectedWidget == kind {
                            RoundedRectangle(cornerRadius: kind == .calendar ? 12 : 8, style: .continuous)
                                .strokeBorder(Color.green, lineWidth: 1.5)
                                .frame(
                                    width: kind == .runningApps ? 37 : nil,
                                    height: kind == .calendar ? 52 : 37
                                )
                                .offset(y: kind == .runningApps ? 4 : 0)
                                .allowsHitTesting(false)
                        }
                    }
                    .modifier(DockReorderModifier(itemID: itemID, orderRaw: $itemOrderRaw, draggedItemID: $draggedDockItemID))
                    .anchorPreference(key: WidgetBoundsKey.self, value: .bounds) { ["widget:\(kind.rawValue)": $0] }
            } else {
                widgetCard(for: kind)
                    .onTapGesture { toggleWidget(kind) }
                    .overlay(alignment: .top) {
                        if selectedWidget == kind {
                            RoundedRectangle(cornerRadius: [.herdr, .music].contains(kind) ? 12 : 8, style: .continuous)
                                .strokeBorder(Color.green, lineWidth: 1.5)
                                .frame(height: [.herdr, .music].contains(kind) ? 52 : 37)
                                .allowsHitTesting(false)
                        }
                    }
                    .modifier(DockReorderModifier(itemID: itemID, orderRaw: $itemOrderRaw, draggedItemID: $draggedDockItemID))
                    .anchorPreference(key: WidgetBoundsKey.self, value: .bounds) { ["widget:\(kind.rawValue)": $0] }
            }
        } else if let folder = folders.first(where: { "folder:\($0.id)" == itemID }) {
            AppFolderWidget(folder: folder)
                .onTapGesture {
                    showChromePreview = false; chromeHoverTask?.cancel()
                    showZedPreview = false; zedHoverTask?.cancel()
                    showSlackPreview = false
                    slackHoverTask?.cancel()
                    selectedWidget = nil
                    selectedFolderID = selectedFolderID == folder.id ? nil : folder.id
                }
                .overlay(alignment: .top) {
                    if selectedFolderID == folder.id {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.green, lineWidth: 1.5)
                            .frame(width: 37, height: 37)
                            .offset(y: 4)
                            .allowsHitTesting(false)
                    }
                }
                .modifier(DockReorderModifier(itemID: itemID, orderRaw: $itemOrderRaw, draggedItemID: $draggedDockItemID))
                .anchorPreference(key: WidgetBoundsKey.self, value: .bounds) { [itemID: $0] }
        } else if itemID.hasPrefix("app:"), let app = launcherApps.first(where: { "app:\($0.id)" == itemID }) {
            LauncherAppIcon(app: app)
                .contextMenu {
                    if app.bundleIdentifier == "com.tinyspeck.slackmacgap" {
                        Button("Unread direct messages…") {
                            showChromePreview = false; chromeHoverTask?.cancel()
                            showZedPreview = false; zedHoverTask?.cancel()
                            slackHoverTask?.cancel()
                            selectedWidget = nil; selectedFolderID = nil; showSlackPreview = true
                        }
                    } else if app.bundleIdentifier == "dev.zed.Zed" {
                        Button("Open projects…") {
                            dismissPanels()
                            showZedPreview = true
                        }
                    } else if app.bundleIdentifier == "com.google.Chrome" {
                        Button("Open tabs…") { dismissPanels(); showChromePreview = true }
                    } else if app.bundleIdentifier == "com.mitchellh.ghostty" {
                        Button("Herdr spaces…") { dismissPanels(); showHerdrSpacesPreview = true }
                    } else if app.bundleIdentifier == "com.apple.finder" {
                        Button("Workspaces…") { dismissPanels(); showFinderSpacesPreview = true }
                    }
                }
                .onHover { hovering in
                    if app.bundleIdentifier == "com.tinyspeck.slackmacgap" { slackHover(hovering) }
                    if app.bundleIdentifier == "dev.zed.Zed" { zedHover(hovering) }
                    if app.bundleIdentifier == "com.mitchellh.ghostty" { herdrSpacesHover(hovering) }
                    if app.bundleIdentifier == "com.apple.finder" { finderSpacesHover(hovering) }
                    if app.bundleIdentifier == "com.google.Chrome" { chromeHover(hovering) }
                }
                .anchorPreference(key: WidgetBoundsKey.self, value: .bounds) { [itemID: $0] }
                .modifier(DockReorderModifier(itemID: itemID, orderRaw: $itemOrderRaw, draggedItemID: $draggedDockItemID))
        }
    }

    @ViewBuilder
    private func expandableWidget(_ kind: WidgetKind) -> some View {
        widgetCard(for: kind)
            .onTapGesture { toggleWidget(kind) }
    }

    private func toggleWidget(_ kind: WidgetKind) {
        showHerdrSpacesPreview = false; herdrSpacesHoverTask?.cancel()
        showFinderSpacesPreview = false; finderSpacesHoverTask?.cancel()
        showChromePreview = false; chromeHoverTask?.cancel()
        showZedPreview = false; zedHoverTask?.cancel()
        showSlackPreview = false
        slackHoverTask?.cancel()
        selectedFolderID = nil
        selectedWidget = selectedWidget == kind ? nil : kind
    }

    private func dismissPanels() {
        showHerdrSpacesPreview = false; herdrSpacesHoverTask?.cancel()
        showFinderSpacesPreview = false; finderSpacesHoverTask?.cancel()
        showChromePreview = false; chromeHoverTask?.cancel()
        showZedPreview = false; zedHoverTask?.cancel()
        showSlackPreview = false
        slackHoverTask?.cancel()
        selectedWidget = nil
        selectedFolderID = nil
    }

    private func synchronizeOrder() {
        let saved = DockOrder.decode(itemOrderRaw)
        let missing = visibleDockItemIDs.filter { !saved.contains($0) }
        if !missing.isEmpty { itemOrderRaw = DockOrder.encode(saved + missing) }
    }

    private func slackHover(_ hovering: Bool) {
        slackHoverTask?.cancel()
        guard hovering, !showSlackPreview else { return }
        slackHoverTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 450_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            showSlackPreview = hovering
            if hovering { showChromePreview = false; chromeHoverTask?.cancel(); showHerdrSpacesPreview = false; herdrSpacesHoverTask?.cancel(); showFinderSpacesPreview = false; finderSpacesHoverTask?.cancel() }
            if hovering { selectedWidget = nil; selectedFolderID = nil; showZedPreview = false; zedHoverTask?.cancel() }
        }
    }

    private func zedHover(_ hovering: Bool) {
        zedHoverTask?.cancel()
        guard hovering, !showZedPreview else { return }
        zedHoverTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 450_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            showZedPreview = hovering
            if hovering { showChromePreview = false; chromeHoverTask?.cancel(); showHerdrSpacesPreview = false; herdrSpacesHoverTask?.cancel(); showFinderSpacesPreview = false; finderSpacesHoverTask?.cancel() }
            if hovering { selectedWidget = nil; selectedFolderID = nil; showSlackPreview = false; slackHoverTask?.cancel() }
        }
    }

    private func chromeHover(_ hovering: Bool) {
        chromeHoverTask?.cancel()
        guard hovering, !showChromePreview else { return }
        chromeHoverTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 450_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            showChromePreview = hovering
            if hovering {
                selectedWidget = nil; selectedFolderID = nil
                showSlackPreview = false; slackHoverTask?.cancel()
                showZedPreview = false; zedHoverTask?.cancel()
                showHerdrSpacesPreview = false; herdrSpacesHoverTask?.cancel()
                showFinderSpacesPreview = false; finderSpacesHoverTask?.cancel()
            }
        }
    }

    private func herdrSpacesHover(_ hovering: Bool) {
        herdrSpacesHoverTask?.cancel()
        guard hovering, !showHerdrSpacesPreview else { return }
        herdrSpacesHoverTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 450_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            showHerdrSpacesPreview = hovering
            if hovering {
                selectedWidget = nil; selectedFolderID = nil
                showSlackPreview = false; slackHoverTask?.cancel()
                showZedPreview = false; zedHoverTask?.cancel()
                showChromePreview = false; chromeHoverTask?.cancel()
                showFinderSpacesPreview = false; finderSpacesHoverTask?.cancel()
            }
        }
    }

    private func finderSpacesHover(_ hovering: Bool) {
        finderSpacesHoverTask?.cancel()
        guard hovering, !showFinderSpacesPreview else { return }
        finderSpacesHoverTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 450_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            showFinderSpacesPreview = hovering
            if hovering {
                selectedWidget = nil; selectedFolderID = nil
                showSlackPreview = false; slackHoverTask?.cancel()
                showZedPreview = false; zedHoverTask?.cancel()
                showChromePreview = false; chromeHoverTask?.cancel()
                showHerdrSpacesPreview = false; herdrSpacesHoverTask?.cancel()
            }
        }
    }

}

private struct ExpandedWidget: View {
    let kind: WidgetKind
    @ObservedObject private var herdr = HerdrStatusModel.shared
    @ObservedObject private var flashspace = FlashSpaceModel.shared
    @ObservedObject private var runningApps = LauncherRunningAppsModel.shared
    @StateObject private var usage = UsageModel()

    private var panelHeight: CGFloat {
        Self.panelHeight(for: kind)
    }

    static func panelWidth(for kind: WidgetKind) -> CGFloat {
        switch kind {
        case .weather: return 300
        case .runningApps: return 250
        case .calendar: return 330
        case .flashspace: return 330
        case .music: return 300
        case .herdr, .usage: return 420
        default: return 270
        }
    }

    static func panelHeight(for kind: WidgetKind) -> CGFloat {
        switch kind {
        case .herdr: return min(max(205, 166 + CGFloat(HerdrStatusModel.shared.agents.count) * 54), 520)
        case .weather: return 300
        case .calendar: return 380
        case .usage: return 500
        case .runningApps: return min(max(190, 154 + CGFloat(LauncherRunningAppsModel.shared.count) * 52), 520)
        case .music: return 350
        case .flashspace: return min(max(190, 80 + CGFloat(FlashSpaceModel.shared.workspaces.count) * 52), 520)
        default: return 112
        }
    }

    var body: some View {
        Group {
            switch kind {
            case .music:
                MusicExpandedView()
            case .herdr:
                HerdrExpandedView(model: herdr)
            case .weather:
                WeatherExpandedView()
            case .calendar:
                CalendarExpandedView()
            case .usage:
                VStack(alignment: .leading, spacing: 14) {
                    Text("AI Usage").font(.custom("JetBrainsMono Nerd Font", size: 15).weight(.semibold))
                    HStack(spacing: 0) {
                        Text("Codex").frame(maxWidth: .infinity).padding(10).background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                        Text("Claude").frame(maxWidth: .infinity).foregroundStyle(.secondary)
                    }.background(.white.opacity(0.08), in: Capsule())
                    Text("Codex").font(.custom("JetBrainsMono Nerd Font", size: 14).weight(.semibold))
                    Text("Personal").font(.custom("JetBrainsMono Nerd Font", size: 11)).foregroundStyle(.secondary)
                    usageBar("Codex today", usage.codexLabel, usage.codexProgress)
                    Text(usage.codexSessionsLabel)
                        .font(.custom("JetBrainsMono Nerd Font", size: 10))
                        .foregroundStyle(.secondary)
                    usageBar("Claude sessions", String(usage.claudeSessions), usage.claudeProgress)
                    Text("Local session activity · provider quota unavailable").font(.custom("JetBrainsMono Nerd Font", size: 10)).foregroundStyle(.secondary)
                    Divider()
                    HStack { Text("Codex sessions"); Spacer(); Text(usage.codexSessionsLabel).foregroundStyle(.secondary) }
                    HStack { Text("Tool calls"); Spacer(); Text("312").foregroundStyle(.secondary) }
                    HStack { Text("Codex tokens"); Spacer(); Text(usage.codexLabel).foregroundStyle(.secondary) }
                    Spacer()
                    Text("Local activity · provider quota unavailable").font(.custom("JetBrainsMono Nerd Font", size: 10)).foregroundStyle(.secondary)
                }
            case .runningApps:
                RunningAppsExpanded()
            case .flashspace:
                FlashSpaceExpandedView()
            default:
                EmptyView()
            }
        }
        .foregroundStyle(Color.ink)
        .padding(16)
        .frame(width: Self.panelWidth(for: kind), height: panelHeight, alignment: .leading)
        .background {
            Color.white.opacity(0.96)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.14), lineWidth: 1)
        }
        .compositingGroup()
        .shadow(color: .black.opacity([.herdr, .calendar, .runningApps, .music].contains(kind) ? 0.08 : 0.18), radius: [.herdr, .calendar, .runningApps, .music].contains(kind) ? 12 : 18, y: 8)
    }

    private func usageBar(_ label: String, _ value: String, _ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(label); Spacer(); Text(value) }
                .font(.custom("JetBrainsMono Nerd Font", size: 11))
            ProgressView(value: progress)
                .tint(Color.ink.opacity(0.82))
        }
    }
}

private struct OverflowScrollView<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Namespace private var coordinateSpace
    @State private var hasMoreBelow = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { viewport in
                ScrollView(.vertical, showsIndicators: false) {
                    content()
                        .frame(maxWidth: .infinity)
                        .background {
                            GeometryReader { contentGeometry in
                                let bottom = contentGeometry.frame(in: .named(coordinateSpace)).maxY
                                Color.clear
                                    .onAppear { hasMoreBelow = bottom > viewport.size.height + 1 }
                                    .onChange(of: bottom) { value in hasMoreBelow = value > viewport.size.height + 1 }
                            }
                        }
                }
                .coordinateSpace(name: coordinateSpace)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(0.65))
                .frame(maxWidth: .infinity)
                .frame(height: 12)
                .opacity(hasMoreBelow ? 1 : 0)
                .accessibilityLabel("More items below")
                .accessibilityHidden(!hasMoreBelow)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.12), value: hasMoreBelow)
        }
    }
}

private struct HerdrExpandedView: View {
    @ObservedObject private var herdr: HerdrStatusModel
    @State private var filter = "All"
    @State private var prompt = ""
    @AppStorage("terminal.choice") private var terminalChoiceRaw = TerminalChoice.ghostty.rawValue

    init(model: HerdrStatusModel) {
        _herdr = ObservedObject(wrappedValue: model)
    }

    private var filteredAgents: [HerdrAgent] {
        guard filter != "All" else { return herdr.agents }
        return herdr.agents.filter { $0.agentStatus.caseInsensitiveCompare(filter) == .orderedSame }
    }

    private struct AgentGroup: Identifiable {
        let id: String
        let label: String
        let agents: [HerdrAgent]
    }

    private var groupedAgents: [AgentGroup] {
        var groups: [String: [HerdrAgent]] = [:]
        for agent in filteredAgents { groups[agent.workspaceID, default: []].append(agent) }
        var order = herdr.spaceOrder.filter { groups[$0] != nil }
        for agent in filteredAgents where !order.contains(agent.workspaceID) { order.append(agent.workspaceID) }
        return order.map { AgentGroup(id: $0, label: herdr.spaceLabels[$0] ?? $0, agents: groups[$0] ?? []) }
    }

    private func stateCount(_ state: String) -> Int {
        herdr.agents.filter { $0.agentStatus.caseInsensitiveCompare(state) == .orderedSame }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.08))
                if let logo = HerdrLogo.image {
                    Image(nsImage: logo).resizable().scaledToFit().frame(width: 17, height: 17)
                } else {
                    Image(systemName: herdr.icon).font(.system(size: 15, weight: .medium)).foregroundStyle(.teal)
                }
                }.frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Herdr agents").font(.custom("JetBrainsMono Nerd Font", size: 12).weight(.medium))
                        Text("\(herdr.total)")
                            .font(.custom("JetBrainsMono Nerd Font", size: 8))
                            .foregroundStyle(.teal).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Text("Servicing local & cloud workers").font(.custom("JetBrainsMono Nerd Font", size: 8)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    HerdrController.openTerminal(TerminalChoice(rawValue: terminalChoiceRaw) ?? .ghostty)
                } label: {
                    Image(systemName: "terminal")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 28, height: 28)
                        .background(Color.teal.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                        .overlay { RoundedRectangle(cornerRadius: 7).stroke(Color.teal.opacity(0.25), lineWidth: 0.75) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.teal)
                .help("Open terminal")
                .accessibilityLabel("Open terminal")
                .disabled(!(TerminalChoice(rawValue: terminalChoiceRaw) ?? .ghostty).isInstalled)
            }

            Divider()

            HStack(spacing: 4) {
                filterButton("All", herdr.agents.count, nil)
                filterButton("Working", stateCount("working"), .orange)
                filterButton("Blocked", stateCount("blocked"), .red)
                filterButton("Idle", stateCount("idle"), .green)
                filterButton("Done", stateCount("done"), .blue)
                Spacer()
            }

            OverflowScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groupedAgents) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 5) {
                                Image(systemName: "rectangle.3.group").font(.system(size: 9)).foregroundStyle(.teal)
                                Text(group.label)
                                    .font(.custom("JetBrainsMono Nerd Font", size: 9).weight(.semibold))
                                    .foregroundStyle(Color.ink.opacity(0.75))
                                    .lineLimit(1)
                                Text("\(group.agents.count)")
                                    .font(.custom("JetBrainsMono Nerd Font", size: 7))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 3))
                                Spacer()
                            }
                            ForEach(group.agents) { agent in
                                agentRow(agent)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 6) {
                TextField("Assign prompt or task to Fleet…", text: $prompt)
                    .textFieldStyle(.plain).font(.custom("JetBrainsMono Nerd Font", size: 8))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color.black.opacity(0.025), in: Capsule())
                    .overlay { Capsule().stroke(Color.black.opacity(0.08), lineWidth: 0.75) }
                Button("Dispatch") { prompt = "" }
                    .font(.custom("JetBrainsMono Nerd Font", size: 8).weight(.semibold))
                    .buttonStyle(.plain).foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(Color.ink, in: Capsule())
            }
        }
    }

    private func agentRow(_ agent: HerdrAgent) -> some View {
        Button { HerdrController.focus(agent, terminal: TerminalChoice(rawValue: terminalChoiceRaw) ?? .ghostty) } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(agent.agent.lowercased().contains("claude") ? Color.orange.opacity(0.12) : Color.teal.opacity(0.08))
                    if let logo = AgentLogo.image(for: agent.agent) {
                        Image(nsImage: logo).resizable().scaledToFit().frame(width: 14, height: 14)
                    } else {
                        Text(agent.iconGlyph).font(.custom("JetBrainsMono Nerd Font", size: 13))
                    }
                }.frame(width: 23, height: 23)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.terminalTitle.isEmpty ? agent.agent.capitalized : agent.terminalTitle)
                        .font(.custom("JetBrainsMono Nerd Font", size: 10).weight(.medium)).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(agent.agent.capitalized)
                        Text("·")
                        Text(agent.tabID)
                        Text("·")
                        Text(agent.agentStatus.capitalized).foregroundStyle(agent.statusColor)
                    }
                    .font(.custom("JetBrainsMono Nerd Font", size: 8)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10)).foregroundStyle(Color.gray.opacity(0.45))
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.black.opacity(0.055), lineWidth: 0.75)
            }
            .shadow(color: .clear, radius: 0)
        }
        .buttonStyle(.plain)
        .help("Focus Herdr pane \(agent.id)")
    }

    private func filterButton(_ label: String, _ count: Int, _ color: Color?) -> some View {
        Button {
            filter = label
        } label: {
            HStack(spacing: 4) {
                if let color {
                    Circle().fill(color).frame(width: 6, height: 6)
                }
                Text("\(label) (\(count))")
            }
        }
            .font(.custom("JetBrainsMono Nerd Font", size: 8))
            .buttonStyle(.plain)
            .foregroundStyle(filter == label ? Color.white : Color.secondary)
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(filter == label ? Color.ink : Color.black.opacity(0.025), in: Capsule())
    }
}

private enum HerdrLogo {
    static var image: NSImage? {
        guard let url = Bundle.main.url(forResource: "HerdrLogo", withExtension: "svg") else { return nil }
        let image = NSImage(contentsOf: url)
        image?.isTemplate = true
        return image
    }
}

private enum AgentLogo {
    static func image(for agent: String) -> NSImage? {
        let name: String?
        switch agent.lowercased() {
        case "codex": name = "OpenAILogo"
        case "claude": name = "ClaudeLogo"
        default: name = nil
        }
        guard let name,
              let url = Bundle.main.url(forResource: name, withExtension: "svg") else { return nil }
        let image = NSImage(contentsOf: url)
        image?.isTemplate = true
        return image
    }
}

private struct RunningAppsWidget: View {
    let isExpanded: Bool
    @ObservedObject private var running = LauncherRunningAppsModel.shared

    private var apps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var body: some View {
        let previewApps = Array(apps.prefix(4))
        VStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.68)).frame(width: 37, height: 37)
                VStack(spacing: 2) {
                    ForEach(0..<2) { row in
                        HStack(spacing: 2) {
                            ForEach(0..<2) { column in
                                let index = row * 2 + column
                                if index < previewApps.count, let icon = previewApps[index].icon {
                                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 15, height: 15)
                                } else {
                                    Color.clear.frame(width: 15, height: 15)
                                }
                            }
                        }
                    }
                }
            }.frame(width: 45, height: 45)
            Text("Running")
                .font(.custom("JetBrainsMono Nerd Font", size: 7).weight(.medium)).lineLimit(1)
                .frame(width: 45, height: 5)
        }
        .contentShape(Rectangle())
        .help("\(apps.count) running apps")
    }
}

private struct CalendarWidget: View {
    @StateObject private var calendar: CalendarModel
    private let displayedEventCount = 3

    init() {
        _calendar = StateObject(wrappedValue: CalendarModel(showsUpcomingEvents: true))
    }

    private var weekday: String {
        Date().formatted(.dateTime.weekday(.abbreviated)).uppercased()
    }

    private var day: String {
        Date().formatted(.dateTime.day())
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(spacing: 0) {
                Text(weekday)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.red)
                Text(day)
                    .font(.system(size: 21, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.ink)
            }
            .frame(width: 38, height: 42)
            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(spacing: 2) {
                if !calendar.hasAccess {
                    calendarMessage("Calendar access required", color: .orange)
                } else if calendar.events.isEmpty {
                    calendarMessage("No events today", color: .green)
                } else {
                    ForEach(Array(calendar.events.prefix(displayedEventCount))) { event in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(event.color)
                                .frame(width: 5, height: 5)
                            Text(event.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.ink)
                                .lineLimit(1)
                            Spacer(minLength: 5)
                            Text(event.time)
                                .font(.system(size: 9, weight: .regular, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(height: 12)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 286, height: 52)
        .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.black.opacity(0.09), lineWidth: 0.75)
        }
        .help("\(calendar.events.count) upcoming calendar events")
    }

    private func calendarMessage(_ message: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(message)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}

private struct CalendarEvent: Identifiable, Sendable {
    let id: String
    let title: String
    let time: String
    let calendarName: String
    let color: Color
    let isAllDay: Bool
}

@MainActor
private final class CalendarModel: ObservableObject {
    @Published private(set) var events: [CalendarEvent] = []
    @Published private(set) var hasAccess = false
    private let store = EKEventStore()
    private let showsUpcomingEvents: Bool

    init(showsUpcomingEvents: Bool = false) {
        self.showsUpcomingEvents = showsUpcomingEvents
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.loadEvents() }
        }
        loadEvents()
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            if #available(macOS 14.0, *) {
                store.requestFullAccessToEvents { [weak self] _, _ in
                    Task { @MainActor in self?.loadEvents() }
                }
            } else {
                store.requestAccess(to: .event) { [weak self] _, _ in
                    Task { @MainActor in self?.loadEvents() }
                }
            }
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func loadEvents() {
        if #available(macOS 14.0, *) {
            hasAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        } else {
            hasAccess = EKEventStore.authorizationStatus(for: .event) == .authorized
        }
        guard hasAccess else { events = []; return }
        let calendar = Calendar.current
        let now = Date()
        let start = showsUpcomingEvents ? now : calendar.startOfDay(for: now)
        let end = showsUpcomingEvents
            ? (calendar.date(byAdding: .month, value: 3, to: now) ?? now)
            : (calendar.date(byAdding: .day, value: 1, to: start) ?? start)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let matchingEvents = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        let selectedEvents = showsUpcomingEvents ? Array(matchingEvents.prefix(3)) : matchingEvents
        events = selectedEvents.map {
            CalendarEvent(
                id: $0.eventIdentifier,
                title: $0.title ?? "Untitled event",
                time: eventTime(for: $0, now: now, calendar: calendar),
                calendarName: $0.calendar?.title ?? "Calendar",
                color: Color(nsColor: $0.calendar?.color ?? .systemBlue),
                isAllDay: $0.isAllDay
            )
        }
    }

    private func eventTime(for event: EKEvent, now: Date, calendar: Calendar) -> String {
        if !showsUpcomingEvents || calendar.isDate(event.startDate, inSameDayAs: now) {
            return event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened)
        }
        let weekday = event.startDate.formatted(.dateTime.weekday(.abbreviated))
        return event.isAllDay
            ? "\(weekday) · All day"
            : event.startDate.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

private struct CalendarExpandedView: View {
    @StateObject private var calendar = CalendarModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 14)).foregroundStyle(.red)
                    .frame(width: 28, height: 28)
                    .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Calendar").font(.custom("JetBrainsMono Nerd Font", size: 12).weight(.medium))
                    Text(Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        .font(.custom("JetBrainsMono Nerd Font", size: 8)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 11)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Open Calendar")
            }
            Divider()
            HStack {
                Text("Today").font(.custom("JetBrainsMono Nerd Font", size: 10).weight(.medium))
                Spacer()
                Text("\(calendar.events.count) events").font(.custom("JetBrainsMono Nerd Font", size: 8)).foregroundStyle(.secondary)
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 7) {
                    if !calendar.hasAccess {
                        Text("Allow calendar access in System Settings to see your events.")
                            .font(.custom("JetBrainsMono Nerd Font", size: 10)).foregroundStyle(.secondary).padding(.vertical, 12)
                    } else if calendar.events.isEmpty {
                        Text("No events today").font(.custom("JetBrainsMono Nerd Font", size: 10)).foregroundStyle(.secondary).padding(.vertical, 12)
                    } else {
                        if calendar.events.contains(where: \.isAllDay) {
                            Text("All day").font(.custom("JetBrainsMono Nerd Font", size: 8)).foregroundStyle(.secondary)
                            ForEach(calendar.events.filter(\.isAllDay)) { event in eventRow(event) }
                        }
                        if calendar.events.contains(where: { !$0.isAllDay }) {
                            ForEach(calendar.events.filter { !$0.isAllDay }) { event in eventRow(event) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 4) {
                Circle().fill(calendar.hasAccess ? Color.teal : Color.orange).frame(width: 5, height: 5)
                Text(calendar.hasAccess ? "Your calendars" : "Calendar access required")
                    .font(.custom("JetBrainsMono Nerd Font", size: 8)).foregroundStyle(.secondary)
            }
        }
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 2).fill(event.color).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.custom("JetBrainsMono Nerd Font", size: 10).weight(.medium)).lineLimit(2)
                Text("\(event.time) · \(event.calendarName)")
                    .font(.custom("JetBrainsMono Nerd Font", size: 8)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.055), lineWidth: 0.75) }
    }
}

private struct UsageWidget: View {
    @StateObject private var usage = UsageModel()

    var body: some View {
        HStack(spacing: 10) {
            UsageRing(value: usage.codexRemaining, valueText: usage.codexRemainingLabel, title: "Codex", tint: .blue)
            UsageRing(value: usage.claudeRemaining, valueText: usage.claudeRemainingLabel, title: "Claude", tint: .blue)
        }
        .padding(.horizontal, 10)
        .frame(width: 122, height: 37)
        .background(.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.bottom, 7)
        .help("Codex today: \(usage.codexLabel); Claude sessions: \(usage.claudeSessions)")
    }
}

private struct UsageRing: View {
    let value: Double
    let valueText: String
    let title: String
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().stroke(tint.opacity(0.18), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.04, value))
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(valueText)
                    .font(.custom("JetBrainsMono Nerd Font", size: 10).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .frame(width: 24, height: 24)
            Text(title)
                .font(.custom("JetBrainsMono Nerd Font", size: 8))
                .foregroundStyle(.secondary)
        }
    }
}

private struct UsageSnapshot: Sendable {
    let codexTokens: Int
    let codexSessions: Int
    let claudeSessions: Int
}

@MainActor
private final class UsageModel: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot(codexTokens: 0, codexSessions: 0, claudeSessions: 0)
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }

    deinit { timer?.invalidate() }

    var codexLabel: String {
        let millions = Double(snapshot.codexTokens) / 1_000_000
        return millions >= 1 ? String(format: "%.1fM", millions) : "\(snapshot.codexTokens / 1_000)K"
    }

    var claudeSessions: Int { snapshot.claudeSessions }
    var codexSessionsLabel: String { "\(snapshot.codexSessions) sessions" }

    var codexProgress: Double { min(Double(snapshot.codexTokens) / 60_000_000, 1) }
    var claudeProgress: Double { min(Double(snapshot.claudeSessions) / 20, 1) }
    var codexRemaining: Double { 1 - codexProgress }
    var claudeRemaining: Double { 1 - claudeProgress }
    var codexRemainingLabel: String { "\(Int(codexRemaining * 100))%" }
    var claudeRemainingLabel: String { "\(Int(claudeRemaining * 100))%" }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let value = Self.read()
            DispatchQueue.main.async { self?.snapshot = value }
        }
    }

    private nonisolated static func read() -> UsageSnapshot {
        let codex = queryCodex()
        let claudeURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/sessions")
        let start = Calendar.current.startOfDay(for: Date())
        let claudeSessions = (try? FileManager.default.contentsOfDirectory(at: claudeURL, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles))?.filter {
            guard let date = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
            return $0.pathExtension == "json" && date >= start
        }.count ?? 0
        return UsageSnapshot(codexTokens: codex.tokens, codexSessions: codex.sessions, claudeSessions: claudeSessions)
    }

    private nonisolated static func queryCodex() -> (tokens: Int, sessions: Int) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        let database = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/state_5.sqlite").path
        process.arguments = [database, "select coalesce(sum(tokens_used),0) || '|' || count(*) from threads where created_at >= strftime('%s','now','start of day');"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let values = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
            return (Int(values.first ?? "0") ?? 0, Int(values.dropFirst().first ?? "0") ?? 0)
        } catch {
            return (0, 0)
        }
    }
}

@MainActor
private final class WeatherModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherModel()
    @Published var locality = "Oslo"
    @Published var isFallback = true
    @Published var forecast: WeatherResponse?
    @Published var updated: Date?
    @Published var error: String?
    @Published var loading = false
    private var coordinate = CLLocationCoordinate2D(latitude: 59.9139, longitude: 10.7522)
    private var request: Task<Void, Never>?
    private var timer: Timer?
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        refresh()
        manager.requestWhenInUseAuthorization()
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if self.manager.authorizationStatus == .authorizedAlways {
                self.manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            coordinate = location.coordinate
            isFallback = false
            locality = "Current location"
            forecast = nil
            updated = nil
            refresh()
            guard let placemark = try? await geocoder.reverseGeocodeLocation(location),
                  let name = placemark.first?.locality ?? placemark.first?.administrativeArea else { return }
            locality = name
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    func refresh() {
        request?.cancel()
        loading = true
        var components = URLComponents(string: "https://api.met.no/weatherapi/locationforecast/2.0/compact")!
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.4f", coordinate.longitude))
        ]
        let url = components.url!
        request = Task {
            do {
                var urlRequest = URLRequest(url: url, timeoutInterval: 20)
                urlRequest.setValue("DockExtend/0.1 (personal macOS prototype; github.com/dorofey)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: urlRequest)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let met = try decoder.decode(METForecast.self, from: data)
                let value = try WeatherResponse(met: met)
                try Task.checkCancellation()
                forecast = value
                updated = Date()
                error = nil
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Weather unavailable · retry"
                loading = false
            }
        }
    }
}

private struct METForecast: Decodable {
    struct Properties: Decodable {
        let timeseries: [Entry]
    }
    struct Entry: Decodable {
        struct Values: Decodable {
            struct Instant: Decodable {
                struct Details: Decodable { let air_temperature: Double }
                let details: Details
            }
            struct Period: Decodable {
                struct Summary: Decodable { let symbol_code: String }
                let summary: Summary
            }
            let instant: Instant
            let next_1_hours: Period?
            let next_6_hours: Period?
            let next_12_hours: Period?
        }
        let time: Date
        let data: Values
        var symbol: String { (data.next_1_hours ?? data.next_6_hours ?? data.next_12_hours)?.summary.symbol_code ?? "unknown" }
    }
    let properties: Properties
}

private struct WeatherResponse {
    struct Current: Decodable {
        let temperature_2m: Double
        let weather_code: String
        let is_day: Int
    }
    struct Hourly: Decodable {
        let time: [Double]
        let temperature_2m: [Double]
        let weather_code: [String]
        let is_day: [Int]
    }
    let current: Current
    let hourly: Hourly
    let utc_offset_seconds: Int

    init(met: METForecast) throws {
        let entries = met.properties.timeseries.filter { $0.time >= Date().addingTimeInterval(-3600) }
        guard let first = entries.first else { throw URLError(.cannotParseResponse) }
        current = Current(temperature_2m: first.data.instant.details.air_temperature, weather_code: first.symbol, is_day: first.symbol.hasSuffix("_night") ? 0 : 1)
        hourly = Hourly(time: entries.map { $0.time.timeIntervalSince1970 }, temperature_2m: entries.map { $0.data.instant.details.air_temperature }, weather_code: entries.map(\.symbol), is_day: entries.map { $0.symbol.hasSuffix("_night") ? 0 : 1 })
        utc_offset_seconds = TimeZone.current.secondsFromGMT()
    }

    var upcoming: [Int] {
        Array(hourly.time.indices.filter {
            hourly.time[$0] >= Date().timeIntervalSince1970 - 3600 &&
            $0 < hourly.temperature_2m.count && $0 < hourly.weather_code.count && $0 < hourly.is_day.count
        }.prefix(6))
    }
}

private func weatherCondition(_ code: String, day: Bool) -> (name: String, icon: String) {
    if code.contains("thunder") { return ("Thunderstorms", "cloud.bolt.rain.fill") }
    if code.contains("snow") { return ("Snow", "cloud.snow.fill") }
    if code.contains("sleet") { return ("Sleet", "cloud.sleet.fill") }
    if code.contains("rain") { return ("Rain", "cloud.rain.fill") }
    if code.contains("fog") { return ("Fog", "cloud.fog.fill") }
    if code.contains("clearsky") { return (day ? "Clear sky" : "Clear night", day ? "sun.max.fill" : "moon.stars.fill") }
    if code.contains("fair") || code.contains("partlycloudy") { return ("Partly cloudy", day ? "cloud.sun.fill" : "cloud.moon.fill") }
    return (code == "cloudy" ? "Overcast" : "Unknown conditions", "cloud.fill")
}

private struct WeatherExpandedView: View {
    @ObservedObject private var weather = WeatherModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("WEATHER", systemImage: "sun.max.fill")
                    .font(.custom("JetBrainsMono Nerd Font", size: 9).weight(.medium))
                Spacer()
                Text(weather.isFallback ? "OSLO · FALLBACK" : "MY LOCATION")
                    .font(.custom("JetBrainsMono Nerd Font", size: 8))
                    .foregroundStyle(.secondary)
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(weather.locality).font(.custom("JetBrainsMono Nerd Font", size: 12))
                    Text(weather.forecast.map { "\(Int($0.current.temperature_2m.rounded()))°" } ?? "—°")
                        .font(.custom("JetBrainsMono Nerd Font", size: 34).weight(.medium))
                    Text(weather.forecast.map { weatherCondition($0.current.weather_code, day: $0.current.is_day == 1).name } ?? (weather.loading ? "Loading weather…" : "Unavailable"))
                        .font(.custom("JetBrainsMono Nerd Font", size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: weather.forecast.map { weatherCondition($0.current.weather_code, day: $0.current.is_day == 1).icon } ?? "cloud.fill")
                    .font(.system(size: 52)).symbolRenderingMode(.multicolor)
            }.padding(.top, 22)
            Divider().padding(.vertical, 15)
            if let forecast = weather.forecast {
                HStack(spacing: 3) {
                    ForEach(forecast.upcoming, id: \.self) { index in
                        VStack(spacing: 9) {
                            Text(hourLabel(forecast.hourly.time[index], offset: forecast.utc_offset_seconds))
                                .font(.custom("JetBrainsMono Nerd Font", size: 8)).foregroundStyle(.secondary)
                            Image(systemName: weatherCondition(forecast.hourly.weather_code[index], day: forecast.hourly.is_day[index] == 1).icon)
                                .symbolRenderingMode(.multicolor).font(.system(size: 15))
                            Text("\(Int(forecast.hourly.temperature_2m[index].rounded()))°")
                                .font(.custom("JetBrainsMono Nerd Font", size: 10).weight(.medium))
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(index == forecast.upcoming.first ? Color.cyan.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            } else {
                Text("Hourly forecast unavailable").font(.custom("JetBrainsMono Nerd Font", size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack {
                Button { weather.refresh() } label: {
                    Text(weather.error ?? (weather.loading ? "Updating…" : weather.updated.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "Retry"))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Link(destination: URL(string: "https://www.yr.no/")!) {
                    Text(weather.error == nil ? "● Yr / MET Norway" : "● Offline").foregroundStyle(weather.error == nil ? Color.teal : Color.orange)
                }
            }.font(.custom("JetBrainsMono Nerd Font", size: 8))
        }
    }

    private func hourLabel(_ timestamp: Double, offset: Int) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: offset)
        formatter.dateFormat = "HH"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

private struct WeatherWidget: View {
    @ObservedObject private var weather = WeatherModel.shared
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: weather.forecast.map { weatherCondition($0.current.weather_code, day: $0.current.is_day == 1).icon } ?? "cloud.fill")
                .font(.system(size: 22))
                .symbolRenderingMode(.multicolor)
            Text(weather.forecast.map { "\(Int($0.current.temperature_2m.rounded()))°" } ?? "—°")
                .font(.custom("JetBrainsMono Nerd Font", size: 15).weight(.semibold))
        }
        .frame(width: 88, height: 37)
        .background(.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.bottom, 7)
        .help("Weather in \(weather.locality)\(weather.isFallback ? " (fallback location)" : "")")
    }
}

private struct RunningAppsExpanded: View {
    @AppStorage("launcher.apps") private var appsRaw = AppCatalog.defaultJSON
    @ObservedObject private var flashspace = FlashSpaceModel.shared
    @State private var search = ""
    @State private var apps: [NSRunningApplication] = []
    @FocusState private var searchFocused: Bool

    private func refreshApps() {
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != "com.dorofeev.DockExtend" }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private var filteredApps: [NSRunningApplication] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let dockBundleIDs = Set(AppCatalog.decode(appsRaw).compactMap(\.bundleIdentifier))
        return apps.filter { query.isEmpty || ($0.localizedName ?? "").localizedStandardContains(query) }
            .sorted { left, right in
                let leftInDock = left.bundleIdentifier.map { dockBundleIDs.contains($0) } ?? false
                let rightInDock = right.bundleIdentifier.map { dockBundleIDs.contains($0) } ?? false
                if leftInDock != rightInDock { return !leftInDock }
                return (left.localizedName ?? "").localizedStandardCompare(right.localizedName ?? "") == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Running apps")
                        .font(.custom("JetBrainsMono Nerd Font", size: 11).weight(.medium))
                    Text(search.isEmpty ? "\(apps.count) applications open" : "\(filteredApps.count) of \(apps.count) apps")
                        .font(.custom("JetBrainsMono Nerd Font", size: 8))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(Color.cyan).frame(width: 5, height: 5).padding(.top, 4)
            }

            Divider()

            OverflowScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if filteredApps.isEmpty {
                        Text(search.isEmpty ? "No applications open" : "No matching apps")
                            .font(.custom("JetBrainsMono Nerd Font", size: 10))
                            .foregroundStyle(.secondary).padding(.vertical, 16)
                    }
                    ForEach(filteredApps, id: \.processIdentifier) { app in
                        HStack(spacing: 4) {
                        Button {
                            NotificationCenter.default.post(name: .dismissExpandedWidget, object: nil)
                            app.activate(options: [.activateIgnoringOtherApps])
                        } label: {
                            HStack(spacing: 8) {
                                if let icon = app.icon {
                                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
                                } else {
                                    Image(systemName: "app.fill").frame(width: 18, height: 18)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.localizedName ?? "Unknown app")
                                        .font(.custom("JetBrainsMono Nerd Font", size: 10).weight(.medium))
                                        .lineLimit(1)
                                    Text(flashspace.workspaceLabel(for: app.bundleIdentifier))
                                        .font(.custom("JetBrainsMono Nerd Font", size: 8))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                        .help(flashspace.workspaceLabel(for: app.bundleIdentifier))
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help("Switch to \(app.localizedName ?? "app")")
                        Button {
                            app.terminate()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Quit \(app.localizedName ?? "app")")
                        .accessibilityLabel("Quit \(app.localizedName ?? "app")")
                        }
                        .padding(.horizontal, 6)
                        .background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.055), lineWidth: 0.75))
                    }
                }
            }
            .frame(maxHeight: .infinity)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(.secondary)
                TextField("Filter apps by name…", text: $search)
                    .textFieldStyle(.plain)
                    .font(.custom("JetBrainsMono Nerd Font", size: 8))
                    .focused($searchFocused)
                    .accessibilityLabel("Filter apps by name")
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
        .onAppear {
            refreshApps()
            NSApp.activate(ignoringOtherApps: true)
            searchFocused = true
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refreshApps() }
        .task {
            while !Task.isCancelled {
                await flashspace.refreshAssignments()
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { break }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshApps() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in refreshApps() }
    }
}

private struct DockGlassBackdrop: ViewModifier {
    let opacity: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            let density = min(0.58, 0.24 + max(0, min(opacity, 1)) * 0.30)
            content
                .background(
                    .black.opacity(density),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .glassEffect(
                .regular
                    .tint(.black.opacity(0.08))
                    .interactive(),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        } else {
            content.background {
                GlassBackground(opacity: opacity)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

private struct GlassBackground: NSViewRepresentable {
    let opacity: Double

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.cornerCurve = .continuous
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.state = .active
        view.alphaValue = max(0, min(opacity, 1))
    }
}

private enum DisplayMode: String, CaseIterable {
    case compact
    case expanded
}

private enum TerminalChoice: String, CaseIterable, Identifiable {
    case ghostty
    case iterm2
    case termy

    var id: String { rawValue }
    var name: String {
        switch self {
        case .ghostty: return "Ghostty"
        case .iterm2: return "iTerm2"
        case .termy: return "Termy"
        }
    }
    var bundleIdentifier: String {
        switch self {
        case .ghostty: return "com.mitchellh.ghostty"
        case .iterm2: return "com.googlecode.iterm2"
        case .termy: return "com.lassevestergaard.termy"
        }
    }
    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil }
}

@MainActor
private struct FlashSpaceApp: Identifiable, Equatable {
    let id: String
    let name: String
    let bundleIdentifier: String

    var icon: NSImage? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(forFile: "/Applications/\(name).app")
    }
}

@MainActor
private final class FlashSpaceModel: ObservableObject {
    static let shared = FlashSpaceModel()
    @Published var workspaces: [String] = []
    @Published var active: Set<String> = []
    @Published var status = "Connecting…"
    @Published var switching = false
    @Published private var assignments: [String: [String]] = [:]
    @Published private var floating = Set<String>()
    @Published private var assignmentsAvailable = false
    @Published var appsByWorkspace: [String: [FlashSpaceApp]] = [:]
    @Published private var workspaceIcons: [String: String] = [:]
    @Published private(set) var managerName = "FlashSpace"
    private var workspaceTargets: [String: String] = [:]
    var appURL: URL { URL(fileURLWithPath: "/Applications/\(managerName).app") }
    private var omniExecutable: String { appURL.appendingPathComponent("Contents/MacOS/omniwmctl").path }

    private func detectManager() {
        let running = NSWorkspace.shared.runningApplications
        let name = running.contains(where: { $0.bundleURL?.lastPathComponent == "OmniWM.app" }) ? "OmniWM" :
            running.contains(where: { $0.bundleURL?.lastPathComponent == "FlashSpace.app" }) ? "FlashSpace" :
            FileManager.default.fileExists(atPath: "/Applications/OmniWM.app") ? "OmniWM" : "FlashSpace"
        guard name != managerName else { return }
        managerName = name
        clearWorkspaceState()
    }

    private func clearWorkspaceState() {
        workspaces = []; active = []; appsByWorkspace = [:]; workspaceIcons = [:]
        assignments = [:]; floating = []; assignmentsAvailable = false; workspaceTargets = [:]
    }

    private func omniRows(_ kind: String) async throws -> [[String: Any]] {
        let output = try await Self.command(["query", kind, "--format", "json"], executable: omniExecutable)
        guard let root = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              root["ok"] as? Bool == true,
              let result = root["result"] as? [String: Any],
              let payload = result["payload"] as? [String: Any],
              let rows = payload[kind] as? [[String: Any]] else {
            throw NSError(domain: "OmniWM", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid OmniWM workspace response"])
        }
        return rows
    }

    private func refreshOmni() async throws {
        let rows = try await omniRows("workspaces").sorted { ($0["number"] as? Int ?? 0) < ($1["number"] as? Int ?? 0) }
        let windows = try await omniRows("windows")
        let display = NSApp.windows.first(where: { $0 is DockWindow })?.screen?.localizedName ?? NSScreen.main?.localizedName
        var labels: [String: String] = [:]
        var targets: [String: String] = [:]
        var names: [String] = []
        var selected = Set<String>()
        for row in rows {
            guard let id = row["id"] as? String, let raw = row["rawName"] as? String else { continue }
            let title = row["displayName"] as? String ?? raw
            let duplicate = rows.filter { ($0["displayName"] as? String) == title }.count > 1
            let label = duplicate ? "\(raw) · \(title)" : title
            labels[id] = label; targets[label] = raw; names.append(label)
            let monitor = row["display"] as? [String: Any]
            if row["isVisible"] as? Bool == true && (monitor?["name"] as? String == display || (display == nil && row["isFocused"] as? Bool == true)) {
                selected.insert(label)
            }
        }
        var loaded: [String: [FlashSpaceApp]] = [:]
        var assigned: [String: [String]] = [:]
        for window in windows {
            guard window["isScratchpad"] as? Bool != true,
                  let space = window["workspace"] as? [String: Any], let id = space["id"] as? String,
                  let label = labels[id], let app = window["app"] as? [String: Any],
                  let bundle = app["bundleId"] as? String, let name = app["name"] as? String else { continue }
            if !(loaded[label] ?? []).contains(where: { $0.id == bundle }) {
                loaded[label, default: []].append(FlashSpaceApp(id: bundle, name: name, bundleIdentifier: bundle))
                assigned[bundle, default: []].append(label)
            }
        }
        workspaces = names; active = selected; workspaceTargets = targets
        appsByWorkspace = loaded; assignments = assigned; floating = []; workspaceIcons = [:]
        assignmentsAvailable = true
        status = names.isEmpty ? "No workspaces configured" : ""
    }

    func icon(for workspace: String) -> String {
        let symbol = workspaceIcons[workspace] ?? "rectangle.3.group"
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) == nil ? "rectangle.3.group" : symbol
    }

    private func loadWorkspaceIcons(profileName: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/flashspace/profiles.json")
        guard let data = try? Data(contentsOf: url),
              let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let profiles = config["profiles"] as? [[String: Any]],
              let profile = profiles.first(where: { $0["name"] as? String == profileName }),
              let spaces = profile["workspaces"] as? [[String: Any]] else {
            workspaceIcons = [:]; return
        }
        var icons: [String: String] = [:]
        for space in spaces {
            if let name = space["name"] as? String, let symbol = space["symbolIconName"] as? String {
                icons[name] = symbol
            }
        }
        workspaceIcons = icons
    }
    private var loadingAssignments = false

    func workspaceLabel(for bundleID: String?) -> String {
        guard assignmentsAvailable else { return "Workspace unavailable" }
        guard let bundleID else { return "Unassigned" }
        if floating.contains(bundleID) { return "Floating · all workspaces" }
        return assignments[bundleID]?.joined(separator: " · ") ?? "Unassigned"
    }

    func revealApplication(_ bundleID: String) async {
        for _ in 0..<100 where loadingAssignments || refreshing || switching {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard !loadingAssignments, !refreshing, !switching else { return }
        await refreshAssignments()
        guard assignmentsAvailable, !floating.contains(bundleID),
              let spaces = assignments[bundleID], !spaces.isEmpty else { return }
        await refresh()
        guard !spaces.contains(where: { active.contains($0) }) else { return }
        await activate(spaces[0])
    }

    func refreshAssignments() async {
        guard !loadingAssignments else { return }
        detectManager()
        if managerName == "OmniWM" { await refresh(); return }
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL == appURL }) else {
            assignmentsAvailable = false; return
        }
        loadingAssignments = true
        defer { loadingAssignments = false }
        do {
            let names = try await Self.command(["list-workspaces"])
            var result: [String: [String]] = [:]
            for name in names.components(separatedBy: .newlines).filter({ !$0.isEmpty }) {
                let apps = try await Self.command(["list-apps", name, "--with-bundle-id"])
                for line in apps.components(separatedBy: .newlines) {
                    if let comma = line.lastIndex(of: ",") {
                        let id = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                        if !id.isEmpty { result[id, default: []].append(name) }
                    }
                }
            }
            let floatApps = try await Self.command(["list-floating-apps", "--with-bundle-id"])
            floating = Set(floatApps.components(separatedBy: .newlines).compactMap { line in
                guard let comma = line.lastIndex(of: ",") else { return nil }
                return String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
            })
            assignments = result
            assignmentsAvailable = true
        } catch { assignmentsAvailable = false }
    }
    private var refreshing = false

    var activeApps: [FlashSpaceApp] {
        active.flatMap { appsByWorkspace[$0] ?? [] }
    }

    private static func parseApps(_ output: String) -> [FlashSpaceApp] {
        output.components(separatedBy: .newlines).compactMap { line in
            guard let comma = line.lastIndex(of: ",") else { return nil }
            let name = String(line[..<comma]).trimmingCharacters(in: .whitespacesAndNewlines)
            let bundleID = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return FlashSpaceApp(id: bundleID.isEmpty ? name : bundleID, name: name, bundleIdentifier: bundleID)
        }
    }

    func refresh() async {
        guard !refreshing, !switching else { return }
        detectManager()
        guard FileManager.default.fileExists(atPath: appURL.path) else {
            clearWorkspaceState(); status = "\(managerName) not installed"; return
        }
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL == appURL }) else {
            clearWorkspaceState(); status = "Open \(managerName)"; return
        }
        refreshing = true
        defer { refreshing = false }
        if managerName == "OmniWM" {
            do { try await refreshOmni() }
            catch { clearWorkspaceState(); status = "OmniWM unavailable · check IPC: \(error.localizedDescription)" }
            return
        }
        guard let display = NSApp.windows.first(where: { $0 is DockWindow })?.screen?.localizedName
                ?? NSScreen.main?.localizedName else {
            active = []; status = "Dock display unavailable"; return
        }
        do {
            let names = try await Self.command(["list-workspaces"])
            let selected = try await Self.command(["get-workspace", "--display", display])
            workspaces = names.components(separatedBy: .newlines).filter { !$0.isEmpty }
            active = selected.isEmpty ? [] : [selected]
            var loaded: [String: [FlashSpaceApp]] = [:]
            for workspace in workspaces {
                if let output = try? await Self.command(["list-apps", workspace, "--with-bundle-id"]) {
                    loaded[workspace] = Self.parseApps(output)
                }
            }
            appsByWorkspace = loaded
            if let profile = try? await Self.command(["get-profile"]) {
                loadWorkspaceIcons(profileName: profile)
            } else { workspaceIcons = [:] }
            status = workspaces.isEmpty ? "No workspaces configured" : ""
        } catch { status = error.localizedDescription }
    }

    func activate(_ name: String) async {
        guard !switching, !refreshing else { return }
        if managerName == "OmniWM", active.contains(name) { return }
        switching = true
        do {
            if managerName == "OmniWM" {
                guard let target = workspaceTargets[name] else { switching = false; return }
                _ = try await Self.command(["workspace", "focus-name", target], executable: omniExecutable)
            } else { _ = try await Self.command(["workspace", "--name", name]) }
        }
        catch { status = error.localizedDescription; switching = false; return }
        switching = false
        await refresh()
    }

    func open() {
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    nonisolated private static func command(_ arguments: [String], executable: String = "/Applications/FlashSpace.app/Contents/Resources/flashspace") async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
            defer { timeout.cancel() }
            // Drain concurrently with the process so long lists cannot fill the pipe.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 || (executable.hasSuffix("/omniwmctl") && text == "ignored: no_change") else {
                throw NSError(domain: "FlashSpace", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: text.isEmpty ? "FlashSpace unavailable" : text])
            }
            return text
        }.value
    }
}

private struct FlashSpaceWidget: View {
    let isExpanded: Bool
    @ObservedObject private var model = FlashSpaceModel.shared
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: model.appURL.path))
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .accessibilityLabel(model.managerName)
        VStack(alignment: .leading, spacing: 2) {
                Text("Spaces")
                    .font(.custom("JetBrainsMono Nerd Font", size: 10).weight(.medium))
                    .foregroundStyle(.secondary)
                Text(model.active.isEmpty ? model.managerName : model.active.sorted().joined(separator: " · "))
                    .font(.custom("JetBrainsMono Nerd Font", size: 11).weight(.medium))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
            }
            .frame(width: 100, alignment: .leading)
        }
            .frame(height: 32)
            .padding(.horizontal, 6)
            .frame(height: 37)
        .background(.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.bottom, 7)
            .help(model.status.isEmpty ? model.active.sorted().joined(separator: " · ") : model.status)
            .task {
                while !Task.isCancelled {
                    await model.refresh()
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { break }
                }
            }
    }
}

private struct FlashSpaceExpandedView: View {
    @ObservedObject private var model = FlashSpaceModel.shared
    var showFinderHeader = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.teal.opacity(0.08))
                    let appPath = showFinderHeader ? "/System/Library/CoreServices/Finder.app" : model.appURL.path
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appPath)).resizable().scaledToFit().frame(width: 20, height: 20)
                }.frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(showFinderHeader ? "\(model.managerName) workspaces" : "Workspaces")
                            .font(.custom("JetBrainsMono Nerd Font", size: 12).weight(.medium))
                        Text("\(model.workspaces.count)")
                            .font(.custom("JetBrainsMono Nerd Font", size: 8)).foregroundStyle(.teal)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                    }
                    if showFinderHeader {
                        Text("Click to focus").font(.custom("JetBrainsMono Nerd Font", size: 8)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { model.open() } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.plain).help("Open \(model.managerName)")
            }

            if !model.status.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(model.status).font(.custom("JetBrainsMono Nerd Font", size: 9)).foregroundStyle(.secondary)
                    Spacer()
                    if model.status == "Open \(model.managerName)" { Button("Open") { model.open() }.buttonStyle(.plain).foregroundStyle(.indigo) }
                }
            }

            OverflowScrollView {
                VStack(spacing: 6) {
                    if model.workspaces.isEmpty {
                        Text(model.status.isEmpty ? "No workspaces configured" : "Connect \(model.managerName) to see workspaces")
                            .font(.custom("JetBrainsMono Nerd Font", size: 10)).foregroundStyle(.secondary).padding(.vertical, 18)
                    }
                    ForEach(model.workspaces, id: \.self) { workspace in
                        let assignedApps = (model.appsByWorkspace[workspace] ?? []).map(\.name).joined(separator: " · ")
                        Button { Task { await model.activate(workspace) } } label: {
                            HStack(spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 5).fill(Color.cyan.opacity(0.10))
                                    Image(systemName: model.icon(for: workspace)).foregroundStyle(.cyan)
                                }.frame(width: 26, height: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workspace).font(.custom("JetBrainsMono Nerd Font", size: 10).weight(.medium)).lineLimit(1)
                                    Text(assignedApps.isEmpty ? "No apps assigned" : assignedApps)
                                        .font(.custom("JetBrainsMono Nerd Font", size: 8)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if model.active.contains(workspace) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(model.active.contains(workspace) ? Color.green.opacity(0.08) : Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(model.active.contains(workspace) ? Color.green : Color.black.opacity(0.1), lineWidth: 0.75) }
                        }
                        .buttonStyle(.plain).disabled(model.switching)
                        .help("\(workspace): \(assignedApps.isEmpty ? "No apps assigned" : assignedApps)")
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Text(model.switching ? "Switching space…" : "\(model.managerName) · click a workspace to switch")
                .font(.custom("JetBrainsMono Nerd Font", size: 8)).foregroundStyle(.secondary)
        }
        .task { await model.refresh() }
    }

}

struct WidgetCard: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let detail: String
    let isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.custom("JetBrainsMono Nerd Font", size: 9).weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(tint, in: RoundedRectangle(cornerRadius: 5))
                Text(title)
                    .font(.custom("JetBrainsMono Nerd Font", size: 10).weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "ellipsis")
                    .font(.custom("JetBrainsMono Nerd Font", size: 9).weight(.bold))
                    .foregroundStyle(.tertiary)
            }

            Text(value)
                .font(.custom("JetBrainsMono Nerd Font", size: 13).weight(.semibold))
                .foregroundStyle(Color.ink)
                .lineLimit(1)

        }
        .frame(width: 100, alignment: .leading)
        .padding(.horizontal, 6)
        .frame(height: 37)
        .background(.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.bottom, 7)
        .help(detail)
    }
}

@MainActor
private final class MusicStatusModel: ObservableObject {
    static let shared = MusicStatusModel()
    @Published var state = "Unavailable"
    @Published var track = "Music"
    @Published var artist = ""
    @Published var album = ""
    @Published var artwork: NSImage?
    @Published var errorMessage: String?
    private var artworkData: Data?
    private let queue = DispatchQueue(label: "DockExtend.music", qos: .utility)
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    func refresh() {
        queue.async { [weak self] in
            let snapshot = Self.readSnapshot()
            DispatchQueue.main.async { self?.apply(snapshot) }
        }
    }

    private func apply(_ snapshot: MusicSnapshot) {
        state = snapshot.state
        track = snapshot.track
        artist = snapshot.artist
        album = snapshot.album
        errorMessage = snapshot.errorMessage
        if artworkData != snapshot.artworkData {
            artworkData = snapshot.artworkData
            artwork = snapshot.artworkData.flatMap { NSImage(data: $0) }
        }
    }

    private nonisolated static func readSnapshot() -> MusicSnapshot {
        let script = """
        if application "Music" is not running then return {"unavailable", "", "", "", missing value}
        tell application "Music"
            set playbackState to player state as string
            try
                set musicTrack to current track
                set cover to missing value
                try
                    set cover to raw data of artwork 1 of musicTrack
                end try
                return {playbackState, name of musicTrack, artist of musicTrack, album of musicTrack, cover}
            on error
                return {playbackState, "", "", "", missing value}
            end try
        end tell
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error), error == nil, result.numberOfItems >= 5 else {
            let denied = (error?["NSAppleScriptErrorNumber"] as? Int) == -1743
            return MusicSnapshot(state: "Unavailable", track: "", artist: "", album: "", artworkData: nil, errorMessage: denied ? "Allow Music access in Privacy & Security → Automation." : "Music info unavailable")
        }
        return MusicSnapshot(
            state: result.atIndex(1)?.stringValue?.capitalized ?? "Unavailable",
            track: result.atIndex(2)?.stringValue ?? "",
            artist: result.atIndex(3)?.stringValue ?? "",
            album: result.atIndex(4)?.stringValue ?? "",
            artworkData: result.atIndex(5)?.data,
            errorMessage: nil
        )
    }

    func togglePlayback() { run("tell application \"Music\" to playpause"); refresh() }
    func nextTrack() { run("tell application \"Music\" to next track"); refresh() }
    func previousTrack() { run("tell application \"Music\" to previous track"); refresh() }
    func openMusic() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func run(_ source: String) {
        queue.async {
            var error: NSDictionary?
            _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }
}

private struct MusicSnapshot: Sendable {
    let state: String
    let track: String
    let artist: String
    let album: String
    let artworkData: Data?
    let errorMessage: String?
}

private struct MusicArtwork: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.pink.opacity(0.06)
                    Image(systemName: "music.note").font(.system(size: size * 0.3)).foregroundStyle(Color.pink.opacity(0.5))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 50 ? 10 : 6))
        .overlay { RoundedRectangle(cornerRadius: size > 50 ? 10 : 6).stroke(Color.black.opacity(0.06), lineWidth: 0.75) }
        .accessibilityLabel(image == nil ? "No album artwork" : "Album artwork")
    }
}

private struct MusicExpandedView: View {
    @ObservedObject private var music = MusicStatusModel.shared
    private var isPlaying: Bool { music.state.lowercased() == "playing" }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Music", systemImage: "music.note")
                    .font(.custom("JetBrainsMono Nerd Font", size: 11).weight(.medium))
                Spacer()
                Text(music.state == "Unavailable" ? "Apple Music" : music.state)
                    .font(.custom("JetBrainsMono Nerd Font", size: 8)).foregroundStyle(.secondary)
                Button { music.openMusic() } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 28, height: 28)
                        .background(Color.pink.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                        .overlay { RoundedRectangle(cornerRadius: 7).stroke(Color.pink.opacity(0.22), lineWidth: 0.75) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.pink)
                .help("Open Apple Music")
                .accessibilityLabel("Open Apple Music")
            }
            Divider()
            MusicArtwork(image: music.artwork, size: 150)
            VStack(spacing: 2) {
                Text(music.track.isEmpty ? "Nothing playing" : music.track)
                    .font(.custom("JetBrainsMono Nerd Font", size: 13).weight(.medium))
                    .lineLimit(2).multilineTextAlignment(.center)
                Text(music.artist.isEmpty ? "Play a song in Music" : music.artist)
                    .font(.custom("JetBrainsMono Nerd Font", size: 10)).foregroundStyle(.secondary).lineLimit(1)
                if let error = music.errorMessage {
                    Text(error).font(.custom("JetBrainsMono Nerd Font", size: 8)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(2)
                } else if !music.album.isEmpty {
                    Text(music.album).font(.custom("JetBrainsMono Nerd Font", size: 8)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 24) {
                Button { music.previousTrack() } label: {
                    Image(systemName: "backward.fill").font(.system(size: 17)).frame(width: 28, height: 32)
                }.help("Previous track").accessibilityLabel("Previous track").disabled(music.track.isEmpty)
                Button { music.togglePlayback() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18)).foregroundStyle(.white)
                        .frame(width: 42, height: 42).background(Color.ink, in: Circle())
                }.help(isPlaying ? "Pause" : "Play").accessibilityLabel(isPlaying ? "Pause" : "Play")
                Button { music.nextTrack() } label: {
                    Image(systemName: "forward.fill").font(.system(size: 17)).frame(width: 28, height: 32)
                }.help("Next track").accessibilityLabel("Next track").disabled(music.track.isEmpty)
            }.buttonStyle(.plain)
        }.frame(maxWidth: .infinity)
    }
}

private struct MusicWidget: View {
    @ObservedObject private var model = MusicStatusModel.shared
    let isExpanded: Bool

    private var isPlaying: Bool { model.state.lowercased() == "playing" }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            MusicArtwork(image: model.artwork, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.artist.isEmpty ? "Apple Music" : model.artist)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Text(model.album.isEmpty ? "No album" : model.album)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(model.track.isEmpty ? "Nothing playing" : model.track)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 230, height: 52)
        .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.black.opacity(0.09), lineWidth: 0.75)
        }
        .help("\(model.artist) · \(model.album) · \(model.track)")
    }
}

private struct HerdrAgentList: Decodable {
    let result: HerdrResult
}

private struct HerdrResult: Decodable {
    let agents: [HerdrAgent]
}

private struct HerdrWorkspaceList: Decodable {
    struct Workspace: Decodable {
        let workspaceID: String
        let label: String
        let order: Int?
        enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case label
            case order = "number"
        }
    }
    struct Result: Decodable {
        let workspaces: [Workspace]
    }
    let result: Result
}

private struct HerdrAgent: Decodable, Identifiable, Sendable {
    let id: String
    let agent: String
    let agentStatus: String
    let terminalTitle: String
    let tabID: String
    let workspaceID: String

    var icon: String {
        switch agent.lowercased() {
        case "codex": return "sparkles"
        case "claude": return "quote.bubble.fill"
        case "opencode": return "chevron.left.forwardslash.chevron.right"
        default: return "person.fill"
        }
    }

    var iconGlyph: String {
        switch agent.lowercased() {
        case "codex": return "\u{EC81}"     // cod-openai
        case "claude": return "\u{EC82}"   // cod-claude
        case "opencode": return "\u{EAC4}"  // cod-code
        default: return "\u{EA85}"          // cod-terminal
        }
    }

    var statusColor: Color {
        switch agentStatus {
        case "blocked": return .red
        case "working": return .orange
        case "done": return .blue
        default: return .green
        }
    }

    enum CodingKeys: String, CodingKey {
        case id = "pane_id"
        case agent
        case agentStatus = "agent_status"
        case terminalTitle = "terminal_title_stripped"
        case tabID = "tab_id"
        case workspaceID = "workspace_id"
    }
}

@MainActor
private final class HerdrStatusModel: ObservableObject {
    static let shared = HerdrStatusModel()
    @Published var agents: [HerdrAgent] = []
    @Published var spaceLabels: [String: String] = [:]
    @Published var spaceOrder: [String] = []
    @Published var total = 0
    @Published var working = 0
    @Published var blocked = 0
    @Published var idle = 0
    @Published var done = 0
    @Published var unknown = 0
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    var icon: String {
        if blocked > 0 { return "exclamationmark.triangle.fill" }
        if working > 0 { return "bolt.fill" }
        if total == 0 { return "person.2.slash" }
        return "person.2.fill"
    }

    var tint: Color {
        if blocked > 0 { return .red }
        if working > 0 { return .orange }
        if total == 0 { return .gray }
        return .green
    }

    var summary: String {
        if total == 0 { return "No agents" }
        if blocked > 0 { return "\(blocked) blocked" }
        if working > 0 { return "\(working) working" }
        return "\(total) ready"
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let counts = Self.readCounts()
            DispatchQueue.main.async { self?.apply(counts) }
        }
    }

    private func apply(_ counts: HerdrCounts) {
        agents = counts.agents
        spaceLabels = counts.spaceLabels
        spaceOrder = counts.spaceOrder
        total = counts.total
        working = counts.working
        blocked = counts.blocked
        idle = counts.idle
        done = counts.done
        unknown = counts.unknown
    }

    private nonisolated static func readCounts() -> HerdrCounts {
        let agents = (try? JSONDecoder().decode(HerdrAgentList.self, from: run(["agent", "list"])))?.result.agents ?? []
        let workspaces = (try? JSONDecoder().decode(HerdrWorkspaceList.self, from: run(["workspace", "list"])))?.result.workspaces ?? []
        let spaceLabels = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.workspaceID, $0.label) })
        let spaceOrder = workspaces.sorted { ($0.order ?? 0) < ($1.order ?? 0) }.map { $0.workspaceID }
        return HerdrCounts(
            agents: agents,
            spaceLabels: spaceLabels,
            spaceOrder: spaceOrder,
            total: agents.count,
            working: agents.filter { $0.agentStatus == "working" }.count,
            blocked: agents.filter { $0.agentStatus == "blocked" }.count,
            idle: agents.filter { $0.agentStatus == "idle" }.count,
            done: agents.filter { $0.agentStatus == "done" }.count,
            unknown: agents.filter { $0.agentStatus == "unknown" }.count
        )
    }

    private nonisolated static func run(_ arguments: [String]) -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/herdr")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["HERDR_ENV": "1"]) { _, new in new }
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return output.fileHandleForReading.readDataToEndOfFile()
        } catch {
            return Data()
        }
    }
}

private struct HerdrCounts: Sendable {
    let agents: [HerdrAgent]
    let spaceLabels: [String: String]
    let spaceOrder: [String]
    let total: Int
    let working: Int
    let blocked: Int
    let idle: Int
    let done: Int
    let unknown: Int
}

private enum HerdrController {
    private static let focusQueue = DispatchQueue(label: "DockExtend.herdrFocus", qos: .userInitiated)
    @MainActor private static var focusGeneration = 0

    @MainActor
    static func openTerminal(_ terminal: TerminalChoice) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleIdentifier) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, _ in
            DispatchQueue.main.async {
                application?.unhide()
                application?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
        }
    }

    @MainActor
    static func focus(_ agent: HerdrAgent, terminal: TerminalChoice) {
        focusGeneration += 1
        let revision = focusGeneration
        Task { @MainActor in
            await FlashSpaceModel.shared.revealApplication(terminal.bundleIdentifier)
            guard revision == focusGeneration else { return }
            let focused = await withCheckedContinuation { continuation in
                focusQueue.async {
                    let success = run(["workspace", "focus", agent.workspaceID])
                        && run(["tab", "focus", agent.tabID])
                        && run(["agent", "focus", agent.id])
                    continuation.resume(returning: success)
                }
            }
            if focused, revision == focusGeneration { openTerminal(terminal) }
        }
    }

    @discardableResult
    private static func run(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin/herdr")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["HERDR_ENV": "1"]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

private struct HerdrWidget: View {
    @ObservedObject private var model = HerdrStatusModel.shared
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let logo = HerdrLogo.image {
                    Image(nsImage: logo).resizable().scaledToFit()
                } else {
                    Image(systemName: "terminal").resizable().scaledToFit().foregroundStyle(.teal)
                }
            }
            .frame(width: 26, height: 26)
            .frame(width: 38, height: 42)
            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel("Herdr")

            VStack(spacing: 2) {
                statusRow("Working", count: model.working, color: .orange, showsSpinner: true)
                combinedStatusRow
                statusRow("Idle", count: model.idle, color: .green)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 230, height: 52)
        .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.black.opacity(0.09), lineWidth: 0.75)
        }
    }

    private func statusRow(_ name: String, count: Int, color: Color, showsSpinner: Bool = false) -> some View {
        HStack(spacing: 5) {
            if showsSpinner, count > 0 {
                ProgressView()
                    .controlSize(.mini)
                    .tint(color)
                    .scaleEffect(0.55)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
            } else {
                Circle().fill(color).frame(width: 5, height: 5)
            }
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.ink)
            Spacer(minLength: 5)
            countLabel(count)
        }
        .frame(height: 12)
        .help("\(name): \(count)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(count)")
    }

    private var combinedStatusRow: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.red).frame(width: 5, height: 5)
            Text("Blocked")
            Text("/").foregroundStyle(.tertiary)
            Circle().fill(Color.blue).frame(width: 5, height: 5)
            Text("Done")
            Spacer(minLength: 5)
            countLabel(model.blocked)
            Text("/").foregroundStyle(.tertiary)
            countLabel(model.done)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.ink)
        .frame(height: 12)
        .help("Blocked: \(model.blocked), Done: \(model.done)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Blocked: \(model.blocked), Done: \(model.done)")
    }

    private func countLabel(_ count: Int) -> some View {
        Text(String(count))
            .font(.system(size: 9, weight: .regular, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct DockHoverModifier: ViewModifier {
    let isApp: Bool
    let isDragging: Bool
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var highlighted: Bool { isHovered && !isDragging }

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(highlighted ? 0.12 : 0))
                    .allowsHitTesting(false)
            }
            .scaleEffect(highlighted && !reduceMotion ? (isApp ? 1.10 : 1.045) : 1, anchor: .bottom)
            .offset(y: highlighted && !reduceMotion ? (isApp ? -5 : -3) : 0)
            .zIndex(highlighted ? 1 : 0)
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.82), value: highlighted)
    }
}

private struct AppBadge: View {
    let label: String
    private var isDot: Bool { ["•", "●", "·"].contains(label) }

    var body: some View {
        Group {
            if isDot {
                Circle().fill(Color.red).frame(width: 10, height: 10)
            } else {
                Text(label.count > 4 ? String(label.prefix(3)) + "+" : label)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Color.red, in: Capsule())
            }
        }
        .overlay { Capsule().stroke(Color.white.opacity(0.9), lineWidth: 1) }
        .accessibilityLabel("App badge \(label)")
        .allowsHitTesting(false)
    }
}

private struct LauncherAppIcon: View {
    let app: LauncherApp
    @ObservedObject private var runningApps = LauncherRunningAppsModel.shared
    @State private var isLaunching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 2) {
            if let icon = app.icon {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 45, height: 45)
            } else {
                Image(systemName: app.symbol)
                    .font(.custom("JetBrainsMono Nerd Font", size: 18).weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 45, height: 45)
                    .background(Color.gray.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            Circle().fill(runningApps.isRunning(app) ? .white : .clear)
                .frame(width: 5, height: 5)
                .shadow(color: .black.opacity(0.35), radius: 2)
        }
        .overlay(alignment: .topTrailing) {
            if let label = runningApps.badge(for: app) {
                AppBadge(label: label).offset(x: 3, y: -1)
            }
        }
        .contentShape(Rectangle())
        .scaleEffect(isLaunching && !reduceMotion ? 0.92 : 1)
        .onTapGesture {
            NotificationCenter.default.post(name: .dismissExpandedWidget, object: nil)
            withAnimation(.easeOut(duration: 0.10)) { isLaunching = true }
            launch()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.65)) { isLaunching = false }
            }
        }
        .animation(.easeOut(duration: 0.18), value: runningApps.isRunning(app))
        .help("Launch \(app.name)\(runningApps.badge(for: app).map { " · Badge \($0)" } ?? "")")
    }

    private func launch() {
        let url: URL?
        if let bundleIdentifier = app.bundleIdentifier {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        } else if let path = app.path {
            url = URL(fileURLWithPath: path)
        } else {
            url = nil
        }
        guard let url else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct LauncherView: View {
    @AppStorage("launcher.apps") private var appsRaw = AppCatalog.defaultJSON
    @State private var draggedAppID: String?
    @StateObject private var runningApps = LauncherRunningAppsModel()

    private var apps: [LauncherApp] { AppCatalog.decode(appsRaw) }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(apps) { app in
                Button { launch(app) } label: {
                    VStack(spacing: 2) {
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 45, height: 45)
                        } else {
                            Image(systemName: app.symbol)
                                .font(.custom("JetBrainsMono Nerd Font", size: 18).weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 45, height: 45)
                                .background(Color.gray.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        Circle()
                            .fill(runningApps.isRunning(app) ? .white : .clear)
                            .frame(width: 5, height: 5)
                            .shadow(color: .black.opacity(0.35), radius: 2)
                    }
                    .contentShape(Rectangle())
                    .onDrag {
                        draggedAppID = app.id
                        return NSItemProvider(object: NSString(string: app.id))
                    }
                    .onDrop(of: [.text], delegate: AppDropDelegate(
                        targetID: app.id,
                        appsRaw: $appsRaw,
                        draggedAppID: $draggedAppID
                    ))
                }
                .buttonStyle(.plain)
                .help("Drag to reorder \(app.name)")
            }
        }
    }

    private func launch(_ app: LauncherApp) {
        let appURL: URL?
        if let bundleIdentifier = app.bundleIdentifier {
            appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        } else if let path = app.path {
            appURL = URL(fileURLWithPath: path)
        } else {
            appURL = nil
        }
        guard let appURL else { return }
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

@MainActor
private final class LauncherRunningAppsModel: ObservableObject {
    static let shared = LauncherRunningAppsModel()
    @Published private var runningBundleIDs = Set<String>()
    @Published private var badges: [String: String] = [:]
    private let badgeQueue = DispatchQueue(label: "DockExtend.badges", qos: .utility)
    private var readingBadges = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    func isRunning(_ app: LauncherApp) -> Bool {
        if let bundleIdentifier = app.bundleIdentifier { return runningBundleIDs.contains(bundleIdentifier) }
        return false
    }

    func badge(for app: LauncherApp) -> String? {
        guard let bundleID = app.bundleIdentifier else { return nil }
        return badges[bundleID]
    }

    var count: Int { runningBundleIDs.count }

    private func refresh() {
        runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        guard !readingBadges else { return }
        readingBadges = true
        let targets = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { app -> (String, Int32)? in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return (bundleID, app.processIdentifier)
        }
        badgeQueue.async { [weak self] in
            let values = Self.readBadges(targets)
            Task { @MainActor in
                guard let self else { return }
                var updated = self.badges.filter { self.runningBundleIDs.contains($0.key) }
                for (bundleID, label) in values where self.runningBundleIDs.contains(bundleID) {
                    if label.isEmpty { updated.removeValue(forKey: bundleID) }
                    else { updated[bundleID] = label }
                }
                self.badges = updated
                self.readingBadges = false
            }
        }
    }

    // Best-effort mirror of labels published to LaunchServices by running apps.
    // No message contents or notification databases are read.
    private nonisolated static func readBadges(_ targets: [(String, Int32)]) -> [String: String] {
        var values: [String: String] = [:]
        guard let identityPattern = try? NSRegularExpression(pattern: #""CFBundleIdentifier"\s*=\s*"([^"]*)""#),
              let labelPattern = try? NSRegularExpression(pattern: #""label"\s*=\s*"([^"]*)""#) else { return values }
        for (bundleID, pid) in targets {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        // Bare numbers are LaunchServices ASNs; prefix with # to address a PID.
        process.arguments = ["-all", "info", "-only", "StatusLabel,bundleid", "#\(pid)"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: timeout)
            defer { timeout.cancel() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { continue }
            let range = NSRange(output.startIndex..., in: output)
            guard let identity = identityPattern.firstMatch(in: output, range: range),
                  let identityRange = Range(identity.range(at: 1), in: output),
                  String(output[identityRange]) == bundleID else { continue }
            if let match = labelPattern.firstMatch(in: output, range: range),
               let labelRange = Range(match.range(at: 1), in: output) {
                values[bundleID] = String(output[labelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // An identified app with no status label has cleared its badge.
                values[bundleID] = ""
            }
        } catch { continue }
        }
        return values
    }
}

private enum DockOrder {
    static let defaultRaw = encode([
        "widget:focus", "widget:music",
        "app:com.apple.finder", "app:com.apple.Terminal", "app:com.apple.Safari",
        "app:com.apple.Notes", "app:com.apple.MobileSMS", "app:com.apple.Music", "app:com.apple.Photos",
        "widget:weather", "widget:herdr", "widget:calendar", "widget:usage", "widget:runningApps", "widget:note"
    ])

    static func decode(_ raw: String) -> [String] {
        guard let data = raw.data(using: .utf8), let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return ids
    }

    static func encode(_ ids: [String]) -> String {
        guard let data = try? JSONEncoder().encode(ids), let raw = String(data: data, encoding: .utf8) else { return "[]" }
        return raw
    }
}

private struct DockReorderModifier: ViewModifier {
    let itemID: String
    @Binding var orderRaw: String
    @Binding var draggedItemID: String?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onDrag {
                draggedItemID = itemID
                return NSItemProvider(object: NSString(string: itemID))
            }
            .onDrop(of: [.text], delegate: DockDropDelegate(
                targetID: itemID,
                orderRaw: $orderRaw,
                draggedItemID: $draggedItemID
            ))
    }
}

private struct DockDropDelegate: DropDelegate {
    let targetID: String
    @Binding var orderRaw: String
    @Binding var draggedItemID: String?

    func dropEntered(info: DropInfo) {
        guard let draggedItemID, draggedItemID != targetID else { return }
        var ids = DockOrder.decode(orderRaw)
        if !ids.contains(draggedItemID) { ids.append(draggedItemID) }
        guard let fromIndex = ids.firstIndex(of: draggedItemID), let toIndex = ids.firstIndex(of: targetID) else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            let moved = ids.remove(at: fromIndex)
            ids.insert(moved, at: toIndex)
            orderRaw = DockOrder.encode(ids)
        }
    }

    func validateDrop(info: DropInfo) -> Bool { draggedItemID != nil }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        draggedItemID = nil
        return true
    }
}

private struct AppDropDelegate: DropDelegate {
    let targetID: String
    @Binding var appsRaw: String
    @Binding var draggedAppID: String?

    func dropEntered(info: DropInfo) {
        guard let draggedAppID, draggedAppID != targetID else { return }
        var apps = AppCatalog.decode(appsRaw)
        guard let fromIndex = apps.firstIndex(where: { $0.id == draggedAppID }),
              let toIndex = apps.firstIndex(where: { $0.id == targetID }) else { return }

        withAnimation(.easeOut(duration: 0.16)) {
            let movedApp = apps.remove(at: fromIndex)
            apps.insert(movedApp, at: toIndex)
            appsRaw = AppCatalog.encode(apps)
        }
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggedAppID != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedAppID = nil
        return true
    }
}

private struct LauncherApp: Codable, Identifiable, Equatable {
    let id: String
    let symbol: String
    let name: String
    let bundleIdentifier: String?
    let path: String?

    var applicationURL: URL? {
        if let bundleIdentifier, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) { return url }
        if let path, FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        return nil
    }

    func launch() {
        guard let url = applicationURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    var icon: NSImage? {
        let appURL: URL?
        if let bundleIdentifier {
            appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        } else if let path {
            appURL = URL(fileURLWithPath: path)
        } else {
            appURL = nil
        }
        guard let appURL else { return nil }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    static let defaults = [
        LauncherApp(id: "com.apple.finder", symbol: "face.smiling", name: "Finder", bundleIdentifier: "com.apple.finder", path: nil),
        LauncherApp(id: "com.apple.Terminal", symbol: "terminal", name: "Terminal", bundleIdentifier: "com.apple.Terminal", path: nil),
        LauncherApp(id: "com.apple.Safari", symbol: "safari", name: "Safari", bundleIdentifier: "com.apple.Safari", path: nil),
        LauncherApp(id: "com.apple.Notes", symbol: "note.text", name: "Notes", bundleIdentifier: "com.apple.Notes", path: nil),
        LauncherApp(id: "com.apple.MobileSMS", symbol: "bubble.left.and.bubble.right.fill", name: "Messages", bundleIdentifier: "com.apple.MobileSMS", path: nil),
        LauncherApp(id: "com.apple.Music", symbol: "music.note", name: "Music", bundleIdentifier: "com.apple.Music", path: nil),
        LauncherApp(id: "com.apple.Photos", symbol: "photo", name: "Photos", bundleIdentifier: "com.apple.Photos", path: nil)
    ]
}

private enum AppCatalog {
    static let defaultJSON: String = encode(LauncherApp.defaults)

    static func decode(_ raw: String) -> [LauncherApp] {
        guard let data = raw.data(using: .utf8), let apps = try? JSONDecoder().decode([LauncherApp].self, from: data) else {
            return LauncherApp.defaults
        }
        return apps
    }

    static func encode(_ apps: [LauncherApp]) -> String {
        guard let data = try? JSONEncoder().encode(apps), let raw = String(data: data, encoding: .utf8) else { return "[]" }
        return raw
    }

    static func addApplication(to raw: String) -> String? {
        let chosen = chooseApplications(allowsMultipleSelection: false)
        guard !chosen.isEmpty else { return nil }
        var apps = decode(raw)
        for app in chosen where !apps.contains(where: { $0.id == app.id }) { apps.append(app) }
        return encode(apps)
    }

    static func chooseApplications(allowsMultipleSelection: Bool = true) -> [LauncherApp] {
        let panel = NSOpenPanel()
        panel.title = "Add applications to Dock Extend"
        panel.message = "Choose applications to add."
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map { url in
            let bundleIdentifier = Bundle(url: url)?.bundleIdentifier
            return LauncherApp(id: bundleIdentifier ?? url.path, symbol: "app.fill", name: url.deletingPathExtension().lastPathComponent, bundleIdentifier: bundleIdentifier, path: url.path)
        }
    }

    static func remove(_ app: LauncherApp, from raw: String) -> String {
        encode(decode(raw).filter { $0.id != app.id })
    }
}

private struct AppFolder: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var apps: [LauncherApp]
}

private enum FolderCatalog {
    static func decode(_ raw: String) -> [AppFolder] {
        guard let data = raw.data(using: .utf8), let folders = try? JSONDecoder().decode([AppFolder].self, from: data) else { return [] }
        return folders
    }

    static func encode(_ folders: [AppFolder]) -> String {
        guard let data = try? JSONEncoder().encode(folders), let raw = String(data: data, encoding: .utf8) else { return "[]" }
        return raw
    }
}

private struct FloatingPanelSurface: ViewModifier {
    let width: CGFloat
    let height: CGFloat
    func body(content: Content) -> some View {
        content.foregroundStyle(Color.ink).padding(16)
            .frame(width: width, height: height)
            .background(Color.white.opacity(0.96), in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).stroke(Color.black.opacity(0.14), lineWidth: 1) }
            .compositingGroup().shadow(color: .black.opacity(0.08), radius: 12, y: 8)
    }
}

private struct AppFolderWidget: View {
    let folder: AppFolder
    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.68)).frame(width: 37, height: 37)
                if folder.apps.isEmpty {
                    Image(systemName: "folder.fill").font(.system(size: 23)).foregroundStyle(Color.blue.opacity(0.55))
                } else {
                    VStack(spacing: 2) {
                        ForEach(0..<2) { row in
                            HStack(spacing: 2) {
                                ForEach(0..<2) { column in
                                    let index = row * 2 + column
                                    if index < folder.apps.count, let icon = folder.apps[index].icon {
                                        Image(nsImage: icon).resizable().scaledToFit().frame(width: 15, height: 15)
                                    } else {
                                        Color.clear.frame(width: 15, height: 15)
                                    }
                                }
                            }
                        }
                    }
                }
            }.frame(width: 45, height: 45)
            Text(folder.name.isEmpty ? "Folder" : folder.name)
                .font(.custom("JetBrainsMono Nerd Font", size: 7).weight(.medium)).lineLimit(1)
                .frame(width: 45, height: 5)
        }
        .contentShape(Rectangle()).help("Open \(folder.name)")
    }
}

private struct FolderExpandedView: View {
    @ObservedObject private var flashspace = FlashSpaceModel.shared
    let folder: AppFolder
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @ObservedObject private var running = LauncherRunningAppsModel.shared
    private var filteredApps: [LauncherApp] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? folder.apps : folder.apps.filter { $0.name.localizedStandardContains(query) }
    }

    static func panelHeight(for folder: AppFolder) -> CGFloat {
        min(max(170, 132 + CGFloat(folder.apps.count) * 52), 520)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(folder.name.isEmpty ? "Folder" : folder.name).font(.custom("JetBrainsMono Nerd Font", size: 11).weight(.medium))
                    Text(search.isEmpty ? "\(folder.apps.count) applications" : "\(filteredApps.count) of \(folder.apps.count) apps")
                        .font(.custom("JetBrainsMono Nerd Font", size: 8)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { NotificationCenter.default.post(name: .showDockSettings, object: nil) } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 10)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).help("Configure folders")
            }
            Divider()
            OverflowScrollView {
                VStack(spacing: 6) {
                    if filteredApps.isEmpty {
                        Text(folder.apps.isEmpty ? "Add apps to this folder in settings." : "No matching apps")
                            .font(.custom("JetBrainsMono Nerd Font", size: 10)).foregroundStyle(.secondary).padding(.vertical, 16)
                    }
                    ForEach(filteredApps) { app in
                        HStack(spacing: 4) {
                        Button {
                            app.launch()
                            NotificationCenter.default.post(name: .dismissExpandedWidget, object: nil)
                        } label: {
                            HStack(spacing: 8) {
                                if let icon = app.icon {
                                    Image(nsImage: icon).resizable().scaledToFit().frame(width: 18, height: 18)
                                } else { Image(systemName: "app.fill").frame(width: 18, height: 18) }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name).font(.custom("JetBrainsMono Nerd Font", size: 10).weight(.medium)).lineLimit(1)
                                    Text(flashspace.workspaceLabel(for: app.bundleIdentifier))
                                        .font(.custom("JetBrainsMono Nerd Font", size: 8))
                                        .foregroundStyle(.secondary).lineLimit(1)
                                        .help(flashspace.workspaceLabel(for: app.bundleIdentifier))
                                }
                                Spacer()
                                if let badge = running.badge(for: app) { AppBadge(label: badge) }
                                if !running.isRunning(app) {
                                Text(app.applicationURL == nil ? "Missing" : "Launch")
                                    .font(.custom("JetBrainsMono Nerd Font", size: 7)).foregroundStyle(.secondary)
                                }
                            }.padding(.horizontal, 8).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).disabled(app.applicationURL == nil).help("Launch \(app.name)")
                        if running.isRunning(app) {
                            Button {
                                NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == app.bundleIdentifier }
                                    .forEach { $0.terminate() }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary).frame(width: 24, height: 24).contentShape(Rectangle())
                            }.buttonStyle(.plain).help("Quit \(app.name)").accessibilityLabel("Quit \(app.name)")
                        }
                        }
                        .padding(.trailing, 6)
                        .background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.055), lineWidth: 0.75))
                    }
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(.secondary)
                TextField("Filter apps by name…", text: $search).textFieldStyle(.plain)
                    .font(.custom("JetBrainsMono Nerd Font", size: 8)).focused($searchFocused).accessibilityLabel("Filter folder apps by name")
                if !search.isEmpty {
                    Button { search = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear filter")
                }
            }.padding(.horizontal, 8).padding(.vertical, 7)
                .background(Color.black.opacity(0.025), in: Capsule())
                .overlay { Capsule().stroke(Color.black.opacity(0.08), lineWidth: 0.75) }
        }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            searchFocused = true
        }
        .task {
            while !Task.isCancelled {
                await flashspace.refreshAssignments()
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { break }
            }
        }
    }
}

private struct DockSettingsRoot: View {
    @ObservedObject private var registry = DockProfiles.shared
    @State private var selectedID: String
    init(initialID: String) { _selectedID = State(initialValue: initialID) }
    var body: some View {
        VStack(spacing: 0) {
            DockManagementSettings(selectedID: $selectedID)
            Divider()
            SettingsView().defaultAppStorage(registry.defaults(for: selectedID)).id(selectedID)
        }
        .onChange(of: registry.profiles.map(\.id)) { ids in
            if !ids.contains(selectedID), let first = ids.first { selectedID = first }
        }
    }
}

private struct SettingsView: View {
    @StateObject private var updateChecker = UpdateChecker()
    @AppStorage("dock.backdropOpacity") private var backdropOpacity = 0.45
    @AppStorage("dock.horizontalPadding") private var horizontalPadding = 6.0
    @AppStorage("dock.verticalPadding") private var verticalPadding = 4.0
    @AppStorage("widget.flashspace.visible") private var showFlashSpace = true
    @AppStorage("launcher.folders") private var foldersRaw = "[]"
    @State private var expandedFolderIDs = Set<String>()
    @AppStorage("dock.displayMode") private var displayModeRaw = DisplayMode.compact.rawValue
    @AppStorage("terminal.choice") private var terminalChoiceRaw = TerminalChoice.ghostty.rawValue
    @AppStorage("widget.focus.visible") private var showFocus = true
    @AppStorage("widget.weather.visible") private var showWeather = true
    @AppStorage("widget.note.visible") private var showNote = false
    @AppStorage("widget.music.visible") private var showMusic = true
    @AppStorage("widget.herdr.visible") private var showHerdr = true
    @AppStorage("widget.calendar.visible") private var showCalendar = true
    @AppStorage("widget.usage.visible") private var showUsage = true
    @AppStorage("widget.runningApps.visible") private var showRunningApps = true
    @AppStorage("launcher.apps") private var appsRaw = AppCatalog.defaultJSON

    private var apps: [LauncherApp] { AppCatalog.decode(appsRaw) }
    private var folders: [AppFolder] { FolderCatalog.decode(foldersRaw) }

    var body: some View {
        Form {
            Section("Updates") {
                Text(updateChecker.message)
                    .font(.custom("JetBrainsMono Nerd Font", size: 10))
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Check for Updates…") {
                        Task { await updateChecker.check() }
                    }
                    .disabled(updateChecker.isChecking)

                    if updateChecker.isChecking {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    if updateChecker.latestRelease != nil {
                        Button("View Release & Download") {
                            updateChecker.openLatestRelease()
                        }
                    }
                }
                Text("Current version: \(updateChecker.installedVersion). Downloads are installed manually from GitHub.")
                    .font(.custom("JetBrainsMono Nerd Font", size: 10))
                    .foregroundStyle(.secondary)
            }
            Section("Display") {
                VStack(alignment: .leading) {
                    Text("Backdrop opacity: \(Int(backdropOpacity * 100))%")
                    Slider(value: $backdropOpacity, in: 0...1, step: 0.05)
                        .accessibilityLabel("Backdrop opacity")
                }
                VStack(alignment: .leading) {
                    Text("Horizontal padding: \(Int(horizontalPadding)) pt")
                    Slider(value: $horizontalPadding, in: 0...20, step: 1)
                        .accessibilityLabel("Horizontal padding")
                }
                VStack(alignment: .leading) {
                    Text("Vertical padding: \(Int(verticalPadding)) pt")
                    Slider(value: $verticalPadding, in: 0...16, step: 1)
                        .accessibilityLabel("Vertical padding")
                }
            }
            Section("Widgets") {
                Toggle("Focus timer", isOn: $showFocus)
                Toggle("Weather", isOn: $showWeather)
                Toggle("Quick note", isOn: $showNote)
                Toggle("Music controls", isOn: $showMusic)
                Toggle("Herdr agents", isOn: $showHerdr)
                Toggle("Calendar", isOn: $showCalendar)
                Toggle("LLM usage", isOn: $showUsage)
                Toggle("Running apps", isOn: $showRunningApps)
                Toggle("Workspaces (automatic)", isOn: $showFlashSpace)
            }
            Section("Slack previews") {
                SlackConnectionSettings()
            }
            Section("Terminal") {
                Picker("Herdr terminal", selection: $terminalChoiceRaw) {
                    ForEach(TerminalChoice.allCases) { terminal in
                        Text(terminal.isInstalled ? terminal.name : "\(terminal.name) (not installed)")
                            .tag(terminal.rawValue)
                            .disabled(!terminal.isInstalled)
                    }
                }
                Text("Detected applications are enabled automatically.")
                    .font(.custom("JetBrainsMono Nerd Font", size: 10))
                    .foregroundStyle(.secondary)
            }
            Section("App folders") {
                Text("Create folders such as Tools or AI. Drag folders in the dock to reorder them.")
                    .font(.custom("JetBrainsMono Nerd Font", size: 10)).foregroundStyle(.secondary)
                ForEach(folders) { folder in
                    DisclosureGroup(isExpanded: Binding(
                        get: { expandedFolderIDs.contains(folder.id) },
                        set: { if $0 { expandedFolderIDs.insert(folder.id) } else { expandedFolderIDs.remove(folder.id) } }
                    )) {
                        TextField("Folder name", text: Binding(
                            get: { folders.first(where: { $0.id == folder.id })?.name ?? "" },
                            set: { name in updateFolder(folder.id) { $0.name = name } }
                        )).accessibilityLabel("Folder name")
                        ForEach(folder.apps) { app in
                            HStack(spacing: 8) {
                                if let icon = app.icon { Image(nsImage: icon).resizable().scaledToFit().frame(width: 20, height: 20) }
                                Text(app.name).lineLimit(1)
                                Spacer()
                                Button("Remove") { updateFolder(folder.id) { $0.apps.removeAll { $0.id == app.id } } }.buttonStyle(.link)
                            }
                        }
                        Button("Add applications…") {
                            let selected = AppCatalog.chooseApplications()
                            updateFolder(folder.id) { value in
                                for app in selected where !value.apps.contains(where: { $0.id == app.id }) { value.apps.append(app) }
                            }
                        }
                        Button("Delete folder", role: .destructive) {
                            foldersRaw = FolderCatalog.encode(folders.filter { $0.id != folder.id })
                            expandedFolderIDs.remove(folder.id)
                        }.buttonStyle(.link)
                    } label: {
                        Label("\(folder.name.isEmpty ? "Folder" : folder.name) (\(folder.apps.count))", systemImage: "folder")
                    }
                }
                Button("New folder") {
                    let folder = AppFolder(id: UUID().uuidString, name: "New folder", apps: [])
                    foldersRaw = FolderCatalog.encode(folders + [folder])
                    expandedFolderIDs.insert(folder.id)
                }
            }
            Section("Applications") {
                Text("Drag apps in the dock to change their order.")
                    .font(.custom("JetBrainsMono Nerd Font", size: 10))
                    .foregroundStyle(.secondary)
                ForEach(apps) { app in
                    HStack(spacing: 8) {
                        if let icon = app.icon { Image(nsImage: icon).resizable().scaledToFit().frame(width: 24, height: 24) }
                        Text(app.name)
                        Spacer()
                        Button("Remove") { appsRaw = AppCatalog.remove(app, from: appsRaw) }.buttonStyle(.link)
                    }
                }
                Button("Add application…") {
                    if let updated = AppCatalog.addApplication(to: appsRaw) { appsRaw = updated }
                }
                Button("Restore default applications") { appsRaw = AppCatalog.defaultJSON }.buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
        .padding(18)
        .frame(width: 500)
    }

    private func updateFolder(_ id: String, change: (inout AppFolder) -> Void) {
        var values = folders
        guard let index = values.firstIndex(where: { $0.id == id }) else { return }
        change(&values[index])
        foldersRaw = FolderCatalog.encode(values)
    }
}

private extension Color {
    static let ink = Color(red: 0.095, green: 0.125, blue: 0.208)
}
