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

nonisolated struct WallSceneLayerPresentation: Identifiable {
    let presentation: WallScenePresentation
    let opacity: Double
    var id: Int { presentation.scene.id }
}

/// Owns playback state independently of the window and SwiftUI view lifecycle.
@MainActor
@Observable
final class WallPlaybackController {
    private(set) var currentScene: WallScene?
    private(set) var outgoing: WallScenePresentation?
    private(set) var isPaused = false
    private(set) var waitingForImages = false
    private(set) var imageFailureMessage: String?
    let imageStore: PhotoImageStore?
    private(set) var settings = WallSettings()
    private(set) var viewport = CGSize(width: 1, height: 1)
    private(set) var slots: [GallerySlot] = []
    private(set) var sceneStartedAt: TimeInterval = 0
    private var sceneDuration: TimeInterval = 5
    private var removedScrollDistance: CGFloat = 0
    @ObservationIgnored private var clock = WallPlaybackClock()
    @ObservationIgnored private var planner = WallScenePlanner()
    @ObservationIgnored private var assets: [PhotoAsset] = []
    @ObservationIgnored private var scenePreparation: Task<Void, Never>?
    @ObservationIgnored private var slotPreparations: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingSlots: [Int: PhotoAsset] = [:]
    @ObservationIgnored private var scrollPreparation: Task<Void, Never>?

    // A nil store lets pure scheduling tests use synthetic metadata without I/O.
    // AppModel supplies the shared decoded-image store for actual playback.
    init(imageStore: PhotoImageStore? = nil) {
        self.imageStore = imageStore
    }

    func start(assets: [PhotoAsset], settings: WallSettings, viewport: CGSize,
               seed: UInt64 = .random(in: .min ... .max), now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        stop()
        self.assets = assets
        self.settings = settings
        self.viewport = viewport
        planner = WallScenePlanner(seed: seed)
        clock.reset(at: now)
        imageStore?.resetFailures()
        moveToNext(at: 0)
    }

    func stop() {
        scenePreparation?.cancel()
        scrollPreparation?.cancel()
        for task in slotPreparations.values { task.cancel() }
        slotPreparations.removeAll()
        pendingSlots.removeAll()
        waitingForImages = false
        imageFailureMessage = nil
        imageStore?.setDisplayedAssets([], cacheMegabytes: settings.cacheMegabytes)
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
        let elapsed = waitingForImages ? 0 : max(0, clock.elapsed(at: now) - sceneStartedAt)
        return WallScenePresentation(scene: currentScene, progress: min(1, elapsed / sceneDuration),
                                     elapsed: elapsed, slots: slots,
                                     scrollDistance: max(0, elapsed * settings.galleryScrollPixelsPerSecond - removedScrollDistance))
    }

    func transitionProgress(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        if waitingForImages { return 0 }
        guard outgoing != nil else { return 1 }
        return min(1, max(0, (clock.elapsed(at: now) - sceneStartedAt) / settings.fadeSeconds))
    }

