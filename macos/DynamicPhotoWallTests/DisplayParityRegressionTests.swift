import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DynamicPhotoWall

@MainActor
private final class MultiWallHost: DesktopWallHosting {
    var outputs: [DesktopWallOutput] = []
    var failNext = false
    func show(on screen: ScreenDescriptor, playback: WallPlaybackController) {}
    func present(_ outputs: [DesktopWallOutput]) throws {
        if failNext { failNext = false; throw CocoaError(.fileReadUnknown) }
        self.outputs = outputs
    }
    func close() { outputs = [] }
}

@MainActor
private final class DisplayInventory {
    var screens: [ScreenDescriptor]
    init(_ screens: [ScreenDescriptor]) { self.screens = screens }
}

@MainActor
struct DisplayParityRegressionTests {
    private func display(_ id: UInt32, x: Double = 0, y: Double = 0, width: Double = 1920,
                         height: Double = 1080, group: String? = "連結", enabled: Bool = true) -> WallDisplay {
        WallDisplay(id: id, name: "画面\(id)", x: x, y: y, width: width, height: height, enabled: enabled, groupID: group)
    }
    private func screen(_ id: UInt32, x: Double = 0, scale: Double = 1) -> ScreenDescriptor {
        ScreenDescriptor(id: id, name: "画面\(id)", frame: CGRect(x: x, y: 0, width: 1920 / scale, height: 1080 / scale), pixelWidth: 1920, pixelHeight: 1080)
    }
    private func photo(_ name: String = "p", width: Int = 3000, height: Int = 6000, faces: [FaceRegion]? = nil) -> PhotoAsset {
        PhotoAsset(url: URL(filePath: "/isolated/\(name).jpg"), pixelWidth: width, pixelHeight: height, faces: faces)
    }
    private func only(_ mode: WallMode, perDisplay: Bool = false) -> WallSettings {
        var s = WallSettings()
        for m in WallMode.allCases where m != mode { s.disable(m) }
        s.galleryPerDisplay = perDisplay; s.galleryScrollPerDisplay = perDisplay
        s.verticalPanPerDisplay = perDisplay; s.horizontalPanPerDisplay = perDisplay; s.zoomPerDisplay = perDisplay
        s.glassBackground = false
        return s
    }
    private func profile() -> (UserDefaults, String) {
        let name = "DPW-DisplayParity-\(UUID())"
        return (UserDefaults(suiteName: name)!, name)
    }
    private func awaitScan(_ model: AppModel) async throws {
        for _ in 0..<1000 { if !model.isScanning { return }; try await Task.sleep(for: .milliseconds(1)) }
        throw CocoaError(.fileReadUnknown)
    }

    @Test func groupCoordinatesPreserveNegativeOffsetsGapsAndIndependentIdentity() throws {
        let list = [display(1, x: 1920, y: -100), display(2, x: -100, y: 100), display(3, x: 100000, group: nil)]
        let groups = try DisplayLayout.groups(list)
        #expect(groups.count == 2)
        #expect(groups[0].viewport == CGSize(width: 3940, height: 1280))
        #expect(groups[0].region(list[0]) == CGRect(x: 2020, y: 0, width: 1920, height: 1080))
        #expect(groups[1].viewport.width == 1920)
        #expect(try DisplayLayout.groups([display(1, group: "2"), display(2, group: nil)]).count == 2)
        #expect(try DisplayLayout.groups([display(1, group: "A"), display(2, group: "a")]).count == 2)
        #expect(try DisplayLayout.groups([display(1, group: " "), display(2, group: nil)]).count == 2)
        #expect(throws: (any Error).self) { try DisplayLayout.groups([display(1, width: -1)]) }
        #expect(throws: (any Error).self) { try DisplayLayout.groups([display(1), display(2, x: 32768)]) }
        #expect(throws: (any Error).self) { try DisplayLayout.groups([display(1, x: .infinity)]) }
    }

