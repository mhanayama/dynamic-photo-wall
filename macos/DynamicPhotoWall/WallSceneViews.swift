import SwiftUI

struct WallSceneLayer: View {
    let presentation: WallScenePresentation
    let settings: WallSettings
    let images: PhotoImageStore

    let viewport: CGSize
    let paused: Bool
    var sharedAmbient: AmbientSampler? = nil
    @State private var ambient = AmbientSampler()

    private var usesCardCaption: Bool { presentation.scene.mode == .gallery || presentation.scene.mode == .horizontalGallery }

    var body: some View {
        ZStack {
            Color(hex: settings.backgroundHex)
            if settings.glassBackground, let image = (sharedAmbient ?? ambient).image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .overlay(Color.black.opacity(0.42))
            }
            let placements = ForegroundGeometry.placements(presentation, settings: settings, viewport: viewport)
            ForEach(Array(placements.enumerated()), id: \.offset) { _, item in
                PhotoCard(asset: item.asset, settings: settings, images: images, showCaption: usesCardCaption)
                    .frame(width: item.frame.width, height: item.frame.height)
                    .clipShape(RoundedRectangle(cornerRadius: item.cornerRadius))
                    .position(x: item.frame.midX, y: item.frame.midY)
                    .opacity(item.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            // Windows adds motion captions to the scene Canvas, outside the
            // moving image. Keep them visible throughout Pan and Zoom.
            if settings.exifOverlay, !usesCardCaption, let asset = presentation.scene.assets.first {
                PhotoCaption(asset: asset)
            }
        }
        .clipped()
        .onChange(of: Int(presentation.elapsed * 8), initial: true) {
            if sharedAmbient == nil, settings.glassBackground { ambient.update(presentation, settings: settings, viewport: viewport, images: images, paused: paused) }
        }
        .onChange(of: paused) { _, paused in if paused { ambient.stop() } }
        .onDisappear { ambient.stop() }
    }
}

private struct PhotoCard: View {
    let asset: PhotoAsset
    let settings: WallSettings
    let images: PhotoImageStore
    let showCaption: Bool

    var body: some View {
        PhotoImageView(asset: asset, contentMode: .fit, images: images)
            .overlay(alignment: .bottomLeading) {
                if settings.exifOverlay && showCaption { PhotoCaption(asset: asset) }
            }
    }
}

private struct PhotoCaption: View {
    let asset: PhotoAsset
    private static let formatter: DateFormatter = {
        let value = DateFormatter()
        value.locale = Locale(identifier: "en_US_POSIX")
        value.calendar = Calendar(identifier: .gregorian)
        value.dateFormat = "yyyy/MM/dd HH:mm"
        return value
    }()

    private var caption: String {
        let details = "\(asset.displayName)  ·  \(asset.pixelWidth)×\(asset.pixelHeight)"
        guard let date = asset.takenAt else { return details }
        Self.formatter.timeZone = .current
        return details + "  " + Self.formatter.string(from: date)
    }

    var body: some View {
        Text(caption)
            .font(.system(size: 16))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.white)
            .padding(10)
            .background(.black.opacity(130.0 / 255))
            .frame(maxWidth: 1200, alignment: .leading)
    }
}

nonisolated enum GalleryLayout {
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
