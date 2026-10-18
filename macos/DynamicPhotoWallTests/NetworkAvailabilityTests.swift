import Foundation
import Security
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
    @Test func startupKeychainDenialShowsAnAppMessageWithoutRequestingInteraction() async {
        let profile = "DynamicPhotoWall.KeychainConsent.Tests.\(UUID())"
        let defaults = UserDefaults(suiteName: profile)!
        defer { defaults.removePersistentDomain(forName: profile) }
        defaults.set(true, forKey: "networkOnline")
        let denied = DeniedSecrets()
        var requestedInteraction: [Bool] = []
        let model = PNNetworkModel(defaults: defaults, settings: { WallSettings() }, displays: { [] },
            folders: { [] }, albums: { [] }, assets: { [] }, enter: {}, sharedSettings: { _ in },
            secretStore: { _, allowed in requestedInteraction.append(allowed); return denied })
        model.restore()
        for _ in 0..<100 where !model.keychainNeedsAuthorization { await Task.yield() }
        #expect(model.keychainNeedsAuthorization)
        #expect(!model.online && !model.busy && model.session == nil)
        #expect(requestedInteraction == [false])
        #expect(defaults.bool(forKey: "networkOnline")) // Preserve the user's intent.
        #expect(model.status.contains("Keychain"))
    }
    @Test func interactiveAccessIsRequestedOnlyByTheExplicitRetryAction() async {
        let defaults = UserDefaults(suiteName: "DynamicPhotoWall.KeychainRetry.Tests.\(UUID())")!
        let denied = DeniedSecrets()
        var requestedInteraction: [Bool] = []
        let model = PNNetworkModel(defaults: defaults, settings: { WallSettings() }, displays: { [] },
            folders: { [] }, albums: { [] }, assets: { [] }, enter: {}, sharedSettings: { _ in },
            secretStore: { _, allowed in requestedInteraction.append(allowed); return denied })
        await model.authorizeKeychain()
        #expect(requestedInteraction.isEmpty)
        await model.setOnline(true)
        #expect(requestedInteraction == [false] && model.keychainNeedsAuthorization)
        await model.authorizeKeychain()
        #expect(requestedInteraction == [false, false, true])
        #expect(!model.online && model.session == nil) // No sockets or cache fallback.
    }
    @Test func identityUsesInteractiveSecretsOnlyForInitialization() throws {
        let initial = MemorySecrets(), quiet = MemorySecrets()
        let identity = try PNIdentity(secrets: quiet, initialSecrets: initial)
        #expect(initial.readCount == 2 && quiet.readCount == 0)
        #expect(initial.writeCount == 1 && quiet.writeCount == 0)
        try identity.accept(UUID(), digest: String(repeating: "a", count: 64))
        #expect(initial.writeCount == 1 && quiet.writeCount == 1)
    }
    @Test func keychainPreflightKeepsTheIdentityAndDoesNotStartNetworking() throws {
        let secrets = MemorySecrets()
        var requested: [Bool] = []
        let model = PNNetworkModel(defaults: UserDefaults(suiteName: "DPW.Permission.Preflight.\(UUID())")!,
            settings: { WallSettings() }, displays: { [] }, folders: { [] }, albums: { [] }, assets: { [] },
            enter: {}, sharedSettings: { _ in }, secretStore: { _, interactive in requested.append(interactive); return secrets })
        try model.prepareKeychain(allowInteraction: false)
        let identity = try secrets.read("identity-v1")
        try model.prepareKeychain(allowInteraction: true)
        #expect(try secrets.read("identity-v1") == identity)
        #expect(try secrets.read("trusted-peers-v1") != nil)
        #expect(requested == [false, true] && !model.online && model.session == nil)
    }
    private nonisolated final class DeniedSecrets: PNSecretStore, @unchecked Sendable {
        func read(_ name: String) throws -> Data? { throw PNKeychainError(status: errSecInteractionNotAllowed) }
        func write(_ name: String, _ data: Data) throws { throw PNKeychainError(status: errSecInteractionNotAllowed) }
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
