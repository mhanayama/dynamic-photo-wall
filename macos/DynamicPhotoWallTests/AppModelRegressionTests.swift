import AppKit
import Foundation
import Testing
@testable import DynamicPhotoWall

@MainActor
private final class FakeWallHost: DesktopWallHosting {
    var shownIDs: [CGDirectDisplayID] = []
    var closed = 0
    func show(on screen: ScreenDescriptor, playback: WallPlaybackController) { shownIDs.append(screen.id) }
    func close() { closed += 1 }
}

extension AppModelRegressionTests {
    private var album: PhotoAlbum { PhotoAlbum(id: "test-album/L0/040", title: "旅行") }
    private var albumPhoto: PhotoAsset {
        PhotosAlbumLibrary.makeAsset(identifier: "photo-a/L0/001", width: 2400, height: 1600,
                                    modifiedAt: Date(timeIntervalSince1970: 100), takenAt: nil, filename: "IMG_001.HEIC")
    }

    @Test func albumOnlySourceCanStartAndIsRestoredAfterSaving() async throws {
        let (defaults, name) = profile()
        defer { defaults.removePersistentDomain(forName: name) }
        let album = album, photo = albumPhoto
        let client = PhotosAlbumClient(catalog: { PhotoAlbumCatalog(albums: [album]) },
                                       scan: { $0.isEmpty ? PhotoAlbumScan() : PhotoAlbumScan(assets: [photo]) })
        let model = AppModel(defaults: defaults, host: FakeWallHost(), playback: WallPlaybackController(),
                             screenProvider: { [first] }, observeEnvironment: false, albumsClient: client)
        defer { model.shutdown() }
        #expect(!model.canStart)
        await model.loadPhotoAlbums()
        model.addPhotoAlbums(ids: [album.id])
        model.addPhotoAlbums(ids: [album.id])
        #expect(model.photoAlbums == [album])
        #expect(model.canStart)
        #expect(!model.canStartApplied)
        #expect(model.photoAssets.isEmpty)
        try await awaitAlbumPreview(model)
        #expect(model.albumPhotoCount == 1)
        #expect(!model.desiredRunning)
        model.saveSettings()
        try await awaitScan(model)
        #expect(model.photoAssets == [photo])
        #expect(model.isPlaying)
        #expect(model.folders.isEmpty)
        model.stop()
        model.saveSettings()
        try await awaitScan(model)
        #expect(model.isPlaying)
        let restored = AppModel(defaults: defaults, host: FakeWallHost(), playback: WallPlaybackController(),
                                screenProvider: { [first] }, observeEnvironment: false, albumsClient: client)
        defer { restored.shutdown() }
        try await awaitScan(restored)
        #expect(restored.photoAlbums == [album])
        #expect(restored.photoAssets == [photo])
        #expect(restored.isPlaying)
    }

    @Test func albumDraftRemovalDoesNotAffectAppliedPlaybackAndCanBeCancelled() async throws {
        let (defaults, name) = profile()
        defer { defaults.removePersistentDomain(forName: name) }
        let album = album, photo = albumPhoto
        try SettingsRepository(defaults: defaults).save(SettingsSnapshot(settings: WallSettings(), screenID: 1, folders: [], photoAlbums: [album]))
        let client = PhotosAlbumClient(catalog: { PhotoAlbumCatalog(albums: [album]) },
                                       scan: { $0.isEmpty ? PhotoAlbumScan() : PhotoAlbumScan(assets: [photo]) })
        let model = AppModel(defaults: defaults, host: FakeWallHost(), playback: WallPlaybackController(),
                             screenProvider: { [first] }, observeEnvironment: false, albumsClient: client)
        defer { model.shutdown() }
        try await awaitScan(model)
        model.removePhotoAlbum(id: album.id)
        #expect(!model.canStart)
        #expect(model.canStartApplied)
        model.reloadPhotos()
        try await awaitScan(model)
        #expect(model.photoAssets == [photo])
        model.cancelDraft()
        #expect(model.photoAlbums == [album])
        model.removePhotoAlbum(id: album.id)
        model.saveSettings()
        try await awaitScan(model)
        #expect(model.photoAssets.isEmpty)
        #expect(!model.wallAttached)
        #expect(!model.canStartApplied)
        #expect(SettingsRepository(defaults: defaults).load()?.photoAlbums == [])
    }

