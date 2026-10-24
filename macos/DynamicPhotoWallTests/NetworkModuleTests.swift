import Foundation
import CryptoKit
import Testing
@testable import DynamicPhotoWall

@MainActor struct NetworkModuleTests {
    private nonisolated struct Vector: Decodable, Sendable {
        var masterKey: Data; var original: Data; var encrypted: Data; var now: Date
        var photo: PNPhoto; var wall: PNSnapshot; var scene: PNScene; var packet: PNPacket
        var opaqueId: String; var layoutId: String
    }
    private func vector() throws -> Vector {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try PNWire.decode(Vector.self, Data(contentsOf: root.appending(path: "tests/Fixtures/NetworkWire.v1.json")))
    }
    @Test func windowsWireValuesAndNativeValuesHaveTheSameIdentity() throws {
        let v = try vector(); try v.photo.validate(); try v.wall.validate(); try v.scene.validate()
        #expect(v.photo.key.opaqueId == v.opaqueId)
        #expect(v.wall.displays[0].id == v.layoutId)
        #expect(try v.packet.decode(PNScene.self).id == v.scene.id)
        #expect(v.photo.faceMetadata.faces == [PNFaceRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.4)])
        #expect(v.scene.placements[0].evaluate(2).x == -20)
        #expect(abs(v.scene.placements[0].evaluate(2.1).x - (-21)) < 1e-9)
        let roundtrip = try PNWire.decode(PNSnapshot.self, PNWire.encode(v.wall))
        #expect(roundtrip == v.wall)
        #expect(roundtrip.displays[0].name == "DELL U2723QE")
        #expect(roundtrip.displays[1].displayName == "Studio Display")
    }
    @Test func displayNamesAreOptionalWithoutChangingTheLayoutIdentity() throws {
        let v = try vector(); let display = v.wall.displays[0]
        var value = try #require(JSONSerialization.jsonObject(with: PNWire.encode(display)) as? [String: Any])
        value.removeValue(forKey: "name")
        let legacy = try PNWire.decode(PNDisplay.self, JSONSerialization.data(withJSONObject: value))
        #expect(legacy.name == nil); #expect(legacy.displayName == "ディスプレイ")
        #expect(legacy.key == display.key); #expect(legacy.id == display.id)
    }
    @Test func windowsEncryptedOriginalIsReadableNativelyAndExpiresWithoutExtension() async throws {
        let v = try vector(); let root = FileManager.default.temporaryDirectory.appending(path: "DPW.Network.Cache.\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try PNPhotoCache(root: root, key: SymmetricKey(data: v.masterKey))
        let key = v.photo.key; try await cache.activate(key.providerId, key.generationId)
        let file = root.appending(path: key.providerId.pnHex).appending(path: key.generationId.pnHex).appending(path: key.opaqueId + ".pwc")
        try v.encrypted.write(to: file)
        #expect(try await cache.read(key, now: v.now) == v.original)
        let headers = try await cache.catalog(now: v.now.addingTimeInterval(10))
        #expect(headers.count == 1)
        #expect(headers[0].photo == v.photo)
        #expect(try await cache.read(key, now: v.now.addingTimeInterval(14 * 86400 - 1)) == v.original)
        #expect(try await cache.read(key, now: v.now.addingTimeInterval(14 * 86400)) == nil)
        try await cache.put(v.photo, original: v.original, now: v.now)
        #expect(try await cache.read(key, now: v.now) == v.original)
        var corrupt = try Data(contentsOf: file); corrupt[corrupt.count - 1] ^= 1; try corrupt.write(to: file)
        await #expect(throws: (any Error).self) { try await cache.read(key, now: v.now) }
        try await cache.activate(key.providerId, UUID())
        #expect(!FileManager.default.fileExists(atPath: file.path))
        await #expect(throws: (any Error).self) { try await cache.put(v.photo, original: v.original, now: v.now) }
    }
    @Test func nativeRecoveryKeepsTheSixtySecondDeadlineDuringRetries() {
        var state = PNRecovery(); state.connected(); state.prepare(at: 1002); state.tick(elapsed: 2, now: 1002)
        #expect(state.state == .synchronized)
        state.lost(at: 10, remaining: true); #expect(state.state == .synchronized)
        state.lost(at: 12, remaining: false); state.tick(elapsed: 71.999, now: 1072)
        #expect(state.state == .isolatedRepeating)
        state.connected(); state.lost(at: 50, remaining: false); state.tick(elapsed: 72, now: 1073)
        #expect(state.state == .standalone)
        state.connected(); state.prepare(at: 1100); state.tick(elapsed: 80, now: 1099)
        #expect(state.state != .synchronized)
        state.tick(elapsed: 81, now: 1100); #expect(state.state == .synchronized)
    }
    @Test func nativePrepareBarrierUsesFutureSharedTime() async throws {
        let v = try vector(); let clock = Clock(); let output = Output(); let planner = Planner(scene: v.scene)
        let coordinator = PNSceneCoordinator(planner: planner, output: output, clock: clock)
        var packets: [PNPacket] = []; coordinator.broadcast = { packets.append($0) }
        let live = Set(v.wall.displays.map { $0.key.peerId })
        try await coordinator.pump(local: v.wall.leaderId, wall: v.wall, live: live, photos: [v.photo])
        #expect(output.prepared == 1); #expect(output.commits.isEmpty); #expect(packets.count == 1)
        clock.time = 10
        let other = try #require(live.first { $0 != v.wall.leaderId })
        try await coordinator.ready(other, PNReady(planId: v.scene.id, groupId: v.scene.groupId))
        #expect(output.commits.count == 1); #expect(output.commits[0].startAt == 1012)
    }
    @Test func planningCatalogRefreshesFacesDimensionsMembershipAndOrder() async throws {
        let v = try vector(), catalog = PNPlanningCatalog()
        let first = v.photo
        var second = first; second.key.imageId = PNWire.digest(Data("second".utf8))
        second.faceMetadata.state = "pending"; second.faceMetadata.faces = []
        var third = second; third.key.imageId = PNWire.digest(Data("third".utf8)); third.faceMetadata.state = "failed"
        let initial = try await catalog.prepare([first, second, third])
        let firstURL = URL(string: "peer-cache://image/\(first.key.opaqueId)")!
        let thirdURL = URL(string: "peer-cache://image/\(third.key.opaqueId)")!
        #expect(initial.assets.map(\.url) == [firstURL, thirdURL])
        #expect(initial.byID[first.key.opaqueId]?.faces == first.faceMetadata.faces.map { FaceRegion(x: $0.x, y: $0.y, width: $0.width, height: $0.height) })
        #expect(initial.byURL[thirdURL] == third)
        #expect(initial.byID[second.key.opaqueId] == nil)
        let repeated = try await catalog.prepare([first, second, third])
        #expect(repeated.assets == initial.assets && repeated.byURL == initial.byURL && repeated.byID == initial.byID)
        second.faceMetadata.state = "complete"
        second.faceMetadata.faces = [PNFaceRegion(x: 0.2, y: 0.3, width: 0.1, height: 0.1)]
        second.pixelWidth = 1200; second.faceMetadata.pixelWidth = 1200; second.byteLength += 1
        let updated = try await catalog.prepare([second, first])
        #expect(updated.assets.map(\.url) == [URL(string: "peer-cache://image/\(second.key.opaqueId)")!, firstURL])
        #expect(updated.assets[0].pixelWidth == 1200 && updated.assets[0].fileSize == Int64(second.byteLength))
        #expect(updated.assets[0].faces == [FaceRegion(x: 0.2, y: 0.3, width: 0.1, height: 0.1)])
        #expect(updated.byID[third.key.opaqueId] == nil && updated.byURL[thirdURL] == nil)
        #expect(initial.assets.map(\.url) == [firstURL, thirdURL]) // Prior scenes retain their immutable snapshot.
        #expect(try await catalog.prepare([]).assets.isEmpty)
    }
    @Test func cancelledPlanningCatalogRequestDoesNotPublishItsMetadata() async throws {
        let v = try vector(), catalog = PNPlanningCatalog()
        let original = try await catalog.prepare([v.photo])
        var changed = v.photo; changed.pixelWidth += 100
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await catalog.prepare([changed])
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await catalog.prepare([v.photo]).assets == original.assets)
        #expect(try await catalog.prepare([changed]).assets[0].pixelWidth == changed.pixelWidth)
    }
    @Test func delayedScenePreparationCannotUndoNextStopOrLeadershipChange() async throws {
        let v = try vector()
        for phase in ["planner", "output"] {
            for operation in ["next", "stop", "leadership"] {
                let clock = Clock(), output = Output(), planner = Planner(scene: v.scene)
                let coordinator = PNSceneCoordinator(planner: planner, output: output, clock: clock)
                var packets: [PNPacket] = []; coordinator.broadcast = { packets.append($0) }
                var release: (() -> Void)?, pump: Task<Void, Error>?
                await withCheckedContinuation { began in
                    let wait: @MainActor () async -> Void = {
                        await withCheckedContinuation { finish in
                            release = { finish.resume() }; began.resume()
                        }
                    }
                    if phase == "planner" { planner.beforePrepare = wait } else { output.beforePrepare = wait }
                    pump = Task {
                        try await coordinator.pump(local: v.wall.leaderId, wall: v.wall,
                            live: Set(v.wall.displays.map { $0.key.peerId }), photos: [v.photo])
                    }
                }
                if operation == "leadership" { coordinator.leadershipChanged() }
                else { try coordinator.apply(PNControl(operation: operation, effectiveAt: clock.now)) }
                let finish = try #require(release), task = try #require(pump)
                finish(); try await task.value
                let remote = try #require(v.wall.displays.first { $0.key.peerId != v.wall.leaderId }?.key.peerId)
                try await coordinator.ready(remote, PNReady(planId: v.scene.id, groupId: v.scene.groupId))
                #expect(output.commits.isEmpty)
                #expect(!packets.contains { $0.type == "sceneCommit" })
                if phase == "planner" { #expect(output.prepared == 0 && packets.isEmpty) }
            }
        }
    }
    @Test func sceneTimelineConversionPreservesAllPlacementFields() throws {
        let v = try vector()
        let asset = PhotoAsset(url: URL(string: "peer-cache://image/\(v.photo.key.opaqueId)")!,
            pixelWidth: v.photo.pixelWidth, pixelHeight: v.photo.pixelHeight)
        for fades in [false, true] {
            var placement = v.scene.placements[0]
            placement.id = 17; placement.displayId = v.wall.displays[1].id
            placement.clip = PNRect(x: -120.25, y: 30.5, width: 1800.75, height: 900.125)
            placement.width = 3200.5; placement.height = 1100.25
            placement.fromX = -700.5; placement.fromY = 20.25; placement.toX = 45.75; placement.toY = -21.5
            placement.fromScale = 1.125; placement.toScale = 1.75; placement.centerX = 0.3; placement.centerY = 0.7
            placement.startSeconds = 3.5; placement.motionSeconds = 17.25
            placement.visibleFrom = 2.25; placement.visibleUntil = 45.5
            placement.fadeSeconds = 0.6; placement.cornerRadius = 12.5; placement.ease = fades
            placement.fadeInSeconds = fades ? 0 : nil; placement.fadeOutSeconds = fades ? 1.25 : nil
            let native = PNSceneTimelineAdapter.native(placement, asset: asset, displayID: 2)
            #expect(native.asset == asset && native.displayID == 2)
            let wire = PNSceneTimelineAdapter.wire(native, asset: v.photo.key, displayId: placement.displayId)
            #expect(try PNWire.decode(PNJSON.self, PNWire.encode(wire)) == PNWire.decode(PNJSON.self, PNWire.encode(placement)))
        }
    }
    @Test func nextScenePlanningLeavesMainActorResponsive() async throws {
        let v = try vector(), catalog = PNPlanningCatalog(), worker = PNScenePlanWorker()
        let photos = (0..<512).map { index in
            var photo = v.photo
            photo.key.imageId = PNWire.digest(Data("planning-\(index)".utf8))
            photo.pixelWidth = 600; photo.pixelHeight = 1800
            photo.faceMetadata = PNFaces(pixelWidth: 600, pixelHeight: 1800, detector: "fixture", state: "complete", faces: [])
            return photo
        }
        // Finish catalog work first: callbacks must run during selection/layout,
        // not merely while waiting for the library snapshot to be prepared.
        let prepared = try await catalog.prepare(photos)
        for scroll in [false, true] {
            var settings = WallSettings()
            settings.galleryEnabled = !scroll; settings.galleryScrollEnabled = scroll
            settings.verticalPanEnabled = false; settings.horizontalPanEnabled = false; settings.zoomEnabled = false
            settings.glassBackground = false
            var wall = v.wall; wall.playback = PNOptions(settings)
            var finished = false, callbacks = 0
            let started = ProcessInfo.processInfo.systemUptime
            let task = Task {
                defer { finished = true }
                return try await worker.build(wall: wall, group: wall.groups[0].id, prepared: prepared, previous: nil)
            }
            while !finished {
                try await Task.sleep(for: .milliseconds(1))
                if !finished { callbacks += 1 }
            }
            let plan = try #require(try await task.value)
            try plan.validate()
            #expect(plan.mode == (scroll ? "galleryScroll" : "gallery"))
            #expect(callbacks > 0)
            print("Scene planning \(plan.mode): \(ProcessInfo.processInfo.systemUptime - started)s, \(callbacks) MainActor callbacks")
        }
    }
    @Test func cancelledScenePlanningCannotReturnAPlan() async throws {
        let v = try vector()
        let root = FileManager.default.temporaryDirectory.appending(path: "DPW.Planning.\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try PNPhotoCache(root: root, key: SymmetricKey(size: .bits256))
        let planner = PNScenePlanner(cache: cache)
        var settings = WallSettings()
        settings.galleryEnabled = false; settings.galleryScrollEnabled = false
        settings.verticalPanEnabled = false; settings.horizontalPanEnabled = false; settings.zoomEnabled = true
        settings.glassBackground = false
        var wall = v.wall; wall.playback = PNOptions(settings)
        // Cancel after calculation, while native background input is pending.
        // Completion must not publish the stale result or block a later request.
        var waiting: CheckedContinuation<Data?, Never>?
        planner.readOriginal = { _ in await withCheckedContinuation { waiting = $0 } }
        settings.glassBackground = true; wall.playback = PNOptions(settings)
        let cancelled = Task {
            try await planner.prepare(wall: wall, group: wall.groups[0].id, photos: [v.photo])
        }
        while waiting == nil { await Task.yield() }
        cancelled.cancel()
        waiting?.resume(returning: nil); waiting = nil
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        settings.glassBackground = false; wall.playback = PNOptions(settings)
        let plan = try #require(try await planner.prepare(wall: wall, group: wall.groups[0].id, photos: [v.photo]))
        #expect(plan.mode == "zoom")
        try plan.validate()
    }
    @Test func sharedGalleriesRenewAcrossTwoHoursWithoutWindows() async throws {
        let v = try vector()
        let root = FileManager.default.temporaryDirectory.appending(path: "DPW.Gallery.\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try PNPhotoCache(root: root, key: SymmetricKey(size: .bits256))
        let photos = (0..<12).map { index in
            var photo = v.photo
            photo.key.imageId = PNWire.digest(Data("gallery-\(index)".utf8))
            photo.pixelWidth = 600; photo.pixelHeight = 1800
            photo.faceMetadata = PNFaces(pixelWidth: 600, pixelHeight: 1800, detector: "fixture", state: "complete", faces: [])
            return photo
        }
        let live = Set(v.wall.displays.map { $0.key.peerId })
        let remote = try #require(live.first { $0 != v.wall.leaderId })
        for scroll in [false, true] {
            for perDisplay in [false, true] {
                var settings = WallSettings()
                settings.galleryEnabled = !scroll; settings.galleryScrollEnabled = scroll
                settings.verticalPanEnabled = false; settings.horizontalPanEnabled = false; settings.zoomEnabled = false
                settings.galleryPerDisplay = perDisplay; settings.galleryScrollPerDisplay = perDisplay; settings.glassBackground = false
                var wall = v.wall; wall.playback = PNOptions(settings)
                let planner = PNScenePlanner(cache: cache), clock = Clock(), output = Output()
                let coordinator = PNSceneCoordinator(planner: planner, output: output, clock: clock)
                var previous: PNScene?, previousEnd = 0.0, lastReplacement: Double?
                for round in 0..<100 {
                    try await coordinator.pump(local: wall.leaderId, wall: wall, live: live, photos: photos)
                    try #require(output.plans.count == round + 1)
                    let plan = try #require(output.plans.last); try plan.validate()
                    #expect(plan.id != previous?.id && plan.mode == (scroll ? "galleryScroll" : "gallery"))
                    #expect(plan.placements.contains { scroll ? $0.fromX != $0.toX : $0.visibleFrom > 0 })
                    #expect(Set(plan.placements.map(\.displayId)).count == (perDisplay ? 2 : 1))
                    #expect(output.commits.count == round)
                    try await coordinator.ready(remote, PNReady(planId: plan.id, groupId: plan.groupId))
                    try #require(output.commits.count == round + 1)
                    let commit = try #require(output.commits.last)
                    if let previous {
                        #expect(plan.continues(previous)); #expect(abs(commit.startAt - previousEnd) < 0.000001)
                        let endpoint = previous.placements.filter { $0.visibleUntil == previous.duration && $0.toX + $0.width > $0.clip.x && $0.toX < $0.clip.x + $0.clip.width }
                        let initial = plan.placements.filter { $0.evaluate(0).opacity > 0 && $0.fromX + $0.width > $0.clip.x && $0.fromX < $0.clip.x + $0.clip.width }
                        #expect(endpoint.count == initial.count)
                        for old in endpoint {
                            #expect(initial.contains { $0.asset == old.asset && $0.displayId == old.displayId
                                && abs($0.fromX - old.toX) < 0.000001 && abs($0.fromY - old.toY) < 0.000001
                                && $0.width == old.width && $0.height == old.height })
                        }
                    }
                    if !scroll {
                        for at in Set(plan.placements.filter { ($0.fadeInSeconds ?? 0) > 0 }.map(\.visibleFrom)).sorted() {
                            let time = commit.startAt + at
                            if let lastReplacement {
                                #expect(time - lastReplacement >= settings.fadeSeconds + settings.galleryMinSeconds - 0.00001)
                                #expect(time - lastReplacement <= settings.fadeSeconds + settings.galleryMaxSeconds + 0.00001)
                            }
                            lastReplacement = time
                        }
                    }
                    let roundtrip = try PNWire.decode(PNScene.self, PNWire.encode(plan)); try roundtrip.validate()
                    #expect(roundtrip.continuationOf == plan.continuationOf)
                    previous = plan; previousEnd = commit.startAt + plan.duration
                    clock.time = previousEnd - 4 - 1000 + 0.001
                }
                #expect(clock.time >= 2 * 60 * 60)
            }
        }
    }
    @Test func nativeWallMergePreservesBothGroupsAndTheDestinationAuthority() throws {
        let v = try vector(); var previous = v.wall
        previous.wallId = UUID(); previous.sessionId = UUID(); previous.leaderId = UUID()
        let group = UUID(); previous.groups = [PNGroup(id: group, name: v.wall.groups[0].name)]
        previous.displays = previous.displays.map { d in var d = d; d.key.peerId = UUID(); d.groupId = group; return d }
        previous.sources = [PNSelection(providerId: previous.displays[0].key.peerId, sourceId: UUID(), generationId: UUID())]
        let merged = try PNWallMerge.merge(current: v.wall, previous: previous)
        #expect(merged.displays.count == 4); #expect(merged.groups.count == 2)
        #expect(merged.displays.filter { $0.groupId == group }.count == 2)
        #expect(merged.leaderId == v.wall.leaderId); #expect(merged.wallId == v.wall.wallId)
        #expect(merged.mergedWalls.contains(previous.wallId)); #expect(merged.groups[0].name != merged.groups[1].name)
        #expect(merged.sources.count == 2)
    }
    @Test func invalidRemoteDisplayAndSceneIdentitiesAreRejectedBeforeRendering() throws {
        let v = try vector()
        var wall = v.wall
        wall.displays[0].key.peerId = .pnZero
        #expect(throws: (any Error).self) { try wall.validate() }
        wall = v.wall; wall.groups[0].name = "  "
        #expect(throws: (any Error).self) { try wall.validate() }
        wall = v.wall; wall.sources[0].generationId = .pnZero
        #expect(throws: (any Error).self) { try wall.validate() }
        var scene = v.scene
        scene.displays[0].x = Int.max
        #expect(throws: (any Error).self) { try scene.validate() }
        scene = v.scene; scene.id = .pnZero
        #expect(throws: (any Error).self) { try scene.validate() }
        scene = v.scene; scene.placements.append(scene.placements[0])
        #expect(throws: (any Error).self) { try scene.validate() }
    }
    private final class Clock: PNClock {
        var time = 0.0; var now: Double { 1000 + time }; var elapsed: Double { time }; func observe(_ pong: PNPong) {}
    }
    private final class Output: PNPlaybackOutput {
        var prepared = 0; var commits: [PNCommit] = []
        var plans: [PNScene] = []
        var beforePrepare: (@MainActor () async -> Void)?
        func prepare(_ scene: PNScene) async throws { prepared += 1; plans.append(scene); await beforePrepare?() }
        func commit(_ commit: PNCommit) { commits.append(commit) }
        func control(_ control: PNControl) {}
        func recover(_ state: PNRecoveryState, wall: PNSnapshot) {}
        func stop() {}
    }
    private final class Planner: PNScenePlanning {
        let scene: PNScene; init(scene: PNScene) { self.scene = scene }
        var beforePrepare: (@MainActor () async -> Void)?
        func prepare(wall: PNSnapshot, group: UUID, photos: [PNPhoto]) async throws -> PNScene? { await beforePrepare?(); return scene }
    }
}
