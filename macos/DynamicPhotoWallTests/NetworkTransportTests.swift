import Foundation
import CryptoKit
import Network
import Security
import Testing
@testable import DynamicPhotoWall

@MainActor struct NetworkTransportTests {
    private nonisolated final class Secrets: PNSecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Data] = [:]
        var rejectWrites = false
        func read(_ name: String) throws -> Data? { lock.withLock { values[name] } }
        func write(_ name: String, _ data: Data) throws {
            try lock.withLock {
                if rejectWrites { throw PNError.invalid("Synthetic write failure") }
                values[name] = data
            }
        }
    }
    @Test func protectedIdentityReloadsAndTrustIsCommittedOnlyAfterPersistence() throws {
        let secrets = Secrets(), otherSecrets = Secrets()
        let identity = try PNIdentity(secrets: secrets)
        let reloaded = try PNIdentity(secrets: secrets)
        #expect(identity.peerId == reloaded.peerId)
        #expect(identity.cacheKey.withUnsafeBytes { Data($0) } == reloaded.cacheKey.withUnsafeBytes { Data($0) })
        #expect(identity.peerId != (try PNIdentity(secrets: otherSecrets)).peerId)
        let remote = UUID(), digest = String(repeating: "a", count: 64), changed = String(repeating: "b", count: 64)
        secrets.rejectWrites = true
        #expect(throws: (any Error).self) { try identity.accept(remote, digest: digest) }
        secrets.rejectWrites = false
        // A failed write must not silently create an in-memory pin.
        try identity.accept(remote, digest: changed)
        #expect(throws: (any Error).self) { try identity.accept(remote, digest: digest) }
        #expect(throws: (any Error).self) { try PNIdentity(secrets: secrets).accept(remote, digest: digest) }
    }
    @Test func nativeMutualTLSAcceptsWithoutConfirmationAndExchangesFramedPackets() async throws {
        let identityA = try PNIdentity(secrets: Secrets()), identityB = try PNIdentity(secrets: Secrets())
        let a = PNHello(peerId: identityA.peerId, name: "Isolated A")
        let b = PNHello(peerId: identityB.peerId, name: "Isolated B")
        let server = PNTLSTransport(local: b, identity: identityB, listenHost: "127.0.0.1")
        let client = PNTLSTransport(local: a, identity: identityA, listenHost: "127.0.0.1")
        defer { server.stop(); client.stop() }
        try await server.start { link in
            defer { link.close() }
            do {
                #expect(link.remote == a)
                guard let packet = try await link.receive() else { Issue.record("Missing packet"); return }
                let ping = try packet.decode(PNPing.self)
                try await link.send(PNPacket("clockPong", PNPong(requestId: ping.requestId, sentAt: ping.sentAt, receivedAt: 101, repliedAt: 102)))
            } catch { Issue.record(error) }
        }
        let link = try await client.connect(PNCandidate(hello: b, host: "127.0.0.1", port: server.port))
        defer { link.close() }
        #expect(link.remote == b)
        let ping = PNPing(requestId: UUID(), sentAt: 100)
        try await link.send(PNPacket("clockPing", ping))
        let packet = try #require(try await link.receive())
        #expect(packet.type == "clockPong")
        let reply = try packet.decode(PNPong.self)
        #expect(reply.requestId == ping.requestId && reply.repliedAt == 102)
    }
}
