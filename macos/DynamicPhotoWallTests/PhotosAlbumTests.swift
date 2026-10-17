import Foundation
import Testing
@testable import DynamicPhotoWall

@MainActor
struct PhotosAlbumTests {
    @Test func existingSettingsWithoutAlbumsRemainReadable() throws {
        let snapshot = SettingsSnapshot(settings: WallSettings(), screenID: 2, folders: [])
        let data = try JSONEncoder().encode(snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "photoAlbums")
        let restored = try JSONDecoder().decode(SettingsSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.photoAlbums.isEmpty)
        #expect(restored.screenID == 2)
        #expect(restored.settings == snapshot.settings)
    }

    @Test func albumsDeduplicateByFullIdentifierAndEditsInvalidateImageCache() {
        let photo = PhotosAlbumLibrary.makeAsset(identifier: "same/L0/001", width: 1000, height: 600,
            modifiedAt: Date(timeIntervalSince1970: 1), takenAt: nil, filename: "original.heic")
        let other = PhotosAlbumLibrary.makeAsset(identifier: "same/L0/002", width: 1000, height: 600,
            modifiedAt: nil, takenAt: nil, filename: "original.heic")
        let file = PhotoAsset(url: URL(filePath: "/photos/original.heic"), pixelWidth: 1000, pixelHeight: 600)
        #expect(AppModel.uniquePhotos([photo, photo, other, file]).count == 3)
        #expect(photo.url.scheme == "photos")
        #expect(photo.displayName == "original.heic")
        #expect(PhotoImageKey(photo) != PhotoImageKey(other))
        var edited = photo
        edited.modifiedAt = 2
        #expect(PhotoImageKey(photo) != PhotoImageKey(edited))
    }

    @Test func duplicateAlbumSelectionsAreRejectedByRepository() throws {
        let name = "DynamicPhotoWall.AlbumTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let album = PhotoAlbum(id: "a", title: "A")
        #expect(throws: (any Error).self) {
            try SettingsRepository(defaults: defaults).save(
                SettingsSnapshot(settings: WallSettings(), screenID: nil, folders: [], photoAlbums: [album, album]))
        }
    }
}
