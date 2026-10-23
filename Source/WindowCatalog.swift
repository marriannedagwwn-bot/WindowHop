import AppKit
import ApplicationServices
import ScreenCaptureKit

func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

final class WindowCatalog {
    private let queue = DispatchQueue(label: "local.windowhop.catalog", qos: .userInitiated)
    private var recent: [String: TimeInterval] = [:]
    private var lastExternalPID: pid_t?
    private var focusGeneration = 0
    private let requestLock = NSLock()
    private var requestID = 0
    func cancelPending() { requestLock.lock(); requestID += 1; requestLock.unlock() }
    private func currentRequest() -> Int { requestLock.lock(); defer { requestLock.unlock() }; return requestID }
    private func currentFocusGeneration() -> Int { requestLock.lock(); defer { requestLock.unlock() }; return focusGeneration }
    private func nextFocusGeneration() -> Int { requestLock.lock(); defer { requestLock.unlock() }; focusGeneration += 1; return focusGeneration }
    private func identity(pid: pid_t, element: AXUIElement) -> String { "\(pid)-\(CFHash(element))" }
    /// Synchronously invalidates an older intent before any queued activation or raise can begin.
    func cancelFocus() { _ = nextFocusGeneration() }

    func noteFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
        queue.async { [self] in
            lastExternalPID = app.processIdentifier
            let application = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.15)
            if let focused = axValue(application, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
                let element = unsafeBitCast(focused, to: AXUIElement.self)
                recent[identity(pid: app.processIdentifier, element: element)] = Date().timeIntervalSince1970
            }
        }
    }

    func load(preferences: AppPreferences, targetScreenFrame: CGRect? = nil, currentAppPID: pid_t? = nil,
              scopeOverride: String? = nil,
              completion: @escaping ([WindowRecord]) -> Void) {
        cancelPending()
        let request = currentRequest()
        let includeMinimized = preferences.includeMinimized
        let includeHidden = preferences.includeHidden
        let currentSpaceOnly = preferences.currentSpaceOnly
        let includeFullscreen = preferences.includeFullscreen
        let includeWindowlessApps = preferences.includeWindowlessApps
        let windowScope = scopeOverride ?? preferences.windowScope
        let screenFilter = preferences.screenFilter
        let sortOrder = preferences.sortOrder
        let groupByApp = preferences.groupByApp
        let minimizedAtEnd = preferences.minimizedAtEnd
        let hiddenAtEnd = preferences.hiddenAtEnd
        let excluded = Set(preferences.excludedBundleIDs)
        let screenFrame = targetScreenFrame ?? Self.screenUnderPointerInQuartzCoordinates()
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !$0.isTerminated
                && !excluded.contains($0.bundleIdentifier ?? "")
        }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        queue.async { [self] in
            guard request == currentRequest() else { return }
            let targetPID = currentAppPID ?? (frontPID == getpid() ? lastExternalPID : frontPID)
            if let targetPID { lastExternalPID = targetPID }
            let deadline = Date().addingTimeInterval(2)
            let descriptions = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let visible = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let visibleIDs = Set(visible.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
            var records: [WindowRecord] = []
            var rank: [String: Int] = [:]
            // Visit the front and visually recent applications first if a slow AX server exhausts the budget.
            let orderedApps = applications.sorted { lhs, rhs in
                if (lhs.processIdentifier == targetPID) != (rhs.processIdentifier == targetPID) { return lhs.processIdentifier == targetPID }
                let left = descriptions.firstIndex { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == lhs.processIdentifier } ?? Int.max
                let right = descriptions.firstIndex { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == rhs.processIdentifier } ?? Int.max
                return left == right ? lhs.processIdentifier < rhs.processIdentifier : left < right
            }
            for app in orderedApps {
                guard request == currentRequest() else { return }
                if Date() > deadline { break }
                if !includeHidden && app.isHidden { continue }
                if windowScope == "currentApp" && app.processIdentifier != targetPID { continue }
                if windowScope == "otherApps" && app.processIdentifier == targetPID { continue }
                let application = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(application, 0.08)
                guard let elements = axValue(application, kAXWindowsAttribute) as? [AXUIElement] else { continue }
                let focused = axValue(application, kAXFocusedWindowAttribute)
                if elements.isEmpty && includeWindowlessApps {
                    records.append(WindowRecord(id: "\(app.processIdentifier)-windowless", pid: app.processIdentifier,
                        title: app.localizedName ?? "应用", appName: app.localizedName ?? "应用",
                        bundleIdentifier: app.bundleIdentifier ?? "", icon: app.icon,
                        isHidden: app.isHidden, isWindowless: true))
                }
                for element in elements {
                    guard request == currentRequest() else { return }
                    if Date() > deadline { break }
                    AXUIElementSetMessagingTimeout(element, 0.08)
                    // One round trip per window instead of a separate blocking message for every property.
                    let values = Self.attributes(element, [kAXRoleAttribute, kAXSubroleAttribute,
                        kAXPositionAttribute, kAXSizeAttribute, kAXTitleAttribute, kAXMinimizedAttribute,
                        kAXMainAttribute, "AXFullScreen"])
                    let minimized = (values[kAXMinimizedAttribute] as? Bool) ?? false
                    if !includeMinimized && minimized { continue }
                    let fullscreen = (values["AXFullScreen"] as? Bool) ?? false
                    if !includeFullscreen && fullscreen { continue }
                    var point = CGPoint.zero
                    var size = CGSize.zero
                    if let value = values[kAXPositionAttribute], CFGetTypeID(value) == AXValueGetTypeID() {
                        AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &point)
                    }
                    if let value = values[kAXSizeAttribute], CFGetTypeID(value) == AXValueGetTypeID() {
                        AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size)
                    }
                    guard size.width >= 80 && size.height >= 50 else { continue }
                    let title = Self.singleLine((values[kAXTitleAttribute] as? String) ?? "")
                    let frame = CGRect(origin: point, size: size)
                    if screenFilter == "current", let screenFrame, !frame.intersects(screenFrame) { continue }
                    let match = Self.match(pid: app.processIdentifier, title: title, frame: frame, descriptions: descriptions)
                    // A helper may have a WindowServer surface at a non-document level.
                    // Looking only for level zero and accepting nil used to admit these surfaces.
                    let backing = match ?? Self.match(pid: app.processIdentifier, title: title, frame: frame,
                                                      descriptions: descriptions, normalLayerOnly: false)
                    guard Self.isCandidateWindow(role: values[kAXRoleAttribute] as? String,
                        subrole: values[kAXSubroleAttribute] as? String, title: title,
                        isMain: values[kAXMainAttribute] as? Bool ?? false, isMinimized: minimized,
                        isHidden: app.isHidden, isFullscreen: fullscreen,
                        backingLayer: (backing?.entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
                        backingAlpha: (backing?.entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue) else { continue }
                    let windowID = match.flatMap { ($0.entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
                    if currentSpaceOnly && (windowID == nil || !visibleIDs.contains(windowID!)) { continue }
                    let id = identity(pid: app.processIdentifier, element: element)
                    if app.processIdentifier == targetPID, let focused, CFEqual(focused, element) {
                        recent[id] = Date().timeIntervalSince1970
                    }
                    let record = WindowRecord(id: id, pid: app.processIdentifier, axElement: element,
                        windowID: windowID, title: title.isEmpty ? (app.localizedName ?? "未命名窗口") : title,
                        appName: app.localizedName ?? "应用", bundleIdentifier: app.bundleIdentifier ?? "",
                        icon: app.icon, frame: frame, isMinimized: minimized, isHidden: app.isHidden, isFullscreen: fullscreen)
                    rank[id] = match?.index ?? Int.max
                    records.append(record)
                }
            }
            let activeIDs = Set(records.map(\.id))
            // A preference-filtered window may return on the next invocation; keep its MRU evidence.
            if recent.count > 2048 { recent = recent.filter { activeIDs.contains($0.key) } }
            records = Self.ordered(Self.deduplicated(records), sortOrder: sortOrder, groupByApp: groupByApp,
                minimizedAtEnd: minimizedAtEnd, hiddenAtEnd: hiddenAtEnd, recent: recent, ranks: rank)
            guard request == currentRequest() else { return }
            DispatchQueue.main.async { completion(records) }
        }
    }

    static func isCandidateWindow(role: String?, subrole: String?, title: String,
                                  isMain: Bool, isMinimized: Bool, isHidden: Bool, isFullscreen: Bool,
                                  backingLayer: Int?, backingAlpha: Double?) -> Bool {
        guard role == kAXWindowRole, subrole != kAXFloatingWindowSubrole else { return false }
        if let layer = backingLayer, layer != 0, !isMain, !isFullscreen { return false }
        // Minimized and hidden applications can legitimately have transparent/offscreen surfaces.
        if let alpha = backingAlpha, alpha <= 0, !isMinimized, !isHidden, !isFullscreen { return false }
        if subrole == kAXUnknownSubrole, title.isEmpty, !isMain, !isMinimized, !isHidden, !isFullscreen {
            return false
        }
        return true
    }

    static func deduplicated(_ windows: [WindowRecord]) -> [WindowRecord] {
        var references = Set<String>()
        var surfaces = Set<String>()
        return windows.filter { window in
            guard references.insert("\(window.pid):\(window.id)").inserted else { return false }
            guard let surface = window.windowID, surface != kCGNullWindowID else { return true }
            return surfaces.insert("\(window.pid):\(surface)").inserted
        }
    }

    static func ordered(_ windows: [WindowRecord], sortOrder: String, groupByApp: Bool,
                        minimizedAtEnd: Bool, hiddenAtEnd: Bool,
                        recent: [String: TimeInterval] = [:], ranks: [String: Int] = [:]) -> [WindowRecord] {
        func byRecency(_ lhs: WindowRecord, _ rhs: WindowRecord) -> Bool {
            let left = recent[lhs.id] ?? 0, right = recent[rhs.id] ?? 0
            if left != right { return left > right }
            let leftRank = ranks[lhs.id] ?? Int.max, rightRank = ranks[rhs.id] ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            return lhs.id < rhs.id
        }
        var result = windows.sorted(by: byRecency)
        if groupByApp {
            var included = Set<pid_t>()
            result = result.filter { included.insert($0.pid).inserted }
        }
        return result.sorted { lhs, rhs in
            if lhs.isWindowless != rhs.isWindowless { return !lhs.isWindowless }
            if minimizedAtEnd && lhs.isMinimized != rhs.isMinimized { return !lhs.isMinimized }
            if hiddenAtEnd && lhs.isHidden != rhs.isHidden { return !lhs.isHidden }
            if sortOrder == "app" {
                let comparison = lhs.appName.localizedStandardCompare(rhs.appName)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            if sortOrder == "title" || (sortOrder == "app" && lhs.appName == rhs.appName) {
                let comparison = lhs.title.localizedStandardCompare(rhs.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            return byRecency(lhs, rhs)
        }
    }

    private static func attributes(_ element: AXUIElement, _ names: [String]) -> [String: CFTypeRef] {
        var result: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &result) == .success,
              let values = result as? [CFTypeRef] else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(names, values))
    }

    private static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func screenUnderPointerInQuartzCoordinates() -> CGRect? {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return nil }
        let screen = screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main ?? primary
        return CGRect(x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY,
                      width: screen.frame.width, height: screen.frame.height)
    }

    // Public AX does not expose a CGWindowID. Reject ambiguous matches instead of showing a different window's contents.
    static func match(pid: pid_t, title: String, frame: CGRect, descriptions: [[String: Any]],
                      normalLayerOnly: Bool = true) -> (index: Int, entry: [String: Any])? {
        var candidates: [(Int, [String: Any], CGFloat)] = []
        for (index, entry) in descriptions.enumerated() {
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (!normalLayerOnly || (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0),
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
            let distance = abs(rect.minX-frame.minX) + abs(rect.minY-frame.minY) + abs(rect.width-frame.width) + abs(rect.height-frame.height)
            guard distance < 24 else { continue }
            let cgTitle = Self.singleLine(entry[kCGWindowName as String] as? String ?? "")
            let score = distance + ((!title.isEmpty && !cgTitle.isEmpty && cgTitle != title) ? 1000 : 0)
            candidates.append((index, entry, score))
        }
        candidates.sort { $0.2 < $1.2 }
        guard let first = candidates.first, first.2 < 24 else { return nil }
        if candidates.count > 1 && abs(candidates[1].2-first.2) < 2 { return nil }
        return (first.0, first.1)
    }

    private final class FocusOperation {
        let generation: Int
        let window: WindowRecord
        let app: NSRunningApplication
        var application: AXUIElement
        let started = Date()
        var deadline: Date { started.addingTimeInterval(wasMinimized ? 4 : 1.5) }
        var elapsed: TimeInterval { Date().timeIntervalSince(started) }
        let completion: (Bool) -> Void
        var target: AXUIElement?
        var wasMinimized = false
        var finished = false
        var phase = "start"
        var lastRestoreSignature: String?
        var lastVerificationSignature: String?
        var lastReferenceSignature: String?
        var referenceAttempts = 0
        var restoreRequested = false
        var canonicalAfterRestore = false
        var didActivate = false
        var didRaise = false

        init(_ generation: Int, _ window: WindowRecord, _ app: NSRunningApplication,
             completion: @escaping (Bool) -> Void) {
            self.generation = generation; self.window = window; self.app = app
            self.completion = completion
            application = AXUIElementCreateApplication(window.pid)
            target = window.axElement
            // Messaging timeouts belong to each individual AX reference, even
            // when another reference compares equal. Inventory keeps its 80 ms
            // budget; a committed focus gets a separate, more patient timeout.
            AXUIElementSetMessagingTimeout(application, 0.3)
            if let target { AXUIElementSetMessagingTimeout(target, 0.3) }
        }
    }

    func focus(_ window: WindowRecord, completion: @escaping (Bool) -> Void) {
        // Allocate before enqueueing: a later cancel must also invalidate a request still waiting
        // behind an AX inventory operation, rather than letting that request create a newer token.
        let generation = nextFocusGeneration()
        queue.async { [self] in
            guard generation == currentFocusGeneration(),
                  let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated else {
                DispatchQueue.main.async { completion(false) }; return
            }
            let operation = FocusOperation(generation, window, app, completion: completion)
            Diagnostics.log("focus.phase name=start elapsed=\(operation.elapsed)")
            if window.isWindowless {
                activate(operation)
                return
            }
            guard let target = operation.target else { finish(operation, false); return }
            let minimizedRead = Self.focusAttribute(target, kAXMinimizedAttribute)
            operation.wasMinimized = (minimizedRead.value as? Bool) ?? window.isMinimized
            Diagnostics.log("focus.restore.read error=\(minimizedRead.error.rawValue) minimized=\(Self.traceBoolean(minimizedRead.value as? Bool)) restoreNeeded=\(operation.wasMinimized) elapsed=\(operation.elapsed)")
            guard mayProceed(operation) else { return }
            if operation.wasMinimized {
                requestRestore(operation)
            } else {
                waitForRestore(operation)
            }
        }
    }

    private func mayProceed(_ operation: FocusOperation) -> Bool {
        guard !operation.finished else { return false }
        guard operation.generation == currentFocusGeneration() else { finish(operation, false, reason: "superseded"); return false }
        guard Date() < operation.deadline else { finish(operation, false, reason: "deadline"); return false }
        guard !operation.app.isTerminated else { finish(operation, false, reason: "terminated"); return false }
        return true
    }

    private func phase(_ operation: FocusOperation, _ name: String) {
        guard operation.phase != name else { return }
        operation.phase = name
        Diagnostics.log("focus.phase name=\(name) elapsed=\(operation.elapsed)")
    }

    private static func focusAttribute(_ element: AXUIElement, _ attribute: String) -> (error: AXError, value: CFTypeRef?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error, error == .success ? value : nil)
    }

    private static func traceBoolean(_ value: Bool?) -> String {
        value.map(String.init) ?? "unknown"
    }

    private func requestRestore(_ operation: FocusOperation) {
        guard mayProceed(operation), let target = operation.target else { return }
        guard !operation.restoreRequested else { scheduleReferenceRefresh(operation, reason: "restorePending"); return }
        operation.wasMinimized = true
        operation.restoreRequested = true
        phase(operation, "restore")
        let result = AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        Diagnostics.log("focus.restore.set error=\(result.rawValue) elapsed=\(operation.elapsed)")
        guard mayProceed(operation) else { return }
        // CannotComplete can mean that the app applied an action but has not
        // replied in time. Observe fresh state instead of repeating the action.
        guard result == .success || result == .cannotComplete else { finish(operation, false, reason: "restoreRejected"); return }
        scheduleReferenceRefresh(operation, reason: "afterRestore")
    }

    private func scheduleReferenceRefresh(_ operation: FocusOperation, reason: String) {
        guard mayProceed(operation) else { return }
        let delays: [TimeInterval] = [0.15, 0.22, 0.32, 0.4]
        let delay = delays[min(operation.referenceAttempts, delays.count - 1)]
        queue.asyncAfter(deadline: .now() + delay) {
            self.refreshFocusReferences(operation, reason: reason)
        }
    }

    /// Re-enter the AX server through a freshly created application reference
    /// and its canonical AXWindows elements. A successful geometric resolution
    /// selects a reference only; success still requires focused-window equality.
    private func refreshFocusReferences(_ operation: FocusOperation, reason: String) {
        guard mayProceed(operation) else { return }
        phase(operation, "refreshReferences")
        operation.referenceAttempts += 1
        let freshApplication = AXUIElementCreateApplication(operation.window.pid)
        AXUIElementSetMessagingTimeout(freshApplication, 0.3)
        let read = Self.focusAttribute(freshApplication, kAXWindowsAttribute)
        guard mayProceed(operation) else { return }
        let elements = read.value as? [AXUIElement] ?? []
        var target: AXUIElement?
        var method = "none"
        if read.error == .success {
            if let original = operation.window.axElement,
               let same = elements.first(where: { CFEqual($0, original) }) {
                target = same; method = "originalEquality"
            } else {
                var candidates: [AXUIElement] = []
                for element in elements {
                    guard mayProceed(operation) else { return }
                    AXUIElementSetMessagingTimeout(element, 0.3)
                    let values = Self.attributes(element, [kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute])
                    guard mayProceed(operation) else { return }
                    let title = Self.singleLine(values[kAXTitleAttribute] as? String ?? "")
                    guard !title.isEmpty, title == operation.window.title,
                          let position = values[kAXPositionAttribute], CFGetTypeID(position) == AXValueGetTypeID(),
                          let sizeValue = values[kAXSizeAttribute], CFGetTypeID(sizeValue) == AXValueGetTypeID() else { continue }
                    var point = CGPoint.zero, size = CGSize.zero
                    AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point)
                    AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size)
                    let distance = abs(point.x - operation.window.frame.minX) + abs(point.y - operation.window.frame.minY)
                        + abs(size.width - operation.window.frame.width) + abs(size.height - operation.window.frame.height)
                    if distance < 12 { candidates.append(element) }
                }
                if candidates.count == 1 { target = candidates[0]; method = "uniqueTitleGeometry" }
                else if candidates.count > 1 { method = "ambiguous" }
            }
        }
        let signature = "reason=\(reason) windowsReadError=\(read.error.rawValue) found=\(target != nil) method=\(method)"
        if operation.lastReferenceSignature != signature {
            operation.lastReferenceSignature = signature
            Diagnostics.log("focus.references \(signature) elapsed=\(operation.elapsed)")
        }
        guard mayProceed(operation) else { return }
        guard let target else { scheduleReferenceRefresh(operation, reason: reason); return }
        AXUIElementSetMessagingTimeout(target, 0.3)
        operation.application = freshApplication
        operation.target = target
        if operation.restoreRequested { operation.canonicalAfterRestore = true }
        waitForRestore(operation)
    }

    private func waitForRestore(_ operation: FocusOperation) {
        guard mayProceed(operation), let target = operation.target else { return }
        phase(operation, "waitRestore")
        let read = Self.focusAttribute(target, kAXMinimizedAttribute)
        let minimized = read.value as? Bool
        let signature = "error=\(read.error.rawValue) minimized=\(Self.traceBoolean(minimized))"
        if operation.lastRestoreSignature != signature {
            operation.lastRestoreSignature = signature
            Diagnostics.log("focus.restore.wait \(signature) elapsed=\(operation.elapsed)")
        }
        guard read.error == .success, let minimized else {
            scheduleReferenceRefresh(operation, reason: "minimizedUnknown")
            return
        }
        if minimized {
            if operation.restoreRequested { scheduleReferenceRefresh(operation, reason: "stillMinimized") }
            else { requestRestore(operation) }
            return
        }
        if operation.wasMinimized && !operation.canonicalAfterRestore {
            scheduleReferenceRefresh(operation, reason: "confirmCanonicalRestore")
            return
        }
        if operation.didActivate {
            verifyFocus(operation)
        } else {
            // A known false from a canonical post-restore element is required;
            // an AX messaging error never counts as a restored window.
            queue.asyncAfter(deadline: .now() + (operation.wasMinimized ? 0.12 : 0)) {
                self.activate(operation)
            }
        }
    }

    private func activate(_ operation: FocusOperation) {
        guard mayProceed(operation) else { return }
        guard !operation.didActivate else { verifyFocus(operation); return }
        operation.didActivate = true
        phase(operation, "activate")
        DispatchQueue.main.async {
            guard operation.generation == self.currentFocusGeneration(), Date() < operation.deadline else {
                self.queue.async { _ = self.mayProceed(operation) }; return
            }
            let unhideAccepted = operation.app.unhide()
            let callerActive = NSApp.isActive
            let targetAlreadyActive = operation.app.isActive
            if operation.window.isWindowless, let url = operation.app.bundleURL {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                Diagnostics.log("focus.activate callerActive=\(callerActive) targetActive=\(targetAlreadyActive) unhideAccepted=\(unhideAccepted) mode=workspace elapsed=\(operation.elapsed)")
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
            } else {
                let accepted: Bool
                if callerActive {
                    NSApp.yieldActivation(to: operation.app)
                    accepted = operation.app.activate(from: NSRunningApplication.current, options: [])
                } else {
                    accepted = operation.app.activate(options: [])
                }
                Diagnostics.log("focus.activate callerActive=\(callerActive) targetActive=\(targetAlreadyActive) unhideAccepted=\(unhideAccepted) cooperative=\(callerActive) requestAccepted=\(accepted) elapsed=\(operation.elapsed)")
            }
            self.queue.asyncAfter(deadline: .now() + 0.08) { self.raiseOnce(operation) }
        }
    }

    private func raiseOnce(_ operation: FocusOperation) {
        guard mayProceed(operation) else { return }
        guard !operation.didRaise else { verifyFocus(operation); return }
        operation.didRaise = true
        phase(operation, "raise")
        if let target = operation.target {
            // Public AX servers may reject one of these setters while accepting AXRaise; verify below.
            let mainResult = AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
            Diagnostics.log("focus.main.set error=\(mainResult.rawValue) elapsed=\(operation.elapsed)")
            guard mayProceed(operation) else { return }
            let focusedResult = AXUIElementSetAttributeValue(operation.application, kAXFocusedWindowAttribute as CFString, target)
            Diagnostics.log("focus.focusedWindow.set error=\(focusedResult.rawValue) elapsed=\(operation.elapsed)")
            guard mayProceed(operation) else { return }
            let raised = AXUIElementPerformAction(target, kAXRaiseAction as CFString)
            Diagnostics.log("focus.raise error=\(raised.rawValue) elapsed=\(operation.elapsed)")
            guard mayProceed(operation) else { return }
        }
        verifyFocus(operation)
    }

    private func verifyFocus(_ operation: FocusOperation) {
        guard mayProceed(operation) else { return }
        phase(operation, "verify")
        DispatchQueue.main.async {
            let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            self.queue.async {
                guard self.mayProceed(operation) else { return }
                let focusedRead = Self.focusAttribute(operation.application, kAXFocusedWindowAttribute)
                let focused = focusedRead.value
                let targetIsFocused = operation.target.map { target in focused.map { CFEqual($0, target) } == true } ?? operation.window.isWindowless
                let minimizedRead = operation.target.map { Self.focusAttribute($0, kAXMinimizedAttribute) }
                let minimizedValue = minimizedRead?.value as? Bool
                let knownRestored = operation.window.isWindowless ||
                    (minimizedRead?.error == .success && minimizedValue == false)
                let frontMatches = frontPID == operation.window.pid
                let signature = "frontMatch=\(frontMatches) focusedPresent=\(focused != nil) equal=\(targetIsFocused) focusedReadError=\(focusedRead.error.rawValue) minimized=\(Self.traceBoolean(minimizedValue)) minimizedReadError=\(minimizedRead?.error.rawValue ?? 0)"
                if operation.lastVerificationSignature != signature {
                    operation.lastVerificationSignature = signature
                    Diagnostics.log("focus.verify \(signature) elapsed=\(operation.elapsed)")
                }
                guard self.mayProceed(operation) else { return }
                if frontMatches && targetIsFocused && knownRestored {
                    self.finish(operation, true)
                } else if operation.target != nil && (focusedRead.error != .success || !knownRestored) {
                    // Refresh transport/element references only. Once activation
                    // and raise were requested, observation never reissues them.
                    self.scheduleReferenceRefresh(operation, reason: "verificationUnavailable")
                } else {
                    self.queue.asyncAfter(deadline: .now() + 0.08) { self.verifyFocus(operation) }
                }
            }
        }
    }

    private func finish(_ operation: FocusOperation, _ success: Bool, reason: String = "result") {
        guard !operation.finished else { return }
        operation.finished = true
        if success {
            recent[operation.window.id] = Date().timeIntervalSince1970
            lastExternalPID = operation.window.pid
        }
        Diagnostics.log("focus.result success=\(success) minimizedRestore=\(operation.wasMinimized) reason=\(reason) phase=\(operation.phase) elapsed=\(operation.elapsed)")
        DispatchQueue.main.async { operation.completion(success) }
    }

    /// Completion reports whether the app/AX server accepted the request. The caller refreshes the list
    /// to observe the result; Close/Quit may legitimately present the application's unsaved-file dialog.
    func perform(_ action: WindowAction, on window: WindowRecord, completion: @escaping (Bool) -> Void) {
        queue.async {
            guard action.canApply(to: window),
                  let app = NSRunningApplication(processIdentifier: window.pid), !app.isTerminated else {
                DispatchQueue.main.async { completion(false) }; return
            }
            if action == .hide || action == .quit {
                DispatchQueue.main.async {
                    let accepted = action == .quit ? app.terminate() : (app.isHidden ? app.unhide() : app.hide())
                    completion(accepted)
                }
                return
            }
            guard let target = window.axElement else { DispatchQueue.main.async { completion(false) }; return }
            AXUIElementSetMessagingTimeout(target, 0.15)
            let result: AXError
            switch action {
            case .close:
                if let value = axValue(target, kAXCloseButtonAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() {
                    let button = unsafeBitCast(value, to: AXUIElement.self)
                    AXUIElementSetMessagingTimeout(button, 0.15)
                    result = AXUIElementPerformAction(button, kAXPressAction as CFString)
                } else { result = .actionUnsupported }
            case .minimize, .fullscreen:
                let attribute = action == .minimize ? kAXMinimizedAttribute : "AXFullScreen"
                let fallback = action == .minimize ? window.isMinimized : window.isFullscreen
                let current = axValue(target, attribute) as? Bool ?? fallback
                var settable: DarwinBoolean = false
                if AXUIElementIsAttributeSettable(target, attribute as CFString, &settable) == .success, settable.boolValue {
                    result = AXUIElementSetAttributeValue(target, attribute as CFString, current ? kCFBooleanFalse : kCFBooleanTrue)
                } else { result = .attributeUnsupported }
            case .hide, .quit: result = .failure
            }
            DispatchQueue.main.async { completion(result == .success) }
        }
    }
}

