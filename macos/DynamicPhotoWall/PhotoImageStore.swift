import AppKit
import Foundation
import ImageIO
import Observation

nonisolated struct PhotoImageKey: Hashable, Sendable {
    let url: URL
    let fileSize: Int64
    let modifiedAt: TimeInterval
    init(_ asset: PhotoAsset) {
        url = asset.sourceURL
        fileSize = asset.fileSize
        modifiedAt = asset.modifiedAt
    }
}

nonisolated struct PhotoDecodeKey: Hashable, Sendable {
    let photo: PhotoImageKey
    let maximumPixelSize: Int
}

nonisolated struct PhotoDecodeRequest: Sendable {
    let asset: PhotoAsset
    let maximumPixelSize: Int
    var key: PhotoDecodeKey { PhotoDecodeKey(photo: PhotoImageKey(asset), maximumPixelSize: maximumPixelSize) }

    init(_ asset: PhotoAsset, desiredWidth: Int) {
        self.asset = asset
        let width = Double(max(1, asset.pixelWidth))
        let height = Double(max(1, asset.pixelHeight))
        let requested = Double(max(1, min(8192, desiredWidth)))
        let scale = min(1, requested / width, sqrt(16_000_000 / (width * height)))
        let shortSide = max(1, Int(ceil(min(width, height) * scale)))
        maximumPixelSize = max(1, min(Int(floor(max(width, height) * scale)), 16_000_000 / shortSide))
    }
}

nonisolated struct DecodedPhoto: @unchecked Sendable {
    let image: CGImage
    var bytes: Int { image.bytesPerRow * image.height }
}

