import Foundation
import CryptoKit
import Testing
@testable import DynamicPhotoWall

@MainActor struct NetworkDisconnectTests {
    @Test func savedWallReconnectsFromDiscoveryAfterRestartAndEndpointChange() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DPW.Reconnect.Tests.\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = PNHello(peerId: UUID(), name: "Local"), remote = PNHello(peerId: UUID(), name: "Remote")
        let own = PNSource(providerId: local.peerId, sourceId: UUID(), name: "Local photos")
        let shared = PNSource(providerId: remote.peerId, sourceId: UUID(), name: "Remote photos")
        let key = SymmetricKey(size: .bits256)
        let saved = PNSnapshot(wallId: UUID(), sessionId: UUID(), leaderId: local.peerId, revision: 7,
            groups: [], displays: [PNDisplay(key: PNDisplayKey(peerId: remote.peerId, displayId: "1"),
                selected: true, x: 100, y: 40, width: 100, height: 100)], sources: [], playback: PNOptions(values: [:]))
        let store = PNStateStore(file: root.appending(path: "wall.encrypted"), key: key)
        try store.save(saved)
        let candidate = PNCandidate(hello: remote, host: "127.0.0.1", port: 42)
        let clock = Clock(), transport = Transport(candidate, source: shared), discovery = Discovery()
        let session = try PNPeerSession(local: local, displays: [], transport: transport, discovery: discovery,
            persistence: store, provider: Provider(own), cache: PNPhotoCache(root: root.appending(path: "cache"), key: key),
            planner: Planner(), output: Output(), clock: clock, notifications: Notices(),
            initial: PNSnapshot(wallId: UUID(), sessionId: UUID(), leaderId: local.peerId, revision: 0,
                groups: [], displays: [], sources: [], playback: PNOptions(values: [:])))
        defer { session.stop() }
        try await session.start(automaticPump: false)
        #expect(session.snapshot == saved && session.connectedPeers.isEmpty)
        discovery.found?(PNCandidate(hello: PNHello(peerId: UUID(), name: "Stranger"), host: "127.0.0.1", port: 99))
        try await session.pump()
        for _ in 0..<20 { await Task.yield() }
        #expect(transport.attempts == 0)

        discovery.found?(PNCandidate(hello: remote, host: "127.0.0.1", port: 1))
        clock.time += 6; try await session.pump()
        for _ in 0..<100 where transport.attempts == 0 { await Task.yield() }
        #expect(transport.attempts == 1 && session.connectedPeers.isEmpty)
        discovery.found?(candidate)
        clock.time += 6; try await session.pump()
        for _ in 0..<100 where !session.isSourceConnected(shared) { await Task.yield() }
        #expect(session.connectedPeers == [remote.peerId] && session.isSourceConnected(shared))
        #expect(transport.lastCandidate == candidate && session.snapshot == saved)

