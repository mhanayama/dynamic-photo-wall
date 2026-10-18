import Foundation

nonisolated enum MirrorPolicy {
    static func isBelowHalf(imageWidth: Int, imageHeight: Int, group: CGSize) -> Bool {
        group.width >= group.height ? CGFloat(imageWidth) < group.width / 2 : CGFloat(imageHeight) < group.height / 2
    }
}
