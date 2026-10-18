import Foundation
import Testing
@testable import DynamicPhotoWall

struct ZoomMotionTests {
    @Test func visibleZoomDefaultsAndSharedSettings() throws {
        var settings = WallSettings(); settings.normalize()
        #expect(settings.zoomSeconds == 30 && settings.maxZoom == 1.25)
        let shared = try PNOptions(settings).applying()
        #expect(shared.zoomSeconds == 30 && shared.maxZoom == 1.25)
        settings.maxZoom = 1.5; settings.normalize()
        #expect(settings.maxZoom == 1.5)
        settings.zoomSeconds = .nan; settings.maxZoom = .nan; settings.normalize()
        #expect(settings.zoomSeconds == 30 && settings.maxZoom == 1.25)
        let old = try JSONDecoder().decode(WallSettings.self, from: Data("{\"zoomSeconds\":20,\"maxZoom\":1.08}".utf8))
        #expect(old.zoomSeconds == 20 && old.maxZoom == 1.08)
    }
    @Test func bothDirectionsMoveTwentyFivePercent() {
        let asset = PhotoAsset(url: URL(filePath: "/fixture/zoom.jpg"), pixelWidth: 3000, pixelHeight: 2000)
        var settings = WallSettings(); settings.faceAwareFraming = false
        for reverse in [false, true] {
            let motion = WallMotionGeometry.plan(for: .zoom, asset: asset, viewport: CGSize(width: 1920, height: 1080),
                settings: settings, reverse: reverse, center: CGPoint(x: 0.5, y: 0.5))
            #expect(motion.seconds == 30 && abs(motion.toScale - motion.fromScale) == 0.25)
            #expect(motion.fromScale == (reverse ? 1.25 : 1))
        }
    }
}