        // Also refresh a running process's target after the remote restarts.
        transport.candidate = PNCandidate(hello: remote, host: "127.0.0.2", port: 43)
        clock.time += 7; try await session.pump()
        for _ in 0..<20 { await Task.yield() }
        discovery.found?(transport.candidate)
        clock.time += 6; try await session.pump()
        for _ in 0..<100 where !session.isSourceConnected(shared) { await Task.yield() }
        #expect(session.isSourceConnected(shared) && transport.lastCandidate == transport.candidate)
        #expect(session.snapshot == saved)
    }
    @Test func disconnectHidesSourcesRejectsRetriesAndAllowsExplicitReconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DPW.Disconnect.Tests.\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let local = PNHello(peerId: UUID(), name: "Local"), remote = PNHello(peerId: UUID(), name: "Remote")
        let own = PNSource(providerId: local.peerId, sourceId: UUID(), name: "Local photos")
        let shared = PNSource(providerId: remote.peerId, sourceId: UUID(), name: "Remote photos")
        let selection = PNSelection(providerId: shared.providerId, sourceId: shared.sourceId, generationId: UUID())
        let candidate = PNCandidate(hello: remote, host: "127.0.0.1", port: 1)
        let clock = Clock(), transport = Transport(candidate, source: shared), discovery = Discovery(), notices = Notices()
        let cacheKey = SymmetricKey(size: .bits256)
        let snapshot = PNSnapshot(wallId: UUID(), sessionId: UUID(), leaderId: local.peerId, revision: 0,
            groups: [], displays: [], sources: [selection], playback: PNOptions(values: [:]))
        let session = try PNPeerSession(local: local, displays: [], transport: transport, discovery: discovery,
            persistence: PNStateStore(file: root.appending(path: "wall.encrypted"), key: cacheKey), provider: Provider(own),
            cache: PNPhotoCache(root: root.appending(path: "cache"), key: cacheKey), planner: Planner(),
            output: Output(), clock: clock, notifications: notices, initial: snapshot)
        defer { session.stop() }
        try await session.start(automaticPump: false)
        #expect(session.isSourceConnected(own) && !session.isSourceConnected(shared))
        discovery.found?(candidate)
        #expect(!session.isSourceConnected(shared))
        try await session.connect(candidate)
        for _ in 0..<100 where !session.isSourceConnected(shared) { await Task.yield() }
        #expect(session.isSourceConnected(shared))
        await session.disconnect(remote.peerId)
        #expect(session.connectedPeers.isEmpty && !session.isSourceConnected(shared))
        #expect(session.snapshot.sources == [selection] && session.sources.contains(shared))
        #expect(notices.disconnectedCount == 0)
        #expect(PNNetworkModel.visibleSources(session.sources, available: [own.id], showDisconnected: false) == [own])
        #expect(PNNetworkModel.visibleSources(session.sources, available: [], showDisconnected: true).contains(shared))

        let attempts = transport.attempts
        discovery.found?(candidate)
        clock.time = 10; try await session.pump()
        for _ in 0..<20 { await Task.yield() }
        #expect(transport.attempts == attempts && session.candidates.isEmpty)
        let incoming = try transport.makeLink(outbound: false)
        await transport.accept?(incoming)
        #expect(incoming.closed && session.connectedPeers.isEmpty)
        try await session.connect(candidate)
        for _ in 0..<100 where !session.isSourceConnected(shared) { await Task.yield() }
        #expect(session.isSourceConnected(shared) && session.snapshot.sources == [selection])
    }
    private final class Clock: PNClock {
        var time = 0.0
        var now: Double { 1000 + time }; var elapsed: Double { time }
        func observe(_ pong: PNPong) {}
    }
    private final class Discovery: PNDiscovery {
        var found: ((PNCandidate) -> Void)?
        func start(_ hello: PNHello, port: Int) throws {}
        func stop() {}
    }
    private final class Transport: PNTransport {
        var candidate: PNCandidate
        let source: PNSource
        var attempts = 0
        var lastCandidate: PNCandidate?
        var accept: (@MainActor (any PNPeerLink) async -> Void)?
        var port: Int { 1 }
        init(_ candidate: PNCandidate, source: PNSource) { self.candidate = candidate; self.source = source }
        func start(_ accept: @escaping @MainActor (any PNPeerLink) async -> Void) async throws { self.accept = accept }
        func makeLink(outbound: Bool) throws -> Link {
            try Link(candidate.hello, outbound: outbound,
                packets: [PNPacket("inventory", PNInventory(candidate: candidate, displays: [], sources: [source]))])
        }
        func connect(_ candidate: PNCandidate) async throws -> any PNPeerLink {
            attempts += 1; lastCandidate = candidate
            try PNWire.require(candidate == self.candidate, "Stale endpoint")
            return try makeLink(outbound: true)
        }
        func stop() {}
    }
    private final class Link: PNPeerLink {
        let remote: PNHello, outbound: Bool
        var remoteHost: String { "127.0.0.1" }
        private var packets: [PNPacket]
        private var waiter: CheckedContinuation<PNPacket?, Never>?
        private(set) var closed = false
        init(_ remote: PNHello, outbound: Bool, packets: [PNPacket]) { self.remote = remote; self.outbound = outbound; self.packets = packets }
        func send(_ packet: PNPacket) async throws {}
        func receive() async throws -> PNPacket? {
            if closed { return nil }
            if !packets.isEmpty { return packets.removeFirst() }
            return await withCheckedContinuation { waiter = $0 }
        }
        func close() { closed = true; waiter?.resume(returning: nil); waiter = nil }
    }
    private final class Provider: PNPhotoProviding {
        let sources: [PNSource]
        init(_ source: PNSource) { sources = [source] }
        func read(_ selection: PNSelection) -> AsyncThrowingStream<PNImportedPhoto, Error> { AsyncThrowingStream { $0.finish() } }
    }
    private final class Planner: PNScenePlanning {
        func prepare(wall: PNSnapshot, group: UUID, photos: [PNPhoto]) async throws -> PNScene? { nil }
    }
    private final class Output: PNPlaybackOutput {
        func prepare(_ scene: PNScene) async throws {}
        func commit(_ commit: PNCommit) {}
        func control(_ control: PNControl) {}
        func recover(_ state: PNRecoveryState, wall: PNSnapshot) {}
        func stop() {}
    }
    private final class Notices: PNNotifications {
        var disconnectedCount = 0
        func disconnected(_ name: String) { disconnectedCount += 1 }
        func reconnected(_ name: String) {}
    }
}
