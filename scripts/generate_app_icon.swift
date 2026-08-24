import Foundation
import AppKit

// Generates macOS AppIcon.icns with Material Symbols diversity_2 concept

func drawAppIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let margin = size * 0.08
    let squircleRect = rect.insetBy(dx: margin, dy: margin)
    let cornerRadius = size * 0.22

    // Squircle background with gradient
    let path = CGPath(roundedRect: squircleRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    // Background Gradient: Deep Slate Indigo to Dark Purple
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        NSColor(red: 0.12, green: 0.14, blue: 0.28, alpha: 1.0).cgColor,
        NSColor(red: 0.22, green: 0.18, blue: 0.42, alpha: 1.0).cgColor,
        NSColor(red: 0.10, green: 0.08, blue: 0.22, alpha: 1.0).cgColor
    ] as CFArray
    let locations: [CGFloat] = [0.0, 0.6, 1.0]

    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: size * 0.2, y: size * 0.9), end: CGPoint(x: size * 0.8, y: size * 0.1), options: [])
    }

    // Subtle ambient glow
    ctx.setBlendMode(.screen)
    let glowColors = [
        NSColor(red: 0.38, green: 0.45, blue: 0.98, alpha: 0.35).cgColor,
        NSColor(red: 0.38, green: 0.45, blue: 0.98, alpha: 0.0).cgColor
    ] as CFArray
    if let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(glowGrad, startCenter: CGPoint(x: size * 0.5, y: size * 0.6), startRadius: 0, endCenter: CGPoint(x: size * 0.5, y: size * 0.6), endRadius: size * 0.45, options: [])
    }

    ctx.setBlendMode(.normal)

    // Draw diversity_2 emblem: 3 connected agent figures (top, bottom-left, bottom-right)
    let cx = size * 0.5
    let cy = size * 0.5
    let scale = size / 100.0

    // Coordinates for 3 heads (radius 6.5)
    // Top head: (cx, cy + 18)
    // Bottom-Left head: (cx - 19, cy - 14)
    // Bottom-Right head: (cx + 19, cy - 14)
    let headRadius: CGFloat = 6.5 * scale

    let emblemColor = NSColor(red: 0.96, green: 0.97, blue: 1.0, alpha: 0.95)
    let accentCyan = NSColor(red: 0.40, green: 0.85, blue: 0.98, alpha: 0.95)
    let accentPurple = NSColor(red: 0.82, green: 0.60, blue: 1.0, alpha: 0.95)

    // Helper: draw circle
    func drawHead(center: CGPoint, color: NSColor) {
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - headRadius, y: center.y - headRadius, width: headRadius * 2, height: headRadius * 2))
    }

    let topCenter = CGPoint(x: cx, y: cy + 18 * scale)
    let leftCenter = CGPoint(x: cx - 18 * scale, y: cy - 13 * scale)
    let rightCenter = CGPoint(x: cx + 18 * scale, y: cy - 13 * scale)

    drawHead(center: topCenter, color: accentCyan)
    drawHead(center: leftCenter, color: emblemColor)
    drawHead(center: rightCenter, color: accentPurple)

    // Bodies & Connecting Links (Torso curves and collaborative bridge paths)
    let strokeWidth: CGFloat = 5.0 * scale
    ctx.setLineWidth(strokeWidth)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Top figure torso / arms
    let topTorso = CGMutablePath()
    topTorso.move(to: CGPoint(x: cx - 12 * scale, y: cy + 3 * scale))
    topTorso.addQuadCurve(to: CGPoint(x: cx + 12 * scale, y: cy + 3 * scale), control: CGPoint(x: cx, y: cy + 9 * scale))
    ctx.addPath(topTorso)
    ctx.setStrokeColor(accentCyan.cgColor)
    ctx.strokePath()

    // Left figure torso / arms
    let leftTorso = CGMutablePath()
    leftTorso.move(to: CGPoint(x: cx - 7 * scale, y: cy - 25 * scale))
    leftTorso.addQuadCurve(to: CGPoint(x: cx - 27 * scale, y: cy - 15 * scale), control: CGPoint(x: cx - 21 * scale, y: cy - 26 * scale))
    ctx.addPath(leftTorso)
    ctx.setStrokeColor(emblemColor.cgColor)
    ctx.strokePath()

    // Right figure torso / arms
    let rightTorso = CGMutablePath()
    rightTorso.move(to: CGPoint(x: cx + 27 * scale, y: cy - 15 * scale))
    rightTorso.addQuadCurve(to: CGPoint(x: cx + 7 * scale, y: cy - 25 * scale), control: CGPoint(x: cx + 21 * scale, y: cy - 26 * scale))
    ctx.addPath(rightTorso)
    ctx.setStrokeColor(accentPurple.cgColor)
    ctx.strokePath()

    // Connecting Collaboration Bridge Ring (linking all 3 agents together)
    let bridgePath = CGMutablePath()
    // Top-left link
    bridgePath.move(to: CGPoint(x: cx - 12 * scale, y: cy + 3 * scale))
    bridgePath.addQuadCurve(to: CGPoint(x: cx - 19 * scale, y: cy - 3 * scale), control: CGPoint(x: cx - 22 * scale, y: cy + 4 * scale))

    // Top-right link
    bridgePath.move(to: CGPoint(x: cx + 12 * scale, y: cy + 3 * scale))
    bridgePath.addQuadCurve(to: CGPoint(x: cx + 19 * scale, y: cy - 3 * scale), control: CGPoint(x: cx + 22 * scale, y: cy + 4 * scale))

    // Bottom link
    bridgePath.move(to: CGPoint(x: cx - 7 * scale, y: cy - 25 * scale))
    bridgePath.addLine(to: CGPoint(x: cx + 7 * scale, y: cy - 25 * scale))

    ctx.addPath(bridgePath)
    ctx.setLineWidth(4.0 * scale)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
    ctx.strokePath()

    // Central Core Pulse Dot (AgentBridge coordination hub)
    let centerDotRadius: CGFloat = 3.5 * scale
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: cx - centerDotRadius, y: cy - 3 * scale - centerDotRadius, width: centerDotRadius * 2, height: centerDotRadius * 2))

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
let iconsetPath = "\(currentDir)/AppIcon.iconset"
let resourcesDir = "\(currentDir)/Resources"

try? fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)
try? fm.createDirectory(atPath: resourcesDir, withIntermediateDirectories: true)

let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, size) in sizes {
    let img = drawAppIcon(size: size)
    savePNG(image: img, path: "\(iconsetPath)/\(filename)")
}

print("✅ Saved all iconset PNGs to \(iconsetPath)")

// Compile to .icns using iconutil
let icnsPath = "\(resourcesDir)/AppIcon.icns"
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetPath, "-o", icnsPath]
try proc.run()
proc.waitUntilExit()

if proc.terminationStatus == 0 {
    print("✅ Successfully generated \(icnsPath)")
} else {
    print("❌ iconutil failed with status \(proc.terminationStatus)")
}
