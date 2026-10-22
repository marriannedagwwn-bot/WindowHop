import AppKit
import SwiftUI

/// The chooser uses a nonactivating panel so browsing previews never activates a
/// target app. Only a committed selection or an explicit window action does so.
final class OverlayController {
    var onSelect: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?
    var onActivate: ((Int) -> Void)?
    var onWindowAction: ((Int, WindowAction) -> Void)?
    var onDismiss: (() -> Void)?
    var onSearchRequested: (() -> Void)?
    var onSearchChanged: ((String) -> Void)?
    var onEndSearch: (() -> Void)?
    var shortcutLabel = "⌃ ⌥ Tab"
    var releaseToSelect = true
    var presentationScreen: NSScreen?
    var isVisible: Bool { panel?.isVisible == true }
    var columnCount: Int { model.layout.columns }
    var positions: [CGRect] { model.layout.tiles.map(\.frame) }

    private let model = OverlayModel()
    private let selectionPreview = SelectionPreviewController()
    private let presentationAnimator = ChooserPresentationAnimator()
    private var previewFocusedWindow = false
    private var panel: ChooserPanel?
    private var hostingView: NSHostingView<WindowOverlayView>?
    private var backdrop: NSView?
    private var surfaceView: ChooserSurfaceView?
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var pointerAtShow = NSPoint.zero
    private var pointerHasMoved = false
    private var screenPreference = "active"
    private var themePreference = "system"

    init() {
        model.activate = { [weak self] index in
            self?.model.selected = index
            self?.onSelect?(index)
            self?.onActivate?(index)
        }
        model.hover = { [weak self] index in
            guard let self else { return }
            self.model.hovered = index
            guard self.model.hoverSelect, self.pointerHasMoved else { return }
            self.model.selected = index
            self.updateSelectionPreview()
            self.onHover?(index)
        }
        model.windowAction = { [weak self] index, action in self?.onWindowAction?(index, action) }
        model.dismiss = { [weak self] in self?.onDismiss?() }
        model.searchChanged = { [weak self] query in self?.onSearchChanged?(query) }
        model.endSearch = { [weak self] in self?.onEndSearch?() }
    }

    func configure(preferences: AppPreferences) {
        model.style = preferences.appearanceStyle
        model.sizePreference = preferences.appearanceSize
        model.hoverSelect = preferences.mouseHoverEnabled
        model.showWindowControls = preferences.showWindowControls
        model.titleDisplay = preferences.titleDisplay
        model.titleTruncation = preferences.titleTruncation
        model.showThumbnails = preferences.showThumbnails
        previewFocusedWindow = preferences.previewFocusedWindow
        themePreference = preferences.appearanceTheme
        screenPreference = preferences.panelScreen
        if isVisible {
            applyAppearance()
            update(windows: model.windows, selected: model.selected)
        }
    }

    func setSearch(active: Bool, query: String) {
        let wasActive = model.searchActive
        model.searchActive = active
        if model.searchQuery != query { model.searchQuery = query }
        if wasActive != active, let panel {
            presentationAnimator.cancel()
            let previous = panel.frame
            let size = model.panelSize
            panel.setFrame(NSRect(x: previous.midX - size.width / 2, y: previous.midY - size.height / 2,
                                  width: size.width, height: size.height), display: true)
        }
    }

    func navigationTarget(from selected: Int, vertical direction: Int) -> Int {
        model.layout.navigationTarget(from: selected, vertical: direction)
    }

    func show(windows: [WindowRecord], selected: Int, isDemo: Bool = false) {
        let opening = !isVisible
        presentationAnimator.cancel()
        model.isDemo = isDemo
        model.windows = windows
        model.selected = clampedSelection(selected, count: windows.count)
        model.hovered = nil
        pointerAtShow = NSEvent.mouseLocation
        pointerHasMoved = false
        let screen = presentationScreen ?? preferredScreen(windows: windows)
        model.layout = layout(for: windows, screen: screen)
        if panel == nil { createPanel() }
        applyAppearance()
        let visible = screen.visibleFrame
        let size = model.panelSize
        let origin = NSPoint(x: (visible.midX - size.width / 2).rounded(),
                             y: (visible.midY - size.height / 2).rounded())
        panel?.setFrame(NSRect(origin: origin, size: size), display: true)
        if opening, let panel { presentationAnimator.prepare(panel) }
        panel?.makeKeyAndOrderFront(nil)
        hostingView?.layoutSubtreeIfNeeded()
        if opening { presentationAnimator.start() }
        startOutsideClickMonitoring()
        updateSelectionPreview()
    }

