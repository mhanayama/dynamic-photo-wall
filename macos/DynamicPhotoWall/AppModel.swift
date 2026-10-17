import AppKit
import Observation

@MainActor
@Observable
final class AppModel {
    typealias Scanner = @Sendable (URL, Bool) async -> [PhotoAsset]
    private enum DefaultsKey {
        static let selectedScreenID = "selectedScreenID"
        static let settings = "wallSettings"
    }

    var screens: [ScreenDescriptor] = []
    var displays: [WallDisplay] = []
    var displayGroupNames: [String] = []
    var selectedScreenID: CGDirectDisplayID? {
        get { displays.first(where: \.enabled)?.id }
        set {
            if let id = newValue, !displays.contains(where: { $0.id == id }) {
                let screen = screens.first { $0.id == id }
                displays.append(WallDisplay(id: id, name: screen?.name ?? "未接続のディスプレイ", width: Double(screen?.pixelWidth ?? 1920), height: Double(screen?.pixelHeight ?? 1080)))
            }
            for i in displays.indices { displays[i].enabled = displays[i].id == newValue }
        }
    }
    var folders: [PhotoFolder] = []
    var photoAlbums: [PhotoAlbum] = []
    private(set) var availablePhotoAlbums: [PhotoAlbum] = []
    private(set) var isLoadingAlbums = false
    private(set) var photoAlbumsWarning: String?
    private(set) var isScanningAlbums = false
    private(set) var albumPhotoCount: Int?
    private(set) var albumPreviewWarning: String?
    var photoAssets: [PhotoAsset] = []
    var settings = WallSettings()
    private(set) var isScanning = false
    private(set) var wallAttached = false
    private(set) var desiredRunning = false
    private(set) var statusMessage = "写真フォルダーまたはアルバムを選択してください。"
    private(set) var folderWarning: String?
    private(set) var settingsWarning: String?
    private(set) var userPaused = false
    private(set) var covered = false
    @ObservationIgnored private var coveredGroupIDs: Set<WallGroupID> = []
    private(set) var loginItemStatus = ""
    @ObservationIgnored private let fallbackPlayback: WallPlaybackController
    private(set) var sessions: [WallGroupPlayback] = []
    private(set) var testPatternVisible = false
    @ObservationIgnored private var pendingPreviewRestore: (displays: [WallDisplay], running: Bool, paused: Bool)?
    @ObservationIgnored private var previewDisplays: [WallDisplay]?
    @ObservationIgnored private var appliedDisplays: [WallDisplay] = []
    @ObservationIgnored private var appliedGroupNames: [String] = []
    var playback: WallPlaybackController { sessions.first?.primary ?? fallbackPlayback }

    @ObservationIgnored private let loginItems: LoginItemService
    @ObservationIgnored private var watcher: PhotoFolderWatcher?
    @ObservationIgnored private let repository: SettingsRepository
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let host: any DesktopWallHosting
    @ObservationIgnored private let folderStore: FolderBookmarkStore
    @ObservationIgnored private let screenProvider: @MainActor () -> [ScreenDescriptor]
    @ObservationIgnored private let scanner: Scanner
    @ObservationIgnored private let albumsClient: PhotosAlbumClient
    @ObservationIgnored private let observeEnvironment: Bool
    @ObservationIgnored private var appliedPhotoAlbums: [PhotoAlbum] = []
    @ObservationIgnored private var albumsWatcher: PhotosAlbumWatcher?
    @ObservationIgnored private var albumsChangeTask: Task<Void, Never>?
    @ObservationIgnored private var albumPreview: (albums: [PhotoAlbum], task: Task<PhotoAlbumScan, Never>)?
    @ObservationIgnored private var albumPreviewCompletion: Task<Void, Never>?
    @ObservationIgnored private var albumPreviewGeneration = 0
    @ObservationIgnored private var appliedSettings = WallSettings()
    @ObservationIgnored private var appliedScreenID: CGDirectDisplayID?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    @ObservationIgnored private var reconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var terminated = false

