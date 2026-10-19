import Foundation

nonisolated enum ModeSelection {
    static func isGallery(_ mode: WallMode) -> Bool { mode == .gallery || mode == .horizontalGallery }
    static func weights(gallery: Int, pan: Int, zoom: Int) -> (gallery: Int, motion: Int) {
        (gallery, pan, zoom) == (45, 35, 20) ? (80, 20) : (gallery, pan + zoom)
    }
    static func pick(_ available: [WallMode], galleryWeight: Int, motionWeight: Int, previous: WallMode?, repeats: Int,
                     using generator: inout SeededRandomNumberGenerator, allowGalleryRepeat: Bool = false) -> WallMode? {
        let gallery = available.filter(isGallery), motion = available.filter { !isGallery($0) }
        let g = gallery.isEmpty ? 0 : max(0, galleryWeight), m = motion.isEmpty ? 0 : max(0, motionWeight)
        guard g + m > 0 else { return nil }
        var pool = Double.random(in: 0..<Double(g + m), using: &generator) < Double(g) ? gallery : motion
        if !isGallery(pool[0]), repeats >= 2, pool.count > 1 { pool.removeAll { $0 == previous } }
        let result = pool[Int.random(in: 0..<pool.count, using: &generator)]
        return !allowGalleryRepeat && isGallery(result) && result == previous ? nil : result
    }
}
