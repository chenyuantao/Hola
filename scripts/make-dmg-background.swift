import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift make-dmg-background.swift output.png\n", stderr)
    exit(1)
}

let width = 640
let height = 420
// Finder uses the PNG's pixel dimensions as window coordinates. A 2x bitmap
// makes the artwork twice as large and crops its lower half in this window.
let scale = 1
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: width * scale,
    pixelsHigh: height * scale,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Could not create DMG background\n", stderr)
    exit(1)
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha)
}

// Coordinates below use Finder's top-left origin so they line up with
// icon_locations in dmg-settings.py.
func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
    NSPoint(x: x, y: CGFloat(height) - y)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

color(0xFCFCFC).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

// Navigation-style arrow between the app (lower left) and Applications
// (upper right), pointing toward the folder.
let center = (x: CGFloat(288), y: CGFloat(186))
let radius: CGFloat = 30
let angle = CGFloat(50) * .pi / 180
let outline: [(CGFloat, CGFloat)] = [(0, -1), (0.8, 0.85), (0, 0.42), (-0.8, 0.85)]
let arrow = NSBezierPath()
for (index, (dx, dy)) in outline.enumerated() {
    let rx = dx * cos(angle) - dy * sin(angle)
    let ry = dx * sin(angle) + dy * cos(angle)
    let vertex = point(center.x + rx * radius, center.y + ry * radius)
    index == 0 ? arrow.move(to: vertex) : arrow.line(to: vertex)
}
arrow.close()
arrow.lineJoinStyle = .round
arrow.lineWidth = 7

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = color(0x000000, alpha: 0.22)
shadow.shadowOffset = NSSize(width: 0, height: -4)
shadow.shadowBlurRadius = 12
shadow.set()
NSColor.white.setStroke()
arrow.stroke()
NSGraphicsContext.restoreGraphicsState()

NSColor.white.setStroke()
arrow.stroke()
NSGradient(starting: color(0x15212C), ending: color(0x4F7088))?
    .draw(in: arrow, angle: -40)

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode DMG background\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
