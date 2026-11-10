// Draws the ZipPick icon and writes a 1024px PNG.
// Usage: swift scripts/make-icon.swift <out.png>   (scripts/make-icon.sh wraps this into AppIcon.icns)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func gradient(_ top: UInt32, _ bottom: UInt32, in rect: CGRect) {
    let g = CGGradient(colorsSpace: space, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
}

// Base plate, in the standard macOS icon shape and margins.
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = rounded(plate, 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(platePath)
ctx.setFillColor(color(0x1B1E24))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
gradient(0x3B4250, 0x16181D, in: plate)

// Zipper: a fabric strip with interlocking teeth, running the full height on the left.
let zipX: CGFloat = 300
ctx.setFillColor(color(0x0E1014, 0.55))
ctx.fill(CGRect(x: zipX - 62, y: plate.minY, width: 124, height: plate.height))
let step: CGFloat = 46
var y = plate.minY - 10
var index = 0
while y < plate.maxY {
    let left = index % 2 == 0
    let tooth = CGRect(x: left ? zipX - 40 : zipX - 6, y: y, width: 46, height: 26)
    ctx.addPath(rounded(tooth, 9))
    ctx.setFillColor(color(left ? 0xD5DAE2 : 0xAEB5C0))
    ctx.fillPath()
    y += step / 2
    index += 1
}

// Zipper pull.
let slider = CGRect(x: zipX - 66, y: 690, width: 132, height: 104)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: color(0x000000, 0.5))
ctx.addPath(rounded(slider, 30))
ctx.setFillColor(color(0xE9EDF2))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(rounded(slider, 30))
ctx.clip()
gradient(0xFFFFFF, 0xB9C0CB, in: slider)
ctx.restoreGState()
let tab = CGRect(x: zipX - 34, y: 530, width: 68, height: 190)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 14, color: color(0x000000, 0.45))
ctx.addPath(rounded(tab, 30))
ctx.setFillColor(color(0xD9DEE6))
ctx.fillPath()
ctx.restoreGState()
ctx.addPath(rounded(CGRect(x: zipX - 14, y: 556, width: 28, height: 72), 14))
ctx.setFillColor(color(0x22262E))
ctx.fillPath()

// Three rows: two picked, one left behind.
let rows: [(y: CGFloat, picked: Bool, barEnd: CGFloat)] = [(672, true, 846), (512, true, 786), (352, false, 822)]
for row in rows {
    let box = CGRect(x: 436, y: row.y - 58, width: 116, height: 116)
    if row.picked {
        ctx.saveGState()
        ctx.addPath(rounded(box, 32))
        ctx.clip()
        gradient(0x4EE07A, 0x1FB455, in: box)
        ctx.restoreGState()
        ctx.setStrokeColor(color(0xFFFFFF))
        ctx.setLineWidth(22)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: box.minX + 28, y: box.midY - 2))
        ctx.addLine(to: CGPoint(x: box.minX + 50, y: box.midY - 24))
        ctx.addLine(to: CGPoint(x: box.minX + 88, y: box.midY + 24))
        ctx.strokePath()
    } else {
        ctx.addPath(rounded(box.insetBy(dx: 7, dy: 7), 26))
        ctx.setStrokeColor(color(0xFFFFFF, 0.32))
        ctx.setLineWidth(14)
        ctx.strokePath()
    }
    let bar = CGRect(x: 592, y: row.y - 23, width: row.barEnd - 592, height: 46)
    ctx.addPath(rounded(bar, 23))
    ctx.setFillColor(color(0xFFFFFF, row.picked ? 0.94 : 0.28))
    ctx.fillPath()
}
ctx.restoreGState()

// Soft top highlight on the plate edge.
ctx.addPath(rounded(plate.insetBy(dx: 2, dy: 2), 184))
ctx.setStrokeColor(color(0xFFFFFF, 0.10))
ctx.setLineWidth(4)
ctx.strokePath()

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
