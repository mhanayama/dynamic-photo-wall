import AppKit

/// Scene events invalidate immediately; only content that is actually moving
/// samples playback time. The clock is shared with the foreground, never a timer.
nonisolated struct AmbientRefreshToken: Equatable {
    let presentation: WallScenePresentation
    let settings: WallSettings
    let viewport: CGSize
    let imageRevision: Int

    @MainActor init(_ p: WallScenePresentation, prepared: ForegroundGeometry.Prepared, images: PhotoImageStore) {
        let moving = prepared.isMoving(p)
        // Ignore elapsed/progress in a settled composition. The change back to
        // -1 also requests an exact final sample at the end of an animation.
        presentation = WallScenePresentation(scene: p.scene, progress: 0,
            elapsed: moving ? floor(p.elapsed * 8) : -1, slots: p.slots, scrollDistance: 0,
            galleryLayout: p.galleryLayout, galleryRemoved: p.galleryRemoved)
        self.settings = prepared.settings; self.viewport = prepared.viewport
        imageRevision = images.imageRevision
    }
}

/// Compare at the resolution of the 160px ambient texture. Subpixel foreground
/// changes accumulate until they matter to that texture; paused scrolls dedupe.
nonisolated struct AmbientCompositionKey: Equatable {
    struct Card: Equatable {
        let photo: PhotoImageKey
        let image: ObjectIdentifier
        let geometry: [Int]
    }
    let viewport: CGSize
    let cards: [Card]

    init(placements: [ForegroundPlacement], images: [NSImage], viewport: CGSize) {
        self.viewport = viewport
        let scale = 320 / max(1, max(viewport.width, viewport.height))
        cards = zip(placements, images).map { item, image in
            Card(photo: PhotoImageKey(item.asset), image: ObjectIdentifier(image), geometry:
                [item.frame.minX, item.frame.minY, item.frame.width, item.frame.height, item.cornerRadius]
                    .map { Int(($0 * scale).rounded()) } + [Int((item.opacity * 64).rounded())])
        }
    }
}

/// Cache the invariant face-safe motion plan and static Gallery packing. Timing
/// and interpolation still use the foreground's exact presentation each frame.
@MainActor final class ForegroundGeometryCache {
    private var input: WallScenePresentation?
    private var prepared: ForegroundGeometry.Prepared?
    private(set) var preparationCount = 0

    func prepare(_ p: WallScenePresentation, settings: WallSettings, viewport: CGSize) -> ForegroundGeometry.Prepared {
        let input = WallScenePresentation(scene: p.scene, progress: 0, elapsed: 0, slots: p.slots,
            scrollDistance: 0, galleryLayout: p.galleryLayout, galleryRemoved: p.galleryRemoved)
        if self.input == input, let prepared, prepared.settings == settings, prepared.viewport == viewport { return prepared }
        let prepared = ForegroundGeometry.Prepared(p, settings: settings, viewport: viewport)
        self.input = input; self.prepared = prepared; preparationCount += 1
        return prepared
    }
}
