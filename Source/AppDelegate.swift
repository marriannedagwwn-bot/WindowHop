import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let preferences: AppPreferences
    private let catalog = WindowCatalog()
    private let thumbnails = ThumbnailLoader()
    private let keyboard = KeyboardController()
    private let overlay = OverlayController()
    private lazy var settings = SettingsController(preferences: preferences)
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var observation: NSObjectProtocol?
    private var windows: [WindowRecord] = []
    private var allWindows: [WindowRecord] = []
    private var selected = 0
    private var generation = 0
    private var loading = false
    private var pendingDelta = 0
    private var pendingCommit = false
    private var pendingSearch = false
    private var demo = false
    private var searchActive = false
    private var searchQuery = ""
    private var lastError: String?
    private var lastHealthTrace = Date.distantPast
    private var lastExternalPID: pid_t?
    private var sessionPID: pid_t?
    private var currentAppSession = false
    private var sessionScreen: NSScreen?
    private var menuTracking = false
    private var windowActionGeneration: Int?
    private var windowActionSerial = 0
    private var pendingFocusPID: pid_t?
    private var focusInputMonitors: [Any] = []

    override init() {
        let args = CommandLine.arguments
        if args.contains("--snapshot") || args.contains("--settings-snapshot") {
            let store = UserDefaults(suiteName: "local.windowhop.preview.\(UUID().uuidString)")!
            preferences = AppPreferences(defaults: store)
            for (flag, key) in [("--appearance", "appearanceStyle"), ("--size", "appearanceSize"), ("--theme", "appearanceTheme")] {
                if let i = args.firstIndex(of: flag), args.indices.contains(i + 1) { store.set(args[i + 1], forKey: key) }
            }
        } else { preferences = AppPreferences() }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let args = CommandLine.arguments
        if args.contains("--self-test") { SelfTest.run(); return }
        if args.contains("--diagnose") {
            let report: [String: Any] = ["app": "WindowHop", "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0", "accessibility": AppPermissions.accessibility,
                "screenRecording": AppPermissions.screenRecording, "shortcut": preferences.shortcutLabel,
                "architecture": "arm64", "windowFocusTested": false]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
            NSApp.terminate(nil); return
        }
        buildApplicationMenu()
        rememberExternalApplication()
        overlay.onSelect = { [weak self] index in self?.selected = index }
        overlay.onHover = { [weak self] index in self?.selected = index }
        overlay.onActivate = { [weak self] index in self?.selected = index; self?.commit() }
        overlay.onDismiss = { [weak self] in self?.cancel() }
        overlay.onWindowAction = { [weak self] index, action in self?.perform(action, index: index) }
        overlay.onSearchRequested = { [weak self] in self?.enterSearch() }
        overlay.onSearchChanged = { [weak self] query in self?.updateSearch(query) }
        overlay.onEndSearch = { [weak self] in self?.endSearch() }
        settings.onPreview = { [weak self] in self?.showDemo() }
        settings.onOpenWindows = { [weak self] in self?.openList() }
        settings.onReconnectKeyboard = { [weak self] in
            guard let self else { return }
            self.cancel(); self.keyboard.stop(); self.refreshPermissions()
        }
        settings.onPreferencesChanged = { [weak self] in
            guard let self else { return }
            let previewing = self.overlay.isVisible && self.demo
            self.cancel(); self.refreshPermissions(); self.syncLaunchAtLogin()
            if previewing { self.showDemo() }
        }
        keyboard.onAction = { [weak self] action in self?.handle(action) }
        overlay.configure(preferences: preferences)
        if let index = args.firstIndex(of: "--settings-snapshot"), args.indices.contains(index + 1) {
            settings.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                do { try self.settings.snapshot(to: URL(fileURLWithPath: args[index + 1])) }
                catch { fputs("settings snapshot failed: \(error)\n", stderr); exit(1) }
                NSApp.terminate(nil)
            }
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "跃窗")
        statusItem.button?.toolTip = "跃窗 WindowHop"
        rebuildMenu()
        if args.contains("--demo") {
            showDemo()
            if let index = args.firstIndex(of: "--snapshot"), args.indices.contains(index + 1) {
                let url = URL(fileURLWithPath: args[index + 1])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    do { try self.overlay.snapshot(to: url); print("snapshot: \(url.path)") }
                    catch { fputs("snapshot failed: \(error)\n", stderr); exit(1) }
                    NSApp.terminate(nil)
                }
            }
            return
        }
        refreshPermissions()
        observation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if pid != getpid() {
                self.lastExternalPID = pid
                if let targetPID = self.pendingFocusPID, pid != targetPID {
                    Diagnostics.log("focus.cancel.applicationChanged")
                    self.cancel()
                }
                if self.loading || (self.overlay.isVisible && !self.demo) {
                    if self.windowActionGeneration == self.generation {
                        Diagnostics.log("chooser.activationDuringAction")
                    } else {
                        Diagnostics.log("chooser.cancel.applicationChanged")
                        self.cancel()
                    }
                }
                self.catalog.noteFrontmost()
            }
        }
        catalog.noteFrontmost()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshPermissions() }
        if !args.contains("--background") || !AppPermissions.accessibility { settings.show() }
    }

    private func rememberExternalApplication() {
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() { lastExternalPID = app.processIdentifier }
    }
    private func buildApplicationMenu() {
        let menu = NSMenu()
        let application = NSMenu(title: "跃窗")
        let applicationItem = NSMenuItem()
        applicationItem.submenu = application
        menu.addItem(applicationItem)
        let settingsItem = application.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        application.addItem(.separator())
        let quitItem = application.addItem(withTitle: "退出跃窗", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        let edit = NSMenu(title: "编辑")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = edit; menu.addItem(editItem)
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
    }
    private func refreshPermissions() {
        keyboard.shortcutMode = preferences.shortcutMode
        keyboard.releaseBehavior = preferences.releaseBehavior
        overlay.shortcutLabel = preferences.shortcutLabel
        overlay.configure(preferences: preferences)
        if AppPermissions.accessibility {
            if !keyboard.isRunning { _ = keyboard.start() }
        } else {
            keyboard.stop()
            if loading || (overlay.isVisible && !demo) { cancel() }
        }
        settings.shortcutStatus = !AppPermissions.accessibility ? "需要辅助功能权限" :
            (keyboard.isRunning ? "已就绪 · \(preferences.shortcutLabel)" : "未连接，请重新连接或重新打开应用")
        if Diagnostics.enabled && Date().timeIntervalSince(lastHealthTrace) >= 10 {
            lastHealthTrace = Date()
            Diagnostics.log("health accessibility=\(AppPermissions.accessibility) recording=\(AppPermissions.screenRecording) keyboard=\(keyboard.isRunning) events=\(keyboard.inputEventCount) triggers=\(keyboard.triggerCount)")
        }
        if statusItem != nil { statusItem.isVisible = preferences.showMenuBarIcon }
        settings.refresh(); rebuildMenu()
    }
    private func syncLaunchAtLogin() {
        do {
            let service = SMAppService.mainApp
            if preferences.startAtLogin && service.status != .enabled && service.status != .requiresApproval { try service.register() }
            else if !preferences.startAtLogin && (service.status == .enabled || service.status == .requiresApproval) { try service.unregister() }
            settings.generalStatus = service.status == .requiresApproval ? "登录时启动：请在系统设置的登录项中允许跃窗。" : ""
        } catch { settings.generalStatus = "登录时启动未能保存：\(error.localizedDescription)" }
    }
    private func rebuildMenu() {
        guard statusItem != nil, !menuTracking else { return }
        let menu = NSMenu()
        menu.delegate = self
        let state = !AppPermissions.accessibility ? "需要辅助功能权限" : (keyboard.isRunning ? "已就绪 · \(preferences.shortcutLabel)" : "快捷键监听未连接")
        menu.addItem(withTitle: state, action: nil, keyEquivalent: "")
        if let lastError { menu.addItem(withTitle: lastError, action: nil, keyEquivalent: "") }
        menu.addItem(.separator())
        for (title, selector, key) in [("打开窗口列表", #selector(openList), ""), ("当前应用的窗口", #selector(openCurrentAppList), ""), ("设置…", #selector(openSettings), ","), ("外观预览", #selector(preview), "")] {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: key); item.target = self
        }
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出跃窗", action: #selector(quit), keyEquivalent: "q"); quit.target = self
        statusItem.menu = menu
    }
    private func handle(_ action: SwitcherAction) {
        switch action {
        case .begin(let delta): begin(delta: delta)
        case .beginCurrentApp(let delta): begin(delta: delta, currentAppOnly: true)
        case .move(let delta):
            if loading { pendingDelta += delta }
            else if !windows.isEmpty { select(SelectionMath.moved(selected, by: delta, count: windows.count)) }
        case .vertical(let delta):
            if !windows.isEmpty { select(overlay.navigationTarget(from: selected, vertical: delta)) }
        case .commit: commit()
        case .cancel: cancel()
        case .released:
            overlay.releaseToSelect = false
            if preferences.releaseBehavior == "search" { enterSearch() }
            else { overlay.update(windows: windows, selected: selected) }
        case .search: enterSearch()
        case .endSearch: endSearch()
        case .windowAction(let action): perform(action, index: selected)
        }
    }
    private func select(_ index: Int) {
        selected = index
        overlay.update(windows: windows, selected: selected)
    }
    private func begin(delta: Int, currentAppOnly: Bool = false) {
        Diagnostics.log("chooser.begin delta=\(delta) currentApp=\(currentAppOnly)")
        guard AppPermissions.accessibility else { settings.show(); return }
        rememberExternalApplication()
        stopFocusMonitoring()
        catalog.cancelFocus()
        currentAppSession = currentAppOnly
        sessionPID = lastExternalPID
        sessionScreen = presentationScreen()
        demo = false; generation += 1
        let token = generation
        let started = Date()
        loading = true; pendingDelta = delta; pendingCommit = false; pendingSearch = false
        searchActive = false; searchQuery = ""; keyboard.isSearching = false
        windows = []; allWindows = []; thumbnails.cancel(); overlay.hide(); overlay.setSearch(active: false, query: "")
        overlay.presentationScreen = sessionScreen
        catalog.noteFrontmost()
        loadCatalog { [weak self] result in
            guard let self, token == self.generation else { return }
            Diagnostics.log("chooser.loaded count=\(result.count) elapsed=\(Date().timeIntervalSince(started)) pendingCommit=\(self.pendingCommit)")
            self.loading = false; self.windows = result; self.allWindows = result
            self.selected = SelectionMath.moved(0, by: self.pendingDelta, count: result.count)
            if result.isEmpty {
                self.lastError = "没有符合筛选条件的窗口"; self.rebuildMenu()
            } else { self.lastError = nil }
            if self.pendingCommit {
                if Date().timeIntervalSince(started) > 1.5 {
                    self.cancel(); self.lastError = "读取窗口较慢，请重新切换"; self.rebuildMenu()
                    Diagnostics.log("chooser.cancel.slowLoad")
                } else { self.commit() }
                return
            }
            let delay = self.keyboard.usesModifierRelease
                ? max(0, Double(self.preferences.displayDelay) / 1000 - Date().timeIntervalSince(started)) : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, token == self.generation else { return }
                self.overlay.releaseToSelect = self.keyboard.usesModifierRelease
                self.overlay.show(windows: result, selected: self.selected)
                if self.pendingSearch { self.enterSearch() }
                self.loadThumbnails(token: token)
            }
        }
    }
    private func loadCatalog(completion: @escaping ([WindowRecord]) -> Void) {
        catalog.load(preferences: preferences, targetScreenFrame: sessionScreen.map(quartzFrame),
            currentAppPID: sessionPID, scopeOverride: currentAppSession ? "currentApp" : nil, completion: completion)
    }
    private func loadThumbnails(token: Int) {
        if (preferences.showThumbnails && preferences.appearanceStyle == "thumbnails") || preferences.previewFocusedWindow {
            thumbnails.load(allWindows, highResolution: preferences.previewFocusedWindow) { [weak self] in
                guard let self, token == self.generation, self.overlay.isVisible else { return }
                self.overlay.update(windows: self.windows, selected: self.selected)
            }
        }
    }
    private func commit() {
        if loading { pendingCommit = true; return }
        guard windows.indices.contains(selected) else { cancel(); return }
        let window = windows[selected]
        let isDemo = demo
        Diagnostics.log("chooser.commit index=\(selected) demo=\(isDemo)")
        cancel()
        guard !isDemo else { return }
        let token = generation
        monitorFocusInput(targetPID: window.pid)
        catalog.focus(window) { [weak self] success in
            Diagnostics.log("focus.verified success=\(success)")
            guard let self, token == self.generation else { return }
            self.stopFocusMonitoring()
            self.lastError = success ? nil : "未能确认目标窗口已聚焦，请重试"
            self.rebuildMenu()
        }
    }
    private func monitorFocusInput(targetPID: pid_t) {
        stopFocusMonitoring()
        pendingFocusPID = targetPID
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let interrupt: () -> Void = { [weak self] in
            guard let self, self.pendingFocusPID != nil else { return }
            Diagnostics.log("focus.cancel.userInput")
            self.cancel()
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in interrupt() }) {
            focusInputMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in interrupt(); return event }) {
            focusInputMonitors.append(monitor)
        }
    }
    private func stopFocusMonitoring() {
        for monitor in focusInputMonitors { NSEvent.removeMonitor(monitor) }
        focusInputMonitors.removeAll()
        pendingFocusPID = nil
    }
    private func perform(_ action: WindowAction, index: Int) {
        guard windows.indices.contains(index), windowActionGeneration == nil else { return }
        let window = windows[index]
        guard action.canApply(to: window) else { return }
        if demo {
            if action == .close || action == .quit { allWindows.removeAll { $0.id == window.id }; updateSearch(searchQuery) }
            return
        }
        let token = generation
        let oldIndex = index
        windowActionSerial += 1
        let serial = windowActionSerial
        windowActionGeneration = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, token == self.generation, serial == self.windowActionSerial,
                  self.windowActionGeneration != nil else { return }
            self.windowActionSerial += 1; self.windowActionGeneration = nil
            self.lastError = "窗口操作响应较慢，请重试"; self.rebuildMenu()
        }
        Diagnostics.log("window.action kind=\(action.rawValue)")
        catalog.perform(action, on: window) { [weak self] accepted in
            guard let self, token == self.generation, serial == self.windowActionSerial, self.overlay.isVisible else { return }
            Diagnostics.log("window.action.accepted kind=\(action.rawValue) accepted=\(accepted)")
            // AX close/minimize completion and application events can arrive after the request was accepted.
            // A full-screen transition temporarily removes/reparents AX windows.
            // Read after the Space animation instead of replacing the tile with
            // a windowless placeholder halfway through the transition.
            let settleDelay: TimeInterval = action == .fullscreen ? 1.2 : (action == .minimize ? 0.85 : 0.25)
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
                guard token == self.generation, serial == self.windowActionSerial, self.overlay.isVisible else { return }
                self.loadCatalog { [weak self] result in
                    guard let self, token == self.generation, serial == self.windowActionSerial, self.overlay.isVisible else { return }
                    self.allWindows = result
                    self.selected = min(oldIndex, max(0, result.count - 1))
                    self.updateSearch(self.searchQuery, preserveSelection: false)
                    if let target = self.windows.firstIndex(where: { $0.id == window.id }) { self.select(target) }
                    let updated = result.first(where: { $0.id == window.id })
                    let observed: Bool
                    switch action {
                    case .hide: observed = NSRunningApplication(processIdentifier: window.pid).map { $0.isHidden != window.isHidden } ?? false
                    case .minimize: observed = updated.map { $0.isMinimized != window.isMinimized } ?? false
                    case .fullscreen: observed = updated.map { $0.isFullscreen != window.isFullscreen } ?? false
                    case .close: observed = updated == nil
                    case .quit: observed = NSRunningApplication(processIdentifier: window.pid)?.isTerminated ?? true
                    }
                    Diagnostics.log("window.action.refreshed kind=\(action.rawValue) observed=\(observed) retained=\(updated != nil)")
                    self.lastError = accepted || observed ? nil : "目标应用未接受窗口操作"
                    self.rebuildMenu()
                    self.overlay.show(windows: self.windows, selected: self.selected)
                    self.loadThumbnails(token: token)
                    // Workspace activation notifications may arrive after an AX
                    // reply and the refreshed list, especially across full screen.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        guard let self, token == self.generation, serial == self.windowActionSerial else { return }
                        self.windowActionGeneration = nil
                    }
                }
            }
        }
    }
    private func enterSearch() {
        if loading { pendingSearch = true; keyboard.keepSessionOpen(); return }
        guard overlay.isVisible else { return }
        searchActive = true; keyboard.isSearching = true; keyboard.keepSessionOpen()
        overlay.releaseToSelect = false; overlay.setSearch(active: true, query: searchQuery)
    }
    private func updateSearch(_ query: String, preserveSelection: Bool = true) {
        let oldID = preserveSelection && windows.indices.contains(selected) ? windows[selected].id : nil
        searchQuery = query
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        windows = terms.isEmpty ? allWindows : allWindows.filter { window in
            let text = window.appName + " " + window.title
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }
        selected = oldID.flatMap { id in windows.firstIndex(where: { $0.id == id }) } ?? min(selected, max(0, windows.count - 1))
        overlay.update(windows: windows, selected: selected)
    }
    private func endSearch() {
        if !searchQuery.isEmpty {
            updateSearch(""); overlay.setSearch(active: true, query: "")
        } else {
            searchActive = false; keyboard.isSearching = false
            overlay.setSearch(active: false, query: "")
        }
    }
    private func cancel() {
        stopFocusMonitoring()
        generation += 1; loading = false; pendingCommit = false; pendingSearch = false
        windowActionGeneration = nil; windowActionSerial += 1
        catalog.cancelPending(); catalog.cancelFocus()
        thumbnails.cancel(); overlay.hide(); keyboard.cancelSession()
        windows = []; allWindows = []; searchActive = false; searchQuery = ""
        overlay.setSearch(active: false, query: "")
    }
    private func showDemo() {
        cancel(); demo = true
        allWindows = DemoWindows.make(); windows = allWindows; selected = min(1, windows.count - 1)
        overlay.configure(preferences: preferences)
        overlay.shortcutLabel = preferences.shortcutLabel
        overlay.releaseToSelect = false
        overlay.presentationScreen = presentationScreen()
        overlay.show(windows: windows, selected: selected, isDemo: true)
    }
    private func quartzFrame(_ screen: NSScreen) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        return CGRect(x: screen.frame.minX, y: top - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
    }
    private func presentationScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if preferences.panelScreen == "mouse" {
            return screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        }
        if preferences.panelScreen == "main" { return screens.first ?? NSScreen.main }
        if let pid = lastExternalPID,
           let descriptions = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
           let entry = descriptions.first(where: { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }),
           let bounds = entry[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds),
           let screen = screens.max(by: { quartzFrame($0).intersection(frame).width * quartzFrame($0).intersection(frame).height < quartzFrame($1).intersection(frame).width * quartzFrame($1).intersection(frame).height }) { return screen }
        return NSScreen.main ?? screens.first
    }
    @objc private func openSettings() { cancel(); settings.show() }
    @objc private func openList() { keyboard.openSessionFromMenu(); begin(delta: 0) }
    @objc private func openCurrentAppList() { keyboard.openSessionFromMenu(); begin(delta: 0, currentAppOnly: true) }
    @objc private func preview() { showDemo() }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings(); return true
    }
    func menuWillOpen(_ menu: NSMenu) { menuTracking = true }
    func menuDidClose(_ menu: NSMenu) { menuTracking = false }
    func applicationWillTerminate(_ notification: Notification) {
        stopFocusMonitoring()
        timer?.invalidate(); keyboard.stop(); thumbnails.cancel(); catalog.cancelFocus()
        if let observation { NSWorkspace.shared.notificationCenter.removeObserver(observation) }
    }
}
