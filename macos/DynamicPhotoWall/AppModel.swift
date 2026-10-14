import AppKit
import Observation

@MainActor
@Observable
final class AppModel {
    private enum DefaultsKey {
        static let folderBookmarks = "photoFolderBookmarks"
        static let legacyFolderBookmark = "photoFolderBookmark"
        static let selectedScreenID = "selectedScreenID"
        static let settings = "wallSettings"
    }

    var screens: [ScreenDescriptor] = []
    var selectedScreenID: CGDirectDisplayID?
    var folderURLs: [URL] = []
    var photoAssets: [PhotoAsset] = []
    var settings = WallSettings()
    var isScanning = false
    var isPlaying = false
    var statusMessage = "写真フォルダを選択してください。"

    @ObservationIgnored private let desktopWindowController = DesktopWindowController()
    @ObservationIgnored private var securityScopedFolderURLs: [URL] = []
    @ObservationIgnored private var didHandleLaunchStart = false

    init() {
        restoreSettings()
        refreshScreens()
        restoreSelection()
        restoreFolderAccess()
    }

    var selectedScreen: ScreenDescriptor? {
        screens.first { $0.id == selectedScreenID }
    }

    var canStart: Bool {
        selectedScreen != nil && !photoAssets.isEmpty && !isScanning
    }

    func refreshScreens() {
        screens = ScreenDescriptor.availableScreens()
        if let selectedScreenID, screens.contains(where: { $0.id == selectedScreenID }) {
            return
        }
        selectedScreenID = screens.first?.id
        persistScreenSelection()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "写真フォルダを追加"
        panel.message = "複数の写真フォルダを登録できます。"
        panel.prompt = "追加"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true

        guard panel.runModal() == .OK else {
            return
        }

        for url in panel.urls where !folderURLs.contains(url) {
            guard url.startAccessingSecurityScopedResource() else {
                statusMessage = "選択したフォルダへのアクセスを開始できませんでした。"
                continue
            }
            securityScopedFolderURLs.append(url)
            folderURLs.append(url)
        }
        saveBookmarks()
        reloadPhotos()
    }

    func removeFolders(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            guard folderURLs.indices.contains(index) else {
                continue
            }
            let url = folderURLs.remove(at: index)
            if let accessIndex = securityScopedFolderURLs.firstIndex(of: url) {
                securityScopedFolderURLs.remove(at: accessIndex)
                    .stopAccessingSecurityScopedResource()
            }
        }
        saveBookmarks()
        reloadPhotos()
    }

    func saveSettings() {
        settings.normalize()
        persistScreenSelection()
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.settings)
        }
        reloadPhotos()
    }

    func start() {
        guard let selectedScreen, !photoAssets.isEmpty else {
            statusMessage = "対象画面と写真フォルダを確認してください。"
            return
        }

        settings.normalize()
        saveSettingsWithoutRestart()
        desktopWindowController.show(
            on: selectedScreen,
            photoAssets: photoAssets,
            settings: settings
        )
        isPlaying = true
        statusMessage = "\(selectedScreen.name) で表示中"
    }

    func stop() {
        desktopWindowController.close()
        isPlaying = false
        statusMessage = photoAssets.isEmpty
            ? "写真フォルダを選択してください。"
            : "\(photoAssets.count)枚の写真を読み込み済み"
    }

    func showNextScene() {
        guard isPlaying else {
            return
        }
        desktopWindowController.showNextScene()
        statusMessage = "次の構成を表示しました。"
    }

    private func reloadPhotos() {
        let folders = folderURLs
        guard !folders.isEmpty else {
            photoAssets = []
            statusMessage = "写真フォルダを選択してください。"
            return
        }

        isScanning = true
        statusMessage = "写真を検索しています…"
        let recursive = settings.recursive

        Task {
            let photos = await withTaskGroup(of: [PhotoAsset].self) { group in
                for folder in folders {
                    group.addTask {
                        await PhotoLibrary.scan(folderURL: folder, recursive: recursive)
                    }
                }

                var result: [PhotoAsset] = []
                for await items in group {
                    result.append(contentsOf: items)
                }
                return result
            }

            photoAssets = Array(Dictionary(grouping: photos, by: \.url).compactMap(\.value.first))
                .sorted {
                    $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent)
                        == .orderedAscending
                }
            isScanning = false
            statusMessage = photoAssets.isEmpty
                ? "対応する写真が見つかりませんでした。"
                : "\(photoAssets.count)枚の写真を読み込みました。"

            if isPlaying {
                start()
            } else if !didHandleLaunchStart {
                didHandleLaunchStart = true
                if settings.startOnLaunch, canStart {
                    start()
                }
            }
        }
    }

    private func saveSettingsWithoutRestart() {
        persistScreenSelection()
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.settings)
        }
    }

    private func restoreSettings() {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.settings),
              let decoded = try? JSONDecoder().decode(WallSettings.self, from: data) else {
            return
        }
        settings = decoded
        settings.normalize()
    }

    private func saveBookmarks() {
        let bookmarks = folderURLs.compactMap {
            try? $0.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        UserDefaults.standard.set(bookmarks, forKey: DefaultsKey.folderBookmarks)
    }

    private func restoreFolderAccess() {
        var bookmarks = UserDefaults.standard.array(forKey: DefaultsKey.folderBookmarks) as? [Data] ?? []
        if bookmarks.isEmpty,
           let legacy = UserDefaults.standard.data(forKey: DefaultsKey.legacyFolderBookmark) {
            bookmarks = [legacy]
        }

        for bookmark in bookmarks {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), url.startAccessingSecurityScopedResource() else {
                continue
            }
            securityScopedFolderURLs.append(url)
            folderURLs.append(url)
        }

        saveBookmarks()
        reloadPhotos()
    }

    private func persistScreenSelection() {
        if let selectedScreenID {
            UserDefaults.standard.set(Int(selectedScreenID), forKey: DefaultsKey.selectedScreenID)
        }
    }

    private func restoreSelection() {
        let savedID = UserDefaults.standard.integer(forKey: DefaultsKey.selectedScreenID)
        guard savedID != 0 else {
            return
        }

        let displayID = CGDirectDisplayID(savedID)
        if screens.contains(where: { $0.id == displayID }) {
            selectedScreenID = displayID
        }
    }
}
