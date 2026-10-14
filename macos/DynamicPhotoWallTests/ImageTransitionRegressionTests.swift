import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import DynamicPhotoWall

private actor HeldPhotoDecoder {
    private var blocked: Set<URL>
    private var waiters: [URL: [CheckedContinuation<Void, Never>]] = [:]
    private(set) var calls = 0

    init(blocked: Set<URL>) { self.blocked = blocked }

    func decode(_ asset: PhotoAsset) async -> DecodedPhoto? {
        calls += 1
        if blocked.contains(asset.url) {
            await withCheckedContinuation { continuation in
                waiters[asset.url, default: []].append(continuation)
            }
        }
        return Self.bitmap()
    }

    func block(_ url: URL) { blocked.insert(url) }

    func release(_ url: URL) {
        blocked.remove(url)
        for waiter in waiters.removeValue(forKey: url) ?? [] { waiter.resume() }
    }

    nonisolated static func bitmap() -> DecodedPhoto? {
        guard let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage().map { DecodedPhoto(image: $0) }
    }
}

@MainActor
struct ImageTransitionRegressionTests {
    private let viewport = CGSize(width: 1920, height: 1080)
    private var photos: [PhotoAsset] {
        (0..<6).map { PhotoAsset(url: URL(filePath: "/transition/\($0).jpg"), pixelWidth: 1920, pixelHeight: 1080) }
    }
    private var zoomOnly: WallSettings {
        var settings = WallSettings()
        settings.galleryEnabled = false
        settings.galleryScrollEnabled = false
        settings.verticalPanEnabled = false
        settings.horizontalPanEnabled = false
        settings.randomOrder = false
        settings.recentCount = 0
        return settings
    }

    @Test func slowDecodeKeepsOldBitmapOpaqueAndStartsFadeOnlyWhenReady() async throws {
        let decoder = HeldPhotoDecoder(blocked: [photos[1].url])
        let images = PhotoImageStore(decode: { await decoder.decode($0.asset) })
        #expect(await images.prepare([photos[0]]))
        let playback = WallPlaybackController(imageStore: images)
        defer { playback.stop() }
        playback.start(assets: photos, settings: zoomOnly, viewport: viewport, seed: 42, now: 0)
        let old = try #require(images.image(for: photos[0]))
        let initialLayerID = try #require(playback.layers(now: 0).first).id
        playback.next(now: 1)
        playback.update(now: 100)
        #expect(playback.waitingForImages)
        #expect(playback.layers(now: 100).map(\.id) == [initialLayerID, initialLayerID + 1])
        #expect(playback.layers(now: 100).map(\.opacity) == [1, 0])
        #expect(images.image(for: photos[0]) === old)
        #expect(playback.outgoing?.scene.assets == [photos[0]])
        await decoder.release(photos[1].url)
        #expect(await images.prepare([photos[1]]))
        playback.update(now: 101)
        #expect(!playback.waitingForImages)
        #expect(playback.transitionProgress(now: 101) == 0)
        #expect(abs(playback.transitionProgress(now: 101.6) - 0.5) < 0.001)
        #expect(images.image(for: photos[0]) === old)
        playback.update(now: 103)
        #expect(playback.outgoing == nil)
        #expect(playback.layers(now: 103).map(\.opacity) == [1])
    }

    @Test func rapidNextDuringLoadingDoesNotReplaceOldLayerWithAnEmptyOne() async throws {
        let decoder = HeldPhotoDecoder(blocked: [photos[1].url, photos[2].url])
        let images = PhotoImageStore(decode: { await decoder.decode($0.asset) })
        #expect(await images.prepare([photos[0]]))
        let playback = WallPlaybackController(imageStore: images)
        defer { playback.stop() }
        playback.start(assets: photos, settings: zoomOnly, viewport: viewport, seed: 42, now: 0)
        let old = try #require(images.image(for: photos[0]))
        playback.next(now: 1)
        playback.next(now: 2)
        playback.update(now: 100)
        #expect(playback.outgoing?.scene.id == 0)
        #expect(playback.layers(now: 100).first?.opacity == 1)
        #expect(images.image(for: photos[0]) === old)
        await decoder.release(photos[1].url)
        await decoder.release(photos[2].url)
        let current = try #require(playback.currentScene)
        #expect(await images.prepare(current.assets))
        playback.update(now: 101)
        #expect(playback.outgoing?.scene.id == 0)
    }

