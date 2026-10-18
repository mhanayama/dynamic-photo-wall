import Foundation
import Network
import Security
import Darwin

@MainActor protocol PNPeerLink: AnyObject {
    var remote: PNHello { get }
    var remoteHost: String { get }
    var outbound: Bool { get }
    func send(_ packet: PNPacket) async throws
    func receive() async throws -> PNPacket?
    func close()
}
@MainActor protocol PNTransport: AnyObject {
    var port: Int { get }
    func start(_ accept: @escaping @MainActor (any PNPeerLink) async -> Void) async throws
    func connect(_ candidate: PNCandidate) async throws -> any PNPeerLink
    func stop()
}
@MainActor protocol PNDiscovery: AnyObject {
    var found: ((PNCandidate) -> Void)? { get set }
    func start(_ hello: PNHello, port: Int) throws
    func stop()
}

private nonisolated final class PNCertificateDigest: @unchecked Sendable {
    private let lock = NSLock(); private var value: String?
    func set(_ value: String) { lock.lock(); defer { lock.unlock() }; self.value = value }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
private nonisolated final class PNConnectionReady: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ result: Result<Void, Error>) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock(); c?.resume(with: result)
    }
}

@MainActor final class PNTLSLink: PNPeerLink {
    let remote: PNHello
    let remoteHost: String
    let outbound: Bool
    private let connection: NWConnection
    private let onClosed: () -> Void
    private var buffer = Data()
    private var sending = false
    private var sendQueue: [CheckedContinuation<Void, Never>] = []
    init(connection: NWConnection, remote: PNHello, remoteHost: String, outbound: Bool, onClosed: @escaping () -> Void = {}) {
        self.connection = connection; self.remote = remote; self.remoteHost = remoteHost; self.outbound = outbound
        self.onClosed = onClosed
    }
    func send(_ packet: PNPacket) async throws {
        // A complete length-prefixed message is serialized across all senders.
        if sending { await withCheckedContinuation { sendQueue.append($0) } } else { sending = true }
        defer { if sendQueue.isEmpty { sending = false } else { sendQueue.removeFirst().resume() } }
        let timeout = Task { @MainActor in try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { connection.cancel() } }
        defer { timeout.cancel() }
        let body = try PNWire.encode(packet); try PNWire.require(!body.isEmpty && body.count <= 4 * 1024 * 1024, "Peer frame is too large")
        var length = UInt32(body.count).bigEndian
        let data = withUnsafeBytes(of: &length) { Data($0) } + body
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in if let error { c.resume(throwing: error) } else { c.resume() } })
        }
    }
    private func exact(_ count: Int) async throws -> Data? {
        while buffer.count < count {
            let data: Data? = try await withCheckedThrowingContinuation { c in
                connection.receive(minimumIncompleteLength: 1, maximumLength: min(65536, count - buffer.count)) { bytes, _, complete, error in
                    if let error { c.resume(throwing: error) }
                    else if complete && bytes?.isEmpty != false { c.resume(returning: nil) }
                    else { c.resume(returning: bytes) }
                }
            }
            guard let data, !data.isEmpty else { if buffer.isEmpty { return nil }; throw PNError.invalid("Truncated peer frame") }
            buffer.append(data)
        }
        let data = buffer.prefix(count); buffer.removeFirst(count); return Data(data)
    }
    func receive() async throws -> PNPacket? {
        guard let prefix = try await exact(4) else { return nil }
        let count = prefix.reduce(0) { $0 * 256 + Int($1) }
        try PNWire.require(count > 0 && count <= 4 * 1024 * 1024, "Invalid peer frame size")
        guard let body = try await exact(count) else { throw PNError.invalid("Truncated peer packet") }
        return try PNWire.decode(PNPacket.self, body)
    }
    func close() { connection.cancel(); onClosed() }
}

