import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// An original mark: the ergonomic shell and its thumb ball. No wordmark, no
// vendor branding — the silhouette is what identifies the device.

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}

let space = CGColorSpaceCreateDeviceRGB()

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space,
               colors: stops.map { $0.1 } as CFArray,
               locations: stops.map { $0.0 })!
}

func squircle(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func draw(size s: CGFloat, into ctx: CGContext) {
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // macOS icon geometry: the rounded square is 824/1024 of the canvas.
    let inset = s * 0.0977
    let plate = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = s * 0.1810

    // Drop shadow, so the plate sits on the desktop rather than floating.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012),
                  blur: s * 0.030, color: rgb(0, 0, 0, 0.42))
    ctx.addPath(squircle(plate, corner))
    ctx.setFillColor(rgb(38, 42, 48))
    ctx.fillPath()
    ctx.restoreGState()

    // Plate gradient.
    ctx.saveGState()
    ctx.addPath(squircle(plate, corner))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(78, 86, 96)), (0.55, rgb(50, 56, 64)), (1, rgb(28, 32, 38))]),
        start: CGPoint(x: plate.minX, y: plate.maxY),
        end: CGPoint(x: plate.maxX, y: plate.minY),
        options: []
    )
    // A soft sheen across the top edge.
    ctx.drawLinearGradient(
        gradient([(0, rgb(255, 255, 255, 0.16)), (1, rgb(255, 255, 255, 0))]),
        start: CGPoint(x: plate.midX, y: plate.maxY),
        end: CGPoint(x: plate.midX, y: plate.midY),
        options: []
    )
    ctx.restoreGState()

    // ---- the shell -------------------------------------------------------
    // A tilted egg, fuller at the palm and narrowing toward the nose, with the
    // left flank scooped where the ball sits. Tilted because the device is.
    let c = CGPoint(x: plate.midX + plate.width * 0.055, y: plate.midY)
    let u = plate.width

    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y)
    ctx.rotate(by: -10 * .pi / 180)

    let shell = CGMutablePath()
    shell.move(to: CGPoint(x: 0.01 * u, y: 0.335 * u))                 // nose
    shell.addCurve(to: CGPoint(x: 0.275 * u, y: 0.03 * u),             // right flank
                   control1: CGPoint(x: 0.17 * u, y: 0.325 * u),
                   control2: CGPoint(x: 0.275 * u, y: 0.20 * u))
    shell.addCurve(to: CGPoint(x: 0.045 * u, y: -0.325 * u),           // palm
                   control1: CGPoint(x: 0.275 * u, y: -0.15 * u),
                   control2: CGPoint(x: 0.20 * u, y: -0.325 * u))
    shell.addCurve(to: CGPoint(x: -0.215 * u, y: -0.155 * u),          // bottom left
                   control1: CGPoint(x: -0.09 * u, y: -0.325 * u),
                   control2: CGPoint(x: -0.185 * u, y: -0.27 * u))
    shell.addCurve(to: CGPoint(x: -0.175 * u, y: 0.145 * u),           // scooped flank
                   control1: CGPoint(x: -0.245 * u, y: -0.055 * u),
                   control2: CGPoint(x: -0.245 * u, y: 0.055 * u))
    shell.addCurve(to: CGPoint(x: 0.01 * u, y: 0.335 * u),
                   control1: CGPoint(x: -0.115 * u, y: 0.255 * u),
                   control2: CGPoint(x: -0.075 * u, y: 0.335 * u))
    shell.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: u * 0.008, height: -u * 0.018),
                  blur: u * 0.055, color: rgb(0, 0, 0, 0.55))
    ctx.addPath(shell)
    ctx.setFillColor(rgb(150, 161, 175))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shell)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(206, 216, 228)), (0.5, rgb(156, 167, 181)),
                  (1, rgb(92, 101, 114))]),
        start: CGPoint(x: -0.1 * u, y: 0.36 * u),
        end: CGPoint(x: 0.16 * u, y: -0.34 * u),
        options: []
    )

    if s >= 128 {
        // The seam between the two main buttons.
        ctx.setStrokeColor(rgb(60, 68, 80, 0.34))
        ctx.setLineWidth(max(1, u * 0.009))
        ctx.move(to: CGPoint(x: 0.055 * u, y: 0.335 * u))
        ctx.addLine(to: CGPoint(x: 0.075 * u, y: 0.10 * u))
        ctx.strokePath()
    }
    ctx.restoreGState()

    // ---- scroll wheel ----------------------------------------------------
    let wheel = CGRect(x: -0.045 * u, y: 0.075 * u, width: 0.085 * u, height: 0.185 * u)
    ctx.addPath(CGPath(roundedRect: wheel, cornerWidth: wheel.width * 0.5,
                       cornerHeight: wheel.width * 0.5, transform: nil))
    ctx.setFillColor(rgb(30, 34, 40))
    ctx.fillPath()
    if s >= 128 {
        ctx.setStrokeColor(rgb(170, 180, 192, 0.7))
        ctx.setLineWidth(max(1, u * 0.008))
        for i in 0..<3 {
            let y = wheel.minY + wheel.height * (0.28 + 0.22 * CGFloat(i))
            ctx.move(to: CGPoint(x: wheel.minX + wheel.width * 0.24, y: y))
            ctx.addLine(to: CGPoint(x: wheel.maxX - wheel.width * 0.24, y: y))
        }
        ctx.strokePath()
    }

    // ---- the two thumb buttons -------------------------------------------
    if s >= 128 {
        for i in 0..<2 {
            let b = CGRect(x: -0.163 * u, y: 0.055 * u + CGFloat(i) * 0.085 * u,
                           width: 0.058 * u, height: 0.068 * u)
            ctx.addPath(CGPath(roundedRect: b, cornerWidth: b.width * 0.32,
                               cornerHeight: b.width * 0.32, transform: nil))
            ctx.setFillColor(rgb(74, 83, 96, 0.85))
            ctx.fillPath()
        }
    }
    ctx.restoreGState()

    // ---- the ball --------------------------------------------------------
    // Dark and glossy against the light shell. The one element that must
    // survive 16 points, so contrast matters more than fidelity.
    let r = u * 0.208
    let bc = CGPoint(x: c.x - u * 0.238, y: c.y - u * 0.050)
    let ball = CGRect(x: bc.x - r, y: bc.y - r, width: r * 2, height: r * 2)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -u * 0.006, height: -u * 0.016),
                  blur: u * 0.05, color: rgb(0, 0, 0, 0.6))
    ctx.addEllipse(in: ball)
    ctx.setFillColor(rgb(32, 37, 45))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: ball)
    ctx.clip()
    ctx.drawRadialGradient(
        gradient([(0, rgb(126, 140, 158)), (0.42, rgb(62, 71, 84)),
                  (1, rgb(18, 21, 27))]),
        startCenter: CGPoint(x: bc.x - r * 0.34, y: bc.y + r * 0.38),
        startRadius: 0,
        endCenter: bc, endRadius: r * 1.16,
        options: []
    )
    ctx.restoreGState()

    if s >= 64 {
        ctx.saveGState()
        ctx.addEllipse(in: ball)
        ctx.clip()
        let hl = CGRect(x: bc.x - r * 0.66, y: bc.y + r * 0.22,
                        width: r * 0.66, height: r * 0.40)
        ctx.addEllipse(in: hl)
        ctx.clip()
        ctx.drawRadialGradient(
            gradient([(0, rgb(255, 255, 255, 0.95)), (1, rgb(255, 255, 255, 0))]),
            startCenter: CGPoint(x: hl.midX, y: hl.midY), startRadius: 0,
            endCenter: CGPoint(x: hl.midX, y: hl.midY), endRadius: hl.width * 0.62,
            options: []
        )
        ctx.restoreGState()
    }

    ctx.addEllipse(in: ball.insetBy(dx: u * 0.005, dy: u * 0.005))
    ctx.setStrokeColor(rgb(200, 214, 232, 0.34))
    ctx.setLineWidth(max(0.7, u * 0.008))
    ctx.strokePath()
}

func writePNG(size: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    draw(size: CGFloat(size), into: ctx)
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                   ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    writePNG(size: px, to: out.appendingPathComponent("\(name).png"))
}
print("rendered 10 sizes into \(out.path)")
