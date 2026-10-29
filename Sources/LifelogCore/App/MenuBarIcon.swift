import AppKit

/// The menu bar glyph: a cloud tucked into an archive tray with a label slot, the app icon's shapes as an 18 pt
/// outline. It is a template image, so macOS tints it for light and dark menu bars.
public enum MenuBarIcon {
    public static let size = NSSize(width: 18, height: 18)

    /// Frames of the running spinner; the app steps through them while a run is in progress.
    public static let spinnerFrames = 8

    /// The glyph for a state: a spinner arc while running (turned by `frame`), a dot badge for attention, a dashed
    /// tray while paused, and an exclamation mark in the tray when the last run failed.
    public static func image(_ state: IconState = .idle, frame: Int = 0) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(1.4)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            if state == .running {
                let turn = CGFloat(frame % spinnerFrames) / CGFloat(spinnerFrames) * 2 * .pi
                context.addArc(center: CGPoint(x: 9, y: 5.4), radius: 3.2, startAngle: -.pi / 2 + turn, endAngle: .pi + turn, clockwise: false)
                context.strokePath()
            } else {
                // The cloud ends where the tray begins.
                context.saveGState()
                context.clip(to: CGRect(x: 0, y: 0, width: 18, height: 9.5))
                context.addPath(cloud)
                context.strokePath()
                context.restoreGState()
            }
            context.saveGState()
            if state == .paused { context.setLineDash(phase: 0, lengths: [2, 2]) }
            context.addPath(CGPath(roundedRect: CGRect(x: 2.5, y: 9.5, width: 13, height: 6.5), cornerWidth: 1.7, cornerHeight: 1.7, transform: nil))
            context.strokePath()
            context.restoreGState()
            if state == .failed {
                context.move(to: CGPoint(x: 9, y: 11.3))
                context.addLine(to: CGPoint(x: 9, y: 12.6))
                context.strokePath()
                context.fillEllipse(in: CGRect(x: 8.25, y: 13.6, width: 1.5, height: 1.5))
            } else {
                context.move(to: CGPoint(x: 7.4, y: 12.6))
                context.addLine(to: CGPoint(x: 10.6, y: 12.6))
                context.strokePath()
            }
            if state == .attention {
                // A clear ring keeps the badge apart from the cloud.
                context.setBlendMode(.clear)
                context.fillEllipse(in: CGRect(x: 10.8, y: 0.2, width: 7, height: 7))
                context.setBlendMode(.normal)
                context.fillEllipse(in: CGRect(x: 12, y: 1.4, width: 4.6, height: 4.6))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Lifelog, \(state.rawValue)"
        return image
    }

    /// Three bumps over a base, as one outline.
    static var cloud: CGPath {
        let parts = [CGPath(ellipseIn: CGRect(x: 3.1, y: 4.5, width: 5, height: 5), transform: nil),
                     CGPath(ellipseIn: CGRect(x: 5.9, y: 2.1, width: 6.6, height: 6.6), transform: nil),
                     CGPath(ellipseIn: CGRect(x: 10.2, y: 4.8, width: 4.8, height: 4.8), transform: nil),
                     CGPath(rect: CGRect(x: 5.6, y: 7, width: 7, height: 4), transform: nil)]
        return parts.dropFirst().reduce(parts[0]) { $0.union($1) }
    }
}
