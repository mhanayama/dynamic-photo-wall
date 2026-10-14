import CoreGraphics
import Foundation

nonisolated enum WallMode: String, CaseIterable, Equatable, Sendable {
    case gallery, horizontalGallery, verticalPan, horizontalPan, zoom
}

nonisolated struct WallScene: Equatable, Sendable {
    let id: Int
    let mode: WallMode
    var assets: [PhotoAsset]
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
    private var nextID = 0

    init(seed: UInt64 = .random(in: .min ... .max)) {
        selector = PhotoSelector(seed: seed)
        generator = SeededRandomNumberGenerator(seed: seed ^ 0xA076_1D64_78BD_642F)
    }

    func next(assets: [PhotoAsset], settings: WallSettings, viewport: CGSize,
              excluding: Set<URL> = []) -> WallScene? {
        var choices = eligibleChoices(assets: assets, settings: settings, viewport: viewport, excluding: excluding)
        if choices.isEmpty, !excluding.isEmpty {
            choices = eligibleChoices(assets: assets, settings: settings, viewport: viewport, excluding: [])
        }
        guard !choices.isEmpty else { return nil }
        let galleryCount = choices.filter { $0.mode == .gallery || $0.mode == .horizontalGallery }.count
        let panCount = choices.filter { $0.mode == .verticalPan || $0.mode == .horizontalPan }.count
        for index in choices.indices {
            switch choices[index].mode {
            case .gallery, .horizontalGallery: choices[index].weight /= Double(galleryCount)
            case .verticalPan, .horizontalPan: choices[index].weight /= Double(panCount)
            case .zoom: break
            }
        }
        if repeats >= 2, choices.count > 1 { choices.removeAll { $0.mode == previous } }
        var ticket = Double.random(in: 0..<choices.reduce(0) { $0 + $1.weight }, using: &generator)
        let chosen = choices.first { ticket -= $0.weight; return ticket < 0 } ?? choices[choices.count - 1]
        var selected: [PhotoAsset] = []
        var used: Set<URL> = []
        let count: Int
        switch chosen.mode {
        case .gallery:
            count = min(settings.galleryMax, max(1, Int((viewport.width / viewport.height / 0.68).rounded())))
        case .horizontalGallery: count = min(24, chosen.assets.count)
        default: count = 1
        }
        let portraits = chosen.assets.filter { $0.aspectRatio < 1 }
        var stripWidth = settings.gap
        for _ in 0..<count {
            let pool = (chosen.mode == .gallery || chosen.mode == .horizontalGallery)
                && portraits.contains(where: { !used.contains($0.url) }) ? portraits : chosen.assets
            guard let photo = selector.pick(from: pool, settings: settings, excluding: used) else { break }
            selected.append(photo)
            used.insert(photo.url)
            stripWidth += max(1, viewport.height - 2 * settings.gap) * photo.aspectRatio + settings.gap
            if chosen.mode == .horizontalGallery, selected.count >= 2,
               stripWidth >= viewport.width + viewport.height * 1.5 { break }
        }
        guard !selected.isEmpty else { return nil }
        repeats = chosen.mode == previous ? repeats + 1 : 1
        previous = chosen.mode
        defer { nextID += 1 }
        return WallScene(id: nextID, mode: chosen.mode, assets: selected,
                         reverse: Bool.random(using: &generator),
                         zoomCenter: CGPoint(x: Double.random(in: 0.35...0.65, using: &generator),
                                             y: Double.random(in: 0.35...0.65, using: &generator)))
    }

    func replacement(assets: [PhotoAsset], settings: WallSettings, excluding: Set<URL>) -> PhotoAsset? {
        selector.pick(from: assets, settings: settings, excluding: excluding)
    }

    func galleryInterval(settings: WallSettings) -> TimeInterval {
        Double.random(in: settings.galleryMinSeconds...settings.galleryMaxSeconds, using: &generator)
    }

    private struct Choice {
        let mode: WallMode
        let assets: [PhotoAsset]
        var weight: Double
    }

    private func eligibleChoices(assets: [PhotoAsset], settings: WallSettings, viewport: CGSize,
                                 excluding: Set<URL>) -> [Choice] {
        guard viewport.width > 0, viewport.height > 0 else { return [] }
        let definitions: [(WallMode, Bool, Int)] = [
            (.gallery, settings.galleryEnabled, settings.galleryWeight),
            (.horizontalGallery, settings.galleryScrollEnabled && assets.count > 1, settings.galleryWeight),
            (.verticalPan, settings.verticalPanEnabled, settings.panWeight),
            (.horizontalPan, settings.horizontalPanEnabled, settings.panWeight),
            (.zoom, settings.zoomEnabled, settings.zoomWeight)
        ]
        return definitions.compactMap { mode, enabled, weight in
            guard enabled, weight > 0 else { return nil }
            let candidates = assets.filter {
                !excluding.contains($0.url) && Self.isEligible($0, for: mode, settings: settings, viewport: viewport)
            }
            return candidates.isEmpty ? nil : Choice(mode: mode, assets: candidates, weight: Double(weight))
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
}

nonisolated struct WallMotionPlan: Equatable, Sendable {
    let width: CGFloat
    let height: CGFloat
    let fromX: CGFloat
    let fromY: CGFloat
    let toX: CGFloat
    let toY: CGFloat
    let seconds: TimeInterval

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
    nonisolated static func plan(
        for mode: WallMode,
        asset: PhotoAsset,
        viewport: CGSize,
        settings: WallSettings,
        reverse: Bool = false
    ) -> WallMotionPlan {
        switch mode {
        case .verticalPan:
            let width = viewport.width * settings.panWidthFraction
            let height = width / asset.aspectRatio
            let overflow = max(0, height - viewport.height)
            let left = (viewport.width - width) / 2
            let seconds = overflow > 0
                ? max(0.1, TimeInterval(overflow) / settings.panPixelsPerSecond)
                : 5
            return WallMotionPlan(
                width: width,
                height: height,
                fromX: left,
                fromY: -overflow,
                toX: left,
                toY: 0,
                seconds: seconds
            )

        case .horizontalPan:
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
            let x = (viewport.width - width) / 2
            let y = (viewport.height - height) / 2
            return WallMotionPlan(
                width: width,
                height: height,
                fromX: x,
                fromY: y,
                toX: x,
                toY: y,
                seconds: settings.zoomSeconds
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
        return duration(for: scene.mode, asset: asset, viewport: viewport, settings: settings)
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
