import AppKit
import ImageIO
import SwiftUI

@MainActor final class PNScenePlanner: PNScenePlanning {
    private let cache: PNPhotoCache
    private var planners: [UUID: WallScenePlanner] = [:]
    init(cache: PNPhotoCache) { self.cache = cache }
    func prepare(wall: PNSnapshot, group: UUID, photos: [PNPhoto]) async throws -> PNScene? {
        let displays = wall.displays.filter { $0.selected && $0.unit == group }; guard !displays.isEmpty else { return nil }
        let settings = try wall.playback.applying()
        let left = displays.map(\.x).min()!, top = displays.map(\.y).min()!
        let width = displays.map { Double($0.x) + Double($0.width) }.max()! - Double(left)
        let height = displays.map { Double($0.y) + Double($0.height) }.max()! - Double(top)
        let nativeDisplays = displays.enumerated().map { index, d in WallDisplay(id: UInt32(index + 1), name: d.id, x: Double(d.x), y: Double(d.y), width: Double(d.width), height: Double(d.height), groupID: group.uuidString) }
        let nativeGroup = WallDisplayGroup(id: .named(group.uuidString), displays: nativeDisplays, bounds: CGRect(x: left, y: top, width: Int(width), height: Int(height)))
        let usable = photos.filter { $0.faceMetadata.state != "pending" }
        let assets = usable.map { PhotoAsset(url: URL(string: "peer-cache://image/\($0.key.opaqueId)")!, pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight, fileSize: Int64($0.byteLength), faces: $0.faceMetadata.faces.map { FaceRegion(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }) }
        let byURL = Dictionary(uniqueKeysWithValues: zip(assets.map(\.url), usable))
        let planner = planners[group] ?? WallScenePlanner(); planners[group] = planner
        guard let surfaces = planner.nextGroup(assets: assets, settings: settings, group: nativeGroup, connected: Set(nativeDisplays.map(\.id))), let first = surfaces.first else { return nil }
        var placements: [PNPlacement] = []; var duration = 0.0
        for surface in surfaces {
            try Task.checkCancellation()
            let display = surface.displayID.flatMap { id in displays.indices.contains(Int(id) - 1) ? displays[Int(id) - 1] : nil }
            let ox = Double(display.map { $0.x - left } ?? 0), oy = Double(display.map { $0.y - top } ?? 0)
            let v = surface.viewport; let scene = surface.scene
            var clip = PNRect(x: ox, y: oy, width: v.width, height: v.height)
            func add(_ asset: PhotoAsset, width: Double, height: Double, fromX: Double, fromY: Double, toX: Double, toY: Double,
                     fromScale: Double = 1, toScale: Double = 1, centerX: Double = 0.5, centerY: Double = 0.5,
                     start: Double = 0, motion: Double, visibleFrom: Double = 0, visibleUntil: Double, fade: Double = 0, corner: Double = 0, ease: Bool = false) {
                guard let photo = byURL[asset.url] else { return }
                placements.append(PNPlacement(id: placements.count, asset: photo.key, displayId: display?.id, clip: clip, width: width, height: height,
                    fromX: fromX + ox, fromY: fromY + oy, toX: toX + ox, toY: toY + oy, fromScale: fromScale, toScale: toScale, centerX: centerX, centerY: centerY,
                    startSeconds: start, motionSeconds: motion, visibleFrom: visibleFrom, visibleUntil: visibleUntil, fadeSeconds: fade, cornerRadius: corner, ease: ease))
            }
            let seconds: Double
            switch scene.mode {
            case .gallery:
                seconds = max(90, settings.galleryMaxSeconds * 2)
                let frames = FaceSafeLayout.gallery(scene.assets, viewport: v, gap: settings.gap, displays: settings.avoidFaceDisplayBoundaries ? scene.displayRegions : [])
                for (index, asset) in scene.assets.enumerated() {
                    var at = 0.0; var chosen = asset
                    while at < seconds {
                        let until = min(seconds, at + planner.galleryInterval(settings: settings)); let slot = frames[index]
                        let localRegions = scene.displayRegions.map { $0.offsetBy(dx: -slot.minX, dy: -slot.minY) }
                        let fit = FaceSafeLayout.gallery([chosen], viewport: slot.size, gap: 0, displays: settings.avoidFaceDisplayBoundaries ? localRegions : []).first ?? CGRect(origin: .zero, size: slot.size)
                        add(chosen, width: fit.width, height: fit.height, fromX: slot.minX + fit.minX, fromY: slot.minY + fit.minY, toX: slot.minX + fit.minX, toY: slot.minY + fit.minY, start: at, motion: max(0.1, until - at), visibleFrom: at, visibleUntil: until, fade: settings.fadeSeconds, corner: settings.cornerRadius)
                        if until >= seconds { break }
                        at = max(at + 0.1, until - settings.fadeSeconds)
                        chosen = planner.replacement(assets: assets, settings: settings, excluding: [chosen.url]) ?? chosen
                    }
                }
            case .horizontalGallery:
                seconds = max(120, settings.galleryMaxSeconds * 3)
                let h = max(1, v.height - 2 * settings.gap); var x = settings.gap; var index = 0
                while x < v.width + seconds * settings.galleryScrollPixelsPerSecond && index < 128 {
                    let chosen = index < scene.assets.count ? scene.assets[index] : planner.replacement(assets: assets, settings: settings, excluding: []) ?? scene.assets[0]
                    let w = h * chosen.aspectRatio
                    add(chosen, width: w, height: h, fromX: x, fromY: (v.height - h) / 2, toX: x - seconds * settings.galleryScrollPixelsPerSecond, toY: (v.height - h) / 2, motion: seconds, visibleUntil: seconds, corner: settings.cornerRadius)
                    x += w + settings.gap; index += 1
                }
            default:
                guard let asset = scene.assets.first else { continue }
                let motion = WallMotionGeometry.plan(for: scene.mode, asset: asset, viewport: v, settings: settings, reverse: scene.reverse, center: scene.zoomCenter, displayRegions: scene.displayRegions)
                seconds = motion.seconds + (scene.mode == .verticalPan && settings.stopAtFace && !(asset.faces ?? []).isEmpty ? 3 : 0)
                let frameTop = scene.mode == .verticalPan ? motion.frameTop : 0
                if scene.mode == .verticalPan { clip = PNRect(x: ox + motion.fromX, y: oy + frameTop, width: motion.width, height: min(v.height, motion.height)) }
                add(asset, width: motion.width, height: motion.height, fromX: motion.fromX, fromY: motion.fromY + frameTop, toX: motion.toX, toY: motion.toY + frameTop, fromScale: motion.fromScale, toScale: motion.toScale, centerX: motion.center.x, centerY: motion.center.y, motion: motion.seconds, visibleUntil: seconds, ease: scene.mode == .zoom)
            }
            duration = max(duration, seconds)
        }
        if first.scene.mode != .gallery { for index in placements.indices { placements[index].visibleUntil = duration } }
        let mode = first.scene.mode == .horizontalGallery ? "galleryScroll" : first.scene.mode.rawValue
        var plan = PNScene(id: UUID(), groupId: group, sessionId: wall.sessionId, settingsRevision: wall.revision, mode: mode, viewport: PNSize(width: width, height: height), displays: displays, duration: duration, fadeSeconds: min(settings.fadeSeconds, duration), background: settings.backgroundHex, placements: placements, ambient: [])
        if settings.glassBackground { plan.ambient = try await ambient(plan) }
        try plan.validate(); return plan
    }
    private func ambient(_ plan: PNScene) async throws -> [PNAmbient] {
        let ids = Set(plan.placements.map(\.displayId)); let samples = max(2, min(24, 64 / max(1, ids.count)))
        var images: [String: DecodedPhoto] = [:]
        for key in Set(plan.placements.map(\.asset)) {
            if let bytes = try await cache.read(key), let image = await Task.detached(priority: .utility, operation: { PNImageDecode.decode(bytes, maximum: 128) }).value { images[key.opaqueId] = image }
        }
        var frames: [PNAmbient] = []
        for id in ids {
            let processor = AmbientProcessor()
            let display = plan.displays.first { $0.id == id }
            let size = display.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: plan.viewport.width, height: plan.viewport.height)
            let ox = Double(display.map { $0.x - plan.displays.map(\.x).min()! } ?? 0), oy = Double(display.map { $0.y - plan.displays.map(\.y).min()! } ?? 0)
            for index in 0..<samples {
                let at = Double(index) / Double(samples - 1) * plan.duration
                let cards = plan.placements.filter { $0.displayId == id }.compactMap { p -> AmbientCard? in
                    guard let image = images[p.asset.opaqueId] else { return nil }; let value = p.evaluate(min(at, plan.duration - 0.0001))
                    let frame = CGRect(x: value.x - ox - p.width * (value.scale - 1) * p.centerX, y: value.y - oy - p.height * (value.scale - 1) * p.centerY, width: p.width * value.scale, height: p.height * value.scale)
                    return AmbientCard(image: image.image, frame: frame, opacity: value.opacity, radius: p.cornerRadius)
                }
                if let image = await processor.render(cards: cards, viewport: size), let png = PNImageDecode.png(image.image) { frames.append(PNAmbient(at: at, png: png, displayId: id)) }
            }
        }
        return frames
    }
}