    @Test func galleryKeepsSlotAndBackgroundPhotoUntilReplacementHasDecoded() async throws {
        let decoder = HeldPhotoDecoder(blocked: [photos[2].url])
        let images = PhotoImageStore(decode: { await decoder.decode($0.asset) })
        #expect(await images.prepare(Array(photos.prefix(2))))
        var settings = zoomOnly
        settings.zoomEnabled = false
        settings.galleryEnabled = true
        settings.galleryMax = 2
        settings.galleryMinSeconds = 5
        settings.galleryMaxSeconds = 10
        let playback = WallPlaybackController(imageStore: images)
        defer { playback.stop() }
        playback.start(assets: photos, settings: settings, viewport: viewport, seed: 42, now: 0)
        let old = try #require(images.image(for: photos[0]))
        playback.update(now: 5)
        playback.update(now: 7)
        #expect(playback.slots[0].asset == photos[0])
        #expect(playback.currentScene?.assets.first == photos[0])
        #expect(playback.slots[0].previousAsset == nil)
        #expect(images.image(for: photos[0]) === old)
        await decoder.release(photos[2].url)
        #expect(await images.prepare([photos[2]]))
        playback.update(now: 7.5)
        #expect(playback.slots[0].asset == photos[2])
        #expect(playback.slots[0].previousAsset == photos[0])
        #expect(playback.slots[0].changedAt == 7.5)
        #expect(images.image(for: photos[0]) === old)
    }

    @Test func failedIncomingImageSkipsItAndRetainsTheLastGoodScene() async throws {
        let good = photos[0]
        let bad = photos[1]
        let images = PhotoImageStore(decode: { asset in
            asset.asset.url == good.url ? HeldPhotoDecoder.bitmap() : nil
        })
        #expect(await images.prepare([good]))
        let playback = WallPlaybackController(imageStore: images)
        defer { playback.stop() }
        playback.start(assets: [good, bad], settings: zoomOnly, viewport: viewport, seed: 42, now: 0)
        playback.next(now: 1)
        #expect(!(await images.prepare([bad])))
        playback.update(now: 3)
        #expect(playback.currentScene?.assets == [good])
        #expect(playback.outgoing?.scene.assets == [good])
        #expect(playback.layers(now: 3).first?.opacity == 1)
    }

    @Test func simultaneousRequestsShareDecodeAndFileUpdateInvalidatesTheKey() async throws {
        let decoder = HeldPhotoDecoder(blocked: [photos[0].url])
        let images = PhotoImageStore(decode: { await decoder.decode($0.asset) })
        let asset = photos[0]
        images.setDisplayedAssets([asset], cacheMegabytes: 64)
        let first = Task { await images.prepare([asset]) }
        let second = Task { await images.prepare([asset]) }
        // Both requests are enqueued before releasing the decoder.
        for _ in 0..<1000 {
            if await decoder.calls > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await decoder.calls == 1)
        await decoder.release(asset.url)
        #expect(await first.value)
        #expect(await second.value)
        #expect(await decoder.calls == 1)
        var updated = asset
        updated.modifiedAt += 1
        #expect(images.image(for: updated) == nil)
        #expect(await images.prepare([updated]))
        #expect(await decoder.calls == 2)
        #expect(images.image(for: asset) != nil)
    }
    @Test func updatedFileVersionRetainsOldPixelsDuringTheNewDecode() async throws {
        let original = photos[0]
        let decoder = HeldPhotoDecoder(blocked: [])
        let images = PhotoImageStore(decode: { await decoder.decode($0.asset) })
        #expect(await images.prepare([original]))
        let playback = WallPlaybackController(imageStore: images)
        defer { playback.stop() }
        playback.start(assets: [original], settings: zoomOnly, viewport: viewport, seed: 42, now: 0)
        let old = try #require(images.image(for: original))
        var changed = original
        changed.modifiedAt = 1
        await decoder.block(original.url)
        playback.updateLibrary(assets: [changed], now: 10)
        playback.update(now: 20)
        #expect(playback.outgoing?.scene.assets == [original])
        #expect(playback.layers(now: 20).map(\.opacity) == [1, 0])
        #expect(images.image(for: original) === old)
        await decoder.release(original.url)
        #expect(await images.prepare([changed]))
        playback.update(now: 21)
        #expect(!playback.waitingForImages)
        #expect(images.image(for: original) === old)
    }

