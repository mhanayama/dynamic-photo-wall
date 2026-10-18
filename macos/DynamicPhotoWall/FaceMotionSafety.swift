import Foundation
import CoreGraphics

nonisolated enum FaceMotionSafety {
    static func plan(for mode: WallMode, asset: PhotoAsset, viewport v: CGSize, settings s: WallSettings,
                     reverse: Bool = false, center: CGPoint = CGPoint(x: 0.5, y: 0.5), displayRegions: [CGRect] = []) -> WallMotionPlan? {
        let original = WallMotionGeometry.plan(for: mode, asset: asset, viewport: v, settings: s, reverse: reverse, center: center, displayRegions: displayRegions)
        guard [.verticalPan, .horizontalPan, .zoom].contains(mode), let face = FaceSafeLayout.bounds(asset) else { return original }
        let targets = displayRegions.isEmpty ? [CGRect(origin: .zero, size: v)] : displayRegions
        var plans: [WallMotionPlan] = []
        for d in targets {
            let margin = min(24, min(d.width, d.height) * 0.03), aw = d.width - 2 * margin, ah = d.height - 2 * margin
            guard aw > 0, ah > 0 else { continue }
            let cx = face.midX, cy = face.midY
            var p = original
            if mode == .zoom {
                let maximum = CGFloat(max(original.fromScale, original.toScale))
                let safe = min(aw / (face.width * original.width), ah / (face.height * original.height))
                let factor = min(1, safe / maximum)
                guard factor.isFinite, factor > 0, min(original.width, original.height) * factor >= 32 else { continue }
                p.fromScale *= Double(factor); p.toScale *= Double(factor); p.center = CGPoint(x: cx, y: cy)
                p.fromX = d.midX - cx * p.width; p.toX = p.fromX
                p.fromY = d.midY - cy * p.height; p.toY = p.fromY; plans.append(p); continue
            }
            let shrink = min(1, min(aw / (face.width * original.width), ah / (face.height * original.height)))
            p.width *= shrink; p.height *= shrink
            if mode == .verticalPan {
                let overflow = p.height - v.height; guard overflow > 20 else { continue }
                let low = max(-overflow, d.minY + margin - face.minY * p.height)
                let high = min(0, d.maxY - margin - face.maxY * p.height); guard low <= high else { continue }
                p.toY = min(high, max(low, d.midY - cy * p.height))
                p.fromY = original.fromY <= original.toY ? -overflow : 0
                func safeStart(_ value: CGFloat) -> CGFloat {
                    var value = value
                    if d.minY > 0 { value = max(value, low) }
                    if d.maxY < v.height { value = min(value, high) }
                    return value
                }
                p.fromY = safeStart(p.fromY)
                if abs(p.toY - p.fromY) <= 20 { p.fromY = safeStart(original.fromY <= original.toY ? 0 : -overflow) }
                guard abs(p.toY - p.fromY) > 20 else { continue }
                let left = d.minX + margin - face.minX * p.width
                let right = d.maxX - margin - face.maxX * p.width
                p.fromX = min(right, max(left, (v.width - p.width) / 2)); p.toX = p.fromX; p.frameTop = 0
                p.seconds = max(0.1, abs(p.toY - p.fromY) / s.panPixelsPerSecond)
            } else {
                let overflow = p.width - v.width; guard overflow > 20 else { continue }
                let low = max(-overflow, d.minX + margin - face.minX * p.width)
                let high = min(0, d.maxX - margin - face.maxX * p.width)
                let top = max(0, d.minY + margin - face.minY * p.height)
                let bottom = min(v.height - p.height, d.maxY - margin - face.maxY * p.height)
                guard low <= high, top <= bottom else { continue }
                p.toX = min(high, max(low, d.midX - cx * p.width))
                p.fromX = original.fromX >= original.toX ? 0 : -overflow
                if abs(p.toX - p.fromX) <= 20 { p.fromX = p.fromX == 0 ? -overflow : 0 }
                guard abs(p.toX - p.fromX) > 20 else { continue }
                p.frameTop = min(bottom, max(top, (v.height - p.height) / 2)); p.fromY = 0; p.toY = 0
                p.seconds = max(0.1, abs(p.toX - p.fromX) / s.panPixelsPerSecond)
            }
            plans.append(p)
        }
        return plans.sorted {
            let a = mode == .zoom ? max($0.fromScale, $0.toScale) : Double($0.width)
            let b = mode == .zoom ? max($1.fromScale, $1.toScale) : Double($1.width)
            if a != b { return a > b }
            return abs($0.fromX - original.fromX) + abs($0.fromY - original.fromY) < abs($1.fromX - original.fromX) + abs($1.fromY - original.fromY)
        }.first
    }
}