    init(defaults: UserDefaults = .standard, host: (any DesktopWallHosting)? = nil,
         playback: WallPlaybackController? = nil,
         folderStore: FolderBookmarkStore? = nil,
         screenProvider: @escaping @MainActor () -> [ScreenDescriptor] = ScreenDescriptor.availableScreens,
         scanner: @escaping Scanner = { await PhotoLibrary.scan(folderURL: $0, recursive: $1) },
         observeEnvironment: Bool = true, settingsFile: URL? = nil, loginItems: LoginItemService? = nil,
         albumsClient: PhotosAlbumClient = .system) {
        self.loginItems = loginItems ?? (observeEnvironment ? .system : .isolated)
        self.defaults = defaults
        self.repository = SettingsRepository(defaults: defaults, file: settingsFile)
        self.host = host ?? DesktopWindowController()
        self.fallbackPlayback = playback ?? WallPlaybackController(imageStore: .shared)
        self.folderStore = folderStore ?? FolderBookmarkStore(defaults: defaults)
        self.screenProvider = screenProvider
        self.scanner = scanner
        self.albumsClient = albumsClient
        self.observeEnvironment = observeEnvironment
        let snapshot = repository.load()
        if let snapshot {
            settings = snapshot.settings
            self.folderStore.replace(with: snapshot.folders)
            photoAlbums = snapshot.photoAlbums
        } else { restoreSettings() }
        settingsWarning = repository.warning ?? settingsWarning
        // Read the saved ID before enumeration. Disconnection never overwrites it.
        let saved = snapshot.map { $0.screenID.map(Int.init) ?? 0 } ?? defaults.integer(forKey: DefaultsKey.selectedScreenID)
        let savedID: CGDirectDisplayID? = saved > 0 ? CGDirectDisplayID(exactly: saved) : nil
        screens = screenProvider()
        if let stored = snapshot?.displays { displays = stored }
        else if let savedID {
            if let screen = screens.first(where: { $0.id == savedID }) {
                displays = [DisplayLayout.detected(screen, screens: screens, enabled: true)]
            } else { displays = [WallDisplay(id: savedID, name: "未接続のディスプレイ", width: 1920, height: 1080)] }
        } else if let first = screens.first { displays = [DisplayLayout.detected(first, screens: screens, enabled: true)] }
        appliedDisplays = snapshot?.displays ?? (savedID == nil ? [] : displays)
        displayGroupNames = DisplayLayout.groupNames(snapshot?.displayGroupNames ?? [], displays: displays)
        appliedGroupNames = displayGroupNames
        mergeDetectedScreens()
        appliedScreenID = savedID
        appliedSettings = settings
        appliedPhotoAlbums = photoAlbums
        syncFolders()
        desiredRunning = appliedDisplays.contains(where: \.enabled) && settings.startOnLaunch && (!folders.isEmpty || !photoAlbums.isEmpty)
        loginItemStatus = self.loginItems.status()
        if observeEnvironment {
            watcher = PhotoFolderWatcher { [weak self] in self?.retryFolders() }
            observeSystemEnvironment()
        }
        reloadPhotos()
    }

    static func makeLaunchModel() -> AppModel {
        let environment = ProcessInfo.processInfo.environment
        if let profile = environment["DPW_UI_TEST_PROFILE"] { return makeUITestModel(profile: profile) }
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil {
            // The app is the test host. Never open the user's wall or bookmarks.
            return AppModel(defaults: UserDefaults(suiteName: "DynamicPhotoWall.TestHost.\(UUID())")!,
                            screenProvider: { [] }, observeEnvironment: false)
        }
        return AppModel(settingsFile: RuntimePaths.root.appending(path: "settings.json"))
    }

