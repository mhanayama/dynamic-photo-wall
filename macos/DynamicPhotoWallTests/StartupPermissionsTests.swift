import Foundation
import Testing
@testable import DynamicPhotoWall

@MainActor struct StartupPermissionsTests {
    @Test func signedExecutableIdentityCanBeReadWithoutRequestingAnyPermission() throws {
        let identity = try #require(SystemWallPermissions.buildIdentity)
        #expect(!identity.isEmpty && identity.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(SystemWallPermissions.buildIdentity == identity)
    }
    @Test func launchChecksArePassiveAndPresentOnlyForMissingAccess() async {
        var requests = 0, checks: [WallPermission] = []
        let model = StartupPermissions(client: WallPermissionClient(check: {
            checks.append($0)
            return $0 == .photos ? .denied : .granted
        }, request: { _ in requests += 1; return .granted }))
        await model.check(presentIfNeeded: true)
        #expect(model.presented && model.missing == [.photos])
        #expect(checks == WallPermission.allCases && requests == 0)
        let ready = StartupPermissions(client: WallPermissionClient(check: { _ in .granted }, request: { _ in requests += 1; return .granted }))
        await ready.check(presentIfNeeded: true)
        #expect(!ready.presented && ready.missing.isEmpty && requests == 0)
    }
    @Test func oneActionRequestsSequentiallyAndPreservesDenials() async {
        var requests: [WallPermission] = [], active = 0, maximum = 0
        let model = StartupPermissions(client: WallPermissionClient(check: { $0 == .folders ? .granted : .notDetermined }, request: {
            active += 1; maximum = max(maximum, active)
            requests.append($0); await Task.yield(); active -= 1
            return $0 == .photos ? .denied : .granted
        }))
        await model.check()
        #expect(requests.isEmpty)
        await model.requestMissing()
        #expect(requests == [.photos, .keychain, .notifications, .localNetwork])
        #expect(maximum == 1 && active == 0)
        #expect(model.missing == [.photos] && !model.busy)
    }
    @Test func cancelStopsTheQueueAndRejectsLatePermissionResults() async {
        let gate = Gate()
        var requests: [WallPermission] = [], cancelled = 0
        let model = StartupPermissions(client: WallPermissionClient(check: { _ in .notDetermined }, request: {
            requests.append($0)
            return await withCheckedContinuation { gate.pending = $0 }
        }, cancel: { cancelled += 1 }))
        await model.check()
        let first = Task { await model.requestMissing() }
        for _ in 0..<100 where gate.pending == nil { await Task.yield() }
        #expect(gate.pending != nil && model.busy)
        model.cancel()
        await model.requestMissing() // Cannot put another OS dialog above the old one.
        gate.pending?.resume(returning: .granted); gate.pending = nil
        await first.value
        #expect(requests == [.photos] && cancelled == 1)
        #expect(model.statuses[.photos] == .notDetermined && !model.busy)
    }
    @Test func anExplicitRecheckCanRequestNetworkAccessAgain() async {
        let model = StartupPermissions(client: WallPermissionClient(check: { _ in .granted }, request: { _ in .granted }))
        await model.check(presentIfNeeded: true)
        #expect(!model.presented)
        await model.check(forceNetwork: true)
        #expect(model.missing == [.localNetwork])
        await model.requestMissing()
        #expect(model.missing.isEmpty)
    }
    @Test func folderReauthorizationKeepsIDsAndDoesNotSaveOtherDraftEdits() throws {
        let profile = "DPW.Permission.Folders.\(UUID())"
        let defaults = UserDefaults(suiteName: profile)!
        defer { defaults.removePersistentDomain(forName: profile) }
        let folder = PhotoFolder(bookmark: Data([1]), path: "/fixture/photos")
        let album = PhotoAlbum(id: "saved-album", title: "Saved")
        try SettingsRepository(defaults: defaults).save(SettingsSnapshot(settings: WallSettings(), screenID: nil, folders: [folder], photoAlbums: [album]))
        let access = FolderAccessProvider(resolve: { _ in (URL(filePath: "/fixture/photos"), false) },
            create: { _ in Data([2]) }, start: { _ in true }, stop: { _ in }, isReadable: { _ in true })
        let model = AppModel(defaults: defaults, folderStore: FolderBookmarkStore(defaults: defaults, access: access),
            screenProvider: { [] }, scanner: { _, _ in [] }, observeEnvironment: false,
            albumsClient: PhotosAlbumClient(catalog: { PhotoAlbumCatalog() }, scan: { _ in PhotoAlbumScan() }))
        defer { model.shutdown() }
        model.settings.galleryMax = 17
        model.photoAlbums = []
        let original = model.folders[0]
        #expect(throws: (any Error).self) { try model.renewFolderPermission(original, at: URL(filePath: "/other-folder")) }
        try model.renewFolderPermission(original, at: URL(filePath: "/fixture/photos"))
        let saved = try #require(SettingsRepository(defaults: defaults).load())
        #expect(saved.folders[0].id == folder.id && saved.folders[0].bookmark == Data([2]))
        #expect(saved.settings.galleryMax == 5 && saved.photoAlbums == [album])
        #expect(model.settings.galleryMax == 17 && model.photoAlbums.isEmpty)
        model.cancelDraft()
        #expect(model.folders[0].bookmark == Data([2]) && model.photoAlbums == [album])
        #expect(model.permissions == nil) // Isolated hosts never use the real OS permission clients.
    }
    @Test func deniedNetworkAccessDoesNotBlockPhotoRecoveryOrApplyTheDraft() async throws {
        let profile = "DPW.Permission.Recovery.\(UUID())"
        let defaults = UserDefaults(suiteName: profile)!
        defer { defaults.removePersistentDomain(forName: profile) }
        let album = PhotoAlbum(id: "permission-album", title: "Album")
        try SettingsRepository(defaults: defaults).save(SettingsSnapshot(settings: WallSettings(), screenID: nil, folders: [], photoAlbums: [album]))
        let gate = PhotoAccess()
        let photo = PhotoAsset(url: URL(filePath: "/fixture/photo.jpg"), pixelWidth: 1200, pixelHeight: 800)
        let model = AppModel(defaults: defaults, screenProvider: { [] }, scanner: { _, _ in [] }, observeEnvironment: false,
            albumsClient: PhotosAlbumClient(catalog: { PhotoAlbumCatalog() }, scan: { _ in
                PhotoAlbumScan(assets: await gate.allowed ? [photo] : [])
            }), permissionClient: WallPermissionClient(check: { permission in
                permission == .keychain || permission == .localNetwork ? .denied : .granted
            }, request: { _ in .denied }))
        defer { model.shutdown() }
        for _ in 0..<1000 where model.isScanning { try await Task.sleep(for: .milliseconds(1)) }
        #expect(model.photoAssets.isEmpty)
        model.settings.galleryMax = 19
        model.photoAlbums = [] // Keep the draft separate from the saved album.
        await gate.grant()
        #expect(await model.checkStartupPermissions())
        for _ in 0..<1000 where model.isScanning { try await Task.sleep(for: .milliseconds(1)) }
        #expect(model.photoAssets == [photo])
        #expect(model.settings.galleryMax == 19 && model.photoAlbums.isEmpty)
        #expect(model.network?.online == false && model.network?.session == nil)
        #expect(SettingsRepository(defaults: defaults).load()?.settings.galleryMax == 5)
    }
    private actor PhotoAccess {
        var allowed = false
        func grant() { allowed = true }
    }
    private final class Gate { var pending: CheckedContinuation<WallPermissionStatus, Never>? }
}
