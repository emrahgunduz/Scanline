import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 8-bit grayscale image, row-major.
public struct GrayImage: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width; self.height = height; self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: UInt8 = 0) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: fill, count: width * height))
    }

    @inline(__always) public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }
}

/// Turns a raw scanner page (receipt on black background, ~3x oversampled vertically)
/// into a cropped, straightened, true-scale, black-and-white image — what Capture Tool does.
public struct ReceiptProcessor {
    public struct Options: Sendable {
        /// Raw lines per output line (scanner samples ~900 lines/in for a 300 dpi window).
        public var verticalScale: Double = 2.98
        /// Gray level separating paper from the black background (auto when nil).
        public var paperThreshold: UInt8? = nil
        /// Local-threshold window (px) and offset for black-and-white conversion.
        public var bwWindow: Int = 25
        public var bwOffset: Int = 18
        /// Pixels trimmed from each side after cropping (edge shadow).
        public var inset: Int = 2
        public var blackAndWhite: Bool = true
        /// Pixels below otsu(paper) × this are always ink.
        public var solidInkFactor: Double = 0.6
        /// Turn receipts fed bottom-first upright (reads the text both ways up).
        public var autoOrient: Bool = true
        public init() {}
    }

    public struct Result {
        public var image: GrayImage
        public var skewDegrees: Double
        public var paperFound: Bool
        /// Paper runs into the last scanned line: the scanner stopped before the receipt ended.
        public var cutOff: Bool = false
        /// How the receipt was turned to read upright (fed bottom-first or sideways).
        public var turn: Orientation.Turn = .none
        public var turnedUpright: Bool { turn != .none }
    }

    public var options: Options
    public init(options: Options = Options()) { self.options = options }

    public func process(_ raw: GrayImage) -> Result {
        // 1. Restore true proportions.
        let scaled = Self.resizeVertically(raw, factor: options.verticalScale)
        let t = options.paperThreshold ?? Self.otsu(scaled)
        let cutOff = Self.paperAtBottom(scaled, threshold: t)

        // 2. Measure skew from the paper's left and right edges.
        let angle = Self.skewAngle(scaled, threshold: t)

        // 3. Rotate upright (black fill, like the background).
        var upright = abs(angle) < 0.0005 ? scaled : Self.rotate(scaled, radians: angle)
        // Self-check: the straightened page must measure (near) zero tilt; otherwise
        // the other direction is right.
        if abs(angle) >= 0.0005, abs(Self.skewAngle(upright, threshold: t)) > abs(angle) / 2 {
            upright = Self.rotate(scaled, radians: -angle)
        }

        // 4. Crop to the paper.
        guard let box = Self.paperBox(upright, threshold: t, inset: options.inset) else {
            return Result(image: upright, skewDegrees: angle * 180 / .pi, paperFound: false, cutOff: cutOff)
        }
        var out = Self.crop(upright, box)

        // 5. Black and white.
        if options.blackAndWhite {
            // Anything darker than `dark` is ink outright; this keeps large black areas
            // (white-on-black labels) solid, where a local mean alone would hollow them out.
            let dark = UInt8(Double(Self.otsu(out)) * options.solidInkFactor)
            out = Self.adaptiveThreshold(out, window: options.bwWindow, offset: options.bwOffset, dark: dark)
        }
        var turn = Orientation.Turn.none
        if options.autoOrient {
            turn = Orientation.bestTurn(out)
            out = turn.apply(out)
        }
        return Result(image: out, skewDegrees: angle * 180 / .pi, paperFound: true, cutOff: cutOff, turn: turn)
    }

    // MARK: steps

    /// A complete page ends with background rows after the paper's trailing edge. If any of
    /// the last few rows still holds a paper-wide run, the scan was cut short.
    static func paperAtBottom(_ img: GrayImage, threshold t: UInt8, rows: Int = 4) -> Bool {
        guard img.height > rows else { return false }
        for y in (img.height - rows)..<img.height where edges(img, row: y, threshold: t) != nil {
            return true
        }
        return false
    }

    static func resizeVertically(_ img: GrayImage, factor: Double) -> GrayImage {
        let h = max(1, Int((Double(img.height) / factor).rounded()))
        var out = GrayImage(width: img.width, height: h)
        // Box filter: each output row averages the raw rows it covers.
        for y in 0..<h {
            let y0 = Double(y) * factor, y1 = min(Double(img.height), y0 + factor)
            var acc = [Double](repeating: 0, count: img.width)
            var total = 0.0
            var r = y0
            while r < y1 {
                let row = Int(r)
                let next = min(Double(row + 1), y1)
                let w = next - r
                let base = row * img.width
                for x in 0..<img.width { acc[x] += Double(img.pixels[base + x]) * w }
                total += w
                r = next
            }
            let base = y * img.width
            for x in 0..<img.width { out.pixels[base + x] = UInt8(min(255, (acc[x] / total).rounded())) }
        }
        return out
    }

