import AppKit

@MainActor final class PNLayoutPreview {
    private let local: UUID
    private var windows: [NSWindow] = []
    private var pending: PNPreviewPlan?
    var visible: Bool { !windows.isEmpty }
    var changed: (() -> Void)?
    init(local: UUID) { self.local = local }
    func schedule(_ plan: PNPreviewPlan) { pending = plan }
    func update(_ now: Double) {
        guard let plan = pending, plan.effectiveAt <= now else { return }; pending = nil; close()
        if plan.enabled {
            for unit in Dictionary(grouping: plan.displays.filter(\.selected), by: \.unit).values {
                for display in unit where display.key.peerId == local {
                    guard let id = UInt32(display.key.displayId), let screen = ScreenDescriptor.availableScreens().first(where: { $0.id == id }) else { continue }
                    let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
                    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]; window.backgroundColor = .black
                    window.isOpaque = true; window.hasShadow = false; window.ignoresMouseEvents = true; window.isReleasedWhenClosed = false
                    let view = PNPatternView(); view.displays = unit; view.display = display; window.contentView = view
                    window.orderFrontRegardless(); windows.append(window)
                }
            }
        }
        changed?()
    }
    func close() { for window in windows { window.orderOut(nil); window.close() }; windows.removeAll() }
}
@MainActor private final class PNPatternView: NSView {
    var displays: [PNDisplay] = []; var display: PNDisplay?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let display, let context = NSGraphicsContext.current?.cgContext else { return }
        let left = displays.map(\.x).min()!, top = displays.map(\.y).min()!
        let width = (displays.map { $0.x + $0.width }.max() ?? 0) - left
        let height = (displays.map { $0.y + $0.height }.max() ?? 0) - top
        context.saveGState(); defer { context.restoreGState() }
        context.scaleBy(x: bounds.width / Double(display.width), y: bounds.height / Double(display.height))
        context.translateBy(x: -Double(display.x - left), y: -Double(display.y - top))
        context.setFillColor(NSColor.black.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(NSColor.gray.cgColor); context.setLineWidth(1)
        for x in stride(from: 0, through: width, by: 120) { context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: height)) }
        for y in stride(from: 0, through: height, by: 120) { context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: width, y: y)) }; context.strokePath()
        context.setStrokeColor(NSColor.cyan.cgColor); context.setLineWidth(3)
        context.move(to: .zero); context.addLine(to: CGPoint(x: width, y: height)); context.move(to: CGPoint(x: width, y: 0)); context.addLine(to: CGPoint(x: 0, y: height)); context.strokePath()
        let diameter = Double(min(width, height)) * 0.8
        context.strokeEllipse(in: CGRect(x: (Double(width) - diameter) / 2, y: (Double(height) - diameter) / 2, width: diameter, height: diameter))
        for (index, d) in displays.enumerated() {
            let rect = CGRect(x: d.x - left, y: d.y - top, width: d.width, height: d.height)
            context.setStrokeColor(NSColor.orange.cgColor); context.stroke(rect.insetBy(dx: 2, dy: 2))
            let text = "\(index + 1) · \(d.key.peerId.pnHex.prefix(8)) / \(d.key.displayId)\n\(d.width)×\(d.height) · (\(d.x), \(d.y))"
            (text as NSString).draw(at: CGPoint(x: rect.minX + 24, y: rect.minY + 24), withAttributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.white])
        }
    }
}
