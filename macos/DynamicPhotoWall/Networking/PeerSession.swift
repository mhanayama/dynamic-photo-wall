import Foundation

@MainActor protocol PNClock: AnyObject { var now: Double { get }; var elapsed: Double { get }; func observe(_ pong: PNPong) }
@MainActor final class PNSharedClock: PNClock {
    private let origin = ContinuousClock.now
    private let utc = Date().timeIntervalSince1970
    private var correction = 0.0, target = 0.0, previous = 0.0
    var elapsed: Double { let c = origin.duration(to: .now).components; return Double(c.seconds) + Double(c.attoseconds) / 1e18 }
    var now: Double {
        let e = elapsed; let step = max(0, e - previous) * 0.005; previous = e
        correction += min(step, max(-step, target - correction)); return utc + e + correction
    }
    func observe(_ pong: PNPong) {
        let received = now; let roundtrip = received - pong.sentAt - (pong.repliedAt - pong.receivedAt)
        if [received, pong.sentAt, pong.receivedAt, pong.repliedAt].allSatisfy(\.isFinite) && pong.repliedAt >= pong.receivedAt && roundtrip >= 0 && roundtrip <= 0.25 {
            target = correction + min(0.5, max(-0.5, ((pong.receivedAt - pong.sentAt) + (pong.repliedAt - received)) / 2))
        }
    }
}
nonisolated enum PNRecoveryState: String, Sendable { case listening, preparing, synchronized, isolatedRepeating, standalone }
nonisolated struct PNRecovery: Sendable {
    private(set) var state = PNRecoveryState.listening
    private var isolatedAt: Double?
    private var resumeAt: Double?
    mutating func connected() { state = .preparing }
    mutating func lost(at: Double, remaining: Bool) {
        resumeAt = nil
        if remaining { state = .synchronized }
        else { isolatedAt = isolatedAt ?? at; state = at - isolatedAt! >= 60 ? .standalone : .isolatedRepeating }
    }
    mutating func prepare(at: Double) { resumeAt = at; state = .preparing }
    mutating func tick(elapsed: Double, now: Double) {
        if let resumeAt, now >= resumeAt { state = .synchronized; self.resumeAt = nil; isolatedAt = nil }
        else if let isolatedAt, elapsed - isolatedAt >= 60 { state = .standalone }
    }
}
@MainActor protocol PNScenePlanning { func prepare(wall: PNSnapshot, group: UUID, photos: [PNPhoto]) async throws -> PNScene? }
@MainActor protocol PNPlaybackOutput: AnyObject {
    func prepare(_ scene: PNScene) async throws
    func commit(_ commit: PNCommit)
    func control(_ control: PNControl)
    func recover(_ state: PNRecoveryState, wall: PNSnapshot)
    func preview(_ plan: PNPreviewPlan)
    func stop()
}
extension PNPlaybackOutput { func preview(_ plan: PNPreviewPlan) {} }
@MainActor protocol PNNotifications { func disconnected(_ name: String); func reconnected(_ name: String) }

