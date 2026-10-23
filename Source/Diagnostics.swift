import AppKit
import ApplicationServices

/// Opt-in developer tracing. Never records text, window titles, or captured images.
enum Diagnostics {
    static let enabled = CommandLine.arguments.contains("--trace")
    static func log(_ message: String) {
        guard enabled else { return }
        let line = "[WindowHop \(Date().timeIntervalSince1970)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Explicit, read-only inventory for diagnosing third-party window lists.
    /// Titles are used only for matching and are never included in the report.
    static func windowInventory(bundleIdentifier: String) -> [String: Any] {
        let deadline = Date().addingTimeInterval(2)
        let descriptions = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }
        var applicationReports: [[String: Any]] = []

        func value(_ element: AXUIElement, _ name: String) -> (CFTypeRef?, AXError) {
            var result: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &result)
            return (result, error)
        }
        func frameDictionary(_ frame: CGRect) -> [String: Double] {
            func number(_ value: CGFloat) -> Double { value.isFinite ? Double(value) : 0 }
            return ["x": number(frame.minX), "y": number(frame.minY),
                    "width": number(frame.width), "height": number(frame.height)]
        }
        func cgSummary(_ entry: [String: Any]) -> [String: Any] {
            var summary: [String: Any] = [
                "windowID": (entry[kCGWindowNumber as String] as? NSNumber).map { $0 as Any } ?? NSNull(),
                "layer": (entry[kCGWindowLayer as String] as? NSNumber).map { $0 as Any } ?? NSNull(),
                "onScreen": (entry[kCGWindowIsOnscreen as String] as? NSNumber).map { $0 as Any } ?? NSNull(),
                "alpha": (entry[kCGWindowAlpha as String] as? NSNumber).map { $0 as Any } ?? NSNull(),
                "titleEmpty": (entry[kCGWindowName as String] as? String ?? "").isEmpty
            ]
            if let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
               let frame = CGRect(dictionaryRepresentation: bounds) {
                summary["frame"] = frameDictionary(frame)
            }
            return summary
        }

        for app in applications.prefix(4) {
            guard Date() < deadline else { break }
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.12)
            let (windowsValue, windowsError) = value(application, kAXWindowsAttribute)
            let elements = windowsValue as? [AXUIElement] ?? []
            let (focused, focusedError) = value(application, kAXFocusedWindowAttribute)
            let cgWindows = descriptions.filter {
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier
            }
            var windowReports: [[String: Any]] = []
            for (index, element) in elements.prefix(120).enumerated() {
                guard Date() < deadline else { break }
                AXUIElementSetMessagingTimeout(element, 0.08)
                let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                             kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute,
                             kAXMainAttribute, "AXFullScreen"]
                var rawValues: CFArray?
                let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &rawValues)
                let values = error == .success ? rawValues as? [CFTypeRef] ?? [] : []
                let attributes = Dictionary(uniqueKeysWithValues: zip(names, values))
                let title = (attributes[kAXTitleAttribute] as? String ?? "")
                    .components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
                var point = CGPoint.zero, size = CGSize.zero
                var hasPosition = false, hasSize = false
                if let position = attributes[kAXPositionAttribute], CFGetTypeID(position) == AXValueGetTypeID() {
                    hasPosition = AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point)
                }
                if let sizeValue = attributes[kAXSizeAttribute], CFGetTypeID(sizeValue) == AXValueGetTypeID() {
                    hasSize = AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size)
                }
                let frame = CGRect(origin: point, size: size)
                let match = hasPosition && hasSize
                    ? WindowCatalog.match(pid: app.processIdentifier, title: title, frame: frame, descriptions: cgWindows)
                    : nil
                let backing = match ?? (hasPosition && hasSize
                    ? WindowCatalog.match(pid: app.processIdentifier, title: title, frame: frame,
                                          descriptions: cgWindows, normalLayerOnly: false) : nil)
                var report: [String: Any] = [
                    "index": index, "axHash": CFHash(element), "attributesError": error.rawValue,
                    "role": attributes[kAXRoleAttribute] as? String ?? "unavailable",
                    "subrole": attributes[kAXSubroleAttribute] as? String ?? "unavailable",
                    "titleEmpty": title.isEmpty, "titleLength": title.count,
                    "hasPosition": hasPosition, "hasSize": hasSize,
                    "frame": frameDictionary(frame),
                    "minimized": attributes[kAXMinimizedAttribute] as? Bool ?? false,
                    "main": attributes[kAXMainAttribute] as? Bool ?? false,
                    "fullscreen": attributes["AXFullScreen"] as? Bool ?? false,
                    "focused": focused.map { CFEqual($0, element) } ?? false
                ]
                if let duplicate = elements.prefix(index).firstIndex(where: { CFEqual($0, element) }) {
                    report["equalToEarlierIndex"] = duplicate
                }
                if let match { report["matchedCGWindow"] = cgSummary(match.entry) }
                if let backing { report["backingCGWindow"] = cgSummary(backing.entry) }
                report["admittedByType"] = WindowCatalog.isCandidateWindow(
                    role: attributes[kAXRoleAttribute] as? String,
                    subrole: attributes[kAXSubroleAttribute] as? String, title: title,
                    isMain: attributes[kAXMainAttribute] as? Bool ?? false,
                    isMinimized: attributes[kAXMinimizedAttribute] as? Bool ?? false,
                    isHidden: app.isHidden, isFullscreen: attributes["AXFullScreen"] as? Bool ?? false,
                    backingLayer: (backing?.entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                    backingAlpha: (backing?.entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue)
                windowReports.append(report)
            }
            applicationReports.append([
                "pid": app.processIdentifier, "hidden": app.isHidden,
                "windowsReadError": windowsError.rawValue, "focusedReadError": focusedError.rawValue,
                "axWindowCount": elements.count, "axWindows": windowReports,
                "cgWindows": cgWindows.map(cgSummary),
                "truncated": windowReports.count < elements.count
            ])
        }
        return ["bundleIdentifier": bundleIdentifier, "accessibility": AXIsProcessTrusted(),
                "runningApplicationCount": applications.count, "applications": applicationReports,
                "deadlineReached": Date() >= deadline]
    }
}