nonisolated enum PNImageDecode {
    static func decode(_ bytes: Data, maximum: Int) -> DecodedPhoto? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
            [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
             kCGImageSourceThumbnailMaxPixelSize: max(64, maximum), kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return DecodedPhoto(image: image)
    }
    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(output, image, nil); return CGImageDestinationFinalize(output) ? data as Data : nil
    }
}

@MainActor final class PNPlayback: PNPlaybackOutput {
    struct Frame { var plan: PNScene; var images: [String: DecodedPhoto]; var ambient: [PNAmbientImage]; var start = 0.0; var paused = 0.0 }
    struct PNAmbientImage { var frame: PNAmbient; var image: NSImage }
    private let local: UUID; private let clock: any PNClock; private let cache: PNPhotoCache
    private let enter: () -> Void; private let budget: () -> Int
    private var prepared: [UUID: Frame] = [:], current: [UUID: Frame] = [:], outgoing: [UUID: Frame] = [:]
    private var commits: [UUID: PNCommit] = [:], controls: [PNControl] = []
    private var windows: [String: NSWindow] = [:]
    private var timer: Task<Void, Never>?, fallback: Task<Void, Never>?
    private var recovery = PNRecoveryState.listening
    private var repeating = false
    private var snapshot: PNSnapshot?
    private var planner: (any PNScenePlanning)?
    private let layoutPreview: PNLayoutPreview
    private var photos: PNPhotoTransfers?
    private var pausedAt: Double?, stopped = false
    private(set) var isDisplaying = false
    var isPaused: Bool { pausedAt != nil }
    var isStopped: Bool { stopped }
    var isRunning: Bool { isDisplaying && !stopped && !current.isEmpty }
    var previewVisible: Bool { layoutPreview.visible }
    var changed: (() -> Void)?
    init(local: UUID, clock: any PNClock, cache: PNPhotoCache, budget: @escaping () -> Int, enter: @escaping () -> Void) { self.local = local; self.clock = clock; self.cache = cache; self.budget = budget; self.enter = enter; layoutPreview = PNLayoutPreview(local: local) }
    func preview(_ plan: PNPreviewPlan) { layoutPreview.schedule(plan); layoutPreview.changed = { [weak self] in self?.changed?() }; startTimer() }
    func bind(planner: any PNScenePlanning, photos: PNPhotoTransfers) { self.planner = planner; self.photos = photos }
    func prepare(_ scene: PNScene) async throws {
        try Task.checkCancellation()
        try scene.validate(); let own = Set(scene.displays.filter { $0.key.peerId == local }.map(\.id))
        let keys = Set(scene.placements.filter { $0.displayId == nil || own.contains($0.displayId!) }.map(\.asset))
        let pixels = min(16_000_000, max(65536, budget() * 1024 * 1024 / 8 / max(1, keys.count)))
        var images: [String: DecodedPhoto] = [:]
        for key in keys {
            guard let bytes = try await cache.read(key), let photo = photos?.available[key.opaqueId] else { throw PNError.invalid("写真キャッシュを準備中です。") }
            let maximum = min(4096, max(64, Int(sqrt(Double(pixels) * Double(max(photo.pixelWidth, photo.pixelHeight)) / Double(min(photo.pixelWidth, photo.pixelHeight))))))
            guard let image = await Task.detached(priority: .utility, operation: { PNImageDecode.decode(bytes, maximum: maximum) }).value else { throw PNError.invalid("原寸画像をデコードできません。") }
            images[key.opaqueId] = image
            try Task.checkCancellation()
        }
        let ambient = scene.ambient.compactMap { frame in NSImage(data: frame.png).map { PNAmbientImage(frame: frame, image: $0) } }
        prepared = prepared.filter { $0.value.plan.groupId != scene.groupId }; prepared[scene.id] = Frame(plan: scene, images: images, ambient: ambient)
    }
    func commit(_ commit: PNCommit) { guard prepared[commit.planId] != nil else { return }; commits[commit.groupId] = commit; startTimer() }
    func control(_ control: PNControl) { controls.append(control); startTimer() }
    private func startTimer() {
        if timer != nil { return }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.render()
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }
    private func elapsed(_ frame: Frame) -> Double {
        let value = max(0, (pausedAt ?? clock.now) - frame.start - frame.paused)
        return repeating ? value.truncatingRemainder(dividingBy: frame.plan.duration) : min(value, frame.plan.duration - 0.00001)
    }
    private func render() {
        let now = clock.now
        layoutPreview.update(now)
        for command in controls.filter({ $0.effectiveAt <= now }) {
            switch command.operation {
            case "pause": pausedAt = pausedAt ?? command.effectiveAt
            case "resume":
                if let pausedAt {
                    let delay = max(0, command.effectiveAt - pausedAt)
                    for id in current.keys { current[id]?.paused += delay }
                    for id in outgoing.keys { outgoing[id]?.paused += delay }
                    for id in commits.keys { commits[id]?.startAt += delay }
                }; pausedAt = nil
            case "stop": stopped = true; closeWindows(); current.removeAll(); outgoing.removeAll()
            case "start": stopped = false; pausedAt = nil
            default: break
            }
            changed?()
        }
        controls.removeAll { $0.effectiveAt <= now }
        if stopped { return }
        if pausedAt == nil {
            for commit in commits.values.filter({ $0.startAt <= now }) {
                guard var frame = prepared.removeValue(forKey: commit.planId) else { commits.removeValue(forKey: commit.groupId); continue }
                if !isDisplaying { enter(); isDisplaying = true }
                outgoing[commit.groupId] = current[commit.groupId]; frame.start = commit.startAt; current[commit.groupId] = frame
                commits.removeValue(forKey: commit.groupId); changed?()
            }
        }
        for frame in current.values {
            if now - frame.start >= frame.plan.fadeSeconds { outgoing.removeValue(forKey: frame.plan.groupId) }
            for display in frame.plan.displays where display.selected && display.key.peerId == local {
                guard let id = UInt32(display.key.displayId), let screen = ScreenDescriptor.availableScreens().first(where: { $0.id == id }) else { continue }
                let window: NSWindow
                if let existing = windows[display.id] { window = existing }
                else {
                    window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
                    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]; window.backgroundColor = .black
                    window.isOpaque = true; window.hasShadow = false; window.ignoresMouseEvents = true; window.isReleasedWhenClosed = false
                    window.contentView = PNSceneView(); windows[display.id] = window
                }
                window.setFrame(screen.frame, display: true); if !layoutPreview.visible { window.orderFrontRegardless() }
                if let view = window.contentView as? PNSceneView {
                    view.display = display; view.layers = outgoing[frame.plan.groupId].map { [($0, elapsed($0), 1.0)] } ?? []
                    let opacity = frame.plan.fadeSeconds <= 0 ? 1 : min(1, max(0, elapsed(frame) / frame.plan.fadeSeconds))
                    view.layers.append((frame, elapsed(frame), opacity)); view.needsDisplay = true
                }
            }
        }
        let active = Set(current.values.flatMap { $0.plan.displays.filter { $0.selected && $0.key.peerId == local }.map(\.id) })
        for id in windows.keys.filter({ !active.contains($0) }) { windows.removeValue(forKey: id)?.close() }
        if recovery == .standalone && fallback == nil && current.values.contains(where: { now - $0.start - $0.paused >= $0.plan.duration - 2 }) { rebuildLocal() }
    }
    func recover(_ state: PNRecoveryState, wall: PNSnapshot) {
        for id in current.keys.filter({ id in !wall.displays.contains { $0.selected && $0.key.peerId == local && $0.unit == id } }) { current.removeValue(forKey: id); outgoing.removeValue(forKey: id) }
        snapshot = wall; guard recovery != state else { return }; recovery = state
        if [.isolatedRepeating, .standalone].contains(state) { repeating = true }
        if state == .synchronized { repeating = false }
        if state == .standalone && isDisplaying { rebuildLocal() }; changed?()
    }
    private func rebuildLocal() {
        guard fallback == nil, let planner, let photos, var wall = snapshot, isDisplaying else { return }
        wall.displays.removeAll { $0.key.peerId != local }
        fallback = Task { @MainActor [weak self] in
            guard let self else { return }; defer { fallback = nil }
            do {
                for group in Set(wall.displays.filter(\.selected).map(\.unit)) {
                    guard let plan = try await planner.prepare(wall: wall, group: group, photos: Array(photos.available.values)), !Task.isCancelled && recovery == .standalone else { continue }
                    try await prepare(plan); commit(PNCommit(planId: plan.id, groupId: group, startAt: clock.now + 0.25))
                }
            } catch { if !Task.isCancelled { WallLog.write("単体表示の準備を再試行します。", error: error) } }
        }
    }
    private func closeWindows() { for w in windows.values { w.orderOut(nil); w.close() }; windows.removeAll() }
    func stop() { timer?.cancel(); timer = nil; fallback?.cancel(); fallback = nil; layoutPreview.close(); closeWindows(); current.removeAll(); outgoing.removeAll(); prepared.removeAll(); commits.removeAll(); controls.removeAll(); isDisplaying = false }
}

