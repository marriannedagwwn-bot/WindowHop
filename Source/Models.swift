import AppKit
import ApplicationServices

final class WindowRecord: Identifiable {
    let id: String
    let pid: pid_t
    let axElement: AXUIElement?
    let windowID: CGWindowID?
    let title: String
    let appName: String
    let bundleIdentifier: String
    let icon: NSImage?
    let frame: CGRect
    let isMinimized: Bool
    let isHidden: Bool
    let isFullscreen: Bool
    let isWindowless: Bool
    var thumbnail: NSImage?

    init(id: String, pid: pid_t, axElement: AXUIElement? = nil, windowID: CGWindowID? = nil,
         title: String, appName: String, bundleIdentifier: String = "", icon: NSImage? = nil,
         frame: CGRect = .zero, isMinimized: Bool = false, isHidden: Bool = false, isFullscreen: Bool = false,
         isWindowless: Bool = false, thumbnail: NSImage? = nil) {
        self.id = id; self.pid = pid; self.axElement = axElement; self.windowID = windowID
        self.title = title; self.appName = appName; self.bundleIdentifier = bundleIdentifier
        self.icon = icon; self.frame = frame; self.isMinimized = isMinimized
        self.isHidden = isHidden; self.isFullscreen = isFullscreen
        self.isWindowless = isWindowless; self.thumbnail = thumbnail
    }
}

