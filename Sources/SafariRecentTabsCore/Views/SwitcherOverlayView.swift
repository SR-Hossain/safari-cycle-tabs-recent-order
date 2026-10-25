import AppKit
import SwiftUI

/// Holds what the long-lived switcher view shows, so each keypress updates data instead of rebuilding the view.
@MainActor
public final class SwitcherViewModel: ObservableObject {
    @Published public var state = SwitcherState(tabs: [], highlightedIndex: 0)

    public init() {}
}

public struct SwitcherOverlayView: View {
    @ObservedObject private var model: SwitcherViewModel

    public init(model: SwitcherViewModel) {
        self.model = model
    }

    public var body: some View {
        let state = model.state

        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: SwitcherOverlayMetrics.rowSpacing) {
                    ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, tab in
                        SwitcherTabRow(
                            display: TabDisplayModel(tab: tab),
                            isHighlighted: index == state.highlightedIndex
                        )
                        .id(index)
                    }
                }
                .padding(SwitcherOverlayMetrics.listPadding)
            }
            .onAppear {
                proxy.scrollTo(state.highlightedIndex, anchor: .center)
            }
            .onChange(of: state) { newState in
                proxy.scrollTo(newState.highlightedIndex, anchor: .center)
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

struct SwitcherTabRow: View {
    let display: TabDisplayModel
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Safari's own tab position, not the recency rank.
            Text("\(display.tab.index)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(isHighlighted ? .white.opacity(0.8) : .secondary)
                .frame(width: 22, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(display.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isHighlighted ? .white : .primary)
                    .lineLimit(1)

                Text(display.urlText)
                    .font(.system(size: 11))
                    .foregroundStyle(isHighlighted ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, minHeight: SwitcherOverlayMetrics.rowHeight, alignment: .leading)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? Color.accentColor : .clear)
        )
    }
}