@MainActor private final class PNSceneView: NSView {
    var display: PNDisplay?
    var layers: [(PNPlayback.Frame, Double, Double)] = []
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let display, let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.black.setFill(); bounds.fill()
        context.saveGState(); defer { context.restoreGState() }
        context.scaleBy(x: bounds.width / Double(display.width), y: bounds.height / Double(display.height))
        for (frame, elapsed, opacity) in layers {
            let plan = frame.plan; let left = plan.displays.map(\.x).min()!, top = plan.displays.map(\.y).min()!
            let dx = Double(display.x - left), dy = Double(display.y - top)
            context.saveGState(); context.setAlpha(opacity)
            context.setFillColor(NSColor(Color(hex: plan.background)).cgColor); context.fill(CGRect(x: 0, y: 0, width: display.width, height: display.height))
            let ambient = frame.ambient.filter { $0.frame.displayId == display.id || $0.frame.displayId == nil }.sorted { $0.frame.at < $1.frame.at }
            if let a = ambient.last(where: { $0.frame.at <= elapsed }) ?? ambient.first {
                let area = a.frame.displayId == nil ? CGRect(x: -dx, y: -dy, width: plan.viewport.width, height: plan.viewport.height) : CGRect(x: 0, y: 0, width: display.width, height: display.height)
                a.image.draw(in: area, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                if let b = ambient.first(where: { $0.frame.at > elapsed }) {
                    let blend = min(1, max(0, (elapsed - a.frame.at) / max(0.001, b.frame.at - a.frame.at)))
                    b.image.draw(in: area, from: .zero, operation: .sourceOver, fraction: blend, respectFlipped: true, hints: nil)
                }
                context.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor); context.fill(CGRect(x: 0, y: 0, width: display.width, height: display.height))
            }
            context.translateBy(x: -dx, y: -dy)
            for p in plan.placements where p.displayId == nil || p.displayId == display.id {
                guard let image = frame.images[p.asset.opaqueId]?.image else { continue }; let value = p.evaluate(elapsed)
                if value.opacity <= 0 { continue }
                context.saveGState(); context.clip(to: CGRect(x: p.clip.x, y: p.clip.y, width: p.clip.width, height: p.clip.height))
                context.setAlpha(opacity * value.opacity)
                let rect = CGRect(x: value.x - p.width * (value.scale - 1) * p.centerX, y: value.y - p.height * (value.scale - 1) * p.centerY, width: p.width * value.scale, height: p.height * value.scale)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: p.cornerRadius, cornerHeight: p.cornerRadius, transform: nil)); context.clip()
                context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: rect.size)); context.restoreGState()
            }
            context.restoreGState()
        }
    }
}
