import AppKit
import SwiftUI
import Darwin

// Compiled by rendering-benchmark.py in isolation from the normal app entrypoint.
// No settings, photos, network connection, login item, or single-instance lock.
@MainActor enum BenchmarkStats {
    static var draws = 0, generations = 0
    static var drawMS: [Double] = []
    static func reset() { draws = 0; generations = 0; drawMS = [] }
}

@main struct RenderingBenchmark {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
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
            guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return fallback }; return args[i + 1]
        }
        let scenario = value("--scenario", "local-gallery")
        let seconds = Double(value("--seconds", "30"))!
        let warmup = Double(value("--warmup", "5"))!
        let output = value("--output", "/private/tmp/dpw-benchmark.json")
        let viewport = CGSize(width: 1920, height: 1080)
        let frame = CGRect(x: 40, y: 40, width: 960, height: 540)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Dynamic Photo Wall — isolated rendering measurement"
        window.isReleasedWhenClosed = false
        let image = scenario.contains("zoom") ? fixture(width: 3600, height: 2400) : fixture()
        let store = PhotoImageStore(decode: { _ in DecodedPhoto(image: image) })
        let assets = (0..<4).map { PhotoAsset(url: URL(filePath: "/synthetic/photo-\($0)"), pixelWidth: scenario.contains("zoom") ? 3600 : 2400, pixelHeight: scenario.contains("zoom") ? 2400 : 3600) }
        _ = await store.prepare(assets)
        var settings = WallSettings(); settings.randomOrder = false
        settings.galleryMinSeconds = 3600; settings.galleryMaxSeconds = 3600
        settings.glassBackground = !scenario.hasSuffix("-off")
        settings.zoomSeconds = 120; settings.panPixelsPerSecond = 40
        let playback = WallPlaybackController(imageStore: store)
        var render: (@MainActor (Double) -> Void)?
        if scenario.hasPrefix("local-") {
            let mode: WallMode = scenario.contains("zoom") ? .zoom : scenario.contains("pan") ? .verticalPan : scenario.contains("scroll") ? .horizontalGallery : .gallery
            let scene = WallScene(id: 1, mode: mode, assets: mode == .gallery || mode == .horizontalGallery ? assets : [assets[0]])
            playback.start(assets: assets, settings: settings, viewport: viewport, scene: scene, externallyManaged: true)
            window.contentViewController = NSHostingController(rootView: DesktopWallView(playback: playback))
            if scenario.contains("paused") { playback.setPaused(true) }
        } else {
            let key = PNAssetKey(providerId: UUID(), sourceId: UUID(), generationId: UUID(), imageId: String(repeating: "a", count: 64))
            let display = PNDisplay(key: PNDisplayKey(peerId: key.providerId, displayId: "1"), selected: true, groupId: nil, x: 0, y: 0, width: 1920, height: 1080, name: "Fixture")
            let motion = scenario.contains("zoom")
            let placements = (0..<64).map { i in
                PNPlacement(id: i, asset: key, displayId: nil, clip: PNRect(x: 0, y: 0, width: 1920, height: 1080),
                    width: i < 4 ? 480 : 1920, height: 1080, fromX: Double(i % 4) * 480, fromY: 0,
                    toX: Double(i % 4) * 480, toY: 0, fromScale: 1, toScale: motion ? 1.25 : 1,
                    centerX: 0.5, centerY: 0.5, startSeconds: 0, motionSeconds: 120,
                    visibleFrom: i < 4 ? 0 : 1000, visibleUntil: 3600, fadeSeconds: 0, cornerRadius: 8, ease: true)
            }
            let plan = PNScene(id: UUID(), groupId: UUID(), sessionId: UUID(), settingsRevision: 1, mode: motion ? "zoom" : "gallery",
                viewport: PNSize(width: 1920, height: 1080), displays: [display], duration: 3600, fadeSeconds: 0,
                background: "#101116", placements: placements, ambient: [])
            let tiny = fixture(width: 160, height: 90)
            let ambient = PNPlayback.PNAmbientImage(frame: PNAmbient(at: 0, png: PNImageDecode.png(tiny)!, displayId: nil),
                image: NSImage(cgImage: tiny, size: CGSize(width: 160, height: 90)))
            let prepared = PNPlayback.Frame(plan: plan, images: [key.opaqueId: DecodedPhoto(image: image)], ambient: [ambient])
            let view = PNSceneView(); view.wantsLayer = true
            window.contentView = view
            render = { elapsed in
                view.layers = [PNPlaybackLayer(frame: prepared, display: display, elapsed: scenario.contains("paused") ? 10 : elapsed, opacity: 1)]
                view.needsDisplay = true
            }
        }
        window.orderFrontRegardless()
        let started = ProcessInfo.processInfo.systemUptime
        var measuredAt: Double?, initialCPU = 0.0, intervals: [Double] = [], lastTick: Double?, ticks = 0
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if measuredAt == nil && now - started >= warmup {
                BenchmarkStats.reset(); initialCPU = cpuSeconds(); measuredAt = now
            }
            if let measuredAt {
                if now - measuredAt >= seconds { break }
                if let lastTick { intervals.append((now - lastTick) * 1000) }; lastTick = now; ticks += 1
            }
            render?(now - started)
            try await Task.sleep(for: .milliseconds(16))
        }
        let wall = ProcessInfo.processInfo.systemUptime - measuredAt!
        let cpu = cpuSeconds() - initialCPU
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        func quantile(_ values: [Double], _ fraction: Double) -> Double {
            let sorted = values.sorted(); return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
        }
        let result: [String: Any] = ["scenario": scenario, "wall_seconds": wall, "cpu_seconds": cpu, "average_cpu_percent": cpu / wall * 100,
            "draws": BenchmarkStats.draws, "generations": BenchmarkStats.generations, "driver_ticks": ticks,
            "draw_ms_p50": quantile(BenchmarkStats.drawMS, 0.5), "draw_ms_p95": quantile(BenchmarkStats.drawMS, 0.95),
            "driver_interval_ms_p50": quantile(intervals, 0.5), "driver_interval_ms_p95": quantile(intervals, 0.95),
            "max_rss_mib": Double(usage.ru_maxrss) / 1048576, "window_width": 960, "window_height": 540,
            "viewport_width": 1920, "viewport_height": 1080, "warmup_seconds": warmup]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(filePath: output))
        playback.stop(); window.close()
        print("\(scenario): CPU \(String(format: "%.2f", cpu / wall * 100))%, draws \(BenchmarkStats.draws), ambient \(BenchmarkStats.generations)")
    }

    nonisolated static func cpuSeconds() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    nonisolated static func fixture(width: Int = 2400, height: Int = 3600) -> CGImage {
        let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in stride(from: 0, to: height, by: 20) {
            canvas.setFillColor(CGColor(red: CGFloat(y) / CGFloat(height), green: 0.4, blue: 1 - CGFloat(y) / CGFloat(height), alpha: 1))
            canvas.fill(CGRect(x: 0, y: y, width: width, height: 20))
        }
        return canvas.makeImage()!
    }
}
