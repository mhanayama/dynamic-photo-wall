import Foundation
import CoreGraphics

nonisolated enum GalleryComposition {
    static let candidateLimit = 12
    struct Replacement: Equatable, Sendable { let index: Int; let photo: PhotoAsset }

    static func loss(_ photos: [PhotoAsset], viewport: CGSize, gap: CGFloat, displays: [CGRect]) -> Double {
        guard !photos.isEmpty, FaceSafeLayout.requiresProtection(viewport, displays: displays) else { return 0 }
        let original = GalleryLayout.frames(assets: photos, in: viewport, gap: gap)
        let frames = FaceSafeLayout.gallery(photos, viewport: viewport, gap: gap, displays: displays)
        let normalGap = original.count > 1 ? original[1].minX - original[0].maxX : 0
        var excess: CGFloat = 0
        for i in frames.indices.dropFirst() { excess += max(0, frames[i].minX - frames[i - 1].maxX - normalGap) }
        let rowCenter = (frames[0].minX + frames[frames.count - 1].maxX) / 2
        return 2 * max(0, 1 - frames[0].height / original[0].height)
            + (excess + abs(rowCenter - viewport.width / 2)) / max(1, viewport.width)
    }

    static func improve(_ photos: [PhotoAsset], candidates: [PhotoAsset], viewport: CGSize, gap: CGFloat,
                        displays: [CGRect], onlyIndex: Int? = nil) throws -> Replacement? {
        try Task.checkCancellation()
        var best = loss(photos, viewport: viewport, gap: gap, displays: displays)
        guard best >= 0.02 else { return nil }
        let threshold = best - 0.02
        var result: Replacement?
        var trial = photos
        for candidate in candidates.prefix(candidateLimit) {
            try Task.checkCancellation()
            guard candidate.faces != nil, !photos.contains(where: { $0.sourceURL == candidate.sourceURL }) else { continue }
            let indices = onlyIndex.map { [$0] } ?? Array(photos.indices)
            for index in indices where photos.indices.contains(index) {
                try Task.checkCancellation()
                trial[index] = candidate
                let loss = loss(trial, viewport: viewport, gap: gap, displays: displays)
                trial[index] = photos[index]
                if loss < best && loss <= threshold { best = loss; result = Replacement(index: index, photo: candidate) }
            }
        }
        return result
    }
}

/// Geometry trials execute on this actor, without decoding or UI work.
actor GalleryCompositionProcessor {
    func frames(_ photos: [PhotoAsset], viewport: CGSize, gap: CGFloat, displays: [CGRect]) -> [CGRect] {
        FaceSafeLayout.gallery(photos, viewport: viewport, gap: gap, displays: displays)
    }

    func improve(_ photos: [PhotoAsset], candidates: [PhotoAsset], viewport: CGSize, gap: CGFloat,
                 displays: [CGRect], onlyIndex: Int? = nil) throws -> GalleryComposition.Replacement? {
        try GalleryComposition.improve(photos, candidates: candidates, viewport: viewport, gap: gap, displays: displays, onlyIndex: onlyIndex)
    }
}
