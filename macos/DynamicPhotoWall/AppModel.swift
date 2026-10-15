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
    var selectedScreenID: CGDirectDisplayID?
    var folders: [PhotoFolder] = []
    var photoAssets: [PhotoAsset] = []
    var settings = WallSettings()
    private(set) var isScanning = false
    private(set) var wallAttached = false
    private(set) var desiredRunning = false
    private(set) var statusMessage = "写真フォルダーを選択してください。"
    private(set) var folderWarning: String?
    private(set) var settingsWarning: String?
    private(set) var userPaused = false
    private(set) var covered = false
    private(set) var loginItemStatus = ""
    let playback: WallPlaybackController

    @ObservationIgnored private let loginItems: LoginItemService
    @ObservationIgnored private var watcher: PhotoFolderWatcher?
    @ObservationIgnored private let repository: SettingsRepository
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let host: any DesktopWallHosting
    @ObservationIgnored private let folderStore: FolderBookmarkStore
    @ObservationIgnored private let screenProvider: @MainActor () -> [ScreenDescriptor]
    @ObservationIgnored private let scanner: Scanner
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
         observeEnvironment: Bool = true, settingsFile: URL? = nil, loginItems: LoginItemService? = nil) {
        self.loginItems = loginItems ?? (observeEnvironment ? .system : .isolated)
        self.defaults = defaults
        self.repository = SettingsRepository(defaults: defaults, file: settingsFile)
        self.host = host ?? DesktopWindowController()
        self.playback = playback ?? WallPlaybackController(imageStore: .shared)
        self.folderStore = folderStore ?? FolderBookmarkStore(defaults: defaults)
        self.screenProvider = screenProvider
        self.scanner = scanner
        let snapshot = repository.load()
        if let snapshot {
            settings = snapshot.settings
            self.folderStore.replace(with: snapshot.folders)
        } else { restoreSettings() }
        settingsWarning = repository.warning ?? settingsWarning
        // Read the saved ID before enumeration. Disconnection never overwrites it.
        let saved = snapshot.map { $0.screenID.map(Int.init) ?? 0 } ?? defaults.integer(forKey: DefaultsKey.selectedScreenID)
        let savedID: CGDirectDisplayID? = saved > 0 ? CGDirectDisplayID(exactly: saved) : nil
        selectedScreenID = savedID
        screens = screenProvider()
        if selectedScreenID == nil { selectedScreenID = screens.first?.id }
        appliedScreenID = savedID
        appliedSettings = settings
        syncFolders()
        desiredRunning = savedID != nil && settings.startOnLaunch && !folders.isEmpty
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

    var hasSavedScreen: Bool { appliedScreenID != nil }
    var needsFolderRecovery: Bool { folderStore.hasInvalidStoredData }
    func recoverFolders() { folderStore.recoverInvalidStoredData(); syncFolders() }
    var selectedScreen: ScreenDescriptor? { screens.first { $0.id == selectedScreenID } }
    var displayConnectionMessage: String {
        if selectedScreenID != nil, selectedScreen == nil {
            return "保存済みのディスプレイは未接続です。再接続するか表示対象を選び直してください。"
        }
        return "\(screens.count)台接続中。選択画面だけに写真を表示します。"
    }
    var canStart: Bool { selectedScreen != nil && !folders.isEmpty && !isScanning }
    var canStartApplied: Bool { appliedScreenID != nil && !folderStore.folders.isEmpty && !isScanning }
    var isPlaying: Bool { wallAttached && playback.currentScene != nil && !playback.isWaiting }
    var isWaiting: Bool { desiredRunning && (!wallAttached || playback.isWaiting) }
    var canAdvance: Bool { desiredRunning && wallAttached }
    var playbackStateLabel: String {
        if !desiredRunning { return "停止中" }
        if isWaiting { return "待機中" }
        if sleeping { return "スリープ中" }
        if userPaused { return "一時停止中" }
        if covered { return "画面遮蔽で休止中" }
        if playback.waitingForImages { return "準備中" }
        return "再生中"
    }
    var displayStatusMessage: String {
        playback.imageFailureMessage
            ?? ((playback.waitingForImages || playback.waitingForScrollImage)
                ? "次の写真を準備中 · 現在の表示を保持しています" : statusMessage)
    }
    var currentMode: String? { playback.currentScene?.mode.displayName }

    func refreshScreens() {
        screens = screenProvider()
        if selectedScreenID == nil { selectedScreenID = screens.first?.id }
        reconcilePlayback()
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

    func cancelDraft() {
        settings = appliedSettings
        selectedScreenID = appliedScreenID ?? screens.first?.id
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

    func saveSettings() { applySettings(startRequested: false) }
    func start() {
        guard !isScanning else { return }
        applySettings(startRequested: true)
    }

    func startApplied() {
        guard !isScanning, appliedScreenID != nil, !folderStore.folders.isEmpty else { return }
        desiredRunning = true
        userPaused = false
        reloadPhotos()
    }

    private func applySettings(startRequested: Bool) {
        do {
            guard !folderStore.hasInvalidStoredData else { throw FolderBookmarkStore.AccessError.invalidStoredData }
            var normalized = settings
            normalized.normalize()
            try normalized.validate()
            let previousAutoStart = appliedSettings.autoStart
            try loginItems.setEnabled(normalized.autoStart)
            do { try repository.save(SettingsSnapshot(settings: normalized, screenID: selectedScreenID, folders: folders)) }
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
            appliedScreenID = selectedScreenID
            if startRequested { desiredRunning = true; userPaused = false }
            suspendWall()
            reloadPhotos()
        } catch {
            statusMessage = error.localizedDescription
            WallLog.write("設定を適用できません。", error: error)
        }
    }

    func stop() {
        desiredRunning = false
        userPaused = false
        suspendWall()
        statusMessage = "停止中 · \(photoAssets.count)枚"
    }

    func togglePause() {
        guard desiredRunning else { return }
        userPaused.toggle()
        playback.setPaused(userPaused || sleeping || covered)
        updatePlayingStatus()
    }

    func retryPlayback() {
        guard desiredRunning, !isScanning else { return }
        retryFolders()
    }

    func showNextScene() {
        guard canAdvance else { return }
        playback.next()
        updatePlayingStatus()
    }

    /// All writers use a generation token, including scans that ignore cancellation.
    func reloadPhotos() {
        guard !terminated else { return }
        scanGeneration += 1
        let generation = scanGeneration
        scanTask?.cancel()
        let folders = folderStore.accessibleURLs
        watcher?.watch(folders)
        guard !folders.isEmpty else {
            isScanning = false
            photoAssets = []
            suspendWall()
            statusMessage = self.folders.isEmpty ? "写真フォルダーを選択してください。" : "写真フォルダー未接続 · 再接続を待機中"
            return
        }
        isScanning = true
        statusMessage = "写真を検索しています…"
        let recursive = appliedSettings.recursive
        let scanner = scanner
        let store = folderStore
        let lease = store.beginScan()
        scanTask = Task { [weak self] in
            let photos = await withTaskGroup(of: [PhotoAsset].self) { group in
                for folder in folders { group.addTask { await scanner(folder, recursive) } }
                var result: [PhotoAsset] = []
                for await items in group { result.append(contentsOf: items) }
                return result
            }
            // Even obsolete scans must release their scope lease after all work ends.
            store.endScan(lease)
            guard let self, !Task.isCancelled, !self.terminated,
                  self.scanGeneration == generation else { return }
            let unique = Dictionary(grouping: photos, by: { $0.url.standardizedFileURL })
            let updated = unique.compactMap(\.value.first).sorted { $0.url.path < $1.url.path }
            self.photoAssets = updated
            self.isScanning = false
            self.scanTask = nil
            if self.desiredRunning, self.wallAttached {
                self.playback.updateLibrary(assets: updated)
            }
            self.reconcilePlayback()
        }
    }

    private func reconcilePlayback() {
        guard !terminated, !isScanning else { return }
        guard desiredRunning else {
            statusMessage = "停止中 · \(photoAssets.count)枚"
            return
        }
        guard let screen = screens.first(where: { $0.id == appliedScreenID }) else {
            suspendWall()
            statusMessage = "対象ディスプレイ未接続 · 再接続を待機中"
            return
        }
        guard !photoAssets.isEmpty else {
            if wallAttached { playback.updateLibrary(assets: [], retryFailed: false) }
            statusMessage = "画像がありません · 写真の追加を待機中"
            return
        }
        let viewport = CGSize(width: screen.pixelWidth, height: screen.pixelHeight)
        if !wallAttached || playback.viewport != viewport {
            playback.start(assets: photoAssets, settings: appliedSettings, viewport: viewport)
            guard playback.currentScene != nil else {
                suspendWall()
                statusMessage = "適した写真・有効なモードがありません。"
                return
            }
        }
        playback.setPaused(userPaused || sleeping || covered)
        host.show(on: screen, playback: playback)
        wallAttached = true
        updatePlayingStatus()
    }

    private func suspendWall() {
        host.close()
        playback.stop()
        wallAttached = false
    }

    private func updatePlayingStatus() {
        guard wallAttached else { return }
        if playback.isWaiting {
            statusMessage = playback.imageFailureMessage ?? "画像の準備を待機中"
            return
        }
        statusMessage = userPaused ? "一時停止中" : sleeping ? "スリープ中" : covered ? "画面遮蔽で休止中" : "再生中 · \(photoAssets.count)枚"
    }

    private func syncFolders() {
        folders = folderStore.folders
        folderWarning = folderStore.warning
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
        playback.setPaused(userPaused || sleeping || covered)
        updatePlayingStatus()
    }

    private func checkOcclusion() {
        let screen = screens.first { $0.id == appliedScreenID }
        updateOcclusion(screen.map(WindowOcclusion.isCovered) ?? false)
    }

    private func observeSystemEnvironment() {
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.refreshScreens() }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { $0.checkOcclusion() }
        observe(workspace, NSWorkspace.willSleepNotification) {
            $0.sleeping = true; $0.playback.setPaused(true); $0.updatePlayingStatus()
        }
        observe(workspace, NSWorkspace.didWakeNotification) {
            $0.sleeping = false; $0.refreshScreens(); $0.checkOcclusion(); $0.playback.setPaused($0.userPaused || $0.covered)
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
        healthTask?.cancel()
        reconciliationTask?.cancel()
        watcher?.stop()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        suspendWall()
        folderStore.shutdown()
    }
}
