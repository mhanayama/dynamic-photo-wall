import Foundation
import Observation

nonisolated struct WallSurfacePlan: Sendable {
    let displayID: UInt32?
    let viewport: CGSize
    let scene: WallScene
}

extension WallScenePlanner {
    /// A single mode draw and selector history serve all surfaces in this group.
    func nextGroup(assets: [PhotoAsset], settings: WallSettings, group: WallDisplayGroup,
                   connected: Set<UInt32>, excluding: Set<URL> = [], allowGalleryRepeat: Bool = false,
                   continuation: [WallSurfacePlan]? = nil) -> [WallSurfacePlan]? {
        let displays = group.displays.filter { connected.contains($0.id) }
        guard !displays.isEmpty else { return nil }
        var eligible = settings
        if assets.count < 2 { eligible.galleryScrollEnabled = false }
        var candidates: [WallMode: [PhotoAsset]] = [:]
        for mode in WallMode.allCases {
            let pool = assets.filter { asset in
                if settings.perDisplay(mode) {
                    return displays.contains { Self.isSafeEligible(asset, for: mode, settings: settings, viewport: $0.rect.size) }
                }
                if Self.needsMirror(asset, for: mode, viewport: group.viewport, displays: displays, settings: settings) {
                    return Self.shouldMirror(asset, for: mode, viewport: group.viewport, displays: displays, settings: settings)
                }
                return Self.isSafeEligible(asset, for: mode, settings: settings, viewport: group.viewport)
                    && (![.verticalPan, .horizontalPan, .zoom].contains(mode) || FaceMotionSafety.plan(for: mode, asset: asset,
                        viewport: group.viewport, settings: settings, displayRegions: displays.map { group.region($0) }) != nil)
            }
            let available = settings.perDisplay(mode)
                ? displays.allSatisfy { d in pool.contains { Self.isSafeEligible($0, for: mode, settings: settings, viewport: d.rect.size) } }
                : !pool.isEmpty
            candidates[mode] = pool
            if !available { eligible.disable(mode) }
        }
        // Draw on a viewport where eligibility will not discard per-display or mirror
        // candidates. The normal planner still applies weights and repeat suppression.
        guard let mode = chooseGroupMode(settings: eligible, allowGalleryRepeat: allowGalleryRepeat) else { return nil }
        if continuation?.first?.scene.mode == mode, ModeSelection.isGallery(mode) { return continuation }
        guard let pool = candidates[mode] else { return nil }
        if settings.perDisplay(mode) {
            var used = excluding
            return displays.compactMap { display in
                guard let scene = next(assets: pool, settings: settings, viewport: display.rect.size, excluding: used, forcedMode: mode) else { return nil }
                used.formUnion(scene.assets.map(\.url))
                return WallSurfacePlan(displayID: display.id, viewport: display.rect.size, scene: scene)
            }
        }
        // The selected photo determines automatic mirroring, independently of faces.
        if [.verticalPan, .horizontalPan, .zoom].contains(mode) {
            guard let asset = replacement(assets: pool, settings: settings, excluding: excluding)
                    ?? replacement(assets: pool, settings: settings, excluding: []) else { return nil }
            if Self.shouldMirror(asset, for: mode, viewport: group.viewport, displays: displays, settings: settings) {
                guard let scene = next(assets: [asset], settings: settings, viewport: displays[0].rect.size, forcedMode: mode) else { return nil }
                return displays.map { WallSurfacePlan(displayID: $0.id, viewport: $0.rect.size, scene: scene) }
            }
            guard var scene = next(assets: [asset], settings: settings, viewport: group.viewport, forcedMode: mode) else { return nil }
            scene.displayRegions = displays.map { group.region($0) }
            return [WallSurfacePlan(displayID: nil, viewport: group.viewport, scene: scene)]
        }
        guard var scene = next(assets: pool, settings: settings, viewport: group.viewport, excluding: excluding, forcedMode: mode, displayRegions: displays.map { group.region($0) }) else { return nil }
        scene.displayRegions = displays.map { group.region($0) }
        return [WallSurfacePlan(displayID: nil, viewport: group.viewport, scene: scene)]
    }

    nonisolated static func needsMirror(_ asset: PhotoAsset, for mode: WallMode, viewport: CGSize, displays: [WallDisplay], settings: WallSettings) -> Bool {
        [.verticalPan, .horizontalPan, .zoom].contains(mode) && !settings.perDisplay(mode)
            && displays.contains { $0.width < viewport.width || $0.height < viewport.height }
            && MirrorPolicy.isBelowHalf(imageWidth: asset.pixelWidth, imageHeight: asset.pixelHeight, group: viewport)
    }
    nonisolated static func shouldMirror(_ asset: PhotoAsset, for mode: WallMode = .verticalPan, viewport: CGSize, displays: [WallDisplay], settings: WallSettings) -> Bool {
        needsMirror(asset, for: mode, viewport: viewport, displays: displays, settings: settings)
            && displays.allSatisfy { isEligible(asset, for: mode, settings: settings, viewport: $0.rect.size)
                && FaceMotionSafety.plan(for: mode, asset: asset, viewport: $0.rect.size, settings: settings) != nil }
    }
}

