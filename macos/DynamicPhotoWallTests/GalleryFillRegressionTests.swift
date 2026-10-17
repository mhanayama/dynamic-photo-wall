import AppKit
import Foundation
import Testing
@testable import DynamicPhotoWall

private actor FillDecodeAudit {
    var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}

@MainActor
struct GalleryFillRegressionTests {
    private let viewport = CGSize(width: 800, height: 300)
    private let displays = [CGRect(x: 0, y: 0, width: 400, height: 300), CGRect(x: 400, y: 0, width: 400, height: 300)]
    private var a: PhotoAsset { PhotoAsset(url: URL(filePath: "/fill/a.jpg"), pixelWidth: 400, pixelHeight: 800, faces: [.init(x: 0.25, y: 0.1, width: 0.5, height: 0.3)]) }
    private var bad: PhotoAsset { PhotoAsset(url: URL(filePath: "/fill/b.jpg"), pixelWidth: 1600, pixelHeight: 800, faces: [.init(x: 0.25, y: 0.1, width: 0.5, height: 0.3)]) }
    private var good: PhotoAsset { PhotoAsset(url: URL(filePath: "/fill/c.jpg"), pixelWidth: 1600, pixelHeight: 800, faces: [.init(x: 0.6, y: 0.1, width: 0.2, height: 0.3)]) }

    @Test func compactRowsPreserveGapAndBaselineAndKnownCandidatesImproveOnlyTargetSlot() throws {
        let frames = FaceSafeLayout.gallery([a,bad], viewport: viewport, gap: 8, displays: displays)
        #expect(abs(frames[1].minX - frames[0].maxX - 8) < 1e-7)
        #expect(frames[0].minY == frames[1].minY)
        let replacement = try #require(try GalleryComposition.improve([a,bad], candidates: [good], viewport: viewport, gap: 8, displays: displays, onlyIndex: 1))
        #expect(replacement.index == 1 && replacement.photo == good)
        #expect(GalleryComposition.loss([a,good], viewport: viewport, gap: 8, displays: displays) <= GalleryComposition.loss([a,bad], viewport: viewport, gap: 8, displays: displays) - 0.02)
        #expect(try GalleryComposition.improve([a,good], candidates: [bad], viewport: viewport, gap: 8, displays: displays) == nil)
        var unknown = good; unknown.faces = nil
        #expect(try GalleryComposition.improve([a,bad], candidates: [unknown], viewport: viewport, gap: 8, displays: displays) == nil)
        var noFaces = good; noFaces.faces = []
        #expect(try GalleryComposition.improve([a,bad], candidates: [noFaces], viewport: viewport, gap: 8, displays: displays) != nil)
        #expect(try GalleryComposition.improve([a,bad], candidates: Array(repeating: unknown, count: 12) + [good], viewport: viewport, gap: 8, displays: displays) == nil)
        #expect(try GalleryComposition.improve([a,bad], candidates: [a,bad], viewport: viewport, gap: 8, displays: displays) == nil)
    }

    @Test func samplingDoesNotConsumeHistoryAndRemembersOnlyAdoptedCandidate() {
        let selector = PhotoSelector(seed: 1)
        var ordered = WallSettings(); ordered.randomOrder = false
        #expect(selector.pick(from: [a,bad,good], settings: ordered) == a)
        var random = ordered; random.randomOrder = true
        #expect(selector.sample(from: [a,bad], settings: random, excluding: [], count: 12) == [bad])
        #expect(selector.sample(from: [a,bad], settings: random, excluding: [], count: 12) == [bad])
        selector.remember(bad, settings: random)
        #expect(selector.sample(from: [a,bad,good], settings: random, excluding: [], count: 12) == [good])
        #expect(selector.pick(from: [a,bad,good], settings: ordered) == good)
        #expect(selector.sample(from: [a,bad,good], settings: ordered, excluding: [], count: 12).isEmpty)
        #expect(selector.sample(from: [good], settings: random, excluding: [good.url], count: 12).isEmpty)
    }

