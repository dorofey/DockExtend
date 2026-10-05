import AppKit
import SwiftUI

enum DockOrientation: String, Codable, CaseIterable { case horizontal, vertical }
struct DockPosition: Codable, Equatable { var x: Double; var y: Double }
struct DockProfile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var orientation: DockOrientation = .horizontal
    var displayID: String?
    var positions: [String: DockPosition] = [:]
}

extension Notification.Name {
    static let dockProfilesChanged = Notification.Name("DockExtend.profilesChanged")
}

@MainActor
final class DockProfiles: ObservableObject {
    static let shared = DockProfiles()
    @Published private(set) var profiles: [DockProfile]
    private let key = "dock.profiles.v1"
    private let storage: UserDefaults
    private let suitePrefix: String
    init(storage: UserDefaults = .standard, suitePrefix: String = "com.dorofeev.DockExtend.dock.") {
        self.storage = storage; self.suitePrefix = suitePrefix
        if let data = storage.data(forKey: key),
           let saved = try? JSONDecoder().decode([DockProfile].self, from: data), !saved.isEmpty {
            profiles = saved
        } else { profiles = [DockProfile(id: "primary", name: "Main dock")] }
    }
    func defaults(for id: String) -> UserDefaults {
        id == "primary" ? storage : UserDefaults(suiteName: suitePrefix + id)!
    }
    func update(_ profile: DockProfile, notify: Bool = true) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile; persist(notify: notify)
    }
    @discardableResult
    func add(copying source: DockProfile? = nil) -> String {
        let id = UUID().uuidString
        var profile = DockProfile(id: id, name: source.map { "\($0.name) copy" } ?? "Dock \(profiles.count + 1)")
        profile.orientation = source?.orientation ?? .horizontal
        if let source {
            let original = defaults(for: source.id)
            let target = defaults(for: id)
            for (key, value) in original.dictionaryRepresentation() where Self.isDockSetting(key) { target.set(value, forKey: key) }
        }
        profiles.append(profile); persist(); return id
    }
    func remove(_ id: String) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }; persist()
    }
    static func isDockSetting(_ key: String) -> Bool {
        key.hasPrefix("launcher.") || key.hasPrefix("widget.") ||
        ["dock.itemOrder", "dock.backdropOpacity", "dock.horizontalPadding", "dock.verticalPadding", "dock.displayMode", "terminal.choice"].contains(key)
    }
    private func persist(notify: Bool = true) {
        if let data = try? JSONEncoder().encode(profiles) { storage.set(data, forKey: key) }
        if notify { NotificationCenter.default.post(name: .dockProfilesChanged, object: nil) }
    }
    static func displayID(_ screen: NSScreen) -> String {
        String((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0)
    }
}

struct DockManagementSettings: View {
    @ObservedObject private var registry = DockProfiles.shared
    @Binding var selectedID: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Dock", selection: $selectedID) {
                ForEach(registry.profiles) { Text($0.name).tag($0.id) }
            }
            if let profile = registry.profiles.first(where: { $0.id == selectedID }) {
                TextField("Dock name", text: Binding(get: {
                    registry.profiles.first(where: { $0.id == selectedID })?.name ?? ""
                }, set: { value in
                    guard var current = registry.profiles.first(where: { $0.id == selectedID }) else { return }
                    current.name = value; registry.update(current)
                }))
                Picker("Layout", selection: Binding(get: {
                    registry.profiles.first(where: { $0.id == selectedID })?.orientation ?? .horizontal
                }, set: { value in
                    guard var current = registry.profiles.first(where: { $0.id == selectedID }) else { return }
                    current.orientation = value; registry.update(current)
                })) {
                    Text("Horizontal").tag(DockOrientation.horizontal)
                    Text("Vertical").tag(DockOrientation.vertical)
                }.pickerStyle(.segmented)
                HStack {
                    Button("Add dock") { selectedID = registry.add() }
                    Button("Duplicate") { selectedID = registry.add(copying: profile) }
                    Button("Remove") {
                        registry.remove(selectedID)
                        selectedID = registry.profiles.first!.id
                    }.disabled(registry.profiles.count == 1)
                    Button("Reset position") {
                        var reset = profile; reset.positions = [:]; reset.displayID = nil
                        registry.update(reset)
                    }
                }
            }
            Text("Drag the grip on each dock to move it. Each dock saves its apps, groups, widgets and position independently.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(16)
    }
}

struct DockMoveHandle: NSViewRepresentable {
    final class Grip: NSView {
        override func mouseDown(with event: NSEvent) {
            NotificationCenter.default.post(name: Notification.Name("DockExtend.dismissExpandedWidget"), object: nil)
            window?.performDrag(with: event)
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.withAlphaComponent(0.55).setFill()
            for x in [bounds.midX - 2, bounds.midX + 2] {
                for y in [bounds.midY - 4, bounds.midY, bounds.midY + 4] {
                    NSBezierPath(ovalIn: NSRect(x: x - 0.7, y: y - 0.7, width: 1.4, height: 1.4)).fill()
                }
            }
        }
    }
    func makeNSView(context: Context) -> Grip {
        let grip = Grip(); grip.setAccessibilityLabel("Move dock"); grip.setAccessibilityRole(.button); return grip
    }
    func updateNSView(_ nsView: Grip, context: Context) {}
}
