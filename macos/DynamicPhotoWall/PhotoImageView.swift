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
        view.setImage(image, contentMode: contentMode)
    }
}

final class AspectImageView: NSView {
    private(set) var image: NSImage?
    private(set) var contentMode: ContentMode = .fit
    private(set) var redrawRequestCount = 0

    private func requestRedraw() {
        redrawRequestCount += 1
        needsDisplay = true
    }

    func setImage(_ image: NSImage, contentMode: ContentMode) {
        guard self.image !== image || self.contentMode != contentMode else { return }
        self.image = image; self.contentMode = contentMode
        requestRedraw()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { requestRedraw() }
    }

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
