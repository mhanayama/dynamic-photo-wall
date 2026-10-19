import Foundation

nonisolated final class GalleryRotation {
    private var updated: Set<URL> = []
    init(previous: Set<URL> = []) { updated = previous }
    var updatedURLs: Set<URL> { updated }
    func eligible(_ active: [PhotoAsset]) -> Set<URL> {
        let urls = Set(active.map(\.url)); updated.formIntersection(urls)
        if urls.isSubset(of: updated) { updated.removeAll() }
        return urls.subtracting(updated)
    }
    func inserted(_ asset: PhotoAsset) { updated.insert(asset.url) }
}
