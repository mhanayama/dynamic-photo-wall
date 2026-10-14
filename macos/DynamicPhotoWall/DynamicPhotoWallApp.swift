import AppKit
import SwiftUI

@main
struct DynamicPhotoWallApp: App {
    @State private var model = AppModel.makeLaunchModel()

    var body: some Scene {
        Window("Dynamic Photo Wall", id: "settings") {
            ContentView(model: model)
        }
        .defaultSize(width: 680, height: 430)

        MenuBarExtra("Dynamic Photo Wall", systemImage: "photo.on.rectangle.angled") {
            MenuBarControls(model: model)
        }
    }
}

private struct MenuBarControls: View {
    @Environment(\.openWindow) private var openWindow

    let model: AppModel

    var body: some View {
        Text(model.displayStatusMessage)

        Divider()

        if model.desiredRunning {
            if model.isWaiting {
                Button("再検索して再試行", action: model.retryPlayback)
                    .disabled(model.isScanning)
            } else {
                Button(model.userPaused ? "再開" : "一時停止", action: model.togglePause)
                Button("次の構成", action: model.showNextScene)
                    .disabled(!model.canAdvance)
            }
            Button("停止", action: model.stop)
        } else {
            Button("表示開始", action: model.start)
                .disabled(!model.canStart)
        }

        Button("設定ウィンドウを表示") {
            openWindow(id: "settings")
            NSApplication.shared.activate()
        }

        Divider()

        Button("終了") {
            model.shutdown()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
