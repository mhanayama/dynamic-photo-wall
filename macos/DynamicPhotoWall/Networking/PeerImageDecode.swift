import Foundation
import ImageIO

nonisolated enum PNImageDecode {
    static func decode(_ bytes: Data, maximum: Int) -> DecodedPhoto? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
            [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
             kCGImageSourceThumbnailMaxPixelSize: max(64, maximum), kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return DecodedPhoto(image: image)
    }
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(output, image, nil); return CGImageDestinationFinalize(output) ? data as Data : nil
    }
}
