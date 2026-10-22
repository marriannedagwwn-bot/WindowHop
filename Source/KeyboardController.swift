import AppKit

enum SwitcherAction {
    case begin(Int), beginCurrentApp(Int), move(Int), vertical(Int)
    case commit, cancel, released, search, endSearch, windowAction(WindowAction)
}

final class KeyboardController {
    var onAction: ((SwitcherAction) -> Void)?
    var shortcutMode = "controlOption"
    var releaseBehavior = "focus"
    var isSearching = false
    var verticalStep = 4
    private(set) var inputEventCount = 0
    private(set) var triggerCount = 0
    private(set) var sessionActive = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var consumed = Set<Int64>()
    private var releaseOnOptionUp = true
    private var releaseModifier: CGEventFlags = .maskAlternate
    var usesModifierRelease: Bool { sessionActive && releaseOnOptionUp }

    @discardableResult func start() -> Bool {
        if let tap {
            if CFMachPortIsValid(tap) {
                if !CGEvent.tapIsEnabled(tap: tap) { handleTapInterruption() }
                CGEvent.tapEnable(tap: tap, enable: true)
                if CGEvent.tapIsEnabled(tap: tap) {
                    Diagnostics.log("tap.reenabled")
                    return true
                }
            }
            stop()
        }
        guard AppPermissions.accessibility else { return false }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<KeyboardController>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                Diagnostics.log("tap.disabled type=\(type.rawValue)")
                owner.handleTapInterruption()
                if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return owner.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                Diagnostics.log("tap.create.failed accessibility=\(AppPermissions.accessibility)")
                return false
            }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Diagnostics.log("tap.created enabled=\(CGEvent.tapIsEnabled(tap: tap))")
        return CGEvent.tapIsEnabled(tap: tap)
    }
    func stop() {
        cancelSession()
        consumed.removeAll()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }
    func cancelSession() { sessionActive = false; isSearching = false }
    func handleTapInterruption() {
        sessionActive = false; isSearching = false
        consumed.removeAll()
        onAction?(.cancel)
    }
    func openSessionFromMenu() { sessionActive = true; releaseOnOptionUp = false; isSearching = false }
    func keepSessionOpen() { sessionActive = true; releaseOnOptionUp = false }
    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        inputEventCount += 1
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        if key == 48 && flags.contains(.maskAlternate) {
            Diagnostics.log("tab.event type=\(type.rawValue) flags=\(flags.rawValue)")
        }
        if type == .keyUp { return consumed.remove(key) != nil }
        // Keep swallowing repeats from a held control key until its matching key-up,
        // even when releasing Option or confirming has already ended the chooser.
        if type == .keyDown && !sessionActive && consumed.contains(key) { return true }
        if type == .flagsChanged {
            if sessionActive && releaseOnOptionUp && !flags.contains(releaseModifier) {
                Diagnostics.log("shortcut.modifierReleased")
                releaseOnOptionUp = false
                if releaseBehavior == "focus" { sessionActive = false; onAction?(.commit) }
                else { onAction?(.released) }
            }
            return false
        }
        guard type == .keyDown else { return false }
        // A fresh Command shortcut belongs to the normal app, unless Command is
        // the chooser's currently held trigger. Text editing shortcuts stay local
        // to the search field and must never become destructive window actions.
        if sessionActive && !isSearching && flags.contains(.maskCommand)
            && !(releaseOnOptionUp && releaseModifier == .maskCommand) {
            sessionActive = false; onAction?(.cancel); return false
        }
        let correctModifiers: Bool
        if shortcutMode == "command" {
            correctModifiers = flags.contains(.maskCommand) && !flags.contains(.maskAlternate) && !flags.contains(.maskControl)
        } else {
            correctModifiers = flags.contains(.maskAlternate) && !flags.contains(.maskCommand)
                && (shortcutMode == "option" ? !flags.contains(.maskControl) : flags.contains(.maskControl))
        }
        let currentAppTrigger = key == 50 && flags.contains(.maskAlternate) && !flags.contains(.maskCommand) && !flags.contains(.maskControl)
        if (key == 48 && (correctModifiers || sessionActive)) || currentAppTrigger {
            consumed.insert(key)
            let delta = flags.contains(.maskShift) ? -1 : 1
            if sessionActive { onAction?(.move(delta)) }
            else {
                triggerCount += 1
                Diagnostics.log("shortcut.begin delta=\(delta)")
                sessionActive = true; releaseOnOptionUp = true; isSearching = false
                releaseModifier = currentAppTrigger || shortcutMode != "command" ? .maskAlternate : .maskCommand
                onAction?(currentAppTrigger ? .beginCurrentApp(delta) : .begin(delta))
            }
            return true
        }
        guard sessionActive else { return false }
        if !isSearching, [Int64(1), 3, 4, 12, 13, 46].contains(key),
           event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return true }
        let action: SwitcherAction?
        switch key {
        case 53:
            if isSearching { action = .endSearch }
            else { sessionActive = false; action = .cancel }
        case 36, 76: sessionActive = false; action = .commit
        case 123: action = isSearching ? nil : .move(-1)
        case 124: action = isSearching ? nil : .move(1)
        case 125: action = .vertical(1)
        case 126: action = .vertical(-1)
        case 1: action = isSearching ? nil : .search // S
        case 13: action = isSearching ? nil : .windowAction(.close) // W
        case 46: action = isSearching ? nil : .windowAction(.minimize) // M
        case 3: action = isSearching ? nil : .windowAction(.fullscreen) // F
        case 4: action = isSearching ? nil : .windowAction(.hide) // H
        case 12: action = isSearching ? nil : .windowAction(.quit) // Q
        default: action = nil
        }
        if let action { consumed.insert(key); onAction?(action); return true }
        if flags.contains(.maskCommand), !isSearching {
            sessionActive = false; onAction?(.cancel)
        }
        return false
    }
}
