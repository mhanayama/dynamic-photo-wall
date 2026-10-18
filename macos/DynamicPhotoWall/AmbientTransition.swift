import Foundation

/// Floating point state keeps slow color changes from disappearing to rounding.
/// The response depends on playback time, including pauses, rather than cadence.
nonisolated struct AmbientTransition {
    var responseSeconds = 0.8
    private var current: [Double] = []
    private var lastAt = 0.0

    mutating func push(_ pixels: [UInt8], at: Double) -> [UInt8] {
        if current.count != pixels.count || at < lastAt {
            current = pixels.map(Double.init)
        } else {
            let amount = 1 - exp(-max(0, at - lastAt) / responseSeconds)
            for i in pixels.indices { current[i] += (Double(pixels[i]) - current[i]) * amount }
        }
        lastAt = at
        return current.map { UInt8(min(255, max(0, $0.rounded(.toNearestOrEven)))) }
    }

    static func blend(_ from: [UInt8], _ to: [UInt8], progress: Double) -> [UInt8] {
        let amount = min(1, max(0, progress))
        return to.indices.map { i in
            UInt8((Double(from[i]) + (Double(to[i]) - Double(from[i])) * amount).rounded(.toNearestOrEven))
        }
    }
}
