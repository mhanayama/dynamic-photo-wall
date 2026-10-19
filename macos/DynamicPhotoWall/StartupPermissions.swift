import AppKit
import Network
import Observation
import Photos
import Security
import SwiftUI
import UserNotifications

nonisolated enum WallPermission: String, CaseIterable, Identifiable {
    case photos, notifications, localNetwork, folders
    var id: String { rawValue }
    var title: String {
        switch self {
        case .photos: "写真ライブラリ"
        case .notifications: "接続・切断の通知"
        case .localNetwork: "ローカルネットワーク"
        case .folders: "登録済みの写真フォルダー"
        }
    }
    var purpose: String {
        switch self {
        case .photos: "写真アプリのアルバムと原写真を読み込みます。"
        case .notifications: "LAN同期の切断と再接続を知らせます。通知なしでも利用できます。"
        case .localNetwork: "近くのPhoto Wallを検出して同期します。確認だけではオンラインモードを開始しません。"
        case .folders: "アクセスできない登録先を選び直します。外付けドライブも接続してください。"
        }
    }
    var settingsURL: URL? {
        let pane: String
        switch self {
        case .photos: pane = "com.apple.preference.security?Privacy_Photos"
        case .localNetwork: pane = "com.apple.preference.security?Privacy_LocalNetwork"
        case .notifications: pane = "com.apple.Notifications-Settings.extension"
        default: return nil
        }
        return URL(string: "x-apple.systempreferences:\(pane)")
    }
}

nonisolated enum WallPermissionStatus: Equatable {
    case notDetermined, granted, limited, denied, restricted, unavailable(String)
    var satisfied: Bool { self == .granted || self == .limited }
    var label: String {
        switch self {
        case .notDetermined: "未確認"
        case .granted: "利用可能"
        case .limited: "選択した写真のみ利用可能"
        case .denied: "許可が必要"
        case .restricted: "制限されています"
        case .unavailable(let reason): reason
        }
    }
}

@MainActor struct WallPermissionClient {
    var check: (WallPermission) async -> WallPermissionStatus
    var request: (WallPermission) async -> WallPermissionStatus
    var cancel: () -> Void = {}
}

@MainActor @Observable final class StartupPermissions {
    private(set) var statuses: [WallPermission: WallPermissionStatus] = [:]
    private(set) var checking = false
    private(set) var requesting: WallPermission?
    var presented = false
    @ObservationIgnored private let client: WallPermissionClient
    @ObservationIgnored private var generation = UUID()
    var busy: Bool { checking || requesting != nil }
    var missing: [WallPermission] { WallPermission.allCases.filter { statuses[$0]?.satisfied != true } }
    init(client: WallPermissionClient) { self.client = client }

    func check(presentIfNeeded: Bool = false, forceNetwork: Bool = false) async {
        guard !busy else { return }
        checking = true
        let token = generation
        defer { checking = false }
        for permission in WallPermission.allCases {
            let status = await client.check(permission)
            guard token == generation, !Task.isCancelled else { return }
            statuses[permission] = permission == .localNetwork && forceNetwork ? .notDetermined : status
        }
        if presentIfNeeded && !missing.isEmpty { presented = true }
    }
    func requestMissing() async {
        guard !busy else { return }
        let token = generation
        // Network comes last: its privacy API may wait for connectivity or a
        // response to the OS dialog. Never stack a second OS request above it.
        let order: [WallPermission] = [.photos, .notifications, .folders, .localNetwork]
        for permission in order where statuses[permission]?.satisfied != true {
            guard token == generation, !Task.isCancelled else { break }
            requesting = permission
            await Task.yield()
            guard token == generation, !Task.isCancelled else { requesting = nil; return }
            let status = await client.request(permission)
            guard token == generation, !Task.isCancelled else { requesting = nil; return }
            statuses[permission] = status
        }
        requesting = nil
    }
    func cancel() { generation = UUID(); client.cancel(); presented = false }
}