    @Test func legacySnapshotRetainsAlbumsBookmarksAndNewDefaults() throws {
        let json = """
        {"schemaVersion":1,"screenID":999,"settings":{"autoStart":true},"folders":[{"id":"00000000-0000-0000-0000-000000000001","bookmark":"AQ==","path":"/offline"}],"photoAlbums":[{"id":"album","title":"旅行"}]}
        """
        let value = try JSONDecoder().decode(SettingsSnapshot.self, from: Data(json.utf8))
        #expect(value.displays == nil)
        #expect(value.screenID == 999)
        #expect(value.settings.faceAwarePanDirection && value.settings.avoidFaceDisplayBoundaries)
        #expect(WallMode.allCases.allSatisfy { !value.settings.perDisplay($0) })
        #expect(value.settings.autoStart && value.folders[0].bookmark == Data([1]))
        #expect(value.photoAlbums[0].id == "album")
    }

    @Test func emptyAndAssignedGroupDeletionStaysDraftAndDoesNotReappear() throws {
        let (defaults, name) = profile(); defer { defaults.removePersistentDomain(forName: name) }
        let repository = SettingsRepository(defaults: defaults)
        let list = [display(1), display(2, group: "連結", enabled: false)]
        try repository.save(.init(settings: WallSettings(), screenID: 1, folders: [], displays: list, displayGroupNames: ["連結", "空"]))
        let model = AppModel(defaults: defaults, host: MultiWallHost(), playback: WallPlaybackController(), screenProvider: { [screen(1)] }, observeEnvironment: false)
        defer { model.shutdown() }
        model.deleteDisplayGroup("連結"); model.deleteDisplayGroup("空"); model.refreshScreens()
        #expect(model.displayGroupNames.isEmpty)
        #expect(model.displays.allSatisfy { $0.groupID == nil })
        #expect(model.displays[1].enabled == false)
        model.cancelDraft()
        #expect(model.displayGroupNames == ["連結", "空"])
        model.deleteDisplayGroup("連結"); model.deleteDisplayGroup("空"); model.saveSettings()
        let saved = try #require(repository.load())
        #expect(saved.displayGroupNames.isEmpty && saved.displays?.allSatisfy { $0.groupID == nil } == true)
        model.refreshScreens(); #expect(model.displayGroupNames.isEmpty)
        model.addDisplayGroup(); #expect(model.displayGroupNames == ["グループ1"])
        model.addDisplayGroup(); model.deleteDisplayGroup("グループ1"); model.addDisplayGroup()
        #expect(model.displayGroupNames == ["グループ2", "グループ1"])
    }

    @Test func testPatternNeedsNoPhotosDoesNotSaveAndSurvivesDraftCancellation() throws {
        let (defaults, name) = profile(); defer { defaults.removePersistentDomain(forName: name) }
        let host = MultiWallHost(), screens = [screen(1), screen(2, x: 1920, scale: 2)]
        let model = AppModel(defaults: defaults, host: host, playback: WallPlaybackController(), screenProvider: { screens }, observeEnvironment: false)
        defer { model.shutdown() }
        let before = defaults.data(forKey: SettingsRepository.key)
        model.displays = [display(1, x: 1920), display(2, x: -100, y: -50)]
        model.toggleTestPattern()
        #expect(model.testPatternVisible && host.outputs.count == 2)
        #expect(host.outputs[1].group.region(host.outputs[0].display).minX == 2020)
        #expect(host.outputs.map(\.number) == [1, 2])
        #expect(host.outputs.allSatisfy { $0.session == nil })
        model.cancelDraft(); model.refreshScreens()
        #expect(model.testPatternVisible && host.outputs.count == 2)
        #expect(defaults.data(forKey: SettingsRepository.key) == before)
        model.toggleTestPattern()
        #expect(!model.testPatternVisible && !model.desiredRunning && host.outputs.isEmpty)
        model.toggleTestPattern() // Cancel restored an unconfigured draft: no connected selected output.
        model.stop(); #expect(!model.testPatternVisible)
    }

