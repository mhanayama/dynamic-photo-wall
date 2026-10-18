import CoreGraphics
import Foundation
import Testing
@testable import DynamicPhotoWall

@MainActor
struct PlaybackRegressionTests {
    private let viewport = CGSize(width: 1920, height: 1080)
    private var photos: [PhotoAsset] {
        (0..<7).map { PhotoAsset(url: URL(filePath: "/\($0).jpg"), pixelWidth: 2400, pixelHeight: 1600) }
    }
    private var zoomOnly: WallSettings {
        var settings = WallSettings()
        settings.galleryEnabled = false
        settings.galleryScrollEnabled = false
        settings.verticalPanEnabled = false
        settings.horizontalPanEnabled = false
        return settings
    }

    @Test func wideGallerySupportsTwentyPhotosAndPreservesSharedSettings() throws {
        var settings = WallSettings(); settings.randomOrder = false
        settings.galleryScrollEnabled = false; settings.verticalPanEnabled = false
        settings.horizontalPanEnabled = false; settings.zoomEnabled = false
        let assets = (0..<40).map { PhotoAsset(url: URL(filePath: "/fixture/\($0).jpg"), pixelWidth: 800, pixelHeight: 1600) }
        let wide = CGSize(width: 15360, height: 1080)
        for limit in [1, 5, 12, 20] {
            settings.galleryMax = limit; settings.normalize()
            let scene = try #require(WallScenePlanner(seed: 42).next(assets: assets, settings: settings, viewport: wide))
            #expect(scene.assets.count == limit); #expect(Set(scene.assets.map(\.url)).count == limit)
            let frames = GalleryLayout.frames(assets: scene.assets, in: wide, gap: settings.gap)
            #expect(frames.count == limit)
            #expect(frames.allSatisfy { $0.width > 0 && $0.height > 0 && $0.minX >= 0 && $0.minY >= 0 && $0.maxX <= wide.width + 1e-7 && $0.maxY <= wide.height + 1e-7 })
        }
        #expect(try PNOptions(settings).applying().galleryMax == 20)
        #expect(try PNWire.decode(WallSettings.self, PNWire.encode(settings)).galleryMax == 20)
        #expect(throws: (any Error).self) { try PNOptions(values: ["galleryMax": .integer(21)]).validate() }
        settings.galleryMax = 21; settings.normalize(); #expect(settings.galleryMax == 20)
    }

    @Test func disabledOrIneligibleModesNeverFallBackToGallery() {
        var settings = zoomOnly
        settings.zoomEnabled = false
        #expect(WallScenePlanner(seed: 42).next(assets: photos, settings: settings, viewport: viewport) == nil)
        settings.zoomEnabled = true
        settings.zoomWeight = 0
        #expect(WallScenePlanner(seed: 42).next(assets: photos, settings: settings, viewport: viewport) == nil)
        settings.zoomWeight = 20
        let portrait = PhotoAsset(url: URL(filePath: "/p.jpg"), pixelWidth: 800, pixelHeight: 1600)
        #expect(WallScenePlanner(seed: 42).next(assets: [portrait], settings: settings, viewport: viewport) == nil)
    }

    @Test func actualPlannerSequentialModeVisitsAllSevenPhotos() throws {
        var settings = zoomOnly
        settings.randomOrder = false
        settings.recentCount = 0
        let planner = WallScenePlanner(seed: 42)
        let names = try (0..<8).map { _ in
            try #require(planner.next(assets: Array(photos.reversed()), settings: settings, viewport: viewport)).assets[0].url.lastPathComponent
        }
        #expect(names == ["0.jpg", "1.jpg", "2.jpg", "3.jpg", "4.jpg", "5.jpg", "6.jpg", "0.jpg"])
    }

