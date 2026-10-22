import AppKit
import Carbon
import SwiftUI

@MainActor
public protocol TabSearchPanelControlling {
    func show(tabs: [SafariTab], onSelect: @escaping (SafariTab) -> Void)
    func hide()
}

/// Borderless panels refuse key status by default; the search field needs it to receive typing.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
public final class TabSearchPanelController: NSObject, TabSearchPanelControlling, NSWindowDelegate {
    private var panel: KeyablePanel?
    private var model: TabSearchModel?
    private var keyMonitor: Any?
    public var onVisibilityChanged: (Bool) -> Void = { _ in }

    public override init() {
        super.init()
    }

    public func show(tabs: [SafariTab], onSelect: @escaping (SafariTab) -> Void) {
        let model = TabSearchModel(tabs: tabs) { [weak self] tab in
            self?.hide()
            onSelect(tab)
        }
        let panel = panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: TabSearchView(model: model))
        if let screen = NSScreen.main {
            panel.setFrame(TabSearchMetrics.panelFrame(visibleFrame: screen.visibleFrame), display: true)
        }
        // Non-activating, so Safari stays the active app while the panel takes keystrokes.
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        self.model = model
        installKeyMonitor()
        onVisibilityChanged(true)
    }

    public func hide() {
        guard model != nil else {
            return
        }
        model = nil
        removeKeyMonitor()
        panel?.orderOut(nil)
        onVisibilityChanged(false)
    }

    public func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: TabSearchMetrics.panelWidth, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        return panel
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else {
            return
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let model = self.model, self.panel?.isKeyWindow == true else {
                return event
            }
            switch Int(event.keyCode) {
            case kVK_DownArrow:
                model.moveSelection(by: 1)
            case kVK_UpArrow:
                model.moveSelection(by: -1)
            case kVK_Return, kVK_ANSI_KeypadEnter:
                model.selectCurrent()
            case kVK_Escape:
                self.hide()
            default:
                return event
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }
}
