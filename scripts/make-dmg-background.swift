import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift make-dmg-background.swift output.png\n", stderr)
    exit(1)
}

let width = 760
let height = 560
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

func color(_ hex: UInt32) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1)
}

func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor) {
    fill.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func label(_ value: String, x: CGFloat, top: CGFloat, size: CGFloat,
           ink: NSColor, weight: NSFont.Weight = .regular) {
    let font = NSFont.systemFont(ofSize: size, weight: weight)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: ink
    ]
    let measured = (value as NSString).size(withAttributes: attributes)
    (value as NSString).draw(at: NSPoint(x: x, y: CGFloat(height) - top - measured.height),
                             withAttributes: attributes)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

color(0xF4F7F2).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
rounded(NSRect(x: 0, y: 0, width: width, height: 9), radius: 0, fill: color(0x346B57))

label("Hola · 言好", x: 36, top: 30, size: 28, ink: color(0x245442), weight: .semibold)
label("拖拽 Hola 到「应用程序」完成安装", x: 36, top: 78, size: 20,
      ink: color(0x24382F), weight: .medium)
label("Drag Hola to Applications to install", x: 36, top: 108, size: 15,
      ink: color(0x60766B))

let arrow = NSBezierPath()
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 323, y: 110))
arrow.line(to: NSPoint(x: 430, y: 110))
arrow.move(to: NSPoint(x: 418, y: 122))
arrow.line(to: NSPoint(x: 430, y: 110))
arrow.line(to: NSPoint(x: 418, y: 98))
color(0x5C977A).setStroke()
arrow.stroke()

rounded(NSRect(x: 26, y: 185, width: 708, height: 230), radius: 16,
        fill: color(0xE7EFE8))
label("首次打开 · First launch", x: 48, top: 159, size: 17,
      ink: color(0x245442), weight: .semibold)
label("从「应用程序」打开 Hola。如果 macOS 阻止打开，先关闭提示，再前往：",
      x: 48, top: 190, size: 14, ink: color(0x24382F))
label("Open Hola from Applications. If macOS blocks it, dismiss the alert and go to:",
      x: 48, top: 213, size: 12, ink: color(0x60766B))
label("macOS 13+   系统设置 → 隐私与安全性 → 安全性 → 仍要打开",
      x: 48, top: 247, size: 14, ink: color(0x24382F), weight: .medium)
label("macOS 12     系统偏好设置 → 安全性与隐私 → 通用 → 仍要打开",
      x: 48, top: 277, size: 14, ink: color(0x24382F), weight: .medium)
label("13+: System Settings → Privacy & Security → Security → Open Anyway",
      x: 48, top: 310, size: 11, ink: color(0x60766B))
label("12: System Preferences → Security & Privacy → General → Open Anyway",
      x: 48, top: 328, size: 11, ink: color(0x60766B))
label("请先确认下载来源为 Hola 官方 Releases。若看不到按钮，请先尝试打开一次。",
      x: 48, top: 347, size: 12, ink: color(0x60766B))

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fputs("Could not encode DMG background\n", stderr)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
