import AppKit
import QuartzCore
import SwiftUI

/// Retain decoded image contents in Core Animation. Playback ticks only change
/// geometry/opacity; background interpolation never repaints the photographs.
@MainActor final class PNLayerCompositor {
    struct Key: Hashable {
        let content: UUID
        let start: Double
        let display: PNDisplayKey
    }
    final class Card {
        let clip = CALayer()
        let image = CALayer()
        init(_ card: PNPlayback.PreparedCard) {
            clip.masksToBounds = true
            clip.isGeometryFlipped = true
            image.masksToBounds = true
            image.cornerRadius = card.placement.cornerRadius
            image.contents = card.image
            image.contentsGravity = .resize
            image.minificationFilter = .linear; image.magnificationFilter = .linear
            clip.addSublayer(image)
        }
    }
    final class Scene {
        let root = CALayer(), background = CALayer(), nextBackground = CALayer(), shade = CALayer()
        let content: PNPlayback.SurfaceContent
        let cards: [Card]
        let ambient: [CGImage?]
        let ambientOpaque: [Bool]
        init(_ layer: PNPlaybackLayer, content: PNPlayback.SurfaceContent) {
            self.content = content
            root.anchorPoint = .zero; root.position = .zero
            root.isGeometryFlipped = true; root.masksToBounds = true; root.allowsGroupOpacity = true
            root.backgroundColor = NSColor(Color(hex: layer.frame.plan.background)).cgColor
            for item in [background, nextBackground] {
                item.contentsGravity = .resize; item.minificationFilter = .linear; item.magnificationFilter = .linear
                root.addSublayer(item)
            }
            shade.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
            root.addSublayer(shade)
            cards = content.cards.map(Card.init)
            for card in cards { root.addSublayer(card.clip) }
            var decoded: [ObjectIdentifier: CGImage] = [:]
            ambient = content.ambient.map { item in
                let key = ObjectIdentifier(item.image)
                if let image = decoded[key] { return image }
                let image = item.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                decoded[key] = image; return image
            }
            var opacity: [ObjectIdentifier: Bool] = [:]
            ambientOpaque = ambient.map { image in
                guard let image else { return false }
                let key = ObjectIdentifier(image)
                if let opaque = opacity[key] { return opaque }
                let opaque = Self.isOpaque(image); opacity[key] = opaque; return opaque
            }
        }
        private static func isOpaque(_ image: CGImage) -> Bool {
            switch image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: return true
            default: break
            }
            guard let canvas = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let bytes = canvas.data?.assumingMemoryBound(to: UInt8.self) else { return false }
            for y in 0..<image.height {
                for x in 0..<image.width where bytes[y * canvas.bytesPerRow + x * 4 + 3] != 255 { return false }
            }
            return true
        }
    }
    let root = CALayer()
    private(set) var scenes: [Key: Scene] = [:]
    private var order: [Key] = []
    private(set) var contentBuildCount = 0
    private(set) var mutationCount = 0

    init() {
        // NSView's backing layer already has flipped geometry. This container
        // inherits it; scene and clip layers establish their top-left children.
        root.masksToBounds = true; root.backgroundColor = NSColor.black.cgColor
    }

    func update(_ layers: [PNPlaybackLayer], size: CGSize) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        setFrame(root, CGRect(origin: .zero, size: size))
        var keys: [Key] = []
        for layer in layers where layer.opacity > 0 {
            guard let content = layer.content else { continue }
            let key = Key(content: layer.frame.renderID, start: layer.frame.start, display: layer.display.key)
            let scene: Scene
            if let existing = scenes[key] { scene = existing }
            else { scene = Scene(layer, content: content); scenes[key] = scene; contentBuildCount += 1 }
            keys.append(key)
            let displaySize = CGSize(width: layer.display.width, height: layer.display.height)
            let bounds = CGRect(origin: .zero, size: displaySize)
            if scene.root.bounds != bounds { scene.root.bounds = bounds; mutationCount += 1 }
            let transform = CATransform3DMakeScale(size.width / displaySize.width, size.height / displaySize.height, 1)
            if !CATransform3DEqualToTransform(scene.root.transform, transform) { scene.root.transform = transform; mutationCount += 1 }
            setOpacity(scene.root, layer.opacity)
            updateBackground(scene, layer: layer, bounds: bounds)
            for (prepared, card) in zip(content.cards, scene.cards) {
                let p = prepared.placement, value = layer.evaluate(p)
                let hidden = value.opacity <= 0
                if card.clip.isHidden != hidden { card.clip.isHidden = hidden; mutationCount += 1 }
                guard !hidden else { continue }
                let crop = content.crop
                setFrame(card.clip, CGRect(x: p.clip.x - crop.minX, y: p.clip.y - crop.minY, width: p.clip.width, height: p.clip.height))
                setOpacity(card.clip, value.opacity)
                setFrame(card.image, CGRect(x: value.x - p.width * (value.scale - 1) * p.centerX - p.clip.x,
                    y: value.y - p.height * (value.scale - 1) * p.centerY - p.clip.y,
                    width: p.width * value.scale, height: p.height * value.scale))
            }
        }
        let held = Set(keys)
        for key in scenes.keys.filter({ !held.contains($0) }) { scenes.removeValue(forKey: key)?.root.removeFromSuperlayer() }
        if order != keys { root.sublayers = keys.compactMap { scenes[$0]?.root }; order = keys; mutationCount += 1 }
    }

    private func updateBackground(_ scene: Scene, layer: PNPlaybackLayer, bounds: CGRect) {
        let frames = scene.content.ambient
        guard !frames.isEmpty else {
            if !scene.shade.isHidden { scene.shade.isHidden = true; mutationCount += 1 }
            return
        }
        let index = frames.lastIndex(where: { $0.frame.at <= layer.elapsed }) ?? 0
        let a = frames[index]
        let area = a.frame.displayId == nil
            ? CGRect(x: -scene.content.crop.minX, y: -scene.content.crop.minY, width: layer.frame.plan.viewport.width, height: layer.frame.plan.viewport.height)
            : bounds
        setFrame(scene.background, area); setFrame(scene.nextBackground, area); setFrame(scene.shade, bounds)
        setContents(scene.background, scene.ambient[index])
        var amount = 0.0
        if let next = frames.indices.first(where: { frames[$0].frame.at > layer.elapsed }) {
            setContents(scene.nextBackground, scene.ambient[next])
            // Equal opaque samples need no animation. Equal translucent samples
            // still change under source-over and must preserve the wire blend.
            if scene.ambient[index] !== scene.ambient[next] || !scene.ambientOpaque[index] {
                amount = min(1, max(0, (layer.elapsed - a.frame.at) / max(0.001, frames[next].frame.at - a.frame.at)))
            }
        }
        setOpacity(scene.nextBackground, amount)
    }

    private func setFrame(_ layer: CALayer, _ frame: CGRect) {
        if layer.frame != frame { layer.frame = frame; mutationCount += 1 }
    }
    private func setOpacity(_ layer: CALayer, _ value: Double) {
        let value = Float(value)
        if layer.opacity != value { layer.opacity = value; mutationCount += 1 }
    }
    private func setContents(_ layer: CALayer, _ image: CGImage?) {
        let previous = layer.contents as AnyObject?
        if previous !== image { layer.contents = image; mutationCount += 1 }
    }
}