    func update(windows: [WindowRecord], selected: Int) {
        defer { updateSelectionPreview() }
        model.windows = windows
        model.selected = clampedSelection(selected, count: windows.count)
        guard let panel else { return }
        let screen = presentationScreen ?? panel.screen ?? preferredScreen(windows: windows)
        let nextLayout = layout(for: windows, screen: screen)
        guard model.layout != nextLayout else { return }
        presentationAnimator.cancel()
        let oldFrame = panel.frame
        model.layout = nextLayout
        let panelSize = model.panelSize
        panel.setFrame(NSRect(x: (oldFrame.midX - panelSize.width / 2).rounded(),
                              y: (oldFrame.midY - panelSize.height / 2).rounded(),
                              width: panelSize.width, height: panelSize.height), display: true)
    }

    func hide() {
        presentationAnimator.cancel()
        selectionPreview.hide()
        panel?.orderOut(nil)
        stopOutsideClickMonitoring()
        model.windows = []
        model.hovered = nil
    }

    /// Captures only this app's view, used for safe demo exports.
    func snapshot(to url: URL) throws {
        guard let view = panel?.contentView else {
            throw NSError(domain: "WindowHop.Overlay", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "请先显示切换面板，再保存预览。"])
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw NSError(domain: "WindowHop.Overlay", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建面板预览。"])
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "WindowHop.Overlay", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "无法编码 PNG 预览。"])
        }
        try png.write(to: url, options: .atomic)
    }

    private func createPanel() {
        let chooser = ChooserPanel(contentRect: NSRect(origin: .zero, size: model.panelSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        chooser.level = .popUpMenu
        chooser.isOpaque = false
        chooser.backgroundColor = .clear
        chooser.hasShadow = true
        chooser.animationBehavior = .none
        chooser.hidesOnDeactivate = false
        chooser.isReleasedWhenClosed = false
        chooser.isMovableByWindowBackground = false
        chooser.acceptsMouseMovedEvents = true
        chooser.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        chooser.dismiss = { [weak self] in self?.onDismiss?() }
        chooser.navigate = { [weak self] delta in
            guard let self, !self.model.windows.isEmpty else { return }
            self.select(SelectionMath.moved(self.model.selected, by: delta, count: self.model.windows.count))
        }
        chooser.navigateVertical = { [weak self] direction in
            guard let self else { return }
            self.select(self.navigationTarget(from: self.model.selected, vertical: direction))
        }
        chooser.activateSelection = { [weak self] in
            guard let self, self.model.windows.indices.contains(self.model.selected) else { return }
            self.onActivate?(self.model.selected)
        }
        chooser.isSearching = { [weak self] in self?.model.searchActive == true }
        chooser.beginSearch = { [weak self] in self?.onSearchRequested?() }
        chooser.endSearch = { [weak self] in self?.onEndSearch?() }
        chooser.windowAction = { [weak self] action in
            guard let self, self.model.windows.indices.contains(self.model.selected) else { return }
            self.onWindowAction?(self.model.selected, action)
        }
        chooser.pointerMoved = { [weak self] in
            guard let self else { return }
            let pointer = NSEvent.mouseLocation
            if hypot(pointer.x - self.pointerAtShow.x, pointer.y - self.pointerAtShow.y) > 2 {
                self.pointerHasMoved = true
                if self.model.hoverSelect, let hovered = self.model.hovered,
                   hovered != self.model.selected {
                    self.model.selected = hovered
                    self.updateSelectionPreview()
                    self.onHover?(hovered)
                }
            }
        }
        let hosting = TransparentChooserHostingView(rootView: WindowOverlayView(model: model))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: model.panelSize)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        let effect: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: model.panelSize))
            glass.style = .regular
            glass.cornerRadius = model.panelCornerRadius
            hosting.autoresizingMask = [.width, .height]
            glass.contentView = hosting
            effect = glass
        } else {
            let frosted = NSVisualEffectView(frame: NSRect(origin: .zero, size: model.panelSize))
            frosted.material = .hudWindow
            frosted.blendingMode = .behindWindow
            frosted.state = .active
            hosting.translatesAutoresizingMaskIntoConstraints = false
            frosted.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: frosted.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: frosted.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: frosted.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: frosted.bottomAnchor)
            ])
            effect = frosted
        }
        effect.wantsLayer = true
        effect.layer?.backgroundColor = NSColor.clear.cgColor
        effect.layer?.isOpaque = false
        effect.layer?.borderWidth = 0
        // An effect view's private backdrop drawing may extend beyond its own
        // corner layer. Clip the complete native hierarchy in a plain root view.
        let surface = ChooserSurfaceView(frame: NSRect(origin: .zero, size: model.panelSize))
        surface.cornerRadius = model.panelCornerRadius
        effect.frame = surface.bounds
        effect.autoresizingMask = [.width, .height]
        surface.addSubview(effect)
        surface.materialView = effect as? NSVisualEffectView
        chooser.contentView = surface
        panel = chooser; hostingView = hosting; backdrop = effect; surfaceView = surface
        surface.synchronizeContour()
    }

    private func select(_ index: Int) {
        guard model.windows.indices.contains(index) else { return }
        model.selected = index
        updateSelectionPreview()
        onSelect?(index)
    }

    private func updateSelectionPreview() {
        guard previewFocusedWindow, !model.isDemo, let panel, panel.isVisible,
              model.windows.indices.contains(model.selected),
              let image = model.windows[model.selected].thumbnail else {
            selectionPreview.hide(); return
        }
        let window = model.windows[model.selected]
        let screen = presentationScreen ?? panel.screen ?? preferredScreen(windows: model.windows)
        selectionPreview.show(image: image, quartzFrame: window.frame, screen: screen, below: panel)
    }

    private func applyAppearance() {
        switch themePreference {
        case "light": panel?.appearance = NSAppearance(named: .aqua)
        case "dark": panel?.appearance = NSAppearance(named: .darkAqua)
        default: panel?.appearance = nil
        }
        if #available(macOS 26.0, *), let glass = backdrop as? NSGlassEffectView {
            glass.cornerRadius = model.panelCornerRadius
        }
        surfaceView?.cornerRadius = model.panelCornerRadius
        surfaceView?.synchronizeContour()
        let appearance = panel?.effectiveAppearance ?? NSApp.effectiveAppearance
        model.isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func layout(for windows: [WindowRecord], screen: NSScreen) -> OverlayLayout {
        let modernGlass: Bool
        if #available(macOS 26.0, *) { modernGlass = true } else { modernGlass = false }
        var available = screen.visibleFrame.size
        if model.searchActive { available.height = max(180, available.height - 42) }
        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let physicalWidth = screenNumber.map { CGDisplayScreenSize(CGDirectDisplayID($0.uint32Value)).width }
        return OverlayLayout(windowSizes: windows.map { $0.isWindowless ? CGSize(width: 128, height: 128) : $0.frame.size },
                      available: available, style: model.style, size: model.sizePreference, modernGlass: modernGlass,
                      physicalScreenWidth: physicalWidth)
    }

    private func clampedSelection(_ selected: Int, count: Int) -> Int {
        count == 0 ? 0 : max(0, min(selected, count - 1))
    }

    private func preferredScreen(windows: [WindowRecord]) -> NSScreen {
        let main = NSScreen.main ?? NSScreen.screens[0]
        if screenPreference == "main" { return main }
        if screenPreference == "active", let frontmost = NSWorkspace.shared.frontmostApplication,
           let window = windows.first(where: { $0.pid == frontmost.processIdentifier && !$0.isMinimized }),
           window.frame.width > 0, window.frame.height > 0 {
            // Accessibility/CG coordinates start at the primary display's top.
            let primaryTop = NSScreen.screens[0].frame.maxY
            let appKitFrame = CGRect(x: window.frame.minX, y: primaryTop - window.frame.maxY,
                                     width: window.frame.width, height: window.frame.height)
            if let best = NSScreen.screens.max(by: {
                $0.frame.intersection(appKitFrame).area < $1.frame.intersection(appKitFrame).area
            }), best.frame.intersects(appKitFrame) { return best }
        }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? main
    }

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible,
                  !panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.onDismiss?()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, self.isVisible, let eventWindow = event.window,
               eventWindow !== self.panel, eventWindow.level.rawValue < NSWindow.Level.popUpMenu.rawValue {
                self.onDismiss?()
            }
            return event
        }
    }

    private func stopOutsideClickMonitoring() {
        if let monitor = outsideMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor) }
        outsideMonitor = nil; localMonitor = nil
    }

    deinit { presentationAnimator.cancel(); stopOutsideClickMonitoring() }
}

