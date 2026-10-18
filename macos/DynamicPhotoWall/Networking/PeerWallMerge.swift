import Foundation

nonisolated enum PNWallMerge {
    static func merge(current: PNSnapshot, previous: PNSnapshot) throws -> PNSnapshot {
        var next = current; next.revision += 1
        for var group in previous.groups where !current.groups.contains(where: { $0.id == group.id }) {
            if current.groups.contains(where: { $0.name == group.name }) { group.name = String(group.name.prefix(110)) + " (" + String(group.id.pnHex.prefix(8)) + ")" }
            next.groups.append(group)
        }
        next.displays = previous.displays.map { d in
            var d = d; d.name = current.displays.first(where: { $0.key == d.key })?.name ?? d.name; return d
        } + current.displays.filter { d in !previous.displays.contains { $0.key == d.key } }
        next.sources += previous.sources.filter { s in !current.sources.contains { $0.providerId == s.providerId } }
        next.appliedRequests = Array(unique(current.appliedRequests + previous.appliedRequests).suffix(1024))
        next.mergedWalls = Array(unique(current.mergedWalls + previous.mergedWalls + [previous.wallId]).filter { $0 != current.wallId }.suffix(1024))
        try next.validate(); return next
    }
    private static func unique(_ ids: [UUID]) -> [UUID] { var seen: Set<UUID> = []; return ids.filter { seen.insert($0).inserted } }
}