@MainActor final class LocalNetworkPermissionProbe {
    private var browser: NWBrowser?
    private var completion: CheckedContinuation<WallPermissionStatus, Never>?
    private var timeout: Task<Void, Never>?
    private var ready: Task<Void, Never>?
    private var generation = UUID()
    func request() async -> WallPermissionStatus {
        cancel()
        let token = UUID(); generation = token
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion = continuation
                let browser = NWBrowser(for: .bonjour(type: "_photowall._tcp", domain: "local."), using: .tcp)
                self.browser = browser
                browser.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard self?.generation == token else { return }
                        self?.changed(state)
                    }
                }
                browser.start(queue: .main)
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    self?.finish(.unavailable("確認できません。許可とLAN接続を確認して再試行してください。"))
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    private func changed(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            ready?.cancel()
            ready = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                self?.finish(.granted)
            }
        case .waiting(let error), .failed(let error):
            ready?.cancel(); ready = nil
            if case .dns(-65570) = error {
                // PolicyDenied also occurs while the first consent alert is
                // open. Keep the browser alive so granting can make it ready.
                return
            }
            if case .failed = state { finish(.unavailable("ネットワークを確認できません。接続を確認して再試行してください。")) }
        default: break
        }
    }
    private func finish(_ status: WallPermissionStatus) {
        guard let completion else { return }
        self.completion = nil
        browser?.stateUpdateHandler = nil; browser?.cancel(); browser = nil
        timeout?.cancel(); timeout = nil; ready?.cancel(); ready = nil
        completion.resume(returning: status)
    }
    func cancel() { generation = UUID(); finish(.notDetermined) }
}

@MainActor enum SystemWallPermissions {
    static func photos() -> WallPermissionStatus {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: .granted
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unavailable("写真の権限を確認できません。")
        }
    }
    static func requestPhotos() async -> WallPermissionStatus {
        if photos() == .notDetermined { _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        return photos()
    }
    static func notifications() async -> WallPermissionStatus {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unavailable("通知の権限を確認できません。")
        }
    }
    static var buildIdentity: String? {
        var code: SecCode?, staticCode: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let data = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}

extension WallPermissionClient {
    static func system(defaults: UserDefaults, folders: @escaping () -> WallPermissionStatus,
                       requestFolders: @escaping () -> WallPermissionStatus) -> Self {
        let probe = LocalNetworkPermissionProbe()
        let proofKey = "localNetworkPermission.checkedCodeIdentity"
        let identity = SystemWallPermissions.buildIdentity
        return Self(check: { permission in
            switch permission {
            case .photos: return SystemWallPermissions.photos()
            case .notifications: return await SystemWallPermissions.notifications()
            case .folders: return folders()
            case .localNetwork:
                // Previous consent to the setup flow allows a fresh operation
                // for this exact executable. Never treat a saved flag as the
                // current OS privilege; a revoked grant must be detected again.
                guard identity != nil && defaults.string(forKey: proofKey) == identity else { return .notDetermined }
                return await probe.request()
            }
        }, request: { permission in
            switch permission {
            case .photos: return await SystemWallPermissions.requestPhotos()
            case .folders: return requestFolders()
            case .notifications:
                if await SystemWallPermissions.notifications() == .notDetermined {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                }
                return await SystemWallPermissions.notifications()
            case .localNetwork:
                let status = await probe.request()
                if status == .granted, let identity { defaults.set(identity, forKey: proofKey) }
                else { defaults.removeObject(forKey: proofKey) }
                return status
            }
        }, cancel: { probe.cancel() })
    }
}

struct StartupPermissionsView: View {
    @Bindable var permissions: StartupPermissions
    let completed: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("アクセス権限の確認").font(.title2).bold()
            Text("アプリの更新後は再許可が必要になる場合があります。不足している項目を順に確認します。macOSの確認では、それぞれ許可を選んでください。")
                .foregroundStyle(.secondary)
            ForEach(WallPermission.allCases) { permission in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(permission.title).bold()
                        Text(permission.purpose).font(.caption).foregroundStyle(.secondary)
                        Text(permissions.requesting == permission ? "確認中…" : permissions.statuses[permission]?.label ?? "確認中…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if permissions.statuses[permission]?.satisfied != true,
                       let url = permission.settingsURL {
                        Button("システム設定") { NSWorkspace.shared.open(url) }.disabled(permissions.busy)
                    }
                }
            }
            if permissions.requesting == .localNetwork {
                Text("OSの確認が出ている場合は応答してください。拒否済みの場合やLAN未接続の場合は、確認に最大30秒かかります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(permissions.busy ? "中止" : "あとで") { permissions.cancel(); completed() }
                Button("状態を再確認") { Task { await permissions.check(forceNetwork: true) } }.disabled(permissions.busy)
                Spacer()
                if permissions.missing.isEmpty {
                    Button("完了") { permissions.presented = false; completed() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("不足している権限を取得") { Task { await permissions.requestMissing(); completed() } }
                        .disabled(permissions.busy).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24).frame(width: 640)
        .interactiveDismissDisabled(permissions.busy)
    }
}
