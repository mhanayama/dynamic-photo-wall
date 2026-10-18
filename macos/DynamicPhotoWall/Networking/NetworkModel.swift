import AppKit
import Observation
import SwiftUI
import UserNotifications

@MainActor final class PNSystemNotifications: NSObject, PNNotifications, UNUserNotificationCenterDelegate {
    func disconnected(_ name: String) { deliver("Photo Wall の接続が切れました", "\(name) へ再接続しています。") }
    func reconnected(_ name: String) { deliver("Photo Wall に再接続しました", "\(name) との表示同期を準備しています。") }
    func install() { UNUserNotificationCenter.current().delegate = self }
    private func deliver(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil), withCompletionHandler: nil)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
}

// Native composition root. Views edit a revisioned draft; networking services
// receive immutable values and never read SwiftUI or AppModel directly.
@MainActor @Observable final class PNNetworkModel {
    let hostName = ProcessInfo.processInfo.hostName
    private(set) var online = false
    private(set) var busy = false
    private(set) var status = "オフライン"
    private(set) var candidates: [PNCandidate] = []
    private(set) var sources: [PNSource] = []
    var draft: PNSnapshot?
    private(set) var dirty = false
    private(set) var connected: Set<UUID> = []
    private(set) var connectedDisplays: Set<PNDisplayKey> = []
    var showDisconnectedDisplays = false
    private(set) var needsNewStorageProfile = false
    @ObservationIgnored private(set) var session: PNPeerSession?
    @ObservationIgnored private var output: PNPlayback?
    @ObservationIgnored private var identity: PNIdentity?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secretStore: (URL) -> any PNSecretStore
    @ObservationIgnored private let usesFileSecrets: Bool
    private var dataRoot: URL { root.appending(path: "local-v2", directoryHint: .isDirectory) }
    @ObservationIgnored private let settings: () -> WallSettings
    @ObservationIgnored private let displayValues: () -> [WallDisplay]
    @ObservationIgnored private let folders: () -> [PhotoFolder]
    @ObservationIgnored private let albums: () -> [PhotoAlbum]
    @ObservationIgnored private let assets: () -> [PhotoAsset]
    @ObservationIgnored private let enter: () -> Void
    @ObservationIgnored private let sharedSettings: (PNOptions) -> Void
    @ObservationIgnored private let leave: () -> Void
    @ObservationIgnored private let playbackState: (Bool, Bool) -> Void
    @ObservationIgnored private let notification = PNSystemNotifications()
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private let viewUpdates = PNViewUpdates()
    private(set) var isDisplaying = false
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var previewVisible = false
    init(defaults: UserDefaults, root: URL = RuntimePaths.root.appending(path: "network"), settings: @escaping () -> WallSettings,
         displays: @escaping () -> [WallDisplay], folders: @escaping () -> [PhotoFolder], albums: @escaping () -> [PhotoAlbum],
         assets: @escaping () -> [PhotoAsset], enter: @escaping () -> Void, sharedSettings: @escaping (PNOptions) -> Void,
         leave: @escaping () -> Void = {}, playbackState: @escaping (Bool, Bool) -> Void = { _, _ in },
         secretStore: ((URL) -> any PNSecretStore)? = nil) {
        self.defaults = defaults; self.root = root; self.settings = settings; displayValues = displays; self.folders = folders
        self.albums = albums; self.assets = assets; self.enter = enter; self.sharedSettings = sharedSettings
        self.leave = leave; self.playbackState = playbackState
        usesFileSecrets = secretStore == nil
        self.secretStore = secretStore ?? { PNFileSecrets(directory: $0.appending(path: "credentials", directoryHint: .isDirectory)) }
    }
    func restore() { if defaults.bool(forKey: "networkOnline") { Task { await setOnline(true) } } }
    func prepareStorage(createNewProfile: Bool = false) throws {
        if identity != nil { return }
        if usesFileSecrets, !FileManager.default.fileExists(atPath: dataRoot.appending(path: "credentials/identity-v1").path) {
            let fm = FileManager.default
            if ["cache", "wall.encrypted", "credentials/trusted-peers-v1"].contains(where: { fm.fileExists(atPath: dataRoot.appending(path: $0).path) }) {
                throw PNLocalStorageError.missingIdentity
            }
            if !createNewProfile, ["cache", "wall.encrypted"].contains(where: { fm.fileExists(atPath: root.appending(path: $0).path) }) {
                needsNewStorageProfile = true
                throw PNLocalStorageError.previousProfile
            }
        }
        identity = try PNIdentity(secrets: secretStore(dataRoot))
        needsNewStorageProfile = false
    }
    func createLocalProfile() {
        guard needsNewStorageProfile, !busy, !online else { return }
        do {
            try prepareStorage(createNewProfile: true)
            defaults.set(false, forKey: "networkOnline")
            status = "新しい通信設定を作成しました。オンラインモードを有効にして他の端末と接続し直してください。"
        } catch { status = error.localizedDescription }
    }
    func setOnline(_ enabled: Bool) async {
        guard enabled != online && !busy else { return }; busy = true; defer { busy = false }
        if !enabled { session?.stop(); session = nil; output = nil; online = false; isDisplaying = false; isRunning = false; isPaused = false; previewVisible = false; clearSessionViewState(); status = "オフライン"; defaults.set(false, forKey: "networkOnline"); leave(); return }
        do {
            try prepareStorage()
            guard let identity else { throw PNLocalStorageError.inaccessible }
            let hello = PNHello(peerId: identity.peerId, name: hostName)
            let localSettings = settings(); let values = displayValues()
            let groups = Set(values.compactMap(\.groupID)).sorted().map { PNGroup(id: PNWire.id("\(identity.peerId.pnHex):\($0)"), name: $0) }
            let displays = values.map { d in PNDisplay(key: PNDisplayKey(peerId: identity.peerId, displayId: String(d.id)), selected: d.enabled,
                groupId: groups.first(where: { $0.name == d.groupID })?.id,
                x: Int(d.x), y: Int(d.y), width: Int(d.width), height: Int(d.height), name: d.name) }
            let initial = PNSnapshot(wallId: UUID(), sessionId: UUID(), leaderId: identity.peerId, revision: 0, groups: groups, displays: displays, sources: [], playback: PNOptions(localSettings))
            let cache = try PNPhotoCache(root: dataRoot.appending(path: "cache"), key: identity.cacheKey)
            let clock = PNSharedClock(); let planner = PNScenePlanner(cache: cache)
            let output = PNPlayback(local: identity.peerId, clock: clock, cache: cache, budget: { [weak self] in self?.settings().cacheMegabytes ?? 256 }, enter: enter); self.output = output
            let provider = PNSystemPhotoProvider(peerId: identity.peerId, folders: folders, albums: albums, assets: assets,
                cached: { [weak self] key in self?.session?.photos.available[key.opaqueId] != nil })
            let present = Set(ScreenDescriptor.availableScreens().map { String($0.id) })
            let session = try PNPeerSession(local: hello, displays: displays.filter { present.contains($0.key.displayId) }, transport: PNTLSTransport(local: hello, identity: identity), discovery: PNLanDiscovery(),
                persistence: PNStateStore(file: dataRoot.appending(path: "wall.encrypted"), key: identity.cacheKey), provider: provider, cache: cache, planner: planner, output: output, clock: clock, notifications: notification, initial: initial)
            self.session = session; output.bind(planner: planner, photos: session.photos)
            planner.readOriginal = { [weak photos = session.photos] key in try await photos?.readOriginal(key) }
            output.changed = { [weak self] in self?.scheduleRefresh() }; session.changed = { [weak self] in self?.scheduleRefresh() }
            session.failed = { [weak self] error in
                self?.status = error.localizedDescription
                WallLog.write("ネットワーク処理を再試行します。", error: error)
            }
            try await session.start(); online = true; defaults.set(true, forKey: "networkOnline"); notification.install(); refresh()
        } catch {
            session?.stop(); session = nil; output = nil; clearSessionViewState()
            status = error.localizedDescription
        }
    }
    private func clearSessionViewState() {
        viewUpdates.cancel()
        connected = []; connectedDisplays = []; candidates = []; sources = []; draft = nil; dirty = false
    }
    private func scheduleRefresh() { viewUpdates.request { [weak self] in self?.refresh() } }
    private func refresh() {
        guard let session else { return }
        refreshing = true; defer { refreshing = false }
        connected = session.connectedPeers; candidates = session.candidates.values.filter { !connected.contains($0.id) }.sorted { $0.hello.name < $1.hello.name }
        connectedDisplays = session.connectedDisplays
        isDisplaying = output?.isDisplaying == true; isRunning = output?.isRunning == true
        isPaused = connected.isEmpty ? output?.isPaused == true : session.playbackPaused; previewVisible = output?.previewVisible == true
        if isDisplaying { playbackState(connected.isEmpty ? output?.isStopped == true : session.playbackStopped, isPaused) }
        sources = session.sources
        for selection in session.snapshot.sources where !sources.contains(where: { $0.providerId == selection.providerId && $0.sourceId == selection.sourceId }) {
            sources.append(PNSource(providerId: selection.providerId, sourceId: selection.sourceId, name: "未接続の写真ソース"))
        }
        if !dirty && draft != session.snapshot { draft = session.snapshot; sharedSettings(session.snapshot.playback) }
        if dirty, var value = draft {
            for index in value.displays.indices {
                if let current = session.snapshot.displays.first(where: { $0.key == value.displays[index].key }) { value.displays[index].name = current.name }
            }
            if draft != value { draft = value }
        }
        status = connected.isEmpty ? "接続待機中" : "\(connected.count + 1)ピア接続 · \(session.photos.available.count)枚準備済み · \(session.playbackState.rawValue)"
        if session.photos.deferredCount > 0 { status += " · 容量上限で\(session.photos.deferredCount)枚待機" }
    }
    func peerName(_ peerId: UUID) -> String { session?.peerName(peerId) ?? "未接続の端末" }
    func isDisplayConnected(_ key: PNDisplayKey) -> Bool { connectedDisplays.contains(key) }
    nonisolated static func visibleDisplays(_ displays: [PNDisplay], connected: Set<PNDisplayKey>, showDisconnected: Bool) -> [PNDisplay] {
        displays.filter { showDisconnected || connected.contains($0.key) }
    }
    func visibleDisplays(in snapshot: PNSnapshot) -> [PNDisplay] {
        Self.visibleDisplays(snapshot.displays, connected: connectedDisplays, showDisconnected: showDisconnectedDisplays)
    }
    func markDirty() { if !refreshing && online { dirty = true } }
    func optionsEdited(_ settings: WallSettings) { if let draft, PNOptions(settings) != draft.playback { markDirty() } }
    func reload() { dirty = false; draft = nil; refresh() }
    func displayBinding<T>(_ display: PNDisplay, wallId: UUID, _ path: WritableKeyPath<PNDisplay, T>) -> Binding<T> {
        // SwiftUI can still read an old control after refresh removes its row.
        // Resolve the current value by identity; never retain an array index.
        Binding(get: { [weak self] in
            guard let draft = self?.draft, draft.wallId == wallId,
                  let current = draft.displays.first(where: { $0.key == display.key }) else { return display[keyPath: path] }
            return current[keyPath: path]
        }, set: { [weak self] value in
            guard let self, var draft = self.draft, draft.wallId == wallId,
                  let index = draft.displays.firstIndex(where: { $0.key == display.key }) else { return }
            draft.displays[index][keyPath: path] = value
            self.draft = draft; self.markDirty()
        })
    }
    func addGroup(wallId: UUID) {
        guard var draft, draft.wallId == wallId else { return }
        draft.groups.append(PNGroup(id: UUID(), name: "グループ\(draft.groups.count + 1)"))
        self.draft = draft; markDirty()
    }
    func removeGroup(_ id: UUID, wallId: UUID) {
        guard var draft, draft.wallId == wallId, draft.groups.contains(where: { $0.id == id }) else { return }
        draft.groups.removeAll { $0.id == id }
        for index in draft.displays.indices where draft.displays[index].groupId == id { draft.displays[index].groupId = nil }
        self.draft = draft; markDirty()
    }
    func selectSource(_ source: PNSource, enabled: Bool) {
        guard var value = draft else { return }
        value.sources.removeAll { $0.providerId == source.providerId && $0.sourceId == source.sourceId }
        if enabled { value.sources.append(PNSelection(providerId: source.providerId, sourceId: source.sourceId, generationId: UUID())) }
        let generation = UUID()
        for i in value.sources.indices where value.sources[i].providerId == source.providerId { value.sources[i].generationId = generation }
        draft = value; markDirty()
    }
    func regenerate() {
        guard var value = draft else { return }
        for provider in Set(value.sources.map(\.providerId)) { let generation = UUID(); for i in value.sources.indices where value.sources[i].providerId == provider { value.sources[i].generationId = generation } }
        draft = value; markDirty()
    }
    func apply(_ options: WallSettings) async {
        guard let session, let draft else { return }
        do {
            let result = try await session.propose(PNProposal(requestId: UUID(), expectedRevision: draft.revision, groups: draft.groups, displays: draft.displays, sources: draft.sources, playback: PNOptions(options)))
            if result.accepted { dirty = false; self.draft = nil; refresh() } else { status = result.error ?? "設定を反映できません。" }
        } catch { status = error.localizedDescription }
    }
    func connect(_ peer: PNCandidate) { Task { do { try await session?.connect(peer) } catch { status = error.localizedDescription } } }
    func togglePreview() {
        guard let draft else { return }
        Task { do { try await session?.preview(PNPreviewRequest(enabled: !previewVisible, displays: draft.displays, groups: draft.groups)) } catch { status = error.localizedDescription } }
    }
    func control(_ operation: String) {
        if connected.isEmpty { if let session { output?.control(PNControl(operation: operation, effectiveAt: session.clock.now)) } }
        else { Task { do { try await session?.control(operation) } catch { status = error.localizedDescription } } }
    }
    func refreshPhotos() { session?.refreshPhotos() }
    func stop() { session?.stop(); session = nil; output = nil; identity = nil; online = false; clearSessionViewState() }
}

