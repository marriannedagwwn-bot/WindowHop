import AppKit
import ApplicationServices

enum SelfTest {
    /// Pure regression checks. No event is posted, no event tap is started, and
    /// preferences use disposable suites instead of the user's saved settings.
    static func run() {
        var passed = 0
        var failed = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if condition() { passed += 1 }
            else { failed += 1; fputs("FAIL: \(message)\n", stderr) }
        }

        check(SelectionMath.moved(0, by: -1, count: 3) == 2, "reverse wraps")
        check(SelectionMath.moved(1, by: 12, count: 3) == 1, "repeat wraps")
        check(SelectionMath.moved(0, by: 1, count: 0) == 0, "empty selection remains safe")
        let rect = CGRect(x: 25, y: 50, width: 900, height: 600)
        let entry: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: 123),
            kCGWindowLayer as String: NSNumber(value: 0), kCGWindowNumber as String: NSNumber(value: 456),
            kCGWindowName as String: "A", kCGWindowBounds as String: rect.dictionaryRepresentation]
        check(WindowCatalog.match(pid: 123, title: "A", frame: rect, descriptions: [entry])?.index == 0, "matching geometry")
        check(WindowCatalog.match(pid: 124, title: "A", frame: rect, descriptions: [entry]) == nil, "reject another process")
        check(WindowCatalog.match(pid: 123, title: "A", frame: rect, descriptions: [entry, entry]) == nil, "reject ambiguous windows")
        check(WindowCatalog.match(pid: 123, title: "B", frame: rect, descriptions: [entry]) == nil, "reject conflicting title")

        var helperSurface = entry
        helperSurface[kCGWindowLayer as String] = NSNumber(value: 3)
        helperSurface[kCGWindowAlpha as String] = NSNumber(value: 0)
        check(WindowCatalog.match(pid: 123, title: "A", frame: rect, descriptions: [helperSurface]) == nil,
              "capture matching does not use a floating helper surface")
        check(WindowCatalog.match(pid: 123, title: "A", frame: rect, descriptions: [helperSurface],
                                  normalLayerOnly: false)?.entry[kCGWindowLayer as String] as? Int == 3,
              "eligibility lookup can observe a helper's non-document layer")

        func candidate(role: String? = kAXWindowRole, subrole: String? = kAXStandardWindowSubrole,
                       title: String = "Document", main: Bool = false, minimized: Bool = false,
                       hidden: Bool = false, fullscreen: Bool = false,
                       layer: Int? = 0, alpha: Double? = 1) -> Bool {
            WindowCatalog.isCandidateWindow(role: role, subrole: subrole, title: title,
                isMain: main, isMinimized: minimized, isHidden: hidden, isFullscreen: fullscreen,
                backingLayer: layer, backingAlpha: alpha)
        }
        check(!candidate(subrole: kAXDialogSubrole, title: "", alpha: 0),
              "transparent persistent quit-prompt dialog is not a switch target")
        check(!candidate(layer: 3), "floating non-main surface is not a document window")
        check(!candidate(subrole: kAXDialogSubrole, title: "Prompt", layer: 3),
              "a titled dialog does not exempt an auxiliary floating surface")
        check(!candidate(subrole: kAXUnknownSubrole, title: ""),
              "untitled unknown helper is excluded")
        check(candidate(title: ""), "a real untitled standard document remains available")
        check(candidate(subrole: kAXDialogSubrole), "ordinary dialog remains available")
        check(candidate(subrole: kAXUnknownSubrole, title: "Custom document"),
              "titled custom framework window remains available")
        check(candidate(layer: nil, alpha: nil),
              "missing CG metadata alone does not discard a standard AX window")
        check(candidate(minimized: true, alpha: 0),
              "transparent minimized window can still be restored")
        check(candidate(hidden: true, alpha: 0),
              "transparent window of a hidden app remains available")
        check(candidate(main: true, layer: 3),
              "an app's main document can legitimately float above normal windows")
        check(candidate(fullscreen: true, layer: 101),
              "fullscreen presentation is not rejected for its elevated level")
        check(candidate(subrole: kAXUnknownSubrole, title: "", main: true),
              "main-window evidence keeps an untitled custom document")
        check(candidate(subrole: kAXUnknownSubrole, title: "", minimized: true, alpha: 0),
              "minimization does not turn a custom document into a helper")
        check(candidate(alpha: 0.01), "a translucent document is not an invisible helper")
        check(!candidate(subrole: kAXFloatingWindowSubrole, main: true),
              "explicit floating-panel semantics are not overridden by main status")
        check(!candidate(role: kAXGroupRole), "non-window accessibility elements are excluded")

        func inventoryWindow(_ id: String, pid: pid_t = 123, surface: CGWindowID? = nil) -> WindowRecord {
            WindowRecord(id: id, pid: pid, windowID: surface, title: "Same title",
                         appName: "Example", frame: rect)
        }
        let firstSurface = inventoryWindow("root", surface: 456)
        let repeatedReference = inventoryWindow("root", surface: 456)
        let surfaceAlias = inventoryWindow("alias", surface: 456)
        check(WindowCatalog.deduplicated([firstSurface, repeatedReference, surfaceAlias]).map(\.id) == ["root"],
              "repeated AX reference and aliases of one physical surface produce one tile")
        check(WindowCatalog.deduplicated([firstSurface, surfaceAlias]).first === firstSurface,
              "de-duplication retains the canonical first window reference")
        let secondSurface = inventoryWindow("second", surface: 457)
        check(WindowCatalog.deduplicated([firstSurface, secondSurface]).count == 2,
              "two real windows retain separate tiles even with identical title and frame")
        check(WindowCatalog.deduplicated([firstSurface, inventoryWindow("root", pid: 124, surface: 456)]).count == 2,
              "AX identities and numeric CG ids are scoped to their owning process")
        check(WindowCatalog.deduplicated([inventoryWindow("unmatched-a"), inventoryWindow("unmatched-b")]).count == 2,
              "distinct AX windows without CG ids remain separate")
        check(WindowCatalog.deduplicated([inventoryWindow("zero-a", surface: 0), inventoryWindow("zero-b", surface: 0)]).count == 2,
              "null CG id is missing evidence rather than a shared surface")
        check(WindowCatalog.deduplicated([inventoryWindow("unmatched"), inventoryWindow("unmatched")]).count == 1,
              "duplicate AX reference is removed even without CG metadata")

        let controller = KeyboardController()
        var actions: [String] = []
        controller.onAction = { action in
            switch action {
            case .begin(let delta): actions.append("begin:\(delta)")
            case .beginCurrentApp(let delta): actions.append("current:\(delta)")
            case .move(let delta): actions.append("move:\(delta)")
            case .vertical(let delta): actions.append("vertical:\(delta)")
            case .commit: actions.append("commit")
            case .cancel: actions.append("cancel")
            case .released: actions.append("released")
            case .search: controller.isSearching = true; actions.append("search")
            case .endSearch: controller.isSearching = false; actions.append("endSearch")
            case .windowAction(let action): actions.append("window:\(action.rawValue)")
            }
        }
        func event(_ type: CGEventType, key: CGKeyCode, flags: CGEventFlags = [], repeated: Bool = false) -> Bool {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: type != .keyUp)!
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
            return controller.handle(type, event)
        }
        func press(_ key: CGKeyCode, flags: CGEventFlags = []) -> Bool {
            let swallowed = event(.keyDown, key: key, flags: flags)
            _ = event(.keyUp, key: key, flags: flags)
            return swallowed
        }
        func reset() {
            controller.stop()
            controller.shortcutMode = "controlOption"
            controller.releaseBehavior = "focus"
            actions.removeAll()
        }

        // Preserve the original shortcut lifecycle coverage, including matching
        // key-up events that arrive after a modifier release closes the panel.
        check(!event(.keyDown, key: 48, flags: .maskAlternate), "default leaves Option Tab available")
        check(event(.keyDown, key: 48, flags: [.maskAlternate, .maskControl]), "trigger key-down swallowed")
        check(event(.keyUp, key: 48, flags: [.maskAlternate, .maskControl]), "trigger key-up swallowed")
        check(event(.keyDown, key: 48, flags: [.maskAlternate, .maskControl, .maskShift]), "reverse repeat swallowed")
        _ = event(.flagsChanged, key: 58, flags: .maskControl)
        check(actions == ["begin:1", "move:-1", "commit"], "fast modifier release commits before catalog load")
        check(!controller.sessionActive, "release ends focus session")
        check(event(.keyDown, key: 48), "held Tab repeat cannot leak to focused window")
        check(event(.keyUp, key: 48), "held Tab key-up remains swallowed")
        check(!event(.keyDown, key: 48), "fresh ordinary Tab passes through")
        actions.removeAll()
        controller.openSessionFromMenu()
        _ = event(.flagsChanged, key: 59)
        check(actions.isEmpty && controller.sessionActive, "menu session ignores modifier releases")
        check(event(.keyDown, key: 48), "menu plain Tab swallowed")
        check(event(.keyUp, key: 48), "menu plain Tab release swallowed")
        check(event(.keyDown, key: 48, flags: .maskShift), "menu reverse Tab swallowed")
        check(event(.keyUp, key: 48, flags: .maskShift), "menu reverse Tab release swallowed")
        check(actions == ["move:1", "move:-1"], "menu session navigates both directions")
        actions.removeAll()
        check(event(.keyDown, key: 53), "Escape swallowed")
        check(actions == ["cancel"] && !controller.sessionActive, "Escape cancels chooser")
        check(event(.keyUp, key: 53), "Escape release swallowed after cancel")
        actions.removeAll()
        check(event(.keyDown, key: 48, flags: [.maskAlternate, .maskControl]), "begin before listener interruption")
        controller.handleTapInterruption()
        check(!controller.sessionActive && actions.last == "cancel", "interrupted listener cancels selection")
        check(!event(.keyDown, key: 48), "lost key-up does not swallow a fresh Tab after interruption")

        reset()
        controller.shortcutMode = "command"
        check(!press(48, flags: .maskAlternate), "Command mode ignores Option Tab")
        check(press(48, flags: .maskCommand), "Command Tab starts chooser")
        _ = event(.flagsChanged, key: 58, flags: .maskCommand)
        check(actions == ["begin:1"] && controller.sessionActive, "Command session ignores unrelated Option release")
        _ = event(.flagsChanged, key: 55)
        check(actions == ["begin:1", "commit"] && !controller.sessionActive, "Command release commits Command Tab chooser")
        reset()
        controller.shortcutMode = "option"
        check(!press(48, flags: [.maskAlternate, .maskControl]), "Option mode rejects extra Control")
        check(press(48, flags: [.maskAlternate, .maskShift]), "Option Shift Tab starts reversed")
        check(actions == ["begin:-1"], "reverse initial trigger retains direction")

        for behavior in ["hold", "search"] {
            reset()
            controller.releaseBehavior = behavior
            _ = press(48, flags: [.maskAlternate, .maskControl])
            _ = event(.flagsChanged, key: 58)
            check(actions == ["begin:1", "released"] && controller.sessionActive,
                  "\(behavior) release keeps chooser open without committing")
            _ = event(.flagsChanged, key: 59)
            check(actions == ["begin:1", "released"], "\(behavior) release callback occurs once")
            check(press(36) && actions.last == "commit" && !controller.sessionActive,
                  "\(behavior) session can still confirm with Return")
        }

        reset()
        controller.shortcutMode = "command"
        check(press(50, flags: .maskAlternate), "Option grave starts current application chooser")
        check(actions == ["current:1"], "current application shortcut has its own action")
        _ = event(.flagsChanged, key: 58)
        check(actions.last == "commit", "current application shortcut releases on Option even in Command mode")
        reset()
        check(press(50, flags: [.maskAlternate, .maskShift]) && actions == ["current:-1"],
              "current application reverse shortcut retains direction")

        reset()
        controller.openSessionFromMenu()
        for (key, name): (CGKeyCode, String) in [(13, "close"), (46, "minimize"), (3, "fullscreen"), (4, "hide"), (12, "quit")] {
            check(press(key) && actions.last == "window:\(name)", "window action \(name) dispatched and key consumed")
        }
        check(controller.sessionActive, "window action keys preserve session until backend resolves action")
        actions.removeAll()
        _ = press(125)
        _ = press(126)
        _ = press(123)
        _ = press(124)
        check(actions == ["vertical:1", "vertical:-1", "move:-1", "move:1"], "vertical navigation is separate from linear navigation")
        actions.removeAll()
        check(press(1) && controller.isSearching && actions == ["search"], "S starts search")
        check(!press(13) && !press(12) && actions == ["search"], "typing W and Q in search cannot close or quit a window")
        check(!press(123) && !press(124), "search leaves horizontal caret movement available")
        check(press(53) && actions.last == "endSearch" && controller.sessionActive && !controller.isSearching,
              "first Escape exits search while keeping chooser")
        check(press(53) && actions.last == "cancel" && !controller.sessionActive,
              "second Escape cancels chooser")
        actions.removeAll()
        check(!press(13) && !press(12) && actions.isEmpty, "window action letters pass through outside chooser")
        reset()
        controller.openSessionFromMenu()
        check(press(76) && actions == ["commit"], "keypad Enter commits menu chooser")
        reset()

        // A normal application Command shortcut must not be reinterpreted as
        // an operation on the highlighted candidate in a menu/held chooser.
        for mode in ["option", "controlOption"] {
            for (key, name): (CGKeyCode, String) in [(13, "close"), (12, "quit")] {
                reset()
                controller.shortcutMode = mode
                controller.openSessionFromMenu()
                check(!press(key, flags: .maskCommand) && actions == ["cancel"] && !controller.sessionActive,
                      "fresh Command shortcut cannot \(name) candidate in \(mode) menu session")
            }
        }
        reset()
        controller.shortcutMode = "command"
        _ = press(48, flags: .maskCommand)
        check(press(13, flags: .maskCommand) && actions == ["begin:1", "window:close"] && controller.sessionActive,
              "W remains a window action while the primary Command trigger is still held")
        reset()
        controller.shortcutMode = "command"
        controller.releaseBehavior = "hold"
        _ = press(48, flags: .maskCommand)
        _ = event(.flagsChanged, key: 55)
        check(!press(12, flags: .maskCommand) && actions == ["begin:1", "released", "cancel"] && !controller.sessionActive,
              "new Command Q after trigger release cancels held chooser without quitting candidate")
        reset()

        controller.openSessionFromMenu()
        let closeDown = event(.keyDown, key: 13)
        let closeRepeat = event(.keyDown, key: 13, repeated: true)
        let closeUp = event(.keyUp, key: 13)
        check(closeDown && closeRepeat && closeUp && actions == ["window:close"],
              "held W consumes repeats without closing successive candidate windows")
        actions.removeAll()
        let tabDown = event(.keyDown, key: 48)
        let tabRepeat = event(.keyDown, key: 48, repeated: true)
        let tabUp = event(.keyUp, key: 48)
        check(tabDown && tabRepeat && tabUp && actions == ["move:1", "move:1"],
              "held Tab still navigates repeatedly")
        reset()

        // Geometry uses heterogeneous source proportions. Besides the numeric
        // bounds, verify the navigation target follows visual column position.
        let dimensions = [CGSize(width: 1600, height: 900), CGSize(width: 800, height: 1600),
            CGSize(width: 1000, height: 1000), CGSize(width: 2000, height: 1000),
            CGSize(width: 700, height: 1400), CGSize(width: 1300, height: 900),
            CGSize(width: 1700, height: 900), CGSize(width: 600, height: 1000)]
        let layout = OverlayLayout(windowSizes: dimensions, available: CGSize(width: 1200, height: 800))
        check(layout.tiles.count == dimensions.count && layout.tiles.map(\.index) == Array(dimensions.indices),
              "layout keeps stable source indices")
        check(Set(layout.tiles.map { Int($0.frame.height.rounded()) }).count == 1, "mixed aspect ratios keep equal tile height")
        check(Set(layout.tiles.map { Int($0.frame.width.rounded()) }).count > 1, "mixed aspect ratios retain variable widths")
        check(layout.rows.count > 1, "heterogeneous test spans multiple rows")
        for (rowIndex, row) in layout.rows.enumerated() {
            guard let first = row.first, let last = row.last else { continue }
            let center = (layout.tiles[first].frame.minX + layout.tiles[last].frame.maxX) / 2
            check(abs(center - layout.contentSize.width / 2) <= 1, "row \(rowIndex) centers within content")
        }
        for selected in layout.tiles.indices {
            guard let currentRow = layout.rows.firstIndex(where: { $0.contains(selected) }) else { continue }
            for direction in [-1, 1] {
                let target = layout.navigationTarget(from: selected, vertical: direction)
                let targetRow = (currentRow + direction + layout.rows.count) % layout.rows.count
                let center = layout.tiles[selected].frame.midX
                let minimum = layout.rows[targetRow].map { abs(layout.tiles[$0].frame.midX - center) }.min() ?? 0
                check(layout.rows[targetRow].contains(target) && abs(abs(layout.tiles[target].frame.midX - center) - minimum) < 0.01,
                      "vertical navigation follows closest center from \(selected) direction \(direction)")
            }
        }
        check(layout.navigationTarget(from: -1, vertical: 1) == -1, "invalid selection does not index layout")
        let emptyLayout = OverlayLayout(windowSizes: [])
        check(emptyLayout.tiles.isEmpty && emptyLayout.navigationTarget(from: 0, vertical: 1) == 0, "empty layout has safe navigation")
        let many = (0..<60).map { dimensions[$0 % dimensions.count] }
        let scrolling = OverlayLayout(windowSizes: many, available: CGSize(width: 1200, height: 800))
        check(scrolling.contentSize.height > scrolling.viewportHeight && scrolling.tiles.count == many.count,
              "sixty windows remain present in a bounded scrolling viewport")
        let auto = OverlayLayout(windowSizes: many, available: CGSize(width: 1200, height: 800), size: "auto")
        let small = OverlayLayout(windowSizes: many, available: CGSize(width: 1200, height: 800), size: "small")
        check(auto == small, "auto falls back to small when sixty windows cannot fit")
        let oneAuto = OverlayLayout(windowSizes: [dimensions[0]], available: CGSize(width: 1200, height: 800), size: "auto")
        let oneLarge = OverlayLayout(windowSizes: [dimensions[0]], available: CGSize(width: 1200, height: 800), size: "large")
        check(oneAuto == oneLarge, "auto uses large when available space permits")
        for available in [CGSize(width: 1440, height: 900), CGSize(width: 320, height: 240), CGSize(width: 220, height: 180)] {
            for style in ["thumbnails", "icons", "titles"] {
                for size in ["small", "medium", "large", "auto"] {
                  for modernGlass in [false, true] {
                    let result = OverlayLayout(windowSizes: many, available: available, style: style, size: size, modernGlass: modernGlass)
                    let context = "\(style)/\(size), glass=\(modernGlass) in \(Int(available.width))×\(Int(available.height))"
                    check(result.size.width <= available.width + 0.01 && result.size.height <= available.height + 0.01,
                          "panel stays within available bounds: \(context)")
                    check(result.tiles.allSatisfy { tile in
                        tile.frame.minX >= -0.01 && tile.frame.minY >= -0.01 &&
                        tile.frame.maxX <= result.contentSize.width + 0.01 &&
                        tile.frame.maxY <= result.contentSize.height + 0.01
                    }, "all scrolling tiles remain inside document: \(context)")
                    check(result.tiles.allSatisfy { $0.previewSize.width <= $0.frame.width + 0.01 && $0.previewSize.height <= $0.frame.height + 0.01 },
                          "preview fits its tile: \(context)")
                  }
                }
            }
        }
        check([CGFloat?.none, 0, CGFloat.nan, CGFloat.infinity].allSatisfy {
            OverlayLayout.screenWidthFraction(physicalWidth: $0) == 0.9
        }, "missing or invalid physical display width uses default maximum fraction")
        check(OverlayLayout.screenWidthFraction(physicalWidth: 300) == 0.9, "physical display width fraction clamps to ninety percent")
        check(OverlayLayout.screenWidthFraction(physicalWidth: 600) == 0.9, "six hundred millimetre display uses ninety percent")
        check(OverlayLayout.screenWidthFraction(physicalWidth: 1000) == 0.6, "one metre display uses sixty percent")
        check(OverlayLayout.screenWidthFraction(physicalWidth: 2000) == 0.45, "physical display width fraction clamps to forty five percent")
        for physicalWidth: CGFloat in [600, 1000, 2000] {
            let icons = OverlayLayout(windowSizes: many, available: CGSize(width: 2560, height: 1440),
                style: "icons", size: "medium", modernGlass: true, physicalScreenWidth: physicalWidth)
            check(icons.size.width <= 2560 * OverlayLayout.screenWidthFraction(physicalWidth: physicalWidth) + 0.01,
                  "icon panel applies physical viewing width at \(Int(physicalWidth)) millimetres")
            check(icons.tiles.allSatisfy { tile in
                let titleFrame = icons.iconTitleFrame(for: tile.index)
                return titleFrame.minX >= -0.01 && titleFrame.maxX <= icons.contentSize.width + 0.01 &&
                    titleFrame.width <= tile.frame.width * 2 + 0.01 && abs(titleFrame.midX - tile.frame.midX) < 0.01
            }, "icon titles remain centred and within both document edges at \(Int(physicalWidth)) millimetres")
        }
        check(["small", "medium", "large"].allSatisfy { size in
            [1, 2, 9, 40].allSatisfy { count in
                let layout = OverlayLayout(windowSizes: Array(repeating: CGSize(width: 640, height: 480), count: count),
                    available: CGSize(width: 1024, height: 768), style: "icons", size: size)
                return layout.tiles.allSatisfy { tile in
                    let title = layout.iconTitleFrame(for: tile.index)
                    return abs(title.midX - tile.frame.midX) < 0.01 && title.minX >= -0.01 && title.maxX <= layout.contentSize.width + 0.01
                }
            }
        }, "first, last and wrapped-row icon titles remain centred at every icon size")
        let iconTitles = OverlayLayout(windowSizes: dimensions, style: "icons")
        check(iconTitles.tiles.contains { iconTitles.iconTitleFrame(for: $0.index).width > $0.frame.width },
              "icon title may expand beyond one tile to preserve readable application names")
        check(iconTitles.iconTitleFrame(for: -1) == .zero && iconTitles.iconTitleFrame(for: iconTitles.tiles.count) == .zero,
              "invalid icon title index returns empty frame")
        let malformed = OverlayLayout(windowSizes: [.zero, CGSize(width: CGFloat.nan, height: -5), CGSize(width: CGFloat.infinity, height: 10)])
        check(malformed.tiles.allSatisfy { $0.frame.width.isFinite && $0.frame.height.isFinite && $0.previewSize.width > 0 && $0.previewSize.height > 0 },
              "invalid source geometry falls back to finite preview sizes")

        let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let positionedPreview = SelectionPreviewLayout.frame(quartzFrame: CGRect(x: 100, y: 100, width: 500, height: 300),
            imageSize: CGSize(width: 1000, height: 600), primaryScreenTop: 900, screenVisibleFrame: visible)
        check(positionedPreview == CGRect(x: 100, y: 500, width: 500, height: 300),
              "preview converts Quartz top-left coordinates while preserving visible window placement")
        for source in [CGRect(x: 3000, y: 50, width: 500, height: 300),
                       CGRect(x: -200, y: 0, width: 3000, height: 2000), .zero] {
            let fit = SelectionPreviewLayout.frame(quartzFrame: source, imageSize: CGSize(width: 1440, height: 960),
                primaryScreenTop: 900, screenVisibleFrame: visible)
            check(visible.contains(fit) && fit.width > 0 && fit.height > 0,
                  "offscreen, oversized or absent preview geometry fits the visible display: \(source)")
        }
        let negativeVisible = CGRect(x: -1600, y: 0, width: 1600, height: 900)
        let negativePreview = SelectionPreviewLayout.frame(quartzFrame: CGRect(x: -1400, y: 100, width: 500, height: 300),
            imageSize: CGSize(width: 1000, height: 600), primaryScreenTop: 900, screenVisibleFrame: negativeVisible)
        check(negativePreview == CGRect(x: -1400, y: 500, width: 500, height: 300),
              "preview preserves placement on a display left of the primary display")

        // Ordering is checked independently of the AX scan, including grouping
        // before alphabetical sorting so a stale window cannot replace the MRU.
        func record(_ id: String, pid: pid_t = 111, title: String, app: String = "App", minimized: Bool = false,
                    hidden: Bool = false, windowless: Bool = false, bundle: String = "example.app", ax: AXUIElement? = nil) -> WindowRecord {
            WindowRecord(id: id, pid: pid, axElement: ax, title: title, appName: app, bundleIdentifier: bundle,
                isMinimized: minimized, isHidden: hidden, isWindowless: windowless)
        }
        let oldA = record("oldA", title: "A"), newZ = record("newZ", title: "Z")
        let other = record("other", pid: 222, title: "B", app: "Other")
        let representatives = WindowCatalog.ordered([oldA, other, newZ], sortOrder: "title", groupByApp: true,
            minimizedAtEnd: false, hiddenAtEnd: false, recent: ["oldA": 1, "newZ": 2])
        check(representatives.map(\.id) == ["other", "newZ"], "grouping chooses MRU representative before title sorting")
        let minimized = record("min", pid: 333, title: "C", minimized: true)
        let hidden = record("hidden", pid: 444, title: "D", hidden: true)
        let windowless = record("windowless", pid: 555, title: "E", windowless: true)
        let ordered = WindowCatalog.ordered([windowless, hidden, minimized, other], sortOrder: "recent", groupByApp: false,
            minimizedAtEnd: true, hiddenAtEnd: true, recent: ["windowless": 100, "hidden": 90, "min": 80, "other": 1])
        check(ordered.map(\.id) == ["other", "hidden", "min", "windowless"], "minimized and hidden ordering precedes recency; windowless remains last")
        let titleA = record("a", pid: 10, title: "A", app: "Zulu")
        let titleZ = record("z", pid: 11, title: "Z", app: "Alpha")
        check(WindowCatalog.ordered([titleZ, titleA], sortOrder: "title", groupByApp: false,
            minimizedAtEnd: false, hiddenAtEnd: false).map(\.id) == ["a", "z"], "title sort is independent of application name")
        check(WindowCatalog.ordered([titleA, titleZ], sortOrder: "app", groupByApp: false,
            minimizedAtEnd: false, hiddenAtEnd: false).map(\.id) == ["z", "a"], "application sort uses application name")
        check(WindowCatalog.ordered([oldA, newZ, other], sortOrder: "recent", groupByApp: false,
            minimizedAtEnd: false, hiddenAtEnd: false, ranks: ["other": 0, "newZ": 1, "oldA": 2]).map(\.id) == ["other", "newZ", "oldA"],
              "system rank provides deterministic order without MRU evidence")
        let portrait = ThumbnailLoader.captureSize(for: NSSize(width: 1000, height: 2000))
        let landscape = ThumbnailLoader.captureSize(for: NSSize(width: 2000, height: 1000))
        check(portrait.width == 240 && portrait.height == 480, "portrait capture preserves aspect ratio within thumbnail bounds")
        check(landscape.width == 720 && landscape.height == 360, "landscape capture preserves aspect ratio within thumbnail bounds")
        let highPortrait = ThumbnailLoader.captureSize(for: NSSize(width: 1000, height: 2000), highResolution: true)
        let highLandscape = ThumbnailLoader.captureSize(for: NSSize(width: 2000, height: 1000), highResolution: true)
        check(highPortrait.width == 480 && highPortrait.height == 960,
              "high resolution portrait capture preserves aspect ratio within 1440 by 960 bounds")
        check(highLandscape.width == 1440 && highLandscape.height == 720,
              "high resolution landscape capture preserves aspect ratio within 1440 by 960 bounds")
        for invalidSize in [CGSize(width: CGFloat.nan, height: CGFloat.infinity),
                            CGSize(width: CGFloat.infinity, height: CGFloat.nan)] {
            for highResolution in [false, true] {
                let safe = ThumbnailLoader.captureSize(for: invalidSize, highResolution: highResolution)
                check(safe.width >= 2 && safe.height >= 2 && safe.width <= 1440 && safe.height <= 960,
                      "nonfinite capture geometry remains bounded with high resolution \(highResolution)")
            }
        }
        let applicationOnly = record("app", title: "Example", windowless: true)
        check(!WindowAction.close.canApply(to: applicationOnly) && !WindowAction.minimize.canApply(to: applicationOnly) && !WindowAction.fullscreen.canApply(to: applicationOnly),
              "windowless applications disable window-only operations")
        check(WindowAction.hide.canApply(to: applicationOnly) && WindowAction.quit.canApply(to: applicationOnly),
              "windowless applications permit application operations")
        let axWindow = record("ax", title: "Example", ax: AXUIElementCreateApplication(123456))
        check(WindowAction.close.canApply(to: axWindow) && WindowAction.minimize.canApply(to: axWindow) && WindowAction.fullscreen.canApply(to: axWindow),
              "AX-backed windows expose window operation capability")
        let noAX = record("noax", title: "Example")
        check(!WindowAction.close.canApply(to: noAX), "window without AX handle cannot claim close support")
        let finder = record("finder", title: "Finder", bundle: "com.apple.finder")
        check(!WindowAction.quit.canApply(to: finder), "Finder has no quit action")
        let invalidPID = record("invalid", pid: 0, title: "Example", windowless: true)
        check(!WindowAction.hide.canApply(to: invalidPID) && !WindowAction.quit.canApply(to: invalidPID), "invalid PID disables application actions")

        // Exercise JSON transfer through separate real UserDefaults stores. This
        // cannot register a login item or change the running user's preferences.
        let suiteA = "WindowHop.SelfTest.\(UUID().uuidString)"
        let suiteB = "WindowHop.SelfTest.\(UUID().uuidString)"
        let defaultsA = UserDefaults(suiteName: suiteA)!
        let defaultsB = UserDefaults(suiteName: suiteB)!
        let prefsA = AppPreferences(defaults: defaultsA)
        let prefsB = AppPreferences(defaults: defaultsB)
        check(prefsA.appearanceStyle == "thumbnails" && prefsA.appearanceSize == "medium" && prefsA.shortcutMode == "controlOption",
              "clean preferences register expected layout and shortcut defaults")
        check(!prefsA.previewFocusedWindow && prefsA.displayDelay == 100,
              "preview defaults off with one hundred millisecond display delay")
        prefsA.displayDelay = -20
        check(prefsA.displayDelay == 0, "negative display delay clamps to zero")
        prefsA.displayDelay = 550
        check(prefsA.displayDelay == 500, "excessive display delay clamps to five hundred milliseconds")
        prefsA.displayDelay = 230
        prefsA.previewFocusedWindow = true
        prefsA.appearanceStyle = "icons"
        prefsA.appearanceSize = "large"
        prefsA.appearanceTheme = "dark"
        prefsA.shortcutMode = "command"
        prefsA.releaseBehavior = "search"
        prefsA.groupByApp = true
        prefsA.includeWindowlessApps = true
        prefsA.excludedBundleIDs = ["com.example.first", "com.example.second"]
        prefsA.startAtLogin = true
        prefsA.showMenuBarIcon = false
        do {
            let exported = try prefsA.exportData()
            try prefsB.importData(exported)
            let exportedAgain = try prefsB.exportData()
            let first = try JSONSerialization.jsonObject(with: exported) as? NSDictionary
            let second = try JSONSerialization.jsonObject(with: exportedAgain) as? NSDictionary
            check(first == second, "JSON import/export round trip preserves all preference values")
            check(prefsB.previewFocusedWindow && prefsB.displayDelay == 230,
                  "JSON transfer preserves preview boolean and integer display delay")
            check(prefsB.shortcutMode == "command" && prefsB.releaseBehavior == "search" && prefsB.groupByApp && prefsB.includeWindowlessApps,
                  "behavior preferences survive transfer")
            check(prefsB.excludedBundleIDs == ["com.example.first", "com.example.second"] && prefsB.startAtLogin && !prefsB.showMenuBarIcon,
                  "exceptions and general preferences survive transfer without side effects")
            try prefsB.importData(Data("{\"format\":\"WindowHop\",\"version\":1,\"settings\":{\"notASetting\":true,\"appearanceSize\":\"unknown\",\"includeHidden\":\"false\"}}".utf8))
            check(defaultsB.object(forKey: "notASetting") == nil, "import ignores fields outside preference whitelist")
            check(prefsB.appearanceSize == "medium" && prefsB.includeHidden, "invalid enum falls back and wrong boolean type is ignored")
            var invalidRejected = false
            do { try prefsB.importData(Data("{\"format\":\"OtherApp\",\"version\":1,\"settings\":{}}".utf8)) }
            catch { invalidRejected = true }
            check(invalidRejected, "foreign settings document is rejected")
            var malformedRejected = false
            do { try prefsB.importData(Data("not json".utf8)) }
            catch { malformedRejected = true }
            check(malformedRejected, "malformed settings document is rejected")
        } catch {
            check(false, "settings transfer failed: \(error.localizedDescription)")
        }
        defaultsA.removePersistentDomain(forName: suiteA)
        defaultsB.removePersistentDomain(forName: suiteB)
        check(defaultsA.persistentDomain(forName: suiteA) == nil && defaultsB.persistentDomain(forName: suiteB) == nil,
              "temporary preference suites are removed")

        if failed > 0 {
            fputs("FAILED: \(failed) of \(passed + failed) checks. No system events posted; temporary preferences removed.\n", stderr)
            exit(1)
        }
        print("PASS: \(passed) checks (shortcut lifecycle/search/actions, layout/navigation/bounds, window ordering, capture geometry, settings transfer). No system events posted; temporary preferences removed.")
        NSApp.terminate(nil)
    }
}
