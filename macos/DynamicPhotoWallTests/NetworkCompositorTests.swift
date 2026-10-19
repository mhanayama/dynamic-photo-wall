import AppKit
import QuartzCore
import Testing
@testable import DynamicPhotoWall

// Offscreen layers/bitmaps only: no desktop windows or GUI automation.
@MainActor struct NetworkCompositorTests {
    let size = CGSize(width: 80, height: 60)
    func image(_ rgba: [UInt8]) throws -> CGImage {
        try #require(AmbientProcessor.image(rgba, width: rgba.count / 4, height: 1))
    }
    func fixture(at: Double = 0, opacity: Double = 1, ambient: [PNPlayback.PNAmbientImage] = [], moving: Bool = false) throws -> PNPlaybackLayer {
        let key = PNAssetKey(providerId: UUID(), sourceId: UUID(), generationId: UUID(), imageId: String(repeating: "a", count: 64))
        let display = PNDisplay(key: PNDisplayKey(peerId: key.providerId, displayId: "1"), selected: true, groupId: nil, x: 0, y: 0, width: 80, height: 60)
        let placement = PNPlacement(id: 1, asset: key, displayId: nil, clip: PNRect(x: 0, y: 0, width: 80, height: 60),
            width: 30, height: 20, fromX: 5, fromY: 6, toX: moving ? 35 : 5, toY: moving ? 20 : 6,
            fromScale: 1, toScale: moving ? 1.5 : 1, centerX: 0.25, centerY: 0.75,
            startSeconds: 0, motionSeconds: 10, visibleFrom: 0, visibleUntil: 100, fadeSeconds: 0, cornerRadius: 0, ease: false)
        let plan = PNScene(id: UUID(), groupId: UUID(), sessionId: UUID(), settingsRevision: 1, mode: "gallery",
            viewport: PNSize(width: 80, height: 60), displays: [display], duration: 100, fadeSeconds: 0,
            background: "#000000", placements: [placement], ambient: ambient.map(\.frame))
        let photo = try #require(AmbientProcessor.image([255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,0,255], width: 2, height: 2))
        let frame = PNPlayback.Frame(plan: plan, images: [key.opaqueId: DecodedPhoto(image: photo)], ambient: ambient)
        return PNPlaybackLayer(frame: frame, display: display, elapsed: at, opacity: opacity)
    }
    func at(_ layer: PNPlaybackLayer, _ elapsed: Double, opacity: Double? = nil) -> PNPlaybackLayer {
        PNPlaybackLayer(frame: layer.frame, display: layer.display, elapsed: elapsed, opacity: opacity ?? layer.opacity)
    }
    func background(_ color: [UInt8], at: Double) throws -> PNPlayback.PNAmbientImage {
        let image = try image(color)
        return PNPlayback.PNAmbientImage(frame: PNAmbient(at: at, png: try #require(PNImageDecode.png(image)), displayId: nil),
            image: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)))
    }
    func bitmap(_ layers: [PNPlaybackLayer], composited: Bool, size: CGSize? = nil) throws -> [UInt8] {
        let size = size ?? self.size, width = Int(size.width), height = Int(size.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let canvas = try #require(CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            canvas.translateBy(x: 0, y: size.height); canvas.scaleBy(x: 1, y: -1)
            if composited {
                let view = PNSceneView(); view.frame = CGRect(origin: .zero, size: size); view.layers = layers
                try #require(view.layer).render(in: canvas)
            } else {
                NSGraphicsContext.saveGraphicsState()
                defer { NSGraphicsContext.restoreGraphicsState() }
                NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: true)
                let view = PNSceneView(composited: false); view.frame = CGRect(origin: .zero, size: size)
                view.layers = layers; view.draw(view.bounds)
            }
        }
        return pixels
    }

    @Test func unchangedStaticAndPausedFramesDoNotMutateTheLayerTree() throws {
        let layer = try fixture(), renderer = PNLayerCompositor()
        renderer.update([layer], size: size)
        let mutations = renderer.mutationCount
        let scene = try #require(renderer.scenes.values.first)
        let contents = scene.cards[0].image.contents as AnyObject?
        for tick in 0...600 { renderer.update([at(layer, Double(tick) / 60)], size: size) }
        #expect(renderer.contentBuildCount == 1)
        #expect(renderer.mutationCount == mutations)
        #expect(scene.cards[0].image.contents as AnyObject? === contents)
        for _ in 0..<60 { renderer.update([at(layer, 10)], size: size) }
        #expect(renderer.mutationCount == mutations)
    }

    @Test func motionUsesTheExactForegroundGeometryWithoutReplacingImageContents() throws {
        let layer = try fixture(moving: true), renderer = PNLayerCompositor()
        renderer.update([layer], size: size)
        let scene = try #require(renderer.scenes.values.first)
        let image = scene.cards[0].image.contents as AnyObject?
        renderer.update([at(layer, 5)], size: size)
        #expect(scene.cards[0].image.frame == CGRect(x: 18.125, y: 9.25, width: 37.5, height: 25))
        #expect(scene.cards[0].image.contents as AnyObject? === image)
        #expect(renderer.contentBuildCount == 1)
        #expect(scene.root.animationKeys() == nil && scene.cards[0].image.animationKeys() == nil)
    }

    @Test func duplicateAmbientPngsShareContentsAndDoNotAnimateAnUnchangedBackground() throws {
        let a = try background([255, 0, 0, 255], at: 0), b = try background([255, 0, 0, 255], at: 10)
        let layer = try fixture(ambient: [a, b]), renderer = PNLayerCompositor()
        #expect(layer.frame.ambient[0].image === layer.frame.ambient[1].image)
        renderer.update([layer], size: size)
        let mutations = renderer.mutationCount
        for tick in 1..<600 { renderer.update([at(layer, Double(tick) / 60)], size: size) }
        #expect(renderer.mutationCount == mutations)
    }

    @Test func equalTranslucentAmbientSamplesPreserveSourceOverBlending() throws {
        let layer = try fixture(at: 5, ambient: [background([128, 0, 0, 128], at: 0), background([128, 0, 0, 128], at: 10)])
        let renderer = PNLayerCompositor(); renderer.update([layer], size: size)
        #expect(try #require(renderer.scenes.values.first).nextBackground.opacity == 0.5)
        let old = try bitmap([layer], composited: false), new = try bitmap([layer], composited: true)
        for i in 0..<4 { #expect(abs(Int(old[i]) - Int(new[i])) < 4) }
    }

    @Test func backgroundCrossfadeChangesOpacityWhilePhotographContentsStayHeld() throws {
        let layer = try fixture(ambient: [background([255, 0, 0, 255], at: 0), background([0, 0, 255, 255], at: 10)])
        let renderer = PNLayerCompositor(); renderer.update([at(layer, 2)], size: size)
        let scene = try #require(renderer.scenes.values.first), image = scene.cards[0].image.contents as AnyObject?
        #expect(abs(scene.nextBackground.opacity - 0.2) < 0.00001)
        renderer.update([at(layer, 7)], size: size)
        #expect(abs(scene.nextBackground.opacity - 0.7) < 0.00001)
        #expect(scene.cards[0].image.contents as AnyObject? === image && renderer.contentBuildCount == 1)
    }

    @Test func pixelsMatchBitmapForOrientationPositionAndResize() throws {
        let layer = try fixture()
        for size in [self.size, CGSize(width: 40, height: 30)] {
            let old = try bitmap([layer], composited: false, size: size)
            let new = try bitmap([layer], composited: true, size: size)
            let scale = size.width / self.size.width, width = Int(size.width)
            for point in [CGPoint(x: 1, y: 1), CGPoint(x: 10, y: 10), CGPoint(x: 28, y: 10), CGPoint(x: 10, y: 22), CGPoint(x: 28, y: 22), CGPoint(x: 60, y: 40)] {
                let i = (Int(point.y * scale) * width + Int(point.x * scale)) * 4
                for c in 0..<4 { #expect(abs(Int(old[i + c]) - Int(new[i + c])) < 4, "point=\(point), channel=\(c), old=\(old[i+c]), new=\(new[i+c])") }
            }
        }
    }

    @Test func sceneOpacityCompositesTheBackgroundAndOverlappingPhotosAsOneGroup() throws {
        let a = try fixture(), b = try fixture(at: 2, opacity: 0.5,
            ambient: [background([0, 0, 255, 255], at: 0), background([0, 255, 0, 255], at: 10)])
        let old = try bitmap([a, b], composited: false), new = try bitmap([a, b], composited: true)
        for point in [CGPoint(x: 1, y: 1), CGPoint(x: 10, y: 10), CGPoint(x: 28, y: 22), CGPoint(x: 60, y: 40)] {
            let i = (Int(point.y) * 80 + Int(point.x)) * 4
            for c in 0..<4 { #expect(abs(Int(old[i + c]) - Int(new[i + c])) < 4, "point=\(point), channel=\(c), old=\(old[i+c]), new=\(new[i+c])") }
        }
    }

    @Test func embeddedViewAndBackgroundOrientationMatchTheBitmapPath() throws {
        let source = try #require(AmbientProcessor.image([255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,0,255], width: 2, height: 2))
        let ambient = PNPlayback.PNAmbientImage(frame: PNAmbient(at: 0, png: try #require(PNImageDecode.png(source)), displayId: nil),
            image: NSImage(cgImage: source, size: CGSize(width: 2, height: 2)))
        let layer = try fixture(ambient: [ambient])
        let old = try bitmap([layer], composited: false), new = try bitmap([layer], composited: true)
        for point in [CGPoint(x: 1, y: 1), CGPoint(x: 70, y: 1), CGPoint(x: 1, y: 55), CGPoint(x: 70, y: 55), CGPoint(x: 10, y: 10)] {
            let i = (Int(point.y) * 80 + Int(point.x)) * 4
            for c in 0..<4 { #expect(abs(Int(old[i + c]) - Int(new[i + c])) < 4, "point=\(point), channel=\(c), old=\(old[i+c]), new=\(new[i+c])") }
        }
    }

    @Test func spannedCropRoundedCornersAndTransparentPhotosMatchTheBitmapPath() throws {
        let original = try fixture()
        var plan = original.frame.plan
        var display = original.display; display.x = 40
        var remote = display; remote.key.displayId = "remote"; remote.x = 0; remote.width = 40
        plan.displays = [remote, display]; plan.viewport.width = 120
        plan.placements[0].fromX += 40; plan.placements[0].toX += 40; plan.placements[0].clip.width = 120
        plan.placements[0].cornerRadius = 6; plan.placements[0].fadeInSeconds = 4
        let transparent = try image([128, 0, 0, 128])
        let frame = PNPlayback.Frame(plan: plan, images: [plan.placements[0].asset.opaqueId: DecodedPhoto(image: transparent)], ambient: [])
        let layer = PNPlaybackLayer(frame: frame, display: display, elapsed: 2, opacity: 0.8)
        let old = try bitmap([layer], composited: false), new = try bitmap([layer], composited: true)
        for point in [CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 6), CGPoint(x: 20, y: 12), CGPoint(x: 34, y: 25), CGPoint(x: 60, y: 40)] {
            let i = (Int(point.y) * 80 + Int(point.x)) * 4
            for c in 0..<4 { #expect(abs(Int(old[i + c]) - Int(new[i + c])) < 4, "point=\(point), channel=\(c), old=\(old[i+c]), new=\(new[i+c])") }
        }
    }

    @Test func fullSizedFixturePhotoBoundariesMatchTheBitmapPath() async throws {
        func gradient(_ width: Int, _ height: Int, reverse: Bool = false) throws -> CGImage {
            let canvas = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            for y in stride(from: 0, to: height, by: 20) {
                let value = CGFloat(y) / CGFloat(height)
                canvas.setFillColor(CGColor(red: reverse ? 1 - value : value, green: 0.4, blue: reverse ? value : 1 - value, alpha: 1))
                canvas.fill(CGRect(x: 0, y: y, width: width, height: 20))
            }
            return try #require(canvas.makeImage())
        }
        let original = try fixture(), photo = try gradient(2400, 3600)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("dpw-compositor-boundaries", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        print("Boundary diagnostics: \(output.path)")
        for mode in ["gallery", "ambient", "zoom", "production"] {
            let inset = mode == "ambient" || mode == "production"
            var plan = original.frame.plan, display = original.display
            display.width = 1920; display.height = 1080
            plan.viewport = PNSize(width: 1920, height: 1080); plan.displays = [display]; plan.duration = 3600
            plan.placements = (0..<4).map { i in
                var p = original.frame.plan.placements[0]
                p.id = i; p.clip = PNRect(x: 0, y: 0, width: 1920, height: 1080)
                p.width = inset ? 432 : 480; p.height = inset ? 864 : 1080
                p.fromX = Double(i) * 480; p.toX = p.fromX
                p.fromY = inset ? 108 : 0; p.toY = p.fromY
                p.toScale = mode == "zoom" ? 1.25 : 1; p.centerX = 0.5; p.centerY = 0.5
                p.motionSeconds = 120; p.visibleUntil = 3600; p.cornerRadius = 8; p.ease = true
                return p
            }
            var backgrounds = try (mode == "ambient" ? [0, 120] : [0]).map { time in
                let image = try gradient(160, 90, reverse: time > 0)
                return PNPlayback.PNAmbientImage(frame: PNAmbient(at: Double(time), png: try #require(PNImageDecode.png(image)), displayId: nil),
                    image: NSImage(cgImage: image, size: CGSize(width: 160, height: 90)))
            }
            if mode == "production" {
                let bytes = try #require(PNImageDecode.png(photo))
                let tiny = try #require(PNImageDecode.decode(bytes, maximum: 128))
                let cards = plan.placements.map { p in AmbientCard(image: tiny.image,
                    frame: CGRect(x: p.fromX, y: p.fromY, width: p.width, height: p.height), opacity: 1, radius: p.cornerRadius) }
                let rendered = await AmbientProcessor().render(cards: cards, viewport: CGSize(width: 1920, height: 1080), at: 0, enhanceColors: false)
                let background = try #require(rendered), enhanced = try #require(AmbientColors.enhance(background.image))
                backgrounds = [PNPlayback.PNAmbientImage(frame: PNAmbient(at: 0, png: try #require(PNImageDecode.png(background.image)), displayId: nil),
                    image: NSImage(cgImage: enhanced.image, size: CGSize(width: enhanced.image.width, height: enhanced.image.height)))]
            }
            let frame = PNPlayback.Frame(plan: plan, images: [plan.placements[0].asset.opaqueId: DecodedPhoto(image: photo)], ambient: backgrounds)
            let layer = PNPlaybackLayer(frame: frame, display: display, elapsed: 10, opacity: 1), size = CGSize(width: 960, height: 540)
            let old = try bitmap([layer], composited: false, size: size), new = try bitmap([layer], composited: true, size: size)
            for (name, pixels) in [("bitmap", old), ("layers", new)] {
                let image = try #require(AmbientProcessor.image(pixels, width: 960, height: 540))
                try #require(PNImageDecode.png(image)).write(to: output.appendingPathComponent("\(mode)-\(name).png"))
            }
            var maximum = 0, changed = 0
            for i in stride(from: 0, to: old.count, by: 4) {
                let difference = (0..<4).map { abs(Int(old[i+$0]) - Int(new[i+$0])) }.max() ?? 0
                maximum = max(maximum, difference); if difference > 4 { changed += 1 }
            }
            print("Boundary difference \(mode): max=\(maximum), pixelsOver4=\(changed)/518400")
            #expect(maximum < 4, "mode=\(mode), maximum channel difference=\(maximum)")
        }
    }

    @Test func timelineEntryExitAndIndependentFadesStillUpdateRetainedLayers() throws {
        let original = try fixture()
        var plan = original.frame.plan
        plan.placements[0].visibleFrom = 2; plan.placements[0].visibleUntil = 8
        plan.placements[0].fadeInSeconds = 0; plan.placements[0].fadeOutSeconds = 2
        let frame = PNPlayback.Frame(plan: plan, images: original.frame.images, ambient: [])
        let layer = PNPlaybackLayer(frame: frame, display: original.display, elapsed: 1, opacity: 1)
        let renderer = PNLayerCompositor(); renderer.update([layer], size: size)
        let card = try #require(renderer.scenes.values.first).cards[0]
        #expect(card.clip.isHidden)
        renderer.update([at(layer, 2)], size: size)
        #expect(!card.clip.isHidden && card.clip.opacity == 1)
        renderer.update([at(layer, 7)], size: size)
        #expect(!card.clip.isHidden && card.clip.opacity == 0.5)
        renderer.update([at(layer, 8)], size: size)
        #expect(card.clip.isHidden && renderer.contentBuildCount == 1)
    }

    @Test func resumeResizeAndNewContentKeepOrReplaceOnlyTheRequiredScene() throws {
        let layer = try fixture(), renderer = PNLayerCompositor()
        renderer.update([layer], size: size)
        let scene = try #require(renderer.scenes.values.first)
        var resumed = layer.frame; resumed.paused += 10
        renderer.update([PNPlaybackLayer(frame: resumed, display: layer.display, elapsed: 0, opacity: 1)], size: CGSize(width: 40, height: 30))
        #expect(renderer.scenes.values.first === scene && renderer.contentBuildCount == 1)
        let next = try fixture()
        renderer.update([layer, at(next, 0, opacity: 0.5)], size: size)
        #expect(renderer.scenes.count == 2 && renderer.contentBuildCount == 2)
        renderer.update([next], size: size)
        #expect(renderer.scenes.count == 1 && renderer.contentBuildCount == 2)
        renderer.update([], size: size)
        #expect(renderer.scenes.isEmpty && renderer.root.sublayers?.isEmpty != false)
    }
}
