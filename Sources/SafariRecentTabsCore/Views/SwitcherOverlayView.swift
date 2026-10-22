import AppKit
import SwiftUI

public struct SwitcherOverlayView: View {
    private let state: SwitcherState

    public init(state: SwitcherState) {
        self.state = state
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: SwitcherOverlayMetrics.rowSpacing) {
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

private struct SwitcherTabRow: View {
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

                Text(display.domain)
                    .font(.system(size: 11))
                    .foregroundStyle(isHighlighted ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
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
