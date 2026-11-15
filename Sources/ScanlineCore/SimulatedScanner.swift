import Foundation

/// A fake IRIScan Express 4 behind the Novatek bridge, built from what the trace showed.
/// Answers the same CDBs as the real device, so the command layer, session and app can run
/// without hardware. Pages come from `nextPage` (raw 2592-wide gray, ~3x vertical).
public final class SimulatedScanner: ScannerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _paper = false
    private var _button: UInt8 = 0
    /// Raw page delivered by the next scan.
    public var nextPage: GrayImage?
    /// When true the next scan delivers no data (simulates the rollers missing the sheet).
    public var failNextFeed = false
    /// Pause before each image band (seconds), to mimic the real scanner's pace in demos.
    public var bandDelay: TimeInterval = 0
    /// Count of CDBs seen, for tests.
    public private(set) var commands: [[UInt8]] = []

    private var pending: [UInt8] = []          // last tunneled Avision CDB (+data)
    private var page: GrayImage?
    private var bandRow = 0
    private var bandReady: (addr: UInt32, lines: Int)?
    private var scanning = false
    private var ended = false
    private static let base: UInt32 = 0x0046_2240
    private static let bandLines = 240

    public init() {}

    public var paper: Bool {
        get { lock.withLock { _paper } }
        set { lock.withLock { _paper = newValue } }
    }

    public func pressButton(long: Bool = false) { lock.withLock { _button = long ? 0xC1 : 0x81 } }

    public func close() {}

    public func execute(cdb: [UInt8], dataIn: Int, dataOut: [UInt8]) throws -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        commands.append(cdb)
        switch (cdb[0], cdb[1]) {
        case (0xC5, 0x07): return bridge(cdb, dataIn: dataIn, dataOut: dataOut)
        case (0xC3, 0x07): return memRead(cdb, length: dataIn)
        default: throw ScanError.protocolError("simulator: unknown CDB \(cdb.hex)")
        }
    }

    private func pad(_ b: [UInt8], _ n: Int) -> [UInt8] { Array((b + [UInt8](repeating: 0, count: n)).prefix(n)) }

    private func bridge(_ cdb: [UInt8], dataIn: Int, dataOut: [UInt8]) -> [UInt8] {
        let (a, b, c) = (cdb[10], cdb[11], cdb[12])
        switch (a, b) {
        case (0xFF, 0x02): return Array("NOVA".utf8)
        case (0xFF, 0x03): return pad([0x10, 0, 0, 0, 1], 16)
        case (0xFF, _):    return pad([0x10, 0, 0, 0, 1, 0, 0, 0, 1], 16)
        case (0x02, 0x03): pending = dataOut; avisionCommand(dataOut); return []
        case (0x02, 0x01): return pad([0x10], dataIn)
        case (0x02, 0x02):
            switch c {
            case 1: return pad([], dataIn)                         // status GOOD
            case 2: return bandHeader(dataIn)
            default: return avisionData(dataIn)
            }
        default: return pad([], dataIn)
        }
    }

    private func avisionCommand(_ d: [UInt8]) {
        switch d.first {
        case 0x1B:                                   // SCAN
            scanning = true; ended = false; bandRow = 0; bandReady = nil
            page = failNextFeed ? nil : nextPage
            failNextFeed = false
        case 0x17:                                   // RELEASE: page ejected
            if scanning, page != nil { _paper = false }
            scanning = false
        default: break
        }
    }

    private func avisionData(_ n: Int) -> [UInt8] {
        guard let op = pending.first else { return pad([], n) }
        switch op {
        case 0x12:
            return pad([0x06, 0, 0x02, 0x02, 0xAB, 0, 0, 0x10] + Array("IRIS    IRIScanExpress4 0.11".utf8), n)
        case 0x08: return pad([_paper ? 1 : 0, 0], n)
        case 0x28:
            switch pending[2] {
            case 0xA0: return pad([1, 0], n)
            case 0xA1: defer { _button = 0 }; return pad([_button, _button == 0 ? 0 : 3, 0, 0, 0, 0, _button == 0 ? 0 : 1], n)
            default: return pad([], n)
            }
        default: return pad([], n)
        }
    }

    private func bandHeader(_ n: Int) -> [UInt8] {
        guard scanning else { return pad([3], n) }
        guard let p = page else { return pad([0, 0, 0, 0, 1], n) }   // never ready: misfeed
        if bandRow >= p.height || ended { ended = true; return pad([3, 0, 0, 0, 1], n) }
        if bandDelay > 0 { lock.unlock(); Thread.sleep(forTimeInterval: bandDelay); lock.lock() }
        let lines = min(Self.bandLines, p.height - bandRow)
        let addr = Self.base &+ UInt32(bandRow * p.width)
        bandReady = (addr, lines)
        var h = [UInt8](repeating: 0, count: 24)
        h[0] = 1; h[4] = 1
        withUnsafeBytes(of: UInt32(p.width).littleEndian) { h.replaceSubrange(12..<16, with: $0) }
        withUnsafeBytes(of: UInt32(lines).littleEndian) { h.replaceSubrange(16..<20, with: $0) }
        withUnsafeBytes(of: addr.littleEndian) { h.replaceSubrange(20..<24, with: $0) }
        return pad(h, n)
    }

    private func memRead(_ cdb: [UInt8], length: Int) -> [UInt8] {
        guard let p = page else { return [UInt8](repeating: 0, count: length) }
        let addr = UInt32(cdb[2]) << 24 | UInt32(cdb[3]) << 16 | UInt32(cdb[4]) << 8 | UInt32(cdb[5])
        let off = Int(addr &- Self.base)
        let end = min(p.pixels.count, off + length)
        var out = off < end ? Array(p.pixels[off..<end]) : []
        out += [UInt8](repeating: 0, count: length - out.count)
        // Advance past the band once its last byte is read.
        if let b = bandReady, off + length >= Int(b.addr &- Self.base) + b.lines * p.width {
            bandRow += b.lines; bandReady = nil
        }
        return out
    }

    /// Synthetic raw page: a white receipt with dark text bars on black, tilted, 3x tall.
    public static func syntheticReceipt(widthPx: Int = 640, heightPx: Int = 1500,
                                        tiltDegrees: Double = 2, verticalScale: Double = 2.98) -> GrayImage {
        let W = 2592, H = Int(Double(heightPx + 200) * verticalScale)
        var img = GrayImage(width: W, height: H, fill: 12)
        let a = tiltDegrees * .pi / 180
        let cx = 400.0, cy = Double(heightPx + 200) / 2
        for ry in 0..<H {
            let y = Double(ry) / verticalScale          // true-scale row
            for x in 0..<1000 {
                // rotate (x,y) back into receipt coordinates
                let dx = Double(x) - cx, dy = y - cy
                let u = cos(a) * dx + sin(a) * dy + Double(widthPx) / 2
                let v = -sin(a) * dx + cos(a) * dy + Double(heightPx) / 2
                guard u >= 0, u < Double(widthPx), v >= 0, v < Double(heightPx) else { continue }
                let textRow = Int(v) % 50 < 18 && Int(v) > 60 && Int(v) < heightPx - 60
                let textCol = u > 40 && u < Double(widthPx) - 40 && Int(u) % 24 < 14
                img[x, ry] = textRow && textCol ? 45 : 205
            }
        }
        return img
    }
}
