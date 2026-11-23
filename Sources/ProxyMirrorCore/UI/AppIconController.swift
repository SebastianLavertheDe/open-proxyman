import AppKit

/// Original ProxyMirror artwork drawn with AppKit. These variants share a
/// mirrored-arrow mark and do not bundle another application's icon assets.
@MainActor
enum AppIconController {
    static let styles = ["earth", "mars", "candy", "classic"]
    private static var images: [String: NSImage] = [:]

    static func apply(style: String) {
        NSApplication.shared.applicationIconImage = image(style: style)
    }

    static func image(style: String, size: CGFloat = 256) -> NSImage {
        let style = styles.contains(style) ? style : "earth"
        let size = max(16, min(1024, size))
        let key = "\(style)-\(size)"
        if let cached = images[key] { return cached }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let transform = NSAffineTransform()
        transform.scale(by: size / 256)
        transform.concat()
        draw(style: style)
        image.unlockFocus()
        image.isTemplate = false
        images[key] = image
        return image
    }

    private static func draw(style: String) {
        let top: NSColor
        let bottom: NSColor
        switch style {
        case "mars": top = NSColor(hex: 0xF9A45E); bottom = NSColor(hex: 0xA72F41)
        case "candy": top = NSColor(hex: 0xB477F8); bottom = NSColor(hex: 0x5A32AC)
        case "classic": top = NSColor(hex: 0x5A7894); bottom = NSColor(hex: 0x22394F)
        default: top = NSColor(hex: 0x47C0F7); bottom = NSColor(hex: 0x1552AE)
        }
        let tile = NSBezierPath(roundedRect: NSRect(x: 12, y: 12, width: 232, height: 232), xRadius: 52, yRadius: 52)
        NSGradient(starting: bottom, ending: top)?.draw(in: tile, angle: 90)
        NSColor.white.withAlphaComponent(0.35).setStroke()
        tile.lineWidth = 2
        tile.stroke()

        let sphere = NSBezierPath(ovalIn: NSRect(x: 43, y: 43, width: 170, height: 170))
        NSColor.black.withAlphaComponent(0.14).setFill()
        sphere.fill()
        NSColor.white.withAlphaComponent(0.48).setStroke()
        sphere.lineWidth = 3
        sphere.stroke()

        if style == "earth" || style == "classic" {
            drawGrid()
        } else if style == "mars" {
            drawCrater(x: 87, y: 170, radius: 15)
            drawCrater(x: 178, y: 150, radius: 9)
            drawCrater(x: 157, y: 80, radius: 18)
        } else {
            let speckles: [(CGFloat, CGFloat, CGFloat)] = [(74, 175, 8), (182, 174, 6), (171, 73, 9), (69, 91, 5)]
            for (x, y, radius) in speckles {
                NSColor(hex: 0xFFD6F6).withAlphaComponent(0.9).setFill()
                NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)).fill()
            }
        }
        // Two opposing routes meeting at a mirrored centre form the product mark.
        drawArrow(from: NSPoint(x: 70, y: 144), to: NSPoint(x: 181, y: 144), rightward: true)
        drawArrow(from: NSPoint(x: 186, y: 110), to: NSPoint(x: 75, y: 110), rightward: false)
    }

    private static func drawGrid() {
        NSColor.white.withAlphaComponent(0.22).setStroke()
        let meridian = NSBezierPath(ovalIn: NSRect(x: 86, y: 43, width: 84, height: 170))
        meridian.lineWidth = 2
        meridian.stroke()
        let equator = NSBezierPath(ovalIn: NSRect(x: 43, y: 91, width: 170, height: 74))
        equator.lineWidth = 2
        equator.stroke()
        let axis = NSBezierPath()
        axis.move(to: NSPoint(x: 128, y: 43)); axis.line(to: NSPoint(x: 128, y: 213))
        axis.lineWidth = 2
        axis.stroke()
    }

    private static func drawCrater(x: CGFloat, y: CGFloat, radius: CGFloat) {
        NSColor(hex: 0x7B3544).withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)).fill()
        NSColor.white.withAlphaComponent(0.22).setStroke()
        let rim = NSBezierPath(ovalIn: NSRect(x: x - radius + 2, y: y - radius + 3, width: radius * 2, height: radius * 2))
        rim.lineWidth = 2
        rim.stroke()
    }

    private static func drawArrow(from start: NSPoint, to end: NSPoint, rightward: Bool) {
        let path = NSBezierPath()
        path.move(to: start); path.line(to: end)
        let direction: CGFloat = rightward ? -1 : 1
        path.move(to: NSPoint(x: end.x + direction * 20, y: end.y + 18))
        path.line(to: end)
        path.line(to: NSPoint(x: end.x + direction * 20, y: end.y - 18))
        path.lineWidth = 12
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.white.setStroke()
        path.stroke()
    }
}
