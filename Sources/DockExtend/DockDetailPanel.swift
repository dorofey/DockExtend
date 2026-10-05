import AppKit
import SwiftUI

final class DockPopupWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

enum DockPanelPlacement {
    static func frame(dock: CGRect, anchor: CGRect, requested: CGSize, screen: CGRect, vertical: Bool) -> CGRect {
        let actual = CGSize(width: min(requested.width, screen.width - 16), height: min(requested.height, screen.height - 16))
        let above = CGPoint(x: anchor.midX - actual.width / 2, y: dock.maxY + 8)
        let below = CGPoint(x: anchor.midX - actual.width / 2, y: dock.minY - actual.height - 8)
        let right = CGPoint(x: dock.maxX + 8, y: anchor.midY - actual.height / 2)
        let left = CGPoint(x: dock.minX - actual.width - 8, y: anchor.midY - actual.height / 2)
        let candidates = vertical ? [right, left, above, below] : [above, below, right, left]
        var origin = candidates.first(where: { screen.contains(CGRect(origin: $0, size: actual)) }) ?? candidates[0]
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - actual.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - actual.height - 8)
        return CGRect(origin: origin, size: actual)
    }
}

struct DockHoverDismissal {
    private var outsideSince: TimeInterval?
    mutating func shouldDismiss(point: CGPoint, anchor: CGRect, panel: CGRect, now: TimeInterval) -> Bool {
        if anchor.contains(point) || panel.contains(point) {
            outsideSince = nil
            return false
        }
        if outsideSince == nil { outsideSince = now }
        return now - outsideSince! >= 0.45
    }
}

struct DockDetailPanel: NSViewRepresentable {
    let content: AnyView
    let size: CGSize
    let vertical: Bool
    let defaults: UserDefaults
    var hoverID: String? = nil
    var onHoverDismiss: (() -> Void)? = nil
    final class Anchor: NSView {
        var reposition: (() -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); reposition?() }
        override func layout() { super.layout(); reposition?() }
    }
    final class Coordinator {
        let panel: DockPopupWindow
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        var observer: NSObjectProtocol?
        private(set) var isDismantled = false
        private var hoverTimer: Timer?
        private var hoverID: String?
        private var hoverDismissal = DockHoverDismissal()
        private var dismissHover: (() -> Void)?
        init() {
            panel = DockPopupWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.contentView = hosting; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = false; panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenNone]
            panel.isReleasedWhenClosed = false
        }
        deinit {
            hoverTimer?.invalidate()
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        func configureHover(anchor: Anchor, id: String?, dismiss: (() -> Void)?) {
            guard !isDismantled else { return }
            dismissHover = dismiss
            if hoverID != id { hoverDismissal = DockHoverDismissal() }
            hoverID = id
            guard id != nil, dismiss != nil else {
                hoverTimer?.invalidate(); hoverTimer = nil
                return
            }
            guard hoverTimer == nil else { return }
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self, weak anchor] _ in
                guard let self, !self.isDismantled, let anchor, let parent = anchor.window,
                      self.panel.isVisible else { return }
                let bounds = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                if self.hoverDismissal.shouldDismiss(point: NSEvent.mouseLocation, anchor: bounds,
                    panel: self.panel.frame, now: ProcessInfo.processInfo.systemUptime) {
                    self.hoverTimer?.invalidate(); self.hoverTimer = nil
                    self.dismissHover?()
                }
            }
            hoverTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        func dismantle() {
            isDismantled = true
            hoverTimer?.invalidate(); hoverTimer = nil; dismissHover = nil
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        func position(_ anchor: NSView, size: CGSize, vertical: Bool) {
            guard !isDismantled, let parent = anchor.window, let screen = parent.screen ?? NSScreen.main else { return }
            let bounds = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            panel.setFrame(DockPanelPlacement.frame(dock: parent.frame, anchor: bounds, requested: size, screen: screen.visibleFrame, vertical: vertical), display: true)
            if panel.parent !== parent { panel.parent?.removeChildWindow(panel); parent.addChildWindow(panel, ordered: .above) }
            panel.orderFrontRegardless()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        let coordinator = context.coordinator
        view.reposition = { [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            coordinator.position(view, size: size, vertical: vertical)
        }
        coordinator.observer = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { [weak view, weak coordinator] notification in
            guard let view, let coordinator, let moved = notification.object as? NSWindow, moved === view.window else { return }
            coordinator.position(view, size: size, vertical: vertical)
        }
        return view
    }
    func updateNSView(_ view: Anchor, context: Context) {
        let coordinator = context.coordinator
        coordinator.configureHover(anchor: view, id: hoverID, dismiss: onHoverDismiss)
        coordinator.hosting.rootView = AnyView(content.defaultAppStorage(defaults).frame(maxWidth: .infinity, maxHeight: .infinity))
        view.reposition = { [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            coordinator.position(view, size: size, vertical: vertical)
        }
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            coordinator.position(view, size: size, vertical: vertical)
        }
    }
    static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) {
        view.reposition = nil
        coordinator.dismantle()
    }
}