    @Test func unavailableAlbumKeepsSelectionAndReportsWarningWithoutBlockingFolderPhotos() async throws {
        let (defaults, name) = profile()
        defer { defaults.removePersistentDomain(forName: name) }
        try installFolder(in: defaults)
        let photo = photo
        let model = AppModel(defaults: defaults, host: FakeWallHost(), playback: WallPlaybackController(),
                             folderStore: FolderBookmarkStore(defaults: defaults, access: access),
                             screenProvider: { [first] }, scanner: { _, _ in [photo] }, observeEnvironment: false,
                             albumsClient: PhotosAlbumClient(catalog: { PhotoAlbumCatalog() }, scan: {
                                 PhotoAlbumScan(warning: $0.isEmpty ? nil : "アクセス拒否")
                             }))
        defer { model.shutdown() }
        try await awaitScan(model)
        model.photoAlbums = [album]
        model.start()
        try await awaitScan(model)
        #expect(model.photoAssets == [photo])
        #expect(model.photoAlbums == [album])
        #expect(model.photoAlbumsWarning == "アクセス拒否")
        #expect(model.isPlaying)
    }

    @Test func obsoleteAlbumScanCannotReplaceNewerLibrary() async throws {
        let (defaults, name) = profile()
        defer { defaults.removePersistentDomain(forName: name) }
        try SettingsRepository(defaults: defaults).save(SettingsSnapshot(settings: WallSettings(), screenID: 1, folders: [], photoAlbums: [album]))
        let gate = ScanGate()
        let model = AppModel(defaults: defaults, host: FakeWallHost(), playback: WallPlaybackController(),
                             screenProvider: { [first] }, observeEnvironment: false,
                             albumsClient: PhotosAlbumClient(catalog: { PhotoAlbumCatalog() }, scan: { _ in
                                 PhotoAlbumScan(assets: await gate.scan())
                             }))
        defer { model.shutdown() }
        try await awaitRequests(gate, count: 1)
        model.reloadPhotos()
        try await awaitRequests(gate, count: 2)
        await gate.finish(2, photos: [albumPhoto])
        try await awaitScan(model)
        await gate.finish(1, photos: [photo])
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.photoAssets == [albumPhoto])
    }

    @Test func unavailableAlbumCanRecoverOnRetryWithoutLosingSelection() async throws {
        let (defaults, name) = profile()
        defer { defaults.removePersistentDomain(forName: name) }
        try SettingsRepository(defaults: defaults).save(SettingsSnapshot(settings: WallSettings(), screenID: 1, folders: [], photoAlbums: [album]))
        let gate = ScanGate()
        let model = AppModel(defaults: defaults, host: FakeWallHost(), playback: WallPlaybackController(),
                             screenProvider: { [first] }, observeEnvironment: false,
                             albumsClient: PhotosAlbumClient(catalog: { PhotoAlbumCatalog() }, scan: { _ in
                                 let photos = await gate.scan()
                                 return PhotoAlbumScan(assets: photos, warning: photos.isEmpty ? "写真へのアクセス拒否" : nil)
                             }))
        defer { model.shutdown() }
        try await awaitRequests(gate, count: 1)
        await gate.finish(1, photos: [])
        try await awaitScan(model)
        #expect(model.isWaiting)
        #expect(model.displayStatusMessage == "写真へのアクセス拒否")
        #expect(model.photoAlbums == [album])
        model.retryPlayback()
        try await awaitRequests(gate, count: 2)
        await gate.finish(2, photos: [albumPhoto])
        try await awaitScan(model)
        #expect(model.photoAlbumsWarning == nil)
        #expect(model.isPlaying)
    }

    private func awaitAlbumPreview(_ model: AppModel) async throws {
        for _ in 0..<1000 {
            if !model.isScanningAlbums { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw NSError(domain: "RegressionTests.AlbumPreviewTimeout", code: 1)
    }

    @Test func applyingDuringAlbumSelectionScanStartsAfterCompletionWithoutScanningTwice() async throws {
        let (defaults, name) = profile()
        defer { defaults.removePersistentDomain(forName: name) }
        let gate = ScanGate(), album = album
        let model = AppModel(defaults: defaults, host: FakeWallHost(), playback: WallPlaybackController(),
                             screenProvider: { [first] }, observeEnvironment: false,
                             albumsClient: PhotosAlbumClient(catalog: { PhotoAlbumCatalog(albums: [album]) }, scan: { albums in
                                 guard !albums.isEmpty else { return PhotoAlbumScan() }
                                 return PhotoAlbumScan(assets: await gate.scan())
                             }))
        defer { model.shutdown() }
        await model.loadPhotoAlbums()
        model.addPhotoAlbums(ids: [album.id])
        try await awaitRequests(gate, count: 1)
        #expect(model.isScanningAlbums)
        #expect(model.albumPhotoCount == nil)
        #expect(!model.desiredRunning)
        model.saveSettings()
        #expect(model.desiredRunning)
        #expect(model.isScanning)
        await gate.finish(1, photos: [albumPhoto])
        try await awaitScan(model)
        #expect(model.isPlaying)
        #expect(model.photoAssets == [albumPhoto])
        #expect(await gate.count == 1)
    }

    @Test func changedOrCancelledAlbumPreviewCannotChangeAppliedPlayback() async throws {
        let (defaults, name) = profile()
        defer { defaults.removePersistentDomain(forName: name) }
        try installFolder(in: defaults)
        defaults.set(1, forKey: "selectedScreenID")
        let gate = ScanGate(), album = album, photo = photo
        let otherAlbum = PhotoAlbum(id: "other-album", title: "家族")
        let model = AppModel(defaults: defaults, host: FakeWallHost(), playback: WallPlaybackController(),
                             folderStore: FolderBookmarkStore(defaults: defaults, access: access),
                             screenProvider: { [first] }, scanner: { _, _ in [photo] }, observeEnvironment: false,
                             albumsClient: PhotosAlbumClient(catalog: { PhotoAlbumCatalog(albums: [album, otherAlbum]) }, scan: { albums in
                                 guard !albums.isEmpty else { return PhotoAlbumScan() }
                                 return PhotoAlbumScan(assets: await gate.scan())
                             }))
        defer { model.shutdown() }
        try await awaitScan(model)
        let scene = model.playback.currentScene
        await model.loadPhotoAlbums()
        model.addPhotoAlbums(ids: [album.id])
        try await awaitRequests(gate, count: 1)
        model.removePhotoAlbum(id: album.id)
        model.addPhotoAlbums(ids: [otherAlbum.id])
        try await awaitRequests(gate, count: 2)
        await gate.finish(2, photos: [albumPhoto])
        try await awaitAlbumPreview(model)
        #expect(model.albumPhotoCount == 1)
        await gate.finish(1, photos: [photo, albumPhoto])
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.albumPhotoCount == 1)
        #expect(model.photoAlbums == [otherAlbum])
        #expect(model.photoAssets == [photo])
        #expect(model.playback.currentScene == scene)
        model.cancelDraft()
        #expect(model.photoAlbums.isEmpty)
        #expect(model.albumPhotoCount == nil)
        #expect(model.photoAssets == [photo])
        #expect(model.isPlaying)
    }
}