extension WallSettings {
    mutating func disable(_ mode: WallMode) {
        switch mode {
        case .gallery: galleryEnabled = false
        case .horizontalGallery: galleryScrollEnabled = false
        case .verticalPan: verticalPanEnabled = false
        case .horizontalPan: horizontalPanEnabled = false
        case .zoom: zoomEnabled = false
        }
    }
}

@MainActor
@Observable
final class WallGroupPlayback {
    @MainActor @Observable
    final class Surface: Identifiable {
        let id = UUID()
        let displayID: UInt32?
        let playback: WallPlaybackController
        var ambients: [Int: AmbientSampler] = [:]
        init(displayID: UInt32?, playback: WallPlaybackController) {
            self.displayID = displayID; self.playback = playback
            if let scene = playback.currentScene { ambients[scene.id] = AmbientSampler() }
        }
        func stopAmbient() { for ambient in ambients.values { ambient.stop() } }
    }
    struct Batch: Identifiable {
        let id = UUID()
        let surfaces: [Surface]
        let galleryRotation: GalleryRotation
        var assets: [PhotoAsset] { surfaces.flatMap { $0.playback.currentScene?.assets ?? [] } }
    }
    let group: WallDisplayGroup
    let connected: Set<UInt32>
    let settings: WallSettings
    private(set) var current: Batch?
    private(set) var outgoing: Batch?
    private(set) var prepared: Batch?
    private(set) var paused = false
    private(set) var waiting = false
    private(set) var fade = 1.0
    private var assets: [PhotoAsset]
    private let images: PhotoImageStore?
    private let planner: WallScenePlanner
    private let fallback: WallPlaybackController
    private var startedAt: TimeInterval?
    private var duration: TimeInterval = 5
    private var clock = WallPlaybackClock()
    private var ready = false
    private var nextGalleryAt: TimeInterval = 0
    private var galleryWasBusy = false
    private var nextModeDrawAt: TimeInterval = 0
    private let legacy: Bool

    var primary: WallPlaybackController { current?.surfaces.first?.playback ?? fallback }
    var isWaiting: Bool { legacy ? primary.isWaiting : waiting }
    var waitingForImages: Bool { legacy ? primary.waitingForImages : (current != nil && !ready) }

    init(group: WallDisplayGroup, connected: Set<UInt32>, assets: [PhotoAsset], settings: WallSettings,
         primary: WallPlaybackController? = nil, imageStore: PhotoImageStore?, seed: UInt64 = .random(in: .min ... .max),
         now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.group = group; self.connected = connected; self.assets = assets; self.settings = settings
        self.images = imageStore; self.planner = WallScenePlanner(seed: seed)
        self.fallback = primary ?? WallPlaybackController(imageStore: imageStore)
        self.legacy = group.displays.count == 1
        clock.reset(at: now)
        if legacy {
            fallback.start(assets: assets, settings: settings, viewport: group.viewport, seed: seed, now: now)
            current = Batch(surfaces: [Surface(displayID: nil, playback: fallback)], galleryRotation: GalleryRotation())
        } else {
            current = buildBatch(now: now)
            waiting = current == nil
        }
    }

    private func buildBatch(now: TimeInterval) -> Batch? {
        guard clock.elapsed(at: now) >= nextModeDrawAt else { return nil }
        let excluded = Set((current?.assets ?? []).map(\.url) + (outgoing?.assets ?? []).map(\.url))
        let available = assets.filter { !(images?.failed($0) ?? false) }.map { images?.assetWithFaces($0) ?? $0 }
        guard let plans = planner.nextGroup(assets: available, settings: settings, group: group, connected: connected, excluding: excluded) else {
            if planner.lastDrawSkipped { nextModeDrawAt = clock.elapsed(at: now) + 5 }
            return nil
        }
        let rotation = GalleryRotation()
        let surfaces = plans.map { plan in
            let playback = WallPlaybackController(imageStore: images)
            playback.start(assets: available, settings: settings, viewport: plan.viewport, now: now,
                           scene: plan.scene, externallyManaged: true, sharedPlanner: planner, galleryRotation: rotation)
            playback.setPaused(true, now: now)
            return Surface(displayID: plan.displayID, playback: playback)
        }
        return Batch(surfaces: surfaces, galleryRotation: rotation)
    }

