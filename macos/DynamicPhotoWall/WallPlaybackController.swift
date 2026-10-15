import CoreGraphics
import Foundation
import Observation

nonisolated enum WallAnimation {
    static func ease(_ progress: Double) -> Double {
        0.5 - cos(min(1, max(0, progress)) * .pi) / 2
    }
}

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

nonisolated struct GalleryFrameTransition: Equatable, Sendable {
    let from: [CGRect]
    let to: [CGRect]
    let startedAt: TimeInterval
    func frames(elapsed: TimeInterval, duration: TimeInterval) -> [CGRect] {
        let progress = min(1, max(0, (elapsed - startedAt) / duration))
        let eased = WallAnimation.ease(progress)
        return zip(from, to).map { a, b in
            CGRect(x: a.minX + (b.minX - a.minX) * eased, y: a.minY + (b.minY - a.minY) * eased,
                   width: a.width + (b.width - a.width) * eased, height: a.height + (b.height - a.height) * eased)
        }
    }
}

nonisolated struct WallScenePresentation: Equatable, Sendable {
    let scene: WallScene
    let progress: Double
    let elapsed: TimeInterval
    let slots: [GallerySlot]
    let scrollDistance: CGFloat
    var galleryLayout: GalleryFrameTransition? = nil
}

nonisolated struct WallSceneLayerPresentation: Identifiable {
    let presentation: WallScenePresentation
    let opacity: Double
    var id: Int { presentation.scene.id }
}

/// The window, clock and displayed pixels survive library updates and failures.
@MainActor
@Observable
final class WallPlaybackController {
    private(set) var currentScene: WallScene?
    private(set) var outgoing: WallScenePresentation?
    private(set) var isPaused = false
    private(set) var hasSession = false
    private(set) var isWaiting = false
    private(set) var waitingForImages = false
    private(set) var imageFailureMessage: String?
    let imageStore: PhotoImageStore?
    private(set) var settings = WallSettings()
    private(set) var viewport = CGSize(width: 1, height: 1)
    private(set) var slots: [GallerySlot] = []
    private(set) var sceneStartedAt: TimeInterval = 0
    private var galleryLayout: GalleryFrameTransition?
    private var sceneDuration: TimeInterval = 5
    private var removedScrollDistance: CGFloat = 0
    private var scrollHeldSeconds: TimeInterval = 0
    private var scrollHoldAt: TimeInterval?
    var waitingForScrollImage: Bool { scrollHoldAt != nil }
    @ObservationIgnored private var clock = WallPlaybackClock()
    @ObservationIgnored private var planner = WallScenePlanner()
    @ObservationIgnored private var assets: [PhotoAsset] = []
    @ObservationIgnored private var failedVersions: Set<PhotoImageKey> = []
    @ObservationIgnored private var preloadedScene: WallScene?
    @ObservationIgnored private var preloadPreparation: Task<Void, Never>?
    @ObservationIgnored private var scenePreparation: Task<Void, Never>?
    @ObservationIgnored private var slotPreparations: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingSlots: [Int: PhotoAsset] = [:]
    @ObservationIgnored private var scrollPreparation: Task<Void, Never>?
    @ObservationIgnored private var pendingScroll: PhotoAsset?
    @ObservationIgnored private var pendingScrollIsAppended = false
    @ObservationIgnored private var decodeWidths: [PhotoImageKey: Int] = [:]

    // Synthetic scheduling tests can omit decoding; AppModel supplies a store.
    init(imageStore: PhotoImageStore? = nil) { self.imageStore = imageStore }

    private var availableAssets: [PhotoAsset] {
        assets.filter { !failedVersions.contains(PhotoImageKey($0)) && !(imageStore?.failed($0) ?? false) }
    }

    private func needsFaces(_ scene: WallScene) -> Bool {
        (scene.mode == .verticalPan && settings.stopAtFace) || (scene.mode == .zoom && settings.faceAwareFraming)
    }

