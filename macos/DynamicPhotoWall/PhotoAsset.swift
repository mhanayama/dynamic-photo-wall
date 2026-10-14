import CoreGraphics
import Foundation

nonisolated struct PhotoAsset: Identifiable, Equatable, Sendable {
    let url: URL
    let pixelWidth: Int
    let pixelHeight: Int
    var fileSize: Int64 = 0
    var modifiedAt: TimeInterval = 0
    var takenAt: Date? = nil

    nonisolated var id: URL {
        url
    }

    nonisolated var aspectRatio: CGFloat {
        guard pixelHeight > 0 else {
            return 1
        }
        return CGFloat(pixelWidth) / CGFloat(pixelHeight)
    }

}
