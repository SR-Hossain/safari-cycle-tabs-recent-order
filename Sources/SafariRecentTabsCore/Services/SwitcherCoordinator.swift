import AppKit
import Foundation
import os

private let switcherLogger = Logger(subsystem: "com.dhruvshetty.SafariRecentTabs", category: "Switcher")

@MainActor
public final class SwitcherCoordinator {
    private let safariClient: SafariControlling
    private let panelController: SwitcherPanelControlling
    private let activeApplicationProvider: ActiveApplicationProviding
    private let onSwitcherVisibilityChanged: (Bool) -> Void
    private var includesTabsFromAllWindows: Bool
    private var recentTabs = RecentTabStore()
    private var state: SwitcherState?
    private var isActivating = false
    // Last known tab list and active tab, so the switcher can open without waiting on Safari.
    private var cachedTabs: [SafariTab] = []
    private var lastActiveTab: SafariTab?

    public init(
        safariClient: SafariControlling,
        panelController: SwitcherPanelControlling,
        activeApplicationProvider: ActiveApplicationProviding = WorkspaceActiveApplicationProvider(),
        includesTabsFromAllWindows: Bool = false,
        onSwitcherVisibilityChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.safariClient = safariClient
        self.panelController = panelController
        self.activeApplicationProvider = activeApplicationProvider
        self.includesTabsFromAllWindows = includesTabsFromAllWindows
        self.onSwitcherVisibilityChanged = onSwitcherVisibilityChanged
    }

    public func refreshActiveTab() async {
        guard activeApplicationProvider.isSafariFrontmost else {
            return
        }
        guard let current = try? safariClient.frontmostActiveTab() else {
            return
        }
        lastActiveTab = current
        recentTabs.noteActive(current)
    }

    /// Fills the tab cache; called when Safari comes to the front.
    public func prefetchTabs() async {
        guard activeApplicationProvider.isSafariFrontmost, state == nil else {
            return
        }
        if let tabs = try? timedTabsForSwitcher(reason: "prefetch") {
            cachedTabs = tabs
        }
    }

    public func handleHotkey() async {
        if var existingState = state {
            existingState.cycleForward()
            state = existingState
            panelController.show(state: existingState)
            return
        }

        await openSwitcher(reverse: false)
    }

    public func handleReverseHotkey() async {
        if var existingState = state {
            existingState.cycleBackward()
            state = existingState
            panelController.show(state: existingState)
            return
        }

        await openSwitcher(reverse: true)
    }

    public func setIncludesTabsFromAllWindows(_ isEnabled: Bool) {
        guard includesTabsFromAllWindows != isEnabled else {
            return
        }
        includesTabsFromAllWindows = isEnabled
        cachedTabs = []
        cancel()
    }

    private func openSwitcher(reverse: Bool) async {
        guard activeApplicationProvider.isSafariFrontmost else {
            return
        }

        if cachedTabs.count > 1, let current = lastActiveTab {
            show(tabs: cachedTabs, current: current, reverse: reverse)
            // Let the panel draw first, then correct it with Safari's live tab list.
            Task { @MainActor in
                await self.reconcileOpenSwitcher()
            }
            return
        }

        do {
            let tabs = try timedTabsForSwitcher(reason: "open")
            cachedTabs = tabs
            guard let current = tabs.first(where: \.isActive) else {
                return
            }
            show(tabs: tabs, current: current, reverse: reverse)
        } catch {
            panelController.hide()
            state = nil
            onSwitcherVisibilityChanged(false)
        }
    }

    private func show(tabs: [SafariTab], current: SafariTab, reverse: Bool) {
        recentTabs.noteActive(current)
        let ordered = recentTabs.orderedTabs(current: current, availableTabs: tabs)
        guard ordered.count > 1 else {
            return
        }
        let newState = SwitcherState(
            tabs: ordered,
            highlightedIndex: initialHighlightIndex(for: ordered, reverse: reverse)
        )

        // A quick tap released Control before we got here: switch without ever showing the panel.
        guard NSEvent.modifierFlags.contains(.control) else {
            if let target = newState.highlightedTab {
                activate(target)
            }
            return
        }

        state = newState
        onSwitcherVisibilityChanged(true)
        panelController.show(state: newState)
    }

