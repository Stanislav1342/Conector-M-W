import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make_icon.swift <output.png>\n", stderr)
    exit(2)
}

let outputPath = CommandLine.arguments[1]
let size = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Failed to allocate bitmap\n", stderr)
    exit(1)
}
rep.size = NSSize(width: size, height: size)

guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
    fputs("Failed to create NSGraphicsContext\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
cg.setAllowsAntialiasing(true)
cg.setShouldAntialias(true)

// Clear background (transparent outside squircle)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()

let squircleRect = NSRect(x: 100, y: 100, width: 824, height: 824)
let squirclePath = NSBezierPath(roundedRect: squircleRect, xRadius: 185, yRadius: 185)

// Soft outer drop shadow for macOS icon depth
NSGraphicsContext.saveGraphicsState()
let outerShadow = NSShadow()
outerShadow.shadowOffset = NSSize(width: 0, height: -14)
outerShadow.shadowBlurRadius = 32
outerShadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.42)
outerShadow.set()
NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.16, alpha: 1).setFill()
squirclePath.fill()
NSGraphicsContext.restoreGraphicsState()

// Clip to squircle and fill diagonal navy-to-indigo gradient
NSGraphicsContext.saveGraphicsState()
squirclePath.addClip()

let bgColors = [
    NSColor(calibratedRed: 0.059, green: 0.090, blue: 0.165, alpha: 1.0), // #0F172A
    NSColor(calibratedRed: 0.102, green: 0.165, blue: 0.310, alpha: 1.0), // #1A2A4F
    NSColor(calibratedRed: 0.118, green: 0.227, blue: 0.541, alpha: 1.0), // #1E3A8A
]
if let bgGradient = NSGradient(colors: bgColors, atLocations: [0.0, 0.52, 1.0], colorSpace: .deviceRGB) {
    bgGradient.draw(in: squircleRect, angle: 42)
}

// Subtle ambient top glow
let glowColors = [
    NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.97, alpha: 0.20),
    NSColor(calibratedRed: 0.22, green: 0.74, blue: 0.97, alpha: 0.0),
]
if let glow = NSGradient(colors: glowColors) {
    glow.draw(fromCenter: NSPoint(x: 512, y: 840), radius: 0,
              toCenter: NSPoint(x: 512, y: 520), radius: 560, options: [.drawsBeforeStartingLocation])
}

// Subtle bottom ambient dark vignette
let vignetteColors = [
    NSColor(calibratedWhite: 0, alpha: 0.0),
    NSColor(calibratedWhite: 0, alpha: 0.22),
]
if let vignette = NSGradient(colors: vignetteColors) {
    vignette.draw(in: NSRect(x: 100, y: 100, width: 824, height: 240), angle: 270)
}
NSGraphicsContext.restoreGraphicsState()

// Crisp glass rim border
NSGraphicsContext.saveGraphicsState()
let borderPath = NSBezierPath(roundedRect: squircleRect.insetBy(dx: 1.5, dy: 1.5), xRadius: 183.5, yRadius: 183.5)
borderPath.lineWidth = 3
NSColor(calibratedWhite: 1.0, alpha: 0.18).setStroke()
borderPath.stroke()
NSGraphicsContext.restoreGraphicsState()

// Shared emblem shadow
let emblemShadow = NSShadow()
emblemShadow.shadowOffset = NSSize(width: 0, height: -6)
emblemShadow.shadowBlurRadius = 14
emblemShadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.38)

// 1) Left: Apple symbol via SF Symbols
guard let baseApple = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil) else {
    fputs("apple.logo SF Symbol unavailable\n", stderr)
    exit(1)
}
let symbolConfig = NSImage.SymbolConfiguration(pointSize: 165, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
guard let apple = baseApple.withSymbolConfiguration(symbolConfig) else {
    fputs("Failed to configure apple.logo symbol\n", stderr)
    exit(1)
}

let appleTargetH: CGFloat = 212
let aspect = apple.size.height > 0 ? apple.size.width / apple.size.height : 0.82
let appleTargetW = appleTargetH * aspect
let appleCenter = NSPoint(x: 270, y: 520)
let appleRect = NSRect(
    x: appleCenter.x - appleTargetW / 2,
    y: appleCenter.y - appleTargetH / 2,
    width: appleTargetW,
    height: appleTargetH
)
NSGraphicsContext.saveGraphicsState()
emblemShadow.set()
apple.draw(in: appleRect, from: .zero, operation: .sourceOver, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

// 2) Center: Crisp rounded '+' sign
NSGraphicsContext.saveGraphicsState()
emblemShadow.set()
let plusColor = NSColor(calibratedRed: 0.93, green: 0.97, blue: 1.0, alpha: 0.96)
plusColor.setFill()
let armLen: CGFloat = 96
let armThick: CGFloat = 22
let plusCenter = NSPoint(x: 512, y: 512)
let hBar = NSBezierPath(
    roundedRect: NSRect(x: plusCenter.x - armLen / 2, y: plusCenter.y - armThick / 2, width: armLen, height: armThick),
    xRadius: armThick / 2, yRadius: armThick / 2
)
let vBar = NSBezierPath(
    roundedRect: NSRect(x: plusCenter.x - armThick / 2, y: plusCenter.y - armLen / 2, width: armThick, height: armLen),
    xRadius: armThick / 2, yRadius: armThick / 2
)
hBar.fill()
vBar.fill()
NSGraphicsContext.restoreGraphicsState()

// 3) Right: Crisp Windows 11 4-pane logo
let winSize: CGFloat = 184
let winGap: CGFloat = 14
let paneSize = (winSize - winGap) / 2
let winOrigin = NSPoint(x: 754 - winSize / 2, y: 512 - winSize / 2)

let winCombined = NSBezierPath()
for row in 0..<2 {
    for col in 0..<2 {
        let px = winOrigin.x + CGFloat(col) * (paneSize + winGap)
        let py = winOrigin.y + CGFloat(row) * (paneSize + winGap)
        let pane = NSBezierPath(roundedRect: NSRect(x: px, y: py, width: paneSize, height: paneSize), xRadius: 10, yRadius: 10)
        winCombined.append(pane)
    }
}

NSGraphicsContext.saveGraphicsState()
emblemShadow.set()
// Draw solid base first so shadow applies cleanly to all 4 panes
NSColor(calibratedRed: 0.15, green: 0.68, blue: 0.96, alpha: 1.0).setFill()
winCombined.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
winCombined.addClip()
let winGradientColors = [
    NSColor(calibratedRed: 0.02, green: 0.56, blue: 0.89, alpha: 1.0), // bottom #058FE3
    NSColor(calibratedRed: 0.38, green: 0.85, blue: 0.99, alpha: 1.0), // top #61D9FC
]
if let winGradient = NSGradient(colors: winGradientColors) {
    winGradient.draw(in: NSRect(x: winOrigin.x, y: winOrigin.y, width: winSize, height: winSize), angle: 75)
}
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.restoreGraphicsState()

guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}
try pngData.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath) (\(size)x\(size))")
