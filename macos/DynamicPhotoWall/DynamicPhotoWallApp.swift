import AppKit
import CoreServices
import SwiftUI

@main
struct DynamicPhotoWallApp: App {
    @NSApplicationDelegateAdaptor(WallApplicationDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Dynamic Photo Wall", systemImage: "photo.on.rectangle.angled") {
            MenuBarControls(model: delegate.model, openSettings: delegate.showSettings)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("設定…", action: delegate.showSettings).keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class WallApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model: AppModel
    private let instance: SingleInstance
    private let duplicate: Bool

    override init() {
        let environment = ProcessInfo.processInfo.environment
        let testing = environment["DPW_UI_TEST_PROFILE"] != nil || environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestSessionIdentifier"] != nil || NSClassFromString("XCTestCase") != nil
        let instance = SingleInstance()
        let duplicate = !testing && !instance.acquire()
        self.instance = instance
        self.duplicate = duplicate
        if duplicate {
            model = AppModel(defaults: UserDefaults(suiteName: "DynamicPhotoWall.Duplicate.\(UUID())")!,
                             screenProvider: { [] }, observeEnvironment: false)
        } else { model = AppModel.makeLaunchModel() }
        super.init()
    }
    private var settingsWindow: NSWindow?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if duplicate { instance.reopenExisting(); NSApplication.shared.terminate(nil); return }
        let environment = ProcessInfo.processInfo.environment
        let unitHost = environment["DPW_UI_TEST_PROFILE"] == nil &&
            (environment["XCTestConfigurationFilePath"] != nil || environment["XCTestSessionIdentifier"] != nil || NSClassFromString("XCTestCase") != nil)
        if !unitHost {
            let event = NSAppleEventManager.shared().currentAppleEvent
            let loginLaunch = event?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil ||
                event?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsServiceItem)) != nil
            if !loginLaunch || (model.folders.isEmpty && model.photoAlbums.isEmpty) || !model.hasSavedScreen { showSettings() }
        }
    }

    func showSettings() {
        NSApplication.shared.setActivationPolicy(.regular)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1040, height: 800),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Dynamic Photo Wall — 設定"
            window.contentMinSize = CGSize(width: 900, height: 680)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: ContentView(model: model))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    func windowWillClose(_ notification: Notification) {
        model.cancelDraft()
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        model.shutdown()
        Task {
            await PhotoMetadataCache.shared.flush()
            await PhotoFaceAnalyzer.shared.flush()
            await WallLog.flush()
            instance.release()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct MenuBarControls: View {
    let model: AppModel
    let openSettings: () -> Void

    var body: some View {
        Text(model.displayStatusMessage)
        Divider()
        if model.testPatternVisible {
            Button("テスト表示を停止", action: model.toggleTestPattern)
            Button("スライドショー開始", action: model.startApplied).disabled(!model.canStartApplied)
            Button("表示停止", action: model.stop)
        } else if model.desiredRunning {
            if model.isWaiting {
                Button("再検索して再試行", action: model.retryPlayback).disabled(model.isScanning)
            } else {
                Button(model.userPaused ? "再開" : "一時停止", action: model.togglePause)
                Button("次の写真 / 構成", action: model.showNextScene).disabled(!model.canAdvance)
            }
            Button("表示停止", action: model.stop)
        } else {
            Button("スライドショー開始", action: model.startApplied).disabled(!model.canStartApplied)
        }
        Button("設定を開く", action: openSettings)
        Divider()
        Button("終了") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}