final class AppPreferences {
    private let defaults: UserDefaults
    static let registeredValues: [String: Any] = [
        "includeMinimized": true, "includeHidden": true, "includeFullscreen": true,
        "currentSpaceOnly": false, "showThumbnails": true, "shortcutMode": "controlOption",
        "appearanceStyle": "thumbnails", "appearanceSize": "medium", "appearanceTheme": "system",
        "titleDisplay": "window", "titleTruncation": "tail", "mouseHoverEnabled": true,
        "showWindowControls": true, "releaseBehavior": "focus", "panelScreen": "active",
        "windowScope": "all", "screenFilter": "all", "sortOrder": "recent", "groupByApp": false,
        "minimizedAtEnd": false, "hiddenAtEnd": false, "includeWindowlessApps": false,
        "excludedBundleIDs": [String](), "startAtLogin": false, "showMenuBarIcon": true,
        "previewFocusedWindow": false, "displayDelay": 100
    ]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Self.registeredValues)
    }
    private func value(_ key: String, _ allowed: [String]) -> String {
        let value = defaults.string(forKey: key) ?? ""
        return allowed.contains(value) ? value : Self.registeredValues[key] as! String
    }
    var includeMinimized: Bool { get { defaults.bool(forKey: "includeMinimized") } set { defaults.set(newValue, forKey: "includeMinimized") } }
    var includeHidden: Bool { get { defaults.bool(forKey: "includeHidden") } set { defaults.set(newValue, forKey: "includeHidden") } }
    var currentSpaceOnly: Bool { get { defaults.bool(forKey: "currentSpaceOnly") } set { defaults.set(newValue, forKey: "currentSpaceOnly") } }
    var showThumbnails: Bool { get { defaults.bool(forKey: "showThumbnails") } set { defaults.set(newValue, forKey: "showThumbnails") } }
    var shortcutMode: String { get { value("shortcutMode", ["controlOption", "option", "command"]) } set { defaults.set(newValue, forKey: "shortcutMode") } }
    var shortcutLabel: String { shortcutMode == "command" ? "⌘ Tab" : (shortcutMode == "option" ? "⌥ Tab" : "⌃ ⌥ Tab") }
    var appearanceStyle: String { get { value("appearanceStyle", ["thumbnails", "icons", "titles"]) } set { defaults.set(newValue, forKey: "appearanceStyle") } }
    var appearanceSize: String { get { value("appearanceSize", ["small", "medium", "large", "auto"]) } set { defaults.set(newValue, forKey: "appearanceSize") } }
    var appearanceTheme: String { get { value("appearanceTheme", ["system", "light", "dark"]) } set { defaults.set(newValue, forKey: "appearanceTheme") } }
    var titleDisplay: String { get { value("titleDisplay", ["window", "app", "both"]) } set { defaults.set(newValue, forKey: "titleDisplay") } }
    var titleTruncation: String { get { value("titleTruncation", ["head", "middle", "tail"]) } set { defaults.set(newValue, forKey: "titleTruncation") } }
    var mouseHoverEnabled: Bool { get { defaults.bool(forKey: "mouseHoverEnabled") } set { defaults.set(newValue, forKey: "mouseHoverEnabled") } }
    var showWindowControls: Bool { get { defaults.bool(forKey: "showWindowControls") } set { defaults.set(newValue, forKey: "showWindowControls") } }
    var releaseBehavior: String { get { value("releaseBehavior", ["focus", "hold", "search"]) } set { defaults.set(newValue, forKey: "releaseBehavior") } }
    var panelScreen: String { get { value("panelScreen", ["active", "mouse", "main"]) } set { defaults.set(newValue, forKey: "panelScreen") } }
    var windowScope: String { get { value("windowScope", ["all", "currentApp", "otherApps"]) } set { defaults.set(newValue, forKey: "windowScope") } }
    var screenFilter: String { get { value("screenFilter", ["all", "current"]) } set { defaults.set(newValue, forKey: "screenFilter") } }
    var sortOrder: String { get { value("sortOrder", ["recent", "app", "title"]) } set { defaults.set(newValue, forKey: "sortOrder") } }
    var groupByApp: Bool { get { defaults.bool(forKey: "groupByApp") } set { defaults.set(newValue, forKey: "groupByApp") } }
    var minimizedAtEnd: Bool { get { defaults.bool(forKey: "minimizedAtEnd") } set { defaults.set(newValue, forKey: "minimizedAtEnd") } }
    var hiddenAtEnd: Bool { get { defaults.bool(forKey: "hiddenAtEnd") } set { defaults.set(newValue, forKey: "hiddenAtEnd") } }
    var includeFullscreen: Bool { get { defaults.bool(forKey: "includeFullscreen") } set { defaults.set(newValue, forKey: "includeFullscreen") } }
    var includeWindowlessApps: Bool { get { defaults.bool(forKey: "includeWindowlessApps") } set { defaults.set(newValue, forKey: "includeWindowlessApps") } }
    var excludedBundleIDs: [String] { get { defaults.stringArray(forKey: "excludedBundleIDs") ?? [] } set { defaults.set(newValue, forKey: "excludedBundleIDs") } }
    var startAtLogin: Bool { get { defaults.bool(forKey: "startAtLogin") } set { defaults.set(newValue, forKey: "startAtLogin") } }
    var showMenuBarIcon: Bool { get { defaults.bool(forKey: "showMenuBarIcon") } set { defaults.set(newValue, forKey: "showMenuBarIcon") } }
    var previewFocusedWindow: Bool { get { defaults.bool(forKey: "previewFocusedWindow") } set { defaults.set(newValue, forKey: "previewFocusedWindow") } }
    var displayDelay: Int { get { min(500, max(0, defaults.integer(forKey: "displayDelay"))) } set { defaults.set(min(500, max(0, newValue)), forKey: "displayDelay") } }

    func exportData() throws -> Data {
        let settings = Self.registeredValues.mapValues { $0 }
            .map { ($0.key, defaults.object(forKey: $0.key) ?? $0.value) }
        return try JSONSerialization.data(withJSONObject: ["format": "WindowHop", "version": 1,
            "settings": Dictionary(uniqueKeysWithValues: settings)], options: [.prettyPrinted, .sortedKeys])
    }
    func importData(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["format"] as? String == "WindowHop", object["version"] as? Int == 1,
              let settings = object["settings"] as? [String: Any] else {
            throw NSError(domain: "WindowHop.Settings", code: 1, userInfo: [NSLocalizedDescriptionKey: "这不是有效的跃窗设置文件。"])
        }
        for (key, fallback) in Self.registeredValues {
            guard let incoming = settings[key] else { continue }
            if fallback is String, let string = incoming as? String { defaults.set(string, forKey: key) }
            else if fallback is Bool, let number = incoming as? NSNumber,
                    CFGetTypeID(number) == CFBooleanGetTypeID() { defaults.set(number.boolValue, forKey: key) }
            else if fallback is Int, let number = incoming as? NSNumber,
                    CFGetTypeID(number) != CFBooleanGetTypeID() { defaults.set(number.intValue, forKey: key) }
            else if fallback is [String], let strings = incoming as? [String] { defaults.set(strings, forKey: key) }
        }
    }
}

enum AppPermissions {
    static var accessibility: Bool { AXIsProcessTrusted() }
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacy("Privacy_Accessibility")
    }
    static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        openPrivacy("Privacy_ScreenCapture")
    }
    static func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor) {
            NSWorkspace.shared.open(url)
        }
    }
}

enum SelectionMath {
    static func moved(_ selected: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((selected + delta) % count + count) % count
    }
}
