import AppKit
import Carbon
import CoreGraphics
import OSLog

private let hotkeyLogger = Logger(subsystem: "com.dhruvshetty.SafariRecentTabs", category: "HotkeyController")

public final class HotkeyController {
    private let onHotkey: () -> Void
    private let onReverseHotkey: () -> Void
    private let onControlReleased: () -> Void
    private let onEscape: () -> Void
    private let onCloseHighlightedTab: () -> Void
    private let activeApplicationProvider: ActiveApplicationProviding

    private var fallbackHotKeyRefs: [EventHotKeyRef] = []
    private var safariHotKeyRefs: [EventHotKeyRef] = []
    private var closeHighlightedTabHotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?
    private var keyMonitor: Any?
    private var localKeyMonitor: Any?
    private var activeApplicationObserver: NSObjectProtocol?
    private var modifierReleaseTimer: Timer?
    private var keyRepeatTimer: Timer?

    public init(
        onHotkey: @escaping () -> Void,
        onReverseHotkey: @escaping () -> Void,
        onControlReleased: @escaping () -> Void,
        onEscape: @escaping () -> Void,
        onCloseHighlightedTab: @escaping () -> Void,
        activeApplicationProvider: ActiveApplicationProviding = WorkspaceActiveApplicationProvider()
    ) {
        self.onHotkey = onHotkey
        self.onReverseHotkey = onReverseHotkey
        self.onControlReleased = onControlReleased
        self.onEscape = onEscape
        self.onCloseHighlightedTab = onCloseHighlightedTab
        self.activeApplicationProvider = activeApplicationProvider
    }

    public func start() {
        installCarbonEventHandler()
        registerFallbackHotkeys()
        refreshSafariScopedHotkeys()
        installActiveApplicationObserver()
        installEventMonitors()
    }

    public func refreshSafariScopedHotkeys() {
        if activeApplicationProvider.isSafariFrontmost {
            registerSafariHotkeysIfNeeded()
        } else {
            unregisterSafariHotkeys()
        }
    }

