import AppKit
import CoreGraphics
import Foundation

let size = 1024
guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Unable to create icon context")
}
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locations)!
}
let bluePurple = gradient([
    CGColor(red: 0.24, green: 0.82, blue: 0.97, alpha: 1),
    CGColor(red: 0.24, green: 0.48, blue: 1.00, alpha: 1),
    CGColor(red: 0.72, green: 0.57, blue: 0.98, alpha: 1)
])
let glass = gradient([
    CGColor(red: 0.91, green: 0.96, blue: 1.00, alpha: 0.93),
    CGColor(red: 0.83, green: 0.88, blue: 1.00, alpha: 0.88),
    CGColor(red: 0.96, green: 0.84, blue: 1.00, alpha: 0.90),
    CGColor(red: 0.77, green: 0.96, blue: 1.00, alpha: 0.94)
])
let orbitGradient = gradient([
    CGColor(red: 0.28, green: 0.77, blue: 1.00, alpha: 0.85),
    CGColor(red: 0.60, green: 0.66, blue: 1.00, alpha: 0.92),
    CGColor(red: 0.98, green: 0.77, blue: 0.97, alpha: 0.95)
])

func rounded(_ rect: CGRect, _ radius: CGFloat, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
}
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

// Soft ambient glow under the mark.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 25), blur: 52,
              color: CGColor(red: 0.34, green: 0.53, blue: 0.98, alpha: 0.24))
ctx.setFillColor(CGColor(red: 0.83, green: 0.87, blue: 1, alpha: 0.18))
ctx.fillEllipse(in: CGRect(x: 180, y: 315, width: 670, height: 440))
ctx.restoreGState()

// Rear bubble, with a soft cyan-to-violet glass body and a right tail.
let rear = CGMutablePath()
rear.move(to: CGPoint(x: 430, y: 385))
rear.addCurve(to: CGPoint(x: 625, y: 245), control1: CGPoint(x: 450, y: 282), control2: CGPoint(x: 525, y: 245))
rear.addCurve(to: CGPoint(x: 840, y: 452), control1: CGPoint(x: 840, y: 245), control2: CGPoint(x: 840, y: 350))
rear.addCurve(to: CGPoint(x: 790, y: 610), control1: CGPoint(x: 840, y: 525), control2: CGPoint(x: 812, y: 570))
rear.addLine(to: CGPoint(x: 820, y: 704))
rear.addQuadCurve(to: CGPoint(x: 775, y: 724), control: CGPoint(x: 824, y: 740))
rear.addLine(to: CGPoint(x: 675, y: 680))
rear.addCurve(to: CGPoint(x: 430, y: 585), control1: CGPoint(x: 620, y: 702), control2: CGPoint(x: 430, y: 665))
rear.addCurve(to: CGPoint(x: 430, y: 385), control1: CGPoint(x: 390, y: 520), control2: CGPoint(x: 390, y: 440))
rear.closeSubpath()
ctx.saveGState()
ctx.addPath(rear)
ctx.clip()
ctx.drawLinearGradient(bluePurple, start: CGPoint(x: 450, y: 250), end: CGPoint(x: 850, y: 730), options: [])
ctx.restoreGState()
ctx.addPath(rear)
ctx.setStrokeColor(CGColor(red: 0.55, green: 0.83, blue: 1, alpha: 0.82))
ctx.setLineWidth(7)
ctx.strokePath()

// Glassy front bubble.
let front = CGMutablePath()
front.move(to: CGPoint(x: 265, y: 370))
front.addCurve(to: CGPoint(x: 470, y: 315), control1: CGPoint(x: 310, y: 325), control2: CGPoint(x: 385, y: 315))
front.addCurve(to: CGPoint(x: 745, y: 560), control1: CGPoint(x: 745, y: 315), control2: CGPoint(x: 745, y: 425))
front.addCurve(to: CGPoint(x: 470, y: 795), control1: CGPoint(x: 745, y: 700), control2: CGPoint(x: 625, y: 795))
front.addCurve(to: CGPoint(x: 360, y: 770), control1: CGPoint(x: 430, y: 795), control2: CGPoint(x: 395, y: 785))
front.addLine(to: CGPoint(x: 275, y: 820))
front.addQuadCurve(to: CGPoint(x: 245, y: 785), control: CGPoint(x: 230, y: 810))
front.addLine(to: CGPoint(x: 270, y: 700))
front.addCurve(to: CGPoint(x: 265, y: 370), control1: CGPoint(x: 205, y: 650), control2: CGPoint(x: 205, y: 465))
front.closeSubpath()

