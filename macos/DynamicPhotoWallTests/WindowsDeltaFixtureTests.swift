import Foundation
import CoreGraphics
import Testing
@testable import DynamicPhotoWall

nonisolated private struct FixtureRect: Decodable {
    let x: Double, y: Double, width: Double, height: Double
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
nonisolated private struct FixtureSize: Decodable {
    let width: Double, height: Double
    var size: CGSize { CGSize(width: width, height: height) }
}
nonisolated private struct DeltaFixtures: Decodable {
    struct Motion: Decodable {
        struct Expected: Decodable {
            let width: Double, height: Double, fromX: Double, fromY: Double, toX: Double, toY: Double, seconds: Double
            let frameTop: Double?
        }
        let mode: WallMode, width: Int, height: Int, faces: [FaceRegion], viewport: FixtureSize
        let settings: WallSettings, reverse: Bool, displays: [FixtureRect], expected: Expected
    }
    struct Layout: Decodable {
        struct Photo: Decodable { let width: Int, height: Int, faces: [FaceRegion] }
        let viewport: FixtureSize, gap: Double, photos: [Photo], displays: [FixtureRect], expected: [FixtureRect]
    }
    struct Fill: Decodable {
        struct Photo: Decodable { let width: Int, height: Int, faces: [FaceRegion]? }
        let photos: [Photo], candidates: [Photo], viewport: FixtureSize, gap: Double, displays: [FixtureRect]
        let onlyIndex: Int?, expectedLoss: Double, expectedIndex: Int?, expectedCandidate: Int?
    }
    let motion: [Motion], faceLayout: [Layout], galleryFill: [Fill]?
}

@MainActor
struct WindowsDeltaFixtureTests {
    @Test func newFaceDirectionAndBoundaryGeometryMatchWindowsWithoutChangingBaseline() throws {
        let source = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/WindowsDelta.json")
        let bundle = Bundle(for: DeltaFixtureBundle.self).url(forResource: "WindowsDelta", withExtension: "json")
        let fixtures = try JSONDecoder().decode(DeltaFixtures.self, from: Data(contentsOf: bundle ?? source))
        #expect(fixtures.motion.count == 52)
        #expect(fixtures.faceLayout.count == 4)
        for c in fixtures.motion {
            let asset = PhotoAsset(url: URL(filePath: "/fixture/test.jpg"), pixelWidth: c.width, pixelHeight: c.height, faces: c.faces)
            let a = WallMotionGeometry.plan(for: c.mode, asset: asset, viewport: c.viewport.size,
                settings: c.settings, reverse: c.reverse, displayRegions: c.displays.map(\.rect))
            let b = c.expected
            for delta in [a.width-b.width, a.height-b.height, a.fromX-b.fromX, a.fromY-b.fromY,
                          a.toX-b.toX, a.toY-b.toY, a.seconds-b.seconds, a.frameTop-(b.frameTop ?? (c.viewport.height - min(c.viewport.height, b.height)) / 2)] { #expect(abs(delta) < 1e-7) }
        }
        for c in fixtures.faceLayout {
            let assets = c.photos.enumerated().map { i, p in
                PhotoAsset(url: URL(filePath: "/fixture/\(i).jpg"), pixelWidth: p.width, pixelHeight: p.height, faces: p.faces)
            }
            let actual = FaceSafeLayout.gallery(assets, viewport: c.viewport.size, gap: c.gap, displays: c.displays.map(\.rect))
            #expect(actual.count == c.expected.count)
            for (a, b) in zip(actual, c.expected.map(\.rect)) {
                for delta in [a.minX-b.minX, a.minY-b.minY, a.width-b.width, a.height-b.height] { #expect(abs(delta) < 1e-7) }
            }
        }
        #expect(fixtures.galleryFill?.count == 4)
        for c in fixtures.galleryFill ?? [] {
            let photos = c.photos.enumerated().map { i, p in PhotoAsset(url: URL(filePath: "/photo/\(i)"), pixelWidth: p.width, pixelHeight: p.height, faces: p.faces) }
            let candidates = c.candidates.enumerated().map { i, p in PhotoAsset(url: URL(filePath: "/candidate/\(i)"), pixelWidth: p.width, pixelHeight: p.height, faces: p.faces) }
            #expect(abs(GalleryComposition.loss(photos, viewport: c.viewport.size, gap: c.gap, displays: c.displays.map(\.rect)) - c.expectedLoss) < 1e-7)
            let better = try GalleryComposition.improve(photos, candidates: candidates, viewport: c.viewport.size, gap: c.gap, displays: c.displays.map(\.rect), onlyIndex: c.onlyIndex)
            #expect(better?.index == c.expectedIndex)
            #expect(better.flatMap { candidates.firstIndex(of: $0.photo) } == c.expectedCandidate)
        }

    }
}
private final class DeltaFixtureBundle: NSObject {}
