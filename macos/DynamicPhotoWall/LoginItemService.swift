import ServiceManagement

@MainActor
struct LoginItemService {
    var status: () -> String
    var setEnabled: (Bool) throws -> Void

    static var system: Self {
        Self(status: {
            switch SMAppService.mainApp.status {
            case .enabled: "ログイン項目に登録済み"
            case .requiresApproval: "システム設定のログイン項目で許可してください。"
            case .notRegistered: "ログイン項目は未登録"
            case .notFound: "アプリをApplicationsへ移動してから登録してください。"
            @unknown default: "ログイン項目の状態を確認できません。"
            }
        }, setEnabled: { enabled in
            let service = SMAppService.mainApp
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval { try service.unregister() }
        })
    }

    static var isolated: Self { Self(status: { "テスト用ログイン項目（OSへの登録なし）" }, setEnabled: { _ in }) }
    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
