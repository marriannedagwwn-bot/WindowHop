import AppKit

/// Read-only magnification of the captured image. It never focuses or operates
/// the real window, and cannot intercept the switcher's mouse or keyboard input.
final class SelectionPreviewController {
    private var panel: SelectionPreviewPanel?
    private var imageView: NSImageView?

    func show(image: NSImage, quartzFrame: CGRect, screen: NSScreen, below chooser: NSPanel) {
        if panel == nil {
            let preview = SelectionPreviewPanel(contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            preview.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
            preview.isOpaque = false
            preview.backgroundColor = .clear
            preview.hasShadow = true
            preview.ignoresMouseEvents = true
            preview.hidesOnDeactivate = false
            preview.isReleasedWhenClosed = false
            preview.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let imageView = NSImageView(frame: .zero)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 7
            imageView.layer?.masksToBounds = true
            imageView.setAccessibilityElement(false)
            preview.contentView = imageView
            panel = preview
            self.imageView = imageView
        }
        guard let panel else { return }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let frame = SelectionPreviewLayout.frame(quartzFrame: quartzFrame, imageSize: image.size,
            primaryScreenTop: primaryTop, screenVisibleFrame: screen.visibleFrame)
        imageView?.image = image
        panel.setFrame(frame, display: true)
        imageView?.frame = NSRect(origin: .zero, size: frame.size)
        // Never make this panel key. Its lower level also keeps the chooser and
        // any open context menu above the magnified image.
        panel.order(.below, relativeTo: chooser.windowNumber)
    }

    func hide() {
        panel?.orderOut(nil)
        imageView?.image = nil
    }

    deinit { imageView?.image = nil }
}

private final class SelectionPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum SelectionPreviewLayout {
    /// Preserve a visible window's position; fit an offscreen window on the
    /// presentation display without changing the selected application's state.
    static func frame(quartzFrame: CGRect, imageSize: CGSize, primaryScreenTop: CGFloat,
                      screenVisibleFrame visible: CGRect) -> CGRect {
        let hasGeometry = quartzFrame.minX.isFinite && quartzFrame.minY.isFinite &&
            quartzFrame.width.isFinite && quartzFrame.height.isFinite &&
            quartzFrame.width > 0 && quartzFrame.height > 0
        let converted = CGRect(x: quartzFrame.minX, y: primaryScreenTop - quartzFrame.maxY,
                               width: quartzFrame.width, height: quartzFrame.height)
        if hasGeometry, visible.contains(converted) { return converted }
        let source = hasGeometry ? quartzFrame.size :
            (imageSize.width.isFinite && imageSize.height.isFinite && imageSize.width > 0 && imageSize.height > 0
                ? imageSize : CGSize(width: 640, height: 400))
        let inset = min(24, min(visible.width, visible.height) * 0.05)
        let usable = visible.insetBy(dx: inset, dy: inset)
        let scale = min(1, usable.width / source.width, usable.height / source.height)
        let size = CGSize(width: max(1, (source.width * scale).rounded(.down)),
                          height: max(1, (source.height * scale).rounded(.down)))
        return CGRect(x: (visible.midX - size.width / 2).rounded(),
                      y: (visible.midY - size.height / 2).rounded(), width: size.width, height: size.height)
    }
}
