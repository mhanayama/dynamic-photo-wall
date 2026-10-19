import AppKit
import SwiftUI
import Testing
@testable import DynamicPhotoWall

@MainActor struct AmbientSchedulingTests {
    let viewport = CGSize(width: 1920, height: 1080)
    let red = PhotoAsset(url: URL(filePath: "/fixture/red"), pixelWidth: 3000, pixelHeight: 4000)
    let blue = PhotoAsset(url: URL(filePath: "/fixture/blue"), pixelWidth: 4000, pixelHeight: 2000)

    func store() async throws -> PhotoImageStore {
        let a = try #require(AmbientProcessor.image([255, 0, 0, 255], width: 1, height: 1))
        let b = try #require(AmbientProcessor.image([0, 0, 255, 255], width: 1, height: 1))
        let store = PhotoImageStore(decode: { request in DecodedPhoto(image: request.asset.url.lastPathComponent == "red" ? a : b) })
        #expect(await store.prepare([red, blue]))
        return store
    }

    func presentation(_ mode: WallMode = .gallery, at elapsed: Double, asset: PhotoAsset? = nil, id: Int = 1,
                      distance: Double = 0, layout: GalleryFrameTransition? = nil) -> WallScenePresentation {
        let asset = asset ?? red
        return WallScenePresentation(scene: WallScene(id: id, mode: mode, assets: [asset]), progress: 0,
            elapsed: elapsed, slots: [GallerySlot(id: 0, asset: asset, nextReplacementAt: .infinity)],
            scrollDistance: distance, galleryLayout: layout)
    }

