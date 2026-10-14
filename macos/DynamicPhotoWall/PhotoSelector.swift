import Foundation

/// Stateful photo selection matching the Windows implementation's history and
/// sequential-playback rules. Simultaneously displayed photos are never used
/// as the small-library history fallback.
@MainActor
final class PhotoSelector {
    private var recentURLs: [URL] = []
    private var sequentialAfter: URL?
    private var generator: SeededRandomNumberGenerator

    init(seed: UInt64 = UInt64.random(in: .min ... .max)) {
        generator = SeededRandomNumberGenerator(seed: seed)
    }

    func pick(
        from assets: [PhotoAsset],
        settings: WallSettings,
        excluding excludedURLs: Set<URL> = []
    ) -> PhotoAsset? {
        let available = assets
            .filter { !excludedURLs.contains($0.url) }
            .sorted { $0.url.path.localizedCaseInsensitiveCompare($1.url.path) == .orderedAscending }
        guard !available.isEmpty else {
            return nil
        }

        var candidates = available.filter { !recentURLs.contains($0.url) }
        if candidates.isEmpty {
            candidates = available.min { recentIndex(of: $0.url) < recentIndex(of: $1.url) }.map { [$0] } ?? []
        }
        guard !candidates.isEmpty else {
            return nil
        }

        let result: PhotoAsset
        if settings.randomOrder {
            result = candidates[Int.random(in: candidates.indices, using: &generator)]
        } else {
            result = candidates.first {
                guard let sequentialAfter else { return true }
                return $0.url.path.localizedCaseInsensitiveCompare(sequentialAfter.path) == .orderedDescending
            } ?? candidates[0]
        }

        sequentialAfter = result.url
        recentURLs.removeAll { $0 == result.url }
        recentURLs.append(result.url)
        if recentURLs.count > settings.recentCount {
            recentURLs.removeFirst(recentURLs.count - settings.recentCount)
        }
        return result
    }

    func reset() {
        recentURLs.removeAll(keepingCapacity: true)
        sequentialAfter = nil
    }

    private func recentIndex(of url: URL) -> Int {
        recentURLs.firstIndex(of: url) ?? -1
    }
}

nonisolated struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
