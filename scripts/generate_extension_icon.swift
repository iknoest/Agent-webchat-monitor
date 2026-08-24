import Foundation
import AppKit

// Generates Chrome extension icons using Material Symbols ecg_heart concept

func drawECGHeartIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let margin = size * 0.05
    let drawingRect = rect.insetBy(dx: margin, dy: margin)

    let cx = size * 0.5
    let cy = size * 0.5
    let scale = size / 100.0

    // Heart Shape Path
    let heartPath = CGMutablePath()
    let topCenter = CGPoint(x: cx, y: cy + 18 * scale)
    let bottomTip = CGPoint(x: cx, y: cy - 35 * scale)

    heartPath.move(to: topCenter)
    // Left lobe
    heartPath.addCurve(
        to: CGPoint(x: cx - 40 * scale, y: cy + 12 * scale),
        control1: CGPoint(x: cx - 18 * scale, y: cy + 38 * scale),
        control2: CGPoint(x: cx - 40 * scale, y: cy + 32 * scale)
    )
    heartPath.addCurve(
        to: bottomTip,
        control1: CGPoint(x: cx - 40 * scale, y: cy - 8 * scale),
        control2: CGPoint(x: cx - 18 * scale, y: cy - 22 * scale)
    )
    // Right lobe
    heartPath.addCurve(
        to: CGPoint(x: cx + 40 * scale, y: cy + 12 * scale),
        control1: CGPoint(x: cx + 18 * scale, y: cy - 22 * scale),
        control2: CGPoint(x: cx + 40 * scale, y: cy - 8 * scale)
    )
    heartPath.addCurve(
        to: topCenter,
        control1: CGPoint(x: cx + 40 * scale, y: cy + 32 * scale),
        control2: CGPoint(x: cx + 18 * scale, y: cy + 38 * scale)
    )
    heartPath.closeSubpath()

    // Draw Heart Gradient (Vibrant Emerald / Teal Pulse gradient representing active health / ChatGPT monitoring)
    ctx.saveGState()
    ctx.addPath(heartPath)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let heartColors = [
        NSColor(red: 0.06, green: 0.72, blue: 0.55, alpha: 1.0).cgColor,
        NSColor(red: 0.04, green: 0.52, blue: 0.42, alpha: 1.0).cgColor
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: heartColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: cx, y: cy + 35 * scale), end: CGPoint(x: cx, y: cy - 35 * scale), options: [])
    }
    ctx.restoreGState()

    // Draw ECG Pulse line across the heart
    let ecgPath = CGMutablePath()
    let leftX = cx - 35 * scale
    let rightX = cx + 35 * scale
    let baselineY = cy + 2 * scale

    ecgPath.move(to: CGPoint(x: leftX, y: baselineY))
    ecgPath.addLine(to: CGPoint(x: cx - 18 * scale, y: baselineY))
    ecgPath.addLine(to: CGPoint(x: cx - 12 * scale, y: baselineY + 4 * scale))
    ecgPath.addLine(to: CGPoint(x: cx - 6 * scale, y: baselineY - 16 * scale)) // sharp dip
    ecgPath.addLine(to: CGPoint(x: cx + 4 * scale, y: baselineY + 22 * scale))  // sharp R-peak
    ecgPath.addLine(to: CGPoint(x: cx + 12 * scale, y: baselineY - 8 * scale))  // S-wave
    ecgPath.addLine(to: CGPoint(x: cx + 18 * scale, y: baselineY + 4 * scale))  // T-wave start
    ecgPath.addLine(to: CGPoint(x: cx + 22 * scale, y: baselineY))
    ecgPath.addLine(to: CGPoint(x: rightX, y: baselineY))

    let strokeWidth = max(1.5, 5.0 * scale)
    ctx.setLineWidth(strokeWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.addPath(ecgPath)
    ctx.strokePath()

    image.unlockFocus()
    return image
}

func savePNG(image: NSImage, path: String) {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to convert image to PNG for \(path)")
        return
    }
    try? pngData.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
let currentDir = fm.currentDirectoryPath
let extensionIconsDir = "\(currentDir)/adapters/chrome-extension/icons"

try? fm.createDirectory(atPath: extensionIconsDir, withIntermediateDirectories: true)

let extensionSizes: [(String, CGFloat)] = [
    ("icon16.png", 16),
    ("icon32.png", 32),
    ("icon48.png", 48),
    ("icon128.png", 128)
]

for (filename, size) in extensionSizes {
    let img = drawECGHeartIcon(size: size)
    savePNG(image: img, path: "\(extensionIconsDir)/\(filename)")
}

print("✅ Saved all Chrome extension icons to \(extensionIconsDir)")
