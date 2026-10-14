import CoreGraphics
import Foundation
import Testing
@testable import DynamicPhotoWall

struct DynamicPhotoWallTests {
    @Test func supportedPhotoExtensionsIncludeWindowsFormats() {
        #expect(PhotoLibrary.supportedExtensions.contains("jpg"))
        #expect(PhotoLibrary.supportedExtensions.contains("png"))
        #expect(PhotoLibrary.supportedExtensions.contains("webp"))
    }

    @Test func photoScanFindsSupportedFilesRecursively() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let nestedURL = rootURL.appending(path: "Nested", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(
            at: nestedURL,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let imageData = try #require(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        )
        try imageData.write(to: rootURL.appending(path: "first.JPG"))
        try imageData.write(to: nestedURL.appending(path: "second.png"))
        try Data().write(to: rootURL.appending(path: "notes.txt"))

        let photos = await PhotoLibrary.scan(folderURL: rootURL)

        #expect(photos.count == 2)
        #expect(photos.contains { $0.url.lastPathComponent == "first.JPG" })
        #expect(photos.contains { $0.url.lastPathComponent == "second.png" })
        #expect(photos.allSatisfy { $0.pixelWidth == 1 && $0.pixelHeight == 1 })
    }

    @Test func scenePlannerUsesEligibleAspectRatios() {
        let portrait = PhotoAsset(
            url: URL(filePath: "/portrait.jpg"),
            pixelWidth: 800,
            pixelHeight: 1_600
        )
        let landscape = PhotoAsset(
            url: URL(filePath: "/landscape.jpg"),
            pixelWidth: 2_400,
            pixelHeight: 1_000
        )
        let assets = [portrait, landscape]

        let viewport = CGSize(width: 1_920, height: 1_080)
        var settings = WallSettings()
        settings.galleryEnabled = false
        settings.galleryScrollEnabled = false
        settings.horizontalPanEnabled = false
        settings.zoomEnabled = false
        let verticalScene = WallScenePlanner.scene(
            index: 0,
            assets: assets,
            settings: settings,
            viewport: viewport,
            seed: 42
        )

        settings.verticalPanEnabled = false
        settings.zoomEnabled = true
        let zoomScene = WallScenePlanner.scene(
            index: 0,
            assets: assets,
            settings: settings,
            viewport: viewport,
            seed: 42
        )

        settings.zoomEnabled = false
        settings.horizontalPanEnabled = true
        let horizontalScene = WallScenePlanner.scene(
            index: 0,
            assets: assets,
            settings: settings,
            viewport: viewport,
            seed: 42
        )

        #expect(verticalScene.mode == .verticalPan)
        #expect(verticalScene.assets == [portrait])
        #expect(zoomScene.mode == .zoom)
        #expect(zoomScene.assets == [landscape])
        #expect(horizontalScene.mode == .horizontalPan)
        #expect(horizontalScene.assets == [landscape])
    }

    @Test func playbackPositionStartsCrossfadeNearSceneEnd() {
        let asset = PhotoAsset(
            url: URL(filePath: "/photo.jpg"),
            pixelWidth: 1_920,
            pixelHeight: 1_080
        )

        var settings = WallSettings()
        settings.galleryEnabled = false
        settings.galleryScrollEnabled = false
        settings.verticalPanEnabled = false
        settings.horizontalPanEnabled = false
        settings.zoomEnabled = true
        let viewport = CGSize(width: 1_920, height: 1_080)
        let middle = WallPlaybackPosition.resolve(
            elapsed: settings.zoomSeconds / 2,
            assets: [asset],
            settings: settings,
            viewport: viewport,
            seed: 42
        )
        let nearEnd = WallPlaybackPosition.resolve(
            elapsed: settings.zoomSeconds - 0.3,
            assets: [asset],
            settings: settings,
            viewport: viewport,
            seed: 42
        )

        #expect(middle.currentScene.id == 0)
        #expect(middle.transitionProgress == 0)
        #expect(nearEnd.transitionProgress > 0)
        #expect(nearEnd.nextScene.id == 1)
    }

    @Test func galleryLayoutPreservesAspectAndStaysInsideViewport() {
        let assets = [
            PhotoAsset(url: URL(filePath: "/portrait.jpg"), pixelWidth: 800, pixelHeight: 1_600),
            PhotoAsset(url: URL(filePath: "/landscape.jpg"), pixelWidth: 2_400, pixelHeight: 1_000)
        ]
        let viewport = CGSize(width: 1_920, height: 1_080)
        let frames = GalleryLayout.frames(assets: assets, in: viewport, gap: 8)

        #expect(frames.count == 2)
        #expect(abs(frames[0].width / frames[0].height - assets[0].aspectRatio) < 0.001)
        #expect(abs(frames[1].width / frames[1].height - assets[1].aspectRatio) < 0.001)
        #expect(frames.allSatisfy { $0.minX >= 0 && $0.maxX <= viewport.width })
        #expect(frames.allSatisfy { $0.minY >= 0 && $0.maxY <= viewport.height })
    }

    @Test func sceneSequenceChangesWithPlaybackSeed() {
        let assets = [
            PhotoAsset(url: URL(filePath: "/portrait.jpg"), pixelWidth: 800, pixelHeight: 1_600),
            PhotoAsset(url: URL(filePath: "/landscape.jpg"), pixelWidth: 2_400, pixelHeight: 1_000),
            PhotoAsset(url: URL(filePath: "/square.jpg"), pixelWidth: 1_200, pixelHeight: 1_200)
        ]
        let settings = WallSettings()
        let viewport = CGSize(width: 1_920, height: 1_080)
        let first = (0..<20).map {
            WallScenePlanner.scene(
                index: $0,
                assets: assets,
                settings: settings,
                viewport: viewport,
                seed: 1
            ).mode
        }
        let repeated = (0..<20).map {
            WallScenePlanner.scene(
                index: $0,
                assets: assets,
                settings: settings,
                viewport: viewport,
                seed: 1
            ).mode
        }
        let second = (0..<20).map {
            WallScenePlanner.scene(
                index: $0,
                assets: assets,
                settings: settings,
                viewport: viewport,
                seed: 2
            ).mode
        }

        #expect(first == repeated)
        #expect(first != second)
    }

    @Test func photoSelectorExcludesDisplayedPhotosAndAvoidsImmediateRepeats() throws {
        let assets = (0..<5).map {
            PhotoAsset(url: URL(filePath: "/\($0).jpg"), pixelWidth: 100, pixelHeight: 200)
        }
        var settings = WallSettings()
        settings.recentCount = 20
        let selector = PhotoSelector(seed: 10)
        var previous: URL?

        for _ in 0..<100 {
            let selected = try #require(selector.pick(
                from: assets,
                settings: settings,
                excluding: [assets[4].url]
            ))
            #expect(selected.url != assets[4].url)
            #expect(selected.url != previous)
            previous = selected.url
        }
    }

    @Test func photoSelectorSequentialModeSortsAndWraps() throws {
        let assets = ["c", "a", "b"].map {
            PhotoAsset(url: URL(filePath: "/\($0).jpg"), pixelWidth: 100, pixelHeight: 200)
        }
        var settings = WallSettings()
        settings.randomOrder = false
        settings.recentCount = 0
        let selector = PhotoSelector(seed: 1)

        let selected = try (0..<4).map { _ in
            try #require(selector.pick(from: assets, settings: settings)).url.lastPathComponent
        }
        #expect(selected == ["a.jpg", "b.jpg", "c.jpg", "a.jpg"])
    }

    @Test func photoSelectorNeverRelaxesDisplayedPhotoExclusion() {
        let asset = PhotoAsset(url: URL(filePath: "/only.jpg"), pixelWidth: 100, pixelHeight: 200)
        let selector = PhotoSelector(seed: 1)
        #expect(selector.pick(from: [asset], settings: WallSettings(), excluding: [asset.url]) == nil)
    }

    @Test func verticalPanUsesWindowsEndpointsAndPhysicalSpeed() {
        var settings = WallSettings()
        settings.panWidthFraction = 1
        settings.panPixelsPerSecond = 120
        let asset = PhotoAsset(
            url: URL(filePath: "/portrait.jpg"),
            pixelWidth: 1_200,
            pixelHeight: 1_800
        )
        let plan = WallMotionGeometry.plan(
            for: .verticalPan,
            asset: asset,
            viewport: CGSize(width: 3_840, height: 1_100),
            settings: settings
        )

        #expect(plan.width == 3_840)
        #expect(plan.height == 5_760)
        #expect(plan.fromY == -4_660)
        #expect(plan.toY == 0)
        #expect(abs((plan.toY - plan.fromY) / plan.seconds - 120) < 0.001)
        #expect(plan.frame(at: 0).minY == -4_660)
        #expect(plan.frame(at: 1).minY == 0)
    }

    @Test func horizontalPanPreservesAspectAndMovesEdgeToEdge() {
        var settings = WallSettings()
        settings.panPixelsPerSecond = 120
        let asset = PhotoAsset(
            url: URL(filePath: "/wide.jpg"),
            pixelWidth: 8_000,
            pixelHeight: 1_000
        )
        let plan = WallMotionGeometry.plan(
            for: .horizontalPan,
            asset: asset,
            viewport: CGSize(width: 3_840, height: 1_100),
            settings: settings
        )

        #expect(plan.width == 8_800)
        #expect(plan.height == 1_100)
        #expect(plan.fromX == 0)
        #expect(plan.toX == -4_960)
        #expect(abs(plan.width / plan.height - asset.aspectRatio) < 0.001)
    }

    @Test func zoomUsesMinimumAspectFillWithoutDistortion() {
        let asset = PhotoAsset(
            url: URL(filePath: "/landscape.jpg"),
            pixelWidth: 4_096,
            pixelHeight: 3_463
        )
        let viewport = CGSize(width: 3_840, height: 1_100)
        let plan = WallMotionGeometry.plan(
            for: .zoom,
            asset: asset,
            viewport: viewport,
            settings: WallSettings()
        )

        #expect(plan.width >= viewport.width)
        #expect(plan.height >= viewport.height)
        #expect(abs(plan.width / plan.height - asset.aspectRatio) < 0.001)
        #expect(plan.fromX <= 0)
        #expect(plan.fromY <= 0)
    }
}
