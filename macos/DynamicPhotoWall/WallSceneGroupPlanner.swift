import Foundation
import CoreGraphics

nonisolated struct WallSurfacePlan: Sendable {
    let displayID: UInt32?
    let viewport: CGSize
    let scene: WallScene
}

extension WallScenePlanner {
    /// A single mode draw and selector history serve all surfaces in this group.
    nonisolated func nextGroup(assets: [PhotoAsset], settings: WallSettings, group: WallDisplayGroup,
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
    nonisolated mutating func disable(_ mode: WallMode) {
        switch mode {
        case .gallery: galleryEnabled = false
        case .horizontalGallery: galleryScrollEnabled = false
        case .verticalPan: verticalPanEnabled = false
        case .horizontalPan: horizontalPanEnabled = false
        case .zoom: zoomEnabled = false
        }
    }
}