    func update(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if legacy { primary.update(now: now); updateAmbient(current, now: now); return }
        guard !waiting else { return }
        if current == nil { current = buildBatch(now: now); ready = false }
        guard let current else { waiting = true; return }
        for s in current.surfaces { s.playback.update(now: now) }
        for s in prepared?.surfaces ?? [] { s.playback.update(now: now) }
        if current.surfaces.contains(where: { $0.playback.currentScene == nil }) {
            dispose(current); self.current = buildBatch(now: now); ready = false; waiting = self.current == nil; return
        }
        if !ready {
            guard current.surfaces.allSatisfy({ !$0.playback.waitingForImages }) else { return }
            ready = true; waiting = false
            startedAt = clock.elapsed(at: now); fade = outgoing == nil ? 1 : 0
            nextGalleryAt = settings.fadeSeconds + planner.galleryInterval(settings: settings); galleryWasBusy = false
            duration = current.surfaces.map { $0.playback.sceneDuration }.max() ?? 5
            for s in current.surfaces {
                s.playback.synchronizeStart(now: now)
                s.playback.setPaused(paused, now: now)
            }
        }
        let elapsed = clock.elapsed(at: now) - (startedAt ?? 0)
        if !paused, current.surfaces.first?.playback.currentScene?.mode == .gallery {
            let busy = current.surfaces.contains { $0.playback.galleryBusy }
            if galleryWasBusy, !busy { nextGalleryAt = elapsed + planner.galleryInterval(settings: settings); galleryWasBusy = false }
            if !busy, !galleryWasBusy, elapsed >= nextGalleryAt {
                let eligible = current.galleryRotation.eligible(current.assets)
                let choices = current.surfaces.flatMap { surface in surface.playback.slots.filter { eligible.contains($0.asset.url) }.map { (surface, $0.asset.url) } }
                if let (surface, target) = choices.randomElement() {
                    galleryWasBusy = surface.playback.shuffleGallery(now: now, excluding: Set(current.assets.map(\.url)), targetURL: target)
                }
                if !galleryWasBusy { nextGalleryAt = elapsed + planner.galleryInterval(settings: settings) }
            }
        }
        fade = outgoing == nil ? 1 : WallAnimation.ease(elapsed / settings.fadeSeconds)
        if fade >= 1, let outgoing { dispose(outgoing); self.outgoing = nil }
        updateAmbient(current, now: now)
        if prepared == nil { prepared = buildBatch(now: now) }
        if elapsed >= duration + settings.fadeSeconds { next(now: now) }
    }

    private func updateAmbient(_ batch: Batch?, now: TimeInterval) {
        for s in batch?.surfaces ?? [] {
            let layers = s.playback.layers(now: now)
            let ids = Set(layers.map(\.id))
            for id in s.ambients.keys.filter({ !ids.contains($0) }) { s.ambients.removeValue(forKey: id)?.stop() }
            for layer in layers {
                let sampler: AmbientSampler
                if let existing = s.ambients[layer.id] { sampler = existing }
                else { sampler = AmbientSampler(); s.ambients[layer.id] = sampler }
                if settings.glassBackground, let images {
                    sampler.update(layer.presentation, settings: settings, viewport: s.playback.viewport,
                        images: images, paused: (paused && sampler.image != nil) || layer.id != s.playback.currentScene?.id)
                }
            }
        }
    }

    func next(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if legacy { primary.next(now: now); return }
        if waiting { images?.clearFailures() }
        guard let next = prepared ?? buildBatch(now: now) else {
            if current != nil && (planner.lastDrawSkipped || clock.elapsed(at: now) < nextModeDrawAt) { return }
            waiting = true
            for s in current?.surfaces ?? [] { s.playback.setPaused(true, now: now); s.stopAmbient() }
            return
        }
        waiting = false
        prepared = nil
        if let outgoing { dispose(outgoing) }
        outgoing = current
        for s in outgoing?.surfaces ?? [] { s.playback.setPaused(true, now: now); s.stopAmbient() }
        current = next; ready = false; fade = 0
        update(now: now)
    }

    func setPaused(_ value: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard value != paused else { return }
        clock.setPaused(value, at: now); paused = value
        for s in current?.surfaces ?? [] {
            s.playback.setPaused(value || (!legacy && !ready), now: now)
            if value { s.stopAmbient() }
        }
    }

    func updateLibrary(_ assets: [PhotoAsset], now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.assets = assets
        if legacy { primary.updateLibrary(assets: assets, now: now); return }
        images?.clearFailures()
        if let prepared { dispose(prepared); self.prepared = nil }
        let versions = Set(assets.map(PhotoImageKey.init))
        if waiting || current == nil || current?.assets.contains(where: { !versions.contains(PhotoImageKey($0)) }) == true {
            planner.resetModeHistory(); nextModeDrawAt = 0
            next(now: now)
        } else {
            for s in current?.surfaces ?? [] { s.playback.updateLibrary(assets: assets, retryFailed: false, now: now) }
        }
    }

    private func dispose(_ batch: Batch) { for s in batch.surfaces { s.playback.stop(); s.stopAmbient() } }
    func stop() {
        if let current { dispose(current) }; if let outgoing { dispose(outgoing) }; if let prepared { dispose(prepared) }
        current = nil; outgoing = nil; prepared = nil; fallback.stop()
    }
}
