import Foundation
import Security
import CryptoKit

nonisolated protocol PNSecretStore: Sendable {
    func read(_ name: String) throws -> Data?
    func write(_ name: String, _ data: Data) throws
}

// Identity secrets are device-local. The self-signed certificate is pinned after
// the encrypted hello; no certificate is added to the system trust anchors.
@MainActor final class PNIdentity {
    private nonisolated struct Stored: Codable, Sendable { var peerId: UUID; var key: Data; var privateKey: Data; var certificate: Data }
    let peerId: UUID
    let cacheKey: SymmetricKey
    let identity: SecIdentity
    private let secrets: any PNSecretStore
    private var pins: [String: String]
    init(secrets: any PNSecretStore) throws {
        self.secrets = secrets
        let trusted = try secrets.read("trusted-peers-v1")
        let stored: Stored
        if let bytes = try secrets.read("identity-v1") { stored = try PNWire.decode(Stored.self, bytes) }
        else {
            try PNWire.require(trusted == nil, "通信鍵が見つかりません。既存の接続情報は上書きしません。")
            let privateKey = P256.Signing.PrivateKey()
            stored = Stored(peerId: UUID(), key: Self.random(32), privateKey: privateKey.x963Representation,
                certificate: try PNCertificate.make(privateKey))
            try secrets.write("identity-v1", PNWire.encode(stored))
        }
        try PNWire.require(stored.peerId != .pnZero && stored.key.count == 32, "Invalid protected peer identity")
        peerId = stored.peerId; cacheKey = SymmetricKey(data: stored.key)
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(stored.privateKey as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits: 256] as CFDictionary, &error),
            let certificate = SecCertificateCreateWithData(nil, stored.certificate as CFData) else { throw PNError.invalid("TLS identity is unreadable") }
        // Persistence belongs to the device-local store. Build TLS in memory;
        // never register permanent keys or certificates in a system keychain.
        guard let value = SecIdentityCreate(nil, certificate, key) else { throw PNError.invalid("TLS certificate and private key differ") }
        identity = value
        pins = try trusted.map { try PNWire.decode([String: String].self, $0) } ?? [:]
    }
    func accept(_ peer: UUID, digest: String) throws {
        if let previous = pins[peer.pnHex] { try PNWire.require(previous == digest, "登録されたピアの証明書が変更されています。") }
        else {
            var updated = pins; updated[peer.pnHex] = digest
            try secrets.write("trusted-peers-v1", PNWire.encode(updated)); pins = updated
        }
    }
    nonisolated static func random(_ count: Int) -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess); return bytes
    }
}

// Minimal DER encoder for a P-256, SHA-256, self-signed TLS leaf certificate.
// Cryptographic signing is performed by CryptoKit, not by this encoder.
nonisolated enum PNCertificate {
    static func tlv(_ tag: UInt8, _ bytes: Data) -> Data {
        var length = Data()
        if bytes.count < 128 { length.append(UInt8(bytes.count)) }
        else {
            var count = bytes.count; var encoded: [UInt8] = []
            while count > 0 { encoded.insert(UInt8(count & 255), at: 0); count >>= 8 }
            length.append(0x80 | UInt8(encoded.count)); length.append(contentsOf: encoded)
        }
        return Data([tag]) + length + bytes
    }
    static func seq(_ data: Data) -> Data { tlv(0x30, data) }
    static func oid(_ bytes: [UInt8]) -> Data { tlv(6, Data(bytes)) }
    static func make(_ key: P256.Signing.PrivateKey) throws -> Data {
        let algorithm = seq(oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 4, 3, 2]))
        let name = seq(tlv(0x31, seq(oid([0x55, 4, 3]) + tlv(0x0c, Data("photowall".utf8)))))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        let validity = seq(tlv(0x18, Data(formatter.string(from: Date().addingTimeInterval(-86400)).utf8))
            + tlv(0x18, Data(formatter.string(from: Date().addingTimeInterval(10 * 365 * 86400)).utf8)))
        let publicInfo = seq(seq(oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 2, 1]) + oid([0x2a, 0x86, 0x48, 0xce, 0x3d, 3, 1, 7]))
            + tlv(3, Data([0]) + key.publicKey.x963Representation))
        let tbs = seq(tlv(0xa0, tlv(2, Data([2]))) + tlv(2, Data([1]) + PNIdentity.random(15)) + algorithm + name + validity + name + publicInfo)
        return seq(tbs + algorithm + tlv(3, Data([0]) + (try key.signature(for: tbs)).derRepresentation))
    }
}

nonisolated struct PNCacheHeader: Codable, Sendable { var version = 1; var photo: PNPhoto; var cachedAt: Date; var expiresAt: Date }

