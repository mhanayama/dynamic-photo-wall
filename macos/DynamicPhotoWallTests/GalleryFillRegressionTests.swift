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
    func scenePreparationUsesFixedSizeWithoutDecodingUnselectedCandidates(_ variant: String) async throws {
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
        let expected = FixedGalleryLayout.arrange([a,bad], viewport: viewport, gap: settings.gap,
            displays: settings.avoidFaceDisplayBoundaries ? displays : []).map { [a,bad][$0.index] }
        #expect(selected == expected)
        let frames = try #require(controller.presentation(now: 0)?.galleryLayout).to
        #expect(frames.allSatisfy { $0.height == viewport.height - 2 * settings.gap })
        #expect(!decoded.contains(unknown.url))
        #expect(decoded.count <= 2)
        #expect(!decoded.contains(good.url))
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
    @Test func managedGalleryWaitsForOneGroupShuffleAndFreezesAfterPause() async throws {
        let portraits = (0..<8).map { PhotoAsset(url: URL(filePath: "/fill/portrait-\($0).jpg"), pixelWidth: 400, pixelHeight: 800, faces: []) }
        var settings = WallSettings(); settings.glassBackground = false
        settings.galleryMinSeconds = 5; settings.galleryMaxSeconds = 5
        let pixels = try #require(AmbientProcessor.image(Array(repeating: UInt8(255), count: 64), width: 4, height: 4))
        let images = PhotoImageStore(decode: { _ in DecodedPhoto(image: pixels) })
        let controller = WallPlaybackController(imageStore: images)
        controller.start(assets: portraits, settings: settings, viewport: viewport, seed: 1, now: 0,
            scene: WallScene(id: 20, mode: .gallery, assets: Array(portraits.prefix(2)), displayRegions: displays), externallyManaged: true)
        defer { controller.stop() }
        for _ in 0..<2000 {
            controller.update(now: 0)
            if !controller.waitingForImages { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let initial = try #require(controller.currentScene).assets
        controller.update(now: 20)
        #expect(controller.currentScene?.assets == initial) // A managed surface has no independent timer.
        #expect(controller.shuffleGallery(now: 20))
        for _ in 0..<2000 {
            controller.update(now: 20)
            if controller.slots.contains(where: { $0.appearing }) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(controller.slots.count == initial.count + 1)
        #expect(initial.allSatisfy { asset in controller.slots.contains { $0.asset.url == asset.url } })
        #expect(controller.slots.filter { $0.appearing && $0.previousAsset == nil }.count == 1)
        #expect(!controller.shuffleGallery(now: 20.1))
        let p = try #require(controller.presentation(now: 20.1))
        #expect(p.galleryLayout?.to.allSatisfy { $0.height == viewport.height - 2 * settings.gap } == true)
        controller.setPaused(true, now: 20.2)
        let frozen = controller.presentation(now: 20.2)
        controller.update(now: 100)
        #expect(controller.presentation(now: 100) == frozen)
    }

}