ctx.saveGState()
ctx.addPath(front)
ctx.clip()
ctx.drawLinearGradient(glass, start: CGPoint(x: 260, y: 360), end: CGPoint(x: 720, y: 800), options: [])
// A subtle glass highlight across the upper-left interior.
let shine = CGMutablePath()
shine.move(to: CGPoint(x: 290, y: 430))
shine.addCurve(to: CGPoint(x: 610, y: 360), control1: CGPoint(x: 360, y: 365), control2: CGPoint(x: 520, y: 350))
shine.addLine(to: CGPoint(x: 520, y: 500))
shine.addCurve(to: CGPoint(x: 290, y: 535), control1: CGPoint(x: 430, y: 500), control2: CGPoint(x: 345, y: 525))
shine.closeSubpath()
ctx.addPath(shine)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.30))
ctx.fillPath()
ctx.restoreGState()

ctx.addPath(front)
ctx.setStrokeColor(CGColor(red: 0.96, green: 0.99, blue: 1, alpha: 0.98))
ctx.setLineWidth(8)
ctx.strokePath()
ctx.addPath(front)
ctx.setStrokeColor(CGColor(red: 0.58, green: 0.77, blue: 1, alpha: 0.45))
ctx.setLineWidth(2)
ctx.strokePath()

// Orbiting iridescent ring, drawn as a tilted ellipse.
ctx.saveGState()
ctx.translateBy(x: 512, y: 540)
ctx.rotate(by: -0.36)
ctx.translateBy(x: -512, y: -540)
let orbit = CGPath(ellipseIn: CGRect(x: 75, y: 425, width: 900, height: 245), transform: nil)
ctx.addPath(orbit)
ctx.setLineWidth(18)
ctx.replacePathWithStrokedPath()
ctx.clip()
ctx.drawLinearGradient(orbitGradient, start: CGPoint(x: 80, y: 520), end: CGPoint(x: 980, y: 520), options: [])
ctx.restoreGState()

// Three crisp blue message dots.
let dotGradient = gradient([
    CGColor(red: 0.23, green: 0.69, blue: 1, alpha: 1),
    CGColor(red: 0.16, green: 0.39, blue: 0.98, alpha: 1)
])
for x: CGFloat in [365, 500, 635] {
    let r: CGFloat = 34
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: x-r, y: 545-r, width: 2*r, height: 2*r))
    ctx.clip()
    ctx.drawLinearGradient(dotGradient, start: CGPoint(x: x-r, y: 545), end: CGPoint(x: x+r, y: 545), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
    ctx.setLineWidth(2)
    ctx.strokeEllipse(in: CGRect(x: x-r, y: 545-r, width: 2*r, height: 2*r))
}

// Small four-point sparkle in the upper-right corner.
let sparkle = CGMutablePath()
sparkle.move(to: CGPoint(x: 825, y: 140))
sparkle.addCurve(to: CGPoint(x: 875, y: 210), control1: CGPoint(x: 842, y: 190), control2: CGPoint(x: 850, y: 205))
sparkle.addCurve(to: CGPoint(x: 945, y: 230), control1: CGPoint(x: 900, y: 215), control2: CGPoint(x: 925, y: 218))
sparkle.addCurve(to: CGPoint(x: 875, y: 252), control1: CGPoint(x: 925, y: 242), control2: CGPoint(x: 900, y: 245))
sparkle.addCurve(to: CGPoint(x: 825, y: 325), control1: CGPoint(x: 850, y: 275), control2: CGPoint(x: 842, y: 300))
sparkle.addCurve(to: CGPoint(x: 802, y: 252), control1: CGPoint(x: 810, y: 300), control2: CGPoint(x: 805, y: 275))
sparkle.addCurve(to: CGPoint(x: 730, y: 230), control1: CGPoint(x: 780, y: 245), control2: CGPoint(x: 755, y: 242))
sparkle.addCurve(to: CGPoint(x: 802, y: 210), control1: CGPoint(x: 755, y: 218), control2: CGPoint(x: 780, y: 215))
sparkle.closeSubpath()
ctx.addPath(sparkle)
ctx.setFillColor(CGColor(red: 0.28, green: 0.48, blue: 0.98, alpha: 0.88))
ctx.fillPath()

guard let cgImage = ctx.makeImage() else { fatalError("Icon render failed") }
let bitmap = NSBitmapImageRep(cgImage: cgImage)
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encode failed") }
let output = URL(fileURLWithPath: "CustomChat/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: output)
print("Generated replacement icon (1024x1024)")
