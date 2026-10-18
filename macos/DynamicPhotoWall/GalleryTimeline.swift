import Foundation

nonisolated enum GalleryTimeline {
    struct Surface { var assets: [PhotoAsset]; var viewport: CGSize; var displays: [CGRect] }
    struct Segment { var surface: Int; var asset: PhotoAsset; var from: CGRect; var to: CGRect; var at: Double; var until: Double; var motion: Double; var fadeIn: Double; var fadeOut: Double }
    private struct Track { var asset: PhotoAsset; var from: CGRect; var to: CGRect; var at: Double; var fadeIn: Double }
    static func build(_ surfaces: [Surface], duration: Double, settings: WallSettings, replacement: ([PhotoAsset]) -> PhotoAsset?,
                      random: () -> Double = { Double.random(in: 0..<1) }, candidates: [PhotoAsset] = []) -> [Segment] {
        var result: [Segment] = []
        let rotation = GalleryRotation()
        var state = surfaces.map { s in FixedGalleryLayout.arrange(s.assets, viewport: s.viewport, gap: settings.gap, displays: s.displays)
            .map { Track(asset: s.assets[$0.index], from: $0.frame, to: $0.frame, at: 0, fadeIn: 0) } }
        func interval() -> Double { settings.galleryMinSeconds + random() * (settings.galleryMaxSeconds - settings.galleryMinSeconds) }
        func end(_ surface: Int, _ t: Track, until: Double, fadeOut: Double) {
            result.append(Segment(surface: surface, asset: t.asset, from: t.from, to: t.to, at: t.at, until: until,
                motion: t.at == 0 ? 0.1 : max(0.1, settings.fadeSeconds), fadeIn: t.fadeIn, fadeOut: fadeOut))
        }
        var at = interval()
        while at + settings.fadeSeconds < duration {
            defer { at += settings.fadeSeconds + interval() }
            if result.count + state.reduce(0, { $0 + $1.count }) * 2 > 1000 { break }
            let slots = state.enumerated().flatMap { s, tracks in tracks.indices.map { (surface: s, index: $0) } }
            guard !slots.isEmpty else { break }
            let active = state.flatMap { $0.map(\.asset) }
            let eligible = rotation.eligible(active)
            let choices = slots.filter { eligible.contains(state[$0.surface][$0.index].asset.url) }
            let selected = choices[min(choices.count - 1, Int(random() * Double(choices.count)))], old = state[selected.surface], surface = surfaces[selected.surface]
            let additions = old.count < settings.galleryMax ? candidates.filter { photo in
                !active.contains { $0.url == photo.url } && FixedGalleryLayout.update(old.map(\.asset), incoming: photo,
                    viewport: surface.viewport, gap: settings.gap, displays: surface.displays, replacement: -1, maximum: settings.galleryMax)?.isAddition == true
            } : []
            let excluded = additions.isEmpty ? active : active + candidates.filter { p in !additions.contains { $0.url == p.url } }
            guard let photo = replacement(excluded), !active.contains(where: { $0.url == photo.url }),
                  let change = FixedGalleryLayout.update(old.map(\.asset), incoming: photo, viewport: surface.viewport,
                    gap: settings.gap, displays: surface.displays, replacement: selected.index, maximum: settings.galleryMax) else { continue }
            let proposed = change.assets, arranged = change.items, incoming = change.incomingIndex
            func original(_ index: Int) -> Int { change.isAddition && index > incoming ? index - 1 : index }
            let survivors = Set(arranged.filter { $0.index != incoming }.map { original($0.index) })
            for i in old.indices { end(selected.surface, old[i], until: survivors.contains(i) ? at : at + settings.fadeSeconds, fadeOut: survivors.contains(i) ? 0 : settings.fadeSeconds) }
            state[selected.surface] = arranged.map { item in Track(asset: proposed[item.index], from: item.index == incoming ? item.frame : old[original(item.index)].to,
                to: item.frame, at: at, fadeIn: item.index == incoming ? settings.fadeSeconds : 0) }
            rotation.inserted(photo)
        }
        for i in state.indices { for track in state[i] { end(i, track, until: duration, fadeOut: 0) } }
        return result
    }
}
