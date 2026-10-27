import AppKit
import SwiftUI

/// Long-lived model behind the reused search panel; `load` resets it for each open.
@MainActor
public final class TabSearchModel: ObservableObject {
    @Published public var query = "" {
        didSet {
            guard query != oldValue else {
                return
            }
            updateResults()
            selectedIndex = 0
        }
    }
    @Published public private(set) var selectedIndex = 0
    @Published public private(set) var results: [SafariTab] = []

    private var tabs: [SafariTab] = []
    // Lowercased title + URL per tab, built once per open instead of on every keystroke.
    private var haystacks: [String] = []
    private var onSelect: (SafariTab) -> Void = { _ in }

    public init() {}

    /// `tabs` arrive in most-recently-used order, current tab first.
    public func load(tabs: [SafariTab], onSelect: @escaping (SafariTab) -> Void) {
        self.tabs = tabs
        self.onSelect = onSelect
        haystacks = tabs.map { "\($0.title) \($0.url.absoluteString)".lowercased() }
        query = ""
        updateResults()
        // With no query the current tab is pointless to pick, so start on the previous one.
        selectedIndex = tabs.count > 1 ? 1 : 0
    }

    /// Every whitespace-separated word must appear in the title or URL; recency order is kept.
    private func updateResults() {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else {
            results = tabs
            return
        }
        results = zip(tabs, haystacks).compactMap { tab, haystack in
            words.allSatisfy { haystack.contains($0) } ? tab : nil
        }
    }

    public func moveSelection(by offset: Int) {
        let count = results.count
        guard count > 0 else {
            return
        }
        selectedIndex = (selectedIndex + offset + count) % count
    }

    public var selectedTab: SafariTab? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    public func selectCurrent() {
        guard results.indices.contains(selectedIndex) else {
            return
        }
        onSelect(results[selectedIndex])
    }

    public func select(_ tab: SafariTab) {
        onSelect(tab)
    }
}

public struct TabSearchView: View {
    @ObservedObject private var model: TabSearchModel

    public init(model: TabSearchModel) {
        self.model = model
    }

    public var body: some View {
        let results = model.results

        VStack(spacing: 0) {
            SearchField(text: $model.query)
                .padding(.horizontal, 16)
                .frame(height: TabSearchMetrics.fieldHeight)

            Divider()

            if results.isEmpty {
                Text("No matching tabs")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        // Plain VStack keyed by tab ID: a LazyVStack keyed by row index kept showing stale titles.
                        VStack(spacing: SwitcherOverlayMetrics.rowSpacing) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, tab in
                                SwitcherTabRow(
                                    display: TabDisplayModel(tab: tab),
                                    isHighlighted: index == model.selectedIndex
                                )
                                .id(tab.id)
                                .contentShape(Rectangle())
                                .onTapGesture { model.select(tab) }
                            }
                        }
                        .padding(SwitcherOverlayMetrics.listPadding)
                    }
                    .onChange(of: model.selectedIndex) { _ in
                        if let id = model.selectedTab?.id {
                            proxy.scrollTo(id)
                        }
                    }
                    .onAppear {
                        if let id = model.selectedTab?.id {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 1)
        )
    }
}

/// AppKit text field that grabs first responder once its window is key.
/// SwiftUI's `@FocusState` fires before the non-activating panel becomes key, so it often lost focus.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> AutoFocusTextField {
        let field = AutoFocusTextField()
        field.placeholderString = "Search tabs"
        field.font = .systemFont(ofSize: 18)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: AutoFocusTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else {
                return
            }
            text.wrappedValue = field.stringValue
        }
    }
}

final class AutoFocusTextField: NSTextField {
    private var keyObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyObserver {
            NotificationCenter.default.removeObserver(keyObserver)
        }
        keyObserver = nil
        guard let window else {
            return
        }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.focus()
        }
        if window.isKeyWindow {
            focus()
        }
    }

    private func focus() {
        guard let window, window.firstResponder !== currentEditor() else {
            return
        }
        window.makeFirstResponder(self)
    }
}

public enum TabSearchMetrics {
    public static let fieldHeight: CGFloat = 48
    public static let visibleRows = 10
    public static let panelWidth: CGFloat = 600

    public static func panelFrame(visibleFrame: NSRect) -> NSRect {
        let listHeight = CGFloat(visibleRows) * SwitcherOverlayMetrics.rowHeight
            + CGFloat(visibleRows - 1) * SwitcherOverlayMetrics.rowSpacing
            + SwitcherOverlayMetrics.listPadding * 2
        let width = min(panelWidth, visibleFrame.width - SwitcherOverlayMetrics.screenMargin * 2)
        let height = min(fieldHeight + 1 + listHeight, visibleFrame.height - SwitcherOverlayMetrics.screenMargin * 2)

        // Sit in the upper part of the screen, like Spotlight.
        return NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.minY + visibleFrame.height * 0.7 - height / 2,
            width: width,
            height: height
        )
    }
}