struct NetworkSettingsView: View {
    @Bindable var network: PNNetworkModel
    var body: some View {
        Form {
            Section("ピア接続") {
                Text("このMac: \(network.hostName)").textSelection(.enabled)
                Toggle("オンラインモード", isOn: Binding(get: { network.online }, set: { enabled in Task { await network.setOnline(enabled) } }))
                    .disabled(network.busy).accessibilityIdentifier("network-online")
                Text(network.status).foregroundStyle(.secondary)
                if network.needsNewStorageProfile {
                    Text("以前の接続情報はKeychainにあるため、この版では読み出しません。新しい通信設定を作成すると、他の端末からは新しい端末として接続し直します。以前の通信設定とキャッシュは残します。写真フォルダーや表示設定は引き継ぎます。")
                        .foregroundStyle(.secondary)
                    Button("新しい通信設定を作成") { network.createLocalProfile() }.disabled(network.busy)
                }
                ForEach(network.candidates) { peer in HStack { Label(peer.hello.name, systemImage: "desktopcomputer"); Spacer(); Button("接続") { network.connect(peer) } } }
            }
            Section("共有する写真ソース") {
                ForEach(network.sources) { source in
                    Toggle("\(source.name)（\(network.peerName(source.providerId))）", isOn: Binding(get: { network.draft?.sources.contains { $0.providerId == source.providerId && $0.sourceId == source.sourceId } == true }, set: { network.selectSource(source, enabled: $0) }))
                }
                Button("選択した写真キャッシュを更新") { network.regenerate() }
                Text("設定の適用後に原寸の写真と顔データを暗号化して転送します。有効期限は14日です。").foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct NetworkDisplaySettingsView: View {
    @Bindable var network: PNNetworkModel
    var layout = true
    var body: some View {
        Form {
            Section("全ピアの画面") {
                Toggle("未接続の画面も表示", isOn: $network.showDisconnectedDisplays)
                Text("未接続の画面の配置・グループ設定は保持されています。").font(.caption).foregroundStyle(.secondary)
                if layout { Button(network.previewVisible ? "テストパターンを停止" : "テストパターンを表示", action: network.togglePreview) }
                if layout { NetworkLayoutPreview(network: network).frame(height: 240) }
                if let snapshot = network.draft {
                    ForEach(network.visibleDisplays(in: snapshot)) { display in
                        HStack {
                            Toggle("\(network.peerName(display.key.peerId)) / \(display.displayName)", isOn: network.displayBinding(display, wallId: snapshot.wallId, \.selected))
                            Text(network.isDisplayConnected(display.key) ? "接続中" : "未接続").font(.caption).foregroundStyle(.secondary)
                            Picker("所属", selection: network.displayBinding(display, wallId: snapshot.wallId, \.groupId)) {
                                Text("単独表示").tag(nil as UUID?)
                                ForEach(snapshot.groups) { Text($0.name).tag(Optional($0.id)) }
                            }.frame(width: 180)
                            if layout {
                                TextField("X", value: network.displayBinding(display, wallId: snapshot.wallId, \.x), format: .number).frame(width: 70)
                                TextField("Y", value: network.displayBinding(display, wallId: snapshot.wallId, \.y), format: .number).frame(width: 70)
                            }
                        }
                    }
                    if layout {
                        Button("グループを追加") { network.addGroup(wallId: snapshot.wallId) }
                        ForEach(snapshot.groups) { group in HStack {
                            Text(group.name); Button("削除", role: .destructive) {
                                network.removeGroup(group.id, wallId: snapshot.wallId)
                            }
                        } }
                    }
                }
                Button("最新版を読み直す", action: network.reload)
                Text(network.status).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct NetworkLayoutPreview: View {
    @Bindable var network: PNNetworkModel
    @State private var start: (wallId: UUID, id: String, x: Int, y: Int, left: Int, top: Int, scale: Double)?
    var body: some View {
        GeometryReader { proxy in
            let snapshot = network.draft
            let displays = snapshot.map { network.visibleDisplays(in: $0).filter(\.selected) } ?? []
            let left = start?.left ?? displays.map(\.x).min() ?? 0, top = start?.top ?? displays.map(\.y).min() ?? 0
            let width = max(1, (displays.map { $0.x + $0.width }.max() ?? 1) - left)
            let height = max(1, (displays.map { $0.y + $0.height }.max() ?? 1) - top)
            let scale = start?.scale ?? max(0.001, min((proxy.size.width - 24) / Double(width), (proxy.size.height - 24) / Double(height)))
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.15)
                ForEach(displays) { display in
                    Text("\(network.peerName(display.key.peerId)) / \(display.displayName)\(network.isDisplayConnected(display.key) ? "" : "（未接続）")").font(.caption)
                        .frame(width: max(20, Double(display.width) * scale), height: max(20, Double(display.height) * scale))
                        .background(display.groupId == nil ? Color.gray.opacity(0.5) : Color.blue.opacity(0.5))
                        .opacity(network.isDisplayConnected(display.key) ? 1 : 0.5)
                        .border(.secondary).offset(x: 12 + Double(display.x - left) * scale, y: 12 + Double(display.y - top) * scale)
                        .gesture(DragGesture(coordinateSpace: .named("networkDisplayLayout")).onChanged { value in
                            if start == nil, let wallId = snapshot?.wallId { start = (wallId, display.id, display.x, display.y, left, top, scale) }
                            guard let origin = start, network.draft?.wallId == origin.wallId,
                                  let index = network.draft?.displays.firstIndex(where: { $0.id == origin.id }) else { return }
                            let moving = CGRect(x: Double(origin.x) + value.translation.width / origin.scale,
                                y: Double(origin.y) + value.translation.height / origin.scale, width: Double(display.width), height: Double(display.height))
                            let others = displays.filter { $0.id != origin.id }.map { CGRect(x: Double($0.x), y: Double($0.y), width: Double($0.width), height: Double($0.height)) }
                            let snapped = DisplayLayout.snapped(moving, against: others, threshold: 12 / origin.scale)
                            network.draft?.displays[index].x = Int(min(100000, max(-100000, snapped.x.rounded())))
                            network.draft?.displays[index].y = Int(min(100000, max(-100000, snapped.y.rounded())))
                            network.markDirty()
                        }.onEnded { _ in start = nil })
                }
            }.coordinateSpace(name: "networkDisplayLayout").clipped()
                .help("ドラッグして隣の画面の端に近づけると、配置が揃います。")
        }
    }
}
