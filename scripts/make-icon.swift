// Draws the app icon and writes Support/AppIcon.icns: a cloud tucked into an archive tray with an amber label.
// Run from the repository root: swift scripts/make-icon.swift
// Shapes are in a 128-unit design grid; small sizes drop the rim and the label slot.
import AppKit
import Foundation

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func draw(pixels: Int) -> Data {
    let simple = pixels <= 32
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icons keep a margin: the tile spans 824 of 1024 units. Flip to y-down to match the design grid.
    let scale = CGFloat(pixels) / 1024
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)
    context.translateBy(x: 100, y: 100)
    context.scaleBy(x: 824 / 120, y: 824 / 120)
    context.translateBy(x: -4, y: -4)

    func gradient(_ top: UInt32, _ bottom: UInt32, in path: CGPath, from y0: CGFloat, to y1: CGFloat) {
        context.saveGState()
        context.addPath(path)
        context.clip()
        let gradient = CGGradient(colorsSpace: space, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [])
        context.restoreGState()
    }
    func fill(_ path: CGPath, _ hex: UInt32) {
        context.addPath(path)
        context.setFillColor(color(hex))
        context.fillPath()
    }
    func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
    }

    let tile = rounded(4, 4, 120, 120, 28)
    if !simple {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 2.5), blur: 6, color: CGColor(gray: 0, alpha: 0.35))
        fill(tile, 0x0C2329)
        context.restoreGState()
    }
    gradient(0x1B5A5C, 0x0C2329, in: tile, from: 4, to: 124)

    let grow: CGFloat = simple ? 1 : 0
    let cloud = CGMutablePath()
    cloud.addEllipse(in: CGRect(x: 36 - grow, y: 45 - grow, width: 26 + 2 * grow, height: 26 + 2 * grow))
    cloud.addEllipse(in: CGRect(x: 46 - grow, y: 28 - grow, width: 38 + 2 * grow, height: 38 + 2 * grow))
    cloud.addEllipse(in: CGRect(x: 69 - grow, y: 44 - grow, width: 26 + 2 * grow, height: 26 + 2 * grow))
    cloud.addRect(CGRect(x: 49, y: 52, width: 33, height: 19))
    fill(cloud, 0xEEF6F4)

    let tray = CGMutablePath()
    let top: CGFloat = simple ? 66 : 71
    tray.move(to: CGPoint(x: 28, y: top))
    tray.addLine(to: CGPoint(x: 100, y: top))
    tray.addLine(to: CGPoint(x: 100, y: 96))
    tray.addArc(tangent1End: CGPoint(x: 100, y: 105), tangent2End: CGPoint(x: 91, y: 105), radius: 9)
    tray.addLine(to: CGPoint(x: 37, y: 105))
    tray.addArc(tangent1End: CGPoint(x: 28, y: 105), tangent2End: CGPoint(x: 28, y: 96), radius: 9)
    tray.closeSubpath()
    if simple {
        fill(tray, 0x2FB3A0)
        fill(rounded(51, 79, 26, 12, 3), 0xF0A64A)
    } else {
        fill(rounded(24, 64, 80, 9, 4.5), 0x46CDB8)
        gradient(0x2FB3A0, 0x14786C, in: tray, from: 71, to: 105)
        fill(rounded(53, 80, 22, 10, 2.5), 0xF0A64A)
        fill(rounded(57, 84, 14, 2, 1), 0x7A4A10)
    }

    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    return image.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Support/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    try draw(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try draw(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
