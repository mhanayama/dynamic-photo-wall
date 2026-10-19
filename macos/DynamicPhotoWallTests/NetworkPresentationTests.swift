import AppKit
import CryptoKit
import Testing
@testable import DynamicPhotoWall

// Inspect decoded fixtures, timing and fake surfaces. Never create, show,
// draw or capture a desktop window.
@MainActor struct NetworkPresentationTests {
    private let modes = ["gallery", "galleryScroll", "verticalPan", "horizontalPan", "zoom"]
    @Test func galleryContinuationKeepsTheSurfaceImagesAndFullOpacity() async throws {
        let f = try await Fixture(); defer { f.close() }
        for mode in ["gallery", "galleryScroll"] {
            let old = f.plan(mode)
            try await f.show(old); f.clock.time += 2; f.output.render()
            let surface = try #require(f.log.surfaces[1])
            let image = try #require(surface.layers.last?.frame.images[f.photo.key.opaqueId]?.image)
            var next = old; next.id = UUID(); next.continuationOf = old.id
            try await f.output.prepare(next)
            f.output.commit(PNCommit(planId: next.id, groupId: next.groupId, startAt: f.clock.time))
            f.output.render()
            #expect(f.log.surfaces[1] === surface && surface.closed == 0)
            #expect(surface.layers.count == 1 && surface.layers[0].opacity == 1)
            #expect(surface.layers[0].frame.images[f.photo.key.opaqueId]?.image === image)
        }
    }
    @Test func allModeHandoffsKeepSurfacesAndEachPlansOwnCrop() async throws {
        let f = try await Fixture(); defer { f.close() }
        for from in modes {
            for to in modes {
                let old = f.plan(from), next = f.plan(to, remote: false)
                try await f.show(old)
                f.clock.time += 2; f.output.render()
                let surface = try #require(f.log.surfaces[1])
                let image = try #require(surface.layers.last?.frame.images[f.photo.key.opaqueId]?.image)
                let count = f.log.created
                try await f.output.prepare(next)
                #expect(f.log.created == count) // Preparation does not own a window.
                f.output.commit(PNCommit(planId: next.id, groupId: next.groupId, startAt: f.clock.time))
                f.output.render()
                #expect(f.log.created == count && f.log.surfaces[1] === surface && surface.closed == 0)
                #expect(surface.layers.count == 2)
                #expect(surface.layers[0].opacity == 1 && surface.layers[1].opacity == 0)
                #expect(surface.layers[0].crop.minX == 400 && surface.layers[1].crop.minX == 0)
                #expect(surface.layers[0].frame.images[f.photo.key.opaqueId]?.image === image)
                f.clock.time += 0.5; f.output.render()
                #expect(surface.layers.map(\.opacity) == [1, 0.5])
                f.clock.time += 0.6; f.output.render()
                #expect(surface.layers.count == 1 && surface.layers[0].frame.plan.id == next.id)
            }
        }
    }
    @Test func rapidSpanMirrorAndRegroupingChangesRetainTheVisibleComposition() async throws {
        let f = try await Fixture(); defer { f.close() }
        let first = f.plan("gallery"), second = f.plan("zoom", individual: true, remote: false)
        try await f.show(first)
        f.clock.time += 2; f.output.render()
        try await f.show(second)
        f.clock.time += 0.25; f.output.render()
        let surface = try #require(f.log.surfaces[1])
        #expect(surface.layers.map(\.opacity) == [1, 0.25])
        let regrouped = f.plan("verticalPan", group: UUID())
        f.output.recover(.synchronized, wall: f.wall(regrouped))
        f.output.render()
        #expect(surface.layers.map(\.opacity) == [1, 0.25] && surface.closed == 0)
        try await f.show(regrouped)
        #expect(surface.layers.map(\.opacity) == [1, 0.25, 0])
        #expect(surface.layers.map { $0.frame.plan.id } == [first.id, second.id, regrouped.id])
        f.clock.time += 1.1; f.output.render()
        #expect(surface.layers.count == 1 && f.log.created == 2 && surface.closed == 0)
    }
    @Test func preparationFailureAndStopKeepTheirExpectedSurfaceLifetimes() async throws {
        let f = try await Fixture(); defer { f.close() }
        let plan = f.plan("gallery")
        try await f.output.prepare(plan)
        #expect(f.log.created == 0 && f.log.events.isEmpty)
        f.output.commit(PNCommit(planId: plan.id, groupId: plan.groupId, startAt: f.clock.time))
        f.output.render()
        #expect(f.log.events.last == "enter")
        #expect(Set(f.log.events.prefix(4)) == Set(["create1", "present1", "create2", "present2"]))
        let surface = try #require(f.log.surfaces[1])
        #expect(surface.layers[0].opacity == 1)
        #expect(surface.layers[0].evaluate(plan.placements[0]).opacity == 1)
        var broken = f.plan("zoom"); broken.ambient = [PNAmbient(at: 0, png: Data([0]), displayId: nil)]
        await #expect(throws: (any Error).self) { try await f.output.prepare(broken) }
        f.output.commit(PNCommit(planId: broken.id, groupId: broken.groupId, startAt: f.clock.time))
        f.output.render()
        #expect(surface.layers.last?.frame.plan.id == plan.id && surface.closed == 0 && f.log.created == 2)
        f.output.stop(); f.output.render()
        #expect(surface.closed == 1)
        await #expect(throws: CancellationError.self) { try await f.output.prepare(plan) }
        f.output.commit(PNCommit(planId: plan.id, groupId: plan.groupId, startAt: f.clock.time)); f.output.render()
        #expect(f.log.created == 2 && !f.output.isDisplaying)
    }
    @Test func galleryEndpointAndIsolationLoopsNeverExposeAnEmptyFirstFrame() async throws {
        let f = try await Fixture(); defer { f.close() }
        var plan = f.plan("gallery")
        var a = plan.placements[0], b = a
        a.visibleUntil = 5; b.id = 1; b.visibleFrom = 4
        plan.placements = [a, b]
        try await f.show(plan)
        let surface = try #require(f.log.surfaces[1])
        f.clock.time += 4.5; f.output.render()
        #expect(surface.layers[0].evaluate(a).opacity == 0.5 && surface.layers[0].evaluate(b).opacity == 0.5)
        f.clock.time += 5; f.output.render()
        #expect(surface.layers[0].evaluate(b).opacity == 1)
        f.output.recover(.isolatedRepeating, wall: f.wall(plan))
        f.clock.time += 0.5; f.output.render()
        #expect(surface.layers.map(\.opacity) == [1, 0])
        #expect(surface.layers[0].evaluate(b).opacity == 1)
        #expect(surface.layers[1].elapsed == 0 && surface.layers[1].evaluate(a).opacity == 1)
        f.clock.time += 0.5; f.output.render()
        #expect(surface.layers.map(\.opacity) == [1, 0.5])
        f.clock.time += 0.6; f.output.render()
        #expect(surface.layers.count == 1 && surface.closed == 0 && f.log.created == 2)
    }
    @Test func pausingDuringAFadeKeepsThePredecessorUntilTheFadeResumes() async throws {
        let f = try await Fixture(); defer { f.close() }
        try await f.show(f.plan("zoom"))
        f.clock.time += 2; f.output.render()
        try await f.show(f.plan("horizontalPan", remote: false))
        f.clock.time += 0.4
        f.output.control(PNControl(operation: "pause", effectiveAt: f.clock.time)); f.output.render()
        let surface = try #require(f.log.surfaces[1]), opacity = surface.layers.last!.opacity
        f.clock.time += 90; f.output.render()
        #expect(surface.layers.count == 2 && surface.layers.last?.opacity == opacity)
        f.output.control(PNControl(operation: "resume", effectiveAt: f.clock.time)); f.output.render()
        #expect(abs(surface.layers.last!.opacity - opacity) < 1e-9)
        f.clock.time += 0.7; f.output.render()
        #expect(surface.layers.count == 1 && surface.closed == 0)
    }
    @Test func standalonePreparationAndResynchronizationReuseTheSamePhysicalOutputs() async throws {
        let f = try await Fixture(); defer { f.close() }
        let shared = f.plan("gallery"), standalone = f.plan("zoom", individual: true, remote: false)
        try await f.show(shared)
        let surface = try #require(f.log.surfaces[1])
        f.planner.next = standalone
        f.output.recover(.isolatedRepeating, wall: f.wall(shared))
        f.clock.time += 60
        f.output.recover(.standalone, wall: f.wall(shared))
        for _ in 0..<500 where surface.layers.last?.frame.plan.id != standalone.id {
            try await Task.sleep(for: .milliseconds(1)); f.clock.time += 0.1; f.output.render()
        }
        #expect(surface.layers.last?.frame.plan.id == standalone.id)
        #expect(f.log.created == 2 && surface.closed == 0)
        #expect(f.planner.lastWall?.displays.allSatisfy { $0.key.peerId == f.local } == true)
        let rejoined = f.plan("horizontalPan")
        f.output.recover(.synchronized, wall: f.wall(rejoined))
        try await f.show(rejoined)
        #expect(surface.layers.last?.frame.plan.id == rejoined.id && f.log.created == 2 && surface.closed == 0)
        f.output.control(PNControl(operation: "stop", effectiveAt: f.clock.time)); f.output.render()
        #expect(surface.closed == 1)
    }
    @Test func physicalScreenRemovalClosesOnlyThatSurface() async throws {
        let f = try await Fixture(); defer { f.close() }
        try await f.show(f.plan("zoom"))
        let first = try #require(f.log.surfaces[1]), second = try #require(f.log.surfaces[2])
        let screens = f.log.screens; f.log.screens.removeLast(); f.output.render()
        #expect(first.closed == 0 && second.closed == 1)
        f.log.screens = screens; f.output.render()
        #expect(f.log.created == 3 && f.log.surfaces[1] === first && f.log.surfaces[2] !== second)
    }
    @Test func sharedPreviewsGainColorOnceAtTheReceiverWithoutChangingPhotosOrWireBytes() async throws {
        let f = try await Fixture(); defer { f.close() }
        var plan = f.plan("zoom")
        plan.ambient = [PNAmbient(at: 0, png: f.original, displayId: nil)]
        try await f.show(plan)
        let frame = try #require(f.log.surfaces[1]?.layers.last?.frame)
        let foreground = try #require(frame.images[f.photo.key.opaqueId]?.image)
        let image = try #require(frame.ambient.first?.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let referenceImage = try #require(PNImageDecode.decode(f.original, maximum: 4096)?.image)
        let reference = try #require(NSBitmapImageRep(cgImage: referenceImage).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        let original = try #require(NSBitmapImageRep(cgImage: foreground).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        let enhanced = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        #expect(original == reference)
        #expect(enhanced.redComponent > original.redComponent && enhanced.blueComponent < original.blueComponent)
        #expect(frame.plan.ambient[0].png == f.original && plan.ambient[0].png == f.original)
    }
    @Test func theOldLocalHostIsRetiredOnlyAfterAllNewSurfacesHaveActuallyDrawn() async throws {
        let f = try await Fixture(); defer { f.close() }
        f.log.ready = false
        try await f.show(f.plan("zoom"))
        #expect(f.log.created == 2 && !f.log.events.contains("enter") && !f.output.isDisplaying)
        f.output.render()
        #expect(!f.log.events.contains("enter"))
        f.log.ready = true; f.output.render()
        #expect(f.log.events.last == "enter" && f.output.isDisplaying && f.log.created == 2)
    }

