import AppKit

@MainActor final class PNScenePlanner: PNScenePlanning {
    private let cache: PNPhotoCache
    private let catalog = PNPlanningCatalog()
    var readOriginal: ((PNAssetKey) async throws -> Data?)?
    private let worker = PNScenePlanWorker()
    private var preparations: [UUID: UUID] = [:]
    init(cache: PNPhotoCache) { self.cache = cache }
    func prepare(wall: PNSnapshot, group: UUID, photos: [PNPhoto]) async throws -> PNScene? {
        try await prepare(wall: wall, group: group, photos: photos, previous: nil)
    }
    func prepare(wall: PNSnapshot, group: UUID, photos: [PNPhoto], previous: PNScene?) async throws -> PNScene? {
        try Task.checkCancellation()
        let token = UUID(); preparations[group] = token
        defer { if preparations[group] == token { preparations.removeValue(forKey: group) } }
        let prepared = try await catalog.prepare(photos)
        try Task.checkCancellation()
        guard preparations[group] == token else { throw CancellationError() }
        guard var plan = try await worker.build(wall: wall, group: group, prepared: prepared, previous: previous) else { return nil }
        try Task.checkCancellation()
        guard preparations[group] == token else { throw CancellationError() }
        if try wall.playback.applying().glassBackground { plan.ambient = try await ambient(plan) }
        try Task.checkCancellation()
        guard preparations[group] == token else { throw CancellationError() }
        try plan.validate(); return plan
    }
    private func ambient(_ plan: PNScene) async throws -> [PNAmbient] {
        let ids = Set(plan.placements.map(\.displayId)); let samples = max(2, min(24, 64 / max(1, ids.count)))
        var images: [String: DecodedPhoto] = [:]
        for key in Set(plan.placements.map(\.asset)) {
            let bytes: Data?
            if let readOriginal { bytes = try await readOriginal(key) }
            else { bytes = try await cache.read(key) }
            if let bytes, let image = await Task.detached(priority: .utility, operation: { PNImageDecode.decode(bytes, maximum: 128) }).value { images[key.opaqueId] = image }
        }
        var frames: [PNAmbient] = []
        for id in ids {
            let processor = AmbientProcessor()
            let display = plan.displays.first { $0.id == id }
            let size = display.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: plan.viewport.width, height: plan.viewport.height)
            let ox = Double(display.map { $0.x - plan.displays.map(\.x).min()! } ?? 0), oy = Double(display.map { $0.y - plan.displays.map(\.y).min()! } ?? 0)
            for index in 0..<samples {
                let at = Double(index) / Double(samples - 1) * plan.duration
                let cards = plan.placements.filter { $0.displayId == id }.compactMap { p -> AmbientCard? in
                    guard let image = images[p.asset.opaqueId] else { return nil }; let value = p.evaluate(min(at, plan.duration - 0.0001))
                    let frame = CGRect(x: value.x - ox - p.width * (value.scale - 1) * p.centerX, y: value.y - oy - p.height * (value.scale - 1) * p.centerY, width: p.width * value.scale, height: p.height * value.scale)
                    return AmbientCard(image: image.image, frame: frame, opacity: value.opacity, radius: p.cornerRadius)
                }
                if let image = await processor.render(cards: cards, viewport: size, at: at, enhanceColors: false), let png = PNImageDecode.png(image.image) { frames.append(PNAmbient(at: at, png: png, displayId: id)) }
            }
        }
        return frames
    }
}
