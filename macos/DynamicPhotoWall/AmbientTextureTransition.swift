import CoreGraphics
import Foundation

/// Keep two immutable tiny textures. Only opacity changes on presentation ticks;
/// an interrupted fade starts from the actual visible pixel mix.
nonisolated struct AmbientTextureTransition {
    struct Layer { let image: CGImage; let opacity: Double }
    private var from: [UInt8] = []
    private var to: [UInt8] = []
    private var base: CGImage?
    private var target: CGImage?
    private var started = 0.0
    private var responseSeconds: Double?
    static let seconds = 0.125

    mutating func push(_ image: CGImage, at: Double, responseSeconds: Double? = nil) {
        guard let data = image.dataProvider?.data else { return }
        let pixels = Array(data as Data)
        guard image.bytesPerRow == image.width * 4, pixels.count == image.width * image.height * 4 else { return }
        if let target, target.width == image.width, target.height == image.height, at >= started {
            if progress(at: at) >= 1 { from = to; base = target }
            else {
                from = AmbientTransition.blend(from, to, progress: progress(at: at))
                base = AmbientProcessor.image(from, width: image.width, height: image.height)
            }
        } else { from = pixels; base = image }
        to = pixels; target = image; started = at; self.responseSeconds = responseSeconds
    }

    private func progress(at: Double) -> Double {
        let elapsed = max(0, at - started)
        guard let responseSeconds else { return min(1, elapsed / Self.seconds) }
        let remaining = exp(-elapsed / max(0.001, responseSeconds))
        return remaining < 1.0 / 255 ? 1 : 1 - remaining
    }

    func layers(at: Double) -> [Layer] {
        guard let base, let target else { return [] }
        return [Layer(image: base, opacity: 1),
                Layer(image: target, opacity: progress(at: at))]
    }
}
