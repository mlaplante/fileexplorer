import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard let outputPath = CommandLine.arguments.dropFirst().first else {
    FileHandle.standardError.write(Data("usage: IconGen <out.png>\n".utf8))
    exit(1)
}

let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else {
    FileHandle.standardError.write(Data("could not create context\n".utf8))
    exit(1)
}

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
}

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: x, y: y)
}

func drawGradient(in path: CGPath, colors: [CGColor], locations: [CGFloat],
                  start: CGPoint, end: CGPoint) {
    guard let gradient = CGGradient(colorsSpace: colorSpace,
                                    colors: colors as CFArray,
                                    locations: locations) else { return }
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(gradient, start: start, end: end, options: [])
    context.restoreGState()
}

func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
           transform: nil)
}

func drawDropShadow(for path: CGPath, offsetY: CGFloat, alpha: CGFloat) {
    context.saveGState()
    context.translateBy(x: 0, y: offsetY)
    context.addPath(path)
    context.setFillColor(rgba(0, 0, 0, alpha))
    context.fillPath()
    context.restoreGState()
}

func tabStripPath(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                  riseX: CGFloat, tabWidth: CGFloat) -> CGPath {
    let r = height * 0.27
    let path = CGMutablePath()
    path.move(to: point(x + r, y))
    path.addLine(to: point(x + width - r, y))
    path.addQuadCurve(to: point(x + width, y + r),
                      control: point(x + width, y))
    path.addLine(to: point(x + width - 12, y + height - r))
    path.addQuadCurve(to: point(x + width - r - 12, y + height),
                      control: point(x + width - 8, y + height))
    path.addLine(to: point(x + width - tabWidth, y + height))
    path.addQuadCurve(to: point(x + width - tabWidth - riseX, y + height * 0.38),
                      control: point(x + width - tabWidth - 8, y + height))
    path.addLine(to: point(x + r, y + height * 0.38))
    path.addQuadCurve(to: point(x, y + height * 0.16),
                      control: point(x, y + height * 0.34))
    path.closeSubpath()
    return path
}

func folderBodyPath() -> CGPath {
    let path = CGMutablePath()
    path.move(to: point(288, 358))
    path.addLine(to: point(340, 188))
    path.addQuadCurve(to: point(376, 164), control: point(348, 164))
    path.addLine(to: point(656, 164))
    path.addQuadCurve(to: point(694, 192), control: point(684, 164))
    path.addLine(to: point(758, 384))
    path.addQuadCurve(to: point(728, 426), control: point(768, 420))
    path.addLine(to: point(567, 426))
    path.addQuadCurve(to: point(549, 408), control: point(552, 426))
    path.addLine(to: point(535, 378))
    path.addQuadCurve(to: point(512, 360), control: point(530, 360))
    path.addLine(to: point(308, 360))
    path.addQuadCurve(to: point(288, 358), control: point(296, 360))
    path.closeSubpath()
    return path
}

// Transparent canvas outside the app-icon squircle.
context.clear(CGRect(x: 0, y: 0, width: size, height: size))

let card = CGRect(x: 112, y: 112, width: 800, height: 800)
let cardPath = roundedPath(card, radius: 150)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -22), blur: 42,
                  color: rgba(0, 0, 0, 0.42))
context.addPath(cardPath)
context.setFillColor(rgba(0.07, 0.07, 0.07, 1))
context.fillPath()
context.restoreGState()

drawGradient(
    in: cardPath,
    colors: [
        rgba(0.16, 0.16, 0.16),
        rgba(0.075, 0.078, 0.08),
        rgba(0.025, 0.026, 0.028),
    ],
    locations: [0, 0.55, 1],
    start: point(card.midX, card.maxY),
    end: point(card.midX, card.minY))

context.addPath(cardPath)
context.setStrokeColor(rgba(1, 1, 1, 0.10))
context.setLineWidth(5)
context.strokePath()

let innerHighlight = roundedPath(card.insetBy(dx: 14, dy: 14), radius: 136)
context.addPath(innerHighlight)
context.setStrokeColor(rgba(1, 1, 1, 0.035))
context.setLineWidth(3)
context.strokePath()

// Layered tabs echo the dual-pane/file-stack concept while moving closer to
// the richer folder mark in the reference.
let backTab = tabStripPath(x: 308, y: 525, width: 398, height: 60,
                           riseX: 22, tabWidth: 92)
let middleTab = tabStripPath(x: 302, y: 454, width: 420, height: 66,
                             riseX: 24, tabWidth: 98)

drawDropShadow(for: backTab, offsetY: -8, alpha: 0.24)
drawGradient(in: backTab,
             colors: [rgba(0.18, 0.27, 1), rgba(0.04, 0.59, 1)],
             locations: [0, 1],
             start: point(304, 555),
             end: point(716, 555))

drawDropShadow(for: middleTab, offsetY: -9, alpha: 0.26)
drawGradient(in: middleTab,
             colors: [rgba(0.43, 0.27, 1), rgba(1, 0.13, 0.86),
                      rgba(1, 0.56, 0.28)],
             locations: [0, 0.66, 1],
             start: point(298, 486),
             end: point(724, 486))

let body = folderBodyPath()
drawDropShadow(for: body, offsetY: -14, alpha: 0.30)
drawGradient(in: body,
             colors: [rgba(0.09, 0.44, 1), rgba(0.23, 0.82, 1)],
             locations: [0, 1],
             start: point(310, 250),
             end: point(740, 400))

drawGradient(in: body,
             colors: [rgba(0.17, 0.48, 1), rgba(0.17, 0.76, 1)],
             locations: [0, 1],
             start: point(336, 170),
             end: point(734, 426))

let bodyGloss = folderBodyPath()
context.saveGState()
context.addPath(bodyGloss)
context.clip()
let gloss = CGGradient(colorsSpace: colorSpace,
                       colors: [rgba(1, 1, 1, 0.18), rgba(1, 1, 1, 0)] as CFArray,
                       locations: [0, 1])!
context.drawLinearGradient(gloss, start: point(420, 430), end: point(650, 220),
                           options: [])
context.restoreGState()

// Negative-space keyhole, filled with the same near-black as the base.
let keyhole = CGMutablePath()
keyhole.addEllipse(in: CGRect(x: 478, y: 260, width: 68, height: 68))
keyhole.move(to: point(498, 300))
keyhole.addLine(to: point(466, 198))
keyhole.addLine(to: point(558, 198))
keyhole.addLine(to: point(526, 300))
keyhole.closeSubpath()
context.addPath(keyhole)
context.setFillColor(rgba(0.045, 0.046, 0.048, 1))
context.fillPath()

context.addPath(body)
context.setStrokeColor(rgba(1, 1, 1, 0.12))
context.setLineWidth(3)
context.strokePath()

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: outputPath) as CFURL,
          UTType.png.identifier as CFString, 1, nil)
else {
    FileHandle.standardError.write(Data("could not write image\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("finalize failed\n".utf8))
    exit(1)
}
