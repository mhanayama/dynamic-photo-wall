import Foundation
import Testing
@testable import DynamicPhotoWall

@MainActor struct GalleryFaceTests {
    private func photo(_ i: Int, _ w: Int, _ h: Int, faces: [FaceRegion] = []) -> PhotoAsset {
        PhotoAsset(url: URL(filePath: "/fixture/\(i).jpg"), pixelWidth: w, pixelHeight: h, faces: faces)
    }
    @Test func zoomFacesRemainInsideOnePhysicalDisplay() throws {
        let asset = photo(0, 6000, 4000, faces: [FaceRegion(x: 0.2, y: 0.1, width: 0.2, height: 0.8), FaceRegion(x: 0.55, y: 0.2, width: 0.15, height: 0.3)])
        let bounds = try #require(FaceSafeLayout.bounds(asset))
        for vertical in [false, true] {
            let v = vertical ? CGSize(width: 1200, height: 8000) : CGSize(width: 5760, height: 1080)
            let displays = vertical ? (0..<4).map { CGRect(x: 0, y: $0 * 2000, width: 1200, height: 2000) }
                : (0..<3).map { CGRect(x: $0 * 1920, y: 0, width: 1920, height: 1080) }
            for reverse in [false, true] {
                let p = try #require(FaceMotionSafety.plan(for: .zoom, asset: asset, viewport: v, settings: WallSettings(), reverse: reverse, displayRegions: displays))
                #expect(max(p.fromScale, p.toScale) < 1.25)
                #expect(abs(max(p.fromScale, p.toScale) / min(p.fromScale, p.toScale) - 1.25) < 0.00001)
                for i in 0...100 {
                    let scale = CGFloat(p.fromScale + (p.toScale - p.fromScale) * Double(i) / 100)
                    let face = CGRect(x: p.fromX + (1 - scale) * p.center.x * p.width + bounds.minX * p.width * scale,
                        y: p.fromY + (1 - scale) * p.center.y * p.height + bounds.minY * p.height * scale,
                        width: bounds.width * p.width * scale, height: bounds.height * p.height * scale)
                    #expect(displays.contains { $0.insetBy(dx: -0.001, dy: -0.001).contains(face) })
                }
            }
        }
        #expect(FaceMotionSafety.plan(for: .verticalPan, asset: photo(1, 1000, 2000, faces: [FaceRegion(x: 0, y: 0, width: 1, height: 1)]),
            viewport: CGSize(width: 1920, height: 1080), settings: WallSettings()) == nil)
    }
    @Test func repackingRetainsTheShortAxisAndKeepsTheReplacement() {
        for vertical in [false, true] {
            let v = vertical ? CGSize(width: 1080, height: 6000) : CGSize(width: 6000, height: 1080)
            var assets = (0..<8).map { vertical ? photo($0, 1800, 900) : photo($0, 900, 1800) }
            let before = FixedGalleryLayout.arrange(assets, viewport: v, gap: 8)
            assets[3] = vertical ? photo(30, 900, 2700) : photo(30, 2700, 900)
            let after = FixedGalleryLayout.arrange(assets, viewport: v, gap: 8, pinned: 3)
            #expect(after.contains { $0.index == 3 }); #expect(after.count < before.count)
            #expect((before + after).allSatisfy { abs((vertical ? $0.frame.width : $0.frame.height) - 1064) < 0.001 })
        }
    }
    @Test func galleryUsesOneClockAcrossSurfaces() {
        let assets = (0..<30).map { photo($0, 800, 1600) }, settings = WallSettings()
        let surfaces = [GalleryTimeline.Surface(assets: Array(assets.prefix(2)), viewport: CGSize(width: 1920, height: 1080), displays: []),
                        GalleryTimeline.Surface(assets: Array(assets.dropFirst(2).prefix(2)), viewport: CGSize(width: 1920, height: 1080), displays: [])]
        let plan = GalleryTimeline.build(surfaces, duration: 150, settings: settings, replacement: { active in assets.first { p in !active.contains { $0.url == p.url } } }, random: { 0.5 })
        let born = plan.filter { $0.fadeIn > 0 }.sorted { $0.at < $1.at }
        #expect(born.count >= 3); #expect(Set(born.map(\.at)).count == born.count)
        var previous = 0.0
        for item in born { #expect(item.at - previous >= 10 && item.at - previous <= 30.001); previous = item.at + settings.fadeSeconds }
        #expect(plan.allSatisfy { $0.to.height == 1064 && $0.from.height == 1064 })
    }
    @Test func nativeGroupControllersShareOneReplacementClockWithoutWindows() throws {
        var settings = WallSettings()
        settings.galleryScrollEnabled = false; settings.verticalPanEnabled = false
        settings.horizontalPanEnabled = false; settings.zoomEnabled = false; settings.galleryPerDisplay = true
        let assets = (0..<30).map { photo($0, 800, 1600) }
        let displays = [WallDisplay(id: 1, name: "left", x: 0, y: 0, width: 1920, height: 1080, groupID: "test"),
                        WallDisplay(id: 2, name: "right", x: 1920, y: 0, width: 1920, height: 1080, groupID: "test")]
        let group = try #require(DisplayLayout.groups(displays).first)
        let session = WallGroupPlayback(group: group, connected: [1, 2], assets: assets, settings: settings, imageStore: nil, seed: 7, now: 0)
        defer { session.stop() }
        session.update(now: 0)
        var previous = Set(try #require(session.current).assets.map(\.url)), changes: [Double] = []
        for tick in 1...1700 {
            let at = Double(tick) / 20
            session.update(now: at)
            let current = Set(try #require(session.current).assets.map(\.url))
            if current != previous {
                #expect(current.subtracting(previous).count == 1)
                if let last = changes.last { #expect(at - last >= 10 + settings.fadeSeconds - 0.05) }
                changes.append(at); previous = current
            }
        }
        #expect(changes.count >= 2)
    }
}