    static func otsu(_ img: GrayImage) -> UInt8 {
        var hist = [Int](repeating: 0, count: 256)
        var i = 0
        while i < img.pixels.count { hist[Int(img.pixels[i])] += 1; i += 7 }
        let total = hist.reduce(0, +)
        let sumAll = hist.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        var sumB = 0.0, wB = 0, best = 0.0, t = 0
        for k in 0..<256 {
            wB += hist[k]; if wB == 0 { continue }
            let wF = total - wB; if wF == 0 { break }
            sumB += Double(k * hist[k])
            let mB = sumB / Double(wB), mF = (sumAll - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; t = k }
        }
        return UInt8(max(30, min(200, t)))
    }

    /// Paper edge on one row: first/last x where `run` consecutive pixels are above threshold.
    static func edges(_ img: GrayImage, row y: Int, threshold t: UInt8, run: Int = 8) -> (Int, Int)? {
        var left: Int?, right: Int?
        var count = 0
        for x in 0..<img.width {
            if img[x, y] > t { count += 1; if count == run { left = x - run + 1; break } } else { count = 0 }
        }
        count = 0
        for x in stride(from: img.width - 1, through: 0, by: -1) {
            if img[x, y] > t { count += 1; if count == run { right = x + run - 1; break } } else { count = 0 }
        }
        guard let l = left, let r = right, r - l > 40 else { return nil }
        return (l, r)
    }

    /// Angle (radians) of the paper's long axis from vertical, robust to torn ends.
    static func skewAngle(_ img: GrayImage, threshold t: UInt8) -> Double {
        var ys: [Double] = [], ls: [Double] = [], rs: [Double] = []
        let step = max(1, img.height / 400)
        for y in stride(from: 0, to: img.height, by: step) {
            if let (l, r) = edges(img, row: y, threshold: t) {
                ys.append(Double(y)); ls.append(Double(l)); rs.append(Double(r))
            }
        }
        guard ys.count > 20 else { return 0 }
        // Ignore the top/bottom 10% (tear-off edges), then fit both edges.
        let lo = ys.count / 10, hi = ys.count - ys.count / 10
        let slopes = [robustSlope(Array(ys[lo..<hi]), Array(ls[lo..<hi])),
                      robustSlope(Array(ys[lo..<hi]), Array(rs[lo..<hi]))]
        return atan(slopes.reduce(0, +) / 2)
    }

    /// Least squares, refit after dropping points far from the first fit.
    static func robustSlope(_ y: [Double], _ x: [Double]) -> Double {
        func fit(_ idx: [Int]) -> (Double, Double) {
            let n = Double(idx.count)
            let my = idx.reduce(0) { $0 + y[$1] } / n, mx = idx.reduce(0) { $0 + x[$1] } / n
            var num = 0.0, den = 0.0
            for i in idx { num += (y[i] - my) * (x[i] - mx); den += (y[i] - my) * (y[i] - my) }
            let a = den == 0 ? 0 : num / den
            return (a, mx - a * my)
        }
        var idx = Array(0..<y.count)
        var (a, b) = fit(idx)
        for _ in 0..<2 {
            let res = idx.map { abs(x[$0] - (a * y[$0] + b)) }.sorted()
            let cut = max(3.0, res[res.count * 8 / 10] * 1.5)
            let kept = idx.filter { abs(x[$0] - (a * y[$0] + b)) <= cut }
            if kept.count < 10 { break }
            idx = kept; (a, b) = fit(idx)
        }
        return a
    }

    /// Rotates by `radians` around the centre (bilinear), output grows to fit.
    static func rotate(_ img: GrayImage, radians: Double) -> GrayImage {
        let c = cos(radians), s = sin(radians)
        let w = Int((abs(Double(img.width) * c) + abs(Double(img.height) * s)).rounded(.up))
        let h = Int((abs(Double(img.width) * s) + abs(Double(img.height) * c)).rounded(.up))
        var out = GrayImage(width: w, height: h)
        let cx = Double(img.width) / 2, cy = Double(img.height) / 2
        let ox = Double(w) / 2, oy = Double(h) / 2
        for y in 0..<h {
            let dy = Double(y) - oy
            for x in 0..<w {
                let dx = Double(x) - ox
                // inverse mapping
                let sx = c * dx + s * dy + cx, sy = -s * dx + c * dy + cy
                let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
                if x0 < 0 || y0 < 0 || x0 + 1 >= img.width || y0 + 1 >= img.height { continue }
                let fx = sx - Double(x0), fy = sy - Double(y0)
                let p00 = Double(img[x0, y0]), p10 = Double(img[x0 + 1, y0])
                let p01 = Double(img[x0, y0 + 1]), p11 = Double(img[x0 + 1, y0 + 1])
                let v = (p00 * (1 - fx) + p10 * fx) * (1 - fy) + (p01 * (1 - fx) + p11 * fx) * fy
                out[x, y] = UInt8(v.rounded())
            }
        }
        return out
    }

