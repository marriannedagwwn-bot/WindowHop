import AppKit

/// Native settings use the same four groups as the switcher: appearance, controls,
/// general behavior, and exceptions. Every control writes AppPreferences directly.
final class SettingsController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    var onPreferencesChanged: (() -> Void)?
    var onPreview: (() -> Void)?
    var onOpenWindows: (() -> Void)?
    var onReconnectKeyboard: (() -> Void)?
    var shortcutStatus = "正在检查" {
        didSet { shortcutStatusLabel.stringValue = shortcutStatus }
    }
    var generalStatus = "" {
        didSet {
            generalStatusLabel.stringValue = generalStatus
            generalStatusLabel.isHidden = generalStatus.isEmpty
        }
    }

    private enum Page: Int, CaseIterable {
        case appearance, controls, general, exceptions
        var title: String { ["外观", "控制", "通用", "例外"][rawValue] }
        var symbol: String { ["rectangle.3.group", "keyboard", "gearshape", "line.3.horizontal.decrease.circle"][rawValue] }
        var subtitle: String {
            ["选择窗口列表的布局与显示方式。", "设置快捷键、选择方式与窗口范围。",
             "管理启动方式、菜单栏与系统权限。", "在窗口列表中排除指定应用。"][rawValue]
        }
    }

    private let preferences: AppPreferences
    private var window: NSWindow?
    private var selectedPage: Page = .appearance
    private var pages: [Page: NSStackView] = [:]
    private var navigationButtons: [Page: SettingsSidebarButton] = [:]
    private var currentPageConstraints: [NSLayoutConstraint] = []
    private let document = SettingsDocumentView()
    private let scrollView = NSScrollView()
    private let pageTitle = NSTextField(labelWithString: "外观")
    private let pageSubtitle = NSTextField(labelWithString: "")
    private let shortcutStatusLabel = NSTextField(labelWithString: "正在检查")
    private let generalStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let accessibilityStatus = NSTextField(labelWithString: "")
    private let screenRecordingStatus = NSTextField(labelWithString: "")
    private let accessibilityButton = NSButton(title: "前往设置…", target: nil, action: nil)
    private let screenRecordingButton = NSButton(title: "前往设置…", target: nil, action: nil)
    private let exceptionsEditor = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 218))
    private var exceptionsScrollView: SettingsTextEditorScrollView?
    private let runningAppsPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var runningAppBundleIDs: [String] = []
    private var actions: [String: () -> Void] = [:]
    private var refreshers: [() -> Void] = []
    private var bindingSequence = 0
    private var refreshing = false
    private var appearancePreview: SettingsAppearancePreview?

    init(preferences: AppPreferences) {
        self.preferences = preferences
        super.init()
    }

    func show() {
        if window == nil { buildWindow() }
        refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        guard window != nil else { return }
        refreshing = true
        for refresh in refreshers { refresh() }
        accessibilityStatus.stringValue = AppPermissions.accessibility ? "已允许" : "尚未允许"
        accessibilityStatus.textColor = AppPermissions.accessibility ? .systemGreen : .secondaryLabelColor
        screenRecordingStatus.stringValue = AppPermissions.screenRecording ? "已允许" : "尚未允许"
        screenRecordingStatus.textColor = AppPermissions.screenRecording ? .systemGreen : .secondaryLabelColor
        accessibilityButton.title = AppPermissions.accessibility ? "查看设置…" : "前往授权…"
        screenRecordingButton.title = AppPermissions.screenRecording ? "查看设置…" : "前往授权…"
        shortcutStatusLabel.stringValue = shortcutStatus
        generalStatusLabel.stringValue = generalStatus
        generalStatusLabel.isHidden = generalStatus.isEmpty
        if window?.firstResponder !== exceptionsEditor {
            exceptionsEditor.string = preferences.excludedBundleIDs.joined(separator: "\n")
        }
        appearancePreview?.needsDisplay = true
        refreshing = false
    }

    func snapshot(to url: URL) throws {
        guard let view = window?.contentView else { throw NSError(domain: "WindowHop.Settings", code: 1) }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw NSError(domain: "WindowHop.Settings", code: 2) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "WindowHop.Settings", code: 3) }
        try png.write(to: url, options: .atomic)
    }

    private func buildWindow() {
        let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 620),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                      backing: .buffered, defer: false)
        settingsWindow.title = "跃窗 WindowHop · 设置"
        settingsWindow.titleVisibility = .hidden
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.minSize = NSSize(width: 760, height: 560)
        settingsWindow.delegate = self
        settingsWindow.center()
        window = settingsWindow

        let root = NSView()
        settingsWindow.contentView = root
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        let divider = NSBox()
        divider.boxType = .separator
        let main = NSView()
        for view in [sidebar, divider, main] {
            root.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 156),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            main.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            main.topAnchor.constraint(equalTo: root.topAnchor),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        buildSidebar(in: sidebar)
        buildMain(in: main)
        pages[.appearance] = makeAppearancePage()
        pages[.controls] = makeControlsPage()
        pages[.general] = makeGeneralPage()
        pages[.exceptions] = makeExceptionsPage()
        selectPage(.appearance)
        refresh()
    }

    private func buildSidebar(in sidebar: NSView) {
        let brand = vertical(spacing: 5)
        let title = NSTextField(labelWithString: "跃窗")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        brand.addArrangedSubview(title)
        let english = text("WindowHop", size: 11)
        brand.addArrangedSubview(english)
        sidebar.addSubview(brand)
        brand.translatesAutoresizingMaskIntoConstraints = false

        let navigation = vertical(spacing: 4)
        for page in Page.allCases {
            let button = SettingsSidebarButton(title: page.title, symbol: page.symbol)
            button.tag = page.rawValue
            button.target = self
            button.action = #selector(pageClicked(_:))
            button.setAccessibilityLabel(page.title)
            addFullWidth(button, to: navigation)
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            navigationButtons[page] = button
        }
        sidebar.addSubview(navigation)
        navigation.translatesAutoresizingMaskIntoConstraints = false
        let help = text("按住快捷键选择窗口\n松开修饰键完成切换", size: 10)
        sidebar.addSubview(help)
        help.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            brand.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 20),
            brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 21),
            navigation.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            navigation.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),
            navigation.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 27),
            help.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            help.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            help.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -18)
        ])
    }

    private func buildMain(in main: NSView) {
        let header = vertical(spacing: 7)
        pageTitle.font = .systemFont(ofSize: 24, weight: .semibold)
        pageSubtitle.font = .systemFont(ofSize: 12)
        pageSubtitle.textColor = .secondaryLabelColor
        header.addArrangedSubview(pageTitle)
        header.addArrangedSubview(pageSubtitle)
        main.addSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        main.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSView()
        let separator = NSBox()
        separator.boxType = .separator
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY
        let preview = NSButton(title: "预览外观", target: self, action: #selector(previewClicked))
        preview.bezelStyle = .rounded
        preview.toolTip = "使用示例窗口预览当前外观设置"
        let openWindows = NSButton(title: "打开窗口列表", target: self, action: #selector(openWindowsClicked))
        openWindows.bezelStyle = .rounded
        openWindows.keyEquivalent = "\r"
        buttons.addArrangedSubview(preview)
        buttons.addArrangedSubview(openWindows)
        main.addSubview(footer)
        footer.addSubview(separator)
        footer.addSubview(buttons)
        for view in [footer, separator, buttons] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 27),
            header.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -26),
            header.topAnchor.constraint(equalTo: main.topAnchor, constant: 23),
            scrollView.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 18),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            footer.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: main.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 64),
            separator.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            separator.topAnchor.constraint(equalTo: footer.topAnchor),
            buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24),
            buttons.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
    }

    private func makeAppearancePage() -> NSStackView {
        let page = vertical(spacing: 21)
        let preview = SettingsAppearancePreview(preferences: preferences)
        appearancePreview = preview
        addFullWidth(preview, to: page)
        preview.heightAnchor.constraint(equalToConstant: 132).isActive = true

        let layout = group(title: "窗口列表")
        addFullWidth(segmentedRow("显示样式", labels: ["缩略图", "应用图标", "窗口标题"],
            values: ["thumbnails", "icons", "titles"], get: { self.preferences.appearanceStyle },
            set: { self.preferences.appearanceStyle = $0 }), to: layout)
        addFullWidth(pickerRow("大小", labels: ["小", "中", "大", "自动"],
            values: ["small", "medium", "large", "auto"], get: { self.preferences.appearanceSize },
            set: { self.preferences.appearanceSize = $0 }), to: layout)
        addFullWidth(pickerRow("主题", labels: ["跟随系统", "浅色", "深色"],
            values: ["system", "light", "dark"], get: { self.preferences.appearanceTheme },
            set: { self.preferences.appearanceTheme = $0 }), to: layout)
        addFullWidth(pickerRow("显示位置", labels: ["当前窗口所在屏幕", "鼠标所在屏幕", "主屏幕"],
            values: ["active", "mouse", "main"], get: { self.preferences.panelScreen },
            set: { self.preferences.panelScreen = $0 }), to: layout)
        addFullWidth(layout, to: page)

        let titles = group(title: "标题与预览")
        addFullWidth(pickerRow("标题内容", labels: ["窗口标题", "应用名称", "应用名称与窗口标题"],
            values: ["window", "app", "both"], get: { self.preferences.titleDisplay },
            set: { self.preferences.titleDisplay = $0 }), to: titles)
        addFullWidth(pickerRow("过长时省略", labels: ["开头", "中间", "结尾"],
            values: ["head", "middle", "tail"], get: { self.preferences.titleTruncation },
            set: { self.preferences.titleTruncation = $0 }), to: titles)
        addFullWidth(checkbox("显示窗口缩略图", get: { self.preferences.showThumbnails },
            set: { self.preferences.showThumbnails = $0 }), to: titles)
        addFullWidth(checkbox("预览所选窗口", get: { self.preferences.previewFocusedWindow },
            set: { self.preferences.previewFocusedWindow = $0 }), to: titles)
        addFullWidth(checkbox("显示退出、关闭、最小化和全屏按钮", get: { self.preferences.showWindowControls },
            set: { self.preferences.showWindowControls = $0 }), to: titles)
        addFullWidth(text("无法生成预览的窗口会显示应用图标。", size: 11), to: titles)
        addFullWidth(titles, to: page)
        return page
    }

    private func makeControlsPage() -> NSStackView {
        let page = vertical(spacing: 21)
        let keys = group(title: "快捷键")
        addFullWidth(pickerRow("呼出窗口列表", labels: ["⌃ ⌥ Tab", "⌥ Tab", "⌘ Tab"],
            values: ["controlOption", "option", "command"], get: { self.preferences.shortcutMode },
            set: { self.preferences.shortcutMode = $0 }), to: keys)
        let status = horizontal(spacing: 10)
        shortcutStatusLabel.font = .systemFont(ofSize: 11)
        shortcutStatusLabel.textColor = .secondaryLabelColor
        shortcutStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.addArrangedSubview(shortcutStatusLabel)
        let reconnect = NSButton(title: "重新连接快捷键", target: self, action: #selector(reconnectKeyboardClicked))
        reconnect.bezelStyle = .rounded
        reconnect.controlSize = .small
        status.addArrangedSubview(reconnect)
        addFullWidth(status, to: keys)
        addFullWidth(pickerRow("松开修饰键", labels: ["聚焦所选窗口", "保持窗口列表", "进入搜索"],
            values: ["focus", "hold", "search"], get: { self.preferences.releaseBehavior },
            set: { self.preferences.releaseBehavior = $0 }), to: keys)
        addFullWidth(checkbox("鼠标悬停时选择窗口", get: { self.preferences.mouseHoverEnabled },
            set: { self.preferences.mouseHoverEnabled = $0 }), to: keys)
        addFullWidth(pickerRow("显示延迟", labels: ["立即显示", "100 毫秒", "200 毫秒", "400 毫秒"],
            values: ["0", "100", "200", "400"], get: { String(self.preferences.displayDelay) },
            set: { self.preferences.displayDelay = Int($0) ?? 100 }), to: keys)
        addFullWidth(text("⌥ ` 仅切换当前应用的窗口。Tab / ⇧Tab 向前 / 向后选择，方向键移动，回车确认，Esc 取消。", size: 11), to: keys)
        addFullWidth(keys, to: page)

        let scope = group(title: "窗口范围")
        addFullWidth(pickerRow("应用", labels: ["所有应用", "当前应用", "其他应用"],
            values: ["all", "currentApp", "otherApps"], get: { self.preferences.windowScope },
            set: { self.preferences.windowScope = $0 }), to: scope)
        addFullWidth(pickerRow("屏幕", labels: ["所有屏幕", "当前屏幕"],
            values: ["all", "current"], get: { self.preferences.screenFilter },
            set: { self.preferences.screenFilter = $0 }), to: scope)
        addFullWidth(checkbox("仅当前可见桌面的窗口", get: { self.preferences.currentSpaceOnly },
            set: { self.preferences.currentSpaceOnly = $0 }), to: scope)
        addFullWidth(checkbox("包含已最小化的窗口", get: { self.preferences.includeMinimized },
            set: { self.preferences.includeMinimized = $0 }), to: scope)
        addFullWidth(checkbox("包含已隐藏应用的窗口", get: { self.preferences.includeHidden },
            set: { self.preferences.includeHidden = $0 }), to: scope)
        addFullWidth(checkbox("包含全屏窗口", get: { self.preferences.includeFullscreen },
            set: { self.preferences.includeFullscreen = $0 }), to: scope)
        addFullWidth(checkbox("包含没有窗口的应用", get: { self.preferences.includeWindowlessApps },
            set: { self.preferences.includeWindowlessApps = $0 }), to: scope)
        addFullWidth(scope, to: page)

        let ordering = group(title: "排列顺序")
        addFullWidth(pickerRow("排序", labels: ["最近使用", "应用名称", "窗口标题"],
            values: ["recent", "app", "title"], get: { self.preferences.sortOrder },
            set: { self.preferences.sortOrder = $0 }), to: ordering)
        addFullWidth(checkbox("每个应用只显示一个窗口", get: { self.preferences.groupByApp },
            set: { self.preferences.groupByApp = $0 }), to: ordering)
        addFullWidth(text("每个应用优先显示最近使用的窗口。", size: 11), to: ordering)
        addFullWidth(checkbox("已最小化的窗口放在最后", get: { self.preferences.minimizedAtEnd },
            set: { self.preferences.minimizedAtEnd = $0 }), to: ordering)
        addFullWidth(checkbox("已隐藏应用的窗口放在最后", get: { self.preferences.hiddenAtEnd },
            set: { self.preferences.hiddenAtEnd = $0 }), to: ordering)
        addFullWidth(ordering, to: page)

        let actions = group(title: "窗口操作")
        addFullWidth(text("在窗口列表中，按字母键操作所选窗口，也可右键打开操作菜单。", size: 12), to: actions)
        addFullWidth(shortcutLegend("W", "关闭窗口", "M", "最小化 / 恢复"), to: actions)
        addFullWidth(shortcutLegend("F", "切换全屏", "H", "隐藏应用"), to: actions)
        addFullWidth(shortcutLegend("Q", "退出应用", "S", "搜索窗口"), to: actions)
        addFullWidth(actions, to: page)
        return page
    }

    private func makeGeneralPage() -> NSStackView {
        let page = vertical(spacing: 21)
        let behavior = group(title: "启动与菜单栏")
        addFullWidth(checkbox("登录时启动跃窗", get: { self.preferences.startAtLogin },
            set: { self.preferences.startAtLogin = $0 }), to: behavior)
        addFullWidth(checkbox("在菜单栏显示图标", get: { self.preferences.showMenuBarIcon },
            set: { self.preferences.showMenuBarIcon = $0 }), to: behavior)
        addFullWidth(text("双击应用图标可随时重新打开设置。", size: 11), to: behavior)
        generalStatusLabel.font = .systemFont(ofSize: 11)
        generalStatusLabel.textColor = .secondaryLabelColor
        generalStatusLabel.isHidden = generalStatus.isEmpty
        addFullWidth(generalStatusLabel, to: behavior)
        addFullWidth(behavior, to: page)

        let permissions = group(title: "系统权限")
        addFullWidth(permissionRow(title: "辅助功能", detail: "读取窗口、响应快捷键并切换窗口。",
            status: accessibilityStatus, button: accessibilityButton), to: permissions)
        addFullWidth(separator(), to: permissions)
        addFullWidth(permissionRow(title: "屏幕录制", detail: "显示真实窗口缩略图。",
            status: screenRecordingStatus, button: screenRecordingButton), to: permissions)
        accessibilityButton.target = self
        accessibilityButton.action = #selector(accessibilityClicked)
        screenRecordingButton.target = self
        screenRecordingButton.action = #selector(screenRecordingClicked)
        addFullWidth(text("授权后返回设置，状态会自动刷新。", size: 11), to: permissions)
        addFullWidth(permissions, to: page)
        let transfer = group(title: "设置文件")
        let transferButtons = horizontal(spacing: 10)
        let importButton = NSButton(title: "导入设置…", target: self, action: #selector(importSettingsClicked))
        let exportButton = NSButton(title: "导出设置…", target: self, action: #selector(exportSettingsClicked))
        importButton.bezelStyle = .rounded
        exportButton.bezelStyle = .rounded
        transferButtons.addArrangedSubview(importButton)
        transferButtons.addArrangedSubview(exportButton)
        addFullWidth(transferButtons, to: transfer)
        addFullWidth(text("保存或恢复跃窗的外观、快捷键与筛选设置。", size: 11), to: transfer)
        addFullWidth(transfer, to: page)
        return page
    }

    private func makeExceptionsPage() -> NSStackView {
        let page = vertical(spacing: 17)
        addFullWidth(text("以下应用的窗口不会出现在列表中。每行填写一个应用标识符，也可以从运行中的应用添加。", size: 12), to: page)
        let inputScroll = SettingsTextEditorScrollView()
        exceptionsScrollView = inputScroll
        inputScroll.borderType = .lineBorder
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        exceptionsEditor.isRichText = false
        exceptionsEditor.isEditable = true
        exceptionsEditor.isSelectable = true
        exceptionsEditor.allowsUndo = true
        exceptionsEditor.minSize = NSSize(width: 0, height: 218)
        exceptionsEditor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        exceptionsEditor.isAutomaticQuoteSubstitutionEnabled = false
        exceptionsEditor.isAutomaticDashSubstitutionEnabled = false
        exceptionsEditor.isAutomaticSpellingCorrectionEnabled = false
        exceptionsEditor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        exceptionsEditor.textColor = .labelColor
        exceptionsEditor.backgroundColor = .textBackgroundColor
        exceptionsEditor.textContainerInset = NSSize(width: 10, height: 10)
        exceptionsEditor.isVerticallyResizable = true
        exceptionsEditor.isHorizontallyResizable = false
        exceptionsEditor.autoresizingMask = [.width]
        exceptionsEditor.textContainer?.widthTracksTextView = true
        exceptionsEditor.textContainer?.containerSize = NSSize(width: 460, height: CGFloat.greatestFiniteMagnitude)
        exceptionsEditor.delegate = self
        exceptionsEditor.setAccessibilityLabel("排除应用标识符，每行一个")
        inputScroll.documentView = exceptionsEditor
        addFullWidth(inputScroll, to: page)
        inputScroll.heightAnchor.constraint(equalToConstant: 220).isActive = true
        runningAppsPicker.target = self
        runningAppsPicker.action = #selector(addRunningApp(_:))
        runningAppsPicker.setAccessibilityLabel("从运行中的应用添加例外")
        populateRunningApps()
        addFullWidth(runningAppsPicker, to: page)
        addFullWidth(text("例如：com.apple.finder\n修改后自动保存，下次呼出窗口列表时生效。", size: 11), to: page)
        return page
    }

    private func selectPage(_ page: Page) {
        selectedPage = page
        pageTitle.stringValue = page.title
        pageSubtitle.stringValue = page.subtitle
        for (key, button) in navigationButtons { button.isSelected = key == page }
        NSLayoutConstraint.deactivate(currentPageConstraints)
        document.subviews.forEach { $0.removeFromSuperview() }
        guard let content = pages[page] else { return }
        document.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        currentPageConstraints = [
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 27),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -27),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 3),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ]
        NSLayoutConstraint.activate(currentPageConstraints)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if page == .exceptions {
            populateRunningApps()
            window?.contentView?.layoutSubtreeIfNeeded()
            exceptionsScrollView?.synchronizeEditorViewport()
        }
    }

    @objc private func pageClicked(_ sender: NSButton) {
        guard let page = Page(rawValue: sender.tag) else { return }
        window?.makeFirstResponder(nil)
        selectPage(page)
        refresh()
    }

    @objc private func controlChanged(_ sender: NSControl) {
        guard !refreshing, let id = sender.identifier?.rawValue else { return }
        actions[id]?()
        appearancePreview?.needsDisplay = true
        onPreferencesChanged?()
    }

    func textDidChange(_ notification: Notification) {
        guard !refreshing else { return }
        preferences.excludedBundleIDs = normalizedBundleIDs(exceptionsEditor.string)
        onPreferencesChanged?()
    }

    private func normalizedBundleIDs(_ string: String) -> [String] {
        var seen = Set<String>()
        return string.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: ",;")))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func populateRunningApps() {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0.bundleIdentifier != nil
        }.sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
        var seen = Set<String>()
        let unique = apps.filter { seen.insert($0.bundleIdentifier!).inserted }
        runningAppBundleIDs = unique.compactMap { $0.bundleIdentifier }
        runningAppsPicker.removeAllItems()
        runningAppsPicker.addItem(withTitle: "从运行中的应用添加…")
        for app in unique { runningAppsPicker.addItem(withTitle: "\(app.localizedName ?? "应用") · \(app.bundleIdentifier!)") }
        runningAppsPicker.selectItem(at: 0)
    }

    @objc private func addRunningApp(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem - 1
        guard runningAppBundleIDs.indices.contains(index) else { return }
        let bundleID = runningAppBundleIDs[index]
        var values = normalizedBundleIDs(exceptionsEditor.string)
        if !values.contains(bundleID) { values.append(bundleID) }
        preferences.excludedBundleIDs = values
        exceptionsEditor.string = values.joined(separator: "\n")
        sender.selectItem(at: 0)
        onPreferencesChanged?()
    }

    @objc private func accessibilityClicked() {
        if AppPermissions.accessibility { AppPermissions.openPrivacy("Privacy_Accessibility") }
        else { AppPermissions.requestAccessibility() }
        refresh()
    }
    @objc private func screenRecordingClicked() {
        if AppPermissions.screenRecording { AppPermissions.openPrivacy("Privacy_ScreenCapture") }
        else { AppPermissions.requestScreenRecording() }
        refresh()
    }
    @objc private func importSettingsClicked() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "导入跃窗设置"
        panel.message = "选择之前导出的 WindowHop JSON 设置文件。"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                try self.preferences.importData(data)
                self.refresh()
                self.onPreferencesChanged?()
            } catch { self.showSettingsError("无法导入设置", error: error) }
        }
    }

    @objc private func exportSettingsClicked() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.title = "导出跃窗设置"
        panel.nameFieldStringValue = "WindowHop-settings.json"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            do { try self.preferences.exportData().write(to: url, options: .atomic) }
            catch { self.showSettingsError("无法导出设置", error: error) }
        }
    }

    private func showSettingsError(_ title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }

    @objc private func previewClicked() { onPreview?() }
    @objc private func openWindowsClicked() { onOpenWindows?() }
    @objc private func reconnectKeyboardClicked() { onReconnectKeyboard?() }

    private func bind(_ control: NSControl, refresh: @escaping () -> Void, change: @escaping () -> Void) {
        bindingSequence += 1
        let id = "setting-\(bindingSequence)"
        control.identifier = NSUserInterfaceItemIdentifier(id)
        control.target = self
        control.action = #selector(controlChanged(_:))
        actions[id] = change
        refreshers.append(refresh)
        refresh()
    }

    private func checkbox(_ title: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.font = .systemFont(ofSize: 13)
        bind(button, refresh: { button.state = get() ? .on : .off }, change: { set(button.state == .on) })
        return button
    }

    private func pickerRow(_ title: String, labels: [String], values: [String],
                           get: @escaping () -> String, set: @escaping (String) -> Void) -> NSView {
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.addItems(withTitles: labels)
        picker.setAccessibilityLabel(title)
        picker.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        bind(picker, refresh: { picker.selectItem(at: values.firstIndex(of: get()) ?? 0) }, change: {
            let index = picker.indexOfSelectedItem
            if values.indices.contains(index) { set(values[index]) }
        })
        return labeledRow(title, control: picker)
    }

    private func segmentedRow(_ title: String, labels: [String], values: [String],
                              get: @escaping () -> String, set: @escaping (String) -> Void) -> NSView {
        let segmented = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        segmented.segmentStyle = .rounded
        segmented.setAccessibilityLabel(title)
        for i in labels.indices { segmented.setWidth(79, forSegment: i) }
        bind(segmented, refresh: { segmented.selectedSegment = values.firstIndex(of: get()) ?? 0 }, change: {
            let index = segmented.selectedSegment
            if values.indices.contains(index) { set(values[index]) }
        })
        return labeledRow(title, control: segmented)
    }

    private func labeledRow(_ title: String, control: NSView) -> NSStackView {
        let row = horizontal(spacing: 14)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.widthAnchor.constraint(equalToConstant: 105).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(control)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 25).isActive = true
        return row
    }

    private func permissionRow(title: String, detail: String, status: NSTextField, button: NSButton) -> NSStackView {
        let row = horizontal(spacing: 14)
        let labels = vertical(spacing: 5)
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 13, weight: .medium)
        labels.addArrangedSubview(heading)
        addFullWidth(text(detail, size: 11), to: labels)
        status.font = .systemFont(ofSize: 11, weight: .medium)
        labels.addArrangedSubview(status)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(labels)
        row.addArrangedSubview(button)
        button.bezelStyle = .rounded
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return row
    }

    private func shortcutLegend(_ firstKey: String, _ firstTitle: String, _ secondKey: String, _ secondTitle: String) -> NSStackView {
        let row = horizontal(spacing: 9)
        for (key, title) in [(firstKey, firstTitle), (secondKey, secondTitle)] {
            let keyLabel = NSTextField(labelWithString: key)
            keyLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            keyLabel.textColor = .secondaryLabelColor
            keyLabel.alignment = .center
            keyLabel.wantsLayer = true
            keyLabel.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.2).cgColor
            keyLabel.layer?.cornerRadius = 4
            keyLabel.widthAnchor.constraint(equalToConstant: 24).isActive = true
            row.addArrangedSubview(keyLabel)
            let label = text(title, size: 11)
            label.widthAnchor.constraint(equalToConstant: 174).isActive = true
            row.addArrangedSubview(label)
        }
        return row
    }

    private func group(title: String) -> NSStackView {
        let stack = vertical(spacing: 12)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(label)
        return stack
    }
    private func text(_ string: String, size: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.font = .systemFont(ofSize: size)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    private func vertical(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.detachesHiddenViews = true
        return stack
    }
    private func horizontal(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }
    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }
}

