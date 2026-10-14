import SwiftUI

struct WallSceneLayer: View {
    let presentation: WallScenePresentation
    let settings: WallSettings

    var body: some View {
        ZStack {
            if settings.glassBackground {
                AmbientBackgroundView(asset: presentation.scene.assets.first)
            } else {
                Color(hex: settings.backgroundHex)
            }
            switch presentation.scene.mode {
            case .gallery:
                GallerySceneView(presentation: presentation, settings: settings)
            case .horizontalGallery:
                HorizontalGallerySceneView(presentation: presentation, settings: settings)
            case .verticalPan, .horizontalPan, .zoom:
                if let asset = presentation.scene.assets.first {
                    MotionSceneView(asset: asset, presentation: presentation, settings: settings)
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
            LinearGradient(colors: [.white.opacity(0.08), .clear, .black.opacity(0.2)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

private struct PhotoCard: View {
    let asset: PhotoAsset
    let settings: WallSettings
    var body: some View {
        PhotoImageView(asset: asset, contentMode: .fit)
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
    var body: some View {
        GeometryReader { proxy in
            let frames = GalleryLayout.frames(assets: presentation.slots.map(\.asset), in: proxy.size, gap: settings.gap)
            ForEach(presentation.slots) { slot in
                if frames.indices.contains(slot.id) {
                    let frame = frames[slot.id]
                    ZStack {
                        if let old = slot.previousAsset { PhotoCard(asset: old, settings: settings) }
                        PhotoCard(asset: slot.asset, settings: settings)
                            .opacity(slot.previousAsset == nil ? 1 : min(1, max(0, (presentation.elapsed - slot.changedAt) / settings.fadeSeconds)))
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
    var body: some View {
        GeometryReader { proxy in
            let height = max(1, proxy.size.height - 2 * settings.gap)
            let totalWidth = presentation.scene.assets.reduce(0) { $0 + height * $1.aspectRatio + settings.gap }
            HStack(spacing: settings.gap) {
                ForEach(presentation.scene.assets) { asset in
                    PhotoCard(asset: asset, settings: settings)
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
    var body: some View {
        GeometryReader { proxy in
            let scene = presentation.scene
            let plan = WallMotionGeometry.plan(for: scene.mode, asset: asset, viewport: proxy.size,
                                                settings: settings, reverse: scene.reverse)
            let frame = plan.frame(at: presentation.progress)
            let eased = 0.5 - cos(presentation.progress * .pi) / 2
            let scale = scene.mode == .zoom
                ? (scene.reverse ? settings.maxZoom - eased * (settings.maxZoom - 1) : 1 + eased * (settings.maxZoom - 1)) : 1
            PhotoCard(asset: asset, settings: settings)
                .frame(width: frame.width, height: frame.height)
                .scaleEffect(scale, anchor: UnitPoint(x: scene.zoomCenter.x, y: scene.zoomCenter.y))
                .position(x: frame.midX, y: frame.midY)
        }
    }
}