    private func isPrepared(_ scene: WallScene) -> Bool {
        guard let imageStore else { return true }
        return imageStore.isReady(scene.assets) && (!needsFaces(scene) || imageStore.facesReady(scene.assets))
    }

    private func applyPreparedFaces() {
        guard var scene = currentScene, let imageStore else { return }
        scene.assets = scene.assets.map { imageStore.assetWithFaces($0) }
        currentScene = scene
        sceneDuration = WallMotionGeometry.duration(for: scene, viewport: viewport, settings: settings)
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
        hasSession = true
        moveToNext(at: 0)
    }

    func stop() {
        cancelPreparations()
        hasSession = false
        isWaiting = false
        waitingForImages = false
        imageFailureMessage = nil
        currentScene = nil
        outgoing = nil
        slots = []
        assets = []
        galleryLayout = nil
        imageStore?.resetFailures()
        failedVersions.removeAll()
        isPaused = false
        scrollHoldAt = nil
        imageStore?.setDisplayedAssets([], cacheMegabytes: settings.cacheMegabytes)
    }

    /// Only candidate metadata changes. Existing scene, clock and NSWindow stay alive.
    func updateLibrary(assets: [PhotoAsset], retryFailed: Bool = true,
                       now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.assets = assets
        preloadPreparation?.cancel(); preloadPreparation = nil; preloadedScene = nil
        guard hasSession else { return }
        if retryFailed {
            failedVersions.removeAll()
            imageStore?.resetFailures()
        }
        let versions = Set(assets.map(PhotoImageKey.init))
        if currentScene.map({ $0.assets.contains(where: { !versions.contains(PhotoImageKey($0)) }) }) ?? true {
            moveToNext(at: clock.elapsed(at: now))
            return
        }
        // Rebuild only pending preparations; the visible scene and its timing persist.
        scenePreparation?.cancel()
        for task in slotPreparations.values { task.cancel() }
        slotPreparations.removeAll()
        pendingSlots.removeAll()
        scrollPreparation?.cancel()
        pendingScroll = nil
        pendingScrollIsAppended = false
        pinDisplayedImages()
        if waitingForImages, let scene = currentScene { scenePreparation = prepare(scene.assets) }
        else if currentScene?.mode == .horizontalGallery {
            prepareNextScrollPhoto(elapsed: max(0, clock.elapsed(at: now) - sceneStartedAt))
        }
    }

    func retry(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard hasSession else { return }
        failedVersions.removeAll()
        imageStore?.resetFailures()
        moveToNext(at: clock.elapsed(at: now))
    }

    func setPaused(_ paused: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard paused != isPaused else { return }
        update(now: now)
        clock.setPaused(paused, at: now)
        isPaused = paused
    }

    func next(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard hasSession else { return }
        if currentScene == nil { retry(now: now); return }
        let previousID = currentScene?.id
        update(now: now)
        if currentScene?.id == previousID { moveToNext(at: clock.elapsed(at: now)) }
    }

