import AppKit
import Foundation
import ImageIO
import Observation

nonisolated struct PhotoImageKey: Hashable, Sendable {
    let url: URL
    let fileSize: Int64
    let modifiedAt: TimeInterval

    init(_ asset: PhotoAsset) {
        url = asset.url.standardizedFileURL
        fileSize = asset.fileSize
        modifiedAt = asset.modifiedAt
    }
}

nonisolated struct DecodedPhoto: @unchecked Sendable {
    let image: CGImage
    var bytes: Int { image.bytesPerRow * image.height }
}

/// Synchronous ImageIO work stays on this actor, serially, off the UI actor.
actor PhotoImageDecoder {
    func decode(_ asset: PhotoAsset) -> DecodedPhoto? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(asset.url as CFURL, nil) else { return nil }
        let width = Double(asset.pixelWidth)
        let height = Double(asset.pixelHeight)
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, 4096 / max(width, height), sqrt(16_000_000 / (width * height)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(max(width, height) * scale)),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              !Task.isCancelled else { return nil }
        return DecodedPhoto(image: image)
    }
}

/// Views read ready bitmaps synchronously. Displayed images remain pinned even
/// when the reusable LRU cache is evicted; no view owns an asynchronous reset.
@MainActor
@Observable
final class PhotoImageStore {
    static let shared = PhotoImageStore()
    typealias Decode = @Sendable (PhotoAsset) async -> DecodedPhoto?

    private(set) var displayedImages: [PhotoImageKey: NSImage] = [:]
    private(set) var failedKeys: Set<PhotoImageKey> = []
    @ObservationIgnored private let decode: Decode
    @ObservationIgnored private var pinnedKeys: Set<PhotoImageKey> = []
    @ObservationIgnored private var cache: [PhotoImageKey: (image: NSImage, bytes: Int)] = [:]
    @ObservationIgnored private var recency: [PhotoImageKey] = []
    @ObservationIgnored private var inFlight: [PhotoImageKey: (id: UUID, task: Task<DecodedPhoto?, Never>)] = [:]
    @ObservationIgnored private var cachedBytes = 0
    @ObservationIgnored private var budgetBytes = 256 * 1024 * 1024

    init(decode: Decode? = nil) {
        let decoder = PhotoImageDecoder()
        self.decode = decode ?? { await decoder.decode($0) }
    }

    func image(for asset: PhotoAsset) -> NSImage? {
        let key = PhotoImageKey(asset)
        return displayedImages[key] ?? cache[key]?.image
    }

    func isReady(_ assets: [PhotoAsset]) -> Bool {
        !assets.isEmpty && assets.allSatisfy { image(for: $0) != nil }
    }

    func failed(_ asset: PhotoAsset) -> Bool { failedKeys.contains(PhotoImageKey(asset)) }

    func setDisplayedAssets(_ assets: [PhotoAsset], cacheMegabytes: Int) {
        budgetBytes = max(64, min(1024, cacheMegabytes)) * 1024 * 1024
        let keys = Set(assets.map(PhotoImageKey.init))
        var retained: [PhotoImageKey: NSImage] = [:]
        for key in keys {
            if let image = displayedImages[key] ?? cache[key]?.image { retained[key] = image }
        }
        pinnedKeys = keys
        if Set(displayedImages.keys) != Set(retained.keys) { displayedImages = retained }
        evictIfNeeded()
    }

    func resetFailures() { failedKeys.removeAll() }

    @discardableResult
    func prepare(_ assets: [PhotoAsset]) async -> Bool {
        for asset in assets {
            guard !Task.isCancelled else { return false }
            let key = PhotoImageKey(asset)
            if let image = self.image(for: asset) {
                touch(key)
                if pinnedKeys.contains(key), displayedImages[key] == nil { displayedImages[key] = image }
                continue
            }
            guard !failedKeys.contains(key) else { return false }
            let task: Task<DecodedPhoto?, Never>
            let requestID: UUID
            if let pending = inFlight[key] {
                task = pending.task
                requestID = pending.id
            } else {
                let decode = decode
                task = Task { await decode(asset) }
                requestID = UUID()
                inFlight[key] = (requestID, task)
            }
            let decoded = await task.value
            // Other waiters can use the same result. A cancelled scene does not
            // clear a bitmap already needed by the current display.
            if inFlight[key]?.id == requestID { inFlight.removeValue(forKey: key) }
            if let decoded {
                let image = self.image(for: asset) ?? NSImage(cgImage: decoded.image,
                    size: NSSize(width: decoded.image.width, height: decoded.image.height))
                if cache[key] == nil {
                    cache[key] = (image, decoded.bytes)
                    cachedBytes += decoded.bytes
                }
                touch(key)
                if pinnedKeys.contains(key) { displayedImages[key] = image }
                evictIfNeeded()
            } else {
                failedKeys.insert(key)
                return false
            }
        }
        return !Task.isCancelled && isReady(assets)
    }

    private func touch(_ key: PhotoImageKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private func evictIfNeeded() {
        while cachedBytes > budgetBytes, let key = recency.first {
            recency.removeFirst()
            if let entry = cache.removeValue(forKey: key) { cachedBytes -= entry.bytes }
        }
    }
}
