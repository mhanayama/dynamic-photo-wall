import AppKit
import SwiftUI

@MainActor
final class DesktopWindowController {
    private var window: NSWindow?
    private var screen: ScreenDescriptor?
    private var photoAssets: [PhotoAsset] = []
    private var settings = WallSettings()
    private var sceneIndex = 0

    func show(on screen: ScreenDescriptor, photoAssets: [PhotoAsset], settings: WallSettings) {
        close()
        self.screen = screen
        self.photoAssets = photoAssets
        self.settings = settings
        sceneIndex = 0
        showCurrentScene()
    }

    func showNextScene() {
        guard window != nil else {
            return
        }
        sceneIndex += 1
        showCurrentScene()
    }

    private func showCurrentScene() {
        guard let screen else {
            return
        }

        let wallWindow = window ?? NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        wallWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        wallWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        wallWindow.backgroundColor = .black
        wallWindow.isOpaque = true
        wallWindow.hasShadow = false
        wallWindow.ignoresMouseEvents = true
        wallWindow.isReleasedWhenClosed = false
        wallWindow.contentViewController = NSHostingController(
            rootView: DesktopWallView(
                photoAssets: photoAssets,
                initialSceneIndex: sceneIndex,
                settings: settings
            )
        )
        wallWindow.setFrame(screen.frame, display: true)
        wallWindow.orderFrontRegardless()
        window = wallWindow
    }

    func close() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        screen = nil
        photoAssets = []
        settings = WallSettings()
        sceneIndex = 0
    }
}