    private func reconcileOpenSwitcher() async {
        guard let openState = state,
              let tabs = try? timedTabsForSwitcher(reason: "reconcile"),
              state != nil
        else {
            return
        }
        cachedTabs = tabs
        guard let current = tabs.first(where: \.isActive) else {
            return
        }

        recentTabs.noteActive(current)
        let ordered = recentTabs.orderedTabs(current: current, availableTabs: tabs)
        guard ordered.count > 1 else {
            cancel()
            return
        }

        // Keep the user's highlighted tab even if its index shifted in the live list.
        let highlighted = openState.highlightedTab
        let highlightedIndex = ordered.firstIndex {
            $0.windowID == highlighted?.windowID && $0.url == highlighted?.url
        } ?? min(openState.highlightedIndex, ordered.count - 1)

        let newState = SwitcherState(tabs: ordered, highlightedIndex: highlightedIndex)
        guard newState != openState else {
            return
        }
        state = newState
        panelController.show(state: newState)
    }

    private func initialHighlightIndex(for orderedTabs: [SafariTab], reverse: Bool) -> Int {
        guard reverse, orderedTabs.count > 1 else {
            return RecentTabStore.initialHighlightIndex(for: orderedTabs)
        }
        return orderedTabs.count - 1
    }

    public func handleControlRelease() async {
        guard isActivating == false, let selected = state?.highlightedTab else {
            return
        }

        isActivating = true
        defer {
            isActivating = false
        }

        // Hide before talking to Safari so the panel disappears the moment Control is released.
        state = nil
        panelController.hide()
        onSwitcherVisibilityChanged(false)
        activate(selected)
    }

    private func activate(_ tab: SafariTab) {
        guard (try? safariClient.activate(tab: tab)) != nil else {
            return
        }
        lastActiveTab = tab
        recentTabs.noteActive(tab)
    }

    public func handleCloseHighlightedTab() async {
        guard var existingState = state, let selected = existingState.highlightedTab else {
            return
        }

        do {
            try safariClient.close(tab: selected)
            let remainingTabs = try tabsForSwitcher()
            cachedTabs = remainingTabs
            guard !remainingTabs.isEmpty else {
                cancel()
                return
            }

            let remainingOrderedTabs = existingState.tabs.compactMap {
                updatedTab(for: $0, afterClosing: selected, in: remainingTabs)
            }
            guard !remainingOrderedTabs.isEmpty else {
                cancel()
                return
            }

            let nextHighlightedIndex = min(existingState.highlightedIndex, remainingOrderedTabs.count - 1)
            existingState = SwitcherState(
                tabs: remainingOrderedTabs,
                highlightedIndex: nextHighlightedIndex
            )
            state = existingState
            panelController.show(state: existingState)
        } catch {
            return
        }
    }

    public func cancel() {
        guard state != nil else {
            return
        }
        state = nil
        panelController.hide()
        onSwitcherVisibilityChanged(false)
    }

    private func updatedTab(for tab: SafariTab, afterClosing closedTab: SafariTab, in remainingTabs: [SafariTab]) -> SafariTab? {
        guard tab.id != closedTab.id else {
            return nil
        }

        let updatedIndex: Int
        if tab.windowID == closedTab.windowID, tab.index > closedTab.index {
            updatedIndex = tab.index - 1
        } else {
            updatedIndex = tab.index
        }

        return remainingTabs.first {
            $0.windowID == tab.windowID && $0.index == updatedIndex
        }
    }

    private func timedTabsForSwitcher(reason: StaticString) throws -> [SafariTab] {
        let start = ContinuousClock.now
        let tabs = try tabsForSwitcher()
        let elapsed = ContinuousClock.now - start
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        switcherLogger.notice("Fetched \(tabs.count, privacy: .public) tabs for \(reason, privacy: .public) in \(milliseconds, format: .fixed(precision: 1), privacy: .public) ms")
        return tabs
    }

    private func tabsForSwitcher() throws -> [SafariTab] {
        if includesTabsFromAllWindows {
            return try safariClient.allWindowTabs()
        }
        return try safariClient.frontmostWindowTabs()
    }
}