/// A transparent compositor boundary owns the final silhouette on both the
/// frosted-material and Glass paths. Its path also matches SwiftUI's circular
/// clip/stroke, so there is no second corner outline at the window rectangle.
private final class ChooserSurfaceView: NSView {
    var cornerRadius: CGFloat = 23 {
        didSet { if oldValue != cornerRadius { synchronizeContour() } }
    }
    weak var materialView: NSVisualEffectView? {
        didSet { previousBounds = .null; synchronizeContour() }
    }
    private let contourMask = CAShapeLayer()
    private var previousBounds = CGRect.null
    private var previousRadius: CGFloat = -1
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.borderWidth = 0
        layer?.mask = contourMask
        contourMask.fillColor = NSColor.black.cgColor
        synchronizeContour()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        synchronizeContour()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        synchronizeContour()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Rebuild at the display's scale even if geometry has not changed.
        previousBounds = .null
        synchronizeContour()
    }

    func synchronizeContour() {
        guard bounds.width > 0, bounds.height > 0,
              bounds != previousBounds || cornerRadius != previousRadius else { return }
        previousBounds = bounds; previousRadius = cornerRadius
        let radius = min(cornerRadius, min(bounds.width, bounds.height) / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contourMask.frame = bounds
        contourMask.contentsScale = window?.backingScaleFactor ?? 2
        contourMask.path = CGPath(roundedRect: CGRect(origin: .zero, size: bounds.size),
                                 cornerWidth: radius, cornerHeight: radius, transform: nil)
        // The public maskImage API shapes the behind-window material itself;
        // the root's layer mask independently clips hosting and native subviews.
        materialView?.maskImage = Self.materialMask(radius: radius)
        CATransaction.commit()
        // NSWindow caches its shadow. Update it after a style/size change so the
        // cached rectangular or previous-size silhouette cannot remain visible.
        window?.invalidateShadow()
    }

    private static func materialMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private final class TransparentChooserHostingView: NSHostingView<WindowOverlayView> {
    override var isOpaque: Bool { false }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : max(0, width) * max(0, height) }
}

