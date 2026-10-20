import AppKit
import QuartzCore
import CryptoKit
import Darwin

// Opt-in diagnostic executable. No app model, user photos/settings, discovery,
// network connections, login items, or desktop-level windows.
@MainActor private final class PacingDriver: PNFrameDriving {
    let mode: String
    let displayDriver = PNDisplayFrameDriver()
    var task: Task<Void, Never>?
    var recording = false
    var rows: [[Double]] = [] // uptime, render milliseconds
    init(_ mode: String) { self.mode = mode }
    func start(screens: [UInt32], render: @escaping @MainActor () -> Void) {
        let measured: @MainActor () -> Void = { [weak self] in
            let start = CACurrentMediaTime()
            render()
            if let self, recording { rows.append([start, (CACurrentMediaTime() - start) * 1000]) }
        }
        if mode == "displaylink" { displayDriver.start(screens: screens, render: measured) }
        else if task == nil {
            // Same ordering and sleep as PNPlayback.startTimer() at b5103a0.
            task = Task { @MainActor in
                while !Task.isCancelled {
                    measured()
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                }
            }
        }
    }
    func stop() { task?.cancel(); task = nil; displayDriver.stop() }
}

@MainActor private final class PacingSurface: PNPlaybackSurface {
    let window: NSWindow
    let view = PNSceneView()
    var revision = 0
    var lastY = 0.0
    var lastElapsed = 0.0
    var isReady: Bool { view.hasDrawn }
    init(screen: NSScreen) {
        let area = screen.visibleFrame
        let width = min(960, area.width), height = min(540, area.height - 40)
        window = NSWindow(contentRect: CGRect(x: area.midX - width / 2, y: area.midY - height / 2,
            width: width, height: height), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Dynamic Photo Wall — isolated frame pacing measurement"
        window.isReleasedWhenClosed = false; window.contentView = view
        window.orderFrontRegardless()
    }
    func present(_ layers: [PNPlaybackLayer], on screen: ScreenDescriptor, visible: Bool) {
        view.layers = layers
        if let layer = layers.last, let card = layer.content?.cards.first {
            lastElapsed = layer.elapsed; lastY = layer.evaluate(card.placement).y
        }
        revision += 1
        if !view.hasDrawn { view.displayIfNeeded() }
    }
    func close() { window.orderOut(nil); window.close() }
}

@MainActor private final class PacingProbe: NSObject {
    let surface: PacingSurface
    var recording = false
    var rows: [[Double]] = [] // callback uptime, timestamp, target, revision, y, scene elapsed
    init(_ surface: PacingSurface) { self.surface = surface }
    @objc func frame(_ link: CADisplayLink) {
        if recording {
            rows.append([CACurrentMediaTime(), link.timestamp, link.targetTimestamp,
                Double(surface.revision), surface.lastY, surface.lastElapsed])
        }
    }
}

@MainActor private final class PacingClock: PNClock {
    var now: Double { CACurrentMediaTime() }
    var elapsed: Double { now }
    func observe(_ pong: PNPong) {}
}
@MainActor private final class PacingProvider: PNPhotoProviding {
    var sources: [PNSource] { [] }
    func read(_ selection: PNSelection) -> AsyncThrowingStream<PNImportedPhoto, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@main struct FramePacingBenchmark {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run() }
            catch { fputs("\(error)\n", stderr); exit(1) }
            app.terminate(nil)
        }
        app.run()
    }
    @MainActor static func run() async throws {
        let args = CommandLine.arguments
        func value(_ flag: String, _ fallback: String) -> String {
            guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return fallback }
            return args[i + 1]
        }
        let mode = value("--driver", "displaylink")
        let seconds = Double(value("--seconds", "20"))!, warmup = Double(value("--warmup", "3"))!
        guard ["legacy", "displaylink"].contains(mode), seconds.isFinite, warmup.isFinite,
              seconds > 0, warmup >= 0 else { throw PNError.invalid("Invalid measurement arguments") }
        let resultURL = URL(filePath: value("--output", "/private/tmp/dpw-frame-pacing.json"))
        func screenID(_ screen: NSScreen) -> UInt32 {
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value
        }
        let screens = NSScreen.screens
        let wanted = UInt32(value("--display", "0"))!
        guard let screen = screens.first(where: { wanted != 0 ? screenID($0) == wanted :
            CGDisplayPixelsWide(screenID($0)) == 1920 && CGDisplayPixelsHigh(screenID($0)) == 1080 })
            ?? (wanted == 0 ? NSScreen.main : nil) else { throw PNError.invalid("No matching screen") }
        let selectedID = screenID(screen), local = UUID(), group = UUID()
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: "DPW.FramePacing.\(UUID())")
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let cache = try PNPhotoCache(root: cacheRoot, key: SymmetricKey(size: .bits256))
        let image = fixture(width: 1920, height: 7200)
        let bytes = PNImageDecode.png(image)!
        let key = PNAssetKey(providerId: local, sourceId: UUID(), generationId: UUID(), imageId: PNWire.digest(bytes))
        let photo = PNPhoto(key: key, pixelWidth: image.width, pixelHeight: image.height, byteLength: bytes.count,
            faceMetadata: PNFaces(pixelWidth: image.width, pixelHeight: image.height, detector: "synthetic", state: "complete", faces: []))
        try await cache.activate(local, key.generationId); try await cache.put(photo, original: bytes)
        let transfers = PNPhotoTransfers(local: local, provider: PacingProvider(), cache: cache)
        try await transfers.configure([PNSelection(providerId: local, sourceId: key.sourceId, generationId: key.generationId)])
        defer { transfers.stop() }
        let display = PNDisplay(key: PNDisplayKey(peerId: local, displayId: String(selectedID)), selected: true,
            groupId: group, x: 0, y: 0, width: 1920, height: 1080, name: "Synthetic")
        // Long constant-speed Pan; no endpoint or preparation work during capture.
        let placement = PNPlacement(id: 0, asset: key, displayId: nil,
            clip: PNRect(x: 0, y: 0, width: 1920, height: 1080), width: 1920, height: 14400,
            fromX: 0, fromY: -13320, toX: 0, toY: 0, fromScale: 1, toScale: 1,
            centerX: 0.5, centerY: 0.5, startSeconds: 0, motionSeconds: 111,
            visibleFrom: 0, visibleUntil: 111, fadeSeconds: 0, cornerRadius: 0, ease: false)
        let plan = PNScene(id: UUID(), groupId: group, sessionId: UUID(), settingsRevision: 1, mode: "verticalPan",
            viewport: PNSize(width: 1920, height: 1080), displays: [display], duration: 111,
            fadeSeconds: 0, background: "#101116", placements: [placement], ambient: [])
        let surface = PacingSurface(screen: screen), driver = PacingDriver(mode), clock = PacingClock()
        let output = PNPlayback(local: local, clock: clock, cache: cache, budget: { 64 }, enter: {},
            makeSurface: { _ in surface }, frameDriver: driver)
        output.bind(planner: PacingPlanner(), photos: transfers)
        defer { output.stop(); surface.close() }
        try await output.prepare(plan)
        let sceneStart = clock.now
        output.commit(PNCommit(planId: plan.id, groupId: group, startAt: sceneStart))
        let probe = PacingProbe(surface)
        let link = screen.displayLink(target: probe, selector: #selector(PacingProbe.frame(_:)))
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        try await Task.sleep(for: .seconds(warmup))
        let started = CACurrentMediaTime(), initialCPU = cpuSeconds()
        driver.recording = true; probe.recording = true
        try await Task.sleep(for: .seconds(seconds))
        driver.recording = false; probe.recording = false
        let wall = CACurrentMediaTime() - started, cpu = cpuSeconds() - initialCPU
        guard driver.rows.count > 10, probe.rows.count > 10 else { throw PNError.invalid("Insufficient display callbacks") }
        let result: [String: Any] = ["driver": mode, "wall_seconds": wall, "warmup_seconds": warmup,
            "cpu_percent": cpu / wall * 100, "measurement_start": started, "scene_start": sceneStart,
            "render_columns": ["uptime", "render_ms"], "render_rows": driver.rows,
            "probe_columns": ["uptime", "timestamp", "target_timestamp", "revision", "y", "scene_elapsed"], "probe_rows": probe.rows,
            "screen_id": selectedID, "screen_pixels": [CGDisplayPixelsWide(selectedID), CGDisplayPixelsHigh(selectedID)],
            "screen_max_fps": screen.maximumFramesPerSecond, "window_points": [surface.view.bounds.width, surface.view.bounds.height],
            "screen_inventory": screens.map { ["id": Int(screenID($0)), "width": CGDisplayPixelsWide(screenID($0)),
                "height": CGDisplayPixelsHigh(screenID($0)), "max_fps": $0.maximumFramesPerSecond] },
            "note": "Display callbacks sample application model state; not hardware presentation or captured pixels. No network load."]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: resultURL)
        print("\(mode): \(driver.rows.count) renders, \(probe.rows.count) display callbacks, CPU \(cpu / wall * 100)%")
    }
    nonisolated static func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    nonisolated static func fixture(width: Int, height: Int) -> CGImage {
        let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in stride(from: 0, to: height, by: 40) {
            let t = CGFloat(y) / CGFloat(height)
            canvas.setFillColor(CGColor(red: t, green: 0.4, blue: 1 - t, alpha: 1))
            canvas.fill(CGRect(x: 0, y: y, width: width, height: 40))
        }
        return canvas.makeImage()!
    }
}
@MainActor private final class PacingPlanner: PNScenePlanning {
    func prepare(wall: PNSnapshot, group: UUID, photos: [PNPhoto]) async throws -> PNScene? { nil }
}