/// NSTextView starts with an explicit hit-test area and always covers its clip
/// view, including while the editor is empty. The document can grow vertically
/// without horizontal scrolling or changes to the current first responder.
private final class SettingsTextEditorScrollView: NSScrollView {
    private var synchronizingEditor = false

    override func layout() {
        super.layout()
        synchronizeEditorViewport()
    }

    override func tile() {
        super.tile()
        synchronizeEditorViewport()
    }

    func synchronizeEditorViewport() {
        guard !synchronizingEditor, let editor = documentView as? NSTextView else { return }
        let viewport = contentView.bounds.size
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else { return }
        synchronizingEditor = true
        defer { synchronizingEditor = false }
        editor.minSize = NSSize(width: 0, height: viewport.height)
        let width = viewport.width
        let containerWidth = max(1, width - editor.textContainerInset.width * 2)
        if let container = editor.textContainer, abs(container.containerSize.width - containerWidth) > 0.5 {
            container.containerSize = NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
        }
        var textHeight = editor.textContainerInset.height * 2
        if let manager = editor.layoutManager, let container = editor.textContainer {
            manager.ensureLayout(for: container)
            textHeight += manager.usedRect(for: container).height
        }
        let height = max(viewport.height, ceil(textHeight))
        if abs(editor.frame.width - width) > 0.5 || abs(editor.frame.height - height) > 0.5 {
            editor.setFrameSize(NSSize(width: width, height: height))
        }
    }
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class SettingsSidebarButton: NSButton {
    var isSelected = false { didSet { needsDisplay = true } }
    private let sidebarTitle: String
    private let sidebarSymbol: String
    init(title: String, symbol: String) {
        sidebarTitle = title
        sidebarSymbol = symbol
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        if isSelected || isHighlighted {
            (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.quaternaryLabelColor.withAlphaComponent(0.25)).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        let color = isSelected ? NSColor.controlAccentColor : NSColor.labelColor
        let symbol = NSImage(systemSymbolName: sidebarSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))?
            .withSymbolConfiguration(.init(paletteColors: [color]))
        let symbolRect = NSRect(x: 12, y: (bounds.height - 18) / 2, width: 18, height: 18)
        if let symbol {
            symbol.draw(in: symbolRect)
        }
        (sidebarTitle as NSString).draw(at: NSPoint(x: 40, y: (bounds.height - 17) / 2), withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: isSelected ? .medium : .regular), .foregroundColor: color
        ])
    }
}

