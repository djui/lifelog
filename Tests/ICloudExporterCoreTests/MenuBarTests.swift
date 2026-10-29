import AppKit
import XCTest
@testable import ICloudExporterCore

final class MenuBarTests: XCTestCase {
    func testLaunchModeKeepsTheCLIForArgumentsAndTerminals() {
        XCTAssertEqual(LaunchMode.decide([], isTerminal: false, isAppBundle: true), .menuBar, "opened from Finder or at login")
        XCTAssertEqual(LaunchMode.decide(["-psn_0_12345"], isTerminal: false, isAppBundle: true), .menuBar, "older Launch Services argument")
        XCTAssertEqual(LaunchMode.decide(["app"], isTerminal: true, isAppBundle: false), .menuBar)
        XCTAssertEqual(LaunchMode.decide([], isTerminal: true, isAppBundle: true), .cli([]), "typed in Terminal: help")
        XCTAssertEqual(LaunchMode.decide([], isTerminal: false, isAppBundle: false), .cli([]), "swift run or a bare binary")
        XCTAssertEqual(LaunchMode.decide(["archive", "--output", "/tmp/a"], isTerminal: false, isAppBundle: true), .cli(["archive", "--output", "/tmp/a"]),
                       "launchd runs keep working")
        XCTAssertEqual(LaunchMode.decide(["app", "--output", "/tmp/a"], isTerminal: false, isAppBundle: true), .cli(["app", "--output", "/tmp/a"]))
    }

    func testMenuBarIconIsATemplateWithInk() throws {
        let image = MenuBarIcon.image()
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        var inked = 0
        for x in 0..<36 { for y in 0..<36 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { inked += 1 } }
        XCTAssertGreaterThan(inked, 60, "the glyph draws its outline")
        XCTAssertLessThan(inked, 36 * 36 / 2, "an outline, not a filled square")
    }
}
