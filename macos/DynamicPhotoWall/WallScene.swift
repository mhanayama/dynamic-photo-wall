import CoreGraphics
import Foundation

enum WallMode: String, CaseIterable, Equatable, Sendable {
    case gallery
    case horizontalGallery
    case verticalPan
    case horizontalPan
    case zoom
}

struct WallScene: Equatable, Sendable {
    let id: Int
    let mode: WallMode
    let assets: [PhotoAsset]
}

enum WallScenePlanner {
    nonisolated static func scene(
        index: Int,
        assets: [PhotoAsset],
        settings: WallSettings,
        viewport: CGSize,
        seed: UInt64
    ) -> WallScene {
        guard !assets.isEmpty else {
            return WallScene(id: index, mode: .gallery, assets: [])
        }

        var choices: [(mode: WallMode, candidates: [PhotoAsset], weight: Double)] = []
        let galleryModes = [settings.galleryEnabled, settings.galleryScrollEnabled].filter { $0 }.count
        let panModes = [settings.verticalPanEnabled, settings.horizontalPanEnabled].filter { $0 }.count

        func add(_ mode: WallMode, enabled: Bool, weight: Double) {
            guard enabled, weight > 0 else {
                return
            }
            let candidates = eligibleAssets(
                for: mode,
                assets: assets,
                settings: settings,
                viewport: viewport
            )
            if !candidates.isEmpty {
                choices.append((mode, candidates, weight))
            }
        }

        add(
            .gallery,
            enabled: settings.galleryEnabled,
            weight: Double(settings.galleryWeight) / Double(max(1, galleryModes))
        )
        add(
            .horizontalGallery,
            enabled: settings.galleryScrollEnabled && assets.count > 1,
            weight: Double(settings.galleryWeight) / Double(max(1, galleryModes))
        )
        add(
            .verticalPan,
            enabled: settings.verticalPanEnabled,
            weight: Double(settings.panWeight) / Double(max(1, panModes))
        )
        add(
            .horizontalPan,
            enabled: settings.horizontalPanEnabled,
            weight: Double(settings.panWeight) / Double(max(1, panModes))
        )
        add(.zoom, enabled: settings.zoomEnabled, weight: Double(settings.zoomWeight))

        guard !choices.isEmpty else {
            return WallScene(id: index, mode: .gallery, assets: Array(assets.prefix(1)))
        }

        let totalWeight = choices.reduce(0) { $0 + $1.weight }
        var ticket = deterministicUnitValue(index: index, seed: seed) * totalWeight
        let choice = choices.first {
            ticket -= $0.weight
            return ticket < 0
        } ?? choices[choices.count - 1]

        let start = settings.randomOrder
            ? Int(deterministicValue(index: index + 10_000, seed: seed) % UInt64(choice.candidates.count))
            : positiveModulo(index * 7, choice.candidates.count)
        var selected: [PhotoAsset] = []

        switch choice.mode {
        case .gallery:
            let desired = Int((viewport.width / max(viewport.height, 1) / 0.68).rounded())
            let count = min(max(1, desired), min(settings.galleryMax, choice.candidates.count))
            selected = select(count: count, start: start, from: choice.candidates)

        case .horizontalGallery:
            var stripWidth = settings.gap
            var offset = 0
            while selected.count < min(24, choice.candidates.count) {
                let asset = choice.candidates[(start + offset) % choice.candidates.count]
                selected.append(asset)
                stripWidth += max(1, Double(viewport.height) - 2 * settings.gap)
                    * Double(asset.aspectRatio) + settings.gap
                offset += 1
                if selected.count >= 2,
                   stripWidth >= Double(viewport.width + viewport.height * 1.5) {
                    break
                }
            }

        case .verticalPan, .horizontalPan, .zoom:
            selected = [choice.candidates[start]]
        }

        return WallScene(id: index, mode: choice.mode, assets: selected)
    }

