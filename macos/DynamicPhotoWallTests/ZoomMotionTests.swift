import Foundation
import CoreGraphics
import Testing
@testable import DynamicPhotoWall

struct ZoomMotionTests {
    @Test func edgeFacesDoNotPullThePhotographToTheScreenCenter() throws {
        let viewport = CGSize(width: 1920, height: 1080)
        let faces = [FaceRegion(x: 0.04, y: 0.4, width: 0.08, height: 0.16),
                     FaceRegion(x: 0.88, y: 0.4, width: 0.08, height: 0.16),
                     FaceRegion(x: 0.45, y: 0.06, width: 0.1, height: 0.08),
                     FaceRegion(x: 0.45, y: 0.86, width: 0.1, height: 0.08)]
        for zoom in [1.25, 1.5] {
            for reverse in [false, true] {
                for face in faces {
                    let asset = PhotoAsset(url: URL(filePath: "/fixture/edge.jpg"), pixelWidth: 1920, pixelHeight: 1080, faces: [face])
                    var settings = WallSettings(); settings.maxZoom = zoom
                    let p = try #require(FaceMotionSafety.plan(for: .zoom, asset: asset, viewport: viewport, settings: settings, reverse: reverse))
                    #expect(abs(p.fromX) < 0.00001 && abs(p.fromY) < 0.00001)
                    #expect(p.fromX == p.toX && p.fromY == p.toY)
                    assertSafeZoom(p, asset: asset, viewport: viewport, coversViewport: true)
                }
            }
        }
    }

    @Test func croppedEdgeFacesMoveOnlyAsFarAsNeeded() throws {
        let viewport = CGSize(width: 1920, height: 1080)
        for reverse in [false, true] {
            for right in [false, true] {
                let asset = PhotoAsset(url: URL(filePath: "/fixture/wide-edge.jpg"), pixelWidth: 4000, pixelHeight: 1080,
                    faces: [FaceRegion(x: right ? 0.92 : 0.04, y: 0.4, width: 0.04, height: 0.1)])
                var settings = WallSettings(); settings.maxZoom = 1.5
                let p = try #require(FaceMotionSafety.plan(for: .zoom, asset: asset, viewport: viewport, settings: settings, reverse: reverse))
                #expect(abs(p.fromX - (right ? -1984 : -96)) < 0.00001)
                assertSafeZoom(p, asset: asset, viewport: viewport, coversViewport: true)
            }
        }
    }

    @Test func reducedZoomKeepsThePhotographCenteredWhenFacesAlreadyFit() throws {
        let asset = PhotoAsset(url: URL(filePath: "/fixture/large-faces.jpg"), pixelWidth: 1920, pixelHeight: 1080,
            faces: [FaceRegion(x: 0.1, y: 0.1, width: 0.8, height: 0.8)])
        let viewport = CGSize(width: 1920, height: 1080)
        for reverse in [false, true] {
            let p = try #require(FaceMotionSafety.plan(for: .zoom, asset: asset, viewport: viewport, settings: WallSettings(), reverse: reverse))
            #expect(min(p.fromScale, p.toScale) < 1)
            #expect(abs(p.fromX) < 0.00001 && abs(p.fromY) < 0.00001)
            assertSafeZoom(p, asset: asset, viewport: viewport, coversViewport: false)
        }
    }

    @Test func spanningZoomKeepsFacesOnTheirOriginalDisplayWhenPossible() throws {
        let viewport = CGSize(width: 5760, height: 1080)
        let displays = (0..<3).map { CGRect(x: $0 * 1920, y: 0, width: 1920, height: 1080) }
        let asset = PhotoAsset(url: URL(filePath: "/fixture/span-edge.jpg"), pixelWidth: 5760, pixelHeight: 1080,
            faces: [FaceRegion(x: 0.8, y: 0.4, width: 0.06, height: 0.1)])
        for reverse in [false, true] {
            let p = try #require(FaceMotionSafety.plan(for: .zoom, asset: asset, viewport: viewport, settings: WallSettings(),
                reverse: reverse, displayRegions: Array(displays.reversed())))
            #expect(abs(p.fromX) < 0.00001 && abs(p.fromY) < 0.00001)
            assertSafeZoom(p, asset: asset, viewport: viewport, coversViewport: true)
        }
    }

    private func assertSafeZoom(_ p: WallMotionPlan, asset: PhotoAsset, viewport: CGSize, coversViewport: Bool) {
        let bounds = FaceSafeLayout.bounds(asset)!
        for tick in 0...100 {
            let scale = CGFloat(p.fromScale + (p.toScale - p.fromScale) * Double(tick) / 100)
            let image = CGRect(x: p.fromX + (1 - scale) * p.center.x * p.width,
                y: p.fromY + (1 - scale) * p.center.y * p.height, width: p.width * scale, height: p.height * scale)
            let face = CGRect(x: image.minX + bounds.minX * image.width, y: image.minY + bounds.minY * image.height,
                width: bounds.width * image.width, height: bounds.height * image.height)
            #expect(CGRect(origin: .zero, size: viewport).insetBy(dx: -0.001, dy: -0.001).contains(face))
            if coversViewport { #expect(image.insetBy(dx: -0.001, dy: -0.001).contains(CGRect(origin: .zero, size: viewport))) }
        }
    }

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
