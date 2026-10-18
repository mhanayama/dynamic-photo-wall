import Foundation
import CoreGraphics
import Testing
@testable import DynamicPhotoWall

// Synthetic pixel data and immutable textures only. No windows or captures.
struct AmbientTransitionTests {
    @Test func responseDependsOnElapsedTimeAndPreservesTheSettledColor() {
        let black: [UInt8] = [0, 0, 0, 255], color: [UInt8] = [240, 80, 20, 255]
        func response(_ cadence: Int) -> [UInt8] {
            var filter = AmbientTransition(); _ = filter.push(black, at: 0)
            var result = black
            for i in 1...cadence { result = filter.push(color, at: Double(i) / Double(cadence)) }
            return result
        }
        #expect(response(8) == response(60))
        var filter = AmbientTransition(); _ = filter.push(black, at: 0)
        let first = filter.push(color, at: 0.125)
        #expect(first[0] > 0 && first[0] < 40 && first[3] == 255)
        #expect(filter.push(color, at: 0.125) == first) // Paused playback clock.
        #expect(filter.push(color, at: 10) == color)
        #expect(filter.push(black, at: 0) == black) // A new timeline has no stale tail.
        #expect(filter.push(color + color, at: 0) == color + color)
        var alternating = AmbientTransition(); var last = alternating.push(black, at: 0)
        for i in 1...50 {
            let next = alternating.push(i.isMultiple(of: 2) ? black : color, at: Double(i) * 0.125)
            #expect(abs(Int(next[0]) - Int(last[0])) < 40)
            last = next
        }
    }

    @Test func interruptedTextureFadeStartsFromTheVisibleMixAndHoldsAnOpaqueBase() throws {
        let red = try #require(AmbientProcessor.image([255, 0, 0, 255], width: 1, height: 1))
        let blue = try #require(AmbientProcessor.image([0, 0, 255, 255], width: 1, height: 1))
        let green = try #require(AmbientProcessor.image([0, 255, 0, 255], width: 1, height: 1))
        var transition = AmbientTextureTransition()
        transition.push(red, at: 0); transition.push(blue, at: 1)
        let midway = transition.layers(at: 1.0625)
        #expect(midway[0].image === red && midway[1].image === blue)
        #expect(midway.map(\.opacity) == [1, 0.5])
        transition.push(green, at: 1.0625)
        let restarted = transition.layers(at: 1.0625)
        let data = try #require(restarted[0].image.dataProvider?.data)
        #expect(Array(data as Data) == [128, 0, 128, 255])
        #expect(restarted.map(\.opacity) == [1, 0])
        #expect(restarted[1].image === green)
        for tick in 0...60 {
            let layers = transition.layers(at: 1.0625 + Double(tick) / 60)
            #expect(layers[0].opacity == 1 && layers[1].image === green)
        }
        #expect(transition.layers(at: 10).map(\.opacity) == [1, 1])
        let resized = try #require(AmbientProcessor.image([255, 0, 0, 255, 255, 0, 0, 255], width: 2, height: 1))
        transition.push(resized, at: 11)
        #expect(transition.layers(at: 11).allSatisfy { $0.image === resized })
    }
}
