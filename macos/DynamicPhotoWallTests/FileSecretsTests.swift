import Darwin
import CryptoKit
import Foundation
import Testing
@testable import DynamicPhotoWall

@MainActor struct FileSecretsTests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "DPW.FileSecrets.\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func model(_ root: URL, _ defaults: UserDefaults) -> PNNetworkModel {
        PNNetworkModel(defaults: defaults, root: root, settings: { WallSettings() }, displays: { [] },
            folders: { [] }, albums: { [] }, assets: { [] }, enter: {}, sharedSettings: { _ in })
    }

    @Test func restartPreservesIdentityCacheKeyAndTrustWithPrivatePermissions() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appending(path: "private"), store = PNFileSecrets(directory: dir)
        let first = try PNIdentity(secrets: store), remote = UUID(), digest = String(repeating: "a", count: 64)
        try first.accept(remote, digest: digest)
        let restarted = try PNIdentity(secrets: PNFileSecrets(directory: dir))
        #expect(first.peerId == restarted.peerId)
        #expect(first.cacheKey.withUnsafeBytes { Data($0) } == restarted.cacheKey.withUnsafeBytes { Data($0) })
        try restarted.accept(remote, digest: digest)
        #expect(throws: (any Error).self) { try restarted.accept(remote, digest: String(repeating: "b", count: 64)) }
        #expect(try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int == 0o700)
        for name in ["identity-v1", "trusted-peers-v1"] {
            #expect(try FileManager.default.attributesOfItem(atPath: dir.appending(path: name).path)[.posixPermissions] as? Int == 0o600)
        }
        #expect(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["identity-v1", "trusted-peers-v1"])
    }

    @Test func atomicTrustUpdatesNeverReplaceAnExistingIdentityOrLeaveStagingFiles() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PNFileSecrets(directory: root.appending(path: "keys"))
        try store.write("identity-v1", Data([1, 2, 3]))
        #expect(throws: (any Error).self) { try store.write("identity-v1", Data([9])) }
        #expect(try store.read("identity-v1") == Data([1, 2, 3]))
        try store.write("trusted-peers-v1", Data([4, 5, 6]))
        try store.write("trusted-peers-v1", Data([7, 8]))
        #expect(throws: (any Error).self) { try store.write("trusted-peers-v1", Data(repeating: 0, count: 2 * 1024 * 1024 + 1)) }
        #expect(try store.read("trusted-peers-v1") == Data([7, 8]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).allSatisfy { !$0.hasSuffix(".tmp") })
    }

    @Test func linksUnsafePermissionsAndUnexpectedNamesCannotExposeSecrets() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PNFileSecrets(directory: root.appending(path: "keys"))
        let original = root.appending(path: "other"), file = store.directory.appending(path: "identity-v1")
        try Data([42]).write(to: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original.path)
        #expect(try store.read("identity-v1") == nil)
        #expect(throws: (any Error).self) { try store.read("../other") }
        #expect(throws: (any Error).self) { try store.write("../other", Data([99])) }
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: original)
        #expect(throws: (any Error).self) { try store.read("identity-v1") }
        #expect(throws: (any Error).self) { try store.write("identity-v1", Data([99])) }
        #expect(try Data(contentsOf: original) == Data([42]))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.linkItem(at: original, to: file)
        #expect(throws: (any Error).self) { try store.read("identity-v1") }
        try FileManager.default.removeItem(at: file)
        try store.write("identity-v1", Data([1]))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(throws: (any Error).self) { try store.read("identity-v1") }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.directory.path)
        #expect(throws: (any Error).self) { try store.read("identity-v1") }
        let alias = root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: store.directory)
        #expect(throws: (any Error).self) { try PNFileSecrets(directory: alias).read("identity-v1") }
        #expect(throws: (any Error).self) { try PNFileSecrets(directory: alias.appending(path: "child")).read("identity-v1") }
        #expect(!FileManager.default.fileExists(atPath: store.directory.appending(path: "child").path))
    }

    @Test func corruptOrMissingIdentityNeverGeneratesReplacementKeys() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PNFileSecrets(directory: root.appending(path: "keys"))
        try store.write("identity-v1", Data([1, 2, 3]))
        #expect(throws: (any Error).self) { try PNIdentity(secrets: store) }
        #expect(try store.read("identity-v1") == Data([1, 2, 3]))
        try FileManager.default.removeItem(at: store.directory.appending(path: "identity-v1"))
        try store.write("trusted-peers-v1", Data("{}".utf8))
        #expect(throws: (any Error).self) { try PNIdentity(secrets: store) }
        #expect(try store.read("identity-v1") == nil)
        let profile = "DPW.FileSecrets.Missing.\(UUID())", defaults = UserDefaults(suiteName: profile)!
        defer { defaults.removePersistentDomain(forName: profile) }
        let cache = root.appending(path: "local-v2/cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        #expect(throws: PNLocalStorageError.missingIdentity) { try model(root, defaults).prepareStorage(createNewProfile: true) }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "local-v2/credentials").path))
    }

    @Test func legacyDataWaitsForExplicitNewProfileAndIsNeverReadOrOverwritten() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appending(path: "wall.encrypted"), oldBytes = Data([42, 43, 44])
        try oldBytes.write(to: old)
        let cache = root.appending(path: "cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data([9]).write(to: cache.appending(path: "old.pwc"))
        let profile = "DPW.FileSecrets.Legacy.\(UUID())", defaults = UserDefaults(suiteName: profile)!
        defer { defaults.removePersistentDomain(forName: profile) }
        defaults.set(true, forKey: "networkOnline")
        let network = model(root, defaults)
        await network.setOnline(true)
        #expect(network.needsNewStorageProfile && !network.online && network.session == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "local-v2").path))
        network.createLocalProfile()
        #expect(!network.needsNewStorageProfile && !network.online && network.session == nil)
        #expect(!defaults.bool(forKey: "networkOnline"))
        #expect(try Data(contentsOf: old) == oldBytes)
        #expect(try Data(contentsOf: cache.appending(path: "old.pwc")) == Data([9]))
        let store = PNFileSecrets(directory: root.appending(path: "local-v2/credentials"))
        let saved = try store.read("identity-v1")
        try model(root, defaults).prepareStorage()
        #expect(try store.read("identity-v1") == saved)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "local-v2/cache").path))
    }
}
