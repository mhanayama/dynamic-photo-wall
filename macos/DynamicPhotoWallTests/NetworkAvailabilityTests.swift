import Foundation
import Testing
@testable import DynamicPhotoWall

@MainActor struct NetworkAvailabilityTests {
    @Test func cachedRemoteScreensAreHiddenUntilConnectionAndReturnWithTheirSavedPlacement() {
        let a = UUID(), b = UUID(), c = UUID(), group = UUID()
        let displays = [a, b, c].enumerated().map { index, peer in
            PNDisplay(key: PNDisplayKey(peerId: peer, displayId: "1"), selected: true,
                groupId: group, x: index * 1920, y: 40, width: 1920, height: 1080)
        }
        #expect(PNNetworkModel.visibleDisplays(displays, connected: [displays[0].key], showDisconnected: false) == [displays[0]])
        #expect(PNNetworkModel.visibleDisplays(displays, connected: Set(displays.prefix(2).map(\.key)), showDisconnected: false) == Array(displays.prefix(2)))
        #expect(PNNetworkModel.visibleDisplays(displays, connected: Set(displays.map(\.key)), showDisconnected: false) == displays)
        #expect(PNNetworkModel.visibleDisplays(displays, connected: [displays[0].key, displays[2].key], showDisconnected: false) == [displays[0], displays[2]])
        #expect(PNNetworkModel.visibleDisplays(displays, connected: [], showDisconnected: false).isEmpty)
        #expect(PNNetworkModel.visibleDisplays(displays, connected: [], showDisconnected: true) == displays)
        let removed = PNDisplay(key: PNDisplayKey(peerId: a, displayId: "old"), selected: true, x: 0, y: 0, width: 1920, height: 1080)
        #expect(PNNetworkModel.visibleDisplays(displays + [removed], connected: [displays[0].key], showDisconnected: false) == [displays[0]])
        #expect(displays[1].x == 1920 && displays[1].y == 40 && displays[1].groupId == group)
    }
    @Test func storageFailureDoesNotStartNetworkingOrDiscardOnlineIntent() async {
        let profile = "DynamicPhotoWall.StorageFailure.Tests.\(UUID())"
        let defaults = UserDefaults(suiteName: profile)!
        defer { defaults.removePersistentDomain(forName: profile) }
        defaults.set(true, forKey: "networkOnline")
        let denied = DeniedSecrets()
        var requests = 0
        let model = PNNetworkModel(defaults: defaults, settings: { WallSettings() }, displays: { [] },
            folders: { [] }, albums: { [] }, assets: { [] }, enter: {}, sharedSettings: { _ in },
            secretStore: { _ in requests += 1; return denied })
        model.restore()
        for _ in 0..<100 where model.status == "オフライン" { await Task.yield() }
        #expect(!model.online && !model.busy && model.session == nil)
        #expect(requests == 1)
        #expect(defaults.bool(forKey: "networkOnline")) // Preserve the user's intent.
        #expect(model.status.contains("保存先"))
    }
    @Test func storagePreparationIsCachedWithoutNetworkingOrRepeatedWrites() throws {
        let secrets = MemorySecrets()
        var requests = 0
        let model = PNNetworkModel(defaults: UserDefaults(suiteName: "DPW.Permission.Preflight.\(UUID())")!,
            settings: { WallSettings() }, displays: { [] }, folders: { [] }, albums: { [] }, assets: { [] },
            enter: {}, sharedSettings: { _ in }, secretStore: { _ in requests += 1; return secrets })
        for _ in 0..<10 { try model.prepareStorage() }
        #expect(secrets.readCount == 2 && secrets.writeCount == 1 && requests == 1)
        #expect(!model.online && model.session == nil)
    }
    private nonisolated final class DeniedSecrets: PNSecretStore, @unchecked Sendable {
        func read(_ name: String) throws -> Data? { throw PNLocalStorageError.inaccessible }
        func write(_ name: String, _ data: Data) throws { throw PNLocalStorageError.inaccessible }
    }
    private nonisolated final class MemorySecrets: PNSecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]
        private var reads = 0, writes = 0
        var readCount: Int { lock.withLock { reads } }
        var writeCount: Int { lock.withLock { writes } }
        func read(_ name: String) throws -> Data? { lock.withLock { reads += 1; return values[name] } }
        func write(_ name: String, _ data: Data) throws { lock.withLock { writes += 1; values[name] = data } }
    }
}
