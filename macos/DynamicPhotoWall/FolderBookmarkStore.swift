import Foundation

nonisolated struct PhotoFolder: Identifiable, Codable, Equatable {
    var id = UUID()
    var bookmark: Data
    var path: String?
    // Resolved access is runtime state, never the source of the persisted list.
    var url: URL?
    var isAccessible = false

    private enum CodingKeys: String, CodingKey { case id, bookmark, path }
}

@MainActor
struct FolderAccessProvider {
    var resolve: (Data) throws -> (url: URL, stale: Bool)
    var create: (URL) throws -> Data
    var start: (URL) -> Bool
    var stop: (URL) -> Void
    var isReadable: (URL) -> Bool

    static var system: Self {
        Self(resolve: { data in
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url.standardizedFileURL, stale)
        }, create: { url in
            try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }, start: { $0.startAccessingSecurityScopedResource() },
             stop: { $0.stopAccessingSecurityScopedResource() },
             isReadable: { FileManager.default.isReadableFile(atPath: $0.path) })
    }
}

/// Retains unresolved bookmarks and scopes still in use by a cancelled scan.
@MainActor
final class FolderBookmarkStore {
    static let recordsKey = "photoFolderRecords"
    private let defaults: UserDefaults
    private let access: FolderAccessProvider
    private(set) var folders: [PhotoFolder] = []
    private(set) var warning: String?
    private var scopes: Set<URL> = []
    private var retiredScopes: Set<URL> = []
    private var activeScans: Set<UUID> = []
    private var storedDataIsInvalid = false

    init(defaults: UserDefaults = .standard, access: FolderAccessProvider? = nil) {
        self.defaults = defaults
        self.access = access ?? .system
        if let data = defaults.data(forKey: Self.recordsKey) {
            do { folders = try JSONDecoder().decode([PhotoFolder].self, from: data) }
            catch {
                storedDataIsInvalid = true
                warning = "フォルダ登録情報を読み込めませんでした。元の情報を保持しています。"
            }
        } else {
            var bookmarks = defaults.array(forKey: "photoFolderBookmarks") as? [Data] ?? []
            if bookmarks.isEmpty, let legacy = defaults.data(forKey: "photoFolderBookmark") { bookmarks = [legacy] }
            folders = bookmarks.map { PhotoFolder(bookmark: $0) }
        }
        refreshAccess()
    }

    var accessibleURLs: [URL] { folders.filter(\.isAccessible).compactMap(\.url) }

    func refreshAccess() {
        guard !storedDataIsInvalid else { return }
        warning = nil
        for index in folders.indices {
            do {
                let result = try access.resolve(folders[index].bookmark)
                let url = result.url.standardizedFileURL
                folders[index].url = url
                folders[index].path = url.path
                if !scopes.contains(url), access.start(url) { scopes.insert(url) }
                folders[index].isAccessible = scopes.contains(url) && access.isReadable(url)
                if result.stale, scopes.contains(url) {
                    // Never replace a valid old bookmark with a failed regeneration.
                    if let renewed = try? access.create(url) { folders[index].bookmark = renewed }
                }
                if !folders[index].isAccessible { warning = "未接続または再許可が必要なフォルダがあります。" }
            } catch {
                folders[index].isAccessible = false
                warning = "未接続または再許可が必要なフォルダがあります。登録情報は保持しています。"
            }
        }
        persist()
    }

    func add(_ selectedURL: URL) throws {
        guard !storedDataIsInvalid else { throw AccessError.invalidStoredData }
        let url = selectedURL.standardizedFileURL
        let alreadyAccessing = scopes.contains(url)
        guard alreadyAccessing || access.start(url) else { throw AccessError.denied }
        do {
            let data = try access.create(url)
            scopes.insert(url)
            retiredScopes.remove(url)
            if let index = folders.firstIndex(where: { $0.url == url || $0.path == url.path }) {
                folders[index].bookmark = data
                folders[index].url = url
                folders[index].path = url.path
                folders[index].isAccessible = access.isReadable(url)
            } else {
                folders.append(PhotoFolder(bookmark: data, path: url.path, url: url, isAccessible: access.isReadable(url)))
            }
            persist()
        } catch {
            if !alreadyAccessing { access.stop(url) }
            throw error
        }
    }

    func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where folders.indices.contains(index) {
            if let url = folders[index].url, scopes.contains(url) { retiredScopes.insert(url) }
            folders.remove(at: index)
        }
        // Keep a scope if another registration still refers to it.
        retiredScopes.subtract(folders.compactMap(\.url))
        persist()
        releaseRetiredScopes()
    }

    func beginScan() -> UUID {
        let id = UUID()
        activeScans.insert(id)
        return id
    }

    func endScan(_ id: UUID) {
        activeScans.remove(id)
        releaseRetiredScopes()
    }

    func shutdown() {
        retiredScopes.formUnion(scopes)
        releaseRetiredScopes()
    }

    private func releaseRetiredScopes() {
        guard activeScans.isEmpty else { return }
        for url in retiredScopes { access.stop(url); scopes.remove(url) }
        retiredScopes.removeAll()
    }

    private func persist() {
        guard !storedDataIsInvalid else { return }
        do { defaults.set(try JSONEncoder().encode(folders), forKey: Self.recordsKey) }
        catch { warning = "フォルダ登録情報を保存できませんでした。" }
    }

    enum AccessError: LocalizedError {
        case denied, invalidStoredData
        var errorDescription: String? {
            switch self {
            case .denied: "選択したフォルダへのアクセスを開始できませんでした。"
            case .invalidStoredData: "保存済みのフォルダ情報が壊れています。元の情報を退避してから再登録してください。"
            }
        }
    }
}
