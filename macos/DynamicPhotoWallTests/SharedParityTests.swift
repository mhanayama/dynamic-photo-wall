import Foundation
import CoreGraphics
import Testing
@testable import DynamicPhotoWall

private final class ParityFixtureBundle: NSObject {}

@MainActor
struct SharedParityTests {
    private func fixtures() throws -> [String: Any] {
        let source = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/WindowsParity.json")
        let url = Bundle(for: ParityFixtureBundle.self).url(forResource: "WindowsParity", withExtension: "json") ?? source
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func mode(_ name: String) throws -> WallMode {
        try #require(name == "galleryScroll" ? .horizontalGallery : WallMode(rawValue: name))
    }

    @Test func motionAndEligibilityMatchWindowsSharedFixtures() throws {
        let all = try fixtures()
        let cases = try #require(all["motion"] as? [[String: Any]])
        #expect(cases.count == 36)
        for c in cases {
            let v = try #require(c["viewport"] as? [String: Double])
            let viewport = CGSize(width: try #require(v["width"]), height: try #require(v["height"]))
            let settings = try JSONDecoder().decode(WallSettings.self, from: JSONSerialization.data(withJSONObject: try #require(c["settings"])))
            let faces = try c["faces"].flatMap { $0 is NSNull ? nil : try JSONDecoder().decode([FaceRegion].self, from: JSONSerialization.data(withJSONObject: $0)) }
            let asset = PhotoAsset(url: URL(filePath: "/fixture/test.jpg"), pixelWidth: try #require(c["width"] as? Int), pixelHeight: try #require(c["height"] as? Int), faces: faces)
            let selectedMode = try mode(try #require(c["mode"] as? String))
            let plan = WallMotionGeometry.plan(for: selectedMode, asset: asset, viewport: viewport, settings: settings,
                reverse: try #require(c["reverse"] as? Bool), center: CGPoint(x: try #require(c["centerX"] as? Double), y: try #require(c["centerY"] as? Double)))
            let expected = try #require(c["expected"] as? [String: Double])
            let actual = ["width": plan.width, "height": plan.height, "fromX": plan.fromX, "fromY": plan.fromY,
                "toX": plan.toX, "toY": plan.toY, "fromScale": plan.fromScale, "toScale": plan.toScale,
                "centerX": plan.center.x, "centerY": plan.center.y, "seconds": plan.seconds]
            for (key, value) in actual { #expect(abs(value - (try #require(expected[key]))) < 1e-7) }
            for (key, expected) in try #require(c["eligible"] as? [String: Bool]) {
                #expect(WallScenePlanner.isEligible(asset, for: try mode(key), settings: settings, viewport: viewport) == expected)
            }
        }
    }

    @Test func galleryLayoutMatchesWindowsSharedFixtures() throws {
        let all = try fixtures()
        for c in try #require(all["layout"] as? [[String: Any]]) {
            let v = try #require(c["viewport"] as? [String: Double])
            let photos = try #require(c["photos"] as? [[String: Int]])
            let assets = try photos.enumerated().map { i, p in
                PhotoAsset(url: URL(filePath: "/fixture/\(i).jpg"), pixelWidth: try #require(p["width"]), pixelHeight: try #require(p["height"]))
            }
            let frames = GalleryLayout.frames(assets: assets, in: CGSize(width: try #require(v["width"]), height: try #require(v["height"])), gap: try #require(c["gap"] as? Double))
            let expected = try #require(c["expected"] as? [[String: Double]])
            #expect(frames.count == expected.count)
            for (a, e) in zip(frames, expected) {
                for (key, value) in ["x": a.minX, "y": a.minY, "width": a.width, "height": a.height] { #expect(abs(value - (try #require(e[key]))) < 1e-7) }
            }
        }
    }
    @Test func selectionHistoryAndSimultaneousExclusionMatchWindowsSharedFixtures() throws {
        let all = try fixtures()
        for c in try #require(all["selection"] as? [[String: Any]]) {
            let paths = try #require(c["photos"] as? [String])
            let photos = paths.map { PhotoAsset(url: URL(filePath: $0), pixelWidth: 100, pixelHeight: 200) }
            var settings = WallSettings(); settings.randomOrder = false
            settings.recentCount = try #require(c["recentCount"] as? Int)
            let excluded = try #require(c["excluded"] as? [[String]])
            let expected = try #require(c["expected"] as? [String])
            let selector = PhotoSelector(seed: 42)
            for (index, exclusions) in excluded.enumerated() {
                let chosen = selector.pick(from: photos, settings: settings, excluding: Set(exclusions.map { URL(filePath: $0) }))
                #expect(chosen?.url.path == expected[index])
            }
        }
    }

}
