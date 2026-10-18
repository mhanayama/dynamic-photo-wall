import CoreGraphics
import Foundation

// Premultiplied RGBA, matching Windows AmbientPixels.EnhanceColors (BGRA).
nonisolated enum AmbientColors {
    static func enhance(_ pixels: inout [UInt8]) {
        for i in stride(from: 0, to: pixels.count - pixels.count % 4, by: 4) {
            let alpha = Double(pixels[i + 3]); if alpha == 0 { continue }
            let r = Double(pixels[i]) * 255 / alpha
            let g = Double(pixels[i + 1]) * 255 / alpha
            let b = Double(pixels[i + 2]) * 255 / alpha
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let maximum = max(r, g, b) - luminance, minimum = min(r, g, b) - luminance
            let lifted = min(luminance * 1.12, 255 - maximum)
            var chroma = 1.6
            if maximum > 0 { chroma = min(chroma, (255 - lifted) / maximum) }
            if minimum < 0 { chroma = min(chroma, lifted / -minimum) }
            for (offset, value) in [r, g, b].enumerated() {
                let result = ((lifted + (value - luminance) * chroma) * alpha / 255).rounded(.toNearestOrEven)
                pixels[i + offset] = UInt8(min(alpha, max(0, result)))
            }
        }
    }
    static func enhance(_ image: CGImage) -> DecodedPhoto? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        guard drawn else { return nil }
        enhance(&pixels)
        return AmbientProcessor.image(pixels, width: image.width, height: image.height).map { DecodedPhoto(image: $0) }
    }
}
