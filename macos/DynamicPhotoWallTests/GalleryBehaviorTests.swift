import Foundation
import CoreGraphics
import Testing
@testable import DynamicPhotoWall

@MainActor struct GalleryBehaviorTests {
    private func photo(_ id: Int, _ width: Int = 600, _ height: Int = 1800, faces: [FaceRegion] = []) -> PhotoAsset {
        PhotoAsset(url: URL(filePath: "/fixture/behavior-\(id).jpg"), pixelWidth: width, pixelHeight: height, faces: faces)
    }
    @Test func mirroredPansCenterThePhotographInsteadOfItsOffCenterFace() throws {
        let asset = photo(0, 2000, 6000, faces: [FaceRegion(x: 0.65, y: 0.15, width: 0.12, height: 0.4)])
        for viewport in [CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 1024)] {
            let plan = try #require(FaceMotionSafety.plan(for: .verticalPan, asset: asset, viewport: viewport, settings: WallSettings()))
            #expect(abs(plan.fromX + plan.width / 2 - viewport.width / 2) < 0.001)
        }
        let gallery = photo(1, 300, 1000, faces: [FaceRegion(x: 0.2, y: 0.2, width: 0.2, height: 0.2)])
        let frame = try #require(FixedGalleryLayout.arrange([gallery], viewport: CGSize(width: 3000, height: 1000), gap: 8,
            displays: (0..<3).map { CGRect(x: $0 * 1000, y: 0, width: 1000, height: 1000) }).first).frame
        #expect(abs(frame.midX - 1500) < 0.001)
    }
    @Test func vacantPaddingAddsWithoutResizingOrRemovingExistingCards() throws {
        let assets = (0..<3).map { photo($0) }
        let change = try #require(FixedGalleryLayout.update(assets, incoming: photo(4), viewport: CGSize(width: 4000, height: 1080),
            gap: 8, displays: [], replacement: 0, maximum: 5))
        #expect(change.isAddition && change.items.count == 4)
        #expect(assets.allSatisfy { change.assets.contains($0) })
        #expect(change.items.allSatisfy { $0.frame.height == 1064 })
        #expect(FixedGalleryLayout.update(assets, incoming: assets[0], viewport: CGSize(width: 4000, height: 1080),
            gap: 8, displays: [], replacement: 0, maximum: 5) == nil)
    }
    @Test func flagsRotateOldCardsAndVisitEveryPhotoWithHistoryDisabled() throws {
        let rotation = GalleryRotation(); var active = (0..<4).map { photo($0) }; var originals = Set(active.map(\.url))
        for i in 0..<4 {
            let eligible = rotation.eligible(active)
            let index = try #require(active.firstIndex { eligible.contains($0.url) })
            #expect(originals.remove(active[index].url) != nil)
            active[index] = photo(10 + i); rotation.inserted(active[index])
        }
        var settings = WallSettings(); settings.recentCount = 0
        let selector = PhotoSelector(seed: 1), library = (0..<12).map { photo($0) }
        for _ in 0..<3 {
            let round = try (0..<12).map { _ in try #require(selector.pick(from: library, settings: settings)).url }
            #expect(Set(round).count == 12)
        }
    }
    @Test func skippedSingleGalleryKeepsUpdatingWithoutChangingTheScene() throws {
        var settings = WallSettings()
        settings.galleryScrollEnabled = false; settings.verticalPanEnabled = false
        settings.horizontalPanEnabled = false; settings.zoomEnabled = false
        let playback = WallPlaybackController()
        playback.start(assets: (0..<30).map { photo($0) }, settings: settings, viewport: CGSize(width: 1920, height: 1080), seed: 7, now: 0)
        defer { playback.stop() }
        let first = try #require(playback.currentScene)
        for tick in 1...2200 { playback.update(now: Double(tick) / 20) }
        #expect(playback.currentScene?.id == first.id && !playback.isWaiting)
        #expect(playback.currentScene?.assets != first.assets)
    }
}