actor PhotoImageDecoder {
    func decode(_ request: PhotoDecodeRequest) async -> DecodedPhoto? {
        if request.asset.photosIdentifier != nil {
            return await PhotosAlbumLibrary.decode(request)
        }
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(request.asset.url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: request.maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width <= 16_000_000 / max(1, image.height), !Task.isCancelled else { return nil }
        return DecodedPhoto(image: image)
    }
}

/// Decoded variants use a byte-budgeted LRU. Currently displayed pixels are
/// retained separately so eviction, resizing and transitions cannot blank them.
@MainActor
@Observable
final class PhotoImageStore {
    static let shared = PhotoImageStore()
    typealias Decode = @Sendable (PhotoDecodeRequest) async -> DecodedPhoto?
    private(set) var displayedImages: [PhotoDecodeKey: NSImage] = [:]
    private(set) var failedKeys: Set<PhotoImageKey> = []
    // Observe decode changes without scanning all variants on each display tick.
    private(set) var imageRevision = 0
    @ObservationIgnored private let decode: Decode
    @ObservationIgnored private let faceAnalyzer: PhotoFaceAnalyzer?
    private(set) var analyzedFaces: [PhotoImageKey: [FaceRegion]] = [:]
    @ObservationIgnored private var owners: [UUID: (photos: Set<PhotoImageKey>, widths: [PhotoImageKey: Int])] = [:]
    private static let legacyOwner = UUID()
    @ObservationIgnored private var pinnedPhotos: Set<PhotoImageKey> = []
    @ObservationIgnored private var desiredWidths: [PhotoImageKey: Int] = [:]
    @ObservationIgnored private var cache: [PhotoDecodeKey: (image: NSImage, bytes: Int)] = [:]
    @ObservationIgnored private var recency: [PhotoDecodeKey] = []
    @ObservationIgnored private var inFlight: [PhotoDecodeKey: (id: UUID, task: Task<DecodedPhoto?, Never>)] = [:]
    @ObservationIgnored private var failureGeneration = 0
    @ObservationIgnored private var cachedBytes = 0
    @ObservationIgnored private var budgetBytes = 256 * 1024 * 1024

    init(decode: Decode? = nil, faceAnalyzer: PhotoFaceAnalyzer? = nil) {
        let decoder = PhotoImageDecoder()
        self.decode = decode ?? { await decoder.decode($0) }
        self.faceAnalyzer = faceAnalyzer ?? (decode == nil ? .shared : nil)
    }

    var cacheByteCount: Int { cachedBytes }

    func facesReady(_ assets: [PhotoAsset]) -> Bool {
        faceAnalyzer == nil || assets.allSatisfy { analyzedFaces[PhotoImageKey($0)] != nil }
    }

    func assetWithFaces(_ asset: PhotoAsset) -> PhotoAsset {
        var result = asset
        if let faces = analyzedFaces[PhotoImageKey(asset)] { result.faces = faces }
        return result
    }

    /// Cache-only lookup: nil means unexamined, [] means examined with no face.
    func cachedFaceAssets(_ assets: [PhotoAsset]) async -> [PhotoAsset] {
        let known = assets.map(assetWithFaces).filter { $0.faces != nil }
        guard let faceAnalyzer else { return known }
        let knownKeys = Set(known.map(PhotoImageKey.init))
        let persisted = await faceAnalyzer.cachedAssets(assets.filter { !knownKeys.contains(PhotoImageKey($0)) })
        for asset in persisted { analyzedFaces[PhotoImageKey(asset)] = asset.faces }
        return known + persisted
    }

    func request(for asset: PhotoAsset, desiredWidth: Int? = nil) -> PhotoDecodeRequest {
        PhotoDecodeRequest(asset, desiredWidth: desiredWidth ?? desiredWidths[PhotoImageKey(asset)] ?? asset.pixelWidth)
    }

    func image(for asset: PhotoAsset) -> NSImage? {
        let request = request(for: asset)
        // A lower-resolution bitmap remains usable while a larger variant loads.
        let keys = Set(displayedImages.keys).union(cache.keys).filter { $0.photo == request.key.photo }
        let adequate = keys.filter { $0.maximumPixelSize >= request.maximumPixelSize }.min { $0.maximumPixelSize < $1.maximumPixelSize }
        guard let key = adequate ?? keys.max(by: { $0.maximumPixelSize < $1.maximumPixelSize }) else { return nil }
        return displayedImages[key] ?? cache[key]?.image
    }

    func isReady(_ assets: [PhotoAsset]) -> Bool {
        !assets.isEmpty && assets.allSatisfy { readyKey(for: request(for: $0)) != nil }
    }

    func failed(_ asset: PhotoAsset) -> Bool { failedKeys.contains(PhotoImageKey(asset)) }

    func setDisplayedAssets(_ assets: [PhotoAsset], cacheMegabytes: Int,
                            desiredWidths: [PhotoImageKey: Int] = [:], owner: UUID? = nil) {
        budgetBytes = max(64, min(1024, cacheMegabytes)) * 1024 * 1024
        let owner = owner ?? Self.legacyOwner
        if assets.isEmpty { owners.removeValue(forKey: owner) }
        else { owners[owner] = (Set(assets.map(PhotoImageKey.init)), desiredWidths) }
        pinnedPhotos = owners.values.reduce(into: Set<PhotoImageKey>()) { $0.formUnion($1.photos) }
        let previousWidths = self.desiredWidths
        self.desiredWidths = owners.values.reduce(into: [:]) { all, value in
            for (key, width) in value.widths { all[key] = max(all[key] ?? 0, width) }
        }
        var retained = displayedImages.filter { pinnedPhotos.contains($0.key.photo) }
        for (key, value) in cache where pinnedPhotos.contains(key.photo) { retained[key] = value.image }
        if Set(displayedImages.keys) != Set(retained.keys) { displayedImages = retained; imageRevision += 1 }
        if previousWidths != self.desiredWidths { imageRevision += 1 }
        evictIfNeeded()
    }

    func clearFailures() { failedKeys.removeAll() }

    func resetFailures() {
        failureGeneration += 1
        failedKeys.removeAll()
        for pending in inFlight.values { pending.task.cancel() }
        inFlight.removeAll()
    }

    @discardableResult
    func prepare(_ assets: [PhotoAsset], desiredWidths: [PhotoImageKey: Int]? = nil, detectFaces: Bool = false) async -> Bool {
        let requests = assets.map { request(for: $0, desiredWidth: max(desiredWidths?[PhotoImageKey($0)] ?? self.desiredWidths[PhotoImageKey($0)] ?? $0.pixelWidth, self.desiredWidths[PhotoImageKey($0)] ?? 0)) }
        let generation = failureGeneration
        for request in requests {
            guard !Task.isCancelled else { return false }
            let key = request.key
            if let existing = readyKey(for: request) {
                touch(existing)
                if pinnedPhotos.contains(key.photo), displayedImages[existing] == nil {
                    displayedImages[existing] = cache[existing]?.image
                }
                if detectFaces { await prepareFaces(request, generation: generation) }
                continue
            }
            guard !failedKeys.contains(key.photo) else { return false }
            let pending: (id: UUID, task: Task<DecodedPhoto?, Never>)
            if let shared = inFlight[key] { pending = shared }
            else {
                let decode = decode
                pending = (UUID(), Task { await decode(request) })
                inFlight[key] = pending
            }
            let decoded = await pending.task.value
            if inFlight[key]?.id == pending.id { inFlight.removeValue(forKey: key) }
            guard generation == failureGeneration else { return false }
            guard let decoded else {
                if !pending.task.isCancelled {
                    failedKeys.insert(key.photo)
                    WallLog.write("写真をデコードできません: \(request.asset.url.path)")
                }
                return false
            }
            let image = displayedImages[key] ?? cache[key]?.image ?? NSImage(cgImage: decoded.image,
                size: NSSize(width: decoded.image.width, height: decoded.image.height))
            if cache[key] == nil {
                cache[key] = (image, decoded.bytes)
                cachedBytes += decoded.bytes
                imageRevision += 1
            }
            touch(key)
            if pinnedPhotos.contains(key.photo) { displayedImages[key] = image }
            evictIfNeeded()
            if detectFaces { await prepareFaces(request, generation: generation) }
        }
        return !Task.isCancelled && requests.allSatisfy { readyKey(for: $0) != nil }
            && (!detectFaces || facesReady(assets))
    }

    private func prepareFaces(_ request: PhotoDecodeRequest, generation: Int) async {
        let key = request.key.photo
        guard analyzedFaces[key] == nil, let faceAnalyzer, !Task.isCancelled,
              let image = image(for: request.asset)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let faces = await faceAnalyzer.analyze(request.asset, image: DecodedPhoto(image: image))
        guard !Task.isCancelled, generation == failureGeneration else { return }
        analyzedFaces[key] = faces
        if analyzedFaces.count > 10_000 {
            for old in analyzedFaces.keys where !pinnedPhotos.contains(old) {
                analyzedFaces.removeValue(forKey: old)
                if analyzedFaces.count <= 10_000 { break }
            }
        }
    }

    private func readyKey(for request: PhotoDecodeRequest) -> PhotoDecodeKey? {
        Set(displayedImages.keys).union(cache.keys)
            .filter { $0.photo == request.key.photo && $0.maximumPixelSize >= request.maximumPixelSize }
            .min { $0.maximumPixelSize < $1.maximumPixelSize }
    }

    private func touch(_ key: PhotoDecodeKey) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
    private func evictIfNeeded() {
        while cachedBytes > budgetBytes, let key = recency.first {
            recency.removeFirst()
            if let entry = cache.removeValue(forKey: key) { cachedBytes -= entry.bytes; imageRevision += 1 }
        }
    }
}
