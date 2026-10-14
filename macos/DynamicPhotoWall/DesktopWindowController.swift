import AppKit
import SwiftUI

@MainActor
protocol DesktopWallHosting: AnyObject {
    func show(on screen: ScreenDescriptor, playback: WallPlaybackController)
    func close()
}

@MainActor
final class DesktopWindowController: DesktopWallHosting {
    private var window: NSWindow?
    private var playback: WallPlaybackController?

    func show(on screen: ScreenDescriptor, playback: WallPlaybackController) {
        let wallWindow = window ?? NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                                            backing: .buffered, defer: false)
        wallWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        wallWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        wallWindow.backgroundColor = .black
        wallWindow.isOpaque = true
        wallWindow.hasShadow = false
        wallWindow.ignoresMouseEvents = true
        wallWindow.isReleasedWhenClosed = false
        if self.playback !== playback || wallWindow.contentViewController == nil {
            wallWindow.contentViewController = NSHostingController(rootView: DesktopWallView(playback: playback))
            self.playback = playback
        }
        wallWindow.setFrame(screen.frame, display: true)
        wallWindow.orderFrontRegardless()
        window = wallWindow
    }

    func close() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        playback = nil
    }
}
