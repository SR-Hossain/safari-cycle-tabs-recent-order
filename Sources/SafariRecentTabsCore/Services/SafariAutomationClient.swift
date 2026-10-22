import AppKit
import Foundation

public protocol SafariControlling {
    func frontmostWindowTabs() throws -> [SafariTab]
    func frontmostActiveTab() throws -> SafariTab?
    func allWindowTabs() throws -> [SafariTab]
    func activate(tab: SafariTab) throws
    func close(tab: SafariTab) throws
}

public enum SafariAutomationError: Error, LocalizedError {
    case safariNotRunning
    case appleScriptError(String)
    case invalidResult

    public var errorDescription: String? {
        switch self {
        case .safariNotRunning:
            return "Safari is not running."
        case .appleScriptError(let message):
            return message
        case .invalidResult:
            return "Safari returned tab data in an unexpected format."
        }
    }
}

public final class AppleScriptSafariAutomationClient: SafariControlling {
    // Each `of every tab` read is one Apple event per window, instead of two per tab.
    private static let frontmostWindowTabsSource = """
    tell application "Safari"
        if (count of windows) is 0 then return {}
        set frontWindow to front window
        return {{id of frontWindow, name of every tab of frontWindow, URL of every tab of frontWindow}, index of current tab of frontWindow}
    end tell
    """

    private static let allWindowTabsSource = """
    tell application "Safari"
        if (count of windows) is 0 then return {}
        set windowData to {}
        repeat with safariWindow in windows
            try
                set end of windowData to {id of safariWindow, name of every tab of safariWindow, URL of every tab of safariWindow}
            end try
        end repeat
        return {windowData, index of current tab of front window, id of front window}
    end tell
    """

    private static let frontmostActiveTabSource = """
    tell application "Safari"
        if (count of windows) is 0 then return {}
        set frontWindow to front window
        set safariTab to current tab of frontWindow
        return {id of frontWindow, index of safariTab, name of safariTab, URL of safariTab}
    end tell
    """

    // Compiled once on first use; compiling on every keypress was part of the open delay.
    private lazy var frontmostWindowTabsScript = Self.compile(Self.frontmostWindowTabsSource)
    private lazy var allWindowTabsScript = Self.compile(Self.allWindowTabsSource)
    private lazy var frontmostActiveTabScript = Self.compile(Self.frontmostActiveTabSource)

    public init() {}

    public func frontmostWindowTabs() throws -> [SafariTab] {
        try ensureSafariRunning()
        let result = try run(frontmostWindowTabsScript)
        guard result.numberOfItems == 2,
              let window = result.atIndex(1),
              let activeIndex = result.atIndex(2)?.int32Value
        else {
            return []
        }
        return parseWindow(window, activeIndex: Int(activeIndex), isFrontWindow: true)
    }

    public func frontmostActiveTab() throws -> SafariTab? {
        try ensureSafariRunning()
        let result = try run(frontmostActiveTabScript)
        guard result.numberOfItems == 4,
              let windowID = result.atIndex(1)?.int32Value,
              let index = result.atIndex(2)?.int32Value
        else {
            return nil
        }
        return SafariTab(
            windowID: Int(windowID),
            index: Int(index),
            title: result.atIndex(3)?.stringValue ?? "",
            url: Self.url(from: result.atIndex(4)),
            isActive: true
        )
    }

    public func allWindowTabs() throws -> [SafariTab] {
        try ensureSafariRunning()
        let result = try run(allWindowTabsScript)
        guard result.numberOfItems == 3,
              let windows = result.atIndex(1),
              let activeIndex = result.atIndex(2)?.int32Value,
              let frontWindowID = result.atIndex(3)?.int32Value
        else {
            return []
        }

        var tabs: [SafariTab] = []
        for windowIndex in stride(from: 1, through: windows.numberOfItems, by: 1) {
            guard let window = windows.atIndex(windowIndex) else {
                continue
            }
            let isFrontWindow = window.atIndex(1)?.int32Value == frontWindowID
            tabs += parseWindow(window, activeIndex: Int(activeIndex), isFrontWindow: isFrontWindow)
        }
        return tabs
    }

    public func activate(tab: SafariTab) throws {
        let escapedURL = Self.escape(tab.url.absoluteString)
        // The tab list may come from a cache, so confirm the URL before trusting the index.
        let staleCheck = tab.url == Self.blankURL
            ? ""
            : "if URL of targetTab is not \"\(escapedURL)\" then error \"Stale tab index\""
        let script = """
        tell application "Safari"
            set targetWindow to first window whose id is \(tab.windowID)
            set targetTab to tab \(tab.index) of targetWindow
            \(staleCheck)
            set current tab of targetWindow to targetTab
            set index of targetWindow to 1
            activate
        end tell
        """

        do {
            try run(source: script)
        } catch {
            let fallbackScript = """
            tell application "Safari"
                repeat with safariWindow in windows
                    repeat with safariTab in tabs of safariWindow
                        if URL of safariTab is "\(escapedURL)" then
                            set current tab of safariWindow to safariTab
                            set index of safariWindow to 1
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
            try run(source: fallbackScript)
        }
    }

    public func close(tab: SafariTab) throws {
        let escapedURL = Self.escape(tab.url.absoluteString)
        let script = """
        tell application "Safari"
            set targetWindow to first window whose id is \(tab.windowID)
            close tab \(tab.index) of targetWindow
        end tell
        """

        do {
            try run(source: script)
        } catch {
            let fallbackScript = """
            tell application "Safari"
                repeat with safariWindow in windows
                    repeat with safariTab in tabs of safariWindow
                        if URL of safariTab is "\(escapedURL)" then
                            close safariTab
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """
            try run(source: fallbackScript)
        }
    }

    /// Parses `{windowID, {names}, {urls}}` into tabs.
    private func parseWindow(_ window: NSAppleEventDescriptor, activeIndex: Int, isFrontWindow: Bool) -> [SafariTab] {
        guard window.numberOfItems == 3,
              let windowID = window.atIndex(1)?.int32Value,
              let names = window.atIndex(2),
              let urls = window.atIndex(3)
        else {
            return []
        }

        let count = min(names.numberOfItems, urls.numberOfItems)
        guard count > 0 else {
            return []
        }

        return (1...count).map { index in
            SafariTab(
                windowID: Int(windowID),
                index: index,
                title: names.atIndex(index)?.stringValue ?? "",
                url: Self.url(from: urls.atIndex(index)),
                isActive: isFrontWindow && index == activeIndex
            )
        }
    }

    private func ensureSafariRunning() throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty == false else {
            throw SafariAutomationError.safariNotRunning
        }
    }

    private static let blankURL = URL(string: "about:blank")!

    private static func compile(_ source: String) -> NSAppleScript? {
        let script = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        script?.compileAndReturnError(&errorInfo)
        return script
    }

    /// Blank tabs report `missing value` for their URL.
    private static func url(from descriptor: NSAppleEventDescriptor?) -> URL {
        descriptor?.stringValue.flatMap(URL.init(string:)) ?? blankURL
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    @discardableResult
    private func run(source: String) throws -> NSAppleEventDescriptor {
        try run(NSAppleScript(source: source))
    }

    @discardableResult
    private func run(_ script: NSAppleScript?) throws -> NSAppleEventDescriptor {
        guard let script else {
            throw SafariAutomationError.invalidResult
        }

        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error."
            throw SafariAutomationError.appleScriptError(message)
        }

        return descriptor
    }
}
