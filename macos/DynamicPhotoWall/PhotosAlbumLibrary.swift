import AppKit
import Foundation
import Photos

nonisolated struct PhotoAlbum: Identifiable, Codable, Equatable, Sendable {
    let id: String
    var title: String
}

nonisolated struct PhotoAlbumCatalog: Sendable {
    var albums: [PhotoAlbum] = []
    var warning: String? = nil
}

nonisolated struct PhotoAlbumScan: Sendable {
    var assets: [PhotoAsset] = []
    var warning: String? = nil
}

/// Closures keep isolated tests away from the user's Photos library and TCC.
nonisolated struct PhotosAlbumClient: Sendable {
    var catalog: @Sendable () async -> PhotoAlbumCatalog
    var scan: @Sendable ([PhotoAlbum]) async -> PhotoAlbumScan

    static let system = PhotosAlbumClient(catalog: { await PhotosAlbumLibrary.catalog() },
                                         scan: { await PhotosAlbumLibrary.scan($0) })
}

nonisolated enum PhotosAlbumLibrary {
    static let permissionWarning = "写真へのアクセスが許可されていません。システム設定 → プライバシーとセキュリティ → 写真で許可し、再検索してください。"

    static var hasAccess: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    static func catalog() async -> PhotoAlbumCatalog {
        // Permission is requested only after the user presses the album button.
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard hasAccess else { return PhotoAlbumCatalog(warning: permissionWarning) }
        return await Task.detached(priority: .userInitiated) {
            var albums: [String: PhotoAlbum] = [:]
            for type: PHAssetCollectionType in [.album, .smartAlbum] {
                let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
                for index in 0..<collections.count {
                    let collection = collections.object(at: index)
                    guard collection.assetCollectionSubtype != .smartAlbumAllHidden else { continue }
                    if type == .smartAlbum && PHAsset.fetchAssets(in: collection, options: imageOptions()).count == 0 { continue }
                    albums[collection.localIdentifier] = PhotoAlbum(id: collection.localIdentifier,
                        title: collection.localizedTitle ?? "名称未設定のアルバム")
                }
            }
            return PhotoAlbumCatalog(albums: albums.values.sorted {
                $0.title.localizedStandardCompare($1.title) == .orderedAscending
            })
        }.value
    }

    static func scan(_ albums: [PhotoAlbum]) async -> PhotoAlbumScan {
        guard !albums.isEmpty else { return PhotoAlbumScan() }
        // Restoring saved selections must never trigger a permission dialog.
        guard hasAccess else { return PhotoAlbumScan(warning: permissionWarning) }
        let task = Task.detached(priority: .userInitiated) {
            var photos: [String: PhotoAsset] = [:]
            var missing: [String] = []
            for album in albums {
                guard !Task.isCancelled else { return PhotoAlbumScan() }
                guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album.id], options: nil).firstObject else {
                    missing.append(album.title)
                    continue
                }
                let assets = PHAsset.fetchAssets(in: collection, options: imageOptions())
                for index in 0..<assets.count {
                    guard !Task.isCancelled else { return PhotoAlbumScan() }
                    let asset = assets.object(at: index)
                    guard asset.pixelWidth > 0, asset.pixelHeight > 0,
                          asset.pixelWidth <= 500_000_000 / asset.pixelHeight else { continue }
                    photos[asset.localIdentifier] = makeAsset(identifier: asset.localIdentifier,
                        width: asset.pixelWidth, height: asset.pixelHeight,
                        modifiedAt: asset.modificationDate, takenAt: asset.creationDate,
                        filename: PHAssetResource.assetResources(for: asset).first?.filename)
                }
            }
            return PhotoAlbumScan(assets: photos.values.sorted { $0.url.absoluteString < $1.url.absoluteString },
                warning: missing.isEmpty ? nil : "アルバムが見つかりません（削除・ライブラリ変更・アクセス制限）: \(missing.joined(separator: "、"))。登録は保持しています。")
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    static func makeAsset(identifier: String, width: Int, height: Int, modifiedAt: Date?, takenAt: Date?, filename: String?) -> PhotoAsset {
        // The full local identifier stays in the path, including its slash suffix.
        let url = URL(string: "photos://library/")!.appendingPathComponent(identifier)
        return PhotoAsset(url: url, pixelWidth: width, pixelHeight: height,
            modifiedAt: modifiedAt?.timeIntervalSince1970 ?? 0, takenAt: takenAt,
            photosIdentifier: identifier, originalFilename: filename)
    }

    private static func imageOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d AND hidden == NO", PHAssetMediaType.image.rawValue)
        return options
    }

    static func decode(_ request: PhotoDecodeRequest) async -> DecodedPhoto? {
        guard !Task.isCancelled, hasAccess, let identifier = request.asset.photosIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
        let manager = PHImageManager.default()
        let pending = PhotosImageRequest(manager: manager)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard pending.install(continuation) else { return }
                let options = PHImageRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .exact
                options.version = .current
                options.isNetworkAccessAllowed = true
                let size = CGFloat(request.maximumPixelSize)
                let id = manager.requestImage(for: asset, targetSize: CGSize(width: size, height: size),
                    contentMode: .aspectFit, options: options) { image, info in
                    if (info?[PHImageCancelledKey] as? Bool) == true || info?[PHImageErrorKey] != nil {
                        pending.finish(nil)
                        return
                    }
                    guard (info?[PHImageResultIsDegradedKey] as? Bool) != true else { return }
                    guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                          cgImage.width <= 16_000_000 / max(1, cgImage.height) else {
                        pending.finish(nil)
                        return
                    }
                    pending.finish(DecodedPhoto(image: cgImage))
                }
                pending.setID(id)
            }
        } onCancel: { pending.cancel() }
    }
}

/// PhotoKit may call back before requestImage returns, or after cancellation.
/// The lock protects both races and resumes the continuation exactly once.
nonisolated final class PhotosImageRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let manager: PHImageManager
    private var continuation: CheckedContinuation<DecodedPhoto?, Never>?
    private var requestID: PHImageRequestID?
    private var finished = false

    init(manager: PHImageManager) { self.manager = manager }

    func install(_ continuation: CheckedContinuation<DecodedPhoto?, Never>) -> Bool {
        lock.lock()
        if finished { lock.unlock(); continuation.resume(returning: nil); return false }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setID(_ id: PHImageRequestID) {
        lock.lock()
        requestID = id
        let shouldCancel = finished
        lock.unlock()
        if shouldCancel { manager.cancelImageRequest(id) }
    }

    func finish(_ result: DecodedPhoto?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }

    func cancel() {
        finish(nil)
        lock.lock()
        let id = requestID
        lock.unlock()
        if let id { manager.cancelImageRequest(id) }
    }
}

nonisolated final class PhotosAlbumWatcher: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        super.init()
        PHPhotoLibrary.shared().register(self)
    }
    func photoLibraryDidChange(_ changeInstance: PHChange) { onChange() }
    func stop() { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
}
