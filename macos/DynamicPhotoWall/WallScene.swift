import CoreGraphics
import Foundation

nonisolated enum WallMode: String, CaseIterable, Codable, Equatable, Sendable {
    case gallery, horizontalGallery, verticalPan, horizontalPan, zoom

    var displayName: String {
        switch self {
        case .gallery: "Gallery"
        case .horizontalGallery: "Scrolling Gallery"
        case .verticalPan: "Vertical Pan"
        case .horizontalPan: "Horizontal Pan"
        case .zoom: "Cinematic Zoom"
        }
    }
}

nonisolated struct WallScene: Equatable, Sendable {
    let id: Int
    let mode: WallMode
    var assets: [PhotoAsset]
    var displayRegions: [CGRect] = []
    var reverse = false
    var zoomCenter = CGPoint(x: 0.5, y: 0.5)
}

/// One planner and one selector live for the entire playback session.
@MainActor
final class WallScenePlanner {
    private let selector: PhotoSelector
    private var generator: SeededRandomNumberGenerator
    private var previous: WallMode?
    private var repeats = 0
    private(set) var lastDrawSkipped = false
    private var nextID = 0
    func resetModeHistory() { previous = nil; repeats = 0; lastDrawSkipped = false }

    init(seed: UInt64 = .random(in: .min ... .max)) {
        selector = PhotoSelector(seed: seed)
        generator = SeededRandomNumberGenerator(seed: seed ^ 0xA076_1D64_78BD_642F)
    }

    func next(assets: [PhotoAsset], settings: WallSettings, viewport: CGSize,
              excluding: Set<URL> = [], forcedMode: WallMode? = nil, displayRegions: [CGRect] = []) -> WallScene? {
        lastDrawSkipped = false
        func availableChoices(excluding: Set<URL>) -> [Choice] {
            eligibleChoices(assets: assets, settings: settings, viewport: viewport, excluding: excluding)
                .filter { forcedMode == nil || $0.mode == forcedMode }
                .map { choice in
                    Choice(mode: choice.mode, assets: choice.assets.filter { asset in
                        if choice.mode == .gallery, settings.avoidFaceDisplayBoundaries {
                            return !FixedGalleryLayout.arrange([asset], viewport: viewport, gap: settings.gap, displays: displayRegions).isEmpty
                        }
                        return ![.verticalPan, .horizontalPan, .zoom].contains(choice.mode)
                            || FaceMotionSafety.plan(for: choice.mode, asset: asset, viewport: viewport, settings: settings, displayRegions: displayRegions) != nil
                    })
                }.filter { !$0.assets.isEmpty }
        }
        var choices = availableChoices(excluding: excluding)
        if choices.isEmpty, !excluding.isEmpty {
            choices = availableChoices(excluding: [])
        }
        guard !choices.isEmpty else { return nil }
        let weights = ModeSelection.weights(gallery: settings.galleryWeight, pan: settings.panWeight, zoom: settings.zoomWeight)
        guard let mode = ModeSelection.pick(choices.map(\.mode), galleryWeight: weights.gallery, motionWeight: weights.motion,
            previous: forcedMode == nil ? previous : nil, repeats: forcedMode == nil ? repeats : 0, using: &generator),
              let chosen = choices.first(where: { $0.mode == mode }) else { lastDrawSkipped = true; return nil }
        var selected: [PhotoAsset] = []
        var used: Set<URL> = []
        let count: Int
        switch chosen.mode {
        case .gallery:
            count = settings.galleryMax
        case .horizontalGallery: count = min(24, chosen.assets.count)
        default: count = 1
        }
        let portraits = chosen.assets.filter { viewport.width >= viewport.height ? $0.aspectRatio < 1 : $0.aspectRatio >= 1 }
        var stripWidth = settings.gap
        for _ in 0..<count {
            let fitting = chosen.mode == .gallery ? chosen.assets.filter { p in
                !used.contains(p.url) && FixedGalleryLayout.arrange(selected + [p], viewport: viewport, gap: settings.gap,
                    displays: settings.avoidFaceDisplayBoundaries ? displayRegions : []).count == selected.count + 1
            } : chosen.assets
            let preferredFits = fitting.filter { p in portraits.contains { $0.url == p.url } }
            let pool = (chosen.mode == .gallery || chosen.mode == .horizontalGallery)
                && preferredFits.contains(where: { !used.contains($0.url) }) ? preferredFits : fitting
            guard let photo = selector.pick(from: pool, settings: settings, excluding: used) else { break }
            selected.append(photo)
            used.insert(photo.url)
            stripWidth += max(1, viewport.height - 2 * settings.gap) * photo.aspectRatio + settings.gap
            if chosen.mode == .horizontalGallery, selected.count >= 2,
               stripWidth >= viewport.width + viewport.height * 1.5 { break }
        }
        if chosen.mode == .gallery { selected = FixedGalleryLayout.arrange(selected, viewport: viewport, gap: settings.gap,
            displays: settings.avoidFaceDisplayBoundaries ? displayRegions : []).map { selected[$0.index] } }
        guard !selected.isEmpty else { return nil }
        if forcedMode == nil {
            repeats = chosen.mode == previous ? repeats + 1 : 1
            previous = chosen.mode
        }
        defer { nextID += 1 }
        return WallScene(id: nextID, mode: chosen.mode, assets: selected,
                         reverse: Bool.random(using: &generator),
                         zoomCenter: CGPoint(x: Double.random(in: 0.35...0.65, using: &generator),
                                             y: Double.random(in: 0.35...0.65, using: &generator)))
    }

