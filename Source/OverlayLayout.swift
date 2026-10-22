import Foundation
import CoreGraphics

/// Independent geometry for the three switcher presentations. Coordinates are
/// top-left based so the same frames can be rendered in AppKit or SwiftUI.
struct OverlayTile: Equatable {
    let index: Int
    var frame: CGRect
    let previewSize: CGSize
}

struct OverlayLayout: Equatable {
    let tiles: [OverlayTile]
    let rows: [[Int]]
    let contentSize: CGSize
    let size: CGSize
    let padding: CGFloat
    let edgeInset: CGFloat
    let iconSize: CGFloat
    let fontSize: CGFloat
    let tileHeight: CGFloat
    let viewportHeight: CGFloat
    let resolvedSize: String
    var columns: Int { rows.map(\.count).max() ?? 1 }

    init(windowSizes: [CGSize] = [], available: CGSize = CGSize(width: 1440, height: 900),
         style: String = "thumbnails", size requestedSize: String = "medium", modernGlass: Bool = false,
         physicalScreenWidth: CGFloat? = nil) {
        let safeAvailable = CGSize(width: max(220, available.width), height: max(180, available.height))
        let widthFraction = Self.screenWidthFraction(physicalWidth: physicalScreenWidth)
        let maxPanelWidth = max(180, min(safeAvailable.width - 36, safeAvailable.width * widthFraction))
        let maxPanelHeight = max(130, safeAvailable.height * 0.8)
        let candidates = requestedSize == "auto" ? ["large", "medium", "small"] : [requestedSize]
        var result: OverlayLayout?
        for candidate in candidates {
            let next = Self.measure(windowSizes: windowSizes, maxPanelWidth: maxPanelWidth,
                                    maxPanelHeight: maxPanelHeight, style: style, size: candidate, modernGlass: modernGlass)
            result = next
            if next.contentSize.height <= next.viewportHeight { break }
        }
        self = result!
    }

    private init(tiles: [OverlayTile], rows: [[Int]], contentSize: CGSize, size: CGSize,
                 padding: CGFloat, edgeInset: CGFloat, iconSize: CGFloat, fontSize: CGFloat,
                 tileHeight: CGFloat, viewportHeight: CGFloat, resolvedSize: String) {
        self.tiles = tiles; self.rows = rows; self.contentSize = contentSize; self.size = size
        self.padding = padding; self.edgeInset = edgeInset; self.iconSize = iconSize
        self.fontSize = fontSize; self.tileHeight = tileHeight; self.viewportHeight = viewportHeight
        self.resolvedSize = resolvedSize
    }

