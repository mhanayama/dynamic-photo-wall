import AppKit
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DynamicPhotoWall

@MainActor
struct FullParityRegressionTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "DPW-Parity-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func bitmap(red: UInt8 = 255, blue: UInt8 = 0) throws -> CGImage {
        try #require(AmbientProcessor.image(Array(repeating: [red, 0, blue, 255], count: 64).flatMap { $0 }, width: 8, height: 8))
    }

    @Test func draftRemovalAndScreenChangeCanBeCancelledAndOnlySavePersists() async throws {
        let profile = UUID().uuidString
        let model = AppModel.makeUITestModel(profile: profile)
        defer { model.shutdown(); UserDefaults(suiteName: "DynamicPhotoWall.UITests.\(profile)")!.removePersistentDomain(forName: "DynamicPhotoWall.UITests.\(profile)") }
        let original = model.folders
        model.removeFolders(ids: [original[0].id])
        model.selectedScreenID = 999
        model.settings.randomOrder = false
        model.cancelDraft()
        #expect(model.folders.map(\.id) == original.map(\.id))
        #expect(model.selectedScreenID == 1)
        #expect(model.settings.randomOrder)
        model.removeFolders(ids: Set(original.map(\.id)))
        model.saveSettings()
        #expect(model.folders.isEmpty)
        model.cancelDraft()
        #expect(model.folders.isEmpty)
        let restored = AppModel.makeUITestModel(profile: profile)
        defer { restored.shutdown() }
        #expect(restored.folders.isEmpty)
    }

    @Test func atomicSettingsRecoverPreviousDocumentAndPreserveInvalidBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "DPW-Settings-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let file = directory.appending(path: "settings.json")
        let repository = SettingsRepository(defaults: defaults, file: file)
        var first = SettingsSnapshot(settings: WallSettings(), screenID: 2, folders: [PhotoFolder(bookmark: Data([1]), path: "/offline")])
        try repository.save(first)
        first.screenID = 3
        try repository.save(first)
        let invalid = Data("{broken".utf8)
        try invalid.write(to: file)
        let restored = SettingsRepository(defaults: defaults, file: file)
        let snapshot = try #require(restored.load())
        #expect(snapshot.screenID == 2)
        #expect(snapshot.folders.first?.bookmark == Data([1]))
        #expect(restored.warning != nil)
        #expect(defaults.data(forKey: "configurationSnapshot.invalid") == invalid)
        #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).contains { $0.lastPathComponent.contains("invalid-") })
    }

    @Test func failedAtomicSaveLeavesLastConfigurationIntact() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "DPW-FailedSave-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let repository = SettingsRepository(defaults: defaults, file: directory) // A directory cannot become a JSON file.
        #expect(throws: (any Error).self) { try repository.save(.init(settings: WallSettings(), screenID: 2, folders: [])) }
        #expect(defaults.data(forKey: SettingsRepository.key) == nil)
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func occlusionOnlyPausesForOneForegroundWindowOnTheTargetDisplay() {
        let target = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let other = ForegroundWindow(ownerPID: 2, layer: 0, alpha: 1, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(!WindowOcclusion.covers(target, windows: [other], foregroundPID: 2, ownPID: 1))
        let covering = ForegroundWindow(ownerPID: 2, layer: 0, alpha: 1, bounds: target)
        #expect(WindowOcclusion.covers(target, windows: [covering], foregroundPID: 2, ownPID: 1))
        #expect(!WindowOcclusion.covers(target, windows: [covering], foregroundPID: 1, ownPID: 1))
        #expect(!WindowOcclusion.covers(target, windows: [covering], foregroundPID: 3, ownPID: 1))
        #expect(!WindowOcclusion.covers(target, windows: [other, covering], foregroundPID: 2, ownPID: 1))
    }

    @Test func watcherDebouncesAndStopsDeliveryAfterShutdown() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var events = 0
        let watcher = PhotoFolderWatcher { events += 1 }
        watcher.watch([directory])
        defer { watcher.stop() }
        for i in 0..<5 { try Data([1]).write(to: directory.appending(path: "\(i).jpg")) }
        for _ in 0..<40 {
            if events > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(events == 1)
        watcher.stop()
        try Data([2]).write(to: directory.appending(path: "after.jpg"))
        try await Task.sleep(for: .milliseconds(1300))
        #expect(events == 1)
    }

    @Test func ambientFollowsVisiblePhotoAndTemporallyBlendsWithoutDarkPadding() async throws {
        let red = try bitmap(), blue = try bitmap(red: 0, blue: 255)
        let processor = AmbientProcessor()
        let viewport = CGSize(width: 1920, height: 1080)
        let narrow = CGRect(x: 800, y: 200, width: 300, height: 700)
        let first = try #require(await processor.render(cards: [.init(image: red, frame: narrow, opacity: 1, radius: 0)], viewport: viewport))
        #expect(first.image.width == 160)
        #expect(first.image.height == 90)
        let second = try #require(await processor.render(cards: [.init(image: blue, frame: narrow, opacity: 1, radius: 0)], viewport: viewport))
        let a = try rgba(first.image), b = try rgba(second.image)
        #expect(a[0] > 240 && a[2] < 10 && a[3] == 255)
        #expect(abs(Int(b[0]) - 127) < 10 && abs(Int(b[2]) - 127) < 10)
        #expect(await processor.render(cards: [], viewport: viewport) == nil)
    }

    @Test func ambientUsesPanCropAndScrollPositionRatherThanOriginalWholePhoto() async throws {
        var pixels = [UInt8]()
        for y in 0..<64 {
            for _ in 0..<16 { pixels += y < 32 ? [255, 0, 0, 255] : [0, 0, 255, 255] }
        }
        let split = try #require(AmbientProcessor.image(pixels, width: 16, height: 64))
        let viewport = CGSize(width: 160, height: 90)
        let top = try #require(await AmbientProcessor().render(cards: [.init(image: split, frame: CGRect(x: 0, y: 0, width: 160, height: 640), opacity: 1, radius: 0)], viewport: viewport))
        let bottom = try #require(await AmbientProcessor().render(cards: [.init(image: split, frame: CGRect(x: 0, y: -550, width: 160, height: 640), opacity: 1, radius: 0)], viewport: viewport))
        let a = try rgba(top.image), b = try rgba(bottom.image)
        #expect(a[0] > 230 && b[2] > 230)
    }

    @Test func ambientSamplerStopsWhenPausedOrDisposed() async throws {
        let asset = PhotoAsset(url: URL(filePath: "/ambient/red.png"), pixelWidth: 8, pixelHeight: 8)
        let decoded = DecodedPhoto(image: try bitmap())
        let images = PhotoImageStore(decode: { _ in decoded })
        #expect(await images.prepare([asset]))
        let p = WallScenePresentation(scene: WallScene(id: 0, mode: .zoom, assets: [asset]), progress: 0, elapsed: 0, slots: [], scrollDistance: 0)
        let sampler = AmbientSampler()
        sampler.update(p, settings: WallSettings(), viewport: CGSize(width: 1920, height: 1080), images: images, paused: true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(sampler.updateCount == 0)
        sampler.update(p, settings: WallSettings(), viewport: CGSize(width: 1920, height: 1080), images: images, paused: false)
        sampler.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(sampler.updateCount == 0)
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { data in
            let context = try #require(CGContext(data: data.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    @Test func realJPEGAllEightEXIFOrientationsDecodeCorrectCornerPixels() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var pixels = [UInt8]()
        let colors: [[UInt8]] = [[255,0,0,255], [0,255,0,255], [0,0,255,255], [255,255,0,255]]
        for y in 0..<32 { for x in 0..<48 { pixels += colors[(y < 16 ? 0 : 2) + (x < 24 ? 0 : 1)] } }
        let original = try #require(AmbientProcessor.image(pixels, width: 48, height: 32))
        let expected = [[0,1,2,3], [1,0,3,2], [3,2,1,0], [2,3,0,1], [0,2,1,3], [2,0,3,1], [3,1,2,0], [1,3,0,2]]
        for orientation in 1...8 {
            let url = directory.appending(path: "\(orientation).jpg")
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, original, [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
        }
        let photos = await PhotoLibrary.scan(folderURL: directory)
        #expect(photos.count == 8)
        for asset in photos {
            let orientation = asset.orientation
            #expect(asset.pixelWidth == (orientation >= 5 ? 32 : 48))
            let result = try #require(await PhotoImageDecoder().decode(.init(asset, desiredWidth: 48)))
            let bytes = try rgba(result.image), w = result.image.width, h = result.image.height
            let points = [(3,3), (w-4,3), (3,h-4), (w-4,h-4)]
            for (corner, point) in points.enumerated() {
                let i = (point.1 * w + point.0) * 4
                let wanted = colors[expected[orientation-1][corner]]
                for c in 0..<3 { #expect(abs(Int(bytes[i+c]) - Int(wanted[c])) < 35) }
            }
        }
    }
    @Test func metadataCachePersistsAndInvalidatesChangedFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "metadata.json")
        let asset = PhotoAsset(url: directory.appending(path: "a.jpg"), pixelWidth: 2400, pixelHeight: 1600, fileSize: 100, modifiedAt: 10)
        let cache = PhotoMetadataCache(file: file)
        await cache.store(asset); await cache.flush()
        let restored = PhotoMetadataCache(file: file)
        #expect(await restored.find(asset.url, size: 100, modified: 10) == asset)
        #expect(await restored.find(asset.url, size: 101, modified: 10) == nil)
        #expect(await restored.find(asset.url, size: 100, modified: 11) == nil)
    }

    @Test func visionNoFaceResultPersistsWithoutChangingMotion() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "faces.json")
        let asset = PhotoAsset(url: directory.appending(path: "red.png"), pixelWidth: 8, pixelHeight: 8)
        let image = DecodedPhoto(image: try bitmap())
        let analyzer = PhotoFaceAnalyzer(file: file)
        #expect(await analyzer.analyze(asset, image: image).isEmpty)
        await analyzer.flush()
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(await PhotoFaceAnalyzer(file: file).analyze(asset, image: image).isEmpty)
    }

    @Test func userPauseSurvivesOcclusionRemoval() async throws {
        let profile = UUID().uuidString
        let model = AppModel.makeUITestModel(profile: profile)
        defer { model.shutdown(); UserDefaults(suiteName: "DynamicPhotoWall.UITests.\(profile)")!.removePersistentDomain(forName: "DynamicPhotoWall.UITests.\(profile)") }
        for _ in 0..<1000 {
            if !model.isScanning { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        model.updateOcclusion(true)
        #expect(model.playback.isPaused)
        model.togglePause()
        model.updateOcclusion(false)
        #expect(model.userPaused && model.playback.isPaused)
        model.togglePause()
        #expect(!model.playback.isPaused)
    }

    @Test func loginRegistrationAndStartOnLaunchAreIndependentAndFailuresDoNotSave() {
        let name = "DPW-Login-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var registered = false
        var failRegistration = false
        let service = LoginItemService(status: { registered ? "registered" : "off" }, setEnabled: {
            if failRegistration { throw CocoaError(.fileWriteNoPermission) }
            registered = $0
        })
        let model = AppModel(defaults: defaults, playback: WallPlaybackController(), screenProvider: { [] }, observeEnvironment: false, loginItems: service)
        defer { model.shutdown() }
        model.settings.autoStart = true; model.settings.startOnLaunch = false
        model.saveSettings()
        #expect(registered)
        #expect(!model.desiredRunning)
        #expect(model.loginItemStatus == "registered")
        let snapshot = SettingsRepository(defaults: defaults).load()
        #expect(snapshot?.settings.autoStart == true && snapshot?.settings.startOnLaunch == false)
        let saved = defaults.data(forKey: SettingsRepository.key)
        failRegistration = true
        model.settings.autoStart = false
        model.saveSettings()
        #expect(registered)
        #expect(defaults.data(forKey: SettingsRepository.key) == saved)
        model.cancelDraft()
        #expect(model.settings.autoStart)
    }

    @Test func realPNGAndHEICDecodeAndRecursiveScanExcludesCorruptFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let nested = directory.appending(path: "Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let image = try bitmap()
        for (type, root, name) in [(UTType.png, directory, "red.png"), (UTType.heic, nested, "red.heic")] {
            let destination = try #require(CGImageDestinationCreateWithURL(root.appending(path: name) as CFURL, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        try Data("broken".utf8).write(to: directory.appending(path: "broken.jpg"))
        #expect(await PhotoLibrary.scan(folderURL: directory, recursive: false).count == 1)
        let photos = await PhotoLibrary.scan(folderURL: directory, recursive: true)
        #expect(photos.count == 2)
        for photo in photos { #expect(await PhotoImageDecoder().decode(.init(photo, desiredWidth: 8)) != nil) }
    }

    @Test func singleInstanceLockExcludesSecondOwnerAndCanBeReleased() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "instance.lock")
        let first = SingleInstance(), second = SingleInstance()
        defer { first.release(); second.release() }
        #expect(first.acquire(file: file))
        #expect(!second.acquire(file: file))
        first.release()
        #expect(second.acquire(file: file))
    }

    @Test func logRotatesAndKeepsOnePreviousGeneration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        WallLog.write(String(repeating: "first ", count: 30), directory: directory, maximumBytes: 100)
        await WallLog.flush()
        WallLog.write("second", directory: directory, maximumBytes: 100)
        await WallLog.flush()
        #expect(try String(contentsOf: directory.appending(path: "app.log.1"), encoding: .utf8).contains("first"))
        #expect(try String(contentsOf: directory.appending(path: "app.log"), encoding: .utf8).contains("second"))
    }

    private func fixture(_ name: String, extension suffix: String) throws -> URL {
        try #require(Bundle(for: ImageFixtureBundle.self).url(forResource: name, withExtension: suffix))
    }

    @Test func realWebPAndHEIFContainersDecode() async throws {
        let source = try fixture("hopper", extension: "webp")
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: source, to: directory.appending(path: "hopper.webp"))
        let heif = directory.appending(path: "test.heif")
        let destination = try #require(CGImageDestinationCreateWithURL(heif as CFURL, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try bitmap(), nil)
        #expect(CGImageDestinationFinalize(destination))
        let photos = await PhotoLibrary.scan(folderURL: directory)
        #expect(photos.count == 2)
        for photo in photos { #expect(await PhotoImageDecoder().decode(.init(photo, desiredWidth: 128)) != nil) }
        #expect(photos.first { $0.url.pathExtension == "webp" }?.pixelWidth == 128)
    }

    @Test func realFaceDetectionUsesUprightPixelsForAllEXIFDirections() async throws {
        let source = try #require(CGImageSourceCreateWithURL(try fixture("astronaut", extension: "png") as CFURL, nil))
        let original = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let inverse: [UInt32] = [1,2,3,4,5,8,7,6]
        let analyzer = PhotoFaceAnalyzer(file: directory.appending(path: "faces.json"))
        var baseline: FaceRegion?
        for orientation in 1...8 {
            let rotated = CIImage(cgImage: original).oriented(try #require(CGImagePropertyOrientation(rawValue: inverse[orientation-1])))
            let raw = try #require(context.createCGImage(rotated, from: rotated.extent))
            let url = directory.appending(path: "face-\(orientation).jpg")
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, raw, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
            let asset = PhotoAsset(url: url, pixelWidth: 512, pixelHeight: 512, orientation: orientation)
            let image = try #require(await PhotoImageDecoder().decode(.init(asset, desiredWidth: 512)))
            let faces = await analyzer.analyze(asset, image: image)
            #expect(!faces.isEmpty)
            #expect(faces.allSatisfy { $0.isValid })
            let face = try #require(faces.max { $0.width * $0.height < $1.width * $1.height })
            #expect(face.y < 0.4)
            if let baseline {
                #expect(abs(face.x-baseline.x) < 0.06 && abs(face.y-baseline.y) < 0.06)
            } else { baseline = face }
        }
        await analyzer.flush()
    }

    @Test func cacheBudgetEvictsLRUButKeepsDisplayedPixelsAlive() async throws {
        let canvas = try #require(CGContext(data: nil, width: 2048, height: 2048, bitsPerComponent: 8, bytesPerRow: 2048*4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let decoded = DecodedPhoto(image: try #require(canvas.makeImage()))
        let images = PhotoImageStore(decode: { _ in decoded })
        let photos = (0..<5).map { PhotoAsset(url: URL(filePath: "/cache/\($0).jpg"), pixelWidth: 2048, pixelHeight: 2048) }
        images.setDisplayedAssets([photos[0]], cacheMegabytes: 64)
        #expect(await images.prepare(photos))
        #expect(images.cacheByteCount <= 64*1024*1024)
        #expect(images.image(for: photos[0]) != nil)
        images.setDisplayedAssets([], cacheMegabytes: 64)
        #expect(images.image(for: photos[0]) == nil)
        #expect(images.isReady(Array(photos.suffix(4))))
    }

    @Test func ambientTracksScrollAndGalleryReplacementColors() async throws {
        let redAsset = PhotoAsset(url: URL(filePath: "/red.png"), pixelWidth: 8, pixelHeight: 8)
        let blueAsset = PhotoAsset(url: URL(filePath: "/blue.png"), pixelWidth: 8, pixelHeight: 8)
        let red = try bitmap(), blue = try bitmap(red: 0, blue: 255)
        var settings = WallSettings(); settings.gap = 0; settings.cornerRadius = 0
        let viewport = CGSize(width: 90, height: 90)
        func sample(_ p: WallScenePresentation) async throws -> [UInt8] {
            let cards = ForegroundGeometry.placements(p, settings: settings, viewport: viewport).map {
                AmbientCard(image: $0.asset.url == redAsset.url ? red : blue, frame: $0.frame, opacity: $0.opacity, radius: $0.cornerRadius)
            }
            return try rgba(try #require(await AmbientProcessor().render(cards: cards, viewport: viewport)).image)
        }
        let scroll = WallScene(id: 0, mode: .horizontalGallery, assets: [redAsset, blueAsset])
        let before = try await sample(.init(scene: scroll, progress: 0, elapsed: 0, slots: [], scrollDistance: 0))
        let after = try await sample(.init(scene: scroll, progress: 0, elapsed: 1, slots: [], scrollDistance: 90))
        #expect(before[0] > 240 && before[2] < 10)
        #expect(after[0] < 10 && after[2] > 240)
        let gallery = WallScene(id: 1, mode: .gallery, assets: [blueAsset])
        let slot = GallerySlot(id: 0, asset: blueAsset, previousAsset: redAsset, changedAt: 0, nextReplacementAt: 30)
        let start = try await sample(.init(scene: gallery, progress: 0, elapsed: 0, slots: [slot], scrollDistance: 0))
        let end = try await sample(.init(scene: gallery, progress: 0, elapsed: settings.fadeSeconds, slots: [slot], scrollDistance: 0))
        #expect(start[0] > 240 && end[2] > 240)
    }

    @Test func overlappingGalleryLayoutChangesStartFromCurrentFrame() {
        let a = CGRect(x: 0, y: 0, width: 200, height: 100)
        let b = CGRect(x: 100, y: 50, width: 100, height: 200)
        let first = GalleryFrameTransition(from: [a], to: [b], startedAt: 0)
        let middle = first.frames(elapsed: 0.6, duration: 1.2)
        let next = GalleryFrameTransition(from: middle, to: [a], startedAt: 0.6)
        #expect(next.frames(elapsed: 0.6, duration: 1.2) == middle)
        #expect(next.frames(elapsed: 1.8, duration: 1.2) == [a])
    }

    @Test func savedNilScreenDoesNotResurrectLegacySelection() throws {
        let name = "DPW-NilScreen-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(2, forKey: "selectedScreenID")
        try SettingsRepository(defaults: defaults).save(.init(settings: WallSettings(), screenID: nil, folders: []))
        let model = AppModel(defaults: defaults, playback: WallPlaybackController(), screenProvider: { [] }, observeEnvironment: false)
        defer { model.shutdown() }
        #expect(!model.hasSavedScreen)
        #expect(!model.desiredRunning)
        #expect(model.selectedScreenID == nil)
    }

    @Test func duplicateFolderIDsArePreservedAsInvalidAndRequireExplicitRecovery() throws {
        let name = "DPW-InvalidFolders-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let record = PhotoFolder(bookmark: Data([1]), path: "/offline")
        let data = try JSONEncoder().encode([record, record])
        defaults.set(data, forKey: FolderBookmarkStore.recordsKey)
        let store = FolderBookmarkStore(defaults: defaults)
        defer { store.shutdown() }
        #expect(store.hasInvalidStoredData)
        #expect(store.folders.isEmpty)
        #expect(defaults.data(forKey: FolderBookmarkStore.recordsKey) == data)
        store.recoverInvalidStoredData()
        #expect(!store.hasInvalidStoredData)
        #expect(defaults.data(forKey: FolderBookmarkStore.recordsKey + ".invalid") == data)
    }

}

private final class ImageFixtureBundle: NSObject {}
