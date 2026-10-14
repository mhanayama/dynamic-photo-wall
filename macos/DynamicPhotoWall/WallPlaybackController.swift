import CoreGraphics
import Foundation
import Observation

nonisolated struct WallPlaybackClock {
    private var accumulated: TimeInterval = 0
    private var resumedAt: TimeInterval?

    func elapsed(at now: TimeInterval) -> TimeInterval {
        accumulated + (resumedAt.map { max(0, now - $0) } ?? 0)
    }

    mutating func reset(at now: TimeInterval) {
        accumulated = 0
        resumedAt = now
    }

    mutating func setPaused(_ paused: Bool, at now: TimeInterval) {
        if paused, let started = resumedAt {
            accumulated += max(0, now - started)
            resumedAt = nil
        } else if !paused, resumedAt == nil {
            resumedAt = now
        }
    }
}

nonisolated struct GallerySlot: Identifiable, Equatable, Sendable {
    let id: Int
    var asset: PhotoAsset
    var previousAsset: PhotoAsset?
    var changedAt: TimeInterval = -.infinity
    var nextReplacementAt: TimeInterval
}

nonisolated struct WallScenePresentation: Equatable, Sendable {
    let scene: WallScene
    let progress: Double
    let elapsed: TimeInterval
    let slots: [GallerySlot]
    let scrollDistance: CGFloat
}

/// Owns playback state independently of the window and SwiftUI view lifecycle.
@MainActor
@Observable
final class WallPlaybackController {
    private(set) var currentScene: WallScene?
    private(set) var outgoing: WallScenePresentation?
    private(set) var isPaused = false
    private(set) var settings = WallSettings()
    private(set) var viewport = CGSize(width: 1, height: 1)
    private(set) var slots: [GallerySlot] = []
    private(set) var sceneStartedAt: TimeInterval = 0
    private var sceneDuration: TimeInterval = 5
    private var removedScrollDistance: CGFloat = 0
    @ObservationIgnored private var clock = WallPlaybackClock()
    @ObservationIgnored private var planner = WallScenePlanner()
    @ObservationIgnored private var assets: [PhotoAsset] = []

    func start(assets: [PhotoAsset], settings: WallSettings, viewport: CGSize,
               seed: UInt64 = .random(in: .min ... .max), now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        stop()
        self.assets = assets
        self.settings = settings
        self.viewport = viewport
        planner = WallScenePlanner(seed: seed)
        clock.reset(at: now)
        moveToNext(at: 0)
    }

    func stop() {
        currentScene = nil
        outgoing = nil
        slots = []
        assets = []
        isPaused = false
    }

    func setPaused(_ paused: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard paused != isPaused else { return }
        update(now: now)
        clock.setPaused(paused, at: now)
        isPaused = paused
    }

    func next(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard currentScene != nil else { return }
        update(now: now)
        moveToNext(at: clock.elapsed(at: now))
    }

