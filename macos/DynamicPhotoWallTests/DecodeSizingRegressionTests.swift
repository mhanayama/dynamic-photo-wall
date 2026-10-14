import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import DynamicPhotoWall

@MainActor
struct DecodeSizingRegressionTests {
    @Test func requestedWidthCreatesDistinctDecodeVariantsWithoutUpscaling() {
        let asset = PhotoAsset(url: URL(filePath: "/large.jpg"), pixelWidth: 8000, pixelHeight: 4000)
        let small = PhotoDecodeRequest(asset, desiredWidth: 1000)
        let large = PhotoDecodeRequest(asset, desiredWidth: 2000)
        #expect(small.maximumPixelSize == 1000)
        #expect(large.maximumPixelSize == 2000)
        #expect(small.key != large.key)
        let tiny = PhotoAsset(url: URL(filePath: "/tiny.jpg"), pixelWidth: 80, pixelHeight: 40)
        #expect(PhotoDecodeRequest(tiny, desiredWidth: 1920).maximumPixelSize == 80)
    }

    @Test func tallPanUsesPixelBudgetInsteadOfAFixed4096LongEdge() {
        let asset = PhotoAsset(url: URL(filePath: "/tall.jpg"), pixelWidth: 500, pixelHeight: 100000)
        let request = PhotoDecodeRequest(asset, desiredWidth: 1843)
        #expect(request.maximumPixelSize > 4096)
        let width = Int(ceil(Double(request.maximumPixelSize) * Double(asset.aspectRatio)))
        #expect(width * request.maximumPixelSize <= 16_000_000)
        let plan = WallMotionGeometry.plan(for: .verticalPan, asset: asset,
                                           viewport: CGSize(width: 1920, height: 1080), settings: WallSettings())
        #expect(abs(plan.width / plan.height - asset.aspectRatio) < 0.000001)
    }

    @Test func actualImageIODecodeMatchesTheRequestedWidth() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "decode-sizing-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try #require(CGContext(data: nil, width: 2048, height: 1024, bitsPerComponent: 8,
            bytesPerRow: 2048 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let asset = PhotoAsset(url: url, pixelWidth: 2048, pixelHeight: 1024)
        let decoded = try #require(await PhotoImageDecoder().decode(PhotoDecodeRequest(asset, desiredWidth: 256)))
        #expect(decoded.image.width == 256)
        #expect(decoded.image.height == 128)
    }
}

private actor DecodeSizeRecorder {
    private(set) var sizes: [Int] = []
    func decode(_ request: PhotoDecodeRequest) -> DecodedPhoto? {
        sizes.append(request.maximumPixelSize)
        guard let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return context.makeImage().map { DecodedPhoto(image: $0) }
    }
}

@MainActor
struct DecodeVariantRegressionTests {
    @Test func resolutionUpgradeKeepsOldPixelsAndUsesDistinctCachedVariants() async throws {
        let recorder = DecodeSizeRecorder()
        let images = PhotoImageStore(decode: { await recorder.decode($0) })
        let asset = PhotoAsset(url: URL(filePath: "/variant.jpg"), pixelWidth: 8000, pixelHeight: 4000)
        let key = PhotoImageKey(asset)
        images.setDisplayedAssets([asset], cacheMegabytes: 64, desiredWidths: [key: 1000])
        #expect(await images.prepare([asset]))
        let old = try #require(images.image(for: asset))
        images.setDisplayedAssets([asset], cacheMegabytes: 64, desiredWidths: [key: 2000])
        #expect(images.image(for: asset) === old)
        #expect(!images.isReady([asset]))
        #expect(await images.prepare([asset]))
        #expect(images.isReady([asset]))
        #expect(await recorder.sizes == [1000, 2000])
        images.setDisplayedAssets([asset], cacheMegabytes: 64, desiredWidths: [key: 1000])
        #expect(await images.prepare([asset]))
        #expect(await recorder.sizes == [1000, 2000])
    }
}