    @Test func testPatternRestoresAppliedPlaybackPauseAndRollsBackOutputFailures() async throws {
        let (defaults, name) = profile(); defer { defaults.removePersistentDomain(forName: name) }
        let host = MultiWallHost(), screens = [screen(1), screen(2, x: 1920)]
        let album = PhotoAlbum(id: "a", title: "A"), p = photo("landscape", width: 2400, height: 1600)
        try SettingsRepository(defaults: defaults).save(.init(settings: only(.gallery), screenID: 1, folders: [], photoAlbums: [album], displays: [display(1, group: nil)]))
        let model = AppModel(defaults: defaults, host: host, playback: WallPlaybackController(), screenProvider: { screens }, observeEnvironment: false,
            albumsClient: PhotosAlbumClient(catalog: { PhotoAlbumCatalog() }, scan: { _ in PhotoAlbumScan(assets: [p]) }))
        defer { model.shutdown() }; try await awaitScan(model)
        model.togglePause(); #expect(model.userPaused)
        let old = try #require(model.sessions.first)
        model.displays = [display(2, x: 500)]
        host.failNext = true; model.toggleTestPattern()
        #expect(!model.testPatternVisible && model.sessions.first === old)
        model.toggleTestPattern(); #expect(model.testPatternVisible && model.userPaused)
        let savedBefore = defaults.data(forKey: SettingsRepository.key)
        model.displays[0].x = 900; model.saveSettings(); try await awaitScan(model)
        #expect(model.testPatternVisible && host.outputs[0].display.x == 500)
        #expect(defaults.data(forKey: SettingsRepository.key) != savedBefore)
        host.failNext = true; model.toggleTestPattern()
        #expect(model.testPatternVisible)
        model.toggleTestPattern()
        #expect(!model.testPatternVisible && model.isPlaying && model.userPaused)
        #expect(host.outputs.map { $0.display.id } == [2])
        #expect(model.playback.isPaused)
        model.toggleTestPattern(); host.failNext = true; model.startApplied(); try await awaitScan(model)
        #expect(model.testPatternVisible && model.userPaused)
        model.startApplied(); try await awaitScan(model)
        #expect(!model.testPatternVisible && !model.userPaused && model.isPlaying)
        model.toggleTestPattern(); model.stop()
        #expect(!model.testPatternVisible && !model.desiredRunning && host.outputs.isEmpty)
    }

    @Test func disconnectedGroupKeepsViewportWhileOtherGroupsContinueAndPreviewReconnects() async throws {
        let (defaults, name) = profile(); defer { defaults.removePersistentDomain(forName: name) }
        let host = MultiWallHost(), inventory = DisplayInventory([screen(1), screen(2), screen(3)])
        let album = PhotoAlbum(id: "a", title: "A"), p = photo()
        try SettingsRepository(defaults: defaults).save(.init(settings: only(.gallery), screenID: 1, folders: [], photoAlbums: [album],
            displays: [display(1, x: 1920), display(2), display(3, group: nil)]))
        let model = AppModel(defaults: defaults, host: host, playback: WallPlaybackController(), screenProvider: { inventory.screens }, observeEnvironment: false,
            albumsClient: PhotosAlbumClient(catalog: { PhotoAlbumCatalog() }, scan: { _ in PhotoAlbumScan(assets: [p]) }))
        defer { model.shutdown() }; try await awaitScan(model)
        #expect(model.sessions.count == 2 && host.outputs.count == 3)
        let independent = try #require(model.sessions.last)
        inventory.screens = [screen(2), screen(3)]; model.refreshScreens()
        #expect(model.sessions.first?.group.viewport.width == 3840)
        #expect(model.sessions.last === independent)
        #expect(host.outputs.map { $0.display.id } == [2, 3])
        inventory.screens = [screen(3)]; model.refreshScreens()
        #expect(model.sessions.count == 1 && model.sessions[0] === independent)
        inventory.screens = [screen(1), screen(2), screen(3)]; model.refreshScreens()
        #expect(model.sessions.count == 2 && model.sessions.last === independent)
        model.stop(); model.toggleTestPattern()
        inventory.screens = []; model.refreshScreens()
        #expect(model.testPatternVisible && !model.wallAttached)
        inventory.screens = [screen(2)]; model.refreshScreens()
        #expect(host.outputs.count == 1 && host.outputs[0].group.viewport.width == 3840)
    }

