import AppKit
import CoreGraphics
import Foundation

let size = 1024
guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil,
                              width: size,
                              height: size,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Unable to create icon bitmap context")
}

// Draw in a top-left-origin coordinate system, matching the reference artwork.
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)
context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

let gradientColors = [
    CGColor(red: 0.24, green: 0.78, blue: 0.94, alpha: 1),
    CGColor(red: 0.11, green: 0.31, blue: 0.98, alpha: 1)
]
let gradient = CGGradient(colorsSpace: colorSpace,
                          colors: gradientColors as CFArray,
                          locations: [0, 1])!

func fillWhite(_ path: CGPath) {
    context.saveGState()
    context.addPath(path)
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fillPath()
    context.restoreGState()
}

func strokeWithGradient(_ path: CGPath, width: CGFloat = 48) {
    context.saveGState()
    context.addPath(path)
    context.setLineWidth(width)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 170, y: 510),
                               end: CGPoint(x: 875, y: 510),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func drawBubble(_ path: CGPath) {
    fillWhite(path)
    strokeWithGradient(path)
}

// Rear conversation bubble: its upper arc and right-side tail remain visible
// behind the foreground bubble, matching the supplied overlapping-bubbles mark.
let rear = CGMutablePath()
rear.move(to: CGPoint(x: 390, y: 389))
rear.addCurve(to: CGPoint(x: 616, y: 222),
              control1: CGPoint(x: 410, y: 284),
              control2: CGPoint(x: 500, y: 222))
rear.addCurve(to: CGPoint(x: 856, y: 452),
              control1: CGPoint(x: 754, y: 222),
              control2: CGPoint(x: 856, y: 324))
rear.addCurve(to: CGPoint(x: 776, y: 616),
              control1: CGPoint(x: 856, y: 523),
              control2: CGPoint(x: 827, y: 579))
rear.addLine(to: CGPoint(x: 798, y: 693))
rear.addCurve(to: CGPoint(x: 775, y: 711),
              control1: CGPoint(x: 802, y: 710),
              control2: CGPoint(x: 789, y: 718))
rear.addLine(to: CGPoint(x: 681, y: 671))
rear.addCurve(to: CGPoint(x: 390, y: 568),
              control1: CGPoint(x: 630, y: 693),
              control2: CGPoint(x: 417, y: 656))
rear.addCurve(to: CGPoint(x: 390, y: 389),
              control1: CGPoint(x: 359, y: 501),
              control2: CGPoint(x: 360, y: 443))
rear.closeSubpath()
drawBubble(rear)

// Foreground bubble, including the small lower-left speech tail.
let front = CGMutablePath()
front.move(to: CGPoint(x: 274, y: 361))
front.addCurve(to: CGPoint(x: 456, y: 298),
               control1: CGPoint(x: 323, y: 323),
               control2: CGPoint(x: 383, y: 298))
front.addCurve(to: CGPoint(x: 744, y: 557),
               control1: CGPoint(x: 744, y: 298),
               control2: CGPoint(x: 744, y: 408))
front.addCurve(to: CGPoint(x: 477, y: 793),
               control1: CGPoint(x: 744, y: 692),
               control2: CGPoint(x: 627, y: 793))
front.addCurve(to: CGPoint(x: 366, y: 771),
               control1: CGPoint(x: 437, y: 793),
               control2: CGPoint(x: 399, y: 785))
front.addLine(to: CGPoint(x: 284, y: 809))
front.addCurve(to: CGPoint(x: 247, y: 781),
               control1: CGPoint(x: 262, y: 820),
               control2: CGPoint(x: 241, y: 803))
front.addLine(to: CGPoint(x: 268, y: 701))
front.addCurve(to: CGPoint(x: 274, y: 361),
               control1: CGPoint(x: 225, y: 661),
               control2: CGPoint(x: 200, y: 610))
front.closeSubpath()
drawBubble(front)

// Three simple blue dots centered inside the front bubble.
func drawGradientDot(center: CGPoint, radius: CGFloat) {
    context.saveGState()
    context.addEllipse(in: CGRect(x: center.x - radius,
                                  y: center.y - radius,
                                  width: radius * 2,
                                  height: radius * 2))
    context.clip()
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: center.x - radius, y: center.y),
                               end: CGPoint(x: center.x + radius, y: center.y),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

for x in [335.0, 456.0, 577.0] {
    drawGradientDot(center: CGPoint(x: x, y: 565), radius: 34)
}

guard let image = context.makeImage() else {
    fatalError("Unable to render app icon")
}
let bitmap = NSBitmapImageRep(cgImage: image)
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode app icon PNG")
}
let output = URL(fileURLWithPath: "CustomChat/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
try png.write(to: output)
print("Generated \(output.path) (\(size)x\(size))")