// The on-disk envelope matches DPWCAC01 in the portable .NET module. Each device
// uses its own local key; transferring originals never transfers that key.
actor PNPhotoCache {
    private let root: URL
    private let master: SymmetricKey
    private let maximumDiskBytes: Int
    private var active: [UUID: UUID] = [:]
    init(root: URL, key: SymmetricKey, maximumDiskBytes: Int = 10 * 1024 * 1024 * 1024) throws { self.root = root; master = key; self.maximumDiskBytes = maximumDiskBytes; try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    private func directory(_ provider: UUID, _ generation: UUID) -> URL { root.appending(path: provider.pnHex).appending(path: generation.pnHex) }
    private func check(_ path: URL) throws {
        try PNWire.require(path.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") || path.standardizedFileURL == root.standardizedFileURL, "Cache path escaped its root")
        var current = path
        while current.path.count >= root.path.count {
            if let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]) { try PNWire.require(values.isSymbolicLink != true, "Cache cannot contain links") }
            if current == root { break }; current.deleteLastPathComponent()
        }
    }
    func activate(_ provider: UUID, _ generation: UUID) throws {
        active[provider] = generation
        let parent = root.appending(path: provider.pnHex); try check(parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        for old in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) where old.lastPathComponent != generation.pnHex {
            try check(old)
            for file in try FileManager.default.contentsOfDirectory(at: old, includingPropertiesForKeys: nil) where ["pwc", "tmp"].contains(file.pathExtension) { try check(file); try FileManager.default.removeItem(at: file) }
        }
        try FileManager.default.createDirectory(at: directory(provider, generation), withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(at: directory(provider, generation), includingPropertiesForKeys: nil) where file.pathExtension == "tmp" { try check(file); try FileManager.default.removeItem(at: file) }
    }
    private func path(_ key: PNAssetKey) throws -> URL {
        try PNWire.require(active[key.providerId] == key.generationId, "Inactive source generation")
        let path = directory(key.providerId, key.generationId).appending(path: key.opaqueId + ".pwc"); try check(path); return path
    }
    private func derive(_ salt: Data) -> SymmetricKey { HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt, info: Data("DynamicPhotoWall/photo-cache/v1".utf8), outputByteCount: 32) }
    private func nonce(_ block: UInt64) throws -> AES.GCM.Nonce { var n = block.bigEndian; return try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + withUnsafeBytes(of: &n) { Data($0) }) }
    private func aad(_ id: String, _ block: UInt64, _ count: Int) -> Data { Data("DPWCAC01:\(id):\(block):\(count)".utf8) }
    func put(_ photo: PNPhoto, original: Data, now: Date = Date()) throws {
        try photo.validate(); try PNWire.require(photo.byteLength == original.count && PNWire.digest(original) == photo.key.imageId, "Original hash differs")
        let path = try path(photo.key); let salt = PNIdentity.random(32); let key = derive(salt)
        let header = PNCacheHeader(photo: photo, cachedAt: now, expiresAt: now.addingTimeInterval(14 * 86400))
        let encodedHeader = try PNWire.encode(header)
        var occupied = 0
        for provider in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try check(provider)
            for generation in try FileManager.default.contentsOfDirectory(at: provider, includingPropertiesForKeys: nil) {
                try check(generation)
                for file in try FileManager.default.contentsOfDirectory(at: generation, includingPropertiesForKeys: [.fileSizeKey]) where file.pathExtension == "pwc" && file != path {
                    try check(file); occupied += try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                }
            }
        }
        let projected = original.count + encodedHeader.count + 40 + 20 * ((original.count + 65535) / 65536 + 1)
        if occupied + projected > maximumDiskBytes { throw PNError.budget }
        var result = Data("DPWCAC01".utf8) + salt
        func append(_ plain: Data, block: UInt64) throws {
            let box = try AES.GCM.seal(plain, using: key, nonce: nonce(block), authenticating: aad(photo.key.opaqueId, block, plain.count))
            var length = UInt32(plain.count).littleEndian
            result.append(withUnsafeBytes(of: &length) { Data($0) }); result.append(box.ciphertext); result.append(box.tag)
        }
        try append(encodedHeader, block: 0)
        for offset in stride(from: 0, to: original.count, by: 65536) { try append(original.subdata(in: offset..<min(offset + 65536, original.count)), block: UInt64(offset / 65536 + 1)) }
        // Atomic staging contains ciphertext only.
        let temporary = path.deletingLastPathComponent().appending(path: UUID().pnHex + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try result.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: path.path) { _ = try FileManager.default.replaceItemAt(path, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: path) }
    }
    private func readBlock(_ input: FileHandle, key: SymmetricKey, opaque: String, block: UInt64, maximum: Int) throws -> Data {
        guard let length = try input.read(upToCount: 4), length.count == 4 else { throw PNError.invalid("Truncated cache") }
        let count = length.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        try PNWire.require(count > 0 && count <= maximum, "Invalid cache block")
        guard let cipher = try input.read(upToCount: count), cipher.count == count, let tag = try input.read(upToCount: 16), tag.count == 16 else { throw PNError.invalid("Truncated cache") }
        return try AES.GCM.open(AES.GCM.SealedBox(nonce: nonce(block), ciphertext: cipher, tag: tag), using: key, authenticating: aad(opaque, block, count))
    }
    private func open(_ path: URL) throws -> (FileHandle, SymmetricKey, PNCacheHeader) {
        try check(path); let input = try FileHandle(forReadingFrom: path)
        do {
            try PNWire.require(try input.read(upToCount: 8) == Data("DPWCAC01".utf8), "Unsupported cache format")
            guard let salt = try input.read(upToCount: 32), salt.count == 32 else { throw PNError.invalid("Truncated cache salt") }
            let key = derive(salt)
            let header = try PNWire.decode(PNCacheHeader.self, readBlock(input, key: key, opaque: path.deletingPathExtension().lastPathComponent, block: 0, maximum: 1024 * 1024))
            try header.photo.validate()
            try PNWire.require(header.version == 1 && header.photo.key.opaqueId == path.deletingPathExtension().lastPathComponent && abs(header.expiresAt.timeIntervalSince(header.cachedAt) - 14 * 86400) < 0.01, "Invalid cache header")
            return (input, key, header)
        } catch { try? input.close(); throw error }
    }
    func catalog(now: Date = Date()) throws -> [PNCacheHeader] {
        var result: [PNCacheHeader] = []
        for (provider, generation) in active {
            for file in try FileManager.default.contentsOfDirectory(at: directory(provider, generation), includingPropertiesForKeys: nil) where file.pathExtension == "pwc" {
                do {
                    let (input, _, header) = try open(file); try input.close()
                    if now >= header.expiresAt { try FileManager.default.removeItem(at: file) }
                    else if now >= header.cachedAt { result.append(header) }
                } catch { try? FileManager.default.removeItem(at: file) }
            }
        }
        return result
    }
    func read(_ asset: PNAssetKey, now: Date = Date()) throws -> Data? {
        do { return try readObject(asset, now: now) }
        catch { if let file = try? path(asset) { try? FileManager.default.removeItem(at: file) }; throw error }
    }
    private func readObject(_ asset: PNAssetKey, now: Date) throws -> Data? {
        let file = try path(asset); if !FileManager.default.fileExists(atPath: file.path) { return nil }
        let (input, key, header) = try open(file); defer { try? input.close() }
        if now >= header.expiresAt { try FileManager.default.removeItem(at: file); return nil }
        try PNWire.require(header.photo.key == asset && now >= header.cachedAt, "Invalid cache identity or clock")
        var result = Data(); var block: UInt64 = 1
        while result.count < header.photo.byteLength {
            let expected = min(65536, header.photo.byteLength - result.count)
            let bytes = try readBlock(input, key: key, opaque: asset.opaqueId, block: block, maximum: expected)
            try PNWire.require(bytes.count == expected, "Invalid chunk size"); result.append(bytes); block += 1
        }
        try PNWire.require((try input.read(upToCount: 1))?.isEmpty != false && PNWire.digest(result) == asset.imageId, "Cache hash differs")
        return result
    }
    func delete(_ key: PNAssetKey) throws { let file = try path(key); if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) } }
    func retainProviders(_ providers: Set<UUID>) throws {
        let keep = Set(providers.map(\.pnHex))
        for provider in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where !keep.contains(provider.lastPathComponent) {
            try check(provider)
            for generation in try FileManager.default.contentsOfDirectory(at: provider, includingPropertiesForKeys: nil) {
                try check(generation)
                for file in try FileManager.default.contentsOfDirectory(at: generation, includingPropertiesForKeys: nil) where ["pwc", "tmp"].contains(file.pathExtension) { try check(file); try FileManager.default.removeItem(at: file) }
            }
        }
        active = active.filter { providers.contains($0.key) }
    }
}

nonisolated struct PNStateStore: Sendable {
    let file: URL; let key: SymmetricKey
    func load() throws -> PNSnapshot? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: file))
        let state = try PNWire.decode(PNSnapshot.self, AES.GCM.open(box, using: key, authenticating: Data("photowall-state-v1".utf8)))
        try state.validate(); return state
    }
    func save(_ state: PNSnapshot) throws {
        try state.validate(); try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let box = try AES.GCM.seal(PNWire.encode(state), using: key, authenticating: Data("photowall-state-v1".utf8))
        try box.combined!.write(to: file, options: .atomic)
    }
}
