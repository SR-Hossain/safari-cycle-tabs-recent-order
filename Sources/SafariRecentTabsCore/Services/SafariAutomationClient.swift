import AppKit
import Carbon
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

    // Three Apple events no matter how many windows: ids, names, and URLs for every window at once.
    private static let allWindowTabsBulkSource = """
    tell application "Safari"
        if (count of windows) is 0 then return {}
        return {id of every window, name of every tab of every window, URL of every tab of every window, index of current tab of front window, id of front window}
    end tell
    """

    // Per-window fallback for when a tabless window (e.g. Settings) makes the bulk read fail.
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

    // The tab list may come from a cache, so each handler checks the URL at the index first,
    // then falls back to one `whose URL is` lookup per window instead of walking every tab.
    private static let tabActionsSource = """
    on activatetab(windowID, tabIndex, expectedURL)
        tell application "Safari"
            try
                set targetWindow to first window whose id is windowID
                set targetTab to tab tabIndex of targetWindow
                if expectedURL is "" or URL of targetTab is expectedURL then
                    set current tab of targetWindow to targetTab
                    set index of targetWindow to 1
                    return true
                end if
            end try
            repeat with safariWindow in windows
                try
                    set matches to (tabs of safariWindow whose URL is expectedURL)
                    if matches is not {} then
                        set current tab of safariWindow to item 1 of matches
                        set index of safariWindow to 1
                        return true
                    end if
                end try
            end repeat
            return false
        end tell
    end activatetab

    on closetab(windowID, tabIndex, expectedURL)
        tell application "Safari"
            try
                set targetWindow to first window whose id is windowID
                set targetTab to tab tabIndex of targetWindow
                if expectedURL is "" or URL of targetTab is expectedURL then
                    close targetTab
                    return true
                end if
            end try
            repeat with safariWindow in windows
                try
                    set matches to (tabs of safariWindow whose URL is expectedURL)
                    if matches is not {} then
                        close item 1 of matches
                        return true
                    end if
                end try
            end repeat
            return false
        end tell
    end closetab
    """

    // Compiled once on first use; compiling on every keypress was part of the open delay.
    private lazy var frontmostWindowTabsScript = Self.compile(Self.frontmostWindowTabsSource)
    private lazy var allWindowTabsBulkScript = Self.compile(Self.allWindowTabsBulkSource)
    private lazy var allWindowTabsScript = Self.compile(Self.allWindowTabsSource)
    private lazy var frontmostActiveTabScript = Self.compile(Self.frontmostActiveTabSource)
    private lazy var tabActionsScript = Self.compile(Self.tabActionsSource)

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
        if let result = try? run(allWindowTabsBulkScript) {
            return parseBulkWindows(result)
        }
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
        guard try callTabAction("activatetab", tab: tab) else {
            throw SafariAutomationError.appleScriptError("Tab not found.")
        }
    }

    public func close(tab: SafariTab) throws {
        guard try callTabAction("closetab", tab: tab) else {
            throw SafariAutomationError.appleScriptError("Tab not found.")
        }
    }

    /// Calls a handler in the precompiled tab-actions script with `{windowID, tabIndex, expectedURL}`.
    private func callTabAction(_ handler: String, tab: SafariTab) throws -> Bool {
        guard let script = tabActionsScript else {
            throw SafariAutomationError.invalidResult
        }

        let parameters = NSAppleEventDescriptor.list()
        parameters.insert(NSAppleEventDescriptor(int32: Int32(tab.windowID)), at: 1)
        parameters.insert(NSAppleEventDescriptor(int32: Int32(tab.index)), at: 2)
        // Blank tabs have no URL to check against, so an empty string skips the check.
        parameters.insert(NSAppleEventDescriptor(string: tab.url == Self.blankURL ? "" : tab.url.absoluteString), at: 3)

        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: .currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
        event.setParam(parameters, forKeyword: AEKeyword(keyDirectObject))

        var errorInfo: NSDictionary?
        let result = script.executeAppleEvent(event, error: &errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error."
            throw SafariAutomationError.appleScriptError(message)
        }
        return result.booleanValue
    }

    /// Parses `{{windowIDs}, {{names}}, {{urls}}, activeIndex, frontWindowID}` into tabs.
    private func parseBulkWindows(_ result: NSAppleEventDescriptor) -> [SafariTab] {
        guard result.numberOfItems == 5,
              let windowIDs = result.atIndex(1),
              let names = result.atIndex(2),
              let urls = result.atIndex(3),
              let activeIndex = result.atIndex(4)?.int32Value,
              let frontWindowID = result.atIndex(5)?.int32Value
        else {
            return []
        }

        var tabs: [SafariTab] = []
        for windowIndex in stride(from: 1, through: windowIDs.numberOfItems, by: 1) {
            guard let windowID = windowIDs.atIndex(windowIndex)?.int32Value,
                  let windowNames = names.atIndex(windowIndex),
                  let windowURLs = urls.atIndex(windowIndex)
            else {
                continue
            }
            let window = NSAppleEventDescriptor.list()
            window.insert(NSAppleEventDescriptor(int32: windowID), at: 1)
            window.insert(windowNames, at: 2)
            window.insert(windowURLs, at: 3)
            tabs += parseWindow(window, activeIndex: Int(activeIndex), isFrontWindow: windowID == frontWindowID)
        }
        return tabs
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

        var seenURLs: [URL: Int] = [:]
        return (1...count).map { index in
            let url = Self.url(from: urls.atIndex(index))
            let ordinal = seenURLs[url, default: 0]
            seenURLs[url] = ordinal + 1
            return SafariTab(
                windowID: Int(windowID),
                index: index,
                title: names.atIndex(index)?.stringValue ?? "",
                url: url,
                isActive: isFrontWindow && index == activeIndex,
                duplicateOrdinal: ordinal
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
