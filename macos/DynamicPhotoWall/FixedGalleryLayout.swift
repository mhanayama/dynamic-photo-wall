import Foundation

nonisolated enum FixedGalleryLayout {
    struct Item: Sendable { var index: Int; var frame: CGRect }
    private struct Range { var min: CGFloat; var max: CGFloat }
    static func arrange(_ assets: [PhotoAsset], viewport v: CGSize, gap requestedGap: CGFloat,
                        displays: [CGRect] = [], pinned: Int? = nil) -> [Item] {
        guard !assets.isEmpty else { return [] }
        let horizontal = v.width >= v.height, length = horizontal ? v.width : v.height, cross = horizontal ? v.height : v.width
        let gap = min(requestedGap, min(length, cross) / 4), size = max(1, cross - 2 * gap)
        var active = Array(assets.indices)
        func pack() -> [Item] {
            var items: [Item] = [], used: [Range] = []; var cursor = gap
            for i in active {
                let asset = assets[i], extent = horizontal ? size * asset.aspectRatio : size / asset.aspectRatio
                guard extent <= length - 2 * gap else { continue }
                var ranges: [Range] = []
                if let f = FaceSafeLayout.bounds(asset), !displays.isEmpty {
                    for d in displays {
                        let margin = min(24, min(d.width, d.height) * 0.03)
                        let fc = horizontal ? f.minY : f.minX, fcs = horizontal ? f.height : f.width
                        let dc = horizontal ? d.minY : d.minX, dcs = horizontal ? d.height : d.width
                        guard gap + fc * size >= dc + margin, gap + (fc + fcs) * size <= dc + dcs - margin else { continue }
                        let fa = horizontal ? f.minX : f.minY, fas = horizontal ? f.width : f.height
                        let da = horizontal ? d.minX : d.minY, das = horizontal ? d.width : d.height
                        let low = max(gap, da + margin - fa * extent), high = min(length - gap - extent, da + das - margin - (fa + fas) * extent)
                        if low <= high { ranges.append(Range(min: low, max: high)) }
                    }
                } else { ranges = [Range(min: gap, max: length - gap - extent)] }
                guard let range = ranges.filter({ max(cursor, $0.min) <= $0.max }).min(by: { max(cursor, $0.min) < max(cursor, $1.min) }) else { continue }
                let at = max(cursor, range.min)
                items.append(Item(index: i, frame: horizontal ? CGRect(x: at, y: gap, width: extent, height: size) : CGRect(x: gap, y: at, width: size, height: extent)))
                used.append(Range(min: range.min - at, max: range.max - at)); cursor = at + extent + gap
            }
            if !items.isEmpty {
                let shift = min(used.map(\.max).min()!, max(used.map(\.min).max()!, (length - cursor) / 2))
                for i in items.indices { items[i].frame = items[i].frame.offsetBy(dx: horizontal ? shift : 0, dy: horizontal ? 0 : shift) }
            }
            return items
        }
        var result = pack()
        while let pinned, !result.contains(where: { $0.index == pinned }), active.count > 1 {
            let remove = active.filter { $0 != pinned }.max { abs($0 - pinned) < abs($1 - pinned) }!
            active.removeAll { $0 == remove }; result = pack()
        }
        if result.isEmpty, pinned == nil || active.count == 1 {
            let i = pinned ?? 0, p = assets[i]
            let w = horizontal ? size * p.aspectRatio : size, h = horizontal ? size : size / p.aspectRatio
            let centered = horizontal ? (v.width - w) / 2 : (v.height - h) / 2
            if let f = FaceSafeLayout.bounds(p), !displays.isEmpty {
                for d in displays {
                    let margin = min(24, min(d.width, d.height) * 0.03)
                    let crossStart = horizontal ? gap + f.minY * h : gap + f.minX * w
                    let crossEnd = horizontal ? gap + f.maxY * h : gap + f.maxX * w
                    guard crossStart >= (horizontal ? d.minY : d.minX) + margin, crossEnd <= (horizontal ? d.maxY : d.maxX) - margin else { continue }
                    let low = horizontal ? d.minX + margin - f.minX * w : d.minY + margin - f.minY * h
                    let high = horizontal ? d.maxX - margin - f.maxX * w : d.maxY - margin - f.maxY * h
                    if low <= high { let at = min(high, max(low, centered)); return [Item(index: i, frame: horizontal ? CGRect(x: at, y: gap, width: w, height: h) : CGRect(x: gap, y: at, width: w, height: h))] }
                }
            } else { return [Item(index: i, frame: horizontal ? CGRect(x: centered, y: gap, width: w, height: h) : CGRect(x: gap, y: centered, width: w, height: h))] }
        }
        return result
    }
}