    @Test(arguments: WallMode.allCases) func perDisplayUsesCommonModeLocalViewportsAndSharedPause(_ mode: WallMode) throws {
        let list = [display(1, width: 1000, height: 600), display(2, width: 1200, height: 800)] // deliberately overlapping
        let group = try #require(DisplayLayout.groups(list).first)
        let assets = (0..<8).map { photo("\($0)", width: mode == .verticalPan ? 1000 : 6000, height: mode == .verticalPan ? 4000 : 1000) }
        let session = WallGroupPlayback(group: group, connected: [1, 2], assets: assets, settings: only(mode, perDisplay: true), imageStore: nil, seed: 2, now: 0)
        defer { session.stop() }
        session.update(now: 0)
        let batch = try #require(session.current)
        #expect(batch.surfaces.map(\.displayID) == [1, 2])
        #expect(batch.surfaces.map { $0.playback.viewport } == list.map { $0.rect.size })
        #expect(batch.surfaces.allSatisfy { $0.playback.currentScene?.mode == mode })
        session.update(now: 2); session.setPaused(true, now: 2)
        let times = batch.surfaces.map { $0.playback.presentation(now: 2)?.elapsed }
        session.update(now: 100)
        #expect(batch.surfaces.map { $0.playback.presentation(now: 100)?.elapsed } == times)
        session.next(now: 100)
        #expect(session.current?.id != batch.id)
        #expect(session.current?.surfaces.allSatisfy { $0.playback.isPaused } == true)
        session.setPaused(false, now: 101)
    }

    @Test func mirrorUsesSamePhotoAndBitmapAndLeavesLargePhotoSpanning() async throws {
        let group = try #require(DisplayLayout.groups([display(1), display(2, x: 1920)]).first)
        let small = photo("small", width: 800, height: 2400), large = photo("large", width: 4000, height: 10000)
        let s = only(.verticalPan)
        #expect(WallScenePlanner.shouldMirror(small, viewport: group.viewport, displays: group.displays, settings: s))
        #expect(!WallScenePlanner.shouldMirror(large, viewport: group.viewport, displays: group.displays, settings: s))
        var exact = s; exact.maxPanUpscale = group.viewport.width * s.panWidthFraction / 800
        #expect(WallScenePlanner.shouldMirror(small, viewport: group.viewport, displays: group.displays, settings: exact))
        #expect(!WallScenePlanner.shouldMirror(photo(width: 1920, height: 5760), viewport: group.viewport, displays: group.displays, settings: s))
        #expect(!WallScenePlanner.shouldMirror(photo(width: 100, height: 1000), viewport: group.viewport, displays: group.displays, settings: s))
        let pixels = try #require(AmbientProcessor.image(Array(repeating: [UInt8(255),0,0,255], count: 16).flatMap { $0 }, width: 4, height: 4))
        let images = PhotoImageStore(decode: { _ in DecodedPhoto(image: pixels) })
        let session = WallGroupPlayback(group: group, connected: [1,2], assets: [small], settings: s, imageStore: images, now: 0)
        defer { session.stop() }
        #expect(await images.prepare([small]))
        session.update(now: 1)
        let batch = try #require(session.current)
        #expect(batch.surfaces.count == 2)
        #expect(batch.surfaces.allSatisfy { $0.playback.currentScene?.assets == [small] })
        let a = try #require(batch.surfaces[0].playback.imageStore?.image(for: small))
        #expect(a === batch.surfaces[1].playback.imageStore?.image(for: small))
        let planner = WallScenePlanner(seed: 1)
        #expect(planner.nextGroup(assets: [large], settings: s, group: group, connected: [1,2])?.first?.displayID == nil)
        #expect(planner.nextGroup(assets: [small], settings: s, group: group, connected: [1])?.count == 1)
    }

