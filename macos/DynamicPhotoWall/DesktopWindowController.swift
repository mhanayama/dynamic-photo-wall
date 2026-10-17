import AppKit
import SwiftUI

@MainActor
struct DesktopWallOutput {
    let screen: ScreenDescriptor
    let display: WallDisplay
    let group: WallDisplayGroup
    let number: Int
    let session: WallGroupPlayback?
}

@MainActor
protocol DesktopWallHosting: AnyObject {
    func show(on screen: ScreenDescriptor, playback: WallPlaybackController)
    func present(_ outputs: [DesktopWallOutput]) throws
    func close()
}

extension DesktopWallHosting {
    // Legacy fake hosts remain isolated; multi-output fakes can inspect present().
    func present(_ outputs: [DesktopWallOutput]) throws {
        for output in outputs {
            if let session = output.session { show(on: output.screen, playback: session.primary) }
        }
    }
}

@MainActor
final class DesktopWindowController: DesktopWallHosting {
    private var lastOutputs: [UInt32: DesktopWallOutput] = [:]
    private var windows: [UInt32: NSWindow] = [:]

    private func makeWindow(on screen: ScreenDescriptor) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.backgroundColor = .black
        window.isOpaque = true; window.hasShadow = false
        window.ignoresMouseEvents = true; window.isReleasedWhenClosed = false
        return window
    }

    func show(on screen: ScreenDescriptor, playback: WallPlaybackController) {
        let window = windows[screen.id] ?? makeWindow(on: screen)
        window.contentViewController = NSHostingController(rootView: DesktopWallView(playback: playback))
        window.setFrame(screen.frame, display: true); window.orderFrontRegardless()
        windows[screen.id] = window
    }

    func present(_ outputs: [DesktopWallOutput]) throws {
        let ids = Set(outputs.map { $0.screen.id })
        for id in windows.keys.filter({ !ids.contains($0) }) { windows.removeValue(forKey: id)?.close(); lastOutputs.removeValue(forKey: id) }
        for output in outputs {
            let window = windows[output.screen.id] ?? makeWindow(on: output.screen)
            let old = lastOutputs[output.screen.id]
            if old?.session !== output.session || old?.display != output.display || old?.group != output.group || old?.number != output.number || window.contentViewController == nil {
                window.contentViewController = NSHostingController(rootView: GroupDesktopWallView(output: output))
            }
            lastOutputs[output.screen.id] = output
            window.setFrame(output.screen.frame, display: true); window.orderFrontRegardless()
            windows[output.screen.id] = window
        }
    }

    func close() {
        for window in windows.values { window.orderOut(nil); window.close() }
        windows.removeAll(); lastOutputs.removeAll()
    }
}

struct GroupDesktopWallView: View {
    let output: DesktopWallOutput
    var body: some View {
        GeometryReader { proxy in
            let local = output.display.rect.size
            ZStack(alignment: .topLeading) {
                if let session = output.session {
                    TimelineView(.animation(paused: (session.paused || session.isWaiting) && !session.waitingForImages)) { context in
                        ZStack(alignment: .topLeading) {
                            if let outgoing = session.outgoing { batch(outgoing, session: session) }
                            if let current = session.current { batch(current, session: session).opacity(session.fade) }
                        }
                        .onChange(of: context.date, initial: true) { session.update() }
                    }
                } else {
                    DisplayTestPattern(output: output)
                }
            }
            .frame(width: local.width, height: local.height, alignment: .topLeading)
            .clipped()
            .scaleEffect(x: proxy.size.width / local.width, y: proxy.size.height / local.height, anchor: .topLeading)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .background(.black)
    }

    @ViewBuilder private func batch(_ batch: WallGroupPlayback.Batch, session: WallGroupPlayback) -> some View {
        ForEach(batch.surfaces.filter { $0.displayID == nil || $0.displayID == output.display.id }) { surface in
            let playback = surface.playback
            let region = surface.displayID == nil ? output.group.region(output.display) : CGRect(origin: .zero, size: output.display.rect.size)
            ZStack {
                ForEach(playback.layers()) { layer in
                    WallSceneLayer(presentation: layer.presentation, settings: playback.settings,
                                   images: playback.imageStore ?? .shared, viewport: playback.viewport,
                                   paused: playback.isPaused, sharedAmbient: surface.ambients[layer.id])
                        .opacity(layer.opacity)
                }
            }
            .frame(width: playback.viewport.width, height: playback.viewport.height)
            .clipped()
            .offset(x: -region.minX, y: -region.minY)
        }
    }
}

struct DisplayTestPattern: View {
    let output: DesktopWallOutput
    var body: some View {
        let region = output.group.region(output.display)
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.08)))
            var grid = Path()
            for x in stride(from: -region.minX.truncatingRemainder(dividingBy: 120), through: size.width, by: 120) {
                grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: -region.minY.truncatingRemainder(dividingBy: 120), through: size.height, by: 120) {
                grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(.cyan.opacity(0.7)), lineWidth: 2)
            let wall = CGRect(x: -region.minX, y: -region.minY, width: output.group.viewport.width, height: output.group.viewport.height)
            var diagonal = Path(); diagonal.move(to: wall.origin); diagonal.addLine(to: CGPoint(x: wall.maxX, y: wall.maxY))
            diagonal.move(to: CGPoint(x: wall.maxX, y: wall.minY)); diagonal.addLine(to: CGPoint(x: wall.minX, y: wall.maxY))
            context.stroke(diagonal, with: .color(.yellow), lineWidth: 5)
            let diameter = min(wall.width, wall.height) * 0.8
            context.stroke(Path(ellipseIn: CGRect(x: wall.midX - diameter / 2, y: wall.midY - diameter / 2, width: diameter, height: diameter)), with: .color(.green), lineWidth: 5)
            context.stroke(Path(CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)), with: .color(.white), lineWidth: 8)
        }
        .overlay {
            VStack(spacing: 20) {
                Text("画面 \(output.number)").font(.system(size: 110, weight: .bold))
                Text(output.display.name).font(.system(size: 38))
                Text(output.group.name).font(.system(size: 42))
                Text("\(Int(region.width)) × \(Int(region.height)) px\nX: \(Int(region.minX))  Y: \(Int(region.minY))").font(.system(size: 32, design: .monospaced))
            }
            .foregroundStyle(.white).padding(40).background(.black.opacity(0.65))
        }
    }
}
