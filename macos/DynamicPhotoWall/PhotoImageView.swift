import AppKit
import ImageIO
import SwiftUI

private final class PhotoDataCache: @unchecked Sendable {
    static let shared = PhotoDataCache()

    private let cache = NSCache<NSURL, NSData>()

    private init() {
        cache.totalCostLimit = 256 * 1_024 * 1_024
    }

    func data(for url: URL) async -> Data? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached as Data
        }

        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url, options: [.mappedIfSafe])
        }.value

        if let data {
            cache.setObject(data as NSData, forKey: url as NSURL, cost: data.count)
        }
        return data
    }
}

private enum PhotoDecoder {
    nonisolated static func decode(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4_096,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

struct PhotoImageView: View {
    let asset: PhotoAsset
    let contentMode: ContentMode

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)

            if let image {
                AppKitPhotoView(image: image, contentMode: contentMode)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            }
        }
        .clipped()
        .task(id: asset.id) {
            image = nil
            guard let data = await PhotoDataCache.shared.data(for: asset.url),
                  !Task.isCancelled else {
                return
            }

            let decoded = await Task.detached(priority: .userInitiated) {
                PhotoDecoder.decode(data: data)
            }.value

            guard !Task.isCancelled, let decoded else {
                return
            }
            image = NSImage(
                cgImage: decoded,
                size: NSSize(width: decoded.width, height: decoded.height)
            )
        }
    }
}

private struct AppKitPhotoView: NSViewRepresentable {
    let image: NSImage
    let contentMode: ContentMode

    func makeNSView(context: Context) -> AspectImageView {
        AspectImageView()
    }

    func updateNSView(_ view: AspectImageView, context: Context) {
        view.image = image
        view.contentMode = contentMode
        view.needsDisplay = true
    }
}

private final class AspectImageView: NSView {
    var image: NSImage?
    var contentMode: ContentMode = .fit

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let image, bounds.width > 0, bounds.height > 0,
              image.size.width > 0, image.size.height > 0 else {
            return
        }

        NSGraphicsContext.current?.imageInterpolation = .high
        let widthScale = bounds.width / image.size.width
        let heightScale = bounds.height / image.size.height
        let scale = contentMode == .fill
            ? max(widthScale, heightScale)
            : min(widthScale, heightScale)
        let drawSize = NSSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        let drawRect = NSRect(
            x: (bounds.width - drawSize.width) / 2,
            y: (bounds.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        image.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }
}
