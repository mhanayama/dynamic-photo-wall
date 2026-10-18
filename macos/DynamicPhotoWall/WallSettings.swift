import Foundation

nonisolated struct WallSettings: Codable, Equatable, Sendable {
    var recursive = true
    var randomOrder = true
    var recentCount = 30
    var startOnLaunch = true
    var autoStart = false
    var stopAtFace = true
    var faceAwareFraming = true
    var faceAwarePanDirection = true
    var avoidFaceDisplayBoundaries = true
    var galleryPerDisplay = false
    var galleryScrollPerDisplay = false
    var verticalPanPerDisplay = false
    var horizontalPanPerDisplay = false
    var zoomPerDisplay = false


    var galleryEnabled = true
    var galleryScrollEnabled = true
    var verticalPanEnabled = true
    var horizontalPanEnabled = true
    var zoomEnabled = true

    var galleryWeight = 80
    var panWeight = 20
    var zoomWeight = 0
    var motionWeight: Int {
        get { ModeSelection.weights(gallery: galleryWeight, pan: panWeight, zoom: zoomWeight).motion }
        set { panWeight = newValue; zoomWeight = 0 }
    }
    var galleryMax = 5
    var panPixelsPerSecond = 120.0
    var maxPanUpscale = 4.0
    var panWidthFraction = 1.0
    var galleryScrollPixelsPerSecond = 40.0
    var glassBackground = true
    var zoomSeconds = 30.0
    var maxZoom = 1.25
    var fadeSeconds = 1.2
    var galleryMinSeconds = 5.0
    var galleryMaxSeconds = 10.0
    var backgroundHex = "#101116"
    var gap = 8.0
    var cornerRadius = 8.0
    var exifOverlay = false
    var cacheMegabytes = 256

    init() {}

    private enum CodingKeys: String, CodingKey {
        case faceAwarePanDirection, avoidFaceDisplayBoundaries, galleryPerDisplay, galleryScrollPerDisplay, verticalPanPerDisplay, horizontalPanPerDisplay, zoomPerDisplay, recursive, randomOrder, recentCount, startOnLaunch, autoStart, stopAtFace, faceAwareFraming, galleryEnabled, galleryScrollEnabled, verticalPanEnabled, horizontalPanEnabled, zoomEnabled, galleryWeight, panWeight, zoomWeight, galleryMax, panPixelsPerSecond, maxPanUpscale, panWidthFraction, galleryScrollPixelsPerSecond, glassBackground, zoomSeconds, maxZoom, fadeSeconds, galleryMinSeconds, galleryMaxSeconds, backgroundHex, gap, cornerRadius, exifOverlay, cacheMegabytes
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        recursive = try values.decodeIfPresent(Bool.self, forKey: .recursive) ?? recursive
        randomOrder = try values.decodeIfPresent(Bool.self, forKey: .randomOrder) ?? randomOrder
        recentCount = try values.decodeIfPresent(Int.self, forKey: .recentCount) ?? recentCount
        startOnLaunch = try values.decodeIfPresent(Bool.self, forKey: .startOnLaunch) ?? startOnLaunch
        autoStart = try values.decodeIfPresent(Bool.self, forKey: .autoStart) ?? autoStart
        stopAtFace = try values.decodeIfPresent(Bool.self, forKey: .stopAtFace) ?? stopAtFace
        faceAwareFraming = try values.decodeIfPresent(Bool.self, forKey: .faceAwareFraming) ?? faceAwareFraming
        galleryEnabled = try values.decodeIfPresent(Bool.self, forKey: .galleryEnabled) ?? galleryEnabled
        galleryScrollEnabled = try values.decodeIfPresent(Bool.self, forKey: .galleryScrollEnabled) ?? galleryScrollEnabled
        verticalPanEnabled = try values.decodeIfPresent(Bool.self, forKey: .verticalPanEnabled) ?? verticalPanEnabled
        horizontalPanEnabled = try values.decodeIfPresent(Bool.self, forKey: .horizontalPanEnabled) ?? horizontalPanEnabled
        zoomEnabled = try values.decodeIfPresent(Bool.self, forKey: .zoomEnabled) ?? zoomEnabled
        galleryWeight = try values.decodeIfPresent(Int.self, forKey: .galleryWeight) ?? galleryWeight
        panWeight = try values.decodeIfPresent(Int.self, forKey: .panWeight) ?? panWeight
        zoomWeight = try values.decodeIfPresent(Int.self, forKey: .zoomWeight) ?? zoomWeight
        galleryMax = try values.decodeIfPresent(Int.self, forKey: .galleryMax) ?? galleryMax
        panPixelsPerSecond = try values.decodeIfPresent(Double.self, forKey: .panPixelsPerSecond) ?? panPixelsPerSecond
        maxPanUpscale = try values.decodeIfPresent(Double.self, forKey: .maxPanUpscale) ?? maxPanUpscale
        panWidthFraction = try values.decodeIfPresent(Double.self, forKey: .panWidthFraction) ?? panWidthFraction
        galleryScrollPixelsPerSecond = try values.decodeIfPresent(Double.self, forKey: .galleryScrollPixelsPerSecond) ?? galleryScrollPixelsPerSecond
        glassBackground = try values.decodeIfPresent(Bool.self, forKey: .glassBackground) ?? glassBackground
        zoomSeconds = try values.decodeIfPresent(Double.self, forKey: .zoomSeconds) ?? zoomSeconds
        maxZoom = try values.decodeIfPresent(Double.self, forKey: .maxZoom) ?? maxZoom
        fadeSeconds = try values.decodeIfPresent(Double.self, forKey: .fadeSeconds) ?? fadeSeconds
        galleryMinSeconds = try values.decodeIfPresent(Double.self, forKey: .galleryMinSeconds) ?? galleryMinSeconds
        galleryMaxSeconds = try values.decodeIfPresent(Double.self, forKey: .galleryMaxSeconds) ?? galleryMaxSeconds
        backgroundHex = try values.decodeIfPresent(String.self, forKey: .backgroundHex) ?? backgroundHex
        gap = try values.decodeIfPresent(Double.self, forKey: .gap) ?? gap
        cornerRadius = try values.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? cornerRadius
        exifOverlay = try values.decodeIfPresent(Bool.self, forKey: .exifOverlay) ?? exifOverlay
        cacheMegabytes = try values.decodeIfPresent(Int.self, forKey: .cacheMegabytes) ?? cacheMegabytes
        faceAwarePanDirection = try values.decodeIfPresent(Bool.self, forKey: .faceAwarePanDirection) ?? faceAwarePanDirection
        avoidFaceDisplayBoundaries = try values.decodeIfPresent(Bool.self, forKey: .avoidFaceDisplayBoundaries) ?? avoidFaceDisplayBoundaries
        galleryPerDisplay = try values.decodeIfPresent(Bool.self, forKey: .galleryPerDisplay) ?? galleryPerDisplay
        galleryScrollPerDisplay = try values.decodeIfPresent(Bool.self, forKey: .galleryScrollPerDisplay) ?? galleryScrollPerDisplay
        verticalPanPerDisplay = try values.decodeIfPresent(Bool.self, forKey: .verticalPanPerDisplay) ?? verticalPanPerDisplay
        horizontalPanPerDisplay = try values.decodeIfPresent(Bool.self, forKey: .horizontalPanPerDisplay) ?? horizontalPanPerDisplay
        zoomPerDisplay = try values.decodeIfPresent(Bool.self, forKey: .zoomPerDisplay) ?? zoomPerDisplay
        normalize()
    }

    func perDisplay(_ mode: WallMode) -> Bool {
        switch mode {
        case .gallery: galleryPerDisplay
        case .horizontalGallery: galleryScrollPerDisplay
        case .verticalPan: verticalPanPerDisplay
        case .horizontalPan: horizontalPanPerDisplay
        case .zoom: zoomPerDisplay
        }
    }

    var hasEnabledMode: Bool {
        ((galleryEnabled || galleryScrollEnabled) && galleryWeight > 0)
            || ((verticalPanEnabled || horizontalPanEnabled || zoomEnabled) && motionWeight > 0)
    }

    func validate() throws {
        guard hasEnabledMode else { throw ValidationError.noEnabledMode }
        guard backgroundHex.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
            throw ValidationError.invalidBackground
        }
    }

    enum ValidationError: LocalizedError {
        case noEnabledMode, invalidBackground
        var errorDescription: String? {
            switch self {
            case .noEnabledMode: "少なくとも1つの表示モードを有効にして、ウェイトを1以上にしてください。"
            case .invalidBackground: "背景色を #RRGGBB の形式で入力してください。"
            }
        }
    }

    mutating func normalize() {
        recentCount = recentCount.clamped(to: 0...10_000)
        galleryWeight = galleryWeight.clamped(to: 0...1_000)
        panWeight = panWeight.clamped(to: 0...1_000)
        zoomWeight = zoomWeight.clamped(to: 0...1_000)
        let weights = ModeSelection.weights(gallery: galleryWeight, pan: panWeight, zoom: zoomWeight)
        galleryWeight = weights.gallery; motionWeight = min(1_000, weights.motion)
        galleryMax = galleryMax.clamped(to: 1...20)
        panPixelsPerSecond = (panPixelsPerSecond.isFinite ? panPixelsPerSecond : 120.0).clamped(to: 5...500)
        maxPanUpscale = (maxPanUpscale.isFinite ? maxPanUpscale : 4.0).clamped(to: 1...12)
        panWidthFraction = (panWidthFraction.isFinite ? panWidthFraction : 1.0).clamped(to: 0.3...1)
        galleryScrollPixelsPerSecond = (galleryScrollPixelsPerSecond.isFinite ? galleryScrollPixelsPerSecond : 40.0).clamped(to: 5...200)
        zoomSeconds = (zoomSeconds.isFinite ? zoomSeconds : 30.0).clamped(to: 10...600)
        maxZoom = (maxZoom.isFinite ? maxZoom : 1.25).clamped(to: 1...1.5)
        fadeSeconds = (fadeSeconds.isFinite ? fadeSeconds : 1.2).clamped(to: 0.2...10)
        if (galleryMinSeconds == 30 && galleryMaxSeconds == 60) || (galleryMinSeconds == 10 && galleryMaxSeconds == 30) { galleryMinSeconds = 5; galleryMaxSeconds = 10 }
        galleryMinSeconds = (galleryMinSeconds.isFinite ? galleryMinSeconds : 5.0).clamped(to: 5...600)
        galleryMaxSeconds = (galleryMaxSeconds.isFinite ? galleryMaxSeconds : 10.0).clamped(to: galleryMinSeconds...1_200)
        gap = (gap.isFinite ? gap : 8.0).clamped(to: 0...200)
        cornerRadius = (cornerRadius.isFinite ? cornerRadius : 8.0).clamped(to: 0...100)
        cacheMegabytes = cacheMegabytes.clamped(to: 64...1_024)
    }
}

private extension Comparable {
    nonisolated func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
