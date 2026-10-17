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
    private(set) var sceneDuration: TimeInterval = 5
    private var removedScrollDistance: CGFloat = 0
    private var scrollHeldSeconds: TimeInterval = 0
    private var scrollHoldAt: TimeInterval?
    var waitingForScrollImage: Bool { scrollHoldAt != nil }
    @ObservationIgnored private let galleryProcessor = GalleryCompositionProcessor()
    @ObservationIgnored private var preparedGalleryFrames: [Int: [CGRect]] = [:]
    @ObservationIgnored private var galleryCompleted: Set<Int> = []
    @ObservationIgnored private var optimizationPhotos: [Int: [PhotoAsset]] = [:]
    @ObservationIgnored private var slotPreparedFrames: [Int: [CGRect]] = [:]
    @ObservationIgnored private var optimizedSlots: Set<Int> = []
    @ObservationIgnored private var activeSlotOptimization: Int?
    @ObservationIgnored private var slotOptimizationTask: Task<Void, Never>?
    @ObservationIgnored private let cacheOwner = UUID()
    @ObservationIgnored private var managedScene: WallScene?
    @ObservationIgnored private var externallyManaged = false
    @ObservationIgnored private var displayRegions: [CGRect] = []
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
        (scene.mode == .verticalPan && settings.stopAtFace)
            || ([.verticalPan, .horizontalPan].contains(scene.mode) && settings.faceAwarePanDirection)
            || (scene.mode == .zoom && settings.faceAwareFraming)
            || ([.gallery, .verticalPan].contains(scene.mode) && settings.avoidFaceDisplayBoundaries
                && FaceSafeLayout.requiresProtection(viewport, displays: scene.displayRegions))
    }

    private func isPrepared(_ scene: WallScene) -> Bool {
        guard let imageStore else { return true }
        return imageStore.isReady(scene.assets) && (!needsFaces(scene) || imageStore.facesReady(scene.assets))
            && (!needsPreparedGallery(scene) || galleryCompleted.contains(scene.id))
    }

    private func applyPreparedFaces() {
        guard var scene = currentScene, let imageStore else { return }
        scene.assets = scene.assets.map { imageStore.assetWithFaces($0) }
        currentScene = scene
        if scene.mode == .gallery {
            for index in slots.indices { slots[index].asset = scene.assets[index] }
        }
        sceneDuration = WallMotionGeometry.duration(for: scene, viewport: viewport, settings: settings)
    }

    func start(assets: [PhotoAsset], settings: WallSettings, viewport: CGSize,
               seed: UInt64 = .random(in: .min ... .max), now: TimeInterval = ProcessInfo.processInfo.systemUptime,
               scene: WallScene? = nil, externallyManaged: Bool = false, displayRegions: [CGRect] = [],
               sharedPlanner: WallScenePlanner? = nil) {
        stop()
        self.assets = assets
        self.settings = settings
        self.viewport = viewport
        self.managedScene = scene
        self.externallyManaged = externallyManaged
        self.displayRegions = displayRegions
        planner = sharedPlanner ?? WallScenePlanner(seed: seed)
        clock.reset(at: now)
        if !externallyManaged { imageStore?.clearFailures() }
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
        galleryCompleted = []; optimizationPhotos = [:]; preparedGalleryFrames = [:]
        galleryLayout = nil
        failedVersions.removeAll()
        isPaused = false
        scrollHoldAt = nil
        imageStore?.setDisplayedAssets([], cacheMegabytes: settings.cacheMegabytes, owner: cacheOwner)
    }

    /// Only candidate metadata changes. Existing scene, clock and NSWindow stay alive.
    func updateLibrary(assets: [PhotoAsset], retryFailed: Bool = true,
                       now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.assets = assets
        slotOptimizationTask?.cancel(); slotOptimizationTask = nil; activeSlotOptimization = nil; optimizedSlots = []; slotPreparedFrames = [:]
        optimizationPhotos = [:]
        preloadPreparation?.cancel(); preloadPreparation = nil; preloadedScene = nil
        guard hasSession else { return }
        if retryFailed {
            failedVersions.removeAll()
            imageStore?.clearFailures()
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
        if waitingForImages, let scene = currentScene { scenePreparation = prepareScene(scene) }
        else if currentScene?.mode == .horizontalGallery {
            prepareNextScrollPhoto(elapsed: max(0, clock.elapsed(at: now) - sceneStartedAt))
        }
    }

    func retry(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard hasSession else { return }
        failedVersions.removeAll()
        imageStore?.clearFailures()
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
        if !externallyManaged { preloadNextScene() }
        let elapsed = activeTime - sceneStartedAt
        if outgoing != nil, elapsed >= settings.fadeSeconds { outgoing = nil; pinDisplayedImages() }
        if !externallyManaged, elapsed >= sceneDuration + settings.fadeSeconds { moveToNext(at: activeTime); return }
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
        var next = managedScene ?? preloadedScene ?? (externallyManaged ? nil : planner.next(assets: availableAssets, settings: settings, viewport: viewport, excluding: excluded))
        if next?.displayRegions.isEmpty == true { next?.displayRegions = displayRegions }
        managedScene = nil
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
        if let frames = preparedGalleryFrames[next.id] {
            galleryLayout = GalleryFrameTransition(from: frames, to: frames, startedAt: 0)
        } else { galleryLayout = nil }
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
        scenePreparation = prepareScene(next)
        if !waitingForImages, next.mode == .horizontalGallery { prepareNextScrollPhoto(elapsed: 0) }
    }

    private func preloadNextScene() {
        guard imageStore != nil, !waitingForImages, preloadedScene == nil, let scene = currentScene else { return }
        let excluded = Set(scene.assets.map(\.url)).union(outgoingPhotoURLs)
        guard var next = planner.next(assets: availableAssets, settings: settings, viewport: viewport, excluding: excluded) else { return }
        next.displayRegions = displayRegions
        preloadedScene = next
        pinDisplayedImages()
        preloadPreparation = prepareScene(next)
    }

    private func cancelPreparations() {
        slotOptimizationTask?.cancel(); slotOptimizationTask = nil; activeSlotOptimization = nil
        optimizedSlots = []; slotPreparedFrames = [:]
        optimizationPhotos = [:]
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

    private func needsPreparedGallery(_ scene: WallScene) -> Bool {
        scene.mode == .gallery && settings.avoidFaceDisplayBoundaries
            && FaceSafeLayout.requiresProtection(viewport, displays: scene.displayRegions)
    }

    private func canImproveGallery(_ scene: WallScene) -> Bool {
        scene.mode == .gallery && settings.randomOrder && settings.avoidFaceDisplayBoundaries
            && !settings.galleryPerDisplay && FaceSafeLayout.requiresProtection(viewport, displays: scene.displayRegions)
    }

    private func prepareScene(_ scene: WallScene) -> Task<Void, Never>? {
        guard let imageStore else { return nil }
        let widths = decodeWidths, detectFaces = needsFaces(scene)
        return Task { [weak self] in
            guard let self else { return }
            guard await imageStore.prepare(scene.assets, desiredWidths: widths, detectFaces: detectFaces), !Task.isCancelled else { return }
            var result = scene
            result.assets = scene.assets.map(imageStore.assetWithFaces)
            if self.canImproveGallery(scene), !self.galleryCompleted.contains(scene.id) {
                result.assets = await self.improvedPhotos(result.assets, scene: scene, onlyIndex: nil, passes: 2)
            }
            let frames = self.needsPreparedGallery(scene)
                ? await self.galleryProcessor.frames(result.assets, viewport: self.viewport, gap: self.settings.gap, displays: scene.displayRegions) : nil
            guard !Task.isCancelled, self.hasSession else { return }
            if let frames { self.preparedGalleryFrames[scene.id] = frames }
            if self.currentScene?.id == scene.id, self.waitingForImages {
                self.currentScene = result
                if let frames { self.galleryLayout = GalleryFrameTransition(from: frames, to: frames, startedAt: 0) }
                for i in self.slots.indices { self.slots[i].asset = result.assets[i] }
            }
            if self.preloadedScene?.id == scene.id { self.preloadedScene = result }
            self.galleryCompleted.insert(scene.id)
            self.optimizationPhotos.removeValue(forKey: scene.id)
            let retained = Set([self.currentScene?.id, self.preloadedScene?.id, self.outgoing?.scene.id].compactMap { $0 })
            self.galleryCompleted.formIntersection(retained)
            self.preparedGalleryFrames = self.preparedGalleryFrames.filter { retained.contains($0.key) }
            self.pinDisplayedImages()
        }
    }

    private func improvedPhotos(_ photos: [PhotoAsset], scene: WallScene, onlyIndex: Int?, passes: Int) async -> [PhotoAsset] {
        guard let imageStore, canImproveGallery(scene) else { return photos }
        var result = photos
        for _ in 0..<passes {
            guard !Task.isCancelled else { return photos }
            let known = await imageStore.cachedFaceAssets(availableAssets)
            var blocked = Set(result.map(\.url)).union(outgoingPhotoURLs)
            blocked.formUnion(currentScene?.assets.map(\.url) ?? [])
            blocked.formUnion(slots.compactMap { $0.previousAsset?.url })
            let candidates = planner.sampleKnownFaces(known, settings: settings, excluding: blocked)
            guard !candidates.isEmpty else { break }
            let replacement: GalleryComposition.Replacement?
            do {
                replacement = try await galleryProcessor.improve(result, candidates: candidates, viewport: viewport,
                    gap: settings.gap, displays: scene.displayRegions, onlyIndex: onlyIndex)
            } catch { return photos }
            guard !Task.isCancelled, let replacement else { break }
            optimizationPhotos[scene.id] = result + [replacement.photo]
            pinDisplayedImages()
            let width = Int(ceil(min(8192, max(1, viewport.height * replacement.photo.aspectRatio))))
            let prepared = await imageStore.prepare([replacement.photo], desiredWidths: [PhotoImageKey(replacement.photo): width])
            guard !Task.isCancelled else { return photos }
            if prepared {
                result[replacement.index] = replacement.photo
                planner.remember(replacement.photo, settings: settings)
            }
        }
        return result
    }

    private func optimizeSlot(_ index: Int, pending: PhotoAsset) {
        guard activeSlotOptimization == nil, let scene = currentScene else { return }
        activeSlotOptimization = index
        slotOptimizationTask = Task { [weak self] in
            guard let self else { return }
            var photos = self.slots.map(\.asset)
            photos[index] = self.imageStore?.assetWithFaces(pending) ?? pending
            let improved = await self.improvedPhotos(photos, scene: scene, onlyIndex: index, passes: 1)
            let frames = await self.galleryProcessor.frames(improved, viewport: self.viewport, gap: self.settings.gap, displays: scene.displayRegions)
            guard !Task.isCancelled, self.currentScene?.id == scene.id, self.pendingSlots[index] == pending else { return }
            self.slotPreparedFrames[index] = frames
            self.pendingSlots[index] = improved[index]
            self.optimizedSlots.insert(index)
            self.optimizationPhotos.removeValue(forKey: scene.id)
            self.slotOptimizationTask = nil
            self.pinDisplayedImages()
        }
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
        for photos in optimizationPhotos.values { for photo in photos { add(photo, mode: .gallery) } }
        decodeWidths = widths
        imageStore?.setDisplayedAssets(displayed, cacheMegabytes: settings.cacheMegabytes, desiredWidths: widths, owner: cacheOwner)
    }

    private func galleryFrames(_ assets: [PhotoAsset]) -> [CGRect] {
        FaceSafeLayout.gallery(assets, viewport: viewport, gap: settings.gap,
            displays: settings.avoidFaceDisplayBoundaries ? currentScene?.displayRegions ?? [] : [])
    }

    func synchronizeStart(now: TimeInterval) {
        clock.reset(at: now); sceneStartedAt = 0
        clock.setPaused(isPaused, at: now)
    }

    private func replaceSlot(_ index: Int, with photo: PhotoAsset, elapsed: TimeInterval) {
        let from = galleryLayout?.frames(elapsed: elapsed, duration: settings.fadeSeconds)
            ?? galleryFrames(slots.map(\.asset))
        slots[index].previousAsset = slots[index].asset
        slots[index].asset = imageStore?.assetWithFaces(photo) ?? photo
        slots[index].changedAt = elapsed
        currentScene?.assets[index] = slots[index].asset
        galleryLayout = GalleryFrameTransition(from: from,
            to: slotPreparedFrames.removeValue(forKey: index) ?? galleryFrames(slots.map(\.asset)), startedAt: elapsed)
        slots[index].nextReplacementAt = elapsed + settings.fadeSeconds + planner.galleryInterval(settings: settings)
        pendingSlots.removeValue(forKey: index)
        optimizedSlots.remove(index)
        if activeSlotOptimization == index { activeSlotOptimization = nil }
        slotPreparations.removeValue(forKey: index)
        pinDisplayedImages()
    }

    private func updateGallery(elapsed: TimeInterval) {
        for index in slots.indices {
            if slots[index].previousAsset != nil, elapsed - slots[index].changedAt >= settings.fadeSeconds {
                slots[index].previousAsset = nil; pinDisplayedImages()
            }
            if let pending = pendingSlots[index], let imageStore {
                if imageStore.isReady([pending]) && (!needsFaces(currentScene!) || imageStore.facesReady([pending])) {
                    if needsPreparedGallery(currentScene!), !optimizedSlots.contains(index) {
                        if activeSlotOptimization == nil { optimizeSlot(index, pending: pending) }
                    } else { replaceSlot(index, with: pending, elapsed: elapsed) }
                }
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
                if let imageStore, !imageStore.isReady([photo]) || (needsFaces(currentScene!) && !imageStore.facesReady([photo])) { slotPreparations[index] = prepare([photo]) }
                else if needsPreparedGallery(currentScene!), imageStore != nil {
                    if activeSlotOptimization == nil { optimizeSlot(index, pending: photo) }
                } else { replaceSlot(index, with: photo, elapsed: elapsed) }
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
