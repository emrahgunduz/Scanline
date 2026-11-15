import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Detects receipts fed bottom-first (text upside down). Vision happily "reads" upside-down
/// glyphs, so confidence alone can't tell; instead we read the receipt both ways up and keep
/// the way whose text makes sense: prices, dates, times and common receipt words. On-device.
public enum Orientation {
    /// A turn that makes the receipt read upright.
    public enum Turn: String, Sendable, CaseIterable {
        case none, upsideDown, left, right   // left/right = rotate 90° counter-clockwise / clockwise

        public func apply(_ img: GrayImage) -> GrayImage {
            switch self {
            case .none: img
            case .upsideDown: Orientation.rotated180(img)
            case .left: Orientation.rotated90(img, clockwise: false)
            case .right: Orientation.rotated90(img, clockwise: true)
            }
        }
    }

    /// Which turn makes the text read best. Normal (portrait) scans compare upright vs upside down;
    /// a scan wider than tall (fed sideways) also tries both quarter turns.
    public static func bestTurn(_ img: GrayImage) -> Turn {
        let small = downscale(img, maxSide: 1800)
        let candidates: [Turn] = small.width > small.height ? Turn.allCases : [.none, .upsideDown]
        let scores = candidates.map { ($0, sense($0.apply(small))) }
        let current = scores.first { $0.0 == .none }?.1 ?? 0
        guard let best = scores.max(by: { $0.1 < $1.1 }), best.0 != .none else { return .none }
        return best.1 >= current + 3 && Double(best.1) > Double(current) * 1.5 ? best.0 : .none
    }

    public static func isUpsideDown(_ img: GrayImage) -> Bool { bestTurn(img) == .upsideDown }

    public static func rotated180(_ img: GrayImage) -> GrayImage {
        GrayImage(width: img.width, height: img.height, pixels: img.pixels.reversed())
    }

    public static func rotated90(_ img: GrayImage, clockwise: Bool) -> GrayImage {
        let w = img.width, h = img.height
        var out = GrayImage(width: h, height: w)
        img.pixels.withUnsafeBufferPointer { src in
            out.pixels.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    for x in 0..<w {
                        // clockwise: (x, y) -> (h-1-y, x); counter-clockwise: (x, y) -> (y, w-1-x)
                        let (nx, ny) = clockwise ? (h - 1 - y, x) : (y, w - 1 - x)
                        dst[ny * h + nx] = src[y * w + x]
                    }
                }
            }
        }
        return out
    }

    static let keywords: Set<String> = ["TOPLAM", "TOPKDV", "KDV", "TARIH", "SAAT", "FIS", "TOTAL", "KREDI", "NAKIT",
                                        "TUTAR", "ADET", "KART", "TESEKKUR", "SATIS", "TL", "NO", "VD", "KASIYER",
                                        "TAX", "DATE", "TIME", "CASH", "CARD", "THANK", "RECEIPT", "SUBTOTAL"]
    nonisolated(unsafe) static let patterns: [NSRegularExpression] = [
        #"\d+[.,]\d{2}(?!\d)"#,                // prices: 260,00
        #"\b\d{2}[./-]\d{2}[./-]\d{4}\b"#,     // dates: 04/11/2026
        #"\b\d{2}:\d{2}"#,                     // times: 13:53
    ].map { try! NSRegularExpression(pattern: $0) }

    /// How much of the recognised text reads like a receipt.
    public static func sense(_ img: GrayImage) -> Int {
        guard let cg = img.cgImage else { return 0 }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .fast
        req.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:]).perform([req])
        let tr = Locale(identifier: "tr_TR")
        var score = 0
        for obs in req.results ?? [] {
            guard let text = obs.topCandidates(1).first?.string else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for p in patterns { score += p.numberOfMatches(in: text, range: range) }
            let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: tr).uppercased()
            for word in folded.split(whereSeparator: { !$0.isLetter }) where keywords.contains(String(word)) { score += 1 }
        }
        return score
    }

    public static func downscale(_ img: GrayImage, maxSide: Int) -> GrayImage {
        let side = max(img.width, img.height)
        guard side > maxSide else { return img }
        let f = Double(side) / Double(maxSide)
        let w = max(1, Int(Double(img.width) / f)), h = max(1, Int(Double(img.height) / f))
        var out = GrayImage(width: w, height: h)
        for y in 0..<h {
            let sy = min(img.height - 1, Int(Double(y) * f))
            for x in 0..<w {
                out.pixels[y * w + x] = img.pixels[sy * img.width + min(img.width - 1, Int(Double(x) * f))]
            }
        }
        return out
    }
}

extension GrayImage {
    public var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Reads any image file as 8-bit gray.
    public static func read(_ url: URL) -> GrayImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var img = GrayImage(width: cg.width, height: cg.height)
        let ok = img.pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                      bytesPerRow: cg.width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return true
        }
        return ok ? img : nil
    }
}