    @Test func cacheOwnersRetainOtherGroupsAndAggregateDecodeWidths() async throws {
        let pixels = try #require(AmbientProcessor.image(Array(repeating: UInt8(255), count: 64), width: 4, height: 4))
        let images = PhotoImageStore(decode: { _ in DecodedPhoto(image: pixels) })
        let a = photo("a"), b = photo("b"), first = UUID(), second = UUID()
        images.setDisplayedAssets([a], cacheMegabytes: 64, desiredWidths: [PhotoImageKey(a): 200], owner: first)
        images.setDisplayedAssets([a,b], cacheMegabytes: 64, desiredWidths: [PhotoImageKey(a): 1000, PhotoImageKey(b): 500], owner: second)
        #expect(images.request(for: a).key == PhotoDecodeRequest(a, desiredWidth: 1000).key)
        #expect(await images.prepare([a,b]))
        images.setDisplayedAssets([], cacheMegabytes: 64, owner: first)
        #expect(images.displayedImages.keys.contains { $0.photo == PhotoImageKey(a) })
        #expect(images.displayedImages.keys.contains { $0.photo == PhotoImageKey(b) })
        images.setDisplayedAssets([], cacheMegabytes: 64, owner: second)
        #expect(images.displayedImages.isEmpty)
        #expect(images.cacheByteCount <= 64 * 1024 * 1024)
    }

    @Test func faceDirectionsUseLargestFaceAndKeepStopHoldOutOfMotionTime() {
        let v = CGSize(width: 1000, height: 600)
        var s = WallSettings(); s.panWidthFraction = 1; s.stopAtFace = false
        let top = FaceRegion(x: 0.4, y: 0.05, width: 0.2, height: 0.1)
        let bottom = FaceRegion(x: 0.4, y: 0.85, width: 0.2, height: 0.1)
        for (face, from, to) in [(top, -1400.0, 0.0), (bottom, 0.0, -1400.0)] {
            let p = WallMotionGeometry.plan(for: .verticalPan, asset: photo(width: 1000, height: 2000, faces: [face]), viewport: v, settings: s)
            #expect(p.fromY == from && p.toY == to && abs(p.seconds - 1400 / 120) < 1e-7)
        }
        s.stopAtFace = true
        let asset = photo(width: 1000, height: 2000, faces: [top])
        let p = WallMotionGeometry.plan(for: .verticalPan, asset: asset, viewport: v, settings: s)
        #expect(abs(p.toY + 20) < 1e-7 && abs(p.seconds - 11.5) < 1e-7)
        #expect(abs(WallMotionGeometry.duration(for: WallScene(id: 0, mode: .verticalPan, assets: [asset]), viewport: v, settings: s) - 14.5) < 1e-7)
        let largest = FaceRegion(x: 0.3, y: 0.6, width: 0.3, height: 0.3)
        #expect(WallMotionGeometry.primaryFace(photo(faces: [top, largest])) == largest)
        for x in [0.05, 0.45, 0.85] {
            let a = photo(width: 3000, height: 600, faces: [.init(x: x, y: 0.3, width: 0.1, height: 0.2)])
            let plan = WallMotionGeometry.plan(for: .horizontalPan, asset: a, viewport: v, settings: s, reverse: x >= 0.45)
            #expect(plan.fromX == (x < 0.45 ? -2000 : 0))
            #expect(abs(plan.seconds - 2000 / 120) < 1e-7)
        }
    }
    @Test func shortLocalMotionHoldsUntilLongestSurfaceFinishesAndWaitingKeepsPixels() throws {
        let list = [display(1, width: 1000, height: 600), display(2, x: 1000, width: 1000, height: 1200)]
        let group = try #require(DisplayLayout.groups(list).first)
        let p = photo(width: 1000, height: 4000)
        var s = only(.verticalPan, perDisplay: true); s.stopAtFace = false
        let session = WallGroupPlayback(group: group, connected: [1, 2], assets: [p], settings: s, imageStore: nil, now: 0)
        defer { session.stop() }; session.update(now: 0)
        let batch = try #require(session.current)
        let durations = batch.surfaces.map { $0.playback.sceneDuration }
        let short = try #require(durations.min()), long = try #require(durations.max())
        #expect(short < long)
        session.update(now: short + 0.1)
        #expect(session.current?.id == batch.id)
        let shorter = try #require(batch.surfaces.first { $0.playback.sceneDuration == short })
        #expect(shorter.playback.presentation(now: short + 0.1)?.progress == 1)
        session.updateLibrary([], now: short + 0.2)
        #expect(session.isWaiting && session.current?.id == batch.id)
        #expect(batch.surfaces.allSatisfy { $0.playback.isPaused && $0.playback.currentScene != nil })
        session.updateLibrary([p], now: long + 2)
        #expect(!session.isWaiting && session.current?.id != batch.id)
    }

