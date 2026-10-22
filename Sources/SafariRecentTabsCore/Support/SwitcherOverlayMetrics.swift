import AppKit

public enum SwitcherOverlayMetrics {
    public static let rowHeight: CGFloat = 40
    public static let rowSpacing: CGFloat = 2
    public static let listPadding: CGFloat = 6
    public static let panelWidth: CGFloat = 520
    public static let maximumVisibleRows = 12
    public static let screenMargin: CGFloat = 24

    public static func panelFrame(tabCount: Int, visibleFrame: NSRect) -> NSRect {
        let visibleRows = min(max(tabCount, 1), maximumVisibleRows)
        let contentHeight = CGFloat(visibleRows) * rowHeight
            + CGFloat(visibleRows - 1) * rowSpacing
            + listPadding * 2
        let width = min(panelWidth, visibleFrame.width - screenMargin * 2)
        let height = min(contentHeight, visibleFrame.height - screenMargin * 2)

        return NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
    }
}
