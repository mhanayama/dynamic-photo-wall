import Foundation

struct WallSettings: Codable, Equatable, Sendable {
    var recursive = true
    var randomOrder = true
    var recentCount = 30
    var startOnLaunch = true

    var galleryEnabled = true
    var galleryScrollEnabled = true
    var verticalPanEnabled = true
    var horizontalPanEnabled = true
    var zoomEnabled = true

    var galleryWeight = 45
    var panWeight = 35
    var zoomWeight = 20
    var galleryMax = 5
    var panPixelsPerSecond = 120.0
    var maxPanUpscale = 4.0
    var panWidthFraction = 0.96
    var galleryScrollPixelsPerSecond = 40.0
    var glassBackground = true
    var zoomSeconds = 45.0
    var maxZoom = 1.08
    var fadeSeconds = 1.2
    var galleryMinSeconds = 30.0
    var galleryMaxSeconds = 60.0
    var backgroundHex = "#101116"
    var gap = 8.0
    var cornerRadius = 8.0
    var exifOverlay = false
    var cacheMegabytes = 256

    mutating func normalize() {
        recentCount = recentCount.clamped(to: 0...10_000)
        galleryWeight = galleryWeight.clamped(to: 0...1_000)
        panWeight = panWeight.clamped(to: 0...1_000)
        zoomWeight = zoomWeight.clamped(to: 0...1_000)
        galleryMax = galleryMax.clamped(to: 1...5)
        panPixelsPerSecond = panPixelsPerSecond.clamped(to: 5...500)
        maxPanUpscale = maxPanUpscale.clamped(to: 1...12)
        panWidthFraction = panWidthFraction.clamped(to: 0.3...1)
        galleryScrollPixelsPerSecond = galleryScrollPixelsPerSecond.clamped(to: 5...200)
        zoomSeconds = zoomSeconds.clamped(to: 10...600)
        maxZoom = maxZoom.clamped(to: 1...1.15)
        fadeSeconds = fadeSeconds.clamped(to: 0.2...10)
        galleryMinSeconds = galleryMinSeconds.clamped(to: 5...600)
        galleryMaxSeconds = galleryMaxSeconds.clamped(to: galleryMinSeconds...1_200)
        gap = gap.clamped(to: 0...200)
        cornerRadius = cornerRadius.clamped(to: 0...100)
        cacheMegabytes = cacheMegabytes.clamped(to: 64...1_024)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
