import Foundation

nonisolated struct SettingsSnapshot: Codable {
    var schemaVersion = 1
    var settings: WallSettings
    var screenID: UInt32?
    var folders: [PhotoFolder]
    var displays: [WallDisplay]? = nil
    var displayGroupNames: [String] = []
    var photoAlbums: [PhotoAlbum] = []

    private enum CodingKeys: String, CodingKey { case schemaVersion, settings, screenID, folders, photoAlbums, displays, displayGroupNames }

    init(settings: WallSettings, screenID: UInt32?, folders: [PhotoFolder], photoAlbums: [PhotoAlbum] = [], displays: [WallDisplay]? = nil, displayGroupNames: [String] = []) {
        self.settings = settings
        self.screenID = screenID
        self.folders = folders
        self.photoAlbums = photoAlbums
        self.displays = displays
        self.displayGroupNames = DisplayLayout.groupNames(displayGroupNames, displays: displays ?? [])
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        settings = try values.decode(WallSettings.self, forKey: .settings)
        screenID = try values.decodeIfPresent(UInt32.self, forKey: .screenID)
        folders = try values.decode([PhotoFolder].self, forKey: .folders)
        displays = try values.decodeIfPresent([WallDisplay].self, forKey: .displays)
        displayGroupNames = DisplayLayout.groupNames(try values.decodeIfPresent([String].self, forKey: .displayGroupNames) ?? [], displays: displays ?? [])
        photoAlbums = try values.decodeIfPresent([PhotoAlbum].self, forKey: .photoAlbums) ?? []
    }
}

/// A single atomic document keeps settings, display and sandbox grants together.
@MainActor
final class SettingsRepository {
    static let key = "configurationSnapshot"
    private let defaults: UserDefaults
    private let file: URL?
    private(set) var warning: String?
    private(set) var writable = true

    init(defaults: UserDefaults, file: URL? = nil) {
        self.defaults = defaults
        self.file = file
    }

    func load() -> SettingsSnapshot? {
        let data = file.flatMap { try? Data(contentsOf: $0) } ?? defaults.data(forKey: Self.key)
        guard let data else { return nil }
        do { return try decode(data) }
        catch {
            WallLog.write("設定の復元に失敗しました。", error: error)
            defaults.set(data, forKey: "configurationSnapshot.invalid")
            if let file {
                // Preserve the damaged document before any future save.
                do { try data.write(to: file.appendingPathExtension("invalid-\(UUID().uuidString)"), options: .atomic) }
                catch { writable = false }
                if let previous = try? Data(contentsOf: file.appendingPathExtension("previous")),
                   let recovered = try? decode(previous) {
                    warning = "設定が壊れていたため、直前の保存内容を復元しました。元のデータは退避しました。"
                    return recovered
                }
            }
            warning = "設定を読み込めませんでした。以前の設定・フォルダー登録を復元します。元のデータは退避しました。"
            return nil
        }
    }

    private func decode(_ data: Data) throws -> SettingsSnapshot {
        let value = try JSONDecoder().decode(SettingsSnapshot.self, from: data)
        guard value.schemaVersion == 1 else {
            writable = false
            throw NSError(domain: "DynamicPhotoWall.UnsupportedSettingsVersion", code: value.schemaVersion)
        }
        guard Set(value.folders.map(\.id)).count == value.folders.count,
              Set(value.photoAlbums.map(\.id)).count == value.photoAlbums.count else {
            throw CocoaError(.coderReadCorrupt)
        }
        _ = try DisplayLayout.groups(value.displays ?? [])
        return value
    }

    func save(_ value: SettingsSnapshot) throws {
        guard writable else { throw CocoaError(.fileWriteNoPermission) }
        guard value.schemaVersion == 1, Set(value.folders.map(\.id)).count == value.folders.count else { throw CocoaError(.coderInvalidValue) }
        guard Set(value.photoAlbums.map(\.id)).count == value.photoAlbums.count else { throw CocoaError(.coderInvalidValue) }
        _ = try DisplayLayout.groups(value.displays ?? [])
        let data = try JSONEncoder().encode(value)
        if let file {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let old = try? Data(contentsOf: file), (try? decode(old)) != nil {
                try old.write(to: file.appendingPathExtension("previous"), options: .atomic)
            }
            try data.write(to: file, options: .atomic)
        }
        defaults.set(data, forKey: Self.key)
    }
}