@MainActor final class PNSceneCoordinator {
    private struct Pending { var plan: PNScene; var waiting: Set<UUID>; var created: Double }
    private let planner: any PNScenePlanning; private let output: any PNPlaybackOutput; private let clock: any PNClock
    private var pending: [UUID: Pending] = [:]
    private var retryAt: [UUID: Double] = [:]
    private var current: [UUID: (plan: PNScene, started: Double, paused: Double)] = [:]
    private var pauseAt: Double?, pausedSeconds = 0.0
    private(set) var paused = false, stopped = false
    var status: PNPlaybackStatus { PNPlaybackStatus(paused: paused, stopped: stopped, effectiveAt: clock.now + 1) }
    func applyStatus(_ status: PNPlaybackStatus) throws {
        if stopped != status.stopped { try apply(PNControl(operation: status.stopped ? "stop" : "start", effectiveAt: status.effectiveAt)) }
        if paused != status.paused { try apply(PNControl(operation: status.paused ? "pause" : "resume", effectiveAt: status.effectiveAt)) }
    }
    var broadcast: ((PNPacket) async throws -> Void)?
    var committed: ((PNCommit) -> Void)?
    init(planner: any PNScenePlanning, output: any PNPlaybackOutput, clock: any PNClock) { self.planner = planner; self.output = output; self.clock = clock }
    func pump(local: UUID, wall: PNSnapshot, live: Set<UUID>, photos: [PNPhoto]) async throws {
        guard wall.leaderId == local, live.count > 1, !paused, !stopped, !photos.isEmpty else { return }
        pending = pending.filter { clock.elapsed - $0.value.created <= 35 }
        for (group, displays) in Dictionary(grouping: wall.displays.filter(\.selected), by: \.unit) {
            let participants = Set(displays.map { $0.key.peerId }).intersection(live)
            if participants.isEmpty || pending[group] != nil { continue }
            if let active = current[group], active.plan.settingsRevision == wall.revision && clock.now - active.started - (pausedSeconds - active.paused) < active.plan.duration - 4 { continue }
            if let retry = retryAt[group], clock.elapsed < retry { continue }
            guard let plan = try await planner.prepare(wall: wall, group: group, photos: photos) else { retryAt[group] = clock.elapsed + 5; continue }
            retryAt.removeValue(forKey: group)
            try plan.validate(); pending[group] = Pending(plan: plan, waiting: participants, created: clock.elapsed)
            try await broadcast?(PNPacket("scenePrepare", plan))
            if participants.contains(local) { try await output.prepare(plan); pending[group]?.waiting.remove(local) }
            try await tryCommit(group)
        }
    }
    func ready(_ peer: UUID, _ ready: PNReady) async throws {
        guard pending[ready.groupId]?.plan.id == ready.planId else { return }
        pending[ready.groupId]?.waiting.remove(peer); try await tryCommit(ready.groupId)
    }
    func lost(_ peer: UUID) async throws { for group in Array(pending.keys) { pending[group]?.waiting.remove(peer); try await tryCommit(group) } }
    private func tryCommit(_ group: UUID) async throws {
        guard let item = pending[group], item.waiting.isEmpty else { return }
        let commit = PNCommit(planId: item.plan.id, groupId: group, startAt: clock.now + 2)
        observe(item.plan, commit); pending.removeValue(forKey: group)
        try await broadcast?(PNPacket("sceneCommit", commit)); output.commit(commit); committed?(commit)
    }
    func observe(_ plan: PNScene, _ commit: PNCommit) { current[plan.groupId] = (plan, commit.startAt, pausedSeconds) }
    func control(_ operation: String) async throws {
        try PNWire.require(["pause", "resume", "start", "stop", "next"].contains(operation), "Unknown playback operation")
        let command = PNControl(operation: operation, effectiveAt: clock.now + 1); try apply(command)
        try await broadcast?(PNPacket("playbackControl", command))
    }
    func apply(_ command: PNControl) throws {
        switch command.operation {
        case "pause": if !paused { paused = true; pauseAt = command.effectiveAt }
        case "resume": if let pauseAt { pausedSeconds += max(0, command.effectiveAt - pauseAt) }; paused = false; pauseAt = nil
        case "stop": stopped = true
        case "start": stopped = false; paused = false; pauseAt = nil; invalidate()
        case "next": invalidate()
        default: throw PNError.invalid("Unknown playback operation")
        }
        output.control(command)
    }
    func invalidate() { current.removeAll(); pending.removeAll(); retryAt.removeAll(); pausedSeconds = 0 }
    func leadershipChanged() { pending.removeAll(); retryAt.removeAll() }
}