    @Test func scrollWaitsForPreparedIncomingPhotoWithoutEmptyingTheStrip() async throws {
        let decoder = HeldPhotoDecoder(blocked: [photos[2].url])
        let images = PhotoImageStore(decode: { await decoder.decode($0.asset) })
        #expect(await images.prepare(Array(photos.prefix(2))))
        var settings = zoomOnly
        settings.zoomEnabled = false
        settings.galleryScrollEnabled = true
        let playback = WallPlaybackController(imageStore: images)
        defer { playback.stop() }
        playback.start(assets: photos, settings: settings, viewport: viewport, seed: 42, now: 0)
        let initial = try #require(playback.currentScene).assets
        playback.update(now: 100)
        #expect(playback.currentScene?.assets == initial)
        #expect(playback.presentation(now: 100)?.scrollDistance == 0)
        #expect(images.isReady(initial))
        await decoder.release(photos[2].url)
        #expect(await images.prepare([photos[2]]))
        playback.update(now: 101)
        #expect(playback.currentScene?.assets.first == photos[0])
        #expect(playback.currentScene?.assets.last == photos[2])
        #expect(Set(playback.currentScene?.assets.map(\.url) ?? []).count == playback.currentScene?.assets.count)
        #expect(playback.presentation(now: 102)?.scrollDistance == 40)
        playback.update(now: 151)
        let streamed = try #require(playback.currentScene).assets
        #expect(streamed.first == photos[1])
        #expect(streamed.last == photos[2])
        #expect(images.isReady(streamed))
    }

    @Test func failedScrollCandidateIsNeverAddedToTheVisibleStrip() async throws {
        let bad = photos[2]
        let images = PhotoImageStore(decode: { request in
            request.asset.url == bad.url ? nil : HeldPhotoDecoder.bitmap()
        })
        #expect(await images.prepare(Array(photos.prefix(2))))
        var settings = zoomOnly
        settings.zoomEnabled = false
        settings.galleryScrollEnabled = true
        let playback = WallPlaybackController(imageStore: images)
        defer { playback.stop() }
        playback.start(assets: photos, settings: settings, viewport: viewport, seed: 42, now: 0)
        #expect(!(await images.prepare([bad])))
        playback.update(now: 1)
        #expect(await images.prepare([photos[3]]))
        playback.update(now: 2)
        playback.update(now: 60)
        let streamed = try #require(playback.currentScene).assets
        #expect(!streamed.contains(bad))
        #expect(streamed.last == photos[3])
        #expect(images.isReady(streamed))
    }

    @Test func retryAfterAllFailuresUsesTheOriginalLibraryAgain() async throws {
        let decoder = RepairablePhotoDecoder()
        let images = PhotoImageStore(decode: { await decoder.decode($0) })
        let playback = WallPlaybackController(imageStore: images)
        defer { playback.stop() }
        playback.start(assets: Array(photos.prefix(2)), settings: zoomOnly, viewport: viewport, seed: 42, now: 0)
        for index in 1...3 {
            if let scene = playback.currentScene { _ = await images.prepare(scene.assets) }
            playback.update(now: Double(index))
        }
        #expect(playback.currentScene == nil)
        #expect(playback.isWaiting)
        #expect(playback.hasSession)
        await decoder.repair()
        playback.next(now: 10)
        let retried = try #require(playback.currentScene)
        #expect(await images.prepare(retried.assets))
        playback.update(now: 11)
        #expect(!playback.isWaiting)
        #expect(!playback.waitingForImages)
    }

}

private actor RepairablePhotoDecoder {
    private var repaired = false
    func repair() { repaired = true }
    func decode(_ request: PhotoDecodeRequest) -> DecodedPhoto? {
        repaired ? HeldPhotoDecoder.bitmap() : nil
    }
}
