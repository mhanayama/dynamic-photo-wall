import SwiftUI

struct WallSceneLayer: View {
    let presentation: WallScenePresentation
    let settings: WallSettings
    let images: PhotoImageStore

    var body: some View {
        ZStack {
            if settings.glassBackground {
                AmbientBackgroundView(
                    asset: presentation.scene.assets.first,
                    previousAsset: presentation.slots.first?.previousAsset,
                    progress: presentation.slots.first.map {
                        min(1, max(0, (presentation.elapsed - $0.changedAt) / settings.fadeSeconds))
                    } ?? 1,
                    images: images
                )
            } else {
                Color(hex: settings.backgroundHex)
            }
            switch presentation.scene.mode {
            case .gallery:
                GallerySceneView(presentation: presentation, settings: settings, images: images)
            case .horizontalGallery:
                HorizontalGallerySceneView(presentation: presentation, settings: settings, images: images)
            case .verticalPan, .horizontalPan, .zoom:
                if let asset = presentation.scene.assets.first {
                    MotionSceneView(asset: asset, presentation: presentation, settings: settings, images: images)
                }
            }
        }
        .clipped()
    }
}

private struct AmbientBackgroundView: View {
    let asset: PhotoAsset?
    let previousAsset: PhotoAsset?
    let progress: Double
    let images: PhotoImageStore
    var body: some View {
        ZStack {
            Color.black
            if let asset {
                ForEach(previousAsset.map { [$0, asset] } ?? [asset]) { photo in
                    PhotoImageView(asset: photo, contentMode: .fill, images: images)
                        .blur(radius: 48)
                        .scaleEffect(1.15)
                        .overlay(Color.black.opacity(0.42))
                        .opacity(photo == asset && previousAsset != nil ? progress : 1)
                }
            }
            LinearGradient(colors: [.white.opacity(0.08), .clear, .black.opacity(0.2)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

private struct PhotoCard: View {
    let asset: PhotoAsset
    let settings: WallSettings
    let images: PhotoImageStore
    var body: some View {
        PhotoImageView(asset: asset, contentMode: .fit, images: images)
            .overlay(alignment: .bottomLeading) {
                if settings.exifOverlay {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(asset.url.lastPathComponent) · \(asset.pixelWidth)×\(asset.pixelHeight)")
                        if let date = asset.takenAt { Text(date, format: .dateTime.year().month().day().hour().minute()) }
                    }
                    .font(.system(size: 16))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.5))
                }
            }
    }
}

private struct GallerySceneView: View {
    let presentation: WallScenePresentation
    let settings: WallSettings
    let images: PhotoImageStore
    var body: some View {
        GeometryReader { proxy in
            let frames = GalleryLayout.frames(assets: presentation.slots.map(\.asset), in: proxy.size, gap: settings.gap)
            ForEach(presentation.slots) { slot in
                if frames.indices.contains(slot.id) {
                    let frame = frames[slot.id]
                    ZStack {
                        // Keep the old card's identity when it moves from current
                        // to outgoing, just as we do for full-screen scenes.
                        ForEach(slot.previousAsset.map { [$0, slot.asset] } ?? [slot.asset]) { asset in
                            PhotoCard(asset: asset, settings: settings, images: images)
                                .opacity(asset == slot.asset && slot.previousAsset != nil
                                    ? min(1, max(0, (presentation.elapsed - slot.changedAt) / settings.fadeSeconds)) : 1)
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .clipShape(RoundedRectangle(cornerRadius: settings.cornerRadius))
                    .position(x: frame.midX, y: frame.midY)
                    .animation(.easeInOut(duration: settings.fadeSeconds), value: presentation.scene.assets)
                }
            }
        }
    }
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
    let presentation: WallScenePresentation
    let settings: WallSettings
    let images: PhotoImageStore
    var body: some View {
        GeometryReader { proxy in
            let height = max(1, proxy.size.height - 2 * settings.gap)
            let totalWidth = presentation.scene.assets.reduce(0) { $0 + height * $1.aspectRatio + settings.gap }
            HStack(spacing: settings.gap) {
                ForEach(presentation.scene.assets) { asset in
                    PhotoCard(asset: asset, settings: settings, images: images)
                        .frame(width: height * asset.aspectRatio, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: settings.cornerRadius))
                }
            }
            .frame(width: max(1, totalWidth - settings.gap), height: height, alignment: .leading)
            .offset(x: settings.gap - presentation.scrollDistance, y: settings.gap)
        }
    }
}

private struct MotionSceneView: View {
    let asset: PhotoAsset
    let presentation: WallScenePresentation
    let settings: WallSettings
    let images: PhotoImageStore
    var body: some View {
        GeometryReader { proxy in
            let scene = presentation.scene
            let plan = WallMotionGeometry.plan(for: scene.mode, asset: asset, viewport: proxy.size,
                                                settings: settings, reverse: scene.reverse)
            let frame = plan.frame(at: presentation.progress)
            let eased = 0.5 - cos(presentation.progress * .pi) / 2
            let scale = scene.mode == .zoom
                ? (scene.reverse ? settings.maxZoom - eased * (settings.maxZoom - 1) : 1 + eased * (settings.maxZoom - 1)) : 1
            PhotoCard(asset: asset, settings: settings, images: images)
                .frame(width: frame.width, height: frame.height)
                .scaleEffect(scale, anchor: UnitPoint(x: scene.zoomCenter.x, y: scene.zoomCenter.y))
                .position(x: frame.midX, y: frame.midY)
        }
    }
}
