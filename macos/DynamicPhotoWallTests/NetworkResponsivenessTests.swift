import Foundation
import CryptoKit
import Testing
@testable import DynamicPhotoWall

@MainActor struct NetworkResponsivenessTests {
    @Test func notificationBurstsUseLatestStateAndAllowAFollowup() async throws {
        let updates = PNViewUpdates(delay: .milliseconds(1))
        var latest = 0, observed: [Int] = []
        for i in 1...10000 {
            latest = i
            updates.request {
                observed.append(latest)
                latest += 1
                updates.request { observed.append(latest) }
            }
        }
        for _ in 0..<100 where observed.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(observed == [10000, 10001])
    }
    @Test func cancelledUpdatesCannotRefreshANewSession() async throws {
        let updates = PNViewUpdates(delay: .milliseconds(1))
        var observed: [String] = []
        updates.request { observed.append("old") }
        updates.cancel()
        updates.request { observed.append("new") }
        for _ in 0..<100 where observed.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(observed == ["new"])
    }
    @Test func chunkProgressNotifiesOnlyAfterEncryptedPhotoPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "DPW.Transfer.Tests.\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try PNPhotoCache(root: root, key: SymmetricKey(size: .bits256))
        let provider = UUID(), source = UUID(), generation = UUID()
        let bytes = Data(repeating: 73, count: 150000)
        let key = PNAssetKey(providerId: provider, sourceId: source, generationId: generation, imageId: PNWire.digest(bytes))
        let photo = PNPhoto(key: key, pixelWidth: 6000, pixelHeight: 4000, byteLength: bytes.count,
            faceMetadata: PNFaces(pixelWidth: 6000, pixelHeight: 4000, detector: "fixture", state: "complete", faces: []))
        let transfers = PNPhotoTransfers(local: UUID(), provider: EmptyProvider(), cache: cache)
        defer { transfers.stop() }
        try await transfers.configure([PNSelection(providerId: provider, sourceId: source, generationId: generation)])
        let request = try #require(try await transfers.accept(provider, PNCatalog(photos: [photo])).first)
        var notifications = 0
        transfers.changed = { notifications += 1 }
        for (index, offset) in stride(from: 0, to: bytes.count, by: 65536).enumerated() {
            let end = min(offset + 65536, bytes.count), last = end == bytes.count
            let completed = try await transfers.receive(provider, PNChunk(requestId: request.requestId, photo: photo,
                index: index, data: bytes.subdata(in: offset..<end), last: last))
            #expect(completed == last)
            #expect(notifications == (last ? 1 : 0))
            #expect(transfers.available.count == (last ? 1 : 0))
        }
        #expect(try await cache.read(key) == bytes)
        #expect(try await transfers.accept(provider, PNCatalog(photos: [photo])).isEmpty)
        #expect(transfers.missing(provider).isEmpty)
        let file = root.appending(path: provider.pnHex).appending(path: generation.pnHex).appending(path: key.opaqueId + ".pwc")
        var encrypted = try Data(contentsOf: file); encrypted[encrypted.count - 1] ^= 1; try encrypted.write(to: file)
        #expect(try await transfers.accept(provider, PNCatalog(photos: [photo])).isEmpty) // Catalogs do not decrypt validated originals again.
        await #expect(throws: (any Error).self) { try await transfers.readOriginal(key) }
        #expect(transfers.available.isEmpty)
        #expect(transfers.missing(provider).map(\.key) == [key])
    }
    private final class EmptyProvider: PNPhotoProviding {
        var sources: [PNSource] { [] }
        func read(_ selection: PNSelection) -> AsyncThrowingStream<PNImportedPhoto, Error> { AsyncThrowingStream { $0.finish() } }
    }
}
