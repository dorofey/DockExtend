import AppKit
import Foundation

@main struct DockChecks {
    @MainActor static func main() {
        let domain = "DockExtend.checks." + UUID().uuidString
        let storage = UserDefaults(suiteName: domain)!
        let prefix = domain + ".dock."
        let registry = DockProfiles(storage: storage, suitePrefix: prefix)
        let main = registry.profiles[0]
        precondition(main.id == "primary")
        storage.set("original-apps", forKey: "launcher.apps")
        storage.set("private-client", forKey: "slack.oauth.clientID")
        let copied = registry.add(copying: main)
        let other = registry.add()
        defer {
            storage.removePersistentDomain(forName: domain)
            for id in [copied, other] { UserDefaults.standard.removePersistentDomain(forName: prefix + id) }
        }
        precondition(registry.defaults(for: copied).string(forKey: "launcher.apps") == "original-apps")
        precondition(registry.defaults(for: copied).string(forKey: "slack.oauth.clientID") == nil)
        registry.defaults(for: copied).set("copy-apps", forKey: "launcher.apps")
        precondition(storage.string(forKey: "launcher.apps") == "original-apps")
        precondition(registry.defaults(for: other).string(forKey: "launcher.apps") == nil)
        var profile = registry.profiles.first { $0.id == copied }!
        profile.orientation = .vertical; profile.displayID = "test-display"
        profile.positions["test-display"] = DockPosition(x: -1400, y: 210)
        registry.update(profile, notify: false)
        let reloaded = DockProfiles(storage: storage, suitePrefix: prefix)
        precondition(reloaded.profiles.first { $0.id == copied } == profile)
        registry.remove(other); registry.remove(copied); registry.remove(main.id)
        precondition(registry.profiles.count == 1)

        let screen = CGRect(x: 0, y: 0, width: 1200, height: 900)
        let size = CGSize(width: 330, height: 590)
        let bottomDock = CGRect(x: 300, y: 0, width: 600, height: 60)
        let above = DockPanelPlacement.frame(dock: bottomDock, anchor: bottomDock, requested: size, screen: screen, vertical: false)
        precondition(screen.contains(above) && above.minY >= bottomDock.maxY)
        let topDock = CGRect(x: 300, y: 830, width: 600, height: 60)
        let below = DockPanelPlacement.frame(dock: topDock, anchor: topDock, requested: size, screen: screen, vertical: false)
        precondition(screen.contains(below) && below.maxY <= topDock.minY)
        let rightDock = CGRect(x: 1100, y: 250, width: 90, height: 300)
        let left = DockPanelPlacement.frame(dock: rightDock, anchor: rightDock, requested: size, screen: screen, vertical: true)
        precondition(screen.contains(left) && left.maxX <= rightDock.minX)
        let negativeScreen = CGRect(x: -1600, y: 0, width: 1600, height: 900)
        let secondDock = CGRect(x: -1590, y: 20, width: 90, height: 300)
        let clamped = DockPanelPlacement.frame(dock: secondDock, anchor: secondDock, requested: CGSize(width: 330, height: 1500), screen: negativeScreen, vertical: true)
        precondition(negativeScreen.contains(clamped))
        var hover = DockHoverDismissal()
        let icon = CGRect(x: 300, y: 0, width: 40, height: 50)
        let panel = CGRect(x: 150, y: 58, width: 330, height: 590)
        let outside = CGPoint(x: 900, y: 700)
        precondition(!hover.shouldDismiss(point: CGPoint(x: 320, y: 25), anchor: icon, panel: panel, now: 0))
        precondition(!hover.shouldDismiss(point: outside, anchor: icon, panel: panel, now: 1))
        precondition(!hover.shouldDismiss(point: CGPoint(x: 320, y: 54), anchor: icon, panel: panel, now: 1.2))
        precondition(!hover.shouldDismiss(point: CGPoint(x: 200, y: 200), anchor: icon, panel: panel, now: 1.3))
        precondition(!hover.shouldDismiss(point: outside, anchor: icon, panel: panel, now: 2))
        precondition(hover.shouldDismiss(point: outside, anchor: icon, panel: panel, now: 2.5))
        precondition(!hover.shouldDismiss(point: CGPoint(x: 320, y: 25), anchor: icon, panel: panel, now: 3))
        precondition(!hover.shouldDismiss(point: outside, anchor: icon, panel: panel, now: 3.1))
        precondition(!hover.shouldDismiss(point: outside, anchor: icon, panel: panel, now: 3.3))
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: icon, styleMask: [.borderless], backing: .buffered, defer: false)
        let anchor = DockDetailPanel.Anchor(frame: CGRect(origin: .zero, size: icon.size))
        parent.contentView = anchor
        let coordinator = DockDetailPanel.Coordinator()
        coordinator.dismantle()
        coordinator.position(anchor, size: size, vertical: false)
        precondition(!coordinator.panel.isVisible && coordinator.panel.parent == nil)
        print("Passed: dock migration, duplication, isolated contents, layout/position persistence, removal guard, popup directions and display-edge bounds.")
        print("Passed: hover gap grace, panel entry, missed-exit dismissal, re-entry reset and preventing dismantled panels from reopening.")
    }
}