    public func stop() {
        unregisterFallbackHotkeys()
        unregisterSafariHotkeys()
        unregisterCloseHighlightedTabHotkey()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        eventHandlerRef = nil
        modifierReleaseTimer?.invalidate()
        modifierReleaseTimer = nil
        stopKeyRepeat()
        if let activeApplicationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeApplicationObserver)
        }
        activeApplicationObserver = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
    }

    private func installCarbonEventHandler() {
        guard eventHandlerRef == nil else {
            return
        }

        // Released events let a held Tab auto-repeat until the key comes up.
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else {
                    return noErr
                }
                let controller = Unmanaged<HotkeyController>.fromOpaque(userData).takeUnretainedValue()
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                    // Pressing or releasing Shift while Tab is held can also report a release; keep repeating then.
                    if !isTabKeyDown() {
                        controller.stopKeyRepeat()
                    }
                    return noErr
                }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else {
                    controller.onHotkey()
                    return noErr
                }
                switch hotKeyID.id {
                case HotkeyID.fallbackReverse.rawValue, HotkeyID.safariReverse.rawValue:
                    controller.trigger(.reverse)
                case HotkeyID.closeHighlightedTab.rawValue:
                    controller.onCloseHighlightedTab()
                default:
                    controller.trigger(.forward)
                }
                return noErr
            },
            eventTypes.count,
            &eventTypes,
            selfPointer,
            &eventHandlerRef
        )
    }

    private func registerFallbackHotkeys() {
        guard fallbackHotKeyRefs.isEmpty else {
            return
        }
        registerHotkey(
            id: HotkeyID.fallbackForward.rawValue,
            keyCode: UInt32(kVK_ANSI_Grave),
            modifiers: UInt32(controlKey),
            label: "Control-`",
            refs: &fallbackHotKeyRefs
        )
        registerHotkey(
            id: HotkeyID.fallbackReverse.rawValue,
            keyCode: UInt32(kVK_ANSI_Grave),
            modifiers: UInt32(controlKey | shiftKey),
            label: "Control-Shift-`",
            refs: &fallbackHotKeyRefs
        )
    }

    private func registerSafariHotkeysIfNeeded() {
        guard safariHotKeyRefs.isEmpty else {
            return
        }
        registerHotkey(
            id: HotkeyID.safariForward.rawValue,
            keyCode: UInt32(kVK_Tab),
            modifiers: UInt32(controlKey),
            label: "Safari Control-Tab",
            refs: &safariHotKeyRefs
        )
        registerHotkey(
            id: HotkeyID.safariReverse.rawValue,
            keyCode: UInt32(kVK_Tab),
            modifiers: UInt32(controlKey | shiftKey),
            label: "Safari Control-Shift-Tab",
            refs: &safariHotKeyRefs
        )
    }

    private func unregisterFallbackHotkeys() {
        unregisterHotkeys(&fallbackHotKeyRefs)
    }

    private func unregisterSafariHotkeys() {
        unregisterHotkeys(&safariHotKeyRefs)
    }

    public func setCloseHighlightedTabHotkeyEnabled(_ isEnabled: Bool) {
        if isEnabled {
            guard closeHighlightedTabHotKeyRefs.isEmpty else {
                return
            }
            registerHotkey(
                id: HotkeyID.closeHighlightedTab.rawValue,
                keyCode: UInt32(kVK_ANSI_W),
                modifiers: UInt32(controlKey),
                label: "Close highlighted tab",
                refs: &closeHighlightedTabHotKeyRefs
            )
        } else {
            unregisterCloseHighlightedTabHotkey()
        }
    }

    private func unregisterCloseHighlightedTabHotkey() {
        unregisterHotkeys(&closeHighlightedTabHotKeyRefs)
    }

    private func unregisterHotkeys(_ refs: inout [EventHotKeyRef]) {
        for hotKeyRef in refs {
            UnregisterEventHotKey(hotKeyRef)
        }
        refs.removeAll()
    }

    private func registerHotkey(
        id: UInt32,
        keyCode: UInt32,
        modifiers: UInt32,
        label: String,
        refs: inout [EventHotKeyRef]
    ) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: fourCharCode("SRTS"), id: id)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr, let hotKeyRef {
            refs.append(hotKeyRef)
            hotkeyLogger.info("Registered \(label, privacy: .public) hotkey")
        } else {
            hotkeyLogger.error("Failed to register \(label, privacy: .public) hotkey. status=\(status, privacy: .public)")
        }
    }

    private func installActiveApplicationObserver() {
        guard activeApplicationObserver == nil else {
            return
        }
        activeApplicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshSafariScopedHotkeys()
        }
    }

    private func installEventMonitors() {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                self?.onEscape()
            }
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                self?.onEscape()
                return nil
            }
            return event
        }
    }

    private func trigger(_ action: KeyboardShortcutAction) {
        beginModifierReleasePolling()
        fire(action)
        startKeyRepeat()
    }

    private func fire(_ action: KeyboardShortcutAction) {
        switch action {
        case .forward:
            onHotkey()
        case .reverse:
            onReverseHotkey()
        }
    }

    // Carbon hotkeys fire once per press, so mimic the system key repeat while Tab is held.
    // Direction follows the live Shift state, so pressing Shift mid-repeat reverses like Command-Tab.
    private func startKeyRepeat() {
        stopKeyRepeat()
        let timer = Timer(timeInterval: NSEvent.keyRepeatInterval, repeats: true) { [weak self] _ in
            guard let self else {
                return
            }
            guard isTabKeyDown() else {
                self.stopKeyRepeat()
                return
            }
            self.fire(GetCurrentKeyModifiers() & UInt32(shiftKey) != 0 ? .reverse : .forward)
        }
        timer.fireDate = Date().addingTimeInterval(NSEvent.keyRepeatDelay)
        RunLoop.main.add(timer, forMode: .common)
        keyRepeatTimer = timer
    }

    private func stopKeyRepeat() {
        keyRepeatTimer?.invalidate()
        keyRepeatTimer = nil
    }

    private func beginModifierReleasePolling() {
        guard modifierReleaseTimer == nil else {
            return
        }
        modifierReleaseTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let modifiers = GetCurrentKeyModifiers()
            if modifiers & UInt32(controlKey) == 0 {
                timer.invalidate()
                self.modifierReleaseTimer = nil
                self.stopKeyRepeat()
                self.onControlReleased()
            }
        }
    }
}

private enum HotkeyID: UInt32 {
    case fallbackForward = 1
    case fallbackReverse = 2
    case safariForward = 3
    case safariReverse = 4
    case closeHighlightedTab = 5
}

private func isTabKeyDown() -> Bool {
    CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Tab))
}

private func fourCharCode(_ string: String) -> OSType {
    string.utf8.reduce(0) { result, byte in
        (result << 8) + OSType(byte)
    }
}
