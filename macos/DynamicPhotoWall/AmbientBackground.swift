import AppKit
import CoreImage
import Observation
import os

nonisolated struct ForegroundPlacement: Sendable {
    let asset: PhotoAsset
    let frame: CGRect
    var opacity = 1.0
    var cornerRadius = 0.0
}

/// One geometry source drives both visible cards and the small ambient sample.
nonisolated enum ForegroundGeometry {
    static func placements(_ p: WallScenePresentation, settings s: WallSettings, viewport v: CGSize) -> [ForegroundPlacement] {
        Prepared(p, settings: s, viewport: v).placements(p)
    }

    struct Prepared {
        let settings: WallSettings
        let viewport: CGSize
        let motion: WallMotionPlan?
        let galleryFrames: [CGRect]

        init(_ p: WallScenePresentation, settings: WallSettings, viewport: CGSize) {
            self.settings = settings; self.viewport = viewport
            motion = [.verticalPan, .horizontalPan, .zoom].contains(p.scene.mode)
                ? p.scene.assets.first.flatMap {
                    FaceMotionSafety.plan(for: p.scene.mode, asset: $0, viewport: viewport, settings: settings,
                        reverse: p.scene.reverse, center: p.scene.zoomCenter, displayRegions: p.scene.displayRegions)
                } : nil
            galleryFrames = p.scene.mode == .gallery && p.galleryLayout == nil
                ? FixedGalleryLayout.arrange(p.slots.map(\.asset), viewport: viewport, gap: settings.gap,
                    displays: settings.avoidFaceDisplayBoundaries ? p.scene.displayRegions : []).map(\.frame) : []
        }

        func isMoving(_ p: WallScenePresentation) -> Bool {
            switch p.scene.mode {
            case .gallery:
                p.galleryLayout.map { p.elapsed < $0.startedAt + settings.fadeSeconds && $0.from != $0.to } == true
                    || p.slots.contains { ($0.appearing || $0.previousAsset != nil) && p.elapsed < $0.changedAt + settings.fadeSeconds }
                    || p.galleryRemoved.contains { p.elapsed < $0.at + settings.fadeSeconds }
            case .horizontalGallery: true
            case .verticalPan, .horizontalPan, .zoom: motion.map { p.elapsed < $0.seconds } ?? false
            }
        }

        func placements(_ p: WallScenePresentation) -> [ForegroundPlacement] {
            let s = settings, v = viewport
            switch p.scene.mode {
            case .gallery:
                let frames = p.galleryLayout?.frames(elapsed: p.elapsed, duration: s.fadeSeconds)
                    ?? galleryFrames
                var placements = p.galleryRemoved.map { item in ForegroundPlacement(asset: item.asset, frame: item.frame,
                    opacity: 1 - WallAnimation.ease((p.elapsed - item.at) / s.fadeSeconds), cornerRadius: s.cornerRadius) }
                placements += p.slots.enumerated().flatMap { index, slot -> [ForegroundPlacement] in
                    guard frames.indices.contains(index) else { return [] }
                    let frame = frames[index]
                    var result: [ForegroundPlacement] = []
                    if let previous = slot.previousAsset { result.append(.init(asset: previous, frame: slot.previousFrame ?? frame, cornerRadius: s.cornerRadius)) }
                    let fade = slot.previousAsset == nil && !slot.appearing ? 1 : WallAnimation.ease((p.elapsed - slot.changedAt) / s.fadeSeconds)
                    result.append(.init(asset: slot.asset, frame: frame, opacity: fade, cornerRadius: s.cornerRadius))
                    return result
                }
                return placements
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
                guard let plan = motion else { return [] }
                let progress = min(1, max(0, p.elapsed / plan.seconds))
                var frame = plan.frame(at: progress)
                if p.scene.mode == .verticalPan || p.scene.mode == .horizontalPan { frame.origin.y += plan.frameTop }
                let scale = plan.fromScale + (plan.toScale - plan.fromScale) * WallAnimation.ease(progress)
                frame.origin.x -= frame.width * (scale - 1) * plan.center.x
                frame.origin.y -= frame.height * (scale - 1) * plan.center.y
                frame.size.width *= scale; frame.size.height *= scale
                return [.init(asset: asset, frame: frame)]
            }
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
    private let signposter = OSSignposter(subsystem: "asia.dix.mhanayama.DynamicPhotoWall", category: "Ambient")
    private var transition = AmbientTransition()
    private var previousSize = CGSize.zero
    private var previousEnhanced = true

    func render(cards: [AmbientCard], viewport: CGSize, at: Double = 0, enhanceColors: Bool = true, smoothColors: Bool = true) -> DecodedPhoto? {
        let interval = signposter.beginInterval("Generate", id: signposter.makeSignpostID())
        defer { signposter.endInterval("Generate", interval) }
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
        if enhanceColors { AmbientColors.enhance(&result) }
        if previousEnhanced != enhanceColors || previousSize != CGSize(width: width, height: height) {
            transition = AmbientTransition()
        }
        if smoothColors { result = transition.push(result, at: at) }
        previousSize = CGSize(width: width, height: height); previousEnhanced = enhanceColors
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
    private(set) var textures = AmbientTextureTransition()
    private(set) var updateCount = 0
    typealias Render = @Sendable ([AmbientCard], CGSize, Double) async -> DecodedPhoto?
    @ObservationIgnored private let render: Render
    private var task: Task<Void, Never>?
    private var generation = 0
    private var latestElapsed = 0.0
    @ObservationIgnored private let geometry = ForegroundGeometryCache()
    @ObservationIgnored private var token: AmbientRefreshToken?
    @ObservationIgnored private var completed: AmbientCompositionKey?
    private struct Request {
        let key: AmbientCompositionKey
        let cards: [AmbientCard]
        let viewport: CGSize
        let elapsed: Double
    }
    @ObservationIgnored private var pending: Request?

    init(render: Render? = nil) {
        if let render { self.render = render }
        else {
            let processor = AmbientProcessor()
            self.render = { cards, viewport, elapsed in
                await processor.render(cards: cards, viewport: viewport, at: elapsed, smoothColors: false)
            }
        }
    }

    var isRendering: Bool { task != nil }

    func update(_ presentation: WallScenePresentation, settings: WallSettings, viewport: CGSize, images: PhotoImageStore, paused: Bool) {
        latestElapsed = presentation.elapsed
        guard !paused, settings.glassBackground else { stop(); return }
        let prepared = geometry.prepare(presentation, settings: settings, viewport: viewport)
        let token = AmbientRefreshToken(presentation, prepared: prepared, images: images)
        guard self.token != token else { return }
        let placements = prepared.placements(presentation)
            .filter { $0.opacity > 0 && $0.frame.intersects(CGRect(origin: .zero, size: viewport)) }
        let decoded = placements.compactMap { images.image(for: $0.asset) }
        // Do not consume invalidation while a required image is still decoding.
        guard !placements.isEmpty, decoded.count == placements.count else { return }
        let key = AmbientCompositionKey(placements: placements, images: decoded, viewport: viewport)
        if task == nil, key == completed { self.token = token; return }
        let cards = zip(placements, decoded).compactMap { item, image -> AmbientCard? in
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return AmbientCard(image: cgImage, frame: item.frame, opacity: item.opacity, radius: item.cornerRadius)
        }
        guard cards.count == placements.count else { return }
        self.token = token
        pending = Request(key: key, cards: cards, viewport: viewport, elapsed: presentation.elapsed)
        guard task == nil else { return } // Keep the latest event, including a final static frame.
        let generation = self.generation
        task = Task { [weak self, render] in
            while let self, let request = self.pending {
                self.pending = nil
                if request.key == self.completed { continue }
                let result = await render(request.cards, request.viewport, request.elapsed)
                guard !Task.isCancelled, generation == self.generation else { return }
                if let result {
                    // Color response now lives in the compositor. A static target
                    // reaches its final color without repeatedly generating pixels.
                    self.textures.push(result.image, at: self.latestElapsed, responseSeconds: 0.8)
                    self.image = NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
                    self.completed = request.key
                    self.updateCount += 1
                } else { self.token = nil }
            }
            guard let self, generation == self.generation else { return }
            self.task = nil
        }
    }

    func stop() {
        generation += 1; task?.cancel(); task = nil; pending = nil; token = nil
    }
}