private final class ChooserPanel: NSPanel {
    var dismiss: (() -> Void)?
    var navigate: ((Int) -> Void)?
    var navigateVertical: ((Int) -> Void)?
    var activateSelection: (() -> Void)?
    var pointerMoved: (() -> Void)?
    var isSearching: (() -> Bool)?
    var beginSearch: (() -> Void)?
    var endSearch: (() -> Void)?
    var windowAction: ((WindowAction) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .mouseMoved || event.type == .leftMouseDragged { pointerMoved?() }
        if event.type == .keyDown {
            let searching = isSearching?() == true
            if searching && routeSearchEditingShortcut(event) { return }
            let navigation: Set<UInt16> = searching ? [36, 48, 53, 76, 125, 126] : [36, 48, 53, 76, 123, 124, 125, 126]
            let commands: Set<UInt16> = [1, 3, 4, 12, 13, 46]
            if !searching && commands.contains(event.keyCode) && event.isARepeat { return }
            if navigation.contains(event.keyCode) || (!searching && commands.contains(event.keyCode) && !event.modifierFlags.contains(.command)) {
                keyDown(with: event); return
            }
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isSearching?() == true, routeSearchEditingShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Nonactivating panels do not always receive the app's Edit menu routing.
    /// Keep these commands on our field editor and consume them even if it is
    /// briefly attaching, so they cannot reach a background application's UI.
    private func routeSearchEditingShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option),
              [UInt16(0), 6, 7, 8, 9].contains(event.keyCode) else { return false }
        guard let editor = firstResponder as? NSTextView, editor.isFieldEditor else { return true }
        switch event.keyCode {
        case 0: editor.selectAll(nil)
        case 7: editor.cut(nil)
        case 8: editor.copy(nil)
        case 9:
            if event.modifierFlags.contains(.shift) { editor.pasteAsPlainText(nil) }
            else { editor.paste(nil) }
        case 6:
            if event.modifierFlags.contains(.shift) { editor.undoManager?.redo() }
            else { editor.undoManager?.undo() }
        default: break
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: if isSearching?() == true { endSearch?() } else { dismiss?() }
        case 123: navigate?(-1)
        case 124: navigate?(1)
        case 125: navigateVertical?(1)
        case 126: navigateVertical?(-1)
        case 48: navigate?(event.modifierFlags.contains(.shift) ? -1 : 1)
        case 36, 76: activateSelection?()
        case 1: beginSearch?()
        case 13: windowAction?(.close)
        case 46: windowAction?(.minimize)
        case 3: windowAction?(.fullscreen)
        case 4: windowAction?(.hide)
        case 12: windowAction?(.quit)
        default: super.keyDown(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}

private final class OverlayModel: ObservableObject {
    @Published var windows: [WindowRecord] = []
    @Published var selected = 0
    @Published var hovered: Int?
    @Published var isDemo = false
    @Published var isDark = true
    @Published var style = "thumbnails"
    @Published var sizePreference = "medium"
    @Published var hoverSelect = true
    @Published var showWindowControls = true
    @Published var showThumbnails = true
    @Published var titleDisplay = "window"
    @Published var titleTruncation = "tail"
    @Published var layout = OverlayLayout()
    @Published var searchActive = false
    @Published var searchQuery = ""
    var panelSize: CGSize { CGSize(width: max(searchActive ? 320 : 0, layout.size.width),
                                  height: layout.size.height + (searchActive ? 42 : 0)) }
    var panelCornerRadius: CGFloat {
        if #available(macOS 26.0, *) {
            if style == "thumbnails" { return 43 }
            if style == "icons" { return layout.resolvedSize == "small" ? 50 : (layout.resolvedSize == "large" ? 75 : 55) }
        }
        return 23
    }
    var cellCornerRadius: CGFloat {
        if #available(macOS 26.0, *) {
            if style == "thumbnails" { return 18 }
            if style == "icons" { return layout.resolvedSize == "small" ? 24 : (layout.resolvedSize == "large" ? 45 : 35) }
        }
        return 10
    }
    var searchChanged: ((String) -> Void)?
    var endSearch: (() -> Void)?
    var activate: ((Int) -> Void)?
    var hover: ((Int) -> Void)?
    var windowAction: ((Int, WindowAction) -> Void)?
    var dismiss: (() -> Void)?
}

/// Native field editing is needed in a nonactivating panel: SwiftUI's focus
/// state can update without making the AppKit field editor the first responder.
private struct NativeSwitcherSearchField: NSViewRepresentable {
    var query: String
    var onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> SearchInputField {
        let field = SearchInputField(frame: .zero)
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.textColor = .labelColor
        field.placeholderString = "搜索应用或窗口"
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("搜索应用或窗口")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.stringValue = query
        field.delegate = context.coordinator
        field.onWindowReady = { [weak coordinator = context.coordinator] field in
            coordinator?.requestInitialFocus(field)
        }
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: SearchInputField, context: Context) {
        context.coordinator.onChange = onChange
        // Text-change callbacks already reflect edits in query. Reassigning the
        // value on each result redraw would cancel IME composition and move the
        // insertion point, so external changes alone update the live editor.
        let editor = field.currentEditor() as? NSTextView
        if field.stringValue != query, editor?.hasMarkedText() != true {
            if let editor {
                let previousRange = editor.selectedRange()
                editor.string = query
                let location = min(previousRange.location, (query as NSString).length)
                editor.setSelectedRange(NSRange(location: location, length: 0))
            }
            field.stringValue = query
        }
        context.coordinator.requestInitialFocus(field)
    }