    @Test func plannerAvoidsThreeRepeatedModesAndKeepsSingleModeRunning() throws {
        var settings = WallSettings()
        settings.galleryScrollEnabled = false
        let planner = WallScenePlanner(seed: 42)
        var history: [WallMode] = []
        for _ in 0..<1000 {
            history.append(try #require(planner.next(assets: photos, settings: settings, viewport: viewport)).mode)
        }
        #expect(!(2..<history.count).contains { history[$0] == history[$0 - 1] && history[$0] == history[$0 - 2] })
        let single = WallScenePlanner(seed: 42)
        for _ in 0..<10 { #expect(single.next(assets: photos, settings: zoomOnly, viewport: viewport)?.mode == .zoom) }
    }

    @Test func ineligibleEnabledHorizontalPanDoesNotChangeTheModeSequence() {
        let portrait = PhotoAsset(url: URL(filePath: "/p.jpg"), pixelWidth: 800, pixelHeight: 1600)
        var settings = zoomOnly
        settings.verticalPanEnabled = true
        let withEnabledHorizontal = WallScenePlanner(seed: 42)
        let withoutHorizontal = WallScenePlanner(seed: 42)
        var enabled = settings
        enabled.horizontalPanEnabled = true
        let assets = photos + [portrait]
        let first = (0..<1000).map { _ in withEnabledHorizontal.next(assets: assets, settings: enabled, viewport: viewport)?.mode }
        let second = (0..<1000).map { _ in withoutHorizontal.next(assets: assets, settings: settings, viewport: viewport)?.mode }
        #expect(first == second)
    }

    @Test func currentImagesAreExcludedButSmallLibrariesStillPlay() throws {
        let planner = WallScenePlanner(seed: 42)
        let excluded = Set(photos.prefix(6).map(\.url))
        let scene = try #require(planner.next(assets: photos, settings: zoomOnly, viewport: viewport, excluding: excluded))
        #expect(scene.assets == [photos[6]])
        #expect(planner.next(assets: [photos[0]], settings: zoomOnly, viewport: viewport, excluding: [photos[0].url]) != nil)
        var settings = WallSettings()
        settings.galleryScrollEnabled = false
        settings.verticalPanEnabled = false
        settings.horizontalPanEnabled = false
        settings.zoomEnabled = false
        let portrait = PhotoAsset(url: URL(filePath: "/p.jpg"), pixelWidth: 800, pixelHeight: 1600)
        let gallery = try #require(planner.next(assets: photos + [portrait], settings: settings, viewport: viewport))
        #expect(gallery.assets.first == portrait)
        #expect(Set(gallery.assets.map(\.url)).count == gallery.assets.count)
    }

    @Test func nextAfterAutomaticAdvancesNeverRewindsAndPauseFreezesTime() throws {
        let playback = WallPlaybackController()
        let settings = zoomOnly
        playback.start(assets: photos, settings: settings, viewport: viewport, seed: 42, now: 0)
        let duration = settings.zoomSeconds + settings.fadeSeconds
        for index in 1...3 { playback.update(now: (duration + 0.01) * Double(index)) }
        #expect(playback.currentScene?.id == 3)
        playback.next(now: duration * 3 + 1)
        #expect(playback.currentScene?.id == 4)
        playback.setPaused(true, now: duration * 3 + 2)
        let frozen = try #require(playback.presentation(now: duration * 3 + 2))
        playback.update(now: 10000)
        #expect(playback.presentation(now: 10000) == frozen)
        playback.next(now: 10000)
        #expect(playback.currentScene?.id == 5)
        playback.setPaused(false, now: 20000)
        #expect(playback.presentation(now: 20001)?.elapsed == 1)
    }

    @Test func galleryUpdatesOnlyDueSlotWithoutRepeatingVisiblePhotos() throws {
        var settings = WallSettings()
        settings.galleryScrollEnabled = false
        settings.verticalPanEnabled = false
        settings.horizontalPanEnabled = false
        settings.zoomEnabled = false
        settings.galleryMax = 2
        settings.galleryMinSeconds = 5
        settings.galleryMaxSeconds = 5
        let playback = WallPlaybackController()
        playback.start(assets: photos, settings: settings, viewport: viewport, seed: 42, now: 0)
        let initial = try #require(playback.currentScene).assets
        playback.update(now: 5 + settings.fadeSeconds)
        let updated = try #require(playback.currentScene).assets
        #expect(updated[0] != initial[0])
        #expect(updated[1] == initial[1])
        #expect(!initial.contains(updated[0]))
        #expect(playback.slots[0].previousAsset == initial[0])
    }

    @Test func horizontalGalleryStartsFilledAndStreamsAtTheConfiguredSpeed() throws {
        var settings = WallSettings()
        settings.galleryEnabled = false
        settings.verticalPanEnabled = false
        settings.horizontalPanEnabled = false
        settings.zoomEnabled = false
        let playback = WallPlaybackController()
        playback.start(assets: photos, settings: settings, viewport: viewport, seed: 42, now: 0)
        #expect(playback.presentation(now: 0)?.scrollDistance == 0)
        #expect(playback.presentation(now: 2)?.scrollDistance == 80)
        let initial = try #require(playback.currentScene).assets
        let height = viewport.height - 2 * settings.gap
        let exitsAt = (settings.gap + height * initial[0].aspectRatio) / settings.galleryScrollPixelsPerSecond
        playback.update(now: exitsAt + 0.01)
        let streamed = try #require(playback.currentScene).assets
        #expect(streamed.first == initial[1])
        #expect(Set(streamed.map(\.url)).count == streamed.count)
        #expect(!initial.contains(try #require(streamed.last)))
    }

    @Test func physicalPixelPlanDoesNotDependOnPointViewport() {
        let asset = PhotoAsset(url: URL(filePath: "/p.jpg"), pixelWidth: 800, pixelHeight: 1600)
        let physical = CGSize(width: 3840, height: 2160)
        let plan = WallMotionGeometry.plan(for: .verticalPan, asset: asset, viewport: physical, settings: WallSettings())
        #expect(abs((plan.toY - plan.fromY) / plan.seconds - 120) < 0.001)
        #expect(!WallScenePlanner.isEligible(asset, for: .verticalPan, settings: WallSettings(), viewport: physical))
    }

    @Test func olderSettingsKeepValuesAndFillMissingKeys() throws {
        let data = Data(##"{"recentCount":7,"backgroundHex":"#112233"}"##.utf8)
        let settings = try JSONDecoder().decode(WallSettings.self, from: data)
        #expect(settings.recentCount == 7)
        #expect(settings.backgroundHex == "#112233")
        #expect(settings.panPixelsPerSecond == 120)
        var invalid = settings
        invalid.panPixelsPerSecond = .nan
        invalid.galleryMaxSeconds = .infinity
        invalid.normalize()
        #expect(invalid.panPixelsPerSecond.isFinite)
        #expect(invalid.galleryMaxSeconds.isFinite)
        invalid.zoomEnabled = false
        invalid.galleryEnabled = false
        invalid.galleryScrollEnabled = false
        invalid.verticalPanEnabled = false
        invalid.horizontalPanEnabled = false
        #expect(throws: WallSettings.ValidationError.self) { try invalid.validate() }
    }
    @Test func nextAtExpiredSceneAdvancesOnlyOnce() throws {
        var settings = WallSettings()
        settings.galleryEnabled = false; settings.galleryScrollEnabled = false
        settings.verticalPanEnabled = false; settings.horizontalPanEnabled = false
        let assets = (0..<5).map { PhotoAsset(url: URL(filePath: "/boundary/\($0).jpg"), pixelWidth: 1920, pixelHeight: 1080) }
        let playback = WallPlaybackController()
        defer { playback.stop() }
        playback.start(assets: assets, settings: settings, viewport: CGSize(width: 1920, height: 1080), seed: 42, now: 0)
        playback.next(now: settings.zoomSeconds + settings.fadeSeconds)
        #expect(playback.currentScene?.id == 1)
    }

    @Test func fadeUsesWindowsSineEaseAndShortFacePanIsVerticallyCentered() throws {
        #expect(abs(WallAnimation.ease(0.25) - 0.1464466094067262) < 1e-12)
        #expect(abs(WallAnimation.ease(0.75) - 0.8535533905932737) < 1e-12)
        let viewport = CGSize(width: 1920, height: 1080)
        let photo = PhotoAsset(url: URL(filePath: "/face-close.jpg"), pixelWidth: 800, pixelHeight: 2400,
            faces: [FaceRegion(x: 0, y: 0, width: 1, height: 1)])
        let p = WallScenePresentation(scene: WallScene(id: 0, mode: .verticalPan, assets: [photo]), progress: 0, elapsed: 0, slots: [], scrollDistance: 0)
        let placement = try #require(ForegroundGeometry.placements(p, settings: WallSettings(), viewport: viewport).first)
        #expect(abs(placement.frame.midY - viewport.height / 2) < 1e-7)
        let plan = WallMotionGeometry.plan(for: .verticalPan, asset: photo, viewport: viewport, settings: WallSettings())
        #expect(WallMotionGeometry.duration(for: p.scene, viewport: viewport, settings: WallSettings()) == plan.seconds + 3)
    }

}
