import Foundation

extension PNOptions {
    // Only native common playback values cross this allow-list. Local startup,
    // PhotoKit/bookmark permissions, paths and memory budgets stay on the peer.
    nonisolated static let allowed: Set<String> = ["randomOrder", "galleryEnabled", "galleryScrollEnabled", "verticalPanEnabled", "horizontalPanEnabled", "zoomEnabled",
        "galleryPerDisplay", "galleryScrollPerDisplay", "verticalPanPerDisplay", "horizontalPanPerDisplay", "zoomPerDisplay", "stopAtFace", "faceAwareFraming",
        "faceAwarePanDirection", "avoidFaceDisplayBoundaries", "glassBackground", "recentCount", "galleryMax", "galleryWeight", "panWeight", "zoomWeight",
        "panPixelsPerSecond", "galleryScrollPixelsPerSecond", "panWidthFraction", "maxPanUpscale", "zoomSeconds", "maxZoom", "fadeSeconds", "galleryMinSeconds", "galleryMaxSeconds", "gap", "cornerRadius", "background"]
    nonisolated init(_ settings: WallSettings) {
        let all = (try? PNWire.decode([String: PNJSON].self, PNWire.encode(settings))) ?? [:]
        var values = all.filter { Self.allowed.contains($0.key) }; values["background"] = .string(settings.backgroundHex)
        self.init(values: values)
    }
    nonisolated func applying(to settings: WallSettings = WallSettings()) throws -> WallSettings {
        try validate(); try PNWire.require(Set(values.keys).isSubset(of: Self.allowed), "Unknown playback option")
        var all = try PNWire.decode([String: PNJSON].self, PNWire.encode(settings))
        for (key, value) in values { all[key == "background" ? "backgroundHex" : key] = value }
        var result = try PNWire.decode(WallSettings.self, PNWire.encode(all)); result.normalize(); try result.validate(); return result
    }
}
