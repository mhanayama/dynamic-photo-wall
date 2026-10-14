import SwiftUI

struct WallSceneLayer: View {
    let scene: WallScene
    let allAssets: [PhotoAsset]
    let progress: Double
    let settings: WallSettings

    var body: some View {
        ZStack {
            if settings.glassBackground {
                AmbientBackgroundView(asset: scene.assets.first)
            } else {
                Color(hex: settings.backgroundHex)
            }

            switch scene.mode {
            case .gallery:
                GallerySceneView(
                    sceneID: scene.id,
                    assets: scene.assets,
                    allAssets: allAssets,
                    progress: progress,
                    sceneSeconds: WallMotionGeometry.duration(
                        for: scene,
                        viewport: CGSize(width: 1, height: 1),
                        settings: settings
                    ),
                    minimumSeconds: settings.galleryMinSeconds,
                    maximumSeconds: settings.galleryMaxSeconds,
                    fadeSeconds: settings.fadeSeconds,
                    gap: settings.gap,
                    cornerRadius: settings.cornerRadius
                )
            case .horizontalGallery:
                HorizontalGallerySceneView(
                    assets: scene.assets,
                    progress: progress,
                    gap: settings.gap,
                    cornerRadius: settings.cornerRadius
                )
            case .verticalPan:
                if let asset = scene.assets.first {
                    VerticalPanSceneView(
                        asset: asset,
                        progress: progress,
                        settings: settings
                    )
                }
            case .horizontalPan:
                if let asset = scene.assets.first {
                    HorizontalPanSceneView(asset: asset, progress: progress, settings: settings)
                }
            case .zoom:
                if let asset = scene.assets.first {
                    ZoomSceneView(
                        asset: asset,
                        progress: progress,
                        maxZoom: settings.maxZoom
                    )
                }
            }
        }
        .clipped()
    }
}

private struct AmbientBackgroundView: View {
    let asset: PhotoAsset?

