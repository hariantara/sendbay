// Renders the Sendbay app icon at 1024x1024.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon.png"

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// macOS icon grid: 824pt body centred on a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.28))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(0x14A35A))
ctx.fillPath()
ctx.restoreGState()

// Body gradient (top lighter).
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let gradient = CGGradient(colorsSpace: colorSpace, colors: [rgb(0x3DDC84), rgb(0x0B8A47)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Soft top highlight.
let highlight = CGGradient(colorsSpace: colorSpace, colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(highlight, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
ctx.restoreGState()

// Glyph: an Android phone resting in a tray (the "bay"), with an arrow in
// and an arrow out on its screen.
let white = rgb(0xFFFFFF)
ctx.setStrokeColor(white)
ctx.setFillColor(white)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

// Tray: open-top rounded U.
let tray = CGMutablePath()
tray.move(to: CGPoint(x: 258, y: 500))
tray.addLine(to: CGPoint(x: 258, y: 320))
tray.addArc(tangent1End: CGPoint(x: 258, y: 248), tangent2End: CGPoint(x: 330, y: 248), radius: 72)
tray.addLine(to: CGPoint(x: 694, y: 248))
tray.addArc(tangent1End: CGPoint(x: 766, y: 248), tangent2End: CGPoint(x: 766, y: 320), radius: 72)
tray.addLine(to: CGPoint(x: 766, y: 500))
ctx.setLineWidth(52)
ctx.addPath(tray)
ctx.strokePath()

// Phone body with a punch-hole camera.
let phone = CGRect(x: 372, y: 318, width: 280, height: 500)
ctx.setLineWidth(44)
ctx.addPath(CGPath(roundedRect: phone, cornerWidth: 62, cornerHeight: 62, transform: nil))
ctx.strokePath()
ctx.fillEllipse(in: CGRect(x: 512 - 19, y: 760 - 19, width: 38, height: 38))

// Arrows on the screen: down (to the Mac) and up (to the phone).
func arrow(x: CGFloat, from y0: CGFloat, to y1: CGFloat) {
    let dir: CGFloat = y1 < y0 ? -1 : 1
    ctx.setLineWidth(30)
    ctx.move(to: CGPoint(x: x, y: y0))
    ctx.addLine(to: CGPoint(x: x, y: y1 - dir * 20))
    ctx.strokePath()
    let head = CGMutablePath()
    head.move(to: CGPoint(x: x, y: y1 + dir * 14))
    head.addLine(to: CGPoint(x: x - 46, y: y1 - dir * 42))
    head.addLine(to: CGPoint(x: x + 46, y: y1 - dir * 42))
    head.closeSubpath()
    ctx.addPath(head)
    ctx.setLineWidth(14)
    ctx.drawPath(using: .fillStroke)
}
arrow(x: 466, from: 676, to: 418)
arrow(x: 558, from: 418, to: 676)

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
