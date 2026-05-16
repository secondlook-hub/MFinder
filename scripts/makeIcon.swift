#!/usr/bin/env swift
// Generates AppIcon.iconset (PNGs at 10 sizes) + AppIcon.icns
// Renders a Windows-Explorer-style yellow folder with a blue document accent.

import AppKit
import Foundation

// MARK: - Drawing

func drawIcon(into image: NSImage) {
    image.lockFocus()
    defer { image.unlockFocus() }

    let W: CGFloat = image.size.width
    let H: CGFloat = image.size.height

    // Colors
    let backYellow   = NSColor(red: 0.92, green: 0.66, blue: 0.14, alpha: 1.0)   // #EBA823
    let frontYellow  = NSColor(red: 1.00, green: 0.80, blue: 0.27, alpha: 1.0)   // #FFCC45
    let frontShade   = NSColor(red: 1.00, green: 0.73, blue: 0.18, alpha: 1.0)   // #FFBA2E
    let docWhite     = NSColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1.0)
    let docShadow    = NSColor(red: 0.60, green: 0.60, blue: 0.60, alpha: 0.35)
    let blueStripe   = NSColor(red: 0.13, green: 0.59, blue: 0.95, alpha: 1.0)   // #2196F3
    let blueStripeDk = NSColor(red: 0.05, green: 0.40, blue: 0.78, alpha: 1.0)
    let folderShadow = NSColor.black.withAlphaComponent(0.18)

    // Geometry — designed at 1024 baseline, scales with W.
    let pad: CGFloat = W * 0.08
    let backTop:    CGFloat = H - pad * 0.5
    let frontTop:   CGFloat = H * 0.78
    let folderBot:  CGFloat = pad * 1.4
    let folderLeft: CGFloat = pad
    let folderRight: CGFloat = W - pad
    let cornerRadius: CGFloat = W * 0.04

    // ── Drop shadow under the whole folder
    let shadowRect = NSRect(x: folderLeft + W * 0.02,
                            y: folderBot - W * 0.02,
                            width: folderRight - folderLeft - W * 0.04,
                            height: W * 0.05)
    folderShadow.setFill()
    NSBezierPath(roundedRect: shadowRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

    // ── Back panel (the part that shows above the front) — tab on the left
    let tabLeft: CGFloat   = folderLeft + W * 0.04
    let tabRight: CGFloat  = folderLeft + W * 0.34
    let tabSlant: CGFloat  = W * 0.05

    let back = NSBezierPath()
    back.move(to: NSPoint(x: tabLeft, y: backTop - cornerRadius))
    back.appendArc(withCenter: NSPoint(x: tabLeft + cornerRadius, y: backTop - cornerRadius),
                   radius: cornerRadius, startAngle: 180, endAngle: 90, clockwise: true)
    back.line(to: NSPoint(x: tabRight - cornerRadius, y: backTop))
    back.appendArc(withCenter: NSPoint(x: tabRight - cornerRadius, y: backTop - cornerRadius),
                   radius: cornerRadius, startAngle: 90, endAngle: 0, clockwise: true)
    back.line(to: NSPoint(x: tabRight + tabSlant, y: frontTop + W * 0.04))
    back.line(to: NSPoint(x: folderRight - cornerRadius, y: frontTop + W * 0.04))
    back.appendArc(withCenter: NSPoint(x: folderRight - cornerRadius, y: frontTop + W * 0.04 - cornerRadius),
                   radius: cornerRadius, startAngle: 90, endAngle: 0, clockwise: true)
    back.line(to: NSPoint(x: folderRight, y: folderBot + cornerRadius))
    back.appendArc(withCenter: NSPoint(x: folderRight - cornerRadius, y: folderBot + cornerRadius),
                   radius: cornerRadius, startAngle: 0, endAngle: 270, clockwise: true)
    back.line(to: NSPoint(x: folderLeft + cornerRadius, y: folderBot))
    back.appendArc(withCenter: NSPoint(x: folderLeft + cornerRadius, y: folderBot + cornerRadius),
                   radius: cornerRadius, startAngle: 270, endAngle: 180, clockwise: true)
    back.line(to: NSPoint(x: folderLeft, y: backTop - cornerRadius))
    back.appendArc(withCenter: NSPoint(x: folderLeft + cornerRadius, y: backTop - cornerRadius),
                   radius: cornerRadius, startAngle: 180, endAngle: 90, clockwise: true)
    back.close()
    backYellow.setFill()
    back.fill()

    // ── White document peeking out from inside the folder
    let docInset: CGFloat   = W * 0.14
    let docTop: CGFloat     = frontTop + W * 0.09
    let docHeight: CGFloat  = H * 0.32
    let docRect = NSRect(x: folderLeft + docInset,
                         y: docTop - docHeight,
                         width: folderRight - folderLeft - 2 * docInset,
                         height: docHeight)
    // Small drop-shadow for doc
    let docShadowRect = docRect.offsetBy(dx: W * 0.005, dy: -W * 0.008)
    docShadow.setFill()
    NSBezierPath(roundedRect: docShadowRect, xRadius: cornerRadius * 0.4, yRadius: cornerRadius * 0.4).fill()
    docWhite.setFill()
    NSBezierPath(roundedRect: docRect, xRadius: cornerRadius * 0.4, yRadius: cornerRadius * 0.4).fill()

    // Blue header stripe on the document
    let stripeHeight: CGFloat = docHeight * 0.32
    let stripeRect = NSRect(x: docRect.minX,
                            y: docRect.maxY - stripeHeight,
                            width: docRect.width,
                            height: stripeHeight)
    // Gradient blue (top dark, bottom light)
    let blueGradient = NSGradient(colors: [blueStripeDk, blueStripe])!
    blueGradient.draw(in: stripeRect, angle: -90)

    // Three subtle horizontal "text" lines below the blue header
    let lineColor = NSColor(red: 0.75, green: 0.78, blue: 0.82, alpha: 1.0)
    lineColor.setFill()
    let lineLeft   = docRect.minX + W * 0.025
    let lineRight  = docRect.maxX - W * 0.025
    var lineY      = stripeRect.minY - W * 0.04
    let lineSpacing: CGFloat = W * 0.035
    let lineHeight: CGFloat  = W * 0.012
    for w in [1.0, 0.7, 0.85] {
        let rect = NSRect(x: lineLeft, y: lineY,
                          width: (lineRight - lineLeft) * CGFloat(w),
                          height: lineHeight)
        NSBezierPath(roundedRect: rect, xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
        lineY -= lineSpacing
    }

    // ── Front face of the folder (sits in front of doc bottom half)
    let frontPath = NSBezierPath()
    frontPath.move(to: NSPoint(x: folderLeft, y: frontTop - cornerRadius))
    frontPath.line(to: NSPoint(x: folderLeft, y: folderBot + cornerRadius))
    frontPath.appendArc(withCenter: NSPoint(x: folderLeft + cornerRadius, y: folderBot + cornerRadius),
                        radius: cornerRadius, startAngle: 180, endAngle: 270, clockwise: false)
    frontPath.line(to: NSPoint(x: folderRight - cornerRadius, y: folderBot))
    frontPath.appendArc(withCenter: NSPoint(x: folderRight - cornerRadius, y: folderBot + cornerRadius),
                        radius: cornerRadius, startAngle: 270, endAngle: 0, clockwise: false)
    frontPath.line(to: NSPoint(x: folderRight, y: frontTop - cornerRadius))
    frontPath.appendArc(withCenter: NSPoint(x: folderRight - cornerRadius, y: frontTop - cornerRadius),
                        radius: cornerRadius, startAngle: 0, endAngle: 90, clockwise: false)
    frontPath.line(to: NSPoint(x: folderLeft + cornerRadius, y: frontTop))
    frontPath.appendArc(withCenter: NSPoint(x: folderLeft + cornerRadius, y: frontTop - cornerRadius),
                        radius: cornerRadius, startAngle: 90, endAngle: 180, clockwise: false)
    frontPath.close()
    let frontGradient = NSGradient(colors: [frontYellow, frontShade])!
    frontGradient.draw(in: frontPath, angle: -90)

    // Subtle highlight along the top edge of the front face
    let highlight = NSColor.white.withAlphaComponent(0.18)
    highlight.setFill()
    let highlightRect = NSRect(x: folderLeft + cornerRadius,
                               y: frontTop - W * 0.012,
                               width: folderRight - folderLeft - 2 * cornerRadius,
                               height: W * 0.012)
    NSBezierPath(rect: highlightRect).fill()
}

// MARK: - Export

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png",     16),
    ("icon_16x16@2x.png",  32),
    ("icon_32x32.png",     32),
    ("icon_32x32@2x.png",  64),
    ("icon_128x128.png",  128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",  256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",  512),
    ("icon_512x512@2x.png", 1024),
]

let cwd = FileManager.default.currentDirectoryPath
let iconsetDir = "\(cwd)/Resources/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconsetDir)
try FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

// Master image at 1024px
let master = NSImage(size: NSSize(width: 1024, height: 1024))
drawIcon(into: master)

for entry in sizes {
    let px = entry.px
    let scaled = NSImage(size: NSSize(width: px, height: px))
    scaled.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
                from: NSRect(x: 0, y: 0, width: 1024, height: 1024),
                operation: .copy, fraction: 1.0)
    scaled.unlockFocus()
    guard let tiff = scaled.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fputs("Failed to encode \(entry.name)\n", stderr)
        exit(1)
    }
    let url = URL(fileURLWithPath: "\(iconsetDir)/\(entry.name)")
    try png.write(to: url)
    print("  wrote \(entry.name) (\(px)px)")
}

print("Iconset written to \(iconsetDir)")
print("Run: iconutil -c icns '\(iconsetDir)' -o '\(cwd)/Resources/AppIcon.icns'")