    static func dismantleNSView(_ field: SearchInputField, coordinator: Coordinator) {
        coordinator.isAttached = false
        field.onWindowReady = nil
        field.delegate = nil
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onChange: (String) -> Void
        weak var field: SearchInputField?
        var isAttached = true
        private var hasFocused = false
        private var focusPending = false
        private var attempts = 0

        init(onChange: @escaping (String) -> Void) { self.onChange = onChange }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onChange(field.stringValue)
        }

        func requestInitialFocus(_ field: SearchInputField) {
            guard isAttached, !hasFocused, !focusPending, field.window != nil, attempts < 3 else { return }
            focusPending = true
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field, self.isAttached, let window = field.window else { return }
                self.focusPending = false
                self.attempts += 1
                // makeKey does not activate another app. The chooser is already
                // a nonactivating panel and remains the sole keyboard surface.
                if !window.isKeyWindow { window.makeKey() }
                let accepted = window.makeFirstResponder(field)
                let editor = field.currentEditor() as? NSTextView
                self.hasFocused = accepted && editor != nil && window.firstResponder === editor
                if self.hasFocused, let editor {
                    editor.allowsUndo = true
                    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                }
                Diagnostics.log("search.focus accepted=\(accepted) editor=\(editor != nil) isKey=\(window.isKeyWindow)")
                if !self.hasFocused, self.attempts < 3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak field] in
                        guard let field else { return }
                        self?.requestInitialFocus(field)
                    }
                }
            }
        }
    }
}

