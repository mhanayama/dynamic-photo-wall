import AppKit
import CoreGraphics

struct ScreenDescriptor: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    var visibleFrame: CGRect? = nil

    var resolutionDescription: String {
        "\(pixelWidth) × \(pixelHeight)"
    }

    static func availableScreens() -> [ScreenDescriptor] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            let displayID = CGDirectDisplayID(number.uint32Value)
            return ScreenDescriptor(
                id: displayID,
                name: screen.localizedName,
                frame: screen.frame,
                pixelWidth: CGDisplayPixelsWide(displayID),
                pixelHeight: CGDisplayPixelsHigh(displayID),
                visibleFrame: screen.visibleFrame
            )
        }
    }
}