/// An original, illustrative preview. The full preview button uses the actual chooser.
private final class SettingsAppearancePreview: NSView {
    private let preferences: AppPreferences
    init(preferences: AppPreferences) {
        self.preferences = preferences
        super.init(frame: .zero)
        setAccessibilityLabel("窗口列表外观示意")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        let isDark = preferences.appearanceTheme == "dark" ||
            (preferences.appearanceTheme == "system" && effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        let back = isDark ? NSColor(calibratedWhite: 0.15, alpha: 1) : NSColor(calibratedWhite: 0.91, alpha: 1)
        back.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        let width: CGFloat = preferences.appearanceStyle == "titles" ? min(390, bounds.width - 72) : 96
        let height: CGFloat = preferences.appearanceStyle == "titles" ? 26 : 86
        let names = ["文稿", "浏览器", "信息"]
        let symbols = ["doc.text", "globe", "bubble.left.and.bubble.right"]
        for index in 0..<3 {
            let rect: NSRect
            if preferences.appearanceStyle == "titles" {
                rect = NSRect(x: (bounds.width - width) / 2, y: 17 + CGFloat(2 - index) * 33, width: width, height: height)
            } else {
                rect = NSRect(x: (bounds.width - 314) / 2 + CGFloat(index) * 109, y: 23, width: width, height: height)
            }
            (index == 1 ? NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.38 : 0.2) : NSColor.white.withAlphaComponent(isDark ? 0.06 : 0.3)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            if index == 1 {
                NSColor.controlAccentColor.withAlphaComponent(0.75).setStroke()
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
                outline.lineWidth = 1
                outline.stroke()
            }
            let iconSize: CGFloat = preferences.appearanceStyle == "titles" ? 15 : (preferences.appearanceStyle == "icons" ? 37 : 19)
            let iconX = preferences.appearanceStyle == "titles" ? rect.minX + 9 : rect.midX - iconSize / 2
            let iconY = preferences.appearanceStyle == "titles" ? rect.midY - iconSize / 2 : rect.minY + 34
            let iconColor = isDark ? NSColor.white.withAlphaComponent(0.85) : NSColor.labelColor
            if let symbol = NSImage(systemSymbolName: symbols[index], accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: iconSize, weight: .light))?
                .withSymbolConfiguration(.init(paletteColors: [iconColor])) {
                symbol.draw(in: NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize))
            }
            if preferences.appearanceStyle == "thumbnails" {
                let paper = NSRect(x: rect.minX + 9, y: rect.minY + 29, width: rect.width - 18, height: 48)
                (isDark ? NSColor.white.withAlphaComponent(0.08) : NSColor.white.withAlphaComponent(0.65)).setFill()
                NSBezierPath(roundedRect: paper, xRadius: 4, yRadius: 4).fill()
                for line in 0..<3 {
                    NSColor.secondaryLabelColor.withAlphaComponent(0.17).setFill()
                    NSBezierPath(roundedRect: NSRect(x: paper.minX + 8, y: paper.maxY - 14 - CGFloat(line) * 9, width: line == 2 ? 36 : 55, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
                }
            }
            let color = isDark ? NSColor.white.withAlphaComponent(0.87) : NSColor.labelColor
            let nameX = preferences.appearanceStyle == "titles" ? rect.minX + 33 : rect.midX - 17
            let nameY = preferences.appearanceStyle == "titles" ? rect.midY - 6 : rect.minY + 9
            (names[index] as NSString).draw(at: NSPoint(x: nameX, y: nameY), withAttributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: color
            ])
        }
    }
}
