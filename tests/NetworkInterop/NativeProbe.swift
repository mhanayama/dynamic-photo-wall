import Foundation
import CryptoKit

// Standalone probe uses only the production contracts/storage/transport files.
// Its secrets are memory-only and its listeners bind exclusively to loopback.
nonisolated enum WallLog {
    static func write(_ message: String, error: Error? = nil) { print(message, error.map(String.init(describing:)) ?? "") }
}
nonisolated final class ProbeSecrets: PNSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ name: String) throws -> Data? { lock.withLock { values[name] } }
    func write(_ name: String, _ data: Data) throws { lock.withLock { values[name] = data } }
}
@main struct NativeProbe {
    @MainActor static func main() async throws {
        let root = URL(filePath: CommandLine.arguments[1])
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        let endpoint = root.appending(path: "dotnet-endpoint.json")
        while !FileManager.default.fileExists(atPath: endpoint.path) {
            try PNWire.require(ContinuousClock.now < deadline, "Waiting for .NET timed out")
            try await Task.sleep(for: .milliseconds(50))
        }
        let remote = try PNWire.decode(PNCandidate.self, Data(contentsOf: endpoint))
        let identity = try PNIdentity(secrets: ProbeSecrets())
        let hello = PNHello(peerId: identity.peerId, name: "Interop Swift")
        var testDiscovery: PNLanDiscovery?
        var discovered = false
        let discoveryPortFile = root.appending(path: "discovery-port.json")
        if FileManager.default.fileExists(atPath: discoveryPortFile.path) {
            let port = try JSONDecoder().decode(UInt16.self, from: Data(contentsOf: discoveryPortFile))
            let service = PNLanDiscovery(discoveryPort: port); testDiscovery = service
            service.found = { candidate in if candidate.id == remote.id { discovered = true } }
            try service.start(hello, port: 12345)
            while !discovered {
                try PNWire.require(ContinuousClock.now < deadline, "Multicast discovery timed out")
                try await Task.sleep(for: .milliseconds(50))
            }
            print("PASS Swift discovers .NET multicast advertisement on isolated port")
        }
        defer { testDiscovery?.stop() }
        let transport = PNTLSTransport(local: hello, identity: identity, listenHost: "127.0.0.1")
        defer { transport.stop() }
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { transport.stop() }
        }
        defer { timeout.cancel() }
        let link = try await transport.connect(remote)
        try await link.send(PNPacket("clockPing", PNPing(requestId: UUID(), sentAt: 100)))
        guard let packet = try await link.receive() else { throw PNError.invalid("Missing .NET response") }
        let pong = try packet.decode(PNPong.self)
        try PNWire.require(packet.type == "clockPong" && pong.repliedAt == 102, "Invalid .NET response")
        link.close()
        let (events, continuation) = AsyncThrowingStream<Void, Error>.makeStream()
        try await transport.start { link in
            defer { link.close() }
            do {
                guard let packet = try await link.receive() else { throw PNError.invalid("Missing .NET ping") }
                let ping = try packet.decode(PNPing.self)
                try PNWire.require(packet.type == "clockPing" && ping.sentAt == 200, "Invalid .NET ping")
                try await link.send(PNPacket("clockPong", PNPong(requestId: ping.requestId, sentAt: 200, receivedAt: 201, repliedAt: 202)))
                continuation.yield(()); continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        try PNWire.encode(PNCandidate(hello: hello, host: "127.0.0.1", port: transport.port))
            .write(to: root.appending(path: "swift-endpoint.json"), options: .atomic)
        for try await _ in events { }
        print("PASS native Swift ↔ .NET mutual TLS in both connection directions")
    }
}