    func presentation(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> WallScenePresentation? {
        presentation(atActiveTime: clock.elapsed(at: now))
    }

    private func presentation(atActiveTime time: TimeInterval) -> WallScenePresentation? {
        guard let currentScene else { return nil }
        let elapsed = waitingForImages ? 0 : max(0, time - sceneStartedAt)
        return WallScenePresentation(scene: currentScene, progress: min(1, elapsed / sceneDuration),
                                     elapsed: elapsed, slots: slots, scrollDistance: scrollDistance(elapsed: elapsed), galleryLayout: galleryLayout)
    }

    private func rawScrollDistance(elapsed: TimeInterval) -> CGFloat {
        max(0, ((scrollHoldAt ?? elapsed) - scrollHeldSeconds) * settings.galleryScrollPixelsPerSecond - removedScrollDistance)
    }

    private func scrollDistance(elapsed: TimeInterval) -> CGFloat {
        guard let first = currentScene?.assets.first else { return 0 }
        let step = max(1, viewport.height - 2 * settings.gap) * first.aspectRatio + settings.gap
        return min(step, rawScrollDistance(elapsed: elapsed))
    }

    func transitionProgress(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        if waitingForImages { return 0 }
        guard outgoing != nil else { return 1 }
        return WallAnimation.ease((clock.elapsed(at: now) - sceneStartedAt) / settings.fadeSeconds)
    }

    func layers(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [WallSceneLayerPresentation] {
        var result: [WallSceneLayerPresentation] = []
        if let outgoing { result.append(WallSceneLayerPresentation(presentation: outgoing, opacity: 1)) }
        if let current = presentation(now: now) {
            result.append(WallSceneLayerPresentation(presentation: current, opacity: transitionProgress(now: now)))
        }
        return result
    }

    func update(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let currentScene else { return }
        let activeTime = clock.elapsed(at: now)
        if waitingForImages, let imageStore {
            if isPrepared(currentScene) {
                applyPreparedFaces()
                waitingForImages = false
                sceneStartedAt = activeTime
                if currentScene.mode == .horizontalGallery { prepareNextScrollPhoto(elapsed: 0) }
            } else {
                let failed = currentScene.assets.filter { imageStore.failed($0) }.map(PhotoImageKey.init)
                if !failed.isEmpty {
                    failedVersions.formUnion(failed)
                    moveToNext(at: activeTime)
                }
                return
            }
        }
        preloadNextScene()
        let elapsed = activeTime - sceneStartedAt
        if outgoing != nil, elapsed >= settings.fadeSeconds { outgoing = nil; pinDisplayedImages() }
        if elapsed >= sceneDuration + settings.fadeSeconds { moveToNext(at: activeTime); return }
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
        let previous = waitingForImages ? nil : presentation(atActiveTime: time)
        var excluded = Set(currentScene?.assets.map(\.url) ?? [])
        excluded.formUnion(outgoingPhotoURLs)
        excluded.formUnion(slots.compactMap { $0.previousAsset?.url })
        let next = preloadedScene ?? planner.next(assets: availableAssets, settings: settings, viewport: viewport, excluding: excluded)
        preloadedScene = nil
        cancelPreparations()
        guard let next else {
            if let previous { outgoing = previous }
            currentScene = nil
            slots = []
            waitingForImages = false
            isWaiting = true
            imageFailureMessage = outgoing == nil
                ? "読み込める写真がありません · 再検索または再試行してください"
                : "読み込める写真がありません · 最後の表示を保持して待機中"
            pinDisplayedImages()
            return
        }
        if let previous, outgoing == nil || time - sceneStartedAt >= settings.fadeSeconds / 2 { outgoing = previous }
        currentScene = next
        isWaiting = false
        waitingForImages = !isPrepared(next)
        imageFailureMessage = nil
        sceneStartedAt = time
        sceneDuration = WallMotionGeometry.duration(for: next, viewport: viewport, settings: settings)
        galleryLayout = nil
        removedScrollDistance = 0
        scrollHeldSeconds = 0
        scrollHoldAt = nil
        slots = next.mode == .gallery ? next.assets.enumerated().map { index, asset in
            GallerySlot(id: index, asset: asset,
                        nextReplacementAt: settings.fadeSeconds + settings.galleryMinSeconds + Double(index * 3))
        } : []
        pinDisplayedImages()
        // Readiness must use the newly selected mode's dimensions, not the old ones.
        waitingForImages = !isPrepared(next)
        if !waitingForImages { applyPreparedFaces() }
        scenePreparation = prepare(next.assets)
        if !waitingForImages, next.mode == .horizontalGallery { prepareNextScrollPhoto(elapsed: 0) }
    }

    private func preloadNextScene() {
        guard imageStore != nil, !waitingForImages, preloadedScene == nil, let scene = currentScene else { return }
        let excluded = Set(scene.assets.map(\.url)).union(outgoingPhotoURLs)
        guard let next = planner.next(assets: availableAssets, settings: settings, viewport: viewport, excluding: excluded) else { return }
        preloadedScene = next
        pinDisplayedImages()
        let widths = decodeWidths
        let detectFaces = needsFaces(next)
        preloadPreparation = Task { [weak self] in
            guard let self, let imageStore = self.imageStore else { return }
            _ = await imageStore.prepare(next.assets, desiredWidths: widths, detectFaces: detectFaces)
            guard !Task.isCancelled, self.preloadedScene?.id == next.id else { return }
            let failed = next.assets.filter { imageStore.failed($0) }
            if !failed.isEmpty {
                self.failedVersions.formUnion(failed.map(PhotoImageKey.init))
                self.preloadedScene = nil
                self.pinDisplayedImages()
            }
        }
    }

    private func cancelPreparations() {
        preloadPreparation?.cancel(); preloadPreparation = nil
        preloadedScene = nil
        scenePreparation?.cancel(); scenePreparation = nil
        scrollPreparation?.cancel(); scrollPreparation = nil
        for task in slotPreparations.values { task.cancel() }
        slotPreparations.removeAll()
        pendingSlots.removeAll()
        pendingScroll = nil
        pendingScrollIsAppended = false
    }

    private func prepare(_ photos: [PhotoAsset]) -> Task<Void, Never>? {
        guard let imageStore else { return nil }
        let widths = decodeWidths
        let detectFaces = currentScene.map(needsFaces) ?? false
        return Task { _ = await imageStore.prepare(photos, desiredWidths: widths, detectFaces: detectFaces) }
    }

    private func pinDisplayedImages() {
        var displayed: [PhotoAsset] = []
        var widths: [PhotoImageKey: Int] = [:]
        func add(_ photo: PhotoAsset, mode: WallMode) {
            displayed.append(photo)
            let width: CGFloat
            switch mode {
            case .gallery, .horizontalGallery, .horizontalPan: width = viewport.height * photo.aspectRatio
            case .verticalPan: width = viewport.width * settings.panWidthFraction
            case .zoom: width = max(viewport.width, viewport.height * photo.aspectRatio)
            }
            let key = PhotoImageKey(photo)
            widths[key] = max(widths[key] ?? 0, Int(ceil(min(8192, max(1, width)))))
        }
        if let scene = currentScene {
            for photo in scene.assets { add(photo, mode: scene.mode) }
        }
        if let next = preloadedScene {
            for photo in next.assets { add(photo, mode: next.mode) }
        }
        if let old = outgoing {
            for photo in old.scene.assets { add(photo, mode: old.scene.mode) }
            for photo in old.slots.compactMap(\.previousAsset) { add(photo, mode: .gallery) }
        }
        for photo in slots.compactMap(\.previousAsset) { add(photo, mode: .gallery) }
        for photo in pendingSlots.values { add(photo, mode: .gallery) }
        if let pendingScroll { add(pendingScroll, mode: .horizontalGallery) }
        decodeWidths = widths
        imageStore?.setDisplayedAssets(displayed, cacheMegabytes: settings.cacheMegabytes, desiredWidths: widths)
    }

    private func replaceSlot(_ index: Int, with photo: PhotoAsset, elapsed: TimeInterval) {
        let from = galleryLayout?.frames(elapsed: elapsed, duration: settings.fadeSeconds)
            ?? GalleryLayout.frames(assets: slots.map(\.asset), in: viewport, gap: settings.gap)
        slots[index].previousAsset = slots[index].asset
        slots[index].asset = photo
        slots[index].changedAt = elapsed
        currentScene?.assets[index] = photo
        galleryLayout = GalleryFrameTransition(from: from,
            to: GalleryLayout.frames(assets: slots.map(\.asset), in: viewport, gap: settings.gap), startedAt: elapsed)
        slots[index].nextReplacementAt = elapsed + settings.fadeSeconds + planner.galleryInterval(settings: settings)
        pendingSlots.removeValue(forKey: index)
        slotPreparations.removeValue(forKey: index)
        pinDisplayedImages()
    }

    private func updateGallery(elapsed: TimeInterval) {
        for index in slots.indices {
            if slots[index].previousAsset != nil, elapsed - slots[index].changedAt >= settings.fadeSeconds {
                slots[index].previousAsset = nil; pinDisplayedImages()
            }
            if let pending = pendingSlots[index], let imageStore {
                if imageStore.isReady([pending]) { replaceSlot(index, with: pending, elapsed: elapsed) }
                else if imageStore.failed(pending) {
                    failedVersions.insert(PhotoImageKey(pending))
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
            if let photo = planner.replacement(assets: availableAssets, settings: settings, excluding: excluded) {
                pendingSlots[index] = photo
                pinDisplayedImages()
                if let imageStore, !imageStore.isReady([photo]) { slotPreparations[index] = prepare([photo]) }
                else { replaceSlot(index, with: photo, elapsed: elapsed) }
            } else {
                slots[index].nextReplacementAt = elapsed + planner.galleryInterval(settings: settings)
            }
        }
    }

    private func prepareNextScrollPhoto(elapsed: TimeInterval) {
        guard pendingScroll == nil, let scene = currentScene, scene.mode == .horizontalGallery else { return }
        let candidates = availableAssets
        let excluded = Set(scene.assets.map(\.url)).union(outgoingPhotoURLs)
        let portraits = candidates.filter { $0.aspectRatio < 0.95 }
        let photo = planner.replacement(assets: portraits, settings: settings, excluding: excluded)
            ?? planner.replacement(assets: candidates, settings: settings, excluding: excluded)
            ?? scene.assets.first(where: { candidates.contains($0) })
        guard let photo else {
            if scrollHoldAt == nil { scrollHoldAt = elapsed }
            return
        }
        pendingScroll = photo
        pinDisplayedImages()
        scrollPreparation = prepare([photo])
        if let imageStore, !imageStore.isReady([photo]), scrollHoldAt == nil { scrollHoldAt = elapsed }
    }

    private func updateScroll(elapsed: TimeInterval) {
        prepareNextScrollPhoto(elapsed: elapsed)
        guard let pending = pendingScroll else { return }
        if let imageStore, imageStore.failed(pending) {
            failedVersions.insert(PhotoImageKey(pending))
            pendingScroll = nil
            pendingScrollIsAppended = false
            scrollPreparation?.cancel()
            pinDisplayedImages()
            prepareNextScrollPhoto(elapsed: elapsed)
            return
        }
        if let imageStore, !imageStore.isReady([pending]) {
            if scrollHoldAt == nil { scrollHoldAt = elapsed }
            return
        }
        if let heldAt = scrollHoldAt {
            scrollHeldSeconds += max(0, elapsed - heldAt)
            scrollHoldAt = nil
        }
        guard var scene = currentScene, let first = scene.assets.first else { return }
        // Put a ready, distinct incoming card on the right before moving. Waiting
        // until the first card exits can expose the end of a short strip.
        if !pendingScrollIsAppended, !scene.assets.contains(where: { $0.url == pending.url }) {
            scene.assets.append(pending)
            pendingScrollIsAppended = true
            currentScene = scene
        }
        let distance = max(1, viewport.height - 2 * settings.gap) * first.aspectRatio + settings.gap
        guard scrollDistance(elapsed: elapsed) >= distance else { return }
        // The next bitmap is ready before the visible list changes.
        scene.assets.removeFirst()
        if !pendingScrollIsAppended { scene.assets.append(pending) }
        scrollHeldSeconds += max(0, rawScrollDistance(elapsed: elapsed) - distance) / settings.galleryScrollPixelsPerSecond
        removedScrollDistance += distance
        currentScene = scene
        pendingScroll = nil
        pendingScrollIsAppended = false
        scrollPreparation = nil
        pinDisplayedImages()
        prepareNextScrollPhoto(elapsed: elapsed)
    }
}
