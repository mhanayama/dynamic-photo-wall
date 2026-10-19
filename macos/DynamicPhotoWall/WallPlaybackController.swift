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
    var previousFrame: CGRect? = nil
    var appearing = false
}

nonisolated struct GalleryRemoved: Equatable, Sendable { var asset: PhotoAsset; var frame: CGRect; var at: TimeInterval }

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
    var galleryRemoved: [GalleryRemoved] = []
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
    private var removedGallery: [GalleryRemoved] = []
    private var nextGalleryAt: TimeInterval = 0
    private var nextModeDrawAt: TimeInterval = 0
    @ObservationIgnored private var galleryRotation = GalleryRotation()
    var galleryBusy: Bool { !pendingSlots.isEmpty || slots.contains { $0.previousAsset != nil || $0.appearing } || !removedGallery.isEmpty }
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
            .map { imageStore?.assetWithFaces($0) ?? $0 }
    }

    private func needsFaces(_ scene: WallScene) -> Bool {
        [.verticalPan, .horizontalPan, .zoom].contains(scene.mode)
            || ([.gallery, .verticalPan].contains(scene.mode) && settings.avoidFaceDisplayBoundaries
                && FaceSafeLayout.requiresProtection(viewport, displays: scene.displayRegions))
    }

    private func isPrepared(_ scene: WallScene) -> Bool {
        guard let imageStore else { return true }
        return imageStore.isReady(scene.assets) && (!needsFaces(scene) || imageStore.facesReady(scene.assets))
            && (!needsPreparedGallery(scene) || galleryCompleted.contains(scene.id))
    }

    private func applyPreparedFaces() {
        guard var scene = currentScene else { return }
        scene.assets = scene.assets.map { imageStore?.assetWithFaces($0) ?? $0 }
        if [.verticalPan, .horizontalPan, .zoom].contains(scene.mode), let asset = scene.assets.first,
           FaceMotionSafety.plan(for: scene.mode, asset: asset, viewport: viewport, settings: settings,
                reverse: scene.reverse, center: scene.zoomCenter, displayRegions: scene.displayRegions) == nil {
            currentScene = nil; slots = []; waitingForImages = false; return
        }
        if scene.mode == .gallery {
            let items = FixedGalleryLayout.arrange(scene.assets, viewport: viewport, gap: settings.gap,
                displays: settings.avoidFaceDisplayBoundaries ? scene.displayRegions : [])
            guard !items.isEmpty else { currentScene = nil; slots = []; waitingForImages = false; return }
            let previousSlots = slots
            slots = items.map { item in var slot = previousSlots[item.index]; slot.asset = scene.assets[item.index]; return slot }
            scene.assets = items.map { scene.assets[$0.index] }
            let frames = items.map(\.frame); galleryLayout = GalleryFrameTransition(from: frames, to: frames, startedAt: 0)
        }
        currentScene = scene
        sceneDuration = WallMotionGeometry.duration(for: scene, viewport: viewport, settings: settings)
    }

    func start(assets: [PhotoAsset], settings: WallSettings, viewport: CGSize,
               seed: UInt64 = .random(in: .min ... .max), now: TimeInterval = ProcessInfo.processInfo.systemUptime,
               scene: WallScene? = nil, externallyManaged: Bool = false, displayRegions: [CGRect] = [],
               sharedPlanner: WallScenePlanner? = nil, galleryRotation: GalleryRotation? = nil) {
        stop()
        self.assets = assets
        self.settings = settings
        self.viewport = viewport
        self.managedScene = scene
        self.externallyManaged = externallyManaged
        self.displayRegions = displayRegions
        planner = sharedPlanner ?? WallScenePlanner(seed: seed)
        self.galleryRotation = galleryRotation ?? GalleryRotation()
        nextModeDrawAt = 0
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
        removedGallery = []; nextGalleryAt = 0
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
            // Replacing an invalid visible asset must bypass duplicate-mode suppression.
            planner.resetModeHistory(); nextModeDrawAt = 0
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
        planner.resetModeHistory(); nextModeDrawAt = 0
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
                                     elapsed: elapsed, slots: slots, scrollDistance: scrollDistance(elapsed: elapsed), galleryLayout: galleryLayout, galleryRemoved: removedGallery)
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
                if self.currentScene == nil { moveToNext(at: activeTime); return }
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
        if !externallyManaged { preloadNextScene(at: activeTime) }
        let elapsed = activeTime - sceneStartedAt
        if outgoing != nil, elapsed >= settings.fadeSeconds { outgoing = nil; pinDisplayedImages() }
        if !externallyManaged, elapsed >= sceneDuration + settings.fadeSeconds {
            moveToNext(at: activeTime)
            if self.currentScene?.id != currentScene.id { return }
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
        if managedScene == nil, preloadedScene == nil, currentScene != nil, time < nextModeDrawAt { return }
        let previous = waitingForImages ? nil : presentation(atActiveTime: time)
        var excluded = Set(currentScene?.assets.map(\.url) ?? [])
        excluded.formUnion(outgoingPhotoURLs)
        excluded.formUnion(slots.compactMap { $0.previousAsset?.url })
        var next = managedScene ?? preloadedScene ?? (externallyManaged ? nil : planner.next(assets: availableAssets, settings: settings, viewport: viewport, excluding: excluded, displayRegions: displayRegions))
        if next == nil, planner.lastDrawSkipped, currentScene != nil {
            nextModeDrawAt = time + 5; return
        }
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
        if !externallyManaged { galleryRotation = GalleryRotation() }
        nextModeDrawAt = 0
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
                        nextReplacementAt: .infinity)
        } : []
        removedGallery = []; nextGalleryAt = settings.fadeSeconds + planner.galleryInterval(settings: settings)
        pinDisplayedImages()
        // Readiness must use the newly selected mode's dimensions, not the old ones.
        waitingForImages = !isPrepared(next)
        if !waitingForImages {
            applyPreparedFaces()
            if currentScene == nil, !externallyManaged { moveToNext(at: time); return }
        }
        scenePreparation = prepareScene(next)
        if !waitingForImages, next.mode == .horizontalGallery { prepareNextScrollPhoto(elapsed: 0) }
    }

    private func preloadNextScene(at time: TimeInterval) {
        guard imageStore != nil, !waitingForImages, preloadedScene == nil, time >= nextModeDrawAt, let scene = currentScene else { return }
        let excluded = Set(scene.assets.map(\.url)).union(outgoingPhotoURLs)
        guard var next = planner.next(assets: availableAssets, settings: settings, viewport: viewport, excluding: excluded, displayRegions: displayRegions) else { nextModeDrawAt = time + 5; return }
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
        false // Fixed-size layout filters/reflows instead of shrinking a row.
    }

    private func canImproveGallery(_ scene: WallScene) -> Bool {
        false // The former shrink-based loss is not the current layout policy.
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
            case .gallery: width = viewport.width >= viewport.height ? viewport.height * photo.aspectRatio : viewport.width
            case .horizontalGallery, .horizontalPan: width = viewport.height * photo.aspectRatio
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
            for item in old.galleryRemoved { add(item.asset, mode: .gallery) }
        }
        for photo in slots.compactMap(\.previousAsset) { add(photo, mode: .gallery) }
        for item in removedGallery { add(item.asset, mode: .gallery) }
        for photo in pendingSlots.values { add(photo, mode: .gallery) }
        if let pendingScroll { add(pendingScroll, mode: .horizontalGallery) }
        for photos in optimizationPhotos.values { for photo in photos { add(photo, mode: .gallery) } }
        decodeWidths = widths
        imageStore?.setDisplayedAssets(displayed, cacheMegabytes: settings.cacheMegabytes, desiredWidths: widths, owner: cacheOwner)
    }

    private func galleryFrames(_ assets: [PhotoAsset]) -> [CGRect] {
        FixedGalleryLayout.arrange(assets, viewport: viewport, gap: settings.gap,
            displays: settings.avoidFaceDisplayBoundaries ? currentScene?.displayRegions ?? [] : []).map(\.frame)
    }

    func synchronizeStart(now: TimeInterval) {
        clock.reset(at: now); sceneStartedAt = 0
        clock.setPaused(isPaused, at: now)
    }

    @discardableResult
    private func replaceSlot(_ index: Int, with photo: PhotoAsset, elapsed: TimeInterval) -> Bool {
        let old = slots
        let before = galleryLayout?.frames(elapsed: elapsed, duration: settings.fadeSeconds) ?? galleryFrames(old.map(\.asset))
        let replacement = imageStore?.assetWithFaces(photo) ?? photo
        let change = FixedGalleryLayout.update(old.map(\.asset), incoming: replacement, viewport: viewport, gap: settings.gap,
            displays: settings.avoidFaceDisplayBoundaries ? currentScene?.displayRegions ?? [] : [], replacement: index, maximum: settings.galleryMax)
        pendingSlots.removeAll(); slotPreparations.removeAll(); optimizedSlots = []; activeSlotOptimization = nil
        nextGalleryAt = elapsed + settings.fadeSeconds + planner.galleryInterval(settings: settings)
        guard let change, before.count == old.count else { return false }
        let items = change.items, incoming = change.incomingIndex
        func original(_ index: Int) -> Int { change.isAddition && index > incoming ? index - 1 : index }
        let kept = Set(items.filter { !change.isAddition || $0.index != incoming }.map { original($0.index) })
        for i in old.indices where !kept.contains(i) { removedGallery.append(GalleryRemoved(asset: old[i].asset, frame: before[i], at: elapsed)) }
        var from: [CGRect] = []
        slots = items.map { item in
            if change.isAddition && item.index == incoming {
                from.append(item.frame)
                return GallerySlot(id: (old.map(\.id).max() ?? -1) + 1, asset: replacement, changedAt: elapsed,
                    nextReplacementAt: .infinity, appearing: true)
            }
            let oldIndex = original(item.index)
            var slot = old[oldIndex]
            if item.index == incoming {
                slot.previousAsset = slot.asset; slot.previousFrame = before[oldIndex]
                slot.asset = replacement; slot.changedAt = elapsed; slot.appearing = true
            }
            var start = before[oldIndex]
            start.size = item.frame.size // Never resize the replacement's short axis during its fade.
            from.append(start); return slot
        }
        currentScene?.assets = slots.map(\.asset)
        galleryRotation.inserted(replacement)
        galleryLayout = GalleryFrameTransition(from: from, to: items.map(\.frame), startedAt: elapsed)
        pinDisplayedImages(); return true
    }

    private func requestGalleryShuffle(elapsed: TimeInterval, excluding extra: Set<URL> = [], targetURL: URL? = nil) -> Bool {
        guard !slots.isEmpty, !galleryBusy else { return false }
        let eligible = targetURL.map { Set([$0]) } ?? galleryRotation.eligible(slots.map(\.asset))
        guard let index = slots.indices.filter({ eligible.contains(slots[$0].asset.url) }).randomElement() else { return false }
        var excluded = Set(slots.map { $0.asset.url }); excluded.formUnion(extra)
        excluded.formUnion(outgoingPhotoURLs)
        let additions = slots.count < settings.galleryMax ? availableAssets.filter { p in
            !excluded.contains(p.url) && FixedGalleryLayout.update(slots.map(\.asset), incoming: p, viewport: viewport, gap: settings.gap,
                displays: settings.avoidFaceDisplayBoundaries ? currentScene?.displayRegions ?? [] : [], replacement: -1, maximum: settings.galleryMax)?.isAddition == true
        } : []
        guard let photo = planner.replacement(assets: additions.isEmpty ? availableAssets : additions, settings: settings, excluding: excluded) else { return false }
        pendingSlots[index] = photo; pinDisplayedImages()
        if let imageStore, !imageStore.isReady([photo]) || (needsFaces(currentScene!) && !imageStore.facesReady([photo])) {
            slotPreparations[index] = prepare([photo])
        } else { replaceSlot(index, with: photo, elapsed: elapsed) }
        return true
    }

    @discardableResult
    func shuffleGallery(now: TimeInterval, excluding: Set<URL> = [], targetURL: URL? = nil) -> Bool {
        guard currentScene?.mode == .gallery, !isPaused, !waitingForImages else { return false }
        return requestGalleryShuffle(elapsed: max(0, clock.elapsed(at: now) - sceneStartedAt), excluding: excluding, targetURL: targetURL)
    }

    private func updateGallery(elapsed: TimeInterval) {
        var released = false
        for i in slots.indices where (slots[i].previousAsset != nil || slots[i].appearing) && elapsed - slots[i].changedAt >= settings.fadeSeconds {
            slots[i].previousAsset = nil; slots[i].previousFrame = nil; slots[i].appearing = false
            released = true
        }
        let removedCount = removedGallery.count
        removedGallery.removeAll { elapsed - $0.at >= settings.fadeSeconds }
        if released || removedGallery.count != removedCount { pinDisplayedImages() }
        if let (index, pending) = pendingSlots.first, let imageStore {
            if imageStore.isReady([pending]) && (!needsFaces(currentScene!) || imageStore.facesReady([pending])) {
                replaceSlot(index, with: pending, elapsed: elapsed)
            } else if imageStore.failed(pending) {
                failedVersions.insert(PhotoImageKey(pending)); pendingSlots.removeAll(); slotPreparations.removeAll()
                nextGalleryAt = elapsed + planner.galleryInterval(settings: settings); pinDisplayedImages()
            }
            return
        }
        if !externallyManaged, !galleryBusy, elapsed >= nextGalleryAt {
            if !requestGalleryShuffle(elapsed: elapsed) { nextGalleryAt = elapsed + planner.galleryInterval(settings: settings) }
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
