import Foundation
import AppKit

// Generates macOS AppIcon.icns using exact Google Material Symbols diversity_2 vector geometry

let svgDiversity2White = """
<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48" viewBox="0 -960 960 960"><path fill="#FFFFFF" d="M341-67q-48 0-85-28.5T204-169q-16 26-39 40.5T110-114q-47 0-78-33T1-225q0-49 30.5-77.5T109-332q-18-20-28-46.5T71-432q0-38 19.5-71t55.5-53q5 13 12.5 28t15.5 26q-20 13-31.5 32T131-430q0 60 48.5 75.5T273-330l11 19q-12 35-19.5 57.5T257-212q0 34 25.5 59.5T342-127q41 0 67.5-34.5t43-82q16.5-47.5 25.5-96t15-75.5l58 16q-9 43-21 100t-34.5 108.5Q473-139 436.5-103T341-67ZM111-174q21 0 35.5-14.5T161-224q0-21-14.5-35.5T111-274q-21 0-35.5 14.5T61-224q0 21 14.5 35.5T111-174Zm300-190q-45-40-82-74.5T265.5-506q-26.5-33-41-65T210-639q0-60 42-102t102-42q9 0 17 .5t16 2.5q-9-17-13-29t-4-24q0-46 32-78t78-32q46 0 78 32t32 78q0 11-3.5 23.5T573-780q8-2 16-2.5t17-.5q57 0 96.5 36.5T748-656q-14-1-30-.5t-30 2.5q-5-30-27-49.5T606-723q-37 0-58.5 20.5T490-640h-21q-37-44-58.5-63.5T354-723q-36 0-60 24t-24 60q0 24 13 49t37 53.5q24 28.5 58 60t76 69.5l-43 43Zm69-419q21 0 35.5-14.5T530-833q0-21-14.5-35.5T480-883q-21 0-35.5 14.5T430-833q0 21 14.5 35.5T480-783ZM618-66q-22 0-43.5-7T533-94q8-12 16-27t13-28q14 11 28.5 16.5T620-127q35 0 59.5-25.5T704-212q0-20-8-42.5T677-311l11-19q46-8 94-23.5t48-75.5q0-44-32-65.5T727-516q-42 0-99.5 16T494-459l-15-58q76-25 137-42t111-17q64 0 113.5 38.5T890-430q0 27-10 53t-28 46q46 1 77 30t31 77q0 45-31 78t-78 33q-31 0-55-14.5T757-168q-16 45-53 73.5T618-66Zm233-107q20 0 34.5-14.5T900-223q0-20-15-35.5T850-274q-20 0-35 15t-15 35q0 20 15.5 35.5T851-173Zm-740-51Zm369-609Zm370 609Z"/></svg>
"""

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
    let cornerRadius = size * 0.224

    // Squircle background with gradient
    let path = CGPath(roundedRect: squircleRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    // Background Gradient: Deep Slate Indigo to Dark Purple
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        NSColor(red: 0.12, green: 0.14, blue: 0.32, alpha: 1.0).cgColor,
        NSColor(red: 0.24, green: 0.18, blue: 0.48, alpha: 1.0).cgColor,
        NSColor(red: 0.09, green: 0.07, blue: 0.24, alpha: 1.0).cgColor
    ] as CFArray
    let locations: [CGFloat] = [0.0, 0.5, 1.0]

    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: size * 0.2, y: size * 0.9), end: CGPoint(x: size * 0.8, y: size * 0.1), options: [])
    }

    // Draw exact Material Symbols diversity_2 vector
    if let data = svgDiversity2White.data(using: .utf8),
       let svgImage = NSImage(data: data) {
        let iconSize = size * 0.56
        let iconRect = CGRect(
            x: (size - iconSize) / 2.0,
            y: (size - iconSize) / 2.0,
            width: iconSize,
            height: iconSize
        )
        svgImage.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

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
    try? fm.removeItem(atPath: iconsetPath)
} else {
    print("❌ iconutil failed with status \(proc.terminationStatus)")
}
