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
        func prepare(_ scene: PNScene) async throws { prepared += 1; plans.append(scene) }
        func commit(_ commit: PNCommit) { commits.append(commit) }
        func control(_ control: PNControl) {}
        func recover(_ state: PNRecoveryState, wall: PNSnapshot) {}
        func stop() {}
    }
    private final class Planner: PNScenePlanning {
        let scene: PNScene; init(scene: PNScene) { self.scene = scene }
        func prepare(wall: PNSnapshot, group: UUID, photos: [PNPhoto]) async throws -> PNScene? { scene }
    }
}
