import Foundation
import CoreGraphics

/// LAN adapter and serial owner of the legacy calculation session. A future
/// shared Core call belongs behind this boundary, never in display callbacks.
actor PNScenePlanWorker {
    private var planners: [UUID: WallSceneTimelinePlanner] = [:]
    private var configurations: [UUID: (session: UUID, revision: Int64)] = [:]

    func build(wall: PNSnapshot, group: UUID, prepared: PNPlanningCatalogSnapshot, previous: PNScene?) throws -> PNScene? {
        try Task.checkCancellation()
        let displays = wall.displays.filter { $0.selected && $0.unit == group }; guard !displays.isEmpty else { return nil }
        let settings = try wall.playback.applying()
        let left = displays.map(\.x).min()!, top = displays.map(\.y).min()!
        let width = displays.map { Double($0.x) + Double($0.width) }.max()! - Double(left)
        let height = displays.map { Double($0.y) + Double($0.height) }.max()! - Double(top)
        let nativeDisplays = displays.enumerated().map { index, d in WallDisplay(id: UInt32(index + 1), name: d.id, x: Double(d.x), y: Double(d.y), width: Double(d.width), height: Double(d.height), groupID: group.uuidString) }
        let nativeGroup = WallDisplayGroup(id: .named(group.uuidString), displays: nativeDisplays, bounds: CGRect(x: left, y: top, width: Int(width), height: Int(height)))
        let assets = prepared.assets, byURL = prepared.byURL, byID = prepared.byID
        let planner = planners[group] ?? WallSceneTimelinePlanner(); planners[group] = planner
        if configurations[group]?.session != wall.sessionId || configurations[group]?.revision != wall.revision {
            planner.resetModeHistory(); configurations[group] = (wall.sessionId, wall.revision)
        }
        let previousGallery = previous.flatMap { p -> PNScene? in
            guard p.groupId == group, p.sessionId == wall.sessionId, p.settingsRevision == wall.revision, p.displays == displays,
                  ["gallery", "galleryScroll"].contains(p.mode),
                  p.placements.filter({ $0.visibleUntil == p.duration }).allSatisfy({ byID[$0.asset.opaqueId] != nil }) else { return nil }
            return p
        }
        let nativePrevious = previousGallery.map { plan in
            WallSceneTimeline(mode: plan.mode == "gallery" ? .gallery : .horizontalGallery, duration: plan.duration,
                placements: plan.placements.compactMap { placement in
                    byID[placement.asset.opaqueId].map { PNSceneTimelineAdapter.native(placement, asset: $0,
                        displayID: placement.displayId.flatMap { id in nativeDisplays.first { $0.name == id }?.id }) }
                }, gallerySchedule: plan.gallerySchedule.map { schedule in
                    WallTimelineSchedule(nextChangeSeconds: schedule.nextChangeSeconds,
                        updatedURLs: Set(schedule.updatedAssets.compactMap { byID[$0]?.url }))
                }, continuing: false)
        }
        guard let timeline = try planner.build(assets: assets, settings: settings, group: nativeGroup, previous: nativePrevious) else { return nil }
        let placements = try timeline.placements.map { placement in
            guard let photo = byURL[placement.asset.url] else { throw PNError.invalid("Unknown planned photo") }
            return PNSceneTimelineAdapter.wire(placement, asset: photo.key,
                displayId: placement.displayID.flatMap { id in nativeDisplays.first { $0.id == id }?.name })
        }
        let mode = timeline.mode == .horizontalGallery ? "galleryScroll" : timeline.mode.rawValue
        var plan = PNScene(id: UUID(), groupId: group, sessionId: wall.sessionId, settingsRevision: wall.revision, mode: mode,
            viewport: PNSize(width: width, height: height), displays: displays, duration: timeline.duration,
            fadeSeconds: min(settings.fadeSeconds, timeline.duration), background: settings.backgroundHex, placements: placements, ambient: [])
        plan.continuationOf = timeline.continuing ? previousGallery?.id : nil
        plan.gallerySchedule = timeline.gallerySchedule.map {
            PNGallerySchedule(nextChangeSeconds: $0.nextChangeSeconds, updatedAssets: $0.updatedURLs.map(\.lastPathComponent))
        }
        try Task.checkCancellation()
        try plan.validate()
        return plan
    }
}

/// Mechanical conversion only. Keep all motion and fade fields intact; neither
/// side evaluates time, chooses photographs or owns native image resources.
nonisolated enum PNSceneTimelineAdapter {
    static func native(_ p: PNPlacement, asset: PhotoAsset, displayID: UInt32?) -> WallTimelinePlacement {
        WallTimelinePlacement(id: p.id, asset: asset, displayID: displayID,
            clip: CGRect(x: p.clip.x, y: p.clip.y, width: p.clip.width, height: p.clip.height),
            width: p.width, height: p.height, fromX: p.fromX, fromY: p.fromY, toX: p.toX, toY: p.toY,
            fromScale: p.fromScale, toScale: p.toScale, centerX: p.centerX, centerY: p.centerY,
            startSeconds: p.startSeconds, motionSeconds: p.motionSeconds, visibleFrom: p.visibleFrom, visibleUntil: p.visibleUntil,
            fadeSeconds: p.fadeSeconds, cornerRadius: p.cornerRadius, ease: p.ease, fadeInSeconds: p.fadeInSeconds, fadeOutSeconds: p.fadeOutSeconds)
    }
    static func wire(_ p: WallTimelinePlacement, asset: PNAssetKey, displayId: String?) -> PNPlacement {
        PNPlacement(id: p.id, asset: asset, displayId: displayId,
            clip: PNRect(x: p.clip.minX, y: p.clip.minY, width: p.clip.width, height: p.clip.height),
            width: p.width, height: p.height, fromX: p.fromX, fromY: p.fromY, toX: p.toX, toY: p.toY,
            fromScale: p.fromScale, toScale: p.toScale, centerX: p.centerX, centerY: p.centerY,
            startSeconds: p.startSeconds, motionSeconds: p.motionSeconds, visibleFrom: p.visibleFrom, visibleUntil: p.visibleUntil,
            fadeSeconds: p.fadeSeconds, cornerRadius: p.cornerRadius, ease: p.ease, fadeInSeconds: p.fadeInSeconds, fadeOutSeconds: p.fadeOutSeconds)
    }
}