    func idle(_ sampler: AmbientSampler) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while sampler.isRendering && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(!sampler.isRendering)
    }

    @Test func staticGalleryGeneratesOnceAcrossOneMinuteOfDisplayTicks() async throws {
        let images = try await store(), sampler = AmbientSampler()
        defer { sampler.stop() }
        sampler.update(presentation(at: 0), settings: WallSettings(), viewport: viewport, images: images, paused: false)
        try await idle(sampler)
        for tick in 1...3600 {
            sampler.update(presentation(at: Double(tick) / 60), settings: WallSettings(), viewport: viewport, images: images, paused: false)
        }
        try await idle(sampler)
        #expect(sampler.updateCount == 1)
    }

    @Test func replacementResizeAndSceneChangeInvalidateWithoutWaitingForATick() async throws {
        let images = try await store(), sampler = AmbientSampler()
        defer { sampler.stop() }
        for (index, asset) in [red, blue, red].enumerated() {
            sampler.update(presentation(at: 0, asset: asset), settings: WallSettings(), viewport: viewport, images: images, paused: false)
            try await idle(sampler)
            #expect(sampler.updateCount == index + 1)
        }
        sampler.update(presentation(at: 0), settings: WallSettings(), viewport: CGSize(width: 1080, height: 1920), images: images, paused: false)
        try await idle(sampler)
        #expect(sampler.updateCount == 4)
    }

    @Test func panZoomAndScrollSampleMotionAndHoldTheirFinalComposition() async throws {
        let images = try await store()
        for mode in [WallMode.verticalPan, .horizontalPan, .zoom, .horizontalGallery] {
            let sampler = AmbientSampler()
            let asset = mode == .verticalPan ? red : blue
            var settings = WallSettings(); settings.panPixelsPerSecond = 120
            for tick in 0...8 {
                sampler.update(presentation(mode, at: Double(tick) * 1.25, asset: asset, distance: Double(tick) * 20),
                    settings: settings, viewport: viewport, images: images, paused: false)
                try await idle(sampler)
            }
            #expect(sampler.updateCount > 1)
            sampler.update(presentation(mode, at: 100, asset: asset, distance: 160), settings: settings, viewport: viewport, images: images, paused: false)
            try await idle(sampler)
            let count = sampler.updateCount
            for tick in 801...880 {
                sampler.update(presentation(mode, at: Double(tick) / 8, asset: asset, distance: 160),
                    settings: settings, viewport: viewport, images: images, paused: false)
            }
            try await idle(sampler)
            #expect(sampler.updateCount == count)
            sampler.stop()
        }
    }

    @Test func galleryRearrangementSamplesUntilExactEndAndThenStops() async throws {
        let images = try await store(), sampler = AmbientSampler()
        var settings = WallSettings(); settings.fadeSeconds = 1
        let layout = GalleryFrameTransition(from: [CGRect(x: 0, y: 0, width: 800, height: 1080)],
            to: [CGRect(x: 1000, y: 0, width: 800, height: 1080)], startedAt: 0)
        for tick in 0...8 {
            sampler.update(presentation(at: Double(tick) / 8, layout: layout), settings: settings, viewport: viewport, images: images, paused: false)
            try await idle(sampler)
        }
        #expect(sampler.updateCount == 9)
        sampler.update(presentation(at: 10, layout: layout), settings: settings, viewport: viewport, images: images, paused: false)
        try await idle(sampler)
        #expect(sampler.updateCount == 9)
        sampler.stop()
    }

    @Test func pendingChangesCoalesceAndTheFinalStaticFrameIsNotLost() async throws {
        let images = try await store(), probe = RenderProbe()
        let sampler = AmbientSampler(render: { cards, _, _ in await probe.render(cards) })
        sampler.update(presentation(at: 0), settings: WallSettings(), viewport: viewport, images: images, paused: false)
        while await probe.count == 0 { await Task.yield() }
        sampler.update(presentation(at: 0, asset: blue), settings: WallSettings(), viewport: viewport, images: images, paused: false)
        sampler.update(presentation(at: 0, asset: blue, id: 3), settings: WallSettings(), viewport: viewport, images: images, paused: false)
        await probe.release()
        try await idle(sampler)
        #expect(await probe.count == 2)
        #expect(sampler.updateCount == 2)
        let image = try #require(sampler.image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(Array(try #require(image.dataProvider?.data) as Data)[2] == 255)
        sampler.stop()
    }

    @Test func cancellationCannotPublishAnOldGenerationAfterResume() async throws {
        let images = try await store(), probe = RenderProbe()
        let sampler = AmbientSampler(render: { cards, _, _ in await probe.render(cards) })
        sampler.update(presentation(at: 0), settings: WallSettings(), viewport: viewport, images: images, paused: false)
        while await probe.count == 0 { await Task.yield() }
        sampler.stop()
        sampler.update(presentation(at: 0, asset: blue), settings: WallSettings(), viewport: viewport, images: images, paused: true)
        #expect(sampler.updateCount == 0)
        sampler.update(presentation(at: 0, asset: blue), settings: WallSettings(), viewport: viewport, images: images, paused: false)
        try await idle(sampler)
        await probe.release()
        await Task.yield()
        #expect(sampler.updateCount == 1)
        sampler.stop()
    }

    @Test func imageReadinessAndNewDecodedVariantsInvalidateStaticTokens() async throws {
        let image = try #require(AmbientProcessor.image([255, 0, 0, 255], width: 1, height: 1))
        let images = PhotoImageStore(decode: { _ in DecodedPhoto(image: image) })
        let sampler = AmbientSampler(), p = presentation(at: 0)
        let geometry = ForegroundGeometry.Prepared(p, settings: WallSettings(), viewport: viewport)
        let before = AmbientRefreshToken(p, prepared: geometry, images: images)
        sampler.update(p, settings: WallSettings(), viewport: viewport, images: images, paused: false)
        #expect(sampler.updateCount == 0)
        #expect(await images.prepare([red], desiredWidths: [PhotoImageKey(red): 100]))
        #expect(AmbientRefreshToken(p, prepared: geometry, images: images) != before)
        sampler.update(p, settings: WallSettings(), viewport: viewport, images: images, paused: false)
        try await idle(sampler)
        #expect(sampler.updateCount == 1)
        #expect(await images.prepare([red]))
        sampler.update(p, settings: WallSettings(), viewport: viewport, images: images, paused: false)
        try await idle(sampler)
        #expect(sampler.updateCount == 2)
        sampler.stop()
    }

    @Test func smallMotionAccumulatesToTextureResolutionAndOpacityInvalidates() async throws {
        let images = try await store(), sampler = AmbientSampler()
        let settings = WallSettings()
        sampler.update(presentation(.horizontalGallery, at: 0), settings: settings, viewport: viewport, images: images, paused: false)
        try await idle(sampler)
        sampler.update(presentation(.horizontalGallery, at: 0.125, distance: 0.1), settings: settings, viewport: viewport, images: images, paused: false)
        try await idle(sampler)
        #expect(sampler.updateCount == 1)
        sampler.update(presentation(.horizontalGallery, at: 0.25, distance: 6), settings: settings, viewport: viewport, images: images, paused: false)
        try await idle(sampler)
        #expect(sampler.updateCount == 2)
        sampler.stop()
        let fade = AmbientSampler()
        for tick in 0...8 {
            var slot = GallerySlot(id: 0, asset: blue, previousAsset: red, changedAt: 0, nextReplacementAt: .infinity)
            slot.previousFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let p = WallScenePresentation(scene: WallScene(id: 2, mode: .gallery, assets: [blue]), progress: 0,
                elapsed: Double(tick) / 8 * settings.fadeSeconds, slots: [slot], scrollDistance: 0)
            fade.update(p, settings: settings, viewport: viewport, images: images, paused: false)
            try await idle(fade)
        }
        #expect(fade.updateCount > 2)
        let layers = fade.textures.layers(at: 10)
        #expect(layers.last?.opacity == 1)
        fade.stop()
    }

    @Test func compositorSettlesWithoutGeneratingMorePixelsAndPauseFreezesItsClock() throws {
        let a = try #require(AmbientProcessor.image([255, 0, 0, 255], width: 1, height: 1))
        let b = try #require(AmbientProcessor.image([0, 0, 255, 255], width: 1, height: 1))
        var transition = AmbientTextureTransition()
        transition.push(a, at: 0, responseSeconds: 0.8)
        transition.push(b, at: 1, responseSeconds: 0.8)
        let halfway = transition.layers(at: 1.8)
        #expect(abs(halfway[1].opacity - (1 - exp(-1))) < 0.000001)
        #expect(transition.layers(at: 1.8).map(\.opacity) == halfway.map(\.opacity))
        #expect(transition.layers(at: 10).map(\.opacity) == [1, 1])
        #expect(transition.layers(at: 10)[1].image === b)
    }

    @Test func geometryCacheReusesMotionPlansAndInvalidatesForFacesSettingsAndViewport() {
        let cache = ForegroundGeometryCache()
        var settings = WallSettings()
        for tick in 0...600 {
            let p = presentation(.verticalPan, at: Double(tick) / 60)
            let prepared = cache.prepare(p, settings: settings, viewport: viewport)
            #expect(prepared.placements(p).map(\.frame) == ForegroundGeometry.placements(p, settings: settings, viewport: viewport).map(\.frame))
        }
        #expect(cache.preparationCount == 1)
        settings.panPixelsPerSecond += 10
        _ = cache.prepare(presentation(.verticalPan, at: 10), settings: settings, viewport: viewport)
        #expect(cache.preparationCount == 2)
        var faced = red; faced.faces = [FaceRegion(x: 0.2, y: 0.2, width: 0.1, height: 0.1)]
        _ = cache.prepare(presentation(.verticalPan, at: 10, asset: faced), settings: settings, viewport: viewport)
        _ = cache.prepare(presentation(.verticalPan, at: 10, asset: faced), settings: settings, viewport: CGSize(width: 1000, height: 600))
        #expect(cache.preparationCount == 4)
    }

    @Test func photoRedrawOnlyInvalidatesForImageModeOrSizeChanges() throws {
        let image = NSImage(cgImage: try #require(AmbientProcessor.image([255, 0, 0, 255], width: 1, height: 1)), size: CGSize(width: 1, height: 1))
        let view = AspectImageView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.setImage(image, contentMode: .fit)
        let count = view.redrawRequestCount
        for _ in 0..<600 { view.setImage(image, contentMode: .fit) }
        #expect(view.redrawRequestCount == count)
        view.setImage(image, contentMode: .fill)
        #expect(view.redrawRequestCount == count + 1)
        view.setFrameSize(CGSize(width: 200, height: 100))
        #expect(view.redrawRequestCount == count + 2)
    }
}

private actor RenderProbe {
    private(set) var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func render(_ cards: [AmbientCard]) async -> DecodedPhoto? {
        count += 1
        if count == 1 { await withCheckedContinuation { continuation = $0 } }
        return cards.first.map { DecodedPhoto(image: $0.image) }
    }
    func release() { continuation?.resume(); continuation = nil }
}