    @Test func spanAndPerDisplayFadeKeepSurfaceIdentityAndDisposeOldPins() throws {
        let group = try #require(DisplayLayout.groups([display(1), display(2, x: 1920)]).first)
        var s = only(.gallery, perDisplay: true); s.zoomEnabled = true; s.zoomPerDisplay = false
        let assets = (0..<8).map { photo("landscape\($0)", width: 6000, height: 2000) }
        let session = WallGroupPlayback(group: group, connected: [1, 2], assets: assets, settings: s, imageStore: nil, seed: 5, now: 0)
        defer { session.stop() }; session.update(now: 0)
        var modes = Set<WallMode>()
        var switches = 0
        for i in 1...15 {
            let old = try #require(session.current)
            let oldMode = old.surfaces[0].playback.currentScene?.mode
            session.next(now: Double(i * 10))
            let new = try #require(session.current)
            let mode = try #require(new.surfaces[0].playback.currentScene?.mode)
            modes.insert(mode)
            if oldMode != mode {
                switches += 1
                #expect(session.outgoing?.id == old.id)
                #expect(session.fade == 0)
                #expect(new.surfaces.count == (mode == .gallery ? 2 : 1))
                #expect(new.surfaces.allSatisfy { (mode == .gallery) == ($0.displayID != nil) })
                session.update(now: Double(i * 10) + s.fadeSeconds / 2)
                #expect(abs(session.fade - 0.5) < 1e-7)
            }
            session.update(now: Double(i * 10) + s.fadeSeconds)
            #expect(session.outgoing == nil)
        }
        #expect(modes == [.gallery, .zoom] && switches > 0)
    }