private final class SearchInputField: NSTextField {
    var onWindowReady: ((SearchInputField) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindowReady?(self) }
    }
}

private struct WindowOverlayView: View {
    @ObservedObject var model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if model.searchActive { searchBar }
            grid
        }
        .frame(width: model.panelSize.width, height: model.panelSize.height)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: model.panelCornerRadius, style: .circular))
        .overlay {
            RoundedRectangle(cornerRadius: model.panelCornerRadius, style: .circular)
                .strokeBorder(model.isDark ? .white.opacity(0.16) : .black.opacity(0.12), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            if model.isDemo {
                Text("界面演示").font(.system(size: 9)).foregroundStyle(.secondary)
                    .padding(.bottom, 3).allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, model.isDark ? .dark : .light)
        .onExitCommand { if model.searchActive { model.endSearch?() } else { model.dismiss?() } }
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            NativeSwitcherSearchField(query: model.searchQuery) { query in
                model.searchQuery = query
                model.searchChanged?(query)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            if !model.searchQuery.isEmpty {
                Button { model.searchQuery = ""; model.searchChanged?("") } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain).accessibilityLabel("清空搜索")
            }
        }
        .font(.system(size: 14))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, model.layout.padding)
        .padding(.top, 12)
    }

    private var grid: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    if model.windows.isEmpty {
                        Text(model.searchActive ? "没有匹配的窗口" : "没有可切换的窗口").font(.system(size: 14)).foregroundStyle(.secondary)
                            .frame(width: model.layout.contentSize.width, height: model.layout.contentSize.height)
                    } else {
                        if let selectedTile = model.layout.tiles.first(where: { $0.index == model.selected }) {
                            let height = model.style == "icons"
                                ? model.layout.iconSize + model.layout.edgeInset * 2 : selectedTile.frame.height
                            SwitcherSelectionBackdrop(cornerRadius: model.cellCornerRadius,
                                                      isDark: model.isDark, selected: true)
                                .frame(width: selectedTile.frame.width, height: height)
                                .position(x: selectedTile.frame.midX, y: selectedTile.frame.minY + height / 2)
                                .animation(reduceMotion ? nil : .interpolatingSpring(stiffness: 410, damping: 28),
                                           value: model.selected)
                                .id(selectionLayoutID)
                        }
                        ForEach(model.layout.tiles, id: \.index) { tile in
                            if model.windows.indices.contains(tile.index) {
                                WindowTile(model: model, tile: tile, window: model.windows[tile.index])
                                    .frame(width: tile.frame.width, height: tile.frame.height)
                                    .position(x: tile.frame.midX, y: tile.frame.midY)
                                    .id(tile.index)
                            }
                        }
                    }
                }
                .frame(width: model.layout.contentSize.width, height: model.layout.contentSize.height)
            }
            .scrollIndicators(model.layout.contentSize.height > model.layout.viewportHeight ? .automatic : .hidden)
            .frame(width: model.layout.contentSize.width, height: model.layout.viewportHeight)
            .padding(model.layout.padding)
            .onChange(of: model.selected) { _, selected in reader.scrollTo(selected, anchor: .center) }
            .onChange(of: model.windows.map(\.id)) { _, _ in reader.scrollTo(model.selected, anchor: .center) }
            .onAppear { reader.scrollTo(model.selected, anchor: .center) }
        }

    }

    private var selectionLayoutID: SwitcherSelectionLayoutID {
        SwitcherSelectionLayoutID(windowIDs: model.windows.map(\.id), style: model.style,
            searchActive: model.searchActive, cornerRadius: model.cellCornerRadius,
            frames: model.layout.tiles.map(\.frame))
    }
}

