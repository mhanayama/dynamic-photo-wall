import AppKit
import CoreImage
import Observation

nonisolated struct ForegroundPlacement: Sendable {
    let asset: PhotoAsset
    let frame: CGRect
    var opacity = 1.0
    var cornerRadius = 0.0
}

/// One geometry source drives both visible cards and the small ambient sample.
nonisolated enum ForegroundGeometry {
    static func placements(_ p: WallScenePresentation, settings s: WallSettings, viewport v: CGSize) -> [ForegroundPlacement] {
        switch p.scene.mode {
        case .gallery:
            let frames = p.galleryLayout?.frames(elapsed: p.elapsed, duration: s.fadeSeconds)
                ?? FaceSafeLayout.gallery(p.slots.map(\.asset), viewport: v, gap: s.gap, displays: s.avoidFaceDisplayBoundaries ? p.scene.displayRegions : [])
            return p.slots.enumerated().flatMap { index, slot -> [ForegroundPlacement] in
                guard frames.indices.contains(index) else { return [] }
                let frame = frames[index]
                var result: [ForegroundPlacement] = []
                if let previous = slot.previousAsset { result.append(.init(asset: previous, frame: frame, cornerRadius: s.cornerRadius)) }
                let fade = slot.previousAsset == nil ? 1 : WallAnimation.ease((p.elapsed - slot.changedAt) / s.fadeSeconds)
                result.append(.init(asset: slot.asset, frame: frame, opacity: fade, cornerRadius: s.cornerRadius))
                return result
            }
        case .horizontalGallery:
            let height = max(1, v.height - 2 * s.gap)
            var x = s.gap - p.scrollDistance
            return p.scene.assets.map { asset in
                let width = height * asset.aspectRatio
                defer { x += width + s.gap }
                return .init(asset: asset, frame: CGRect(x: x, y: s.gap, width: width, height: height), cornerRadius: s.cornerRadius)
            }
        case .verticalPan, .horizontalPan, .zoom:
            guard let asset = p.scene.assets.first else { return [] }
            let plan = WallMotionGeometry.plan(for: p.scene.mode, asset: asset, viewport: v, settings: s,
                                               reverse: p.scene.reverse, center: p.scene.zoomCenter, displayRegions: p.scene.displayRegions)
            let progress = min(1, max(0, p.elapsed / plan.seconds))
            var frame = plan.frame(at: progress)
            if p.scene.mode == .verticalPan { frame.origin.y += plan.frameTop }
            let scale = plan.fromScale + (plan.toScale - plan.fromScale) * WallAnimation.ease(progress)
            frame.origin.x -= frame.width * (scale - 1) * plan.center.x
            frame.origin.y -= frame.height * (scale - 1) * plan.center.y
            frame.size.width *= scale; frame.size.height *= scale
            return [.init(asset: asset, frame: frame)]
        }
    }
}

nonisolated struct AmbientCard: @unchecked Sendable {
    let image: CGImage
    let frame: CGRect
    let opacity: Double
    let radius: Double
}