    /// Bounding box of the paper: rows/columns where most samples are paper.
    static func paperBox(_ img: GrayImage, threshold t: UInt8, inset: Int) -> (x: Int, y: Int, w: Int, h: Int)? {
        var rowFrac = [Double](repeating: 0, count: img.height)
        var colCount = [Int](repeating: 0, count: img.width)
        for y in 0..<img.height {
            var n = 0
            for x in 0..<img.width where img[x, y] > t { n += 1; colCount[x] += 1 }
            rowFrac[y] = Double(n)
        }
        // A row is paper if it has at least half the typical paper width.
        let typical = rowFrac.sorted()[img.height * 3 / 4]
        guard typical > 40 else { return nil }
        let rows = rowFrac.indices.filter { rowFrac[$0] > typical * 0.5 }
        guard let y0 = rows.first, let y1 = rows.last else { return nil }
        let span = Double(y1 - y0 + 1)
        let cols = colCount.indices.filter { Double(colCount[$0]) > span * 0.5 }
        guard let x0 = cols.first, let x1 = cols.last else { return nil }
        let x = x0 + inset, y = y0 + inset
        let w = x1 - x0 + 1 - 2 * inset, h = y1 - y0 + 1 - 2 * inset
        guard w > 10, h > 10 else { return nil }
        return (x, y, w, h)
    }

    static func crop(_ img: GrayImage, _ b: (x: Int, y: Int, w: Int, h: Int)) -> GrayImage {
        var out = GrayImage(width: b.w, height: b.h)
        for y in 0..<b.h {
            let src = (b.y + y) * img.width + b.x
            out.pixels.replaceSubrange(y * b.w..<(y + 1) * b.w, with: img.pixels[src..<src + b.w])
        }
        return out
    }

    /// Local mean threshold (Bradley): ink where pixel < mean(window) - offset.
    static func adaptiveThreshold(_ img: GrayImage, window: Int, offset: Int, dark: UInt8 = 0) -> GrayImage {
        let w = img.width, h = img.height
        var integral = [Int](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var rowSum = 0
            for x in 0..<w {
                rowSum += Int(img.pixels[y * w + x])
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + rowSum
            }
        }
        let r = window / 2
        var out = GrayImage(width: w, height: h)
        for y in 0..<h {
            let y0 = max(0, y - r), y1 = min(h, y + r + 1)
            for x in 0..<w {
                let x0 = max(0, x - r), x1 = min(w, x + r + 1)
                let sum = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1]
                        - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
                let mean = sum / ((x1 - x0) * (y1 - y0))
                let p = Int(img.pixels[y * w + x])
                out.pixels[y * w + x] = (p < mean - offset || p < Int(dark)) ? 0 : 255
            }
        }
        return out
    }
}

// MARK: - File I/O

extension GrayImage {
    public static func readPGM(_ url: URL) throws -> GrayImage {
        let d = try Data(contentsOf: url)
        var fields: [String] = []
        var i = d.startIndex, cur = ""
        while fields.count < 4, i < d.endIndex {
            let c = Character(UnicodeScalar(d[i]))
            if c.isWhitespace { if !cur.isEmpty { fields.append(cur); cur = "" } } else { cur.append(c) }
            i += 1
        }
        guard fields.count == 4, fields[0] == "P5", let w = Int(fields[1]), let h = Int(fields[2]) else {
            throw ScanError.protocolError("not an 8-bit PGM")
        }
        return GrayImage(width: w, height: h, pixels: [UInt8](d[i..<(i + w * h)]))
    }

    public func writePGM(_ url: URL) throws {
        var d = Data("P5\n\(width) \(height)\n255\n".utf8)
        d.append(contentsOf: pixels)
        try d.write(to: url)
    }

    /// Grayscale JPEG with dpi metadata.
    public func writeJPEG(_ url: URL, dpi: Double = 300, quality: Double = 0.85) throws {
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        guard let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                               bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ScanError.protocolError("cannot create JPEG") }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ScanError.protocolError("JPEG write failed") }
    }
}
