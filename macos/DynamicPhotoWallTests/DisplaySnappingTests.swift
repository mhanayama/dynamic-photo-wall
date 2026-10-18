import Foundation
import CoreGraphics
import Testing
@testable import DynamicPhotoWall

struct DisplaySnappingTests {
    private nonisolated struct Rect: Decodable, Sendable {
        var x: Double, y: Double, width: Double, height: Double
        var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }
    private nonisolated struct Sample: Decodable, Sendable {
        var name: String; var moving: Rect; var others: [Rect]
        var threshold: Double; var expectedX: Double; var expectedY: Double
    }
    private nonisolated struct Fixture: Decodable, Sendable { var cases: [Sample] }
    @Test func snappingMatchesWindowsWithoutOpeningWindows() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appending(path: "tests/Fixtures/DisplaySnapping.v1.json")))
        for sample in fixture.cases {
            let expected = CGPoint(x: sample.expectedX, y: sample.expectedY)
            #expect(DisplayLayout.snapped(sample.moving.cgRect, against: sample.others.map(\.cgRect), threshold: sample.threshold) == expected)
            #expect(DisplayLayout.snapped(sample.moving.cgRect, against: sample.others.reversed().map(\.cgRect), threshold: sample.threshold) == expected)
        }
    }
}