// Session composes state authority, transport, transfer and playback ports. It
// owns membership and routing; none of the individual modules owns AppModel.
@MainActor final class PNPeerSession {
    private struct LinkState { var link: any PNPeerLink; var seen: Double }
    let local: PNHello; private let displays: [PNDisplay]
    private let transport: any PNTransport; private let discovery: any PNDiscovery
    private let persistence: PNStateStore; private let provider: any PNPhotoProviding
    let photos: PNPhotoTransfers
    private let scenes: PNSceneCoordinator; private let output: any PNPlaybackOutput
    let clock: any PNClock; private let notifications: any PNNotifications
    private(set) var snapshot: PNSnapshot
    private(set) var candidates: [UUID: PNCandidate] = [:]
    private var discovered: [UUID: Double] = [:], targets: [UUID: PNCandidate] = [:]
    private var links: [UUID: LinkState] = [:], connecting: Set<UUID> = []
    private var disconnectedPeers: Set<UUID> = []
    private var displayInventories: [UUID: Set<PNDisplayKey>] = [:]
    private var readTasks: [UUID: Task<Void, Never>] = [:], jobs: [UUID: Task<Void, Never>] = [:]
    private var remoteSources: [PNSource] = [], knownPlans: [UUID: PNScene] = [:]
    private var results: [UUID: PNResult] = [:]
    private var explicitJoins: [UUID: PNSnapshot] = [:], migrations: Set<UUID> = []
    private var proposals: [UUID: CheckedContinuation<PNResult, Error>] = [:]
    private var notices: Set<UUID> = []
    private var timer: Task<Void, Never>?
    private var recovery = PNRecovery()
    private var retryAt = -100.0, maintenanceAt = -100.0
    private var stopped = false, pumping = false
    var changed: (() -> Void)?
    var failed: ((Error) -> Void)?
    var connectedPeers: Set<UUID> { Set(links.keys) }
    var connectedDisplays: Set<PNDisplayKey> {
        guard !stopped else { return [] }
        return Set(displays.map(\.key)).union(displayInventories.filter { links[$0.key] != nil }.values.flatMap { $0 })
    }
    func peerName(_ peerId: UUID) -> String {
        if peerId == local.peerId { return local.name }
        return links[peerId]?.link.remote.name ?? targets[peerId]?.hello.name ?? candidates[peerId]?.hello.name ?? "未接続の端末"
    }
    var sources: [PNSource] { provider.sources + remoteSources }
    func isSourceConnected(_ source: PNSource) -> Bool {
        guard !stopped else { return false }
        if source.providerId == local.peerId { return provider.sources.contains { $0.sourceId == source.sourceId } }
        return links[source.providerId] != nil && displayInventories[source.providerId] != nil
            && remoteSources.contains { $0.providerId == source.providerId && $0.sourceId == source.sourceId }
    }
    var playbackState: PNRecoveryState { recovery.state }
    var playbackPaused: Bool { scenes.paused }
    var playbackStopped: Bool { scenes.stopped }
    private var selfCandidate: PNCandidate { PNCandidate(hello: local, host: "127.0.0.1", port: transport.port) }
    init(local: PNHello, displays: [PNDisplay], transport: any PNTransport, discovery: any PNDiscovery,
         persistence: PNStateStore, provider: any PNPhotoProviding, cache: PNPhotoCache, planner: any PNScenePlanning,
         output: any PNPlaybackOutput, clock: any PNClock, notifications: any PNNotifications, initial: PNSnapshot) throws {
        self.local = local; self.displays = displays; self.transport = transport; self.discovery = discovery
        self.persistence = persistence; self.provider = provider; self.output = output; self.clock = clock; self.notifications = notifications
        snapshot = try persistence.load() ?? initial
        photos = PNPhotoTransfers(local: local.peerId, provider: provider, cache: cache)
        scenes = PNSceneCoordinator(planner: planner, output: output, clock: clock)
        scenes.broadcast = { [weak self] in try await self?.broadcast($0) }
        scenes.committed = { [weak self] in self?.recovery.prepare(at: $0.startAt) }
        photos.produced = { [weak self] in try await self?.broadcast(PNPacket("catalog", $0)) }
        photos.changed = { [weak self] in self?.changed?() }
        discovery.found = { [weak self] in guard let self else { return }; candidates[$0.id] = $0; discovered[$0.id] = clock.elapsed; changed?() }
    }
    func start(automaticPump: Bool = true) async throws {
        if snapshot.leaderId == local.peerId {
            _ = try refreshDisplayNames(displays)
            let added = displays.filter { d in !snapshot.displays.contains { $0.key == d.key } }.map { d in var d = d; d.groupId = nil; return d }
            if !added.isEmpty { var next = snapshot; next.displays += added; next.revision += 1; try adopt(next) }
        }
        try await photos.configure(snapshot.sources)
        try await transport.start { [weak self] link in await self?.attach(link) }
        try discovery.start(local, port: transport.port)
        if automaticPump { timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)); try await self?.pump() }
                catch is CancellationError { return } catch { self?.failed?(error) }
            }
        } }
    }
    func connect(_ candidate: PNCandidate, userInitiated: Bool = true) async throws {
        if userInitiated { disconnectedPeers.remove(candidate.id) }
        guard !disconnectedPeers.contains(candidate.id) else { return }
        targets[candidate.id] = candidate
        guard !connecting.contains(candidate.id), links[candidate.id] == nil else { return }
        if userInitiated { explicitJoins[candidate.id] = snapshot }
        connecting.insert(candidate.id); defer { connecting.remove(candidate.id) }
        let link = try await transport.connect(candidate)
        background { [weak self] in await self?.attach(link) }
    }
    func disconnect(_ peer: UUID) async {
        guard peer != local.peerId else { return }
        disconnectedPeers.insert(peer); explicitJoins.removeValue(forKey: peer)
        await remove(peer)
        changed?()
    }
    private func attach(_ link: any PNPeerLink) async {
        let id = link.remote.peerId
        guard !disconnectedPeers.contains(id), !stopped else { link.close(); return }
        if let old = links[id] {
            let outbound = local.peerId.pnHex < id.pnHex
            if old.link.outbound == outbound || link.outbound != outbound { link.close(); return }
            old.link.close()
        }
        displayInventories.removeValue(forKey: id)
        links[id] = LinkState(link: link, seen: clock.elapsed)
        if notices.remove(id) != nil { notifications.reconnected(link.remote.name) }
        recovery.connected()
        do {
            try await link.send(PNPacket("inventory", PNInventory(candidate: selfCandidate, displays: displays, sources: provider.sources)))
            if !link.outbound { try await link.send(PNPacket("welcome", PNNotice(snapshot: snapshot, members: Array(links.keys) + [local.peerId]))) }
            if snapshot.leaderId == local.peerId { try await link.send(PNPacket("playbackStatus", scenes.status)) }
            let own = photos.catalog.values.filter { $0.key.providerId == local.peerId }
            for photo in own { try await link.send(PNPacket("catalog", PNCatalog(photos: [photo]))) }
            while !stopped, let packet = try await link.receive() {
                guard let current = links[id], current.link === link else { break }
                links[id]?.seen = clock.elapsed; try await handle(link, packet)
            }
        } catch { if !stopped && !disconnectedPeers.contains(id) { failed?(error) } }
        link.close()
        if let current = links[id], current.link === link { await remove(id) }
    }
    private func handle(_ link: any PNPeerLink, _ packet: PNPacket) async throws {
        let peer = link.remote.peerId
        switch packet.type {
        case "inventory":
            let inventory = try packet.decode(PNInventory.self)
            try PNWire.require(inventory.displays.count <= 128 && Set(inventory.displays.map(\.key)).count == inventory.displays.count, "Invalid display inventory")
            for display in inventory.displays { try display.validate() }
            try PNWire.require(inventory.candidate.id == peer && inventory.displays.allSatisfy { $0.key.peerId == peer } && inventory.sources.allSatisfy { $0.providerId == peer }, "Inventory identity differs")
            var endpoint = inventory.candidate; endpoint.host = link.remoteHost; targets[peer] = endpoint; candidates[peer] = endpoint
            if discovered[peer] == nil { discovered[peer] = clock.elapsed }
            displayInventories[peer] = Set(inventory.displays.map(\.key))
            remoteSources.removeAll { $0.providerId == peer }; remoteSources += inventory.sources
            if snapshot.leaderId == local.peerId {
                let renamed = try refreshDisplayNames(inventory.displays)
                let added = inventory.displays.filter { d in !snapshot.displays.contains { $0.key == d.key } }.map { d in var d = d; d.groupId = nil; return d }
                if !added.isEmpty { var next = snapshot; next.displays += added; next.revision += 1; try adopt(next) }
                if renamed || !added.isEmpty { try await publish() }
            }
        case "welcome":
            let notice = try packet.decode(PNNotice.self); try notice.snapshot.validate()
            if link.outbound { try await joinWall(link, notice) }
        case "wallMergeRequest": try await mergeWall(packet.decode(PNMergeRequest.self))
        case "wallMigration": try await migrateWall(link, packet.decode(PNMigration.self))
        case "snapshot":
            let notice = try packet.decode(PNNotice.self); try notice.snapshot.validate()
            if notice.snapshot.leaderId == peer && snapshot.prefers(notice.snapshot) { try adopt(notice.snapshot); try await applyState() }
        case "propose":
            let result = try apply(packet.decode(PNProposal.self)); try await link.send(PNPacket("stateResult", result))
            if result.accepted { try await applyState(); try await publish() }
        case "stateResult":
            let result = try packet.decode(PNResult.self)
            if peer == snapshot.leaderId, let continuation = proposals.removeValue(forKey: result.requestId) {
                if result.accepted { try adopt(result.snapshot); try await applyState() }; continuation.resume(returning: result)
            }
        case "heartbeat":
            let beat = try packet.decode(PNHeartbeat.self)
            for member in beat.members where member.id != local.peerId && member.port > 0 && member.port <= 65535 {
                try member.hello.validate(); if targets[member.id] == nil { targets[member.id] = member }
            }
            if snapshot.leaderId == local.peerId && (beat.sessionId != snapshot.sessionId || beat.revision < snapshot.revision) { try await link.send(PNPacket("snapshot", PNNotice(snapshot: snapshot, members: Array(links.keys) + [local.peerId]))) }
        case "clockPing":
            let ping = try packet.decode(PNPing.self); let at = clock.now
            try await link.send(PNPacket("clockPong", PNPong(requestId: ping.requestId, sentAt: ping.sentAt, receivedAt: at, repliedAt: clock.now)))
        case "clockPong": if peer == snapshot.leaderId { clock.observe(try packet.decode(PNPong.self)) }
        case "catalog": for request in try await photos.accept(peer, packet.decode(PNCatalog.self)) { try await link.send(PNPacket("assetRequest", request)) }
        case "assetRequest": let request = try packet.decode(PNAssetRequest.self); background { [weak self] in try await self?.photos.send(request, to: link) }
        case "assetChunk":
            if try await photos.receive(peer, packet.decode(PNChunk.self)) {
                for request in photos.missing(peer) { try await link.send(PNPacket("assetRequest", request)) }
            }
            return // Transfers notify after a whole photo, rather than each chunk.
        case "scenePrepare":
            guard peer == snapshot.leaderId else { break }
            let scene = try packet.decode(PNScene.self); try scene.validate()
            guard scene.sessionId == snapshot.sessionId && scene.settingsRevision == snapshot.revision else { break }
            knownPlans[scene.id] = scene
            if knownPlans.count > 256 { knownPlans.removeValue(forKey: knownPlans.keys.first!) }
            if scene.displays.contains(where: { $0.key.peerId == local.peerId }) {
                background { [weak self] in
                    guard let self else { return }
                    let keys = scene.placements.filter { p in p.displayId == nil || scene.displays.contains { $0.key.peerId == self.local.peerId && $0.id == p.displayId } }.map(\.asset)
                    let began = clock.elapsed
                    while !keys.allSatisfy({ self.photos.available[$0.opaqueId] != nil }) {
                        try PNWire.require(clock.elapsed - began < 30, "Photo preparation timed out"); try await Task.sleep(for: .milliseconds(100))
                    }
                    guard scene.sessionId == snapshot.sessionId && scene.settingsRevision == snapshot.revision else { return }
                    try await output.prepare(scene); try await link.send(PNPacket("sceneReady", PNReady(planId: scene.id, groupId: scene.groupId)))
                }
            }
        case "sceneReady": if snapshot.leaderId == local.peerId { try await scenes.ready(peer, packet.decode(PNReady.self)) }
        case "sceneCommit":
            if peer == snapshot.leaderId {
                let commit = try packet.decode(PNCommit.self); output.commit(commit)
                if let scene = knownPlans[commit.planId] { scenes.observe(scene, commit) }; recovery.prepare(at: max(clock.now + 0.01, commit.startAt))
            }
        case "playbackRequest": if snapshot.leaderId == local.peerId { try await scenes.control(packet.decode(PNOperation.self).operation) }
        case "playbackControl": if peer == snapshot.leaderId { try scenes.apply(packet.decode(PNControl.self)) }
        case "playbackStatus": if peer == snapshot.leaderId { try scenes.applyStatus(packet.decode(PNPlaybackStatus.self)) }
        case "layoutPreviewRequest": if snapshot.leaderId == local.peerId { try await schedulePreview(packet.decode(PNPreviewRequest.self)) }
        case "layoutPreview": if peer == snapshot.leaderId { output.preview(try packet.decode(PNPreviewPlan.self)) }
        default: throw PNError.invalid("Unknown peer message")
        }
        changed?()
    }
    private func adopt(_ next: PNSnapshot) throws { try next.validate(); try persistence.save(next); snapshot = next }
    private func applyState() async throws { scenes.invalidate(); try await photos.configure(snapshot.sources); changed?() }
    private func apply(_ proposal: PNProposal) throws -> PNResult {
        if let previous = results[proposal.requestId] { return previous }
        if snapshot.appliedRequests.contains(proposal.requestId) { return PNResult(requestId: proposal.requestId, accepted: true, snapshot: snapshot) }
        let result: PNResult
        if snapshot.leaderId != local.peerId || proposal.expectedRevision != snapshot.revision {
            result = PNResult(requestId: proposal.requestId, accepted: false, error: "他のピアで設定が更新されました。最新版を読み直してください。", snapshot: snapshot)
        } else {
            var next = snapshot; next.revision += 1; next.groups = proposal.groups; next.displays = proposal.displays; next.sources = proposal.sources; next.playback = proposal.playback
            next.appliedRequests = Array((next.appliedRequests + [proposal.requestId]).suffix(1024))
            do { try adopt(next); result = PNResult(requestId: proposal.requestId, accepted: true, snapshot: snapshot) }
            catch { result = PNResult(requestId: proposal.requestId, accepted: false, error: error.localizedDescription, snapshot: snapshot) }
        }
        results[proposal.requestId] = result; if results.count > 1024 { results.removeValue(forKey: results.keys.first!) }; return result
    }
    func propose(_ proposal: PNProposal) async throws -> PNResult {
        if snapshot.leaderId == local.peerId { let result = try apply(proposal); if result.accepted { try await applyState(); try await publish() }; return result }
        guard let leader = links[snapshot.leaderId]?.link else { throw PNError.invalid("進行役へ再接続中です。") }
        return try await withCheckedThrowingContinuation { continuation in
            proposals[proposal.requestId] = continuation
            background { [weak self] in
                do { try await leader.send(PNPacket("propose", proposal)); try await Task.sleep(for: .seconds(15)); self?.proposals.removeValue(forKey: proposal.requestId)?.resume(throwing: PNError.invalid("設定の反映がタイムアウトしました。")) }
                catch { self?.proposals.removeValue(forKey: proposal.requestId)?.resume(throwing: error) }
            }
        }
    }
    func control(_ operation: String) async throws {
        if snapshot.leaderId == local.peerId { try await scenes.control(operation) }
        else if let leader = links[snapshot.leaderId]?.link { try await leader.send(PNPacket("playbackRequest", PNOperation(requestId: UUID(), operation: operation))) }
    }
    private func publish() async throws { try await broadcast(PNPacket("snapshot", PNNotice(snapshot: snapshot, members: Array(links.keys) + [local.peerId]))) }
    private func refreshDisplayNames(_ inventory: [PNDisplay]) throws -> Bool {
        var next = snapshot
        for index in next.displays.indices {
            if let name = inventory.first(where: { $0.key == next.displays[index].key })?.name,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                next.displays[index].name = name
            }
        }
        guard next.displays != snapshot.displays else { return false }
        next.revision += 1; try adopt(next); return true
    }
    func preview(_ request: PNPreviewRequest) async throws {
        if snapshot.leaderId == local.peerId { try await schedulePreview(request) }
        else if let leader = links[snapshot.leaderId]?.link { try await leader.send(PNPacket("layoutPreviewRequest", request)) }
    }
    private func schedulePreview(_ request: PNPreviewRequest) async throws {
        var proposed = snapshot; proposed.displays = request.displays; proposed.groups = request.groups; try proposed.validate()
        let plan = PNPreviewPlan(enabled: request.enabled, effectiveAt: clock.now + 1, displays: request.displays, groups: request.groups)
        try await broadcast(PNPacket("layoutPreview", plan)); output.preview(plan)
    }
    private func broadcast(_ packet: PNPacket) async throws {
        for item in Array(links.values) { do { try await item.link.send(packet) } catch { if !stopped && !disconnectedPeers.contains(item.link.remote.peerId) { failed?(error) } } }
    }
    private func remove(_ peer: UUID) async {
        guard let item = links.removeValue(forKey: peer) else { return }; item.link.close(); photos.lost(peer)
        displayInventories.removeValue(forKey: peer)
        do { try await scenes.lost(peer) } catch { failed?(error) }
        if !disconnectedPeers.contains(peer) && !stopped && notices.insert(peer).inserted { notifications.disconnected(item.link.remote.name) }
        recovery.lost(at: clock.elapsed, remaining: !links.isEmpty)
        if snapshot.leaderId == peer && (Array(links.keys) + [local.peerId]).min(by: { $0.pnHex < $1.pnHex }) == local.peerId {
            var next = snapshot; next.leaderId = local.peerId; next.sessionId = UUID(); next.term += 1
            do { try adopt(next); scenes.leadershipChanged(); try await publish() } catch { failed?(error) }
        }
        output.recover(recovery.state, wall: snapshot); changed?()
    }
    func pump() async throws {
        guard !stopped && !pumping else { return }; pumping = true; defer { pumping = false }
        for peer in links.keys.filter({ clock.elapsed - links[$0]!.seen > 6 }) { await remove(peer) }
        for peer in discovered.keys.filter({ clock.elapsed - discovered[$0]! > 8 && links[$0] == nil }) { discovered.removeValue(forKey: peer); candidates.removeValue(forKey: peer) }
        recovery.tick(elapsed: clock.elapsed, now: clock.now); output.recover(recovery.state, wall: snapshot)
        let members = links.keys.compactMap { targets[$0] } + [selfCandidate]
        try await broadcast(PNPacket("heartbeat", PNHeartbeat(members: members, leaderId: snapshot.leaderId, sessionId: snapshot.sessionId, revision: snapshot.revision)))
        if snapshot.leaderId != local.peerId, let leader = links[snapshot.leaderId]?.link { try await leader.send(PNPacket("clockPing", PNPing(requestId: UUID(), sentAt: clock.now))) }
        try await scenes.pump(local: local.peerId, wall: snapshot, live: Set(links.keys).union([local.peerId]), photos: Array(photos.available.values))
        for item in Array(links.values) { for request in photos.missing(item.link.remote.peerId) { try await item.link.send(PNPacket("assetRequest", request)) } }
        if clock.elapsed - retryAt > 5 {
            retryAt = clock.elapsed
            for candidate in targets.values where links[candidate.id] == nil { background { [weak self] in try await self?.connect(candidate, userInitiated: false) } }
        }
        if clock.elapsed - maintenanceAt > 60 { maintenanceAt = clock.elapsed; try await photos.maintain() }
        changed?()
    }
    func refreshPhotos() { photos.refresh(); background { [weak self] in guard let self else { return }; try await broadcast(PNPacket("inventory", PNInventory(candidate: selfCandidate, displays: displays, sources: provider.sources))) } }
    private func background(_ action: @escaping @MainActor () async throws -> Void) {
        let id = UUID(); jobs[id] = Task { @MainActor [weak self] in
            defer { self?.jobs.removeValue(forKey: id) }
            do { try await action() } catch { if self?.stopped == false { self?.failed?(error) } }
        }
    }
    func stop() {
        stopped = true; timer?.cancel(); timer = nil; discovery.stop(); transport.stop(); photos.stop(); output.stop()
        for item in links.values { item.link.close() }; links.removeAll()
        for job in jobs.values { job.cancel() }; jobs.removeAll(); for task in readTasks.values { task.cancel() }; readTasks.removeAll()
        for continuation in proposals.values { continuation.resume(throwing: CancellationError()) }; proposals.removeAll()
    }
}