final class ThumbnailLoader {
    private var task: Task<Void, Never>?
    private struct CachedThumbnail {
        let image: NSImage
        let windowID: CGWindowID
        let frame: CGRect
        let title: String
        let date: Date
    }
    private var cache: [String: CachedThumbnail] = [:]
    func cancel() { task?.cancel(); task = nil }
    func load(_ windows: [WindowRecord], highResolution: Bool = false, changed: @escaping () -> Void) {
        cancel()
        guard AppPermissions.screenRecording else { return }
        task = Task { @MainActor in
            let cutoff = Date().addingTimeInterval(-600)
            cache = cache.filter { $0.value.date > cutoff }
            var restoredFromCache = false
            for window in windows {
                if let cached = cache[window.id], cached.windowID == window.windowID,
                   cached.frame == window.frame, cached.title == window.title {
                    window.thumbnail = cached.image
                    restoredFromCache = true
                }
            }
            if restoredFromCache { changed() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                for window in windows {
                    if Task.isCancelled { return }
                    guard !window.isMinimized, let id = window.windowID,
                          let source = content.windows.first(where: { $0.windowID == id && $0.owningApplication?.processID == window.pid }) else { continue }
                    let filter = SCContentFilter(desktopIndependentWindow: source)
                    let config = SCStreamConfiguration()
                    let size = Self.captureSize(for: window.frame.size, highResolution: highResolution)
                    config.width = size.width; config.height = size.height
                    config.showsCursor = false; config.captureResolution = .best
                    config.ignoreShadowsSingleWindow = true
                    if let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                        if Task.isCancelled { return }
                        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                        window.thumbnail = image
                        cache[window.id] = CachedThumbnail(image: image, windowID: id,
                            frame: window.frame, title: window.title, date: Date())
                        if cache.count > 40, let oldest = cache.min(by: { $0.value.date < $1.value.date })?.key {
                            cache.removeValue(forKey: oldest)
                        }
                        changed()
                    }
                }
            } catch { /* Missing permission or unavailable content falls back to app icons. */ }
        }
    }

    static func captureSize(for size: NSSize, highResolution: Bool = false) -> (width: Int, height: Int) {
        let width = size.width.isFinite ? max(1, size.width) : 1
        let height = size.height.isFinite ? max(1, size.height) : 1
        let scale = min(1, (highResolution ? 1440 : 720) / width, (highResolution ? 960 : 480) / height)
        return (max(2, Int((width * scale).rounded())), max(2, Int((height * scale).rounded())))
    }
}