    func layers(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [WallSceneLayerPresentation] {
        var result: [WallSceneLayerPresentation] = []
        if let outgoing { result.append(WallSceneLayerPresentation(presentation: outgoing, opacity: 1)) }
        if let current = presentation(now: now) {
            result.append(WallSceneLayerPresentation(presentation: current, opacity: transitionProgress(now: now)))
        }
        return result
    }

    /// Called on presentation ticks; work is bounded by the current visible slots.
    func update(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let currentScene else { return }
        let activeTime = clock.elapsed(at: now)
        if waitingForImages, let imageStore {
            if imageStore.isReady(currentScene.assets) {
                // Loading time is not fade or motion time. Until now the old
                // layer has remained opaque, with its decoded pixels retained.
                waitingForImages = false
                sceneStartedAt = activeTime
            } else {
                let failed = Set(currentScene.assets.filter { imageStore.failed($0) }.map(PhotoImageKey.init))
                if !failed.isEmpty {
                    assets.removeAll { failed.contains(PhotoImageKey($0)) }
                    moveToNext(at: activeTime)
                }
                return
            }
        }
        let elapsed = activeTime - sceneStartedAt
        if outgoing != nil, elapsed >= settings.fadeSeconds {
            outgoing = nil
            pinDisplayedImages()
        }
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
        let previous = waitingForImages ? nil : currentScene.map { scene in
            WallScenePresentation(scene: scene, progress: min(1, max(0, time - sceneStartedAt) / sceneDuration),
                                  elapsed: max(0, time - sceneStartedAt), slots: slots,
                                  scrollDistance: max(0, (time - sceneStartedAt) * settings.galleryScrollPixelsPerSecond - removedScrollDistance))
        }
        // Exclude every image in both layers during an interrupted transition.
        var excluded = Set(currentScene?.assets.map(\.url) ?? [])
        excluded.formUnion(outgoingPhotoURLs)
        excluded.formUnion(slots.compactMap { $0.previousAsset?.url })
        guard let next = planner.next(assets: assets, settings: settings, viewport: viewport, excluding: excluded) else {
            if let previous { outgoing = previous }
            currentScene = nil
            waitingForImages = false
            imageFailureMessage = "読み込める写真がありません。最後の表示を保持しています。"
            pinDisplayedImages()
            return
        }
        if let previous {
            // On a rapid Next, retain the layer that is currently most visible.
            if outgoing == nil || time - sceneStartedAt >= settings.fadeSeconds / 2 { outgoing = previous }
        }
        scenePreparation?.cancel()
        scrollPreparation?.cancel()
        for task in slotPreparations.values { task.cancel() }
        slotPreparations.removeAll()
        pendingSlots.removeAll()
        currentScene = next
        waitingForImages = imageStore.map { !$0.isReady(next.assets) } ?? false
        imageFailureMessage = nil
        sceneStartedAt = time
        sceneDuration = WallMotionGeometry.duration(for: next, viewport: viewport, settings: settings)
        removedScrollDistance = 0
        slots = next.mode == .gallery ? next.assets.enumerated().map { index, asset in
            GallerySlot(id: index, asset: asset, nextReplacementAt: settings.galleryMinSeconds + Double(index * 3))
        } : []
        pinDisplayedImages()
        if let imageStore {
            scenePreparation = Task { _ = await imageStore.prepare(next.assets) }
        }
    }

    private func pinDisplayedImages() {
        var displayed = currentScene?.assets ?? []
        displayed.append(contentsOf: outgoing?.scene.assets ?? [])
        displayed.append(contentsOf: outgoing?.slots.compactMap(\.previousAsset) ?? [])
        displayed.append(contentsOf: slots.compactMap(\.previousAsset))
        displayed.append(contentsOf: pendingSlots.values)
        imageStore?.setDisplayedAssets(displayed, cacheMegabytes: settings.cacheMegabytes)
    }

    private func replaceSlot(_ index: Int, with photo: PhotoAsset, elapsed: TimeInterval) {
        slots[index].previousAsset = slots[index].asset
        slots[index].asset = photo
        slots[index].changedAt = elapsed
        currentScene?.assets[index] = photo
        slots[index].nextReplacementAt = elapsed + planner.galleryInterval(settings: settings)
        pendingSlots.removeValue(forKey: index)
        slotPreparations.removeValue(forKey: index)
        pinDisplayedImages()
    }

    private func updateGallery(elapsed: TimeInterval) {
        for index in slots.indices {
            if slots[index].previousAsset != nil, elapsed - slots[index].changedAt >= settings.fadeSeconds {
                slots[index].previousAsset = nil
                pinDisplayedImages()
            }
            if let pending = pendingSlots[index], let imageStore {
                if imageStore.isReady([pending]) {
                    replaceSlot(index, with: pending, elapsed: elapsed)
                } else if imageStore.failed(pending) {
                    assets.removeAll { PhotoImageKey($0) == PhotoImageKey(pending) }
                    pendingSlots.removeValue(forKey: index)
                    slotPreparations.removeValue(forKey: index)
                    slots[index].nextReplacementAt = elapsed + 1
                    pinDisplayedImages()
                }
                continue
            }
            guard elapsed >= slots[index].nextReplacementAt else { continue }
            var excluded = Set(slots.map { $0.asset.url })
            excluded.formUnion(slots.compactMap { $0.previousAsset?.url })
            excluded.formUnion(outgoingPhotoURLs)
            excluded.formUnion(pendingSlots.values.map(\.url))
            if let photo = planner.replacement(assets: assets, settings: settings, excluding: excluded) {
                if let imageStore, !imageStore.isReady([photo]) {
                    pendingSlots[index] = photo
                    pinDisplayedImages()
                    slotPreparations[index] = Task { _ = await imageStore.prepare([photo]) }
                } else {
                    replaceSlot(index, with: photo, elapsed: elapsed)
                }
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
        if scene != currentScene {
            currentScene = scene
            pinDisplayedImages()
            if let imageStore {
                scrollPreparation?.cancel()
                scrollPreparation = Task { _ = await imageStore.prepare(scene.assets) }
            }
        }
    }
}
