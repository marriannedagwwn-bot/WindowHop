import AppKit
import QuartzCore
import SwiftUI

/// Opening moves the actual window, keeping native blur, shadow and hit regions
/// together. It never scales AppKit's backing layers or delays a commit/cancel.
final class ChooserPresentationAnimator: NSObject {
    private weak var window: NSWindow?
    private var destination: NSPoint?
    private var displayLink: CADisplayLink?
    private var began: CFTimeInterval = 0
    private var reduceMotion = false
    private var sampleCount = 0
    private var lowestAlpha: CGFloat = 1
    private var highestOffset: CGFloat = 0
    private let spring = Spring(duration: 0.30, bounce: 0.18)

    func prepare(_ window: NSWindow) {
        cancel()
        self.window = window
        destination = window.frame.origin
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        sampleCount = 0; lowestAlpha = 1; highestOffset = 0
        window.alphaValue = 0
        if !reduceMotion { window.setFrameOrigin(NSPoint(x: window.frame.minX, y: window.frame.minY - 8)) }
    }

    func start() {
        guard let window, destination != nil, window.isVisible else { cancel(); return }
        began = CACurrentMediaTime()
        let link = window.displayLink(target: self, selector: #selector(tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
        Diagnostics.log("motion.open.start reduced=\(reduceMotion)")
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard link === displayLink, let window, let destination, window.isVisible else { cancel(); return }
        if !reduceMotion && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            reduceMotion = true
            window.setFrameOrigin(destination)
        }
        let elapsed = CACurrentMediaTime() - began
        let duration = reduceMotion ? 0.12 : 0.38
        if elapsed >= duration { finish(); return }
        let fade = min(1, max(0, elapsed / 0.13))
        let alpha = CGFloat(1 - pow(1 - fade, 3))
        window.alphaValue = alpha
        let offset = reduceMotion ? 0 : CGFloat((spring.value(target: 1.0, time: elapsed) - 1) * 8)
        if !reduceMotion { window.setFrameOrigin(NSPoint(x: destination.x, y: destination.y + offset)) }
        sampleCount += 1; lowestAlpha = min(lowestAlpha, alpha); highestOffset = max(highestOffset, offset)
    }

    /// Cancelling is synchronous. No delayed completion can reopen a hidden list
    /// or move a later session after the user has already chosen a window.
    func cancel() {
        displayLink?.invalidate(); displayLink = nil
        if let window {
            window.alphaValue = 1
            if let destination { window.setFrameOrigin(destination) }
        }
        window = nil; destination = nil
    }

    private func finish() {
        Diagnostics.log("motion.open.finished samples=\(sampleCount) faded=\(lowestAlpha < 0.98) overshot=\(highestOffset > 0.02)")
        cancel()
    }

    deinit { displayLink?.invalidate() }
}