    func chooseGroupMode(settings: WallSettings, allowGalleryRepeat: Bool = false) -> WallMode? {
        lastDrawSkipped = false
        let weights = ModeSelection.weights(gallery: settings.galleryWeight, pan: settings.panWeight, zoom: settings.zoomWeight)
        let definitions: [(WallMode, Bool, Double)] = [
            (.gallery, settings.galleryEnabled, Double(weights.gallery)),
            (.horizontalGallery, settings.galleryScrollEnabled, Double(weights.gallery)),
            (.verticalPan, settings.verticalPanEnabled, Double(weights.motion)),
            (.horizontalPan, settings.horizontalPanEnabled, Double(weights.motion)),
            (.zoom, settings.zoomEnabled, Double(weights.motion))
        ]
        let choices = definitions.filter { $0.1 && $0.2 > 0 }
        guard let mode = ModeSelection.pick(choices.map { $0.0 }, galleryWeight: weights.gallery, motionWeight: weights.motion,
            previous: previous, repeats: repeats, using: &generator, allowGalleryRepeat: allowGalleryRepeat) else { lastDrawSkipped = !choices.isEmpty; return nil }
        repeats = mode == previous ? repeats + 1 : 1; previous = mode
        return mode
    }

    func sampleKnownFaces(_ assets: [PhotoAsset], settings: WallSettings, excluding: Set<URL>) -> [PhotoAsset] {
        selector.sample(from: assets, settings: settings, excluding: excluding, count: GalleryComposition.candidateLimit)
    }
    func remember(_ asset: PhotoAsset, settings: WallSettings) { selector.remember(asset, settings: settings) }

    func replacement(assets: [PhotoAsset], settings: WallSettings, excluding: Set<URL>) -> PhotoAsset? {
        selector.pick(from: assets, settings: settings, excluding: excluding)
    }

    func galleryInterval(settings: WallSettings) -> TimeInterval {
        Double.random(in: settings.galleryMinSeconds...settings.galleryMaxSeconds, using: &generator)
    }

    private struct Choice {
        let mode: WallMode
        let assets: [PhotoAsset]
    }

    private func eligibleChoices(assets: [PhotoAsset], settings: WallSettings, viewport: CGSize,
                                 excluding: Set<URL>) -> [Choice] {
        guard viewport.width > 0, viewport.height > 0 else { return [] }
        let weights = ModeSelection.weights(gallery: settings.galleryWeight, pan: settings.panWeight, zoom: settings.zoomWeight)
        let definitions: [(WallMode, Bool, Int)] = [
            (.gallery, settings.galleryEnabled, weights.gallery),
            (.horizontalGallery, settings.galleryScrollEnabled && assets.count > 1, weights.gallery),
            (.verticalPan, settings.verticalPanEnabled, weights.motion),
            (.horizontalPan, settings.horizontalPanEnabled, weights.motion),
            (.zoom, settings.zoomEnabled, weights.motion)
        ]
        return definitions.compactMap { mode, enabled, weight in
            guard enabled, weight > 0 else { return nil }
            let candidates = assets.filter {
                !excluding.contains($0.url) && Self.isEligible($0, for: mode, settings: settings, viewport: viewport)
                    && (![.verticalPan, .horizontalPan, .zoom].contains(mode) || FaceMotionSafety.plan(for: mode, asset: $0, viewport: viewport, settings: settings) != nil)
            }
            return candidates.isEmpty ? nil : Choice(mode: mode, assets: candidates)
        }
    }

