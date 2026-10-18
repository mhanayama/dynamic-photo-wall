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
        #expect(v.scene.placements[0].evaluate(2.1).x == -21)
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
    private final class Clock: PNClock {
        var time = 0.0; var now: Double { 1000 + time }; var elapsed: Double { time }; func observe(_ pong: PNPong) {}
    }
    private final class Output: PNPlaybackOutput {
        var prepared = 0; var commits: [PNCommit] = []
        func prepare(_ scene: PNScene) async throws { prepared += 1 }
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
