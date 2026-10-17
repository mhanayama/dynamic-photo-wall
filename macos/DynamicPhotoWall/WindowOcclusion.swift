import AppKit

nonisolated struct ForegroundWindow: Sendable {
    let ownerPID: Int32
    let layer: Int
    let alpha: Double
    let bounds: CGRect
}

nonisolated enum WindowOcclusion {
    static func covers(_ target: CGRect, windows: [ForegroundWindow], foregroundPID: Int32, ownPID: Int32) -> Bool {
        guard foregroundPID != ownPID, !target.isEmpty else { return false }
        // CGWindowList is front-to-back. Match Windows' foreground-window
        // behavior rather than combining other windows owned by the same app.
        guard let window = windows.first(where: { $0.ownerPID == foregroundPID && $0.layer == 0 && $0.alpha > 0.95 }) else { return false }
        return window.bounds.insetBy(dx: -2, dy: -2).contains(target)
    }

    @MainActor static func isCovered(_ screen: ScreenDescriptor) -> Bool { isCovered([screen]) }

    @MainActor static func isCovered(_ screens: [ScreenDescriptor]) -> Bool {
        guard !screens.isEmpty else { return false }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let windows = info.compactMap { value -> ForegroundWindow? in
            guard let owner = value[kCGWindowOwnerPID as String] as? Int32,
                  let layer = value[kCGWindowLayer as String] as? Int,
                  let raw = value[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
            return ForegroundWindow(ownerPID: owner, layer: layer,
                alpha: value[kCGWindowAlpha as String] as? Double ?? 1, bounds: bounds)
        }
        // CGWindow bounds use top-left coordinates; NSScreen uses bottom-left.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screens[0].frame.maxY
        return screens.allSatisfy { screen in
            let visible = screen.visibleFrame ?? screen.frame
            let target = CGRect(x: visible.minX, y: primaryTop - visible.maxY, width: visible.width, height: visible.height)
            return covers(target, windows: windows, foregroundPID: pid, ownPID: ProcessInfo.processInfo.processIdentifier)
        }
    }
}
