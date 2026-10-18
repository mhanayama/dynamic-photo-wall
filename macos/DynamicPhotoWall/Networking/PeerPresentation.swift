import AppKit
import SwiftUI

@MainActor struct PNPlaybackLayer {
    let frame: PNPlayback.Frame
    let display: PNDisplay
    let elapsed: Double
    let opacity: Double
    var crop: CGRect {
        CGRect(x: display.x - (frame.plan.displays.map(\.x).min() ?? 0),
            y: display.y - (frame.plan.displays.map(\.y).min() ?? 0), width: display.width, height: display.height)
    }
    func evaluate(_ placement: PNPlacement) -> (x: Double, y: Double, scale: Double, opacity: Double) {
        var value = placement.evaluate(elapsed)
        if placement.fadeSeconds > 0 {
            // Scene opacity owns the first fade. Terminal Gallery photos stay
            // visible while a successor is loading or the peer is disconnected.
            let fadeIn = placement.visibleFrom == 0 ? 1 : min(1, max(0, (elapsed - placement.visibleFrom) / placement.fadeSeconds))
            let fadeOut = placement.visibleUntil == frame.plan.duration ? 1 : min(1, max(0, (placement.visibleUntil - elapsed) / placement.fadeSeconds))
            value.opacity = elapsed < placement.visibleFrom || elapsed >= placement.visibleUntil ? 0 : min(fadeIn, fadeOut)
        }
        return value
    }
}

// Each physical display owns its current composition. Group IDs and remote
// canvas coordinates can change without discarding the display's predecessor.
@MainActor struct PNPresentation {
    struct Held { var frame: PNPlayback.Frame; var opacity: Double }
    var frame: PNPlayback.Frame
    private(set) var previous: [Held] = []
    func age(at time: Double) -> Double { max(0, time - frame.start - frame.paused) }
    private func visible(at time: Double) -> [Held] {
        let opacity = previous.isEmpty || frame.plan.fadeSeconds <= 0 ? 1 : min(1, age(at: time) / frame.plan.fadeSeconds)
        return (opacity >= 1 ? [] : previous) + [Held(frame: frame, opacity: opacity)]
    }
    mutating func replace(with next: PNPlayback.Frame, at time: Double) {
        previous = visible(at: time).filter { $0.opacity > 0 }
        frame = next
    }
    mutating func advance(at time: Double, repeating: Bool) {
        if repeating && age(at: time) >= frame.plan.duration {
            var next = frame; next.start = time; next.paused = 0
            replace(with: next, at: time)
        }
        if age(at: time) >= frame.plan.fadeSeconds { previous.removeAll() }
    }
    mutating func resume(after delay: Double) {
        frame.paused += delay
        for index in previous.indices { previous[index].frame.paused += delay }
    }
    func layers(for key: PNDisplayKey, at time: Double) -> [PNPlaybackLayer] {
        visible(at: time).compactMap { item in
            guard let display = item.frame.plan.displays.first(where: { $0.key == key }) else { return nil }
            let elapsed = min(max(0, time - item.frame.start - item.frame.paused), item.frame.plan.duration - 0.00001)
            return PNPlaybackLayer(frame: item.frame, display: display, elapsed: elapsed, opacity: item.opacity)
        }
    }
}

@MainActor protocol PNPlaybackSurface: AnyObject {
    var isReady: Bool { get }
    func present(_ layers: [PNPlaybackLayer], on screen: ScreenDescriptor, visible: Bool)
    func close()
}

@MainActor final class PNWindowSurface: PNPlaybackSurface {
    private let window: NSWindow
    private let view = PNSceneView()
    var isReady: Bool { view.hasDrawn }
    init(screen: ScreenDescriptor) {
        window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]; window.backgroundColor = .black
        window.isOpaque = true; window.hasShadow = false; window.ignoresMouseEvents = true; window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = view
    }
    func present(_ layers: [PNPlaybackLayer], on screen: ScreenDescriptor, visible: Bool) {
        view.layers = layers
        if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
        view.needsDisplay = true
        // An ordered but transparent window can draw without covering the old
        // host with its empty backing. Reveal it only after actual drawing.
        if visible { window.orderFrontRegardless() }
        if !view.hasDrawn { view.displayIfNeeded() }
        if view.hasDrawn { window.alphaValue = 1 }
    }
    func close() { window.orderOut(nil); window.close() }
}

@MainActor final class PNSceneView: NSView {
    var layers: [PNPlaybackLayer] = []
    private(set) var hasDrawn = false
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard !layers.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.black.setFill(); bounds.fill()
        for layer in layers where layer.opacity > 0 {
            let frame = layer.frame, display = layer.display, elapsed = layer.elapsed
            let plan = frame.plan, crop = layer.crop
            context.saveGState()
            context.scaleBy(x: bounds.width / Double(display.width), y: bounds.height / Double(display.height))
            // Composite one whole scene, so overlapping cards and ambient frames
            // do not each apply the scene fade to the old content independently.
            context.setAlpha(layer.opacity); context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setFillColor(NSColor(Color(hex: plan.background)).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: display.width, height: display.height))
            let ambient = frame.ambient.filter { $0.frame.displayId == display.id || $0.frame.displayId == nil }.sorted { $0.frame.at < $1.frame.at }
            if let a = ambient.last(where: { $0.frame.at <= elapsed }) ?? ambient.first {
                let area = a.frame.displayId == nil ? CGRect(x: -crop.minX, y: -crop.minY, width: plan.viewport.width, height: plan.viewport.height) : CGRect(x: 0, y: 0, width: display.width, height: display.height)
                a.image.draw(in: area, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                if let b = ambient.first(where: { $0.frame.at > elapsed }) {
                    let blend = min(1, max(0, (elapsed - a.frame.at) / max(0.001, b.frame.at - a.frame.at)))
                    b.image.draw(in: area, from: .zero, operation: .sourceOver, fraction: blend, respectFlipped: true, hints: nil)
                }
                context.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
                context.fill(CGRect(x: 0, y: 0, width: display.width, height: display.height))
            }
            context.translateBy(x: -crop.minX, y: -crop.minY)
            for placement in plan.placements where placement.displayId == nil || placement.displayId == display.id {
                guard let image = frame.images[placement.asset.opaqueId]?.image else { continue }
                let value = layer.evaluate(placement)
                if value.opacity <= 0 { continue }
                context.saveGState(); context.clip(to: CGRect(x: placement.clip.x, y: placement.clip.y, width: placement.clip.width, height: placement.clip.height))
                context.setAlpha(value.opacity)
                let rect = CGRect(x: value.x - placement.width * (value.scale - 1) * placement.centerX,
                    y: value.y - placement.height * (value.scale - 1) * placement.centerY,
                    width: placement.width * value.scale, height: placement.height * value.scale)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: placement.cornerRadius, cornerHeight: placement.cornerRadius, transform: nil)); context.clip()
                context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: rect.size)); context.restoreGState()
            }
            context.endTransparencyLayer(); context.restoreGState()
        }
        hasDrawn = true
    }
}
