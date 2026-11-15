// Renders the Scanline "Beam" icon (docs/design.md) to an .icns.
// usage: swift tools/icon/make-icon.swift <out.icns>
import AppKit
import CoreGraphics

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Draws the icon into a `px`×`px` context. Artwork follows the macOS grid: an 824 body inside 1024.
func render(px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)
    // Work in SVG-like coordinates (y down).
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Body shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.30))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x6C5CFF))
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient field
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0x6C5CFF), color(0xB14BF4), color(0xFF5D3A)] as CFArray,
                          locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: body.minX, y: body.minY), end: CGPoint(x: body.maxX, y: body.maxY), options: [])
    // Soft top highlight
    let hi = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                        colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hi, start: CGPoint(x: 512, y: body.minY), end: CGPoint(x: 512, y: body.minY + 420), options: [])

    // Map the original 1024 tile artwork into the 824 body.
    ctx.translateBy(x: 100, y: 100)
    ctx.scaleBy(x: 824.0 / 1024, y: 824.0 / 1024)

    // Receipt (tilted -7°) with a zig-zag bottom edge
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 512)
    ctx.rotate(by: -7 * .pi / 180)
    ctx.translateBy(x: -512, y: -512)
    let receipt = CGMutablePath()
    receipt.move(to: CGPoint(x: 362, y: 190))
    receipt.addLine(to: CGPoint(x: 662, y: 190))
    receipt.addLine(to: CGPoint(x: 662, y: 790))
    var x: CGFloat = 662
    var up = false
    while x > 362 {
        x -= 30
        receipt.addLine(to: CGPoint(x: x, y: up ? 790 : 816))
        up.toggle()
    }
    receipt.addLine(to: CGPoint(x: 362, y: 790))
    receipt.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 24), blur: 56, color: color(0x2A1260, 0.35))
    ctx.addPath(receipt)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: UInt32) {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
        ctx.setFillColor(color(c))
        ctx.fillPath()
    }
    bar(412, 260, 200, 26, 0x2B2E3D)
    bar(402, 330, 220, 16, 0xB9BCCB)
    bar(402, 374, 170, 16, 0xB9BCCB)
    bar(402, 418, 210, 16, 0xB9BCCB)
    bar(402, 610, 130, 16, 0xB9BCCB)
    bar(402, 664, 220, 30, 0x2B2E3D)
    ctx.restoreGState()

    // Scan beam: glow, then bright core
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 46, color: color(0xFFE066, 1))
    bar(120, 506, 784, 30, 0xFFE066)
    ctx.restoreGState()
    bar(140, 512, 744, 18, 0xFFF6C2)

    ctx.restoreGState()
    return ctx.makeImage()!
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Scanline.iconset")
try? FileManager.default.removeItem(at: tmp)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(cgImage: render(px: px))
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: tmp.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", out]
try p.run()
p.waitUntilExit()
// Also keep a 1024 PNG preview next to the icns.
let png = (out as NSString).deletingPathExtension + "-1024.png"
try NSBitmapImageRep(cgImage: render(px: 1024)).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: png))
print(p.terminationStatus == 0 ? "wrote \(out)" : "iconutil failed")
