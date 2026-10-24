import Foundation
import CoreGraphics

/// Legacy Swift calculation values, independent of LAN envelopes and native
/// image resources. These are not the proposed Rust/FFI schema. PhotoAsset URL
/// identity and native random/order rules stay intact during this extraction.
nonisolated struct WallTimelinePlacement: Sendable {
    var id: Int; var asset: PhotoAsset; var displayID: UInt32?; var clip: CGRect
    var width: Double; var height: Double; var fromX: Double; var fromY: Double; var toX: Double; var toY: Double
    var fromScale: Double; var toScale: Double; var centerX: Double; var centerY: Double
    var startSeconds: Double; var motionSeconds: Double; var visibleFrom: Double; var visibleUntil: Double
    var fadeSeconds: Double; var cornerRadius: Double; var ease: Bool
    var fadeInSeconds: Double? = nil; var fadeOutSeconds: Double? = nil
}
nonisolated struct WallTimelineSchedule: Sendable {
    var nextChangeSeconds: Double
    var updatedURLs: Set<URL>
}
nonisolated struct WallSceneTimeline: Sendable {
    var mode: WallMode
    var duration: Double
    var placements: [WallTimelinePlacement]
    var gallerySchedule: WallTimelineSchedule?
    var continuing: Bool
}

/// Owned serially by the host's planning actor. No I/O, wire IDs, image bytes,
/// timers, clocks or drawing; the host controls when planning is requested.
/// The duration/repeat/fade policy here is the existing LAN v1 policy.
nonisolated final class WallSceneTimelinePlanner {
    private let planner = WallScenePlanner()
    func resetModeHistory() { planner.resetModeHistory() }

    func build(assets: [PhotoAsset], settings: WallSettings, group nativeGroup: WallDisplayGroup,
               previous previousGallery: WallSceneTimeline?) throws -> WallSceneTimeline? {
        try Task.checkCancellation()
        let displays = nativeGroup.displays, nativeDisplays = nativeGroup.displays
        let left = nativeGroup.bounds.minX, top = nativeGroup.bounds.minY
        let carried: [WallSurfacePlan]? = previousGallery.map { p in
            let mode = p.mode
            return (settings.perDisplay(mode) ? nativeDisplays.indices.map { Optional($0) } : [nil]).map { index in
                let display = index.map { displays[$0] }, native = index.map { nativeDisplays[$0] }
                let terminal = p.placements.filter { $0.visibleUntil == p.duration && $0.displayID == display?.id }
                var scene = WallScene(id: 0, mode: mode, assets: terminal.map(\.asset))
                scene.displayRegions = native == nil ? nativeDisplays.map { nativeGroup.region($0) } : []
                return WallSurfacePlan(displayID: native?.id, viewport: native?.rect.size ?? nativeGroup.viewport, scene: scene)
            }
        }
        // Repeated Gallery draws extend the committed photographs and positions.
        guard let surfaces = planner.nextGroup(assets: assets, settings: settings, group: nativeGroup,
            connected: Set(nativeDisplays.map(\.id)), allowGalleryRepeat: true, continuation: carried), let first = surfaces.first else { return nil }
        let continuing = previousGallery?.mode == first.scene.mode
        var placements: [WallTimelinePlacement] = []; var duration = 0.0
        for surface in surfaces {
            try Task.checkCancellation()
            let display = surface.displayID.flatMap { id in displays.indices.contains(Int(id) - 1) ? displays[Int(id) - 1] : nil }
            let ox = Double(display.map { $0.x - left } ?? 0), oy = Double(display.map { $0.y - top } ?? 0)
            let v = surface.viewport; let scene = surface.scene
            var clip = CGRect(x: ox, y: oy, width: v.width, height: v.height)
            func add(_ asset: PhotoAsset, width: Double, height: Double, fromX: Double, fromY: Double, toX: Double, toY: Double,
                     fromScale: Double = 1, toScale: Double = 1, centerX: Double = 0.5, centerY: Double = 0.5,
                     start: Double = 0, motion: Double, visibleFrom: Double = 0, visibleUntil: Double, fade: Double = 0, corner: Double = 0, ease: Bool = false) {
                placements.append(WallTimelinePlacement(id: placements.count, asset: asset, displayID: display?.id, clip: clip, width: width, height: height,
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
                if continuing, let previousGallery {
                    for old in previousGallery.placements where old.displayID == display?.id && old.toX + old.width > clip.minX {
                        var p = old; p.id = placements.count; p.fromX = old.toX; p.fromY = old.toY
                        p.toX = old.toX - seconds * settings.galleryScrollPixelsPerSecond
                        p.startSeconds = 0; p.motionSeconds = seconds; p.visibleFrom = 0; p.visibleUntil = seconds
                        placements.append(p); x = max(x, old.toX - ox + old.width + settings.gap)
                    }
                }
                while x < v.width + seconds * settings.galleryScrollPixelsPerSecond && index < 128 {
                    try Task.checkCancellation()
                    let chosen = !continuing && index < scene.assets.count ? scene.assets[index] : planner.replacement(assets: assets, settings: settings, excluding: []) ?? scene.assets[0]
                    let w = h * chosen.aspectRatio
                    add(chosen, width: w, height: h, fromX: x, fromY: (v.height - h) / 2, toX: x - seconds * settings.galleryScrollPixelsPerSecond, toY: (v.height - h) / 2, motion: seconds, visibleUntil: seconds, corner: settings.cornerRadius)
                    x += w + settings.gap; index += 1
                }
            default:
                guard let asset = scene.assets.first else { continue }
                guard let motion = FaceMotionSafety.plan(for: scene.mode, asset: asset, viewport: v, settings: settings, reverse: scene.reverse, center: scene.zoomCenter, displayRegions: scene.displayRegions) else { return nil }
                seconds = motion.seconds + (scene.mode == .verticalPan && settings.stopAtFace && !(asset.faces ?? []).isEmpty ? 3 : 0)
                let frameTop = scene.mode == .verticalPan || scene.mode == .horizontalPan ? motion.frameTop : 0
                if scene.mode == .verticalPan { clip = CGRect(x: ox + motion.fromX, y: oy + frameTop, width: motion.width, height: min(v.height, motion.height)) }
                add(asset, width: motion.width, height: motion.height, fromX: motion.fromX, fromY: motion.fromY + frameTop, toX: motion.toX, toY: motion.toY + frameTop, fromScale: motion.fromScale, toScale: motion.toScale, centerX: motion.center.x, centerY: motion.center.y, motion: motion.seconds, visibleUntil: seconds, ease: scene.mode == .zoom)
            }
            duration = max(duration, seconds)
        }
        var gallerySchedule: WallTimelineSchedule?
        if first.scene.mode == .gallery {
            let inputs = surfaces.map { surface in
                let display = surface.displayID.map { displays[Int($0) - 1] }
                let ox = Double(display.map { $0.x - left } ?? 0), oy = Double(display.map { $0.y - top } ?? 0)
                let terminal = continuing ? previousGallery?.placements.filter { $0.visibleUntil == previousGallery!.duration && $0.displayID == display?.id } : nil
                return GalleryTimeline.Surface(assets: surface.scene.assets, viewport: surface.viewport,
                    displays: settings.avoidFaceDisplayBoundaries ? surface.scene.displayRegions : [],
                    frames: terminal?.map { CGRect(x: $0.toX - ox, y: $0.toY - oy, width: $0.width, height: $0.height) })
            }
            let timeline = GalleryTimeline.buildPlan(inputs, duration: duration, settings: settings, replacement: { active in
                planner.replacement(assets: assets, settings: settings, excluding: Set(active.map(\.url)))
            }, candidates: assets, nextChangeSeconds: continuing ? previousGallery?.gallerySchedule?.nextChangeSeconds : nil,
                updated: continuing ? previousGallery?.gallerySchedule?.updatedURLs ?? [] : [])
            duration = timeline.duration
            gallerySchedule = WallTimelineSchedule(nextChangeSeconds: timeline.nextChangeSeconds, updatedURLs: timeline.updated)
            for s in timeline.segments {
                let surface = surfaces[s.surface]
                let display = surface.displayID.flatMap { id in displays.indices.contains(Int(id) - 1) ? displays[Int(id) - 1] : nil }
                let x = Double(display.map { $0.x - left } ?? 0), y = Double(display.map { $0.y - top } ?? 0)
                var p = WallTimelinePlacement(id: placements.count, asset: s.asset, displayID: display?.id,
                    clip: CGRect(x: x, y: y, width: surface.viewport.width, height: surface.viewport.height), width: s.to.width, height: s.to.height,
                    fromX: x + s.from.minX, fromY: y + s.from.minY, toX: x + s.to.minX, toY: y + s.to.minY,
                    fromScale: 1, toScale: 1, centerX: 0.5, centerY: 0.5, startSeconds: s.at, motionSeconds: s.motion,
                    visibleFrom: s.at, visibleUntil: s.until, fadeSeconds: 0, cornerRadius: settings.cornerRadius, ease: true)
                p.fadeInSeconds = s.fadeIn; p.fadeOutSeconds = s.fadeOut; placements.append(p)
            }
            guard !placements.isEmpty else { return nil }
        }
        if first.scene.mode != .gallery { for index in placements.indices { placements[index].visibleUntil = duration } }
        try Task.checkCancellation()
        return WallSceneTimeline(mode: first.scene.mode, duration: duration, placements: placements,
            gallerySchedule: gallerySchedule, continuing: continuing)
    }
}
