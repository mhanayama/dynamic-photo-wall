import CoreGraphics
import Foundation

struct PhotoAsset: Identifiable, Equatable, Sendable {
    let url: URL
    let pixelWidth: Int
    let pixelHeight: Int

    nonisolated var id: URL {
        url
    }

    nonisolated var aspectRatio: CGFloat {
        guard pixelHeight > 0 else {
            return 1
        }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }

    nonisolated var stableMotionDirection: CGFloat {
        let checksum = url.absoluteString.utf8.reduce(0) { partialResult, byte in
            (partialResult + Int(byte)) % 2
        }
        return checksum == 0 ? 1 : -1
    }
}
