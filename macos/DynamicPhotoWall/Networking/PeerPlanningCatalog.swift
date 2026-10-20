import Foundation

nonisolated struct PNPlanningCatalogSnapshot: Sendable {
    let assets: [PhotoAsset]
    let byURL: [URL: PNPhoto]
    let byID: [String: PhotoAsset]
}

/// Identity hashing, URL creation and metadata conversion scale with the whole
/// library. Keep them off MainActor, and share one immutable snapshot across
/// groups and successive scenes until the ordered photo metadata changes.
actor PNPlanningCatalog {
    private var previous: [PNPhoto]?
    private var cached: PNPlanningCatalogSnapshot?

    func prepare(_ photos: [PNPhoto]) throws -> PNPlanningCatalogSnapshot {
        try Task.checkCancellation()
        if previous == photos, let cached { return cached }
        var assets: [PhotoAsset] = []
        var byURL: [URL: PNPhoto] = [:], byID: [String: PhotoAsset] = [:]
        assets.reserveCapacity(photos.count); byURL.reserveCapacity(photos.count); byID.reserveCapacity(photos.count)
        for photo in photos {
            try Task.checkCancellation()
            guard photo.faceMetadata.state != "pending" else { continue }
            let id = photo.key.opaqueId
            let asset = PhotoAsset(url: URL(string: "peer-cache://image/\(id)")!, pixelWidth: photo.pixelWidth,
                pixelHeight: photo.pixelHeight, fileSize: Int64(photo.byteLength), faces: photo.faceMetadata.faces.map {
                    FaceRegion(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                })
            assets.append(asset); byURL[asset.url] = photo; byID[id] = asset
        }
        try Task.checkCancellation()
        let snapshot = PNPlanningCatalogSnapshot(assets: assets, byURL: byURL, byID: byID)
        previous = photos; cached = snapshot
        return snapshot
    }
}
