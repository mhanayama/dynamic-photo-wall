import AppKit
import Foundation

/// UI automation uses fake sources and a host that cannot create a desktop window.
@MainActor
private final class RegressionWallHost: DesktopWallHosting {
    func show(on screen: ScreenDescriptor, playback: WallPlaybackController) {}
    func close() {}
}

extension AppModel {
    static func makeUITestModel(profile: String) -> AppModel {
        let defaults = UserDefaults(suiteName: "DynamicPhotoWall.UITests.\(profile)")!
        if !defaults.bool(forKey: "initialized") {
            let records = [1, 2].map {
                PhotoFolder(bookmark: Data([UInt8($0)]), path: "/Test Photos \($0)")
            }
            defaults.set(try! JSONEncoder().encode(records), forKey: FolderBookmarkStore.recordsKey)
            defaults.set(1, forKey: "selectedScreenID")
            defaults.set(true, forKey: "initialized")
        }
        let access = FolderAccessProvider(resolve: { data in
            (URL(filePath: "/Test Photos \(data.first ?? 1)"), false)
        }, create: { url in Data([UInt8(url.lastPathComponent.suffix(1)) ?? 3]) },
            start: { _ in true }, stop: { _ in }, isReadable: { _ in true })
        return AppModel(defaults: defaults, host: RegressionWallHost(), playback: WallPlaybackController(),
            folderStore: FolderBookmarkStore(defaults: defaults, access: access),
            screenProvider: { [ScreenDescriptor(id: 1, name: "Test Display",
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), pixelWidth: 1920, pixelHeight: 1080),
                ScreenDescriptor(id: 2, name: "Test Retina Display", frame: CGRect(x: 1920, y: 0, width: 960, height: 540), pixelWidth: 1920, pixelHeight: 1080),
                ScreenDescriptor(id: 3, name: "Test Independent Display", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), pixelWidth: 1920, pixelHeight: 1080)] },
            scanner: { folder, _ in [PhotoAsset(url: folder.appending(path: "test.jpg"), pixelWidth: 2400, pixelHeight: 1600)] },
            observeEnvironment: false,
            albumsClient: PhotosAlbumClient(catalog: {
                PhotoAlbumCatalog(albums: [PhotoAlbum(id: "test-album", title: "旅行（テスト）")])
            }, scan: { albums in
                PhotoAlbumScan(assets: albums.isEmpty ? [] : [PhotosAlbumLibrary.makeAsset(
                    identifier: "test-photo/L0/001", width: 2400, height: 1600,
                    modifiedAt: nil, takenAt: nil, filename: "test.heic")])
            }))
    }
}