    nonisolated static func isEligible(_ asset: PhotoAsset, for mode: WallMode,
                                       settings: WallSettings, viewport: CGSize) -> Bool {
        guard asset.pixelWidth > 0, asset.pixelHeight > 0 else { return false }
        switch mode {
        case .gallery, .horizontalGallery: return true
        case .verticalPan:
            let width = viewport.width * settings.panWidthFraction
            return asset.aspectRatio < 0.95 && width / CGFloat(asset.pixelWidth) <= settings.maxPanUpscale
                && width / asset.aspectRatio > viewport.height + 20
        case .horizontalPan:
            return asset.aspectRatio > viewport.width / viewport.height * 1.05
                && viewport.height / CGFloat(asset.pixelHeight) <= settings.maxPanUpscale
        case .zoom: return asset.aspectRatio >= 1
        }
    }

    nonisolated static func isSafeEligible(_ asset: PhotoAsset, for mode: WallMode, settings: WallSettings, viewport: CGSize) -> Bool {
        isEligible(asset, for: mode, settings: settings, viewport: viewport)
            && (![.verticalPan, .horizontalPan, .zoom].contains(mode) || FaceMotionSafety.plan(for: mode, asset: asset, viewport: viewport, settings: settings) != nil)
    }
}

nonisolated struct WallMotionPlan: Equatable, Sendable {
    var width: CGFloat
    var height: CGFloat
    var fromX: CGFloat
    var fromY: CGFloat
    var toX: CGFloat
    var toY: CGFloat
    var seconds: TimeInterval
    var frameTop: CGFloat = 0
    var fromScale: Double = 1
    var toScale: Double = 1
    var center: CGPoint = CGPoint(x: 0.5, y: 0.5)

    nonisolated func frame(at progress: Double) -> CGRect {
        let value = CGFloat(min(max(progress, 0), 1))
        return CGRect(
            x: fromX + (toX - fromX) * value,
            y: fromY + (toY - fromY) * value,
            width: width,
            height: height
        )
    }
}

