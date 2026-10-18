import AppKit

/// App coordinates are physical pixels, top-left based, independent of NSScreen points.
nonisolated struct WallDisplay: Codable, Equatable, Identifiable, Sendable {
    var id: UInt32
    var name: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var enabled = true
    var groupID: String? = nil
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    init(id: UInt32, name: String, x: Double = 0, y: Double = 0, width: Double, height: Double,
         enabled: Bool = true, groupID: String? = nil) {
        self.id = id; self.name = name; self.x = x; self.y = y
        self.width = width; self.height = height; self.enabled = enabled; self.groupID = groupID
    }
}

nonisolated enum WallGroupID: Hashable, Sendable {
    case named(String), independent(UInt32)
}

nonisolated struct WallDisplayGroup: Equatable, Identifiable, Sendable {
    let id: WallGroupID
    let displays: [WallDisplay]
    let bounds: CGRect
    var name: String {
        switch id { case .named(let name): name; case .independent: "独立して表示" }
    }
    var viewport: CGSize { bounds.size }
    func region(_ display: WallDisplay) -> CGRect {
        display.rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
    }
}

nonisolated enum DisplayLayout {
    static func cleanName(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }
    static func groupNames(_ names: [String], displays: [WallDisplay]) -> [String] {
        var result: [String] = []
        for name in names + displays.compactMap(\.groupID) {
            if let name = cleanName(name), !result.contains(name) { result.append(name) }
        }
        return result
    }
    static func groups(_ displays: [WallDisplay]) throws -> [WallDisplayGroup] {
        guard Set(displays.map(\.id)).count == displays.count else { throw LayoutError.invalid }
        var keys: [WallGroupID] = []
        var members: [WallGroupID: [WallDisplay]] = [:]
        for display in displays where display.enabled {
            guard [display.x, display.y, display.width, display.height].allSatisfy(\.isFinite),
                  display.width > 0, display.height > 0, display.width <= 32768, display.height <= 32768,
                  abs(display.x) <= 1e9, abs(display.y) <= 1e9 else { throw LayoutError.invalid }
            let key = cleanName(display.groupID).map(WallGroupID.named) ?? .independent(display.id)
            if members[key] == nil { keys.append(key) }
            members[key, default: []].append(display)
        }
        return try keys.map { key in
            let list = members[key]!
            let bounds = list.dropFirst().reduce(list[0].rect) { $0.union($1.rect) }
            guard bounds.width <= 32768, bounds.height <= 32768 else { throw LayoutError.invalid }
            return WallDisplayGroup(id: key, displays: list, bounds: bounds)
        }
    }
    enum LayoutError: LocalizedError {
        case invalid, noConnectedDisplay
        var errorDescription: String? {
            switch self {
            case .invalid: "画面の寸法・配置を確認してください。グループの幅と高さは32768px以内です。"
            case .noConnectedDisplay: "選択したディスプレイが接続されていません。"
            }
        }
    }

    @MainActor static func detected(_ screen: ScreenDescriptor, screens: [ScreenDescriptor], enabled: Bool = false) -> WallDisplay {
        let origin = physicalOrigins(screens)[screen.id] ?? .zero
        return WallDisplay(id: screen.id, name: screen.name, x: origin.x, y: origin.y,
                           width: Double(screen.pixelWidth), height: Double(screen.pixelHeight), enabled: enabled)
    }

    /// Reset app coordinates from OS adjacency, preserving each panel's own
    /// physical dimensions. A global Retina multiplier would overlap mixed-DPI panels.
    @MainActor static func physicalOrigins(_ screens: [ScreenDescriptor]) -> [UInt32: CGPoint] {
        guard let primary = screens.first else { return [:] }
        let top = primary.frame.maxY
        func logical(_ s: ScreenDescriptor) -> CGRect {
            CGRect(x: s.frame.minX, y: top - s.frame.maxY, width: s.frame.width, height: s.frame.height)
        }
        func separation(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let dx = max(0, a.minX - b.maxX, b.minX - a.maxX)
            let dy = max(0, a.minY - b.maxY, b.minY - a.maxY)
            return hypot(dx, dy)
        }
        func coordinate(_ low: CGFloat, _ high: CGFloat, _ anchorLow: CGFloat, _ anchorHigh: CGFloat,
                        _ pixels: CGFloat, _ anchorPixels: CGFloat, _ origin: CGFloat) -> CGFloat {
            let scale = anchorPixels / max(1, anchorHigh - anchorLow)
            if low >= anchorHigh { return origin + anchorPixels + (low - anchorHigh) * scale }
            if high <= anchorLow { return origin - pixels - (anchorLow - high) * scale }
            if abs(low - anchorLow) < 0.5 { return origin }
            if abs(high - anchorHigh) < 0.5 { return origin + anchorPixels - pixels }
            if abs((low + high) - (anchorLow + anchorHigh)) < 0.5 { return origin + (anchorPixels - pixels) / 2 }
            return origin + (low - anchorLow) * scale
        }
        var placed = [primary]
        var result: [UInt32: CGPoint] = [primary.id: .zero]
        var remaining = Array(screens.dropFirst())
        while !remaining.isEmpty {
            var bestIndex = 0, anchor = placed[0], distance = CGFloat.infinity
            for (i, candidate) in remaining.enumerated() {
                for known in placed {
                    let d = separation(logical(candidate), logical(known))
                    if d < distance { bestIndex = i; anchor = known; distance = d }
                }
            }
            let screen = remaining.remove(at: bestIndex), r = logical(screen), a = logical(anchor)
            let origin = result[anchor.id] ?? .zero
            result[screen.id] = CGPoint(
                x: coordinate(r.minX, r.maxX, a.minX, a.maxX, CGFloat(screen.pixelWidth), CGFloat(anchor.pixelWidth), origin.x),
                y: coordinate(r.minY, r.maxY, a.minY, a.maxY, CGFloat(screen.pixelHeight), CGFloat(anchor.pixelHeight), origin.y))
            placed.append(screen)
        }
        return result
    }

    static func snapped(_ rect: CGRect, against others: [CGRect], threshold: CGFloat) -> CGPoint {
        func gap(_ a: CGFloat, _ sizeA: CGFloat, _ b: CGFloat, _ sizeB: CGFloat) -> CGFloat {
            max(0, max(a, b) - min(a + sizeA, b + sizeB))
        }
        func closest(_ value: CGFloat, _ targets: [CGFloat]) -> CGFloat {
            targets.filter { abs($0 - value) <= threshold }.min {
                abs($0 - value) == abs($1 - value) ? $0 < $1 : abs($0 - value) < abs($1 - value)
            } ?? value
        }
        let horizontal = others.filter { gap(rect.minY, rect.height, $0.minY, $0.height) <= threshold }.flatMap {
            [$0.minX - rect.width, $0.maxX, $0.minX, $0.maxX - rect.width, $0.midX - rect.width / 2]
        }
        let vertical = others.filter { gap(rect.minX, rect.width, $0.minX, $0.width) <= threshold }.flatMap {
            [$0.minY - rect.height, $0.maxY, $0.minY, $0.maxY - rect.height, $0.midY - rect.height / 2]
        }
        return CGPoint(x: closest(rect.minX, horizontal), y: closest(rect.minY, vertical))
    }
}