    var hasSavedScreen: Bool { appliedDisplays.contains(where: \.enabled) }
    var needsFolderRecovery: Bool { folderStore.hasInvalidStoredData }
    func recoverFolders() { folderStore.recoverInvalidStoredData(); syncFolders() }
    var selectedScreen: ScreenDescriptor? { screens.first { $0.id == selectedScreenID } }
    var displayConnectionMessage: String {
        "\(screens.count)台接続中 · \(displays.filter(\.enabled).count)台選択。未接続画面の配置も保持します。"
    }
    var canStart: Bool { displays.contains { display in display.enabled && screens.contains(where: { $0.id == display.id }) } && (!folders.isEmpty || !photoAlbums.isEmpty) && !isScanning }
    var canStartApplied: Bool { appliedDisplays.contains(where: \.enabled) && (!folderStore.folders.isEmpty || !appliedPhotoAlbums.isEmpty) && !isScanning }
    var isPlaying: Bool { !testPatternVisible && sessions.contains { $0.primary.currentScene != nil && !$0.isWaiting } }
    var isWaiting: Bool { !testPatternVisible && desiredRunning && (!wallAttached || sessions.allSatisfy(\.isWaiting)) }
    var canAdvance: Bool { !testPatternVisible && desiredRunning && wallAttached }
    var playbackStateLabel: String {
        if testPatternVisible { return "テスト表示中" }
        if !desiredRunning { return "停止中" }
        if isWaiting { return "待機中" }
        if sleeping { return "スリープ中" }
        if userPaused { return "一時停止中" }
        if covered { return "画面遮蔽で休止中" }
        if playback.waitingForImages { return "準備中" }
        return "再生中"
    }
    var displayStatusMessage: String {
        testPatternVisible ? "テストパターンを表示中" : playback.imageFailureMessage
            ?? ((playback.waitingForImages || playback.waitingForScrollImage)
                ? "次の写真を準備中 · 現在の表示を保持しています" : statusMessage)
    }
    var currentMode: String? {
        let modes = sessions.compactMap { $0.primary.currentScene?.mode.displayName }
        return modes.isEmpty ? nil : modes.joined(separator: " / ")
    }
    var displayPhotoAlbumsWarning: String? { albumPreview == nil ? photoAlbumsWarning : albumPreviewWarning }

    private func mergeDetectedScreens() {
        for screen in screens {
            if let i = displays.firstIndex(where: { $0.id == screen.id }) {
                displays[i].name = screen.name
                displays[i].width = Double(screen.pixelWidth); displays[i].height = Double(screen.pixelHeight)
            } else { displays.append(DisplayLayout.detected(screen, screens: screens)) }
            if let i = previewDisplays?.firstIndex(where: { $0.id == screen.id }) {
                previewDisplays?[i].width = Double(screen.pixelWidth); previewDisplays?[i].height = Double(screen.pixelHeight)
            }
            if let i = appliedDisplays.firstIndex(where: { $0.id == screen.id }) {
                appliedDisplays[i].name = screen.name
                appliedDisplays[i].width = Double(screen.pixelWidth); appliedDisplays[i].height = Double(screen.pixelHeight)
            }
        }
    }

    func refreshScreens() {
        screens = screenProvider()
        mergeDetectedScreens()
        reconcilePlayback()
    }

    func addDisplayGroup() {
        var index = 1
        while displayGroupNames.contains("グループ\(index)") { index += 1 }
        displayGroupNames.append("グループ\(index)")
    }

    func deleteDisplayGroup(_ name: String) {
        displayGroupNames.removeAll { $0 == name }
        for i in displays.indices where DisplayLayout.cleanName(displays[i].groupID) == name { displays[i].groupID = nil }
    }

    func resetDisplayPositions() {
        for screen in screens {
            if let i = displays.firstIndex(where: { $0.id == screen.id }) {
                let detected = DisplayLayout.detected(screen, screens: screens)
                displays[i].x = detected.x; displays[i].y = detected.y
            }
        }
    }

    func toggleTestPattern() {
        if testPatternVisible { endTestPattern(); return }
        var attempted = false
        do {
            let groups = try DisplayLayout.groups(displays)
            let outputs = makeOutputs(groups: groups, sessions: [])
            guard !outputs.isEmpty else { throw DisplayLayout.LayoutError.noConnectedDisplay }
            attempted = true
            try host.present(outputs)
            for session in sessions { session.stop() }
            sessions = []
            previewDisplays = displays
            testPatternVisible = true; wallAttached = true
            statusMessage = "テストパターンを表示中"
        } catch {
            if attempted { try? host.present(makeOutputs(groups: sessions.map(\.group), sessions: sessions)) }
            statusMessage = error.localizedDescription
        }
    }

