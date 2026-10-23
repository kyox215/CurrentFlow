import Foundation
import CoreGraphics

enum PanelPlacement {
    static let preferredSize = CGSize(width: 420, height: 300)

    // All rectangles are global AppKit coordinates; a second display can have
    // a negative origin. visibleFrame already excludes the menu bar and Dock.
    static func safeBounds(screen: CGRect, visible: CGRect, safeTop: CGFloat, margin: CGFloat = 10) -> CGRect {
        let usable = screen.intersection(visible)
        guard !usable.isNull, usable.width > 0, usable.height > 0 else { return .zero }
        let top = min(usable.maxY, screen.maxY - max(0, safeTop))
        let inset = min(margin, usable.width / 4, max(0, top - usable.minY) / 4)
        return CGRect(x: usable.minX + inset, y: usable.minY + inset,
                      width: max(0, usable.width - inset * 2),
                      height: max(0, top - usable.minY - inset * 2))
    }

    static func frame(in safe: CGRect, anchor: CGRect?, desired: CGSize = preferredSize) -> CGRect {
        let width = min(max(0, desired.width), safe.width)
        let height = min(max(0, desired.height), safe.height)
        let targetX = (anchor?.maxX ?? safe.maxX) - width
        let x = min(max(targetX, safe.minX), safe.maxX - width)
        let top = min(anchor?.minY ?? safe.maxY, safe.maxY)
        let y = min(max(top - height, safe.minY), safe.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height).integral.intersection(safe)
    }

    static func menuItemFits(_ item: CGRect, screen: CGRect, unobscuredTopAreas: [CGRect]) -> Bool {
        guard !item.isEmpty else { return false }
        if unobscuredTopAreas.isEmpty { return screen.insetBy(dx: -1, dy: -1).contains(item) }
        return unobscuredTopAreas.contains { $0.insetBy(dx: -1, dy: -1).contains(item) }
    }
}