    private static func measure(windowSizes: [CGSize], maxPanelWidth: CGFloat, maxPanelHeight: CGFloat,
                                style: String, size: String, modernGlass: Bool) -> OverlayLayout {
        let isSmall = size == "small", isLarge = size == "large"
        let font: CGFloat = isSmall ? 13 : (isLarge ? 16 : 14)
        let padding: CGFloat = style == "icons" ? 25 : (style == "thumbnails" && modernGlass ? 28 : 18)
        let edge: CGFloat = style == "icons" ? 5 : (style == "titles" ? 7 : 12)
        let desiredIcon: CGFloat = style == "icons" ? (isSmall ? 70 : (isLarge ? 150 : 110)) :
            (style == "titles" ? (isSmall ? 18 : (isLarge ? 30 : 24)) : (isSmall ? 16 : (isLarge ? 28 : 26)))
        let contentMaxWidth = max(130, maxPanelWidth - padding * 2)
        let contentMaxHeight = max(80, maxPanelHeight - padding * 2)
        let icon = min(desiredIcon, max(16, contentMaxWidth - edge * 2),
                       style == "icons" ? max(16, contentMaxHeight - edge * 2 - ceil(font * 1.3) - 10) : desiredIcon)
        let targetRows: CGFloat = isSmall ? 5 : (isLarge ? 3 : 4)
        let headerHeight = max(icon, ceil(font * 1.3))
        let tileHeight: CGFloat
        let previewMax: CGSize
        if style == "icons" {
            tileHeight = icon + edge * 2 + ceil(font * 1.3) + 10
            previewMax = CGSize(width: icon, height: icon)
        } else if style == "titles" {
            tileHeight = headerHeight + edge * 2
            previewMax = .zero
        } else {
            tileHeight = max(headerHeight + edge * 2 + 45,
                             floor((contentMaxHeight - (targetRows - 1)) / targetRows))
            previewMax = CGSize(width: max(80, min(contentMaxWidth, maxPanelWidth * 0.3) - edge * 2),
                                height: max(35, tileHeight - headerHeight - edge * 2 - 5))
        }
        let sizes = windowSizes.isEmpty ? [CGSize(width: 640, height: 400)] : windowSizes
        var tiles: [OverlayTile] = []
        var rows: [[Int]] = [[]]
        var cursor: CGFloat = 0
        var row = 0
        var widest: CGFloat = 0
        for (index, source) in sizes.enumerated() {
            let preview: CGSize
            let width: CGFloat
            if style == "icons" {
                preview = previewMax
                width = min(contentMaxWidth, icon + edge * 2)
            } else if style == "titles" {
                preview = .zero
                width = min(contentMaxWidth, isSmall ? 380 : (isLarge ? 600 : 480))
            } else {
                let validSource = source.width.isFinite && source.height.isFinite && source.width > 0 && source.height > 0
                    ? source : CGSize(width: 128, height: 128)
                let factor = min(1, previewMax.width / validSource.width, previewMax.height / validSource.height)
                preview = CGSize(width: max(1, (validSource.width * factor).rounded()),
                                 height: max(1, (validSource.height * factor).rounded()))
                width = min(contentMaxWidth, max(min(130, contentMaxWidth), preview.width + edge * 2))
            }
            if !rows[row].isEmpty && (style == "titles" || floor(cursor + width) > floor(contentMaxWidth)) {
                widest = max(widest, cursor - 1)
                cursor = 0; row += 1; rows.append([])
            }
            tiles.append(OverlayTile(index: index, frame: CGRect(x: cursor, y: CGFloat(row) * (tileHeight + 1),
                                                                width: width, height: tileHeight), previewSize: preview))
            rows[row].append(index)
            cursor += width + 1
        }
        widest = max(widest, cursor - 1)
        for rowIndexes in rows {
            guard let first = rowIndexes.first, let last = rowIndexes.last else { continue }
            let rowWidth = tiles[last].frame.maxX - tiles[first].frame.minX
            let offset = max(0, ((widest - rowWidth) / 2).rounded())
            for index in rowIndexes { tiles[index].frame.origin.x += offset }
        }
        let contentHeight = CGFloat(max(1, rows.count)) * tileHeight + CGFloat(max(0, rows.count - 1))
        let viewportHeight = min(contentMaxHeight, contentHeight)
        return OverlayLayout(tiles: windowSizes.isEmpty ? [] : tiles, rows: windowSizes.isEmpty ? [] : rows,
            contentSize: CGSize(width: widest, height: contentHeight),
            size: CGSize(width: widest + padding * 2, height: viewportHeight + padding * 2),
            padding: padding, edgeInset: edge, iconSize: icon, fontSize: font,
            tileHeight: tileHeight, viewportHeight: viewportHeight, resolvedSize: size)
    }

    /// Physical display width is in millimetres. Limit the comfortable viewing
    /// width on very large displays; missing/invalid EDID data uses the default.
    static func screenWidthFraction(physicalWidth: CGFloat?) -> CGFloat {
        guard let physicalWidth, physicalWidth.isFinite, physicalWidth > 0 else { return 0.9 }
        return min(0.9, max(0.45, 600 / physicalWidth))
    }

    /// Titles stay centred below their icon. At a document edge, shorten the
    /// available line symmetrically instead of shifting it towards the middle.
    /// Interior titles may still span neighbouring tiles without changing packing.
    func iconTitleFrame(for index: Int) -> CGRect {
        guard tiles.indices.contains(index) else { return .zero }
        let tile = tiles[index].frame
        let roomFromCenter = max(0, min(tile.midX, contentSize.width - tile.midX))
        let width = min(tile.width * 2, roomFromCenter * 2)
        let x = tile.midX - width / 2
        return CGRect(x: x, y: tile.minY + iconSize + edgeInset * 2 + 10,
                      width: width, height: ceil(fontSize * 1.3))
    }

    /// Preserve the horizontal position when moving between differently sized
    /// rows. The first/last row wraps, matching Tab's cyclic navigation.
    func navigationTarget(from selected: Int, vertical direction: Int) -> Int {
        guard tiles.indices.contains(selected), !rows.isEmpty,
              let currentRow = rows.firstIndex(where: { $0.contains(selected) }) else { return selected }
        let targetRow = ((currentRow + (direction < 0 ? -1 : 1)) % rows.count + rows.count) % rows.count
        let center = tiles[selected].frame.midX
        return rows[targetRow].min { abs(tiles[$0].frame.midX - center) < abs(tiles[$1].frame.midX - center) } ?? selected
    }
}
