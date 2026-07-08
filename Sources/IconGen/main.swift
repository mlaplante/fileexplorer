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

// Background squircle: 824×824 centered, Apple-ish corner radius.
let inset: CGFloat = 100
let card = CGRect(x: inset, y: inset,
                  width: CGFloat(size) - 2 * inset,
                  height: CGFloat(size) - 2 * inset)
let cardPath = CGPath(roundedRect: card, cornerWidth: 185, cornerHeight: 185,
                      transform: nil)
context.addPath(cardPath)
context.clip()
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [rgba(0.16, 0.47, 0.96), rgba(0.05, 0.22, 0.60)] as CFArray,
    locations: [0, 1])!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: card.midX, y: card.maxY),
    end: CGPoint(x: card.midX, y: card.minY),
    options: [])

// Two panes: left one plain, right one carrying three "file row" bars.
let paneWidth: CGFloat = 264
let paneHeight: CGFloat = 420
let gap: CGFloat = 56
let paneY = card.midY - paneHeight / 2
let leftPane = CGRect(x: card.midX - gap / 2 - paneWidth, y: paneY,
                      width: paneWidth, height: paneHeight)
let rightPane = CGRect(x: card.midX + gap / 2, y: paneY,
                       width: paneWidth, height: paneHeight)
for (pane, alpha) in [(leftPane, 0.92), (rightPane, 1.0)] {
    context.setFillColor(rgba(1, 1, 1, alpha))
    context.addPath(CGPath(roundedRect: pane, cornerWidth: 36, cornerHeight: 36,
                           transform: nil))
    context.fillPath()
}
// File rows on the right pane.
context.setFillColor(rgba(0.16, 0.47, 0.96, 0.85))
for row in 0..<3 {
    let rowRect = CGRect(x: rightPane.minX + 36,
                         y: rightPane.maxY - 96 - CGFloat(row) * 108,
                         width: paneWidth - 72, height: 52)
    context.addPath(CGPath(roundedRect: rowRect, cornerWidth: 18,
                           cornerHeight: 18, transform: nil))
    context.fillPath()
}

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