    private func endTestPattern() {
        guard testPatternVisible else { return }
        let old = previewDisplays
        testPatternVisible = false; previewDisplays = nil; wallAttached = false
        do {
            try reconcileOutputs()
            if !desiredRunning { host.close() }
        } catch {
            previewDisplays = old; testPatternVisible = true
            if let old, let groups = try? DisplayLayout.groups(old) { try? host.present(makeOutputs(groups: groups, sessions: [])) }
            wallAttached = true; statusMessage = error.localizedDescription
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "写真フォルダーを追加／再許可"
        panel.prompt = "追加"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var failures: [String] = []
        for url in panel.urls {
            do {
                let folder = try folderStore.makeDraftFolder(url)
                if let index = folders.firstIndex(where: { $0.path == folder.path }) { folders[index] = folder }
                else { folders.append(folder) }
            }
            catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { folderWarning = failures.joined(separator: "\n") }
    }

    func removeFolders(at offsets: IndexSet) {
        guard offsets.contains(where: { folders.indices.contains($0) }) else { return }
        for index in offsets.sorted(by: >) where folders.indices.contains(index) { folders.remove(at: index) }
    }

    func loadPhotoAlbums() async {
        guard !isLoadingAlbums, !terminated else { return }
        isLoadingAlbums = true
        let catalog = await albumsClient.catalog()
        isLoadingAlbums = false
        guard !terminated else { return }
        availablePhotoAlbums = catalog.albums
        photoAlbumsWarning = catalog.warning
        updateAlbumsWatcher()
    }

    func addPhotoAlbums(ids: Set<String>) {
        let previous = photoAlbums
        for album in availablePhotoAlbums where ids.contains(album.id) && !photoAlbums.contains(where: { $0.id == album.id }) {
            photoAlbums.append(album)
        }
        if photoAlbums != previous { scanSelectedAlbums() }
    }

    func removePhotoAlbum(id: String) {
        guard photoAlbums.contains(where: { $0.id == id }) else { return }
        photoAlbums.removeAll { $0.id == id }
        scanSelectedAlbums()
    }

    func rescanPhotoAlbums() {
        if photoAlbums == appliedPhotoAlbums {
            clearAlbumPreview()
            reloadPhotos()
        } else { scanSelectedAlbums() }
    }

    private func scanSelectedAlbums() {
        clearAlbumPreview()
        guard !terminated, !photoAlbums.isEmpty else { albumPhotoCount = 0; return }
        let albums = photoAlbums
        let client = albumsClient
        let generation = albumPreviewGeneration
        let task = Task { await client.scan(albums) }
        albumPreview = (albums, task)
        isScanningAlbums = true
        albumPreviewCompletion = Task { [weak self] in
            let result = await task.value
            guard let self, !Task.isCancelled, !self.terminated,
                  self.albumPreviewGeneration == generation, self.photoAlbums == albums else { return }
            self.albumPhotoCount = result.assets.count
            self.albumPreviewWarning = result.warning
            self.isScanningAlbums = false
        }
    }

    private func clearAlbumPreview(cancelScan: Bool = true) {
        albumPreviewGeneration += 1
        if cancelScan { albumPreview?.task.cancel() }
        albumPreviewCompletion?.cancel()
        albumPreviewCompletion = nil
        albumPreview = nil
        isScanningAlbums = false
        albumPhotoCount = nil
        albumPreviewWarning = nil
    }

    static func uniquePhotos(_ photos: [PhotoAsset]) -> [PhotoAsset] {
        Dictionary(grouping: photos, by: \.sourceURL).compactMap(\.value.first)
            .sorted { $0.url.absoluteString < $1.url.absoluteString }
    }

    func cancelDraft() {
        clearAlbumPreview()
        settings = appliedSettings
        photoAlbums = appliedPhotoAlbums
        displays = appliedDisplays
        displayGroupNames = appliedGroupNames
        mergeDetectedScreens()
        folderStore.discardDraft()
        syncFolders()
    }

    func retryFolders() {
        let before = Dictionary(uniqueKeysWithValues: folderStore.folders.map { ($0.id, $0.bookmark) })
        folderStore.refreshAccess()
        let refreshed = Dictionary(uniqueKeysWithValues: folderStore.folders.map { ($0.id, $0) })
        folders = folders.map { before[$0.id] == $0.bookmark ? refreshed[$0.id] ?? $0 : $0 }
        folderWarning = folderStore.warning
        reloadPhotos()
    }

    func removeFolders(ids: Set<UUID>) {
        removeFolders(at: IndexSet(folders.indices.filter { ids.contains(folders[$0].id) }))
    }

    func saveSettings() {
        applySettings(startRequested: selectedScreenID != nil && (!folders.isEmpty || !photoAlbums.isEmpty))
    }
    func start() {
        guard !isScanning else { return }
        applySettings(startRequested: true, endPreview: true)
    }

    func startApplied() {
        guard canStartApplied else { return }
        if let previewDisplays { pendingPreviewRestore = (previewDisplays, desiredRunning, userPaused) }
        testPatternVisible = false; previewDisplays = nil
        desiredRunning = true
        userPaused = false
        reloadPhotos()
    }

    private func applySettings(startRequested: Bool, endPreview: Bool = false) {
        do {
            guard !folderStore.hasInvalidStoredData else { throw FolderBookmarkStore.AccessError.invalidStoredData }
            var normalized = settings
            normalized.normalize()
            try normalized.validate()
            _ = try DisplayLayout.groups(displays)
            let previousAutoStart = appliedSettings.autoStart
            try loginItems.setEnabled(normalized.autoStart)
            do { try repository.save(SettingsSnapshot(settings: normalized, screenID: selectedScreenID, folders: folders, photoAlbums: photoAlbums, displays: displays, displayGroupNames: displayGroupNames)) }
            catch { try? loginItems.setEnabled(previousAutoStart); throw error }
            loginItemStatus = loginItems.status()
            folderStore.replace(with: folders)
            syncFolders()
            let encoded = try JSONEncoder().encode(normalized)
            defaults.set(encoded, forKey: DefaultsKey.settings)
            if let selectedScreenID { defaults.set(Int(selectedScreenID), forKey: DefaultsKey.selectedScreenID) }
            else { defaults.removeObject(forKey: DefaultsKey.selectedScreenID) }
            settings = normalized
            settingsWarning = nil
            appliedSettings = normalized
            appliedPhotoAlbums = photoAlbums
            appliedScreenID = selectedScreenID
            appliedDisplays = displays
            appliedGroupNames = DisplayLayout.groupNames(displayGroupNames, displays: displays)
            displayGroupNames = appliedGroupNames
            // Reuse the selection scan even when Apply is pressed before it finishes.
            let preparedAlbums = albumPreview?.albums == photoAlbums ? albumPreview?.task : nil
            clearAlbumPreview(cancelScan: preparedAlbums == nil)
            if endPreview, testPatternVisible {
                if let previewDisplays { pendingPreviewRestore = (previewDisplays, desiredRunning, userPaused) }
                testPatternVisible = false; previewDisplays = nil
            }
            if startRequested && !testPatternVisible { desiredRunning = true; userPaused = false }
            if !testPatternVisible { suspendWall() }
            reloadPhotos(preparedAlbums: preparedAlbums)
        } catch {
            statusMessage = error.localizedDescription
            WallLog.write("設定を適用できません。", error: error)
        }
    }

    func stop() {
        desiredRunning = false
        userPaused = false
        testPatternVisible = false; previewDisplays = nil; pendingPreviewRestore = nil
        suspendWall()
        statusMessage = "停止中 · \(photoAssets.count)枚"
    }

    func togglePause() {
        guard desiredRunning else { return }
        userPaused.toggle()
        for session in sessions { session.setPaused(userPaused || sleeping || covered || coveredGroupIDs.contains(session.group.id)) }
        updatePlayingStatus()
    }

    func retryPlayback() {
        guard desiredRunning, !isScanning else { return }
        retryFolders()
    }

    func showNextScene() {
        guard canAdvance else { return }
        for session in sessions { session.next() }
        updatePlayingStatus()
    }

    /// All writers use a generation token, including scans that ignore cancellation.
    func reloadPhotos() {
        reloadPhotos(preparedAlbums: nil)
    }

    private func reloadPhotos(preparedAlbums: Task<PhotoAlbumScan, Never>?) {
        guard !terminated else { return }
        scanGeneration += 1
        let generation = scanGeneration
        scanTask?.cancel()
        let folders = folderStore.accessibleURLs
        let albums = appliedPhotoAlbums
        let albumsClient = albumsClient
        updateAlbumsWatcher()
        watcher?.watch(folders)
        guard !folders.isEmpty || !albums.isEmpty else {
            isScanning = false
            photoAssets = []
            if !testPatternVisible { suspendWall() }
            photoAlbumsWarning = nil
            statusMessage = folderStore.folders.isEmpty ? "写真フォルダーまたはアルバムを選択してください。" : "写真フォルダー未接続 · 再接続を待機中"
            return
        }
        isScanning = true
        statusMessage = "写真を検索しています…"
        let recursive = appliedSettings.recursive
        let scanner = scanner
        let store = folderStore
        let lease = store.beginScan()
        scanTask = Task { [weak self] in
            async let albumScan: PhotoAlbumScan = withTaskCancellationHandler {
                if let preparedAlbums { return await preparedAlbums.value }
                return await albumsClient.scan(albums)
            } onCancel: { preparedAlbums?.cancel() }
            let photos = await withTaskGroup(of: [PhotoAsset].self) { group in
                for folder in folders { group.addTask { await scanner(folder, recursive) } }
                var result: [PhotoAsset] = []
                for await items in group { result.append(contentsOf: items) }
                return result
            }
            // Even obsolete scans must release their scope lease after all work ends.
            store.endScan(lease)
            let albumResult = await albumScan
            guard let self, !Task.isCancelled, !self.terminated,
                  self.scanGeneration == generation else { return }
            let updated = Self.uniquePhotos(photos + albumResult.assets)
            self.photoAlbumsWarning = albumResult.warning
            if self.albumPreview == nil, self.photoAlbums == albums {
                self.albumPhotoCount = albumResult.assets.count
            }
            self.photoAssets = updated
            self.isScanning = false
            self.scanTask = nil
            if self.desiredRunning, !self.testPatternVisible, self.wallAttached {
                for session in self.sessions { session.updateLibrary(updated) }
            }
            self.reconcilePlayback()
        }
    }

    private func makeOutputs(groups: [WallDisplayGroup], sessions: [WallGroupPlayback]) -> [DesktopWallOutput] {
        let selected = (testPatternVisible ? previewDisplays ?? [] : (sessions.isEmpty ? displays : appliedDisplays)).filter(\.enabled)
        return groups.flatMap { group in
            group.displays.compactMap { display in
                guard let screen = screens.first(where: { $0.id == display.id }) else { return nil }
                let number = (selected.firstIndex(where: { $0.id == display.id }) ?? 0) + 1
                return DesktopWallOutput(screen: screen, display: display, group: group, number: number,
                    session: sessions.first { $0.group.id == group.id })
            }
        }
    }

    private func reconcilePlayback() {
        guard !terminated else { return }
        do { try reconcileOutputs() }
        catch {
            if let previous = pendingPreviewRestore {
                previewDisplays = previous.displays; desiredRunning = previous.running; userPaused = previous.paused
                testPatternVisible = true; pendingPreviewRestore = nil
                if let groups = try? DisplayLayout.groups(previous.displays) { try? host.present(makeOutputs(groups: groups, sessions: [])) }
                wallAttached = true
            }
            statusMessage = error.localizedDescription; WallLog.write("画面を作成できません。", error: error)
        }
    }

    private func reconcileOutputs() throws {
        if testPatternVisible, let previewDisplays {
            let groups = try DisplayLayout.groups(previewDisplays)
            let outputs = makeOutputs(groups: groups, sessions: [])
            try host.present(outputs)
            wallAttached = !outputs.isEmpty
            return
        }
        guard !isScanning, desiredRunning else { return }
        let groups = try DisplayLayout.groups(appliedDisplays)
        let connected = Set(screens.map(\.id))
        var updated: [WallGroupPlayback] = []
        var created: [WallGroupPlayback] = []
        for group in groups {
            let ids = Set(group.displays.map(\.id)).intersection(connected)
            guard !ids.isEmpty else { continue }
            if let existing = sessions.first(where: { $0.group == group && $0.connected == ids }) { updated.append(existing) }
            else if !photoAssets.isEmpty {
                let session = WallGroupPlayback(group: group, connected: ids, assets: photoAssets, settings: appliedSettings,
                    primary: sessions.isEmpty && groups.count == 1 && group.displays.count == 1 ? fallbackPlayback : nil,
                    imageStore: fallbackPlayback.imageStore)
                updated.append(session); created.append(session)
            }
        }
        let outputs = makeOutputs(groups: updated.map(\.group), sessions: updated)
        do { try host.present(outputs) }
        catch { for session in created { session.stop() }; throw error }
        for session in sessions where !updated.contains(where: { $0 === session }) { session.stop() }
        pendingPreviewRestore = nil
        sessions = updated; wallAttached = !outputs.isEmpty
        for session in sessions { session.setPaused(userPaused || sleeping || covered || coveredGroupIDs.contains(session.group.id)) }
        if outputs.isEmpty {
            statusMessage = groups.contains(where: { $0.displays.contains { connected.contains($0.id) } })
                ? photoAlbumsWarning ?? "画像がありません · 写真の追加を待機中" : "対象ディスプレイ未接続 · 再接続を待機中"
        } else { updatePlayingStatus() }
    }

    private func suspendWall() {
        host.close()
        for session in sessions { session.stop() }
        sessions = []; fallbackPlayback.stop()
        wallAttached = false
    }

    private func updatePlayingStatus() {
        guard wallAttached else { return }
        if testPatternVisible { statusMessage = "テストパターンを表示中"; return }
        if sessions.allSatisfy(\.isWaiting) { statusMessage = playback.imageFailureMessage ?? "画像の準備を待機中"; return }
        statusMessage = userPaused ? "一時停止中" : sleeping ? "スリープ中" : covered ? "画面遮蔽で休止中" : "再生中 · \(photoAssets.count)枚 · \(sessions.count)グループ"
    }

    private func syncFolders() {
        folders = folderStore.folders
        folderWarning = folderStore.warning
    }

    private func updateAlbumsWatcher() {
        guard observeEnvironment, !appliedPhotoAlbums.isEmpty, PhotosAlbumLibrary.hasAccess else {
            albumsWatcher?.stop()
            albumsWatcher = nil
            return
        }
        guard albumsWatcher == nil else { return }
        albumsWatcher = PhotosAlbumWatcher { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.terminated else { return }
                self.albumsChangeTask?.cancel()
                self.albumsChangeTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    self?.reloadPhotos()
                }
            }
        }
    }

