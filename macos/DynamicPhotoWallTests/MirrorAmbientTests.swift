import Foundation
import Testing
@testable import DynamicPhotoWall

@MainActor struct MirrorAmbientTests {
    private nonisolated struct Sample: Decodable, Sendable {
        var groupWidth: Double, groupHeight: Double
        var imageWidth: Int, imageHeight: Int
        var mirror: Bool
    }
    private nonisolated struct Fixture: Decodable, Sendable { var cases: [Sample] }
    @Test func thresholdUsesTheGroupsLongAxisAndExcludesTheExactHalf() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appending(path: "tests/Fixtures/MirrorPolicy.v1.json")))
        for sample in fixture.cases {
            #expect(MirrorPolicy.isBelowHalf(imageWidth: sample.imageWidth, imageHeight: sample.imageHeight,
                group: CGSize(width: sample.groupWidth, height: sample.groupHeight)) == sample.mirror)
        }
    }
    @Test func allMotionModesMirrorTheSameAssetOnHorizontalAndVerticalGroups() throws {
        for vertical in [false, true] {
            let displays = (0..<4).map { i in WallDisplay(id: UInt32(i + 1), name: "Display \(i)",
                x: vertical ? 0 : Double(i * 2000), y: vertical ? Double(i * 2000) : 0,
                width: vertical ? 1200 : 2000, height: vertical ? 2000 : 1200, groupID: "g") }
            let group = try #require(DisplayLayout.groups(displays).first)
            for mode in [WallMode.verticalPan, .horizontalPan, .zoom] {
                var settings = WallSettings(); settings.galleryEnabled = false; settings.galleryScrollEnabled = false
                settings.verticalPanEnabled = mode == .verticalPan; settings.horizontalPanEnabled = mode == .horizontalPan
                settings.zoomEnabled = mode == .zoom
                let width = mode == .verticalPan ? (vertical ? 1200 : 1500) : mode == .horizontalPan ? (vertical ? 4000 : 3000) : 2000
                let height = mode == .verticalPan ? (vertical ? 3000 : 4500) : mode == .horizontalPan ? (vertical ? 1000 : 900) : 1000
                let asset = PhotoAsset(url: URL(filePath: "/fixture/photo.jpg"), pixelWidth: width, pixelHeight: height)
                let plans = try #require(WallScenePlanner(seed: 42).nextGroup(assets: [asset], settings: settings, group: group, connected: Set(displays.map(\.id))))
                #expect(plans.count == 4)
                #expect(Set(plans.compactMap(\.displayID)) == Set(displays.map(\.id)))
                #expect(plans.allSatisfy { $0.scene.mode == mode && $0.scene.assets.map(\.url) == [asset.url] })
            }
        }
    }
    @Test func transparentAmbientMarginsExtendPhotoColorToEveryEdge() {
        var pixels = [UInt8](repeating: 0, count: 257 * 19 * 4)
        for y in 6..<13 { let i = (y * 257 + 128) * 4; pixels[i] = 200; pixels[i + 1] = 80; pixels[i + 2] = 40; pixels[i + 3] = 255 }
        #expect(AmbientProcessor.extendPadding(&pixels, width: 257, height: 19))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            #expect(pixels[i] == 200 && pixels[i + 1] == 80 && pixels[i + 2] == 40 && pixels[i + 3] == 255)
        }
    }
}
