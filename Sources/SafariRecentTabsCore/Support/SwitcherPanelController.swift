import AppKit
import SwiftUI

@MainActor
public protocol SwitcherPanelControlling {
    func show(state: SwitcherState)
    func hide()
}

@MainActor
public final class SwitcherPanelController: SwitcherPanelControlling {
    private let model = SwitcherViewModel()
    private lazy var panel = makePanel()

    public init() {}

    /// Builds the panel and its SwiftUI view up front so the first Control-Tab does not pay for it.
    public func prewarm() {
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    public func show(state: SwitcherState) {
        let tabCountChanged = model.state.tabs.count != state.tabs.count
        model.state = state
        if !panel.isVisible {
            // A hosting view that sat in an ordered-out panel stops redrawing, so each open gets a fresh one.
            // While the panel stays open, keypresses only update the model.
            panel.contentView = NSHostingView(rootView: SwitcherOverlayView(model: model))
            place(panel: panel, tabCount: state.tabs.count)
        } else if tabCountChanged {
            place(panel: panel, tabCount: state.tabs.count)
        }
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 190),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: SwitcherOverlayView(model: model))
        return panel
    }

    private func place(panel: NSPanel, tabCount: Int) {
        guard let screen = NSScreen.main else {
            return
        }
        let frame = SwitcherOverlayMetrics.panelFrame(tabCount: tabCount, visibleFrame: screen.visibleFrame)
        panel.setFrame(frame, display: true)
    }
}