    @Test func independentGalleryFadesSurviveTheOutputAdapterAndLegacyDefaults() async throws {
        let f = try await Fixture(); defer { f.close() }
        var plan = f.plan("gallery")
        var placement = plan.placements[0]
        placement.visibleFrom = 2; placement.visibleUntil = 8
        placement.fadeSeconds = 1; placement.fadeInSeconds = 0; placement.fadeOutSeconds = 2
        plan.placements = [placement]
        try await f.show(plan)
        f.clock.time += 2; f.output.render()
        let surface = try #require(f.log.surfaces[1])
        #expect(try #require(surface.layers.last).evaluate(placement).opacity == 1)
        f.clock.time += 5; f.output.render()
        let layer = try #require(surface.layers.last)
        #expect(layer.evaluate(placement).opacity == 0.5)
        placement.fadeOutSeconds = nil
        #expect(layer.evaluate(placement).opacity == 1)
        placement.fadeOutSeconds = -1
        plan.placements = [placement]
        #expect(throws: (any Error).self) { try plan.validate() }
    }

    private final class Clock: PNClock {
        var time = 100.0
        var now: Double { time }; var elapsed: Double { time }
        func observe(_ pong: PNPong) {}
    }
    private final class Surface: PNPlaybackSurface {
        var layers: [PNPlaybackLayer] = [], closed = 0
        var isReady: Bool { log.ready }
        let id: UInt32
        unowned let log: Log
        init(id: UInt32, log: Log) { self.id = id; self.log = log }
        func present(_ layers: [PNPlaybackLayer], on screen: ScreenDescriptor, visible: Bool) { self.layers = layers; log.events.append("present\(id)") }
        func close() { closed += 1 }
    }
    @MainActor private final class Log {
        var surfaces: [UInt32: Surface] = [:], created = 0, events: [String] = []
        var ready = true
        var screens = (1...2).map { ScreenDescriptor(id: UInt32($0), name: "Fixture", frame: CGRect(x: ($0 - 1) * 400, y: 0, width: 400, height: 300), pixelWidth: 400, pixelHeight: 300) }
    }
    private final class Planner: PNScenePlanning {
        var next: PNScene?, lastWall: PNSnapshot?
        func prepare(wall: PNSnapshot, group: UUID, photos: [PNPhoto]) async throws -> PNScene? { lastWall = wall; return next }
    }
    private final class Provider: PNPhotoProviding {
        var sources: [PNSource] { [] }
        func read(_ selection: PNSelection) -> AsyncThrowingStream<PNImportedPhoto, Error> { AsyncThrowingStream { $0.finish() } }
    }
    @MainActor private final class Fixture {
        let root: URL, local: UUID, remote = UUID(), group = UUID(), session = UUID(), original: Data
        let clock: Clock, log: Log, planner: Planner, output: PNPlayback, transfers: PNPhotoTransfers, photo: PNPhoto
        init() async throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "DPW.Presentation.\(UUID())")
            self.root = root
            let local = UUID(); self.local = local
            let clock = Clock(), log = Log(), planner = Planner()
            self.clock = clock; self.log = log; self.planner = planner
            let cache = try PNPhotoCache(root: root, key: SymmetricKey(size: .bits256))
            let image = try #require(AmbientProcessor.image(Array(repeating: [UInt8(200),80,40,255], count: 16).flatMap { $0 }, width: 4, height: 4))
            let bytes = try #require(PNImageDecode.png(image))
            original = bytes
            let key = PNAssetKey(providerId: local, sourceId: UUID(), generationId: UUID(), imageId: PNWire.digest(bytes))
            let photo = PNPhoto(key: key, pixelWidth: 4, pixelHeight: 4, byteLength: bytes.count,
                faceMetadata: PNFaces(pixelWidth: 4, pixelHeight: 4, detector: "fixture", state: "complete", faces: []))
            self.photo = photo
            try await cache.activate(local, key.generationId); try await cache.put(photo, original: bytes)
            transfers = PNPhotoTransfers(local: local, provider: Provider(), cache: cache)
            try await transfers.configure([PNSelection(providerId: local, sourceId: key.sourceId, generationId: key.generationId)])
            output = PNPlayback(local: local, clock: clock, cache: cache, budget: { 16 }, enter: { log.events.append("enter") },
                screens: { log.screens }, makeSurface: { screen in
                    let surface = Surface(id: screen.id, log: log); log.created += 1; log.surfaces[screen.id] = surface
                    log.events.append("create\(screen.id)"); return surface
                }, automaticRendering: false)
            output.bind(planner: planner, photos: transfers)
        }
        func close() { output.stop(); transfers.stop(); try? FileManager.default.removeItem(at: root) }
        func plan(_ mode: String, individual: Bool = false, remote: Bool = true, group: UUID? = nil) -> PNScene {
            let group = group ?? self.group, offset = remote ? 400 : 0
            let own = (1...2).map { PNDisplay(key: PNDisplayKey(peerId: local, displayId: String($0)), selected: true,
                groupId: group, x: offset + ($0 - 1) * 400, y: 0, width: 400, height: 300) }
            let displays = remote ? [PNDisplay(key: PNDisplayKey(peerId: self.remote, displayId: "remote"), selected: true, groupId: group, x: 0, y: 0, width: 400, height: 300)] + own : own
            let width = remote ? 1200 : 800
            func placement(_ id: Int, _ display: PNDisplay?) -> PNPlacement {
                let x = Double(display?.x ?? 0), w = Double(display?.width ?? width)
                return PNPlacement(id: id, asset: photo.key, displayId: display?.id, clip: PNRect(x: x, y: 0, width: w, height: 300),
                    width: w, height: 300, fromX: x, fromY: 0, toX: x, toY: 0, fromScale: 1, toScale: 1,
                    centerX: 0.5, centerY: 0.5, startSeconds: 0, motionSeconds: 10, visibleFrom: 0, visibleUntil: 10,
                    fadeSeconds: 1, cornerRadius: 0, ease: false)
            }
            return PNScene(id: UUID(), groupId: group, sessionId: session, settingsRevision: 1, mode: mode,
                viewport: PNSize(width: Double(width), height: 300), displays: displays, duration: 10, fadeSeconds: 1, background: "#000000",
                placements: individual ? own.enumerated().map { placement($0.offset, $0.element) } : [placement(0, nil)], ambient: [])
        }
        func wall(_ plan: PNScene) -> PNSnapshot {
            PNSnapshot(wallId: UUID(), sessionId: session, leaderId: local, revision: 1,
                groups: [PNGroup(id: plan.groupId, name: "fixture")], displays: plan.displays, sources: [], playback: PNOptions(WallSettings()))
        }
        func show(_ plan: PNScene) async throws {
            try await output.prepare(plan); output.commit(PNCommit(planId: plan.id, groupId: plan.groupId, startAt: clock.time)); output.render()
        }
    }
}
