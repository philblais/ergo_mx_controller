import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Composites a supplied square artwork into the macOS app-icon plate: the
// rounded square is 824/1024 of the canvas with a 185.4/1024 corner radius,
// and the surrounding margin carries the shadow.

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: makeicon2 <source image> <out dir>\n".data(using: .utf8)!)
    exit(2)
}
let sourceURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])

guard let src = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write("could not read \(sourceURL.path)\n".data(using: .utf8)!)
    exit(1)
}

let space = CGColorSpaceCreateDeviceRGB()

func draw(size s: CGFloat, into ctx: CGContext) {
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    let inset = s * 0.0977
    let plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = s * 0.1810
    let path = CGPath(roundedRect: plate, cornerWidth: corner, cornerHeight: corner,
                      transform: nil)

    // Shadow first, on an opaque fill, so it reads under the artwork rather
    // than through it.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                  blur: s * 0.030,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.42))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(red: 0.12, green: 0.10, blue: 0.22, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Aspect-fill the artwork into the plate.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let aw = CGFloat(artwork.width), ah = CGFloat(artwork.height)
    let scale = max(plate.width / aw, plate.height / ah)
    let w = aw * scale, h = ah * scale
    ctx.interpolationQuality = .high
    ctx.draw(artwork, in: CGRect(x: plate.midX - w / 2, y: plate.midY - h / 2,
                                 width: w, height: h))

    // A hairline rim, so the plate has an edge against a light desktop.
    ctx.restoreGState()
    ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: s * 0.0015, dy: s * 0.0015),
                       cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.setLineWidth(max(0.5, s * 0.003))
    ctx.strokePath()
}

func writePNG(size: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    draw(size: CGFloat(size), into: ctx)
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                               UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                   ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    writePNG(size: px, to: outURL.appendingPathComponent("\(name).png"))
}
print("rendered 10 sizes from \(sourceURL.lastPathComponent)")
