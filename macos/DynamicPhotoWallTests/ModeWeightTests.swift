import Foundation
import Testing
@testable import DynamicPhotoWall

@MainActor struct ModeWeightTests {
    @Test func onlyFiniteSharedTimelinesAllowRepeatedGalleryDraws() {
        for scroll in [false, true] {
            var settings = WallSettings()
            settings.galleryEnabled = !scroll; settings.galleryScrollEnabled = scroll
            settings.verticalPanEnabled = false; settings.horizontalPanEnabled = false; settings.zoomEnabled = false
            let planner = WallScenePlanner(seed: 1234)
            let mode: WallMode = scroll ? .horizontalGallery : .gallery
            #expect(planner.chooseGroupMode(settings: settings) == mode)
            #expect(planner.chooseGroupMode(settings: settings) == nil)
            #expect(planner.lastDrawSkipped)
            #expect(planner.chooseGroupMode(settings: settings, allowGalleryRepeat: true) == mode)
            #expect(!planner.lastDrawSkipped)
        }
    }
    @Test func legacyDefaultsAndSharedCategoriesMigrate() throws {
        var settings = try JSONDecoder().decode(WallSettings.self, from: Data("{\"galleryWeight\":45,\"panWeight\":35,\"zoomWeight\":20}".utf8))
        settings.normalize()
        #expect(settings.galleryWeight == 80 && settings.motionWeight == 20 && settings.zoomWeight == 0)
        let shared = try PNOptions(settings).applying()
        #expect(shared.galleryWeight == 80 && shared.motionWeight == 20)
        settings.galleryWeight = 60; settings.panWeight = 10; settings.zoomWeight = 5; settings.normalize()
        #expect(settings.galleryWeight == 60 && settings.motionWeight == 15)
    }
    @Test func standaloneAndGroupedDrawsKeepEightyPercentGallery() throws {
        let assets = [(3000,5000), (8000,1200), (4000,2400)].enumerated().map {
            PhotoAsset(url: URL(filePath: "/fixture/\($0.offset).jpg"), pixelWidth: $0.element.0, pixelHeight: $0.element.1)
        }
        for grouped in [false, true] {
            for scroll in [false, true] {
                var settings = WallSettings(); settings.galleryScrollEnabled = scroll
                let planner = WallScenePlanner(seed: 1234); var count = 0; var skipped = 0; var previous: WallMode?
                for _ in 0..<20000 {
                    let result = grouped ? planner.chooseGroupMode(settings: settings)
                        : planner.next(assets: assets, settings: settings, viewport: CGSize(width: 1920, height: 1080))?.mode
                    guard let mode = result else { #expect(planner.lastDrawSkipped); skipped += 1; continue }
                    #expect(!ModeSelection.isGallery(mode) || mode != previous)
                    previous = mode
                    if ModeSelection.isGallery(mode) { count += 1 }
                }
                #expect(abs(Double(count + skipped) / 20000 - 0.8) < 0.02)
            }
        }
    }
}
