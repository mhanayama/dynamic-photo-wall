import Foundation
import CoreGraphics

/// Mirrors Windows FaceSafeLayout in physical, orientation-corrected coordinates.
nonisolated enum FaceSafeLayout {
    static func requiresProtection(_ viewport: CGSize, displays: [CGRect]) -> Bool {
        displays.count > 1 || (displays.count == 1 && displays[0] != CGRect(origin: .zero, size: viewport))
    }
    static func bounds(_ asset: PhotoAsset) -> CGRect? {
        let faces = (asset.faces ?? []).filter {
            [$0.x, $0.y, $0.width, $0.height].allSatisfy(\.isFinite) && $0.width > 0 && $0.height > 0
                && $0.x >= 0 && $0.y >= 0 && $0.x + $0.width <= 1.000001 && $0.y + $0.height <= 1.000001
        }.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        guard let first = faces.first else { return nil }
        return faces.dropFirst().reduce(first) { $0.union($1) }
    }
    static func margin(_ r: CGRect) -> CGFloat { min(24, min(r.width, r.height) * 0.03) }
    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { min(high, max(low, value)) }
    private struct Range: Hashable { let left: CGFloat; let right: CGFloat; let top: CGFloat; let bottom: CGFloat }

    static func gallery(_ assets: [PhotoAsset], viewport v: CGSize, gap: CGFloat, displays: [CGRect]) -> [CGRect] {
        let original = GalleryLayout.frames(assets: assets, in: v, gap: gap)
        guard requiresProtection(v, displays: displays), assets.contains(where: { bounds($0) != nil }), let first = original.first else { return original }
        let gap = min(gap, min(v.width / CGFloat(assets.count + 1) * 0.99, v.height / 4))
        func attempt(_ height: CGFloat) -> [CGRect]? {
            let widths = assets.map { height * $0.aspectRatio }
            var ranges: [[Range]] = []
            for i in assets.indices {
                var options: [Range] = []
                if let face = bounds(assets[i]) {
                    for display in displays {
                        let m = margin(display)
                        let left = max(gap, display.minX + m - face.minX * widths[i])
                        let right = min(v.width - gap - widths[i], display.maxX - m - face.maxX * widths[i])
                        let top = max(gap, display.minY + m - face.minY * height)
                        let bottom = min(v.height - gap - height, display.maxY - m - face.maxY * height)
                        if left <= right && top <= bottom { options.append(Range(left: left, right: right, top: top, bottom: bottom)) }
                    }
                } else { options = [Range(left: gap, right: v.width - gap - widths[i], top: gap, bottom: v.height - gap - height)] }
                ranges.append(options)
            }
            let rowWidth = widths.reduce(0, +) + gap * CGFloat(assets.count - 1)
            let centeredX = (v.width - rowWidth) / 2, centeredY = (v.height - height) / 2
            var rows = [Range(left: gap, right: v.width - gap - rowWidth, top: gap, bottom: v.height - gap - height)]
            var offset: CGFloat = 0
            for i in assets.indices {
                var seen: Set<Range> = []
                var intersections: [Range] = []
                for row in rows {
                    for r in ranges[i] {
                        let intersection = Range(left: max(row.left, r.left - offset), right: min(row.right, r.right - offset),
                                                 top: max(row.top, r.top), bottom: min(row.bottom, r.bottom))
                        if intersection.left <= intersection.right && intersection.top <= intersection.bottom,
                           seen.insert(intersection).inserted { intersections.append(intersection) }
                    }
                }
                func distance(_ r: Range) -> CGFloat { abs(clamp(centeredX, r.left, r.right) - centeredX) + abs(clamp(centeredY, r.top, r.bottom) - centeredY) }
                rows = Array(intersections.sorted { distance($0) < distance($1) }.prefix(128))
                offset += widths[i] + gap
                if rows.isEmpty { break }
            }
            if let row = rows.first {
                var x = clamp(centeredX, row.left, row.right)
                let y = clamp(centeredY, row.top, row.bottom)
                return widths.map { width in defer { x += width + gap }; return CGRect(x: x, y: y, width: width, height: height) }
            }
            var minimums: [CGFloat] = [], cursor = gap
            for i in assets.indices {
                guard let minimum = ranges[i].filter({ max(cursor, $0.left) <= $0.right }).map({ max(cursor, $0.left) }).min() else { return nil }
                minimums.append(minimum); cursor = minimum + widths[i] + gap
            }
            var next = v.width - gap
            var centered = (v.width - widths.reduce(0, +) - gap * CGFloat(assets.count - 1)) / 2
            let desired = widths.map { width in defer { centered += width + gap }; return centered }
            var result = Array(repeating: CGRect.zero, count: assets.count)
            for i in assets.indices.reversed() {
                let options = ranges[i].compactMap { r -> CGRect? in
                    let left = max(r.left, minimums[i]), right = min(r.right, next - widths[i])
                    return left <= right ? CGRect(x: clamp(desired[i], left, right), y: clamp(centeredY, r.top, r.bottom), width: widths[i], height: height) : nil
                }
                guard let best = options.min(by: {
                    abs($0.minX - desired[i]) + abs($0.minY - (v.height - height) / 2) < abs($1.minX - desired[i]) + abs($1.minY - (v.height - height) / 2)
                }) else { return nil }
                result[i] = best; next = best.minX - gap
            }
            return result
        }
        var high = first.height
        if let result = attempt(high) { return result }
        var low = high, best: [CGRect]?
        for _ in 0..<100 { low *= 0.85; best = attempt(low); if best != nil { break } }
        guard var result = best else { return original }
        for _ in 0..<20 {
            let middle = (low + high) / 2
            if let next = attempt(middle) { low = middle; result = next } else { high = middle }
        }
        return result
    }

    static func verticalPan(_ asset: PhotoAsset, viewport v: CGSize, settings s: WallSettings,
                            displays: [CGRect], original: WallMotionPlan) -> WallMotionPlan {
        guard let face = bounds(asset), let primary = s.faceAwarePanDirection ? WallMotionGeometry.primaryFace(asset) : asset.faces?.min(by: { $0.y < $1.y }) else { return original }
        let towardBottom = s.faceAwarePanDirection && primary.y + primary.height / 2 > 0.5
        func attempt(_ display: CGRect, _ width: CGFloat) -> WallMotionPlan? {
            let height = width / asset.aspectRatio, overflow = max(0, height - v.height), m = margin(display)
            let left = display.minX + m - face.minX * width, right = display.maxX - m - face.maxX * width
            guard left <= right else { return nil }
            let x = clamp(original.fromX, left, right)
            var frameTop = (v.height - min(v.height, height)) / 2
            if height < v.height {
                let top = max(0, display.minY + m - face.minY * height)
                let bottom = min(v.height - height, display.maxY - m - face.maxY * height)
                guard top <= bottom else { return nil }
                frameTop = clamp(frameTop, top, bottom)
            }
            let safeTop = max(-overflow, display.minY + m - frameTop - face.minY * height)
            let safeBottom = min(0, display.maxY - m - frameTop - face.maxY * height)
            guard safeTop <= safeBottom else { return nil }
            var start: CGFloat = towardBottom ? 0 : -overflow, end: CGFloat = towardBottom ? -overflow : 0
            if s.stopAtFace { end = clamp(display.minY + display.height * 0.3 - frameTop - (primary.y + primary.height / 2) * height, safeTop, safeBottom) }
            let pathMin = display.minY > 0 ? safeTop : -overflow, pathMax = display.maxY < v.height ? safeBottom : 0
            start = clamp(start, pathMin, pathMax); end = clamp(end, pathMin, pathMax)
            var result = original
            result.width = width; result.height = height; result.fromX = x; result.toX = x
            result.fromY = start; result.toY = end; result.frameTop = frameTop
            result.seconds = abs(end - start) > 0 ? max(0.1, abs(end - start) / s.panPixelsPerSecond) : 5
            return result
        }
        var candidates: [WallMotionPlan] = []
        for display in displays {
            var high = original.width, low = high
            var candidate = attempt(display, high)
            if candidate == nil {
                for _ in 0..<100 { low *= 0.85; candidate = attempt(display, low); if candidate != nil { break } }
                guard candidate != nil else { continue }
                for _ in 0..<20 {
                    let middle = (low + high) / 2
                    if let next = attempt(display, middle) { low = middle; candidate = next } else { high = middle }
                }
            }
            if let candidate { candidates.append(candidate) }
        }
        return candidates.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            return abs($0.fromX - original.fromX) < abs($1.fromX - original.fromX)
        }.first ?? original
    }
}
