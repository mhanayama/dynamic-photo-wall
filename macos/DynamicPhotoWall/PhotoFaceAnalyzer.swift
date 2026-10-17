import CoreGraphics
import Foundation
import Vision

actor PhotoFaceAnalyzer {
    static let shared = PhotoFaceAnalyzer()
    private let file: URL
    private var cache: [String: [FaceRegion]]
    private var dirty = 0

    init(file: URL = RuntimePaths.root.appending(path: "faces.json")) {
        self.file = file
        cache = (try? JSONDecoder().decode([String: [FaceRegion]].self, from: Data(contentsOf: file))) ?? [:]
        cache = cache.filter { $0.value.allSatisfy(\.isValid) }
    }

    nonisolated static func cacheKey(_ asset: PhotoAsset) -> String {
        let source = asset.url.isFileURL ? asset.url.path : asset.url.absoluteString
        return "\(source)|\(asset.fileSize)|\(asset.modifiedAt)"
    }

    func cachedAssets(_ assets: [PhotoAsset]) -> [PhotoAsset] {
        assets.compactMap { asset in
            guard let faces = cache[Self.cacheKey(asset)] else { return nil }
            var known = asset; known.faces = faces; return known
        }
    }

    func analyze(_ asset: PhotoAsset, image: DecodedPhoto) -> [FaceRegion] {
        let key = Self.cacheKey(asset)
        if let found = cache[key] { return found }
        guard !Task.isCancelled else { return [] }
        do {
            let source = image.image
            let scale = min(1, 640.0 / Double(max(source.width, source.height)))
            let width = max(1, Int(Double(source.width) * scale)), height = max(1, Int(Double(source.height) * scale))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let small = context.makeImage() else { return [] }
            let request = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cgImage: small, orientation: .up).perform([request])
            guard !Task.isCancelled else { return [] }
            let faces = (request.results ?? []).map { observation in
                let box = observation.boundingBox
                return FaceRegion(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            }.filter(\.isValid)
            cache[key] = faces
            dirty += 1
            if cache.count > 10_000 {
                for old in cache.keys.sorted().prefix(cache.count - 10_000) { cache.removeValue(forKey: old) }
            }
            if dirty >= 16 { flush() }
            return faces
        } catch {
            WallLog.write("顔位置を取得できないため通常のモーションを使用します。", error: error)
            return []
        }
    }

    func flush() {
        guard dirty > 0 else { return }
        do { try RuntimePaths.write(cache, to: file); dirty = 0 }
        catch { WallLog.write("顔位置キャッシュを保存できません。", error: error) }
    }
}
