import Foundation

public struct SafariTab: Identifiable, Equatable, Hashable, Sendable {
    public let windowID: Int
    public let index: Int
    public let title: String
    public let url: URL
    public let isActive: Bool
    /// Which copy of this URL in its window (0 for the first), so duplicate tabs stay distinct.
    public let duplicateOrdinal: Int

    public init(windowID: Int, index: Int, title: String, url: URL, isActive: Bool = false, duplicateOrdinal: Int = 0) {
        self.windowID = windowID
        self.index = index
        self.title = title
        self.url = url
        self.isActive = isActive
        self.duplicateOrdinal = duplicateOrdinal
    }

    /// Identity leaves out the tab position, so moving or closing other tabs does not reshuffle recency.
    public var id: String {
        "\(windowID):\(duplicateOrdinal):\(url.absoluteString)"
    }
}

public struct TabDisplayModel: Identifiable, Equatable {
    public let tab: SafariTab
    public let title: String
    /// Full URL, percent-decoded so non-ASCII paths read normally.
    public let urlText: String

    public var id: String { tab.id }

    public init(tab: SafariTab) {
        self.tab = tab

        let host = tab.url.host(percentEncoded: false) ?? tab.url.host ?? "Safari"
        let trimmedTitle = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)

        self.title = trimmedTitle.isEmpty ? host : trimmedTitle
        self.urlText = tab.url.absoluteString.removingPercentEncoding ?? tab.url.absoluteString
    }
}
