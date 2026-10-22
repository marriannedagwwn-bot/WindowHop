import AppKit
import SwiftUI

/// Recreate the sliding layer when filtering or presentation geometry changes.
/// Ordinary selection changes keep its identity, preserving spring velocity.
struct SwitcherSelectionLayoutID: Hashable {
    let windowIDs: [String]
    let style: String
    let searchActive: Bool
    let cornerRadius: CGFloat
    let geometry: [CGFloat]

    init(windowIDs: [String], style: String, searchActive: Bool,
         cornerRadius: CGFloat, frames: [CGRect]) {
        self.windowIDs = windowIDs
        self.style = style
        self.searchActive = searchActive
        self.cornerRadius = cornerRadius
        geometry = frames.flatMap { [$0.minX, $0.minY, $0.width, $0.height] }
    }
}

/// Neutral, live material. The active layer is denser than the hover layer;
/// transparency is replaced only when the user's accessibility setting asks so.
struct SwitcherSelectionBackdrop: View {
    let cornerRadius: CGFloat
    let isDark: Bool
    let selected: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if reduceTransparency {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else if selected {
                shape.fill(.thickMaterial)
            } else {
                shape.fill(.ultraThinMaterial).opacity(0.42)
            }
            shape.fill(tint)
            shape.strokeBorder(border, lineWidth: contrast == .increased ? 1.5 : 0.7)
        }
        .shadow(color: .black.opacity(selected ? (isDark ? 0.16 : 0.10) : 0), radius: 3, y: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var tint: Color {
        if selected {
            return isDark ? .white.opacity(contrast == .increased ? 0.20 : 0.10) :
                .white.opacity(contrast == .increased ? 0.40 : 0.23)
        }
        return isDark ? .white.opacity(0.025) : .black.opacity(0.018)
    }

    private var border: Color {
        if contrast == .increased { return isDark ? .white.opacity(0.65) : .black.opacity(0.56) }
        if selected { return isDark ? .white.opacity(0.22) : .black.opacity(0.15) }
        return isDark ? .white.opacity(0.07) : .black.opacity(0.05)
    }
}