    private nonisolated static func eligibleAssets(
        for mode: WallMode,
        assets: [PhotoAsset],
        settings: WallSettings,
        viewport: CGSize
    ) -> [PhotoAsset] {
        let viewportAspect = viewport.width / max(viewport.height, 1)

        return assets.filter { asset in
            switch mode {
            case .gallery, .horizontalGallery:
                return true
            case .verticalPan:
                let displayWidth = viewport.width * settings.panWidthFraction
                let upscale = displayWidth / CGFloat(asset.pixelWidth)
                return asset.aspectRatio < 0.95
                    && upscale <= settings.maxPanUpscale
                    && displayWidth / asset.aspectRatio > viewport.height + 20
            case .horizontalPan:
                let upscale = viewport.height / CGFloat(asset.pixelHeight)
                return asset.aspectRatio > viewportAspect * 1.05
                    && upscale <= settings.maxPanUpscale
            case .zoom:
                return asset.aspectRatio >= 1
            }
        }
    }

    private nonisolated static func select(
        count: Int,
        start: Int,
        from assets: [PhotoAsset]
    ) -> [PhotoAsset] {
        (0..<count).map { assets[(start + $0) % assets.count] }
    }

    private nonisolated static func deterministicUnitValue(index: Int, seed: UInt64) -> Double {
        Double(deterministicValue(index: index, seed: seed) % 10_000) / 10_000
    }

    private nonisolated static func deterministicValue(index: Int, seed: UInt64) -> UInt64 {
        var value = UInt64(bitPattern: Int64(index)) ^ seed
        value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        value ^= value >> 30
        value = value &* 13_760_289_258_834_695_229
        value ^= value >> 27
        return value
    }

    private nonisolated static func positiveModulo(_ value: Int, _ divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }
}

struct WallPlaybackPosition: Equatable, Sendable {
    let currentScene: WallScene
    let nextScene: WallScene
    let progress: Double
    let transitionProgress: Double

    nonisolated static func resolve(
        elapsed: TimeInterval,
        assets: [PhotoAsset],
        settings: WallSettings,
        viewport: CGSize,
        seed: UInt64,
        startingSceneIndex: Int = 0
    ) -> WallPlaybackPosition {
        let safeElapsed = max(0, elapsed)
        var sceneIndex = max(0, startingSceneIndex)
        var sceneElapsed = safeElapsed
        var currentScene = WallScenePlanner.scene(
            index: sceneIndex,
            assets: assets,
            settings: settings,
            viewport: viewport,
            seed: seed
        )
        var duration = WallMotionGeometry.duration(
            for: currentScene,
            viewport: viewport,
            settings: settings
        )
        while sceneElapsed >= duration {
            sceneElapsed -= duration
            sceneIndex += 1
            currentScene = WallScenePlanner.scene(
                index: sceneIndex,
                assets: assets,
                settings: settings,
                viewport: viewport,
                seed: seed
            )
            duration = WallMotionGeometry.duration(
                for: currentScene,
                viewport: viewport,
                settings: settings
            )
        }
        let progress = sceneElapsed / duration
        let transitionDuration = min(settings.fadeSeconds, duration)
        let transitionProgress = max(
            0,
            min(1, (sceneElapsed - (duration - transitionDuration)) / transitionDuration)
        )

        return WallPlaybackPosition(
            currentScene: currentScene,
            nextScene: WallScenePlanner.scene(
                index: sceneIndex + 1,
                assets: assets,
                settings: settings,
                viewport: viewport,
                seed: seed
            ),
            progress: progress,
            transitionProgress: transitionProgress
        )
    }
}

struct WallMotionPlan: Equatable, Sendable {
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

enum WallMotionGeometry {
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
            let height = width / max(asset.aspectRatio, 0.01)
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
            let height = max(1, viewport.height - 2 * settings.gap)
            return max(
                120,
                TimeInterval(viewport.width + height * asset.aspectRatio) / settings.galleryScrollPixelsPerSecond
            )
        case .verticalPan, .horizontalPan, .zoom:
            return plan(
                for: mode,
                asset: asset,
                viewport: viewport,
                settings: settings,
                reverse: asset.stableMotionDirection < 0
            ).seconds
        }
    }
}