actor AmbientProcessor {
    private let context = CIContext(options: [.useSoftwareRenderer: true])
    private var previous: Data?
    private var previousSize = CGSize.zero

    func render(cards: [AmbientCard], viewport: CGSize) -> DecodedPhoto? {
        guard !Task.isCancelled, viewport.width > 0, viewport.height > 0 else { return nil }
        let scale = 160 / max(viewport.width, viewport.height)
        let width = max(1, Int(ceil(viewport.width * scale))), height = max(1, Int(ceil(viewport.height * scale)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let color = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let canvas = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: color, bitmapInfo: info) else { return false }
            canvas.translateBy(x: 0, y: CGFloat(height)); canvas.scaleBy(x: scale, y: -scale)
            canvas.interpolationQuality = .low
            for card in cards where card.opacity > 0 && card.frame.intersects(CGRect(origin: .zero, size: viewport)) {
                canvas.saveGState()
                canvas.addPath(CGPath(roundedRect: card.frame, cornerWidth: card.radius, cornerHeight: card.radius, transform: nil))
                canvas.clip()
                canvas.setAlpha(card.opacity)
                let ratio = min(card.frame.width / CGFloat(card.image.width), card.frame.height / CGFloat(card.image.height))
                let size = CGSize(width: CGFloat(card.image.width) * ratio, height: CGFloat(card.image.height) * ratio)
                let rect = CGRect(x: card.frame.midX - size.width / 2, y: card.frame.midY - size.height / 2, width: size.width, height: size.height)
                canvas.translateBy(x: rect.minX, y: rect.maxY); canvas.scaleBy(x: 1, y: -1)
                canvas.draw(card.image, in: CGRect(origin: .zero, size: size))
                canvas.restoreGState()
            }
            return true
        }
        guard drawn, Self.extendPadding(&pixels, width: width, height: height), !Task.isCancelled,
              let source = Self.image(pixels, width: width, height: height),
              let blurred = context.createCGImage(CIImage(cgImage: source).clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 7]), from: CGRect(x: 0, y: 0, width: width, height: height)) else { return nil }
        var result = [UInt8](repeating: 0, count: pixels.count)
        result.withUnsafeMutableBytes { bytes in
            guard let canvas = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: color, bitmapInfo: info) else { return }
            canvas.draw(blurred, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard !Task.isCancelled else { return nil }
        if previousSize == CGSize(width: width, height: height), let previous, previous.count == result.count {
            for i in result.indices { result[i] = UInt8((Int(result[i]) + Int(previous[i])) / 2) }
        }
        previous = Data(result); previousSize = CGSize(width: width, height: height)
        return Self.image(result, width: width, height: height).map { DecodedPhoto(image: $0) }
    }

    nonisolated static func image(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    nonisolated static func extendPadding(_ pixels: inout [UInt8], width: Int, height: Int) -> Bool {
        var rows: [Int] = []
        for y in 0..<height {
            var valid: [Int] = []
            for x in 0..<width {
                let i = (y * width + x) * 4, alpha = Int(pixels[(y * width + x) * 4 + 3])
                guard alpha >= 16 else { continue }
                for c in 0..<3 { pixels[i + c] = UInt8(min(255, Int(pixels[i + c]) * 255 / alpha)) }
                pixels[i + 3] = 255; valid.append(x)
            }
            guard !valid.isEmpty else { continue }
            rows.append(y)
            var nearest = 0
            for x in 0..<width {
                while nearest + 1 < valid.count && abs(valid[nearest + 1] - x) < abs(valid[nearest] - x) { nearest += 1 }
                let i = (y * width + x) * 4
                if pixels[i + 3] < 16 {
                    for c in 0..<4 { pixels[i + c] = pixels[(y * width + valid[nearest]) * 4 + c] }
                }
            }
        }
        guard !rows.isEmpty else { return false }
        var nearest = 0
        for y in 0..<height {
            while nearest + 1 < rows.count && abs(rows[nearest + 1] - y) < abs(rows[nearest] - y) { nearest += 1 }
            if rows[nearest] != y {
                for x in 0..<(width * 4) { pixels[y * width * 4 + x] = pixels[rows[nearest] * width * 4 + x] }
            }
        }
        return true
    }
}

@MainActor
@Observable
final class AmbientSampler {
    private(set) var image: NSImage?
    private(set) var updateCount = 0
    private let processor = AmbientProcessor()
    private var task: Task<Void, Never>?
    private var busy = false
    private var generation = 0

    func update(_ presentation: WallScenePresentation, settings: WallSettings, viewport: CGSize, images: PhotoImageStore, paused: Bool) {
        guard !paused, !busy else { return }
        let cards = ForegroundGeometry.placements(presentation, settings: settings, viewport: viewport).compactMap { item -> AmbientCard? in
            guard let image = images.image(for: item.asset)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return AmbientCard(image: image, frame: item.frame, opacity: item.opacity, radius: item.cornerRadius)
        }
        busy = true
        let generation = self.generation
        task = Task { [weak self, processor] in
            let result = await processor.render(cards: cards, viewport: viewport)
            guard let self, !Task.isCancelled, generation == self.generation else { return }
            self.busy = false
            if let result {
                self.image = NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
                self.updateCount += 1
            }
        }
    }

    func stop() { generation += 1; task?.cancel(); task = nil; busy = false }
}