@MainActor
private final class FakeScreenInventory {
    var screens: [ScreenDescriptor]
    init(_ screens: [ScreenDescriptor]) { self.screens = screens }
}

private actor ScanGate {
    private var requests: [Int: CheckedContinuation<[PhotoAsset], Never>] = [:]
    private(set) var count = 0
    func scan() async -> [PhotoAsset] {
        count += 1
        let index = count
        return await withCheckedContinuation { requests[index] = $0 }
    }
    func finish(_ index: Int, photos: [PhotoAsset]) { requests.removeValue(forKey: index)?.resume(returning: photos) }
}

@MainActor
struct AppModelRegressionTests {
    private func profile() -> (UserDefaults, String) {
        let name = "DynamicPhotoWall.Regression.\(UUID())"
        return (UserDefaults(suiteName: name)!, name)
    }
    private var first: ScreenDescriptor {
        ScreenDescriptor(id: 1, name: "first", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), pixelWidth: 1920, pixelHeight: 1080)
    }
    private var second: ScreenDescriptor {
        ScreenDescriptor(id: 2, name: "second", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), pixelWidth: 1920, pixelHeight: 1080)
    }
    private var photo: PhotoAsset { PhotoAsset(url: URL(filePath: "/photos/a.jpg"), pixelWidth: 2400, pixelHeight: 1600) }
    private var access: FolderAccessProvider {
        FolderAccessProvider(resolve: { _ in (URL(filePath: "/photos"), false) }, create: { _ in Data([1]) },
                             start: { _ in true }, stop: { _ in }, isReadable: { _ in true })
    }
    private func installFolder(in defaults: UserDefaults) throws {
        let data = try JSONEncoder().encode([PhotoFolder(bookmark: Data([1]), path: "/photos")])
        defaults.set(data, forKey: FolderBookmarkStore.recordsKey)
    }
    private func awaitScan(_ model: AppModel) async throws {
        for _ in 0..<1000 {
            if !model.isScanning { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw NSError(domain: "RegressionTests.ScanTimeout", code: 1)
    }
    private func awaitRequests(_ gate: ScanGate, count: Int) async throws {
        for _ in 0..<1000 {
            if await gate.count >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw NSError(domain: "RegressionTests.RequestTimeout", code: 1)
    }

    @Test func savedSecondDisplayIsRestoredWithoutOverwritingDefaults() {
        let (defaults, name) = profile()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(2, forKey: "selectedScreenID")
        let model = AppModel(defaults: defaults, host: FakeWallHost(), playback: WallPlaybackController(), screenProvider: { [first, second] }, observeEnvironment: false)
        defer { model.shutdown() }
        #expect(model.selectedScreenID == 2)
        #expect(defaults.integer(forKey: "selectedScreenID") == 2)
    }

    @Test func disconnectedSavedDisplayWaitsAndReconnectsWithoutMovingToAnother() async throws {
        let (defaults, name) = profile()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(2, forKey: "selectedScreenID")
        try installFolder(in: defaults)
        let inventory = FakeScreenInventory([first, second])
        let host = FakeWallHost()
        let photo = photo
        let model = AppModel(defaults: defaults, host: host, playback: WallPlaybackController(),
                             folderStore: FolderBookmarkStore(defaults: defaults, access: access),
                             screenProvider: { inventory.screens }, scanner: { _, _ in [photo] }, observeEnvironment: false)
        defer { model.shutdown() }
        try await awaitScan(model)
        #expect(model.isPlaying)
        inventory.screens = [first]
        model.refreshScreens()
        #expect(!model.isPlaying)
        #expect(model.desiredRunning)
        #expect(model.selectedScreenID == 2)
        #expect(defaults.integer(forKey: "selectedScreenID") == 2)
        #expect(!host.shownIDs.contains(1))
        inventory.screens = [first, second]
        model.refreshScreens()
        #expect(model.isPlaying)
        #expect(host.shownIDs.last == 2)
    }

    @Test func obsoleteScanCannotReplaceANewerResult() async throws {
        let (defaults, name) = profile()
        defer { defaults.removePersistentDomain(forName: name) }
        try installFolder(in: defaults)
        let gate = ScanGate()
        let model = AppModel(defaults: defaults, host: FakeWallHost(), playback: WallPlaybackController(),
                             folderStore: FolderBookmarkStore(defaults: defaults, access: access),
                             screenProvider: { [first] }, scanner: { _, _ in await gate.scan() }, observeEnvironment: false)
        defer { model.shutdown() }
        try await awaitRequests(gate, count: 1)
        model.reloadPhotos()
        try await awaitRequests(gate, count: 2)
        let newer = PhotoAsset(url: URL(filePath: "/photos/new.jpg"), pixelWidth: 100, pixelHeight: 100)
        await gate.finish(2, photos: [newer])
        try await awaitScan(model)
        await gate.finish(1, photos: [photo])
        try await Task.sleep(for: .milliseconds(10))
        #expect(model.photoAssets == [newer])
        #expect(!model.isScanning)
    }

    @Test func stopDuringScanPreventsAutomaticRestart() async throws {
        let (defaults, name) = profile()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(2, forKey: "selectedScreenID")
        try installFolder(in: defaults)
        let gate = ScanGate()
        let host = FakeWallHost()
        let model = AppModel(defaults: defaults, host: host, playback: WallPlaybackController(),
                             folderStore: FolderBookmarkStore(defaults: defaults, access: access),
                             screenProvider: { [second] }, scanner: { _, _ in await gate.scan() }, observeEnvironment: false)
        defer { model.shutdown() }
        try await awaitRequests(gate, count: 1)
        model.stop()
        await gate.finish(1, photos: [photo])
        try await awaitScan(model)
        #expect(!model.isPlaying)
        #expect(!model.desiredRunning)
        #expect(host.shownIDs.isEmpty)
    }

    @Test func removingLastFolderClosesWallAndARescanCanRecoverEmptyLibrary() async throws {
        let (defaults, name) = profile()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(2, forKey: "selectedScreenID")
        try installFolder(in: defaults)
        let gate = ScanGate()
        let model = AppModel(defaults: defaults, host: FakeWallHost(), playback: WallPlaybackController(),
                             folderStore: FolderBookmarkStore(defaults: defaults, access: access),
                             screenProvider: { [second] }, scanner: { _, _ in await gate.scan() }, observeEnvironment: false)
        defer { model.shutdown() }
        try await awaitRequests(gate, count: 1)
        await gate.finish(1, photos: [])
        try await awaitScan(model)
        #expect(!model.isPlaying)
        #expect(model.desiredRunning)
        model.retryFolders()
        try await awaitRequests(gate, count: 2)
        await gate.finish(2, photos: [photo])
        try await awaitScan(model)
        #expect(model.isPlaying)
        model.removeFolders(at: [0])
        #expect(model.isPlaying) // Removal remains a draft until Save.
        model.saveSettings()
        #expect(!model.isPlaying)
        #expect(model.photoAssets.isEmpty)
        #expect(model.playback.currentScene == nil)
    }

    @Test func unresolvedBookmarksArePreservedWhenAddingAnotherFolder() throws {
        let (defaults, name) = profile()
        defer { defaults.removePersistentDomain(forName: name) }
        let unavailable = Data([99])
        defaults.set([unavailable], forKey: "photoFolderBookmarks")
        var provider = access
        provider.resolve = { data in
            if data == unavailable { throw NSError(domain: "DisconnectedVolume", code: 1) }
            return (URL(filePath: "/new"), false)
        }
        let store = FolderBookmarkStore(defaults: defaults, access: provider)
        #expect(store.folders.count == 1)
        #expect(!store.folders[0].isAccessible)
        try store.add(URL(filePath: "/new"))
        let saved = try JSONDecoder().decode([PhotoFolder].self, from: #require(defaults.data(forKey: FolderBookmarkStore.recordsKey)))
        #expect(saved.count == 2)
        #expect(saved[0].bookmark == unavailable)
    }

    @Test func removedSecurityScopeOutlivesCancelledScan() throws {
        let (defaults, name) = profile()
        defer { defaults.removePersistentDomain(forName: name) }
        try installFolder(in: defaults)
        var released: [URL] = []
        var provider = access
        provider.stop = { released.append($0) }
        let store = FolderBookmarkStore(defaults: defaults, access: provider)
        let lease = store.beginScan()
        store.remove(at: [0])
        #expect(released.isEmpty)
        store.endScan(lease)
        #expect(released == [URL(filePath: "/photos")])
    }
    @Test func addingPhotosDoesNotCloseWindowOrRestartCurrentScene() async throws {
        let (defaults, name) = profile()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(2, forKey: "selectedScreenID")
        try installFolder(in: defaults)
        let gate = ScanGate()
        let host = FakeWallHost()
        let model = AppModel(defaults: defaults, host: host, playback: WallPlaybackController(),
                             folderStore: FolderBookmarkStore(defaults: defaults, access: access),
                             screenProvider: { [second] }, scanner: { _, _ in await gate.scan() }, observeEnvironment: false)
        defer { model.shutdown() }
        try await awaitRequests(gate, count: 1)
        await gate.finish(1, photos: [photo])
        try await awaitScan(model)
        let scene = try #require(model.playback.currentScene)
        let started = model.playback.sceneStartedAt
        let closes = host.closed
        model.retryFolders()
        try await awaitRequests(gate, count: 2)
        let added = PhotoAsset(url: URL(filePath: "/photos/b.jpg"), pixelWidth: 2400, pixelHeight: 1600)
        await gate.finish(2, photos: [photo, added])
        try await awaitScan(model)
        #expect(host.closed == closes)
        #expect(model.playback.currentScene == scene)
        #expect(model.playback.sceneStartedAt == started)
        #expect(model.isPlaying)
    }

    @Test func deletingCurrentFileChangesSceneWithoutClosingWindow() async throws {
        let (defaults, name) = profile()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(2, forKey: "selectedScreenID")
        try installFolder(in: defaults)
        let gate = ScanGate()
        let host = FakeWallHost()
        let model = AppModel(defaults: defaults, host: host, playback: WallPlaybackController(),
                             folderStore: FolderBookmarkStore(defaults: defaults, access: access),
                             screenProvider: { [second] }, scanner: { _, _ in await gate.scan() }, observeEnvironment: false)
        defer { model.shutdown() }
        try await awaitRequests(gate, count: 1)
        await gate.finish(1, photos: [photo])
        try await awaitScan(model)
        let old = try #require(model.playback.currentScene)
        let closes = host.closed
        model.retryFolders()
        try await awaitRequests(gate, count: 2)
        let replacement = PhotoAsset(url: URL(filePath: "/photos/b.jpg"), pixelWidth: 2400, pixelHeight: 1600)
        await gate.finish(2, photos: [replacement])
        try await awaitScan(model)
        #expect(host.closed == closes)
        #expect(model.playback.outgoing?.scene == old)
        #expect(model.playback.currentScene?.assets == [replacement])
    }

    @Test func allDecodeFailuresAreReportedAsWaitingAndNextCanRetry() async throws {
        let (defaults, name) = profile()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(2, forKey: "selectedScreenID")
        try installFolder(in: defaults)
        let images = PhotoImageStore(decode: { _ in nil })
        let playback = WallPlaybackController(imageStore: images)
        let photo = photo
        let model = AppModel(defaults: defaults, host: FakeWallHost(), playback: playback,
                             folderStore: FolderBookmarkStore(defaults: defaults, access: access),
                             screenProvider: { [second] }, scanner: { _, _ in [photo] }, observeEnvironment: false)
        defer { model.shutdown() }
        try await awaitScan(model)
        #expect(!(await images.prepare([photo])))
        playback.update()
        #expect(!model.isPlaying)
        #expect(model.isWaiting)
        #expect(model.playbackStateLabel == "待機中")
        #expect(model.canAdvance)
        model.showNextScene()
        #expect(playback.currentScene != nil)
        #expect(playback.waitingForImages)
    }

}
