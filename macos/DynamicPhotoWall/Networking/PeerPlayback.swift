import AppKit
import ImageIO
import SwiftUI

@MainActor final class PNScenePlanner: PNScenePlanning {
    private let cache: PNPhotoCache
    var readOriginal: ((PNAssetKey) async throws -> Data?)?
    private var planners: [UUID: WallScenePlanner] = [:]
    private var configurations: [UUID: (session: UUID, revision: Int64)] = [:]
    init(cache: PNPhotoCache) { self.cache = cache }
    func prepare(wall: PNSnapshot, group: UUID, photos: [PNPhoto]) async throws -> PNScene? {
        let displays = wall.displays.filter { $0.selected && $0.unit == group }; guard !displays.isEmpty else { return nil }
        let settings = try wall.playback.applying()
        let left = displays.map(\.x).min()!, top = displays.map(\.y).min()!
        let width = displays.map { Double($0.x) + Double($0.width) }.max()! - Double(left)
        let height = displays.map { Double($0.y) + Double($0.height) }.max()! - Double(top)
        let nativeDisplays = displays.enumerated().map { index, d in WallDisplay(id: UInt32(index + 1), name: d.id, x: Double(d.x), y: Double(d.y), width: Double(d.width), height: Double(d.height), groupID: group.uuidString) }
        let nativeGroup = WallDisplayGroup(id: .named(group.uuidString), displays: nativeDisplays, bounds: CGRect(x: left, y: top, width: Int(width), height: Int(height)))
        let usable = photos.filter { $0.faceMetadata.state != "pending" }
        let assets = usable.map { PhotoAsset(url: URL(string: "peer-cache://image/\($0.key.opaqueId)")!, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight, fileSize: Int64($0.byteLength), faces: $0.faceMetadata.faces.map { FaceRegion(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }) }
        let byURL = Dictionary(uniqueKeysWithValues: zip(assets.map(\.url), usable))
        let planner = planners[group] ?? WallScenePlanner(); planners[group] = planner
        if configurations[group]?.session != wall.sessionId || configurations[group]?.revision != wall.revision {
            planner.resetModeHistory(); configurations[group] = (wall.sessionId, wall.revision)
        }
        // Shared galleries have finite timelines and must renew even when the
        // same mode wins again. Only local playback has a live update loop.
        guard let surfaces = planner.nextGroup(assets: assets, settings: settings, group: nativeGroup,
            connected: Set(nativeDisplays.map(\.id)), allowGalleryRepeat: true), let first = surfaces.first else { return nil }
        var placements: [PNPlacement] = []; var duration = 0.0
        for surface in surfaces {
            try Task.checkCancellation()
            let display = surface.displayID.flatMap { id in displays.indices.contains(Int(id) - 1) ? displays[Int(id) - 1] : nil }
            let ox = Double(display.map { $0.x - left } ?? 0), oy = Double(display.map { $0.y - top } ?? 0)
            let v = surface.viewport; let scene = surface.scene
            var clip = PNRect(x: ox, y: oy, width: v.width, height: v.height)
            func add(_ asset: PhotoAsset, width: Double, height: Double, fromX: Double, fromY: Double, toX: Double, toY: Double,
                     fromScale: Double = 1, toScale: Double = 1, centerX: Double = 0.5, centerY: Double = 0.5,
                     start: Double = 0, motion: Double, visibleFrom: Double = 0, visibleUntil: Double, fade: Double = 0, corner: Double = 0, ease: Bool = false) {
                guard let photo = byURL[asset.url] else { return }
                placements.append(PNPlacement(id: placements.count, asset: photo.key, displayId: display?.id, clip: clip, width: width, height: height,
                    fromX: fromX + ox, fromY: fromY + oy, toX: toX + ox, toY: toY + oy, fromScale: fromScale, toScale: toScale, centerX: centerX, centerY: centerY,
                    startSeconds: start, motionSeconds: motion, visibleFrom: visibleFrom, visibleUntil: visibleUntil, fadeSeconds: fade, cornerRadius: corner, ease: ease))
            }
            let seconds: Double
            switch scene.mode {
            case .gallery:
                seconds = max(90, settings.galleryMaxSeconds * 3)
            case .horizontalGallery:
                seconds = max(120, settings.galleryMaxSeconds * 3)
                let h = max(1, v.height - 2 * settings.gap); var x = settings.gap; var index = 0
                while x < v.width + seconds * settings.galleryScrollPixelsPerSecond && index < 128 {
                    let chosen = index < scene.assets.count ? scene.assets[index] : planner.replacement(assets: assets, settings: settings, excluding: []) ?? scene.assets[0]
                    let w = h * chosen.aspectRatio
                    add(chosen, width: w, height: h, fromX: x, fromY: (v.height - h) / 2, toX: x - seconds * settings.galleryScrollPixelsPerSecond, toY: (v.height - h) / 2, motion: seconds, visibleUntil: seconds, corner: settings.cornerRadius)
                    x += w + settings.gap; index += 1
                }
            default:
                guard let asset = scene.assets.first else { continue }
                guard let motion = FaceMotionSafety.plan(for: scene.mode, asset: asset, viewport: v, settings: settings, reverse: scene.reverse, center: scene.zoomCenter, displayRegions: scene.displayRegions) else { return nil }
                seconds = motion.seconds + (scene.mode == .verticalPan && settings.stopAtFace && !(asset.faces ?? []).isEmpty ? 3 : 0)
                let frameTop = scene.mode == .verticalPan || scene.mode == .horizontalPan ? motion.frameTop : 0
                if scene.mode == .verticalPan { clip = PNRect(x: ox + motion.fromX, y: oy + frameTop, width: motion.width, height: min(v.height, motion.height)) }
                add(asset, width: motion.width, height: motion.height, fromX: motion.fromX, fromY: motion.fromY + frameTop, toX: motion.toX, toY: motion.toY + frameTop, fromScale: motion.fromScale, toScale: motion.toScale, centerX: motion.center.x, centerY: motion.center.y, motion: motion.seconds, visibleUntil: seconds, ease: scene.mode == .zoom)
            }
            duration = max(duration, seconds)
        }
        if first.scene.mode == .gallery {
            let inputs = surfaces.map { GalleryTimeline.Surface(assets: $0.scene.assets, viewport: $0.viewport,
                displays: settings.avoidFaceDisplayBoundaries ? $0.scene.displayRegions : []) }
            let segments = GalleryTimeline.build(inputs, duration: duration, settings: settings, replacement: { active in
                planner.replacement(assets: assets, settings: settings, excluding: Set(active.map(\.url)))
            }, candidates: assets)
            for s in segments {
                let surface = surfaces[s.surface]
                let display = surface.displayID.flatMap { id in displays.indices.contains(Int(id) - 1) ? displays[Int(id) - 1] : nil }
                let x = Double(display.map { $0.x - left } ?? 0), y = Double(display.map { $0.y - top } ?? 0)
                guard let photo = byURL[s.asset.url] else { continue }
                var p = PNPlacement(id: placements.count, asset: photo.key, displayId: display?.id,
                    clip: PNRect(x: x, y: y, width: surface.viewport.width, height: surface.viewport.height), width: s.to.width, height: s.to.height,
                    fromX: x + s.from.minX, fromY: y + s.from.minY, toX: x + s.to.minX, toY: y + s.to.minY,
                    fromScale: 1, toScale: 1, centerX: 0.5, centerY: 0.5, startSeconds: s.at, motionSeconds: s.motion,
                    visibleFrom: s.at, visibleUntil: s.until, fadeSeconds: 0, cornerRadius: settings.cornerRadius, ease: true)
                p.fadeInSeconds = s.fadeIn; p.fadeOutSeconds = s.fadeOut; placements.append(p)
            }
            guard !placements.isEmpty else { return nil }
        }
        if first.scene.mode != .gallery { for index in placements.indices { placements[index].visibleUntil = duration } }
        let mode = first.scene.mode == .horizontalGallery ? "galleryScroll" : first.scene.mode.rawValue
        var plan = PNScene(id: UUID(), groupId: group, sessionId: wall.sessionId, settingsRevision: wall.revision, mode: mode, viewport: PNSize(width: width, height: height), displays: displays, duration: duration, fadeSeconds: min(settings.fadeSeconds, duration), background: settings.backgroundHex, placements: placements, ambient: [])
        if settings.glassBackground { plan.ambient = try await ambient(plan) }
        try plan.validate(); return plan
    }
    private func ambient(_ plan: PNScene) async throws -> [PNAmbient] {
        let ids = Set(plan.placements.map(\.displayId)); let samples = max(2, min(24, 64 / max(1, ids.count)))
        var images: [String: DecodedPhoto] = [:]
        for key in Set(plan.placements.map(\.asset)) {
            let bytes: Data?
            if let readOriginal { bytes = try await readOriginal(key) }
            else { bytes = try await cache.read(key) }
            if let bytes, let image = await Task.detached(priority: .utility, operation: { PNImageDecode.decode(bytes, maximum: 128) }).value { images[key.opaqueId] = image }
        }
        var frames: [PNAmbient] = []
        for id in ids {
            let processor = AmbientProcessor()
            let display = plan.displays.first { $0.id == id }
            let size = display.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: plan.viewport.width, height: plan.viewport.height)
            let ox = Double(display.map { $0.x - plan.displays.map(\.x).min()! } ?? 0), oy = Double(display.map { $0.y - plan.displays.map(\.y).min()! } ?? 0)
            for index in 0..<samples {
                let at = Double(index) / Double(samples - 1) * plan.duration
                let cards = plan.placements.filter { $0.displayId == id }.compactMap { p -> AmbientCard? in
                    guard let image = images[p.asset.opaqueId] else { return nil }; let value = p.evaluate(min(at, plan.duration - 0.0001))
                    let frame = CGRect(x: value.x - ox - p.width * (value.scale - 1) * p.centerX, y: value.y - oy - p.height * (value.scale - 1) * p.centerY, width: p.width * value.scale, height: p.height * value.scale)
                    return AmbientCard(image: image.image, frame: frame, opacity: value.opacity, radius: p.cornerRadius)
                }
                if let image = await processor.render(cards: cards, viewport: size, at: at, enhanceColors: false), let png = PNImageDecode.png(image.image) { frames.append(PNAmbient(at: at, png: png, displayId: id)) }
            }
        }
        return frames
    }
}

nonisolated enum PNImageDecode {
    static func decode(_ bytes: Data, maximum: Int) -> DecodedPhoto? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
            [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
             kCGImageSourceThumbnailMaxPixelSize: max(64, maximum), kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return DecodedPhoto(image: image)
    }
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(output, image, nil); return CGImageDestinationFinalize(output) ? data as Data : nil
    }
}