    @Test func cacheOnlyLookupDistinguishesUnknownEmptyAndModifiedPhotoKitAsset() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "DPW-Fill-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var first = a; first.faces = nil
        var album = PhotosAlbumLibrary.makeAsset(identifier: "test/L0/001", width: 1600, height: 800, modifiedAt: Date(timeIntervalSince1970: 100), takenAt: nil, filename: "sample.heic")
        let file = directory.appending(path: "faces.json")
        try JSONEncoder().encode([PhotoFaceAnalyzer.cacheKey(first): a.faces!, PhotoFaceAnalyzer.cacheKey(album): []]).write(to: file)
        let analyzer = PhotoFaceAnalyzer(file: file), audit = FillDecodeAudit()
        let store = PhotoImageStore(decode: { request in await audit.record(request.asset.url); return nil }, faceAnalyzer: analyzer)
        let known = await store.cachedFaceAssets([first,album])
        #expect(known.count == 2 && known[0].faces == a.faces && known[1].faces == [])
        #expect(store.facesReady(known))
        #expect(await audit.urls.isEmpty)
        album.modifiedAt += 1
        #expect(await store.cachedFaceAssets([album]).isEmpty)
        first.fileSize += 1
        #expect(await store.cachedFaceAssets([first]).isEmpty)
    }

    @Test(arguments: ["enabled", "ordered", "perDisplay", "disabled", "decodeFailure"])
    func scenePreparationOptimizesLazilyAndKeepsOriginalWhenUnavailable(_ variant: String) async throws {
        let audit = FillDecodeAudit(), good = good
        let pixels = try #require(AmbientProcessor.image(Array(repeating: UInt8(255), count: 64), width: 4, height: 4))
        let images = PhotoImageStore(decode: { request in
            await audit.record(request.asset.url)
            return variant == "decodeFailure" && request.asset.url == good.url ? nil : DecodedPhoto(image: pixels)
        })
        var settings = WallSettings()
        settings.galleryScrollEnabled = false; settings.verticalPanEnabled = false; settings.horizontalPanEnabled = false; settings.zoomEnabled = false
        settings.randomOrder = variant != "ordered"; settings.galleryPerDisplay = variant == "perDisplay"
        settings.avoidFaceDisplayBoundaries = variant != "disabled"
        var unknown = bad; unknown = PhotoAsset(url: URL(filePath: "/fill/unknown.jpg"), pixelWidth: unknown.pixelWidth, pixelHeight: unknown.pixelHeight)
        let controller = WallPlaybackController(imageStore: images)
        let scene = WallScene(id: 10, mode: .gallery, assets: [a,bad], displayRegions: displays)
        controller.start(assets: [a,bad,good,unknown], settings: settings, viewport: viewport, now: 0, scene: scene, externallyManaged: true)
        defer { controller.stop() }
        for _ in 0..<2000 {
            controller.update(now: 0)
            if !controller.waitingForImages { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(!controller.waitingForImages)
        let selected = try #require(controller.currentScene?.assets)
        let decoded = await audit.urls
        if variant == "enabled" { #expect(selected.contains(good)); #expect(decoded.contains(good.url)) }
        else { #expect(selected == [a,bad]) }
        #expect(!decoded.contains(unknown.url))
        #expect(decoded.count <= 3)
        if !["enabled", "decodeFailure"].contains(variant) { #expect(!decoded.contains(good.url)) }
        let before = controller.presentation(now: 0)
        controller.setPaused(true, now: 0); controller.update(now: 100)
        #expect(controller.presentation(now: 100) == before)
        controller.stop()
        #expect(images.displayedImages.isEmpty)
    }

    @Test func cancelledGeometryAndStoppedPreparationDoNotAdoptCandidatesOrPinImages() async throws {
        let processor = GalleryCompositionProcessor(), photos = [a,bad], candidates = [good], v = viewport, d = displays
        let task = Task { try await processor.improve(photos, candidates: candidates, viewport: v, gap: 8, displays: d) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled layout trial completed") } catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
        let images = PhotoImageStore(decode: { _ in
            try? await Task.sleep(for: .milliseconds(20))
            return nil
        })
        let controller = WallPlaybackController(imageStore: images)
        controller.start(assets: photos + candidates, settings: WallSettings(), viewport: v, scene: WallScene(id: 1, mode: .gallery, assets: photos, displayRegions: d), externallyManaged: true)
        controller.stop()
        try await Task.sleep(for: .milliseconds(30))
        #expect(controller.currentScene == nil && images.displayedImages.isEmpty)
    }
    @Test func periodicReplacementImprovesOnlyDueSlotAndPreservesOtherPhotos() async throws {
        let alternate = PhotoAsset(url: URL(filePath: "/fill/d.jpg"), pixelWidth: good.pixelWidth, pixelHeight: good.pixelHeight, faces: good.faces)
        let photos = [a,good,bad,alternate]
        var settings = WallSettings()
        settings.galleryMinSeconds = 5; settings.galleryMaxSeconds = 5; settings.glassBackground = false
        let excluded: Set<URL> = [a.url,good.url]
        let seed = try #require((UInt64(0)..<30).first { seed in
            let selector = PhotoSelector(seed: seed)
            return selector.pick(from: photos, settings: settings, excluding: excluded) == bad
        })
        let pixels = try #require(AmbientProcessor.image(Array(repeating: UInt8(255), count: 64), width: 4, height: 4))
        let images = PhotoImageStore(decode: { _ in DecodedPhoto(image: pixels) })
        let controller = WallPlaybackController(imageStore: images)
        controller.start(assets: [a,good], settings: settings, viewport: viewport, seed: seed, now: 0,
            scene: WallScene(id: 20, mode: .gallery, assets: [a,good], displayRegions: displays), externallyManaged: true)
        defer { controller.stop() }
        for _ in 0..<2000 {
            controller.update(now: 0)
            if !controller.waitingForImages { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(controller.currentScene?.assets == [a,good])
        // The first slot cannot change at its deadline. Add candidates afterwards,
        // so only the second slot is due during this optimization.
        controller.update(now: 6.3)
        controller.updateLibrary(assets: photos, now: 7)
        for _ in 0..<2000 {
            controller.update(now: 9.3)
            if controller.slots[1].previousAsset != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(controller.slots[1].asset == alternate)
        #expect(controller.slots[1].previousAsset == good && controller.slots[0].asset == a)
        #expect(controller.presentation(now: 9.3)?.galleryLayout != nil)
        controller.setPaused(true, now: 9.4)
        let frozen = controller.presentation(now: 9.4)
        controller.update(now: 100)
        #expect(controller.presentation(now: 100) == frozen)
    }

}
