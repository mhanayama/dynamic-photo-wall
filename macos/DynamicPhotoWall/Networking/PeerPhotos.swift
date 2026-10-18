import Foundation
import ImageIO
import Photos
import Vision

nonisolated struct PNImportedPhoto: Sendable { var photo: PNPhoto; var original: Data }
@MainActor protocol PNPhotoProviding {
    var sources: [PNSource] { get }
    func read(_ selection: PNSelection) -> AsyncThrowingStream<PNImportedPhoto, Error>
}

@MainActor final class PNSystemPhotoProvider: PNPhotoProviding {
    let peerId: UUID
    let folders: () -> [PhotoFolder]
    let albums: () -> [PhotoAlbum]
    let assets: () -> [PhotoAsset]
    private let cached: (PNAssetKey) -> Bool
    private var known: [String: PNAssetKey] = [:]
    init(peerId: UUID, folders: @escaping () -> [PhotoFolder], albums: @escaping () -> [PhotoAlbum], assets: @escaping () -> [PhotoAsset], cached: @escaping (PNAssetKey) -> Bool = { _ in false }) {
        self.peerId = peerId; self.folders = folders; self.albums = albums; self.assets = assets
        self.cached = cached
    }
    var sources: [PNSource] {
        folders().map { PNSource(providerId: peerId, sourceId: $0.id, name: $0.url?.lastPathComponent ?? "写真フォルダー") }
        + albums().map { PNSource(providerId: peerId, sourceId: PNWire.id("album:\($0.id)"), name: $0.title) }
    }
    func read(_ selection: PNSelection) -> AsyncThrowingStream<PNImportedPhoto, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let sourceAssets: [PhotoAsset]
                    if let folder = folders().first(where: { $0.id == selection.sourceId }), let url = folder.url {
                        let prefix = url.standardizedFileURL.path + "/"
                        sourceAssets = assets().filter { $0.url.isFileURL && $0.url.standardizedFileURL.path.hasPrefix(prefix) }
                    } else if let album = albums().first(where: { PNWire.id("album:\($0.id)") == selection.sourceId }) {
                        sourceAssets = await PhotosAlbumLibrary.scan([album]).assets
                    } else { continuation.finish(); return }
                    for asset in sourceAssets {
                        try Task.checkCancellation()
                        let fingerprint = "\(selection.sourceId):\(selection.generationId):\(asset.url.absoluteString):\(asset.fileSize):\(asset.modifiedAt)"
                        if let previous = known[fingerprint], cached(previous) { continue }
                        do {
                            let bytes: Data
                            if let identifier = asset.photosIdentifier { bytes = try await PNOriginalPhotos.read(identifier) }
                            else {
                                bytes = try await Task.detached(priority: .utility) {
                                    let size = try asset.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                                    try PNWire.require(size > 0 && size <= 256 * 1024 * 1024, "Photo exceeds original cache limit")
                                    return try Data(contentsOf: asset.url)
                                }.value
                            }
                            let imported = try await Task.detached(priority: .utility) {
                                try PNPhotoMetadata.make(bytes, peerId: selection.providerId, sourceId: selection.sourceId, generation: selection.generationId)
                            }.value
                            known[fingerprint] = imported.photo.key
                            continuation.yield(imported)
                        } catch is CancellationError { throw CancellationError() }
                        catch { WallLog.write("共有写真を読み込めません。", error: error) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

nonisolated enum PNPhotoMetadata {
    static func make(_ bytes: Data, peerId: UUID, sourceId: UUID, generation: UUID) throws -> PNImportedPhoto {
        try PNWire.require(!bytes.isEmpty && bytes.count <= 256 * 1024 * 1024, "Photo exceeds original cache limit")
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int, let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int else { throw PNError.invalid("Unsupported original image") }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let width = orientation >= 5 ? rawHeight : rawWidth, height = orientation >= 5 ? rawWidth : rawHeight
        var faces: [PNFaceRegion] = []; var state = "failed"
        if let small = CGImageSourceCreateThumbnailAtIndex(source, 0,
            [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary) {
            do {
                let request = VNDetectFaceRectanglesRequest(); try VNImageRequestHandler(cgImage: small, orientation: .up).perform([request])
                faces = (request.results ?? []).map { observation in
                    let box = observation.boundingBox; let x = min(1, max(0, box.minX)), y = min(1, max(0, 1 - box.maxY))
                    return PNFaceRegion(x: x, y: y, width: min(1 - x, box.width), height: min(1 - y, box.height))
                }.filter(\.isValid)
                state = "complete"
            } catch { state = "failed" }
        }
        let photo = PNPhoto(key: PNAssetKey(providerId: peerId, sourceId: sourceId, generationId: generation, imageId: PNWire.digest(bytes)),
            pixelWidth: width, pixelHeight: height, byteLength: bytes.count,
            faceMetadata: PNFaces(pixelWidth: width, pixelHeight: height, detector: "apple-vision", state: state, faces: faces), orientation: orientation)
        try photo.validate(); return PNImportedPhoto(photo: photo, original: bytes)
    }
}

private nonisolated final class PNPhotoRequestBuffer: @unchecked Sendable {
    private let lock = NSLock(); private var data = Data(); private var error: Error?
    private var id: PHAssetResourceDataRequestID?
    private var cancelled = false
    func install(_ id: PHAssetResourceDataRequestID) { lock.lock(); self.id = id; let cancel = cancelled; lock.unlock(); if cancel { PHAssetResourceManager.default().cancelDataRequest(id) } }
    func append(_ bytes: Data) {
        lock.lock()
        if data.count + bytes.count > 256 * 1024 * 1024 { error = PNError.invalid("Photo exceeds original cache limit"); cancelled = true }
        else if !cancelled { data.append(bytes) }
        let cancelId = cancelled ? id : nil; lock.unlock()
        if let cancelId { PHAssetResourceManager.default().cancelDataRequest(cancelId) }
    }
    func result(_ failure: Error?) throws -> Data { lock.lock(); defer { lock.unlock() }; if let error = error ?? failure { throw error }; if cancelled { throw CancellationError() }; return data }
    func cancel() { lock.lock(); cancelled = true; let id = id; lock.unlock(); if let id { PHAssetResourceManager.default().cancelDataRequest(id) } }
}
nonisolated enum PNOriginalPhotos {
    static func read(_ identifier: String) async throws -> Data {
        guard PhotosAlbumLibrary.hasAccess, let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { throw PNError.invalid("写真へのアクセスを確認してください。") }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .photo }) ?? resources.first(where: { $0.type == .fullSizePhoto }) else { throw PNError.invalid("Original photo resource is unavailable") }
        let buffer = PNPhotoRequestBuffer()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
                let id = PHAssetResourceManager.default().requestData(for: resource, options: options,
                    dataReceivedHandler: { buffer.append($0) }, completionHandler: { error in c.resume(with: Result { try buffer.result(error) }) })
                buffer.install(id)
            }
        } onCancel: { buffer.cancel() }
    }
}