    @Test func safeGalleryReplacementInterpolatesSurvivingSlotsAndPauses() throws {
        let group = try #require(DisplayLayout.groups([display(1, width: 1000, height: 600), display(2, x: 1000, width: 1000, height: 600)]).first)
        let top = FaceRegion(x: 0.4, y: 0.1, width: 0.2, height: 0.2)
        let assets = [photo("a", width: 1000, height: 2000, faces: [top]), photo("b", width: 800, height: 2000, faces: [top]), photo("c", width: 1600, height: 2000, faces: [top])]
        var s = only(.gallery); s.galleryMax = 2; s.randomOrder = false; s.galleryMinSeconds = 5; s.galleryMaxSeconds = 5
        let playback = WallPlaybackController()
        playback.start(assets: assets, settings: s, viewport: group.viewport, seed: 1, now: 0, displayRegions: group.displays.map { group.region($0) })
        defer { playback.stop() }
        playback.update(now: 6.3)
        let p = try #require(playback.presentation(now: 6.3))
        let layout = try #require(p.galleryLayout)
        let middle = layout.frames(elapsed: layout.startedAt + s.fadeSeconds / 2, duration: s.fadeSeconds)
        #expect(zip(zip(layout.from, layout.to), middle).contains { pair, mid in pair.0 != pair.1 && mid != pair.0 && mid != pair.1 })
        for (a, rect) in zip(p.slots.map(\.asset), layout.to) {
            let face = try #require(FaceSafeLayout.bounds(a))
            let final = CGRect(x: rect.minX + face.minX * rect.width, y: rect.minY + face.minY * rect.height, width: face.width * rect.width, height: face.height * rect.height)
            #expect(group.displays.contains { group.region($0).contains(final) })
        }
        playback.setPaused(true, now: 6.4)
        let frozen = playback.presentation(now: 6.4)
        playback.update(now: 100)
        #expect(playback.presentation(now: 100) == frozen)
    }

    @Test func renderedOutputsCropSharedCanvasAndKeepOverlappingLocalPhotosSeparate() async throws {
        let a = photo("a", width: 100, height: 100), b = photo("b", width: 100, height: 100)
        let red = try #require(AmbientProcessor.image(Array(repeating: [UInt8(255),0,0,255], count: 100).flatMap { $0 }, width: 10, height: 10))
        let blue = try #require(AmbientProcessor.image(Array(repeating: [UInt8(0),0,255,255], count: 100).flatMap { $0 }, width: 10, height: 10))
        let images = PhotoImageStore(decode: { request in DecodedPhoto(image: request.asset.url == a.url ? red : blue) })
        #expect(await images.prepare([a,b]))
        for perDisplay in [false, true] {
            let list = [display(1, x: perDisplay ? 0 : 100, width: 100, height: 100), display(2, width: 100, height: 100)]
            let group = try #require(DisplayLayout.groups(list).first)
            var s = only(.gallery, perDisplay: perDisplay); s.randomOrder = false; s.gap = 0; s.cornerRadius = 0; s.galleryMax = perDisplay ? 1 : 2
            let session = WallGroupPlayback(group: group, connected: [1,2], assets: [a,b], settings: s, imageStore: images)
            for _ in 0..<1000 { session.update(); if !session.waitingForImages { break }; try await Task.sleep(for: .milliseconds(1)) }
            session.setPaused(true)
            for d in list {
                let screen = ScreenDescriptor(id: d.id, name: d.name, frame: CGRect(x: 0, y: 0, width: 100, height: 100), pixelWidth: 100, pixelHeight: 100)
                let output = DesktopWallOutput(screen: screen, display: d, group: group, number: Int(d.id), session: session)
                let view = NSHostingView(rootView: GroupDesktopWallView(output: output))
                view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
                // In span mode screen 1 is the rightmost tile, despite being first.
                let isRed = perDisplay ? d.id == 1 : d.id == 2
                #expect(isRed ? color.redComponent > 0.9 && color.blueComponent < 0.1 : color.blueComponent > 0.9 && color.redComponent < 0.1)
            }
            session.stop()
        }
    }

