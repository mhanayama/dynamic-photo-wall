import AppKit
import SwiftUI

struct PhotoImageView: View {
    let asset: PhotoAsset
    let contentMode: ContentMode
    let images: PhotoImageStore

    var body: some View {
        Group {
            if let image = images.image(for: asset) {
                AppKitPhotoView(image: image, contentMode: contentMode)
            } else {
                Color.clear
            }
        }
        .clipped()
    }
}

private struct AppKitPhotoView: NSViewRepresentable {
    let image: NSImage
    let contentMode: ContentMode

    func makeNSView(context: Context) -> AspectImageView {
        let view = AspectImageView()
        view.wantsLayer = true
        return view
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