// Transfer has no socket or UI dependency. Only two bounded ingress jobs run at
// once. Originals remain in memory until authenticated encrypted publication.
@MainActor final class PNPhotoTransfers {
    private struct Incoming { var photo: PNPhoto; var bytes = Data(); var next = 0 }
    let cache: PNPhotoCache
    private let local: UUID; private let provider: any PNPhotoProviding
    private var selection: [PNSelection] = []
    private var generations: [UUID: UUID] = [:]
    private(set) var catalog: [String: PNPhoto] = [:]
    private(set) var available: [String: PNPhoto] = [:]
    private var requested: [UUID: PNAssetKey] = [:]
    private var incoming: [UUID: Incoming] = [:]
    private var requestedAt: [UUID: Date] = [:]
    private var deferred: Set<String> = []
    var deferredCount: Int { deferred.count }
    private var importing: Task<Void, Never>?
    private var importGeneration = UUID()
    var produced: ((PNCatalog) async throws -> Void)?
    var changed: (() -> Void)?
    init(local: UUID, provider: any PNPhotoProviding, cache: PNPhotoCache) { self.local = local; self.provider = provider; self.cache = cache }
    private func selected(_ key: PNAssetKey) -> Bool { selection.contains { $0.providerId == key.providerId && $0.sourceId == key.sourceId && $0.generationId == key.generationId } }
    func configure(_ sources: [PNSelection]) async throws {
        let sourceChanged = sources != selection
        if sourceChanged { importing?.cancel() }
        selection = sources; deferred.removeAll()
        for id in generations.keys.filter({ id in !sources.contains { $0.providerId == id } }) { try await cache.activate(id, UUID()); generations.removeValue(forKey: id) }
        for source in sources where generations[source.providerId] != source.generationId {
            generations[source.providerId] = source.generationId; try await cache.activate(source.providerId, source.generationId)
        }
        try await cache.retainProviders(Set(sources.map(\.providerId)))
        for photo in catalog.values.filter({ !selected($0.key) }) {
            if generations[photo.key.providerId] == photo.key.generationId { try await cache.delete(photo.key) }
        }
        catalog = catalog.filter { selected($0.value.key) }; available = available.filter { selected($0.value.key) }
        requested = requested.filter { selected($0.value) }; incoming = incoming.filter { selected($0.value.photo.key) }
        for header in try await cache.catalog() {
            if selected(header.photo.key) { catalog[header.photo.key.opaqueId] = header.photo; available[header.photo.key.opaqueId] = header.photo }
            else { try await cache.delete(header.photo.key) }
        }
        refresh(replace: sourceChanged); changed?()
    }
    func refresh(replace: Bool = false) {
        if importing != nil && !replace { return }
        importing?.cancel()
        let generation = UUID(); importGeneration = generation
        let sources = selection.filter { $0.providerId == local }
        importing = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if importGeneration == generation { importing = nil } }
            do {
                for source in sources {
                    for try await imported in provider.read(source) {
                        try Task.checkCancellation(); guard selected(imported.photo.key) else { continue }
                        let photo = imported.photo
                        if deferred.contains(photo.key.opaqueId) { continue }
                        do { if try await cache.read(photo.key) == nil { try await cache.put(photo, original: imported.original) } }
                        catch PNError.budget { deferred.insert(photo.key.opaqueId); changed?(); continue }
                        guard selected(photo.key) else { continue }
                        catalog[photo.key.opaqueId] = photo; available[photo.key.opaqueId] = photo
                        try await produced?(PNCatalog(photos: [photo])); changed?()
                    }
                }
            } catch is CancellationError { } catch { WallLog.write("写真共有を再試行します。", error: error) }
        }
    }
    func maintain() async throws {
        let valid = Set(try await cache.catalog().map { $0.photo.key.opaqueId }); let count = available.count
        available = available.filter { valid.contains($0.key) }; if count != available.count { deferred.removeAll() }
        for id in requestedAt.keys.filter({ Date().timeIntervalSince(requestedAt[$0]!) > 30 }) { requestedAt.removeValue(forKey: id); requested.removeValue(forKey: id); incoming.removeValue(forKey: id) }
        refresh()
    }
    func accept(_ sender: UUID, _ batch: PNCatalog) async throws -> [PNAssetRequest] {
        try PNWire.require(batch.photos.count <= 128, "Catalog batch too large")
        for photo in batch.photos {
            try photo.validate(); try PNWire.require(photo.key.providerId == sender, "Catalog provider differs")
            if !selected(photo.key) { continue }
            catalog[photo.key.opaqueId] = photo
            if try await cache.read(photo.key) != nil { available[photo.key.opaqueId] = photo }
        }
        return missing(sender)
    }
    func missing(_ peer: UUID) -> [PNAssetRequest] {
        var requests: [PNAssetRequest] = []
        for photo in catalog.values where photo.key.providerId == peer && available[photo.key.opaqueId] == nil && !requested.values.contains(photo.key) && !deferred.contains(photo.key.opaqueId) {
            if requested.count >= 2 { break }; let id = UUID(); requested[id] = photo.key; requestedAt[id] = Date(); requests.append(PNAssetRequest(requestId: id, key: photo.key))
        }
        return requests
    }
    func send(_ request: PNAssetRequest, to link: any PNPeerLink) async throws {
        try PNWire.require(selected(request.key), "Photo is no longer selected")
        guard let photo = available[request.key.opaqueId], let bytes = try await cache.read(request.key) else { throw PNError.invalid("Original is unavailable") }
        for offset in stride(from: 0, to: bytes.count, by: 65536) {
            try Task.checkCancellation()
            let end = min(bytes.count, offset + 65536)
            try await link.send(PNPacket("assetChunk", PNChunk(requestId: request.requestId, photo: photo, index: offset / 65536, data: bytes.subdata(in: offset..<end), last: end == bytes.count)))
        }
    }
    func receive(_ sender: UUID, _ chunk: PNChunk) async throws {
        try chunk.photo.validate()
        try PNWire.require(requested[chunk.requestId] == chunk.photo.key && sender == chunk.photo.key.providerId && selected(chunk.photo.key)
            && !chunk.data.isEmpty && chunk.data.count <= 65536, "Unexpected original chunk")
        var item = incoming[chunk.requestId] ?? Incoming(photo: chunk.photo)
        do {
            try PNWire.require(item.photo == chunk.photo && item.next == chunk.index && item.bytes.count + chunk.data.count <= item.photo.byteLength, "Original chunk order differs")
            item.bytes.append(chunk.data); item.next += 1
            if !chunk.last { incoming[chunk.requestId] = item; return }
            try await cache.put(item.photo, original: item.bytes)
            if selected(item.photo.key) { available[item.photo.key.opaqueId] = item.photo }
            incoming.removeValue(forKey: chunk.requestId); requested.removeValue(forKey: chunk.requestId); changed?()
        } catch PNError.budget { deferred.insert(item.photo.key.opaqueId); incoming.removeValue(forKey: chunk.requestId); requested.removeValue(forKey: chunk.requestId); changed?() }
        catch { incoming.removeValue(forKey: chunk.requestId); requested.removeValue(forKey: chunk.requestId); throw error }
        requestedAt.removeValue(forKey: chunk.requestId)
    }
    func lost(_ peer: UUID) { for (id, key) in requested where key.providerId == peer { requested.removeValue(forKey: id); incoming.removeValue(forKey: id) } }
    func stop() { importing?.cancel(); importing = nil; requested.removeAll(); incoming.removeAll() }
}