    func presentation(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> WallScenePresentation? {
        guard let currentScene else { return nil }
        let elapsed = max(0, clock.elapsed(at: now) - sceneStartedAt)
        return WallScenePresentation(scene: currentScene, progress: min(1, elapsed / sceneDuration),
                                     elapsed: elapsed, slots: slots,
                                     scrollDistance: max(0, elapsed * settings.galleryScrollPixelsPerSecond - removedScrollDistance))
    }

    func transitionProgress(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        guard outgoing != nil else { return 1 }
        return min(1, max(0, (clock.elapsed(at: now) - sceneStartedAt) / settings.fadeSeconds))
    }

    /// Called on presentation ticks; work is bounded by the current visible slots.
    func update(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let currentScene else { return }
        let activeTime = clock.elapsed(at: now)
        let elapsed = activeTime - sceneStartedAt
        if outgoing != nil, elapsed >= settings.fadeSeconds { outgoing = nil }
        if elapsed >= sceneDuration + settings.fadeSeconds {
            moveToNext(at: activeTime)
            return
        }
        switch currentScene.mode {
        case .gallery: updateGallery(elapsed: elapsed)
        case .horizontalGallery: updateScroll(elapsed: elapsed)
        default: break
        }
    }

    private var outgoingPhotoURLs: Set<URL> {
        var urls = Set(outgoing?.scene.assets.map(\.url) ?? [])
        urls.formUnion(outgoing?.slots.compactMap { $0.previousAsset?.url } ?? [])
        return urls
    }

    private func moveToNext(at time: TimeInterval) {
        let previous = currentScene.map { scene in
            WallScenePresentation(scene: scene, progress: min(1, max(0, time - sceneStartedAt) / sceneDuration),
                                  elapsed: max(0, time - sceneStartedAt), slots: slots,
                                  scrollDistance: max(0, (time - sceneStartedAt) * settings.galleryScrollPixelsPerSecond - removedScrollDistance))
        }
        // Exclude every image in both layers during an interrupted transition.
        var excluded = Set(currentScene?.assets.map(\.url) ?? [])
        excluded.formUnion(outgoingPhotoURLs)
        excluded.formUnion(slots.compactMap { $0.previousAsset?.url })
        guard let next = planner.next(assets: assets, settings: settings, viewport: viewport, excluding: excluded) else {
            stop()
            return
        }
        if let previous {
            // On a rapid Next, retain the layer that is currently most visible.
            if outgoing == nil || time - sceneStartedAt >= settings.fadeSeconds / 2 { outgoing = previous }
        }
        currentScene = next
        sceneStartedAt = time
        sceneDuration = WallMotionGeometry.duration(for: next, viewport: viewport, settings: settings)
        removedScrollDistance = 0
        slots = next.mode == .gallery ? next.assets.enumerated().map { index, asset in
            GallerySlot(id: index, asset: asset, nextReplacementAt: settings.galleryMinSeconds + Double(index * 3))
        } : []
    }

    private func updateGallery(elapsed: TimeInterval) {
        for index in slots.indices {
            if slots[index].previousAsset != nil, elapsed - slots[index].changedAt >= settings.fadeSeconds {
                slots[index].previousAsset = nil
            }
            guard elapsed >= slots[index].nextReplacementAt else { continue }
            var excluded = Set(slots.map { $0.asset.url })
            excluded.formUnion(slots.compactMap { $0.previousAsset?.url })
            excluded.formUnion(outgoingPhotoURLs)
            if let photo = planner.replacement(assets: assets, settings: settings, excluding: excluded) {
                slots[index].previousAsset = slots[index].asset
                slots[index].asset = photo
                slots[index].changedAt = elapsed
                currentScene?.assets[index] = photo
            }
            slots[index].nextReplacementAt = elapsed + planner.galleryInterval(settings: settings)
        }
    }

    private func updateScroll(elapsed: TimeInterval) {
        guard var scene = currentScene else { return }
        let height = max(1, viewport.height - 2 * settings.gap)
        var distance = elapsed * settings.galleryScrollPixelsPerSecond - removedScrollDistance
        // A long scheduling stall must not trigger unbounded work on the UI thread.
        for _ in 0..<64 {
            guard let first = scene.assets.first else { break }
            let firstWidth = height * first.aspectRatio
            guard distance >= settings.gap + firstWidth else { break }
            scene.assets.removeFirst()
            removedScrollDistance += firstWidth + settings.gap
            distance -= firstWidth + settings.gap
            var excluded = Set(scene.assets.map(\.url))
            excluded.formUnion(outgoingPhotoURLs)
            if let photo = planner.replacement(assets: assets, settings: settings, excluding: excluded) {
                scene.assets.append(photo)
            } else {
                // A small library can recycle the photo only after it has exited.
                scene.assets.append(first)
            }
        }
        if scene != currentScene { currentScene = scene }
    }
}