nonisolated enum WallMotionGeometry {
    static func primaryFace(_ asset: PhotoAsset) -> FaceRegion? {
        asset.faces?.sorted {
            if $0.width * $0.height != $1.width * $1.height { return $0.width * $0.height > $1.width * $1.height }
            if $0.y != $1.y { return $0.y < $1.y }
            return $0.x < $1.x
        }.first
    }

    nonisolated static func plan(
        for mode: WallMode,
        asset: PhotoAsset,
        viewport: CGSize,
        settings: WallSettings,
        reverse: Bool = false,
        center: CGPoint = CGPoint(x: 0.5, y: 0.5),
        displayRegions: [CGRect] = []
    ) -> WallMotionPlan {
        switch mode {
        case .verticalPan:
            let directionFace = settings.faceAwarePanDirection ? primaryFace(asset) : nil
            let face = settings.stopAtFace ? directionFace ?? asset.faces?.min(by: { $0.y < $1.y }) : nil
            var width = viewport.width * settings.panWidthFraction
            if let face { width = min(width, viewport.height * 0.92 * asset.aspectRatio / face.height) }
            let height = width / asset.aspectRatio
            let overflow = max(0, height - viewport.height)
            let towardBottom = directionFace.map { $0.y + $0.height / 2 > 0.5 } ?? false
            let start: CGFloat = towardBottom ? 0 : -overflow
            var end: CGFloat = towardBottom ? -overflow : 0
            if let face {
                let half = face.height * height / 2
                let lower = half + viewport.height * 0.04, upper = viewport.height - half - viewport.height * 0.04
                let target = lower <= upper ? min(upper, max(lower, viewport.height * 0.3)) : viewport.height * 0.5
                end = min(0, max(-overflow, target - (face.y + face.height * 0.5) * height))
            }
            let left = (viewport.width - width) / 2
            let seconds = abs(end - start) > 0
                ? max(0.1, TimeInterval(abs(end - start)) / settings.panPixelsPerSecond)
                : 5
            let original = WallMotionPlan(
                width: width,
                height: height,
                fromX: left,
                fromY: start,
                toX: left,
                toY: end,
                seconds: seconds, frameTop: (viewport.height - min(viewport.height, height)) / 2
            )
            return settings.avoidFaceDisplayBoundaries && FaceSafeLayout.requiresProtection(viewport, displays: displayRegions)
                ? FaceSafeLayout.verticalPan(asset, viewport: viewport, settings: settings, displays: displayRegions, original: original) : original

        case .horizontalPan:
            let reverse = settings.faceAwarePanDirection ? primaryFace(asset).map { $0.x + $0.width / 2 < 0.5 } ?? reverse : reverse
            let width = viewport.height * asset.aspectRatio
            let overflow = max(0, width - viewport.width)
            return WallMotionPlan(
                width: width,
                height: viewport.height,
                fromX: reverse ? -overflow : 0,
                fromY: 0,
                toX: reverse ? 0 : -overflow,
                toY: 0,
                seconds: max(5, TimeInterval(overflow) / settings.panPixelsPerSecond)
            )

        case .zoom:
            let scale = max(
                viewport.width / CGFloat(asset.pixelWidth),
                viewport.height / CGFloat(asset.pixelHeight)
            )
            let width = max(viewport.width, CGFloat(asset.pixelWidth) * scale)
            let height = max(viewport.height, CGFloat(asset.pixelHeight) * scale)
            var x = (viewport.width - width) / 2
            var y = (viewport.height - height) / 2
            var anchor = center
            if settings.faceAwareFraming, let face = asset.faces?.max(by: { $0.width * $0.height < $1.width * $1.height }) {
                anchor = CGPoint(x: min(1, max(0, face.x + face.width / 2)), y: min(1, max(0, face.y + face.height / 2)))
                x = min(0, max(viewport.width - width, viewport.width * 0.5 - anchor.x * width))
                let half = face.height * height * settings.maxZoom / 2
                let lower = half + viewport.height * 0.04, upper = viewport.height - half - viewport.height * 0.04
                let target = lower <= upper ? min(upper, max(lower, viewport.height * 0.4)) : viewport.height * 0.5
                y = min(0, max(viewport.height - height, target - anchor.y * height))
            }
            return WallMotionPlan(
                width: width,
                height: height,
                fromX: x,
                fromY: y,
                toX: x,
                toY: y,
                seconds: settings.zoomSeconds,
                fromScale: reverse ? settings.maxZoom : 1,
                toScale: reverse ? 1 : settings.maxZoom,
                center: CGPoint(x: min(1, max(0, anchor.x)), y: min(1, max(0, anchor.y)))
            )

        case .gallery, .horizontalGallery:
            return WallMotionPlan(
                width: viewport.width,
                height: viewport.height,
                fromX: 0,
                fromY: 0,
                toX: 0,
                toY: 0,
                seconds: duration(for: mode, asset: asset, viewport: viewport, settings: settings)
            )
        }
    }

    nonisolated static func duration(
        for scene: WallScene,
        viewport: CGSize,
        settings: WallSettings
    ) -> TimeInterval {
        guard let asset = scene.assets.first else { return 5 }
        let seconds = [.verticalPan, .horizontalPan, .zoom].contains(scene.mode)
            ? FaceMotionSafety.plan(for: scene.mode, asset: asset, viewport: viewport, settings: settings, reverse: scene.reverse, displayRegions: scene.displayRegions)?.seconds ?? 5
            : duration(for: scene.mode, asset: asset, viewport: viewport, settings: settings)
        return seconds + (scene.mode == .verticalPan && settings.stopAtFace && !(asset.faces ?? []).isEmpty ? 3 : 0)
    }

    private nonisolated static func duration(
        for mode: WallMode,
        asset: PhotoAsset,
        viewport: CGSize,
        settings: WallSettings
    ) -> TimeInterval {
        switch mode {
        case .gallery:
            return max(90, settings.galleryMaxSeconds * 2)
        case .horizontalGallery:
            return max(120, settings.galleryMaxSeconds * 3)
        case .verticalPan, .horizontalPan, .zoom:
            return plan(
                for: mode,
                asset: asset,
                viewport: viewport,
                settings: settings,
                reverse: false
            ).seconds
        }
    }
}