    var body: some View {
        ZStack {
            Color.black

            if let asset {
                PhotoImageView(asset: asset, contentMode: .fill)
                    .blur(radius: 48)
                    .scaleEffect(1.15)
                    .overlay(Color.black.opacity(0.42))
            }

            LinearGradient(
                colors: [.white.opacity(0.08), .clear, .black.opacity(0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

private struct GallerySceneView: View {
    let sceneID: Int
    let assets: [PhotoAsset]
    let allAssets: [PhotoAsset]
    let progress: Double
    let sceneSeconds: TimeInterval
    let minimumSeconds: TimeInterval
    let maximumSeconds: TimeInterval
    let fadeSeconds: TimeInterval
    let gap: Double
    let cornerRadius: Double

    var body: some View {
        GeometryReader { proxy in
            let slots = gallerySlots()
            let frames = GalleryLayout.frames(
                assets: slots.map(\.asset),
                in: proxy.size,
                gap: CGFloat(gap)
            )

            ForEach(slots) { slot in
                if frames.indices.contains(slot.id) {
                    let frame = frames[slot.id]
                    PhotoImageView(asset: slot.asset, contentMode: .fit)
                        .id(slot.asset.id)
                        .frame(width: frame.width, height: frame.height)
                        .background(.black.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                        .shadow(color: .black.opacity(0.45), radius: 18)
                        .position(x: frame.midX, y: frame.midY)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: fadeSeconds), value: slot.asset.id)
                }
            }
        }
    }

    private func gallerySlots() -> [GallerySlot] {
        guard !assets.isEmpty else { return [] }
        let pool = allAssets.isEmpty ? assets : allAssets
        var used: Set<URL> = []
        let elapsed = progress * sceneSeconds

        return assets.indices.map { slot in
            let intervalRange = max(0, maximumSeconds - minimumSeconds)
            let fraction = Double(deterministicValue(slot: slot) % 10_000) / 10_000
            let interval = max(0.1, minimumSeconds + intervalRange * fraction)
            let delayedElapsed = max(0, elapsed - Double(slot * 3))
            let replacementCount = Int(delayedElapsed / interval)
            let originalIndex = pool.firstIndex(of: assets[slot]) ?? slot % pool.count
            var candidateIndex = (originalIndex + replacementCount) % pool.count
            var attempts = 0
            while used.contains(pool[candidateIndex].url), attempts < pool.count {
                candidateIndex = (candidateIndex + 1) % pool.count
                attempts += 1
            }
            let asset = pool[candidateIndex]
            used.insert(asset.url)
            return GallerySlot(id: slot, asset: asset)
        }
    }

    private func deterministicValue(slot: Int) -> UInt64 {
        var value = UInt64(bitPattern: Int64(sceneID &* 31 &+ slot))
        value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        value ^= value >> 30
        return value
    }
}

private struct GallerySlot: Identifiable {
    let id: Int
    let asset: PhotoAsset
}

enum GalleryLayout {
    static func frames(assets: [PhotoAsset], in size: CGSize, gap: CGFloat) -> [CGRect] {
        guard !assets.isEmpty else {
            return []
        }
        let safeGap = min(gap, min(size.width / CGFloat(assets.count + 1), size.height / 4))
        let aspectSum = assets.reduce(CGFloat.zero) { $0 + $1.aspectRatio }
        let height = max(
            1,
            min(
                size.height - 2 * safeGap,
                (size.width - CGFloat(assets.count + 1) * safeGap) / aspectSum
            )
        )
        var x = (size.width - height * aspectSum - safeGap * CGFloat(assets.count - 1)) / 2
        return assets.map { asset in
            let width = height * asset.aspectRatio
            defer { x += width + safeGap }
            return CGRect(x: x, y: (size.height - height) / 2, width: width, height: height)
        }
    }
}

private struct HorizontalGallerySceneView: View {
    let assets: [PhotoAsset]
    let progress: Double
    let gap: Double
    let cornerRadius: Double

    var body: some View {
        GeometryReader { proxy in
            let height = max(1, proxy.size.height - 2 * gap)
            let widths = assets.map {
                height * $0.aspectRatio
            }
            let spacing = CGFloat(gap)
            let totalWidth = widths.reduce(0, +) + spacing * CGFloat(max(0, assets.count - 1))
            let travel = proxy.size.width + totalWidth

            HStack(spacing: spacing) {
                ForEach(assets.enumerated(), id: \.element.id) { index, asset in
                    PhotoImageView(asset: asset, contentMode: .fit)
                        .frame(width: widths[index], height: height)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                        .shadow(color: .black.opacity(0.4), radius: 12)
                }
            }
            .frame(width: totalWidth, height: height, alignment: .leading)
            .offset(
                x: proxy.size.width - CGFloat(progress) * travel,
                y: gap
            )
        }
    }
}

private struct VerticalPanSceneView: View {
    let asset: PhotoAsset
    let progress: Double
    let settings: WallSettings

    var body: some View {
        GeometryReader { proxy in
            let plan = WallMotionGeometry.plan(
                for: .verticalPan,
                asset: asset,
                viewport: proxy.size,
                settings: settings
            )
            let frame = plan.frame(at: progress)

            PhotoImageView(asset: asset, contentMode: .fit)
                .frame(width: frame.width, height: frame.height)
                .shadow(color: .black.opacity(0.5), radius: 20)
                .position(x: frame.midX, y: frame.midY)
        }
    }
}

private struct HorizontalPanSceneView: View {
    let asset: PhotoAsset
    let progress: Double
    let settings: WallSettings

    var body: some View {
        GeometryReader { proxy in
            let plan = WallMotionGeometry.plan(
                for: .horizontalPan,
                asset: asset,
                viewport: proxy.size,
                settings: settings,
                reverse: asset.stableMotionDirection < 0
            )
            let frame = plan.frame(at: progress)

            PhotoImageView(asset: asset, contentMode: .fit)
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        }
    }
}

private struct ZoomSceneView: View {
    let asset: PhotoAsset
    let progress: Double
    let maxZoom: Double

    var body: some View {
        GeometryReader { proxy in
            let plan = WallMotionGeometry.plan(
                for: .zoom,
                asset: asset,
                viewport: proxy.size,
                settings: {
                    var value = WallSettings()
                    value.maxZoom = maxZoom
                    return value
                }()
            )
            let frame = plan.frame(at: progress)
            let easedProgress = 0.5 - cos(CGFloat(progress) * .pi) / 2
            let scale = 1 + easedProgress * (maxZoom - 1)

            PhotoImageView(asset: asset, contentMode: .fit)
                .frame(width: frame.width, height: frame.height)
                .scaleEffect(scale)
                .position(x: frame.midX, y: frame.midY)
        }
    }
}