@MainActor final class PNTLSTransport: PNTransport {
    private let local: PNHello; private let identity: PNIdentity
    private var listener: NWListener?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var connections: [NWConnection] = []
    private(set) var port = 0
    private var accept: (@MainActor (any PNPeerLink) async -> Void)?
    private let queue = DispatchQueue(label: "PhotoWall.TLS")
    init(local: PNHello, identity: PNIdentity) { self.local = local; self.identity = identity }
    private func parameters(_ digest: PNCertificateDigest) -> NWParameters {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, sec_identity_create(identity.identity)!)
        sec_protocol_options_set_peer_authentication_required(options.securityProtocolOptions, true)
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
            let value = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(value) as? [SecCertificate], let certificate = chain.first else { complete(false); return }
            digest.set(PNWire.digest(SecCertificateCopyData(certificate) as Data)); complete(true)
        }, queue)
        return NWParameters(tls: options, tcp: NWProtocolTCP.Options())
    }
    func start(_ accept: @escaping @MainActor (any PNPeerLink) async -> Void) async throws {
        self.accept = accept
        // Listener verification runs per accepted TLS connection; obtain that
        // connection's actual leaf again from its negotiated security metadata.
        let listener = try NWListener(using: parameters(PNCertificateDigest()), on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in
            guard let self, self.tasks.count < 32 else { connection.cancel(); return }
            let id = UUID(); self.tasks[id] = Task { @MainActor in
                defer { self.tasks.removeValue(forKey: id) }
                do { let link = try await self.handshake(connection, outbound: false, expected: nil); await self.accept?(link) }
                catch { connection.cancel(); WallLog.write("ピア接続を受け入れられません。", error: error) }
            }
        } }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let completion = PNConnectionReady(c)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: completion.finish(.success(()))
                case .failed(let error): completion.finish(.failure(error))
                case .cancelled: completion.finish(.failure(CancellationError()))
                default: break
                }
            }
            listener.start(queue: queue)
        }
        port = Int(listener.port!.rawValue)
    }
    func connect(_ candidate: PNCandidate) async throws -> any PNPeerLink {
        try PNWire.require(candidate.port > 0 && candidate.port <= 65535, "Invalid peer port")
        let connection = NWConnection(host: NWEndpoint.Host(candidate.host), port: NWEndpoint.Port(rawValue: UInt16(candidate.port))!, using: parameters(PNCertificateDigest()))
        return try await handshake(connection, outbound: true, expected: candidate.id)
    }
    private func handshake(_ connection: NWConnection, outbound: Bool, expected: UUID?) async throws -> any PNPeerLink {
        connections.append(connection)
        var completed = false
        defer { if !completed { connection.cancel(); connections.removeAll { $0 === connection } } }
        let timeout = Task { @MainActor in try? await Task.sleep(for: .seconds(10)); if !Task.isCancelled { connection.cancel() } }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let completion = PNConnectionReady(c)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: completion.finish(.success(()))
                case .failed(let e): completion.finish(.failure(e))
                case .cancelled: completion.finish(.failure(CancellationError()))
                default: break
                }
            }
            connection.start(queue: queue)
        }
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { throw PNError.invalid("Missing TLS metadata") }
        let leaf = PNCertificateDigest()
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            let value = sec_certificate_copy_ref(certificate).takeRetainedValue()
            if leaf.get() == nil { leaf.set(PNWire.digest(SecCertificateCopyData(value) as Data)) }
        }
        guard let fingerprint = leaf.get() else { throw PNError.invalid("Missing peer certificate") }
        let host: String
        if case .hostPort(let address, _) = connection.endpoint { host = "\(address)" } else { throw PNError.invalid("Missing peer address") }
        let provisional = PNTLSLink(connection: connection, remote: local, remoteHost: host, outbound: outbound)
        try await provisional.send(PNPacket("hello", local))
        guard let packet = try await provisional.receive(), packet.type == "hello" else { throw PNError.invalid("Missing peer hello") }
        let remote = try packet.decode(PNHello.self); try remote.validate()
        try PNWire.require(remote.peerId != local.peerId && (expected == nil || expected == remote.peerId), "Peer identity differs")
        try identity.accept(remote.peerId, digest: fingerprint)
        completed = true
        return PNTLSLink(connection: connection, remote: remote, remoteHost: host, outbound: outbound,
            onClosed: { [weak self] in self?.connections.removeAll { $0 === connection } })
    }
    func stop() { listener?.cancel(); listener = nil; for task in tasks.values { task.cancel() }; tasks.removeAll(); for c in connections { c.cancel() }; connections.removeAll() }
}

// Same small, versioned multicast advertisement as LanPeerDiscovery.cs. Discovery
// advertises availability; only a user connection or a remembered peer connects.
@MainActor final class PNLanDiscovery: PNDiscovery {
    private nonisolated struct Advertisement: Codable, Sendable { var service = "photowall-v1"; var hello: PNHello; var port: Int }
    var found: ((PNCandidate) -> Void)?
    private var socketFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var task: Task<Void, Never>?
    private var destination = sockaddr_in()
    func start(_ hello: PNHello, port: Int) throws {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP); try PNWire.require(fd >= 0, "Discovery socket failed")
        socketFD = fd
        do {
            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(47391).bigEndian; address.sin_addr.s_addr = INADDR_ANY
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            try PNWire.require(bound == 0, "Discovery bind failed")
            var membership = ip_mreq(); membership.imr_multiaddr.s_addr = inet_addr("239.255.77.87"); membership.imr_interface.s_addr = INADDR_ANY
            try PNWire.require(setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership, socklen_t(MemoryLayout.size(ofValue: membership))) == 0, "Multicast join failed")
            fcntl(fd, F_SETFL, O_NONBLOCK)
            destination = address; destination.sin_addr.s_addr = inet_addr("239.255.77.87")
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main); self.source = source
            source.setEventHandler { [weak self] in Task { @MainActor in self?.read(local: hello.peerId) } }; source.resume()
            let bytes = try PNWire.encode(Advertisement(hello: hello, port: port))
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }; self.advertise(bytes)
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
        } catch { stop(); throw error }
    }
    private func advertise(_ bytes: Data) {
        bytes.withUnsafeBytes { buffer in withUnsafePointer(to: &destination) { address in
            address.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(socketFD, buffer.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } }
    }
    private func read(local: UUID) {
        var bytes = [UInt8](repeating: 0, count: 2049); var address = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socketFD, &bytes, bytes.count, 0, $0, &length) } }
        guard count > 0 && count <= 2048, let advert = try? PNWire.decode(Advertisement.self, Data(bytes.prefix(count))), advert.service == "photowall-v1", advert.hello.peerId != local, advert.port > 0 && advert.port <= 65535, (try? advert.hello.validate()) != nil else { return }
        var ip = address.sin_addr; var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &ip, &host, socklen_t(host.count)) != nil else { return }
        found?(PNCandidate(hello: advert.hello, host: String(cString: host), port: advert.port))
    }
    func stop() { task?.cancel(); task = nil; source?.cancel(); source = nil; if socketFD >= 0 { Darwin.close(socketFD); socketFD = -1 } }
}
