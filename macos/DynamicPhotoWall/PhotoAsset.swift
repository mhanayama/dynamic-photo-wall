import CoreGraphics
import Foundation

nonisolated struct FaceRegion: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1.01 && y + height <= 1.01
    }
}

nonisolated struct PhotoAsset: Identifiable, Codable, Equatable, Sendable {
    let url: URL
    let pixelWidth: Int
    let pixelHeight: Int
    var fileSize: Int64 = 0
    var modifiedAt: TimeInterval = 0
    var takenAt: Date? = nil
    var orientation: Int = 1
    var faces: [FaceRegion]? = nil
    var photosIdentifier: String? = nil
    var originalFilename: String? = nil

    var displayName: String { originalFilename ?? url.lastPathComponent }
    var sourceURL: URL { url.isFileURL ? url.standardizedFileURL : url }

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