extension PNPeerSession {
    private func endpoints() -> [PNCandidate] { targets.values.filter { links[$0.id] != nil } + [selfCandidate] }
    private func joinWall(_ link: any PNPeerLink, _ notice: PNNotice) async throws {
        let selected = explicitJoins.removeValue(forKey: link.remote.peerId)
        let previous = selected ?? snapshot
        if previous.wallId == notice.snapshot.wallId {
            if snapshot.prefers(notice.snapshot) { try adopt(notice.snapshot); try await applyState() }; return
        }
        if selected == nil && !notice.snapshot.mergedWalls.contains(previous.wallId) {
            if previous.mergedWalls.contains(notice.snapshot.wallId) { try await link.send(PNPacket("wallMigration", PNMigration(requestId: UUID(), previousWallId: notice.snapshot.wallId, snapshot: previous, members: endpoints()))) }
            return
        }
        let members = endpoints(); try adopt(notice.snapshot); try await applyState()
        try await link.send(PNPacket("inventory", PNInventory(candidate: selfCandidate, displays: displays, sources: provider.sources)))
        if selected != nil { try await link.send(PNPacket("wallMergeRequest", PNMergeRequest(requestId: UUID(), previous: previous, members: members))) }
    }
    private func mergeWall(_ request: PNMergeRequest) async throws {
        try request.previous.validate(); try PNWire.require(request.members.count <= 128, "Invalid wall merge")
        if snapshot.leaderId != local.peerId {
            if let leader = links[snapshot.leaderId]?.link { try await leader.send(PNPacket("wallMergeRequest", request)) }; return
        }
        if migrations.contains(request.requestId) || request.previous.wallId == snapshot.wallId { return }
        let next = try PNWallMerge.merge(current: snapshot, previous: request.previous)
        try adopt(next); try await applyState(); migrations.insert(request.requestId)
        var members = endpoints(); for member in request.members where !members.contains(where: { $0.id == member.id }) { members.append(member) }
        try await broadcast(PNPacket("wallMigration", PNMigration(requestId: request.requestId, previousWallId: request.previous.wallId, snapshot: next, members: members))); try await publish()
    }
    private func migrateWall(_ link: any PNPeerLink, _ migration: PNMigration) async throws {
        try migration.snapshot.validate(); try PNWire.require(migration.members.count <= 128 && migration.snapshot.mergedWalls.contains(migration.previousWallId), "Invalid wall migration")
        if !migrations.insert(migration.requestId).inserted { return }
        if migrations.count > 1024 { migrations.remove(migrations.first!) }
        guard snapshot.wallId == migration.previousWallId || snapshot.wallId == migration.snapshot.wallId else { return }
        if snapshot.wallId == migration.previousWallId || snapshot.prefers(migration.snapshot) { try adopt(migration.snapshot); try await applyState() }
        var updated = migration
        updated.members = migration.members.map { member in
            if member.id == link.remote.peerId { var value = member; value.host = link.remoteHost; return value }
            return targets[member.id] ?? member
        }
        for member in updated.members where member.id != local.peerId { targets[member.id] = member }
        try await broadcast(PNPacket("wallMigration", updated))
    }
}
