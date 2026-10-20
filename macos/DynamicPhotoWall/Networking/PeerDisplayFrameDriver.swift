import AppKit
import QuartzCore

@MainActor protocol PNFrameDriving: AnyObject {
    func start(screens: [UInt32], render: @escaping @MainActor () -> Void)
    func stop()
}

/// Pace presentation from the selected output, rather than sleeping after the
/// previous render. Playback still evaluates the shared clock at every tick.
@MainActor final class PNDisplayFrameDriver: NSObject, PNFrameDriving {
    @MainActor private final class Target: NSObject {
        weak var owner: PNDisplayFrameDriver?
        @objc func frame(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.render?()
        }
    }
    private let target = Target()
    private var link: CADisplayLink?
    private var screenID: UInt32?
    private var requestedScreens: [UInt32] = []
    private var render: (@MainActor () -> Void)?
    private var observing = false

    override init() { super.init(); target.owner = self }

    func start(screens: [UInt32], render: @escaping @MainActor () -> Void) {
        requestedScreens = screens; self.render = render
        if !observing {
            NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)),
                name: NSApplication.didChangeScreenParametersNotification, object: nil)
            observing = true
        }
        bindScreen()
    }

    @objc private func screensChanged(_ notification: Notification) { bindScreen() }

    private func bindScreen() {
        func id(_ screen: NSScreen) -> UInt32? {
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        let available = NSScreen.screens
        let screen = requestedScreens.lazy.compactMap { wanted in available.first { id($0) == wanted } }.first
            ?? NSScreen.main ?? available.first
        guard let screen else {
            link?.invalidate(); link = nil; screenID = nil
            return // The screen-change notification restarts presentation.
        }
        let nextID = id(screen)
        if link != nil && screenID == nextID { return }
        link?.invalidate()
        let next = screen.displayLink(target: target, selector: #selector(Target.frame(_:)))
        screenID = nextID; link = next
        next.add(to: .main, forMode: .common)
    }

    func stop() {
        link?.invalidate(); link = nil; screenID = nil; render = nil
        if observing { NotificationCenter.default.removeObserver(self); observing = false }
    }
}
