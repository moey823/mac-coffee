import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct IconVariant {
    let size: Int
    let filename: String
}

func renderIcon(size: Int) throws -> CGImage {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
          ) else {
        throw NSError(domain: "MacCoffeeIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create the icon drawing context."])
    }

    let unit = CGFloat(size)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    let background = CGPath(
        roundedRect: CGRect(x: unit * 0.02, y: unit * 0.02, width: unit * 0.96, height: unit * 0.96),
        cornerWidth: unit * 0.23,
        cornerHeight: unit * 0.23,
        transform: nil
    )
    context.addPath(background)
    context.clip()

    let colors = [
        CGColor(red: 0.20, green: 0.10, blue: 0.07, alpha: 1),
        CGColor(red: 0.50, green: 0.27, blue: 0.13, alpha: 1)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: unit), end: CGPoint(x: unit, y: 0), options: [])
    }

    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(CGColor(red: 1.0, green: 0.86, blue: 0.65, alpha: 0.95))
    context.setLineWidth(unit * 0.045)
    let steam = CGMutablePath()
    steam.move(to: CGPoint(x: unit * 0.39, y: unit * 0.70))
    steam.addCurve(to: CGPoint(x: unit * 0.39, y: unit * 0.84),
                   control1: CGPoint(x: unit * 0.33, y: unit * 0.75),
                   control2: CGPoint(x: unit * 0.46, y: unit * 0.79))
    steam.move(to: CGPoint(x: unit * 0.52, y: unit * 0.72))
    steam.addCurve(to: CGPoint(x: unit * 0.52, y: unit * 0.86),
                   control1: CGPoint(x: unit * 0.46, y: unit * 0.77),
                   control2: CGPoint(x: unit * 0.58, y: unit * 0.80))
    steam.move(to: CGPoint(x: unit * 0.65, y: unit * 0.70))
    steam.addCurve(to: CGPoint(x: unit * 0.65, y: unit * 0.83),
                   control1: CGPoint(x: unit * 0.60, y: unit * 0.75),
                   control2: CGPoint(x: unit * 0.71, y: unit * 0.78))
    context.addPath(steam)
    context.strokePath()

    let saucer = CGMutablePath()
    saucer.move(to: CGPoint(x: unit * 0.23, y: unit * 0.24))
    saucer.addQuadCurve(to: CGPoint(x: unit * 0.78, y: unit * 0.24),
                        control: CGPoint(x: unit * 0.50, y: unit * 0.08))
    saucer.addLine(to: CGPoint(x: unit * 0.23, y: unit * 0.24))
    context.addPath(saucer)
    context.setFillColor(CGColor(red: 1.0, green: 0.89, blue: 0.72, alpha: 1))
    context.fillPath()

    let handle = CGRect(x: unit * 0.64, y: unit * 0.35, width: unit * 0.22, height: unit * 0.25)
    context.addEllipse(in: handle)
    context.setStrokeColor(CGColor(red: 1.0, green: 0.89, blue: 0.72, alpha: 1))
    context.setLineWidth(unit * 0.075)
    context.strokePath()

    let cup = CGMutablePath()
    cup.move(to: CGPoint(x: unit * 0.24, y: unit * 0.62))
    cup.addLine(to: CGPoint(x: unit * 0.28, y: unit * 0.34))
    cup.addQuadCurve(to: CGPoint(x: unit * 0.62, y: unit * 0.34),
                     control: CGPoint(x: unit * 0.45, y: unit * 0.30))
    cup.addLine(to: CGPoint(x: unit * 0.66, y: unit * 0.62))
    cup.addQuadCurve(to: CGPoint(x: unit * 0.24, y: unit * 0.62),
                     control: CGPoint(x: unit * 0.45, y: unit * 0.72))
    cup.closeSubpath()
    context.addPath(cup)
    context.setFillColor(CGColor(red: 1.0, green: 0.89, blue: 0.72, alpha: 1))
    context.fillPath()

    context.addEllipse(in: CGRect(x: unit * 0.28, y: unit * 0.56, width: unit * 0.34, height: unit * 0.085))
    context.setFillColor(CGColor(red: 0.27, green: 0.12, blue: 0.07, alpha: 1))
    context.fillPath()

    guard let image = context.makeImage() else {
        throw NSError(domain: "MacCoffeeIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not render the icon."])
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "MacCoffeeIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create PNG output."])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "MacCoffeeIcon", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not write PNG output."])
    }
}

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate-app-icon.swift <iconset-directory>\n", stderr)
    exit(EXIT_FAILURE)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let variants = [
    IconVariant(size: 16, filename: "icon_16x16.png"),
    IconVariant(size: 32, filename: "icon_16x16@2x.png"),
    IconVariant(size: 32, filename: "icon_32x32.png"),
    IconVariant(size: 64, filename: "icon_32x32@2x.png"),
    IconVariant(size: 128, filename: "icon_128x128.png"),
    IconVariant(size: 256, filename: "icon_128x128@2x.png"),
    IconVariant(size: 256, filename: "icon_256x256.png"),
    IconVariant(size: 512, filename: "icon_256x256@2x.png"),
    IconVariant(size: 512, filename: "icon_512x512.png"),
    IconVariant(size: 1024, filename: "icon_512x512@2x.png")
]
for variant in variants {
    try writePNG(renderIcon(size: variant.size), to: output.appendingPathComponent(variant.filename))
}