private struct WindowTile: View {
    @ObservedObject var model: OverlayModel
    let tile: OverlayTile
    @State private var hovering = false
    let window: WindowRecord
    private var selected: Bool { model.selected == tile.index }
    private var layout: OverlayLayout { model.layout }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button { model.activate?(tile.index) } label: {
                tileContents
                    .frame(width: tile.frame.width, height: tile.frame.height, alignment: .topLeading)
                    .background(alignment: .top) {
                        if hovering && !selected {
                            SwitcherSelectionBackdrop(cornerRadius: model.cellCornerRadius,
                                                      isDark: model.isDark, selected: false)
                                .frame(height: highlightHeight)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: model.cellCornerRadius))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .help("\(window.appName)：\(window.title)")
            if model.style == "thumbnails", model.showWindowControls, hovering {
                windowControls
                    .padding(.leading, controlOriginX)
                    .padding(.top, layout.edgeInset + max(layout.iconSize, ceil(layout.fontSize * 1.3)) + 7)
            }
        }
        .onHover { inside in
            hovering = inside
            if inside { model.hover?(tile.index) }
            else if model.hovered == tile.index { model.hovered = nil }
        }
        .contextMenu {
            Button("切换到此窗口") { model.activate?(tile.index) }
            Divider()
            ForEach(WindowAction.allCases, id: \.rawValue) { action in
                Button(actionLabel(action)) { model.windowAction?(tile.index, action) }
                    .disabled(model.isDemo || !action.canApply(to: window))
            }
        }
    }

    @ViewBuilder private var tileContents: some View {
        if model.style == "icons" {
            VStack(spacing: 10) {
                appIcon(size: layout.iconSize)
                    .frame(width: tile.frame.width, height: layout.iconSize + layout.edgeInset * 2)
                Text(displayTitle)
                    .font(.system(size: layout.fontSize)).lineLimit(1).truncationMode(truncation)
                    .foregroundStyle(model.isDark ? .white.opacity(0.85) : .black.opacity(0.8))
                    .opacity(selected || hovering ? 1 : 0)
                    .frame(width: layout.iconTitleFrame(for: tile.index).width)
                    .offset(x: layout.iconTitleFrame(for: tile.index).midX - tile.frame.midX)
                    .frame(width: tile.frame.width)
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 2) {
                    appIcon(size: layout.iconSize)
                    Text(displayTitle)
                        .font(.system(size: layout.fontSize)).lineLimit(1).truncationMode(truncation)
                        .foregroundStyle(model.isDark ? .white.opacity(0.85) : .black.opacity(0.8))
                    Spacer(minLength: 0)
                    statusIcons
                }
                .frame(height: max(layout.iconSize, ceil(layout.fontSize * 1.3)))
                if model.style == "thumbnails" {
                    thumbnail
                        .frame(width: tile.frame.width - layout.edgeInset * 2,
                               height: max(0, tile.frame.height - layout.edgeInset * 2 - max(layout.iconSize, ceil(layout.fontSize * 1.3)) - 5),
                               alignment: .top)
                }
            }
            .padding(layout.edgeInset)
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if model.showThumbnails, let image = window.thumbnail {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                .frame(width: tile.previewSize.width, height: tile.previewSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .shadow(color: .black.opacity(model.isDark ? 0.35 : 0.20), radius: 1, y: 1)
        } else {
            appIcon(size: min(82, tile.previewSize.width, tile.previewSize.height))
                .opacity(window.isHidden ? 0.5 : 0.85)
                .frame(width: tile.previewSize.width, height: tile.previewSize.height)
        }
    }

    @ViewBuilder private var statusIcons: some View {
        if window.isMinimized {
            Image(systemName: "minus.square").font(.system(size: 11)).foregroundStyle(.secondary)
                .help("窗口已最小化")
        }
        if window.isHidden {
            Image(systemName: "eye.slash").font(.system(size: 11)).foregroundStyle(.secondary)
                .help("应用已隐藏")
        }
        if window.isFullscreen {
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10)).foregroundStyle(.secondary)
                .help("全屏窗口")
        }
    }

    private var availableControls: [WindowAction] {
        [.quit, .close, .minimize, .fullscreen].filter { model.isDemo || $0.canApply(to: window) }
    }

    private var controlColumns: Int {
        let count = max(1, availableControls.count)
        let previewHeight = max(16, tile.frame.height - layout.edgeInset * 2 - max(layout.iconSize, ceil(layout.fontSize * 1.3)) - 7)
        let rowsThatFit = max(1, Int((previewHeight + 8) / 24))
        let columnsToFitVertically = Int(ceil(Double(count) / Double(rowsThatFit)))
        let preferredColumns = max(1, Int((tile.previewSize.width - 3 + 8) / 24))
        let columnsInTile = max(1, Int((tile.frame.width - layout.edgeInset * 2 + 8) / 24))
        return max(1, min(count, columnsInTile, max(preferredColumns, columnsToFitVertically)))
    }

    private var controlWidth: CGFloat {
        CGFloat(min(max(1, availableControls.count), controlColumns)) * 24 - 8
    }

    private var controlOriginX: CGFloat {
        let preferred = max(layout.edgeInset, (tile.frame.width - tile.previewSize.width) / 2) + 3
        return max(layout.edgeInset, min(preferred, tile.frame.width - layout.edgeInset - controlWidth))
    }

    private var windowControls: some View {
        let actions = availableControls
        let columns = controlColumns
        let rows = Int(ceil(Double(actions.count) / Double(columns)))
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(Array(actions.dropFirst(row * columns).prefix(columns)), id: \.rawValue) { action in
                        trafficLight(action, color: controlColor(action), symbol: controlSymbol(action))
                    }
                }
            }
        }
    }

    private func controlColor(_ action: WindowAction) -> Color {
        switch action {
        case .quit: return Color(red: 0.75, green: 0.33, blue: 1)
        case .close: return Color(red: 1, green: 0.37, blue: 0.34)
        case .minimize: return Color(red: 1, green: 0.74, blue: 0.18)
        default: return Color(red: 0.16, green: 0.80, blue: 0.27)
        }
    }

    private func controlSymbol(_ action: WindowAction) -> String {
        switch action {
        case .quit: return "power"
        case .close: return "xmark"
        case .minimize: return "minus"
        default: return "arrow.up.left.and.arrow.down.right"
        }
    }

    private func trafficLight(_ action: WindowAction, color: Color, symbol: String) -> some View {
        Button { model.windowAction?(tile.index, action) } label: {
            Image(systemName: symbol).font(.system(size: 7, weight: .bold))
                .foregroundStyle(.black.opacity(0.65))
                .frame(width: 16, height: 16)
                .background(color, in: Circle())
                .overlay(Circle().strokeBorder(.black.opacity(0.13), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(model.isDemo || !action.canApply(to: window))
        .accessibilityLabel("\(actionLabel(action))：\(window.title)")
        .help(actionLabel(action))
    }

    private var highlightHeight: CGFloat {
        model.style == "icons" ? layout.iconSize + layout.edgeInset * 2 : tile.frame.height
    }

    private var displayTitle: String {
        if model.titleDisplay == "app" { return window.appName }
        let title = window.title.isEmpty ? window.appName : window.title
        if model.titleDisplay == "both", window.appName != title { return "\(window.appName) — \(title)" }
        return title
    }

    private var truncation: Text.TruncationMode {
        switch model.titleTruncation {
        case "head": return .head
        case "middle": return .middle
        default: return .tail
        }
    }

    private var accessibilityLabel: String {
        "\(window.appName)，\(window.title)\(window.isMinimized ? "，已最小化" : "")\(window.isHidden ? "，已隐藏" : "")"
    }

    private func actionLabel(_ action: WindowAction) -> String {
        switch action {
        case .minimize: return window.isMinimized ? "恢复窗口" : "最小化窗口"
        case .fullscreen: return window.isFullscreen ? "退出全屏" : "全屏窗口"
        case .hide: return window.isHidden ? "显示应用" : "隐藏应用"
        default: return action.title
        }
    }

    @ViewBuilder private func appIcon(size: CGFloat) -> some View {
        if let icon = window.icon {
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
        } else {
            Image(systemName: "app.fill").resizable().aspectRatio(contentMode: .fit)
                .foregroundStyle(.secondary).frame(width: size, height: size)
        }
    }
}