    @Test func perDisplaySettingsRoundTripAndModeRequiresCandidatesOnEveryDisplay() throws {
        var settings = only(.horizontalPan, perDisplay: true)
        settings.faceAwarePanDirection = false; settings.avoidFaceDisplayBoundaries = false
        let restored = try JSONDecoder().decode(WallSettings.self, from: JSONEncoder().encode(settings))
        #expect(WallMode.allCases.allSatisfy { restored.perDisplay($0) })
        #expect(!restored.faceAwarePanDirection && !restored.avoidFaceDisplayBoundaries)
        let group = try #require(DisplayLayout.groups([display(1, width: 1000, height: 600), display(2, x: 1000, width: 3000, height: 1000)]).first)
        let planner = WallScenePlanner(seed: 1)
        let p = photo(width: 2000, height: 1000)
        #expect(planner.nextGroup(assets: [p], settings: settings, group: group, connected: [1,2]) == nil)
        #expect(planner.nextGroup(assets: [p], settings: settings, group: group, connected: [1])?.count == 1)
        settings.galleryEnabled = true
        let plan = try #require(planner.nextGroup(assets: [p], settings: settings, group: group, connected: [1,2]))
        #expect(plan.count == 2 && plan.allSatisfy { $0.scene.mode == .gallery })
    }

    @Test func groupAmbientIsSharedAcrossTilesAndStopsForPauseAndDisposal() async throws {
        let group = try #require(DisplayLayout.groups([display(1, width: 100, height: 100), display(2, x: 100, width: 100, height: 100)]).first)
        let p = photo(width: 200, height: 100)
        let pixels = try #require(AmbientProcessor.image(Array(repeating: [UInt8(255),0,0,255], count: 16).flatMap { $0 }, width: 4, height: 4))
        let images = PhotoImageStore(decode: { _ in DecodedPhoto(image: pixels) })
        #expect(await images.prepare([p]))
        var settings = only(.gallery); settings.glassBackground = true
        let session = WallGroupPlayback(group: group, connected: [1,2], assets: [p], settings: settings, imageStore: images, now: 0)
        defer { session.stop() }; session.update(now: 0)
        let surface = try #require(session.current?.surfaces.first)
        let sampler = try #require(surface.ambients.values.first)
        for _ in 0..<100 {
            session.update(now: 0)
            if sampler.updateCount > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(sampler.updateCount > 0)
        #expect(session.current?.surfaces.count == 1 && surface.ambients.count == 1)
        session.setPaused(true, now: 1)
        let count = sampler.updateCount
        session.update(now: 50)
        try await Task.sleep(for: .milliseconds(20))
        #expect(sampler.updateCount == count)
        session.next(now: 50); session.stop()
        try await Task.sleep(for: .milliseconds(20))
        #expect(sampler.updateCount == count)
        #expect(images.displayedImages.isEmpty)
    }

    @Test func resettingMixedRetinaLayoutUsesPanelDimensionsWithoutOverlap() {
        let retina = ScreenDescriptor(id: 1, name: "Retina", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), pixelWidth: 3840, pixelHeight: 2160)
        let right = ScreenDescriptor(id: 2, name: "Right", frame: CGRect(x: 1920, y: 0, width: 1280, height: 720), pixelWidth: 1280, pixelHeight: 720)
        let left = ScreenDescriptor(id: 3, name: "Left", frame: CGRect(x: -1280, y: 0, width: 1280, height: 720), pixelWidth: 1280, pixelHeight: 720)
        let positions = DisplayLayout.physicalOrigins([retina, right, left])
        #expect(positions[1] == .zero)
        #expect(positions[2] == CGPoint(x: 3840, y: 1440))
        #expect(positions[3] == CGPoint(x: -1280, y: 1440))
    }

    @Test func ordinaryStartRetriesPreviouslyFailedImagesWithoutCancellingOtherOwners() async throws {
        let p = photo()
        let images = PhotoImageStore(decode: { _ in nil })
        #expect(!(await images.prepare([p])))
        #expect(images.failed(p))
        let controller = WallPlaybackController(imageStore: images)
        controller.start(assets: [p], settings: only(.gallery), viewport: CGSize(width: 1000, height: 600))
        #expect(controller.currentScene != nil && controller.waitingForImages)
        controller.stop()
    }

}
