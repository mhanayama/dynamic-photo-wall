import AppKit
import Testing
@testable import DynamicPhotoWall

@MainActor struct AmbientColorTests {
    private nonisolated struct Sample: Decodable { var name: String; var rgba: [UInt8]; var expected: [UInt8] }
    private nonisolated struct Fixture: Decodable { var version: Int; var cases: [Sample] }
    @Test func premultipliedColorsMatchWindowsIncludingNeutralHighlightsAndAlpha() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appending(path: "tests/Fixtures/AmbientColors.v1.json")))
        for sample in fixture.cases {
            var rgba = sample.rgba; AmbientColors.enhance(&rgba)
            #expect(rgba == sample.expected, "\(sample.name)")
            #expect(rgba[3] == sample.rgba[3])
        }
    }
    @Test func localEnhancementHappensBeforeTemporalBlendingAndWirePreviewsStayUnenhanced() async throws {
        let warm = try #require(AmbientProcessor.image([200,80,40,255], width: 1, height: 1))
        let cool = try #require(AmbientProcessor.image([40,80,200,255], width: 1, height: 1))
        let viewport = CGSize(width: 160, height: 90)
        let a = AmbientCard(image: warm, frame: CGRect(origin: .zero, size: viewport), opacity: 1, radius: 0)
        let b = AmbientCard(image: cool, frame: CGRect(origin: .zero, size: viewport), opacity: 1, radius: 0)
        let processor = AmbientProcessor()
        let first = try #require(await processor.render(cards: [a], viewport: viewport))
        let second = try #require(await processor.render(cards: [b], viewport: viewport))
        let coolOnly = try #require(await AmbientProcessor().render(cards: [b], viewport: viewport))
        let wire = try #require(await AmbientProcessor().render(cards: [a], viewport: viewport, enhanceColors: false))
        func rgb(_ image: CGImage) throws -> [Double] {
            let color = try #require(NSBitmapImageRep(cgImage: image).colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.deviceRGB))
            return [color.redComponent * 255, color.greenComponent * 255, color.blueComponent * 255]
        }
        let c1 = try rgb(first.image), c2 = try rgb(second.image), c3 = try rgb(coolOnly.image), base = try rgb(wire.image)
        #expect(abs(base[0] - 200) < 3 && abs(base[2] - 40) < 3)
        #expect(c1[0] > base[0] && c1[2] < base[2])
        for i in 0..<3 { #expect(abs(c2[i] - (c1[i] + c3[i]) / 2) < 2) }
    }
}
