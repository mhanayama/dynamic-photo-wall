import AppKit

@MainActor final class PNPlayback: PNPlaybackOutput {
    struct PreparedCard { let placement: PNPlacement; let image: CGImage }
    struct SurfaceContent { let crop: CGRect; let cards: [PreparedCard]; let ambient: [PNAmbientImage] }
    struct Frame {
        let renderID = UUID()
        let plan: PNScene
        let images: [String: DecodedPhoto]
        let ambient: [PNAmbientImage]
        let contents: [PNDisplayKey: SurfaceContent]
        var start = 0.0, paused = 0.0
        init(plan: PNScene, images: [String: DecodedPhoto], ambient: [PNAmbientImage]) {
            var byPNG: [Data: NSImage] = [:]
            let ambient = ambient.map { item -> PNAmbientImage in
                guard !item.frame.png.isEmpty else { return item }
                let image = byPNG[item.frame.png] ?? item.image
                byPNG[item.frame.png] = image
                return PNAmbientImage(frame: item.frame, image: image)
            }
            self.plan = plan; self.images = images; self.ambient = ambient
            // Resolve wire identities and display membership once. Hashing asset
            // IDs inside draw() also charged every invisible timeline segment
            // to every display on every frame.
            let byAsset = Dictionary(uniqueKeysWithValues: Set(plan.placements.map(\.asset)).compactMap { key in
                images[key.opaqueId].map { (key, $0.image) }
            })
            let left = plan.displays.map(\.x).min() ?? 0, top = plan.displays.map(\.y).min() ?? 0
            contents = Dictionary(uniqueKeysWithValues: plan.displays.map { display in
                let id = display.id
                let cards = plan.placements.compactMap { placement -> PreparedCard? in
                    guard placement.displayId == nil || placement.displayId == id, let image = byAsset[placement.asset] else { return nil }
                    return PreparedCard(placement: placement, image: image)
                }
                return (display.key, SurfaceContent(crop: CGRect(x: display.x - left, y: display.y - top, width: display.width, height: display.height),
                    cards: cards, ambient: ambient.filter { $0.frame.displayId == nil || $0.frame.displayId == id }.sorted { $0.frame.at < $1.frame.at }))
            })
        }
    }
    struct PNAmbientImage { var frame: PNAmbient; var image: NSImage }
    private let local: UUID
    private let clock: any PNClock
    private let enter: () -> Void
    private let budget: () -> Int
    private let screenProvider: @MainActor () -> [ScreenDescriptor]
    private let makeSurface: (ScreenDescriptor) -> any PNPlaybackSurface
    private let automaticRendering: Bool
    private var prepared: [UUID: Frame] = [:], preparing: [UUID: UUID] = [:]
    private var presentations: [PNDisplayKey: PNPresentation] = [:]
    private var surfaces: [PNDisplayKey: any PNPlaybackSurface] = [:]
    private var commits: [UUID: PNCommit] = [:], controls: [PNControl] = []
    private var timer: Task<Void, Never>?, fallback: Task<Void, Never>?
    private var fallbackToken = UUID()
    private var fallbackPlans: Set<UUID> = []
    private var recovery = PNRecoveryState.listening
    private var repeating = false, shutdown = false
    private var snapshot: PNSnapshot?
    private var planner: (any PNScenePlanning)?
    private let layoutPreview: PNLayoutPreview
    private var photos: PNPhotoTransfers?
    private var pausedAt: Double?, stopped = false
    private(set) var isDisplaying = false
    var isPaused: Bool { pausedAt != nil }
    var isStopped: Bool { stopped }
    var isRunning: Bool { isDisplaying && !stopped && !presentations.isEmpty }
    var previewVisible: Bool { layoutPreview.visible }
    var changed: (() -> Void)?
    init(local: UUID, clock: any PNClock, cache: PNPhotoCache, budget: @escaping () -> Int, enter: @escaping () -> Void,
         screens: @escaping @MainActor () -> [ScreenDescriptor] = ScreenDescriptor.availableScreens,
         makeSurface: ((ScreenDescriptor) -> any PNPlaybackSurface)? = nil, automaticRendering: Bool = true) {
        self.local = local; self.clock = clock; self.budget = budget; self.enter = enter
        screenProvider = screens; self.makeSurface = makeSurface ?? { PNWindowSurface(screen: $0) }
        self.automaticRendering = automaticRendering; layoutPreview = PNLayoutPreview(local: local)
    }
    func preview(_ plan: PNPreviewPlan) { layoutPreview.schedule(plan); layoutPreview.changed = { [weak self] in self?.changed?() }; startTimer() }
    func bind(planner: any PNScenePlanning, photos: PNPhotoTransfers) { self.planner = planner; self.photos = photos }
    func prepare(_ scene: PNScene) async throws {
        try Task.checkCancellation(); guard !shutdown else { throw CancellationError() }
        try scene.validate()
        let token = UUID(); preparing[scene.groupId] = token
        defer { if preparing[scene.groupId] == token { preparing.removeValue(forKey: scene.groupId) } }
        let own = Set(scene.displays.filter { $0.key.peerId == local }.map(\.id))
        let keys = Set(scene.placements.filter { $0.displayId == nil || own.contains($0.displayId!) }.map(\.asset))
        let pixels = min(16_000_000, max(65536, budget() * 1024 * 1024 / 8 / max(1, keys.count)))
        var images: [String: DecodedPhoto] = [:]
        let held = presentations.values.first { scene.continues($0.frame.plan) }?.frame.images ?? [:]
        for key in keys {
            if let image = held[key.opaqueId] { images[key.opaqueId] = image; continue }
            guard let bytes = try await photos?.readOriginal(key), let photo = photos?.available[key.opaqueId] else { throw PNError.invalid("写真キャッシュを準備中です。") }
            let maximum = min(4096, max(64, Int(sqrt(Double(pixels) * Double(max(photo.pixelWidth, photo.pixelHeight)) / Double(min(photo.pixelWidth, photo.pixelHeight))))))
            guard let image = await Task.detached(priority: .utility, operation: { PNImageDecode.decode(bytes, maximum: maximum) }).value else { throw PNError.invalid("原寸画像をデコードできません。") }
            images[key.opaqueId] = image
            try Task.checkCancellation()
            guard !shutdown, preparing[scene.groupId] == token else { throw CancellationError() }
        }
        // Wire PNGs stay unenhanced. Apply color once at the receiving display,
        // regardless of which OS supplied the shared preview.
        let decoded = await Task.detached(priority: .utility) {
            scene.ambient.compactMap { frame -> (PNAmbient, DecodedPhoto)? in
                guard let image = PNImageDecode.decode(frame.png, maximum: 512), let enhanced = AmbientColors.enhance(image.image) else { return nil }
                return (frame, enhanced)
            }
        }.value
        try Task.checkCancellation()
        guard !shutdown, preparing[scene.groupId] == token else { throw CancellationError() }
        guard decoded.count == scene.ambient.count else { throw PNError.invalid("背景画像をデコードできません。") }
        let ambient = decoded.map { PNAmbientImage(frame: $0.0, image: NSImage(cgImage: $0.1.image, size: NSSize(width: $0.1.image.width, height: $0.1.image.height))) }
        prepared = prepared.filter { $0.value.plan.groupId != scene.groupId }
        prepared[scene.id] = Frame(plan: scene, images: images, ambient: ambient)
    }
    func commit(_ commit: PNCommit) { guard !shutdown, prepared[commit.planId]?.plan.groupId == commit.groupId else { return }; commits[commit.groupId] = commit; startTimer() }
    func control(_ control: PNControl) { guard !shutdown else { return }; controls.append(control); startTimer() }
    private func startTimer() {
        if timer != nil || !automaticRendering || shutdown { return }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.render()
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }
    func render() {
        guard !shutdown else { return }
        let now = clock.now
        layoutPreview.update(now)
        for command in controls.filter({ $0.effectiveAt <= now }) {
            switch command.operation {
            case "pause": pausedAt = pausedAt ?? command.effectiveAt
            case "resume":
                if let pausedAt {
                    let delay = max(0, command.effectiveAt - pausedAt)
                    for key in presentations.keys { presentations[key]?.resume(after: delay) }
                    for id in commits.keys { commits[id]?.startAt += delay }
                }; pausedAt = nil
            case "stop":
                stopped = true; closeSurfaces(); presentations.removeAll(); prepared.removeAll(); preparing.removeAll(); commits.removeAll()
                cancelFallback()
            case "start": stopped = false; pausedAt = nil
            default: break
            }
            changed?()
        }
        controls.removeAll { $0.effectiveAt <= now }
        if stopped { return }
        if pausedAt == nil {
            for commit in commits.values.filter({ $0.startAt <= now }) {
                guard var frame = prepared.removeValue(forKey: commit.planId) else { commits.removeValue(forKey: commit.groupId); continue }
                frame.start = commit.startAt
                for display in frame.plan.displays where display.selected && display.key.peerId == local {
                    if var old = presentations[display.key] {
                        old.replace(with: frame, at: now); presentations[display.key] = old
                    } else { presentations[display.key] = PNPresentation(frame: frame) }
                }
                commits.removeValue(forKey: commit.groupId); changed?()
                fallbackPlans.remove(commit.planId)
            }
        }
        let screens = screenProvider(), time = pausedAt ?? now
        for key in presentations.keys {
            presentations[key]?.advance(at: time, repeating: repeating && pausedAt == nil)
            guard let presentation = presentations[key], let id = UInt32(key.displayId),
                  let screen = screens.first(where: { $0.id == id }) else { continue }
            let surface = surfaces[key] ?? makeSurface(screen)
            surfaces[key] = surface
            surface.present(presentation.layers(for: key, at: time), on: screen, visible: !layoutPreview.visible)
        }
        for key in surfaces.keys.filter({ key in presentations[key] == nil || !screens.contains(where: { String($0.id) == key.displayId }) }) {
            surfaces.removeValue(forKey: key)?.close()
        }
        // Wait for real draw completion, rather than just window creation.
        if !isDisplaying && !surfaces.isEmpty && surfaces.values.allSatisfy(\.isReady) { enter(); isDisplaying = true; changed?() }
        if recovery == .standalone && fallback == nil && presentations.values.contains(where: { $0.age(at: time) >= $0.frame.plan.duration - 2 }) { rebuildLocal() }
    }
    func recover(_ state: PNRecoveryState, wall: PNSnapshot) {
        let selected = Set(wall.displays.filter { $0.selected && $0.key.peerId == local }.map(\.key))
        // Regrouping does not remove an old image while its replacement loads.
        for key in presentations.keys.filter({ !selected.contains($0) }) {
            presentations.removeValue(forKey: key); surfaces.removeValue(forKey: key)?.close()
        }
        snapshot = wall; guard recovery != state else { return }; recovery = state
        if [.isolatedRepeating, .standalone].contains(state) { repeating = true }
        if state == .synchronized { repeating = false; cancelFallback() }
        if state == .standalone && isDisplaying { rebuildLocal() }
        changed?()
    }
    private func rebuildLocal() {
        guard fallback == nil, let planner, let photos, var wall = snapshot, isDisplaying, !stopped, !shutdown else { return }
        wall.displays.removeAll { $0.key.peerId != local }
        let token = UUID(); fallbackToken = token
        fallback = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if fallbackToken == token { fallback = nil } }
            do {
                for group in Set(wall.displays.filter(\.selected).map(\.unit)) {
                    guard let plan = try await planner.prepare(wall: wall, group: group, photos: Array(photos.available.values)),
                          !Task.isCancelled && recovery == .standalone else { continue }
                    try await prepare(plan)
                    guard !Task.isCancelled && recovery == .standalone && !stopped else { continue }
                    fallbackPlans.insert(plan.id)
                    commit(PNCommit(planId: plan.id, groupId: group, startAt: clock.now + 0.25))
                }
            } catch { if !Task.isCancelled { WallLog.write("単体表示の準備を再試行します。", error: error) } }
        }
    }
    private func cancelFallback() {
        fallbackToken = UUID(); fallback?.cancel(); fallback = nil
        commits = commits.filter { !fallbackPlans.contains($0.value.planId) }
        prepared = prepared.filter { !fallbackPlans.contains($0.key) }
        fallbackPlans.removeAll()
    }
    private func closeSurfaces() { for surface in surfaces.values { surface.close() }; surfaces.removeAll() }
    func stop() {
        shutdown = true; timer?.cancel(); timer = nil; cancelFallback(); layoutPreview.close(); closeSurfaces()
        presentations.removeAll(); prepared.removeAll(); preparing.removeAll(); commits.removeAll(); controls.removeAll(); isDisplaying = false
    }
}
