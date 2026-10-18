import Foundation
import CryptoKit

// Native implementation of the same versioned wire contract as shared/…Networking.
// These values deliberately contain no PhotoKit identifiers, bookmarks or local paths.
nonisolated enum PNError: Error, LocalizedError {
    case invalid(String)
    case budget
    var errorDescription: String? { switch self { case .invalid(let message): message; case .budget: "写真キャッシュのディスク予算に達しました。" } }
}
nonisolated enum PNWire {
    static func require(_ value: Bool, _ message: String) throws { if !value { throw PNError.invalid(message) } }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = format.date(from: text) { return date }
            format.formatOptions = [.withInternetDateTime]
            guard let date = format.date(from: text) else { throw PNError.invalid("Invalid wire date") }
            return date
        }
        return try decoder.decode(type, from: data)
    }
    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func id(_ text: String) -> UUID {
        let hex = String(digest(Data(text.utf8)).prefix(32))
        return uuid(hex)
    }
    static func uuid(_ hex: String) -> UUID {
        let s = Array(hex); return UUID(uuidString: String(s[0..<8]) + "-" + String(s[8..<12]) + "-" + String(s[12..<16]) + "-" + String(s[16..<20]) + "-" + String(s[20..<32]))!
    }
}
extension UUID { nonisolated var pnHex: String { uuidString.replacingOccurrences(of: "-", with: "").lowercased() } }
extension UUID { nonisolated static let pnZero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")! }

nonisolated enum PNJSON: Codable, Equatable, Sendable {
    case object([String: PNJSON]), array([PNJSON]), string(String), integer(Int64), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: PNJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([PNJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v); case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v); case .number(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .bool(let v): try c.encode(v); case .null: try c.encodeNil()
        }
    }
}
nonisolated struct PNPacket: Codable, Sendable {
    var type: String; var body: PNJSON
    init<T: Encodable>(_ type: String, _ value: T) throws { self.type = type; body = try PNWire.decode(PNJSON.self, PNWire.encode(value)) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try PNWire.decode(type, PNWire.encode(body)) }
}
nonisolated struct PNHello: Codable, Equatable, Sendable {
    var protocolVersion = 1; var peerId: UUID; var name: String; var platform = "macos"
    func validate() throws { try PNWire.require(protocolVersion == 1 && peerId != .pnZero && !name.isEmpty && name.count <= 128 && ["macos", "windows"].contains(platform), "Unsupported peer identity") }
}
nonisolated struct PNCandidate: Codable, Equatable, Identifiable, Sendable {
    var hello: PNHello; var host: String; var port: Int
    var id: UUID { hello.peerId }
}
nonisolated struct PNDisplayKey: Codable, Hashable, Sendable {
    var peerId: UUID; var displayId: String
    var layoutId: String { "\(peerId.pnHex):\(displayId.utf16.count):\(displayId)" }
}
nonisolated struct PNDisplay: Codable, Equatable, Identifiable, Sendable {
    var key: PNDisplayKey; var selected: Bool; var groupId: UUID?; var x: Int; var y: Int; var width: Int; var height: Int
    var name: String? = nil
    var displayName: String { name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? "ディスプレイ" }
    var id: String { key.layoutId }
    var unit: UUID { groupId ?? PNWire.id(key.layoutId) }
    func validate() throws {
        try PNWire.require((name?.utf16.count ?? 0) <= 256, "Invalid display name")
        try PNWire.require(key.peerId != .pnZero && !key.displayId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && key.displayId.utf16.count <= 256 && groupId != .pnZero
            && width > 0 && height > 0 && width <= 32768 && height <= 32768
            && x >= Int(Int32.min) && x <= Int(Int32.max) && y >= Int(Int32.min) && y <= Int(Int32.max), "Invalid physical display")
    }
}
nonisolated struct PNGroup: Codable, Equatable, Identifiable, Sendable { var id: UUID; var name: String }
nonisolated struct PNSource: Codable, Equatable, Identifiable, Sendable {
    var providerId: UUID; var sourceId: UUID; var name: String
    var id: String { "\(providerId.pnHex):\(sourceId.pnHex)" }
}
nonisolated struct PNSelection: Codable, Equatable, Sendable { var providerId: UUID; var sourceId: UUID; var generationId: UUID }
nonisolated struct PNOptions: Codable, Equatable, Sendable {
    var values: [String: PNJSON]
    init(values: [String: PNJSON]) { self.values = values }
    init(from decoder: Decoder) throws { values = try decoder.singleValueContainer().decode([String: PNJSON].self) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(values) }
    func validate() throws {
        for (key, value) in values {
            switch value {
            case .integer(let number): try PNWire.require(number >= 0 && number <= 100000, "Invalid playback parameter: \(key)")
            case .number(let number): try PNWire.require(number.isFinite && number >= 0 && number <= 100000, "Invalid playback parameter: \(key)")
            case .bool: break
            case .string(let color): try PNWire.require(key == "background" && color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil, "Invalid background")
            default: throw PNError.invalid("Invalid playback option")
            }
        }
        if let value = values["galleryMax"] {
            guard case .integer(let count) = value, (1...20).contains(count) else { throw PNError.invalid("Invalid gallery photo count") }
        }
    }
}
nonisolated struct PNSnapshot: Codable, Equatable, Sendable {
    var wallId: UUID; var sessionId: UUID; var leaderId: UUID; var revision: Int64
    var groups: [PNGroup]; var displays: [PNDisplay]; var sources: [PNSelection]; var playback: PNOptions; var term: Int64 = 0
    var appliedRequests: [UUID] = []
    var mergedWalls: [UUID] = []
    private enum CodingKeys: String, CodingKey { case wallId, sessionId, leaderId, revision, groups, displays, sources, playback, term, appliedRequests, mergedWalls }
    func validate() throws {
        try PNWire.require(revision >= 0 && term >= 0 && groups.count <= 128 && displays.count <= 128 && sources.count <= 1024, "Invalid wall size")
        try PNWire.require(wallId != .pnZero && sessionId != .pnZero && leaderId != .pnZero && appliedRequests.count <= 1024
            && Set(appliedRequests).count == appliedRequests.count && !appliedRequests.contains(.pnZero) && mergedWalls.count <= 1024 && !mergedWalls.contains(wallId), "Invalid wall identity or history")
        try PNWire.require(Set(groups.map(\.id)).count == groups.count && Set(displays.map(\.key)).count == displays.count, "Duplicate wall members")
        try PNWire.require(groups.allSatisfy { $0.id != .pnZero && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.utf16.count <= 128 }, "Invalid groups")
        for d in displays {
            try d.validate()
            try PNWire.require(d.width > 0 && d.height > 0 && d.width <= 32768 && d.height <= 32768 && !d.key.displayId.isEmpty && d.key.displayId.utf16.count <= 256 && (d.groupId == nil || groups.contains { $0.id == d.groupId }), "Invalid display")
            try PNWire.require(d.x >= Int(Int32.min) && d.x <= Int(Int32.max) && d.y >= Int(Int32.min) && d.y <= Int(Int32.max), "Invalid physical coordinates")
        }
        for unit in Dictionary(grouping: displays.filter(\.selected), by: \.unit).values {
            try PNWire.require((unit.map { Double($0.x) + Double($0.width) }.max()! - Double(unit.map(\.x).min()!)) <= 32768
                && (unit.map { Double($0.y) + Double($0.height) }.max()! - Double(unit.map(\.y).min()!)) <= 32768, "Wall canvas is too large")
        }
        try PNWire.require(Set(sources.map { "\($0.providerId):\($0.sourceId)" }).count == sources.count
            && Dictionary(grouping: sources, by: \.providerId).values.allSatisfy { Set($0.map(\.generationId)).count == 1 }, "Conflicting source generations")
        try PNWire.require(sources.allSatisfy { $0.providerId != .pnZero && $0.sourceId != .pnZero && $0.generationId != .pnZero }, "Invalid photo source selection")
        try playback.validate()
    }
    func prefers(_ next: PNSnapshot) -> Bool {
        guard wallId == next.wallId else { return false }
        if sessionId == next.sessionId { return next.revision > revision }
        if term != next.term { return next.term > term }
        return next.leaderId.pnHex < leaderId.pnHex
    }
}
nonisolated struct PNProposal: Codable, Sendable { var requestId: UUID; var expectedRevision: Int64; var groups: [PNGroup]; var displays: [PNDisplay]; var sources: [PNSelection]; var playback: PNOptions }
nonisolated struct PNResult: Codable, Sendable { var requestId: UUID; var accepted: Bool; var error: String?; var snapshot: PNSnapshot }
nonisolated struct PNNotice: Codable, Sendable { var snapshot: PNSnapshot; var members: [UUID] }
nonisolated struct PNInventory: Codable, Sendable { var candidate: PNCandidate; var displays: [PNDisplay]; var sources: [PNSource] }
nonisolated struct PNHeartbeat: Codable, Sendable { var members: [PNCandidate]; var leaderId: UUID; var sessionId: UUID; var revision: Int64 }
nonisolated struct PNPing: Codable, Sendable { var requestId: UUID; var sentAt: Double }
nonisolated struct PNPong: Codable, Sendable { var requestId: UUID; var sentAt: Double; var receivedAt: Double; var repliedAt: Double }
nonisolated struct PNAssetKey: Codable, Hashable, Sendable {
    var providerId: UUID; var sourceId: UUID; var generationId: UUID; var imageId: String
    var opaqueId: String { PNWire.digest(Data("\(providerId.pnHex):\(sourceId.pnHex):\(generationId.pnHex):\(imageId)".utf8)) }
    func validate() throws { try PNWire.require(providerId != .pnZero && sourceId != .pnZero && generationId != .pnZero && imageId.count == 64 && imageId.allSatisfy { "0123456789abcdef".contains($0) }, "Invalid asset identity") }
}
nonisolated struct PNFaceRegion: Codable, Equatable, Sendable {
    var x: Double; var y: Double; var width: Double; var height: Double
    var isValid: Bool { [x, y, width, height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1 && y + height <= 1 }
}
nonisolated struct PNFaces: Codable, Equatable, Sendable {
    var version = 1; var pixelWidth: Int; var pixelHeight: Int; var detector: String; var detectorVersion = "1"; var state: String; var faces: [PNFaceRegion]
}
nonisolated struct PNPhoto: Codable, Equatable, Sendable {
    var key: PNAssetKey; var pixelWidth: Int; var pixelHeight: Int; var byteLength: Int; var faceMetadata: PNFaces; var orientation: Int = 1
    private enum CodingKeys: String, CodingKey { case key, pixelWidth, pixelHeight, byteLength, faceMetadata, orientation }
    func validate() throws {
        try key.validate()
        try PNWire.require(key.imageId.count == 64 && key.imageId.allSatisfy { "0123456789abcdef".contains($0) }
            && byteLength > 0 && byteLength <= 256 * 1024 * 1024 && pixelWidth > 0 && pixelHeight > 0
            && (1...8).contains(orientation) && pixelWidth == faceMetadata.pixelWidth && pixelHeight == faceMetadata.pixelHeight
            && faceMetadata.version == 1 && faceMetadata.faces.count <= 4096 && faceMetadata.faces.allSatisfy { $0.isValid && $0.x + $0.width <= 1 && $0.y + $0.height <= 1 }
            && !faceMetadata.detector.isEmpty && faceMetadata.detector.count <= 128 && !faceMetadata.detectorVersion.isEmpty && faceMetadata.detectorVersion.count <= 128
            && (faceMetadata.state == "complete" || faceMetadata.faces.isEmpty)
            && ["pending", "complete", "failed"].contains(faceMetadata.state), "Invalid photo metadata")
    }
}
nonisolated struct PNCatalog: Codable, Sendable { var photos: [PNPhoto] }
nonisolated struct PNAssetRequest: Codable, Sendable { var requestId: UUID; var key: PNAssetKey }
nonisolated struct PNChunk: Codable, Sendable { var requestId: UUID; var photo: PNPhoto; var index: Int; var data: Data; var last: Bool }
nonisolated struct PNRect: Codable, Equatable, Sendable { var x: Double; var y: Double; var width: Double; var height: Double }
nonisolated struct PNSize: Codable, Equatable, Sendable { var width: Double; var height: Double }
nonisolated struct PNPlacement: Codable, Identifiable, Sendable {
    var id: Int; var asset: PNAssetKey; var displayId: String?; var clip: PNRect
    var width: Double; var height: Double; var fromX: Double; var fromY: Double; var toX: Double; var toY: Double
    var fromScale: Double; var toScale: Double; var centerX: Double; var centerY: Double
    var startSeconds: Double; var motionSeconds: Double; var visibleFrom: Double; var visibleUntil: Double; var fadeSeconds: Double; var cornerRadius: Double; var ease: Bool
    func evaluate(_ elapsed: Double) -> (x: Double, y: Double, scale: Double, opacity: Double) {
        var t = min(1, max(0, (elapsed - startSeconds) / motionSeconds)); if ease { t = 0.5 - cos(t * .pi) / 2 }
        let opacity = elapsed < visibleFrom || elapsed >= visibleUntil ? 0 : fadeSeconds <= 0 ? 1 : min(min(1, max(0, (elapsed - visibleFrom) / fadeSeconds)), min(1, max(0, (visibleUntil - elapsed) / fadeSeconds)))
        return (fromX + (toX - fromX) * t, fromY + (toY - fromY) * t, fromScale + (toScale - fromScale) * t, opacity)
    }
}
nonisolated struct PNAmbient: Codable, Sendable { var at: Double; var png: Data; var displayId: String? }
nonisolated struct PNScene: Codable, Identifiable, Sendable {
    var id: UUID; var groupId: UUID; var sessionId: UUID; var settingsRevision: Int64; var mode: String
    var viewport: PNSize; var displays: [PNDisplay]; var duration: Double; var fadeSeconds: Double; var background: String; var placements: [PNPlacement]; var ambient: [PNAmbient]
    func validate() throws {
        try PNWire.require(id != .pnZero && groupId != .pnZero && sessionId != .pnZero && settingsRevision >= 0, "Invalid scene identity")
        try PNWire.require(duration.isFinite && duration > 0 && duration <= 3600 && fadeSeconds >= 0 && fadeSeconds <= duration
            && viewport.width > 0 && viewport.width <= 32768 && viewport.height > 0 && viewport.height <= 32768
            && !displays.isEmpty && displays.count <= 128 && !placements.isEmpty && placements.count <= 1024 && ambient.count <= 64
            && ["gallery", "galleryScroll", "verticalPan", "horizontalPan", "zoom"].contains(mode), "Invalid scene")
        for display in displays { try display.validate() }
        try PNWire.require(Set(displays.map(\.key)).count == displays.count && Set(placements.map(\.id)).count == placements.count, "Duplicate scene identity")
        for p in placements {
            try p.asset.validate()
            try PNWire.require([p.width, p.height, p.fromX, p.fromY, p.toX, p.toY, p.fromScale, p.toScale, p.centerX, p.centerY, p.startSeconds, p.motionSeconds, p.visibleFrom, p.visibleUntil, p.fadeSeconds, p.cornerRadius, p.clip.x, p.clip.y, p.clip.width, p.clip.height].allSatisfy(\.isFinite)
                && p.width > 0 && p.height > 0 && p.clip.width > 0 && p.clip.height > 0 && p.motionSeconds > 0 && p.fromScale > 0 && p.toScale > 0 && p.visibleFrom >= 0 && p.visibleUntil <= duration && p.visibleUntil >= p.visibleFrom && p.fadeSeconds >= 0 && p.cornerRadius >= 0, "Invalid placement")
        }
        try PNWire.require(ambient.allSatisfy { $0.png.count <= 131072 && $0.at >= 0 && $0.at <= duration }, "Invalid ambient frames")
    }
}
nonisolated struct PNCommit: Codable, Equatable, Sendable { var planId: UUID; var groupId: UUID; var startAt: Double }
nonisolated struct PNReady: Codable, Sendable { var planId: UUID; var groupId: UUID }
nonisolated struct PNOperation: Codable, Sendable { var requestId: UUID; var operation: String }
nonisolated struct PNControl: Codable, Sendable { var operation: String; var effectiveAt: Double }
nonisolated struct PNPlaybackStatus: Codable, Sendable { var paused: Bool; var stopped: Bool; var effectiveAt: Double }
nonisolated struct PNPreviewRequest: Codable, Sendable { var enabled: Bool; var displays: [PNDisplay]; var groups: [PNGroup] }
nonisolated struct PNPreviewPlan: Codable, Sendable { var enabled: Bool; var effectiveAt: Double; var displays: [PNDisplay]; var groups: [PNGroup] }
nonisolated struct PNMergeRequest: Codable, Sendable { var requestId: UUID; var previous: PNSnapshot; var members: [PNCandidate] }
nonisolated struct PNMigration: Codable, Sendable { var requestId: UUID; var previousWallId: UUID; var snapshot: PNSnapshot; var members: [PNCandidate] }

extension PNPhoto {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try c.decode(PNAssetKey.self, forKey: .key), pixelWidth: try c.decode(Int.self, forKey: .pixelWidth),
            pixelHeight: try c.decode(Int.self, forKey: .pixelHeight), byteLength: try c.decode(Int.self, forKey: .byteLength),
            faceMetadata: try c.decode(PNFaces.self, forKey: .faceMetadata), orientation: try c.decodeIfPresent(Int.self, forKey: .orientation) ?? 1)
    }
}
extension PNSnapshot {
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(wallId: try c.decode(UUID.self, forKey: .wallId), sessionId: try c.decode(UUID.self, forKey: .sessionId),
            leaderId: try c.decode(UUID.self, forKey: .leaderId), revision: try c.decode(Int64.self, forKey: .revision),
            groups: try c.decode([PNGroup].self, forKey: .groups), displays: try c.decode([PNDisplay].self, forKey: .displays),
            sources: try c.decode([PNSelection].self, forKey: .sources), playback: try c.decode(PNOptions.self, forKey: .playback),
            term: try c.decodeIfPresent(Int64.self, forKey: .term) ?? 0, appliedRequests: try c.decodeIfPresent([UUID].self, forKey: .appliedRequests) ?? [],
            mergedWalls: try c.decodeIfPresent([UUID].self, forKey: .mergedWalls) ?? [])
    }
}