    private func restoreSettings() {
        guard let data = defaults.data(forKey: DefaultsKey.settings) else { return }
        do { settings = try JSONDecoder().decode(WallSettings.self, from: data) }
        catch {
            defaults.set(data, forKey: "wallSettings.invalid")
            settingsWarning = "設定を読み込めないため初期値を使用します。元の設定は退避しました。"
        }
    }

    func updateOcclusion(_ isCovered: Bool) {
        covered = isCovered
        coveredGroupIDs = isCovered ? Set(sessions.map { $0.group.id }) : []
        for session in sessions { session.setPaused(userPaused || sleeping || covered || coveredGroupIDs.contains(session.group.id)) }
        updatePlayingStatus()
    }

    private func checkOcclusion() {
        coveredGroupIDs = []
        var coveredGroups = 0
        for session in sessions {
            let members = screens.filter { session.connected.contains($0.id) }
            let hidden = WindowOcclusion.isCovered(members)
            if hidden { coveredGroups += 1; coveredGroupIDs.insert(session.group.id) }
            session.setPaused(userPaused || sleeping || hidden)
        }
        covered = !sessions.isEmpty && coveredGroups == sessions.count
        updatePlayingStatus()
    }

    private func observeSystemEnvironment() {
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.refreshScreens() }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.checkOcclusion() }
        observe(workspace, NSWorkspace.willSleepNotification) {
            $0.sleeping = true; for session in $0.sessions { session.setPaused(true) }; $0.updatePlayingStatus()
        }
        observe(workspace, NSWorkspace.didWakeNotification) {
            $0.sleeping = false; $0.refreshScreens(); $0.checkOcclusion()
        }
        observe(.default, NSApplication.willTerminateNotification) { $0.shutdown() }
        healthTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.checkOcclusion()
                ticks += 1
                if ticks % 15 == 0 { self?.refreshScreens() }
            }
        }
        reconciliationTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                self?.retryFolders()
            }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (AppModel) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in action(self) }
        }
        observers.append((center, observer))
    }

    func shutdown() {
        guard !terminated else { return }
        terminated = true
        desiredRunning = false
        scanGeneration += 1
        scanTask?.cancel()
        clearAlbumPreview()
        healthTask?.cancel()
        reconciliationTask?.cancel()
        watcher?.stop()
        albumsChangeTask?.cancel()
        albumsWatcher?.stop()
        albumsWatcher = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        suspendWall()
        folderStore.shutdown()
    }
}
