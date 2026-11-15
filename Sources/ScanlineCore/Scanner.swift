import Foundation

/// IRIScan Express 4: Avision SCSI commands tunneled through a Novatek USB bridge.
/// See docs/protocol.md for where every byte here comes from.
public final class IRIScanExpress4 {
    let t: ScannerTransport
    public var log: ((String) -> Void)?

    public init(transport: ScannerTransport) { t = transport }

    // MARK: Novatek bridge

    /// C5 07 … <len BE16> <a> <b> <c>. For a=02: b=03 send CDB, b=01 phase header, b=02 phase data;
    /// c selects the phase: 00 data, 01 status, 02 image band header.
    private func bridge(_ a: UInt8, _ b: UInt8, _ c: UInt8 = 0, inLen: Int = 0, out: [UInt8] = []) throws -> [UInt8] {
        let len = inLen > 0 ? inLen : out.count
        precondition(len <= 0xFFFF)
        let cdb = Self.bridgeCDB(a, b, c, length: len)
        return try t.execute(cdb: cdb, dataIn: inLen, dataOut: out)
    }

    private func poll(_ n: UInt8) throws -> [UInt8] { try bridge(0xFF, n, inLen: 16) }

    /// Identity check; the bridge answers "NOVA".
    public func identify() throws -> String {
        String(decoding: try bridge(0xFF, 0x02, inLen: 4), as: UTF8.self)
    }

    /// Before each phase: wait until FF04 reports ready (byte 8 = 1), then FF03 FF03 FF05.
    private func pre(timeout: TimeInterval = 30) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let s = try poll(0x04)
            if s[8] == 1 { break }
            if Date() > deadline { throw ScanError.timeout("bridge not ready") }
            Thread.sleep(forTimeInterval: 0.1)
        }
        _ = try poll(0x03); _ = try poll(0x03); _ = try poll(0x05)
    }

    /// After each phase: FF04 FF06.
    private func post() throws { _ = try poll(0x04); _ = try poll(0x06) }

    enum Phase: UInt8 { case data = 0, status = 1, band = 2 }

    /// Reads one bridge phase of `len` bytes (02 01 header, FF04, 02 02 data).
    private func readPhase(_ len: Int, _ phase: Phase) throws -> [UInt8] {
        try pre()
        _ = try bridge(0x02, 0x01, phase.rawValue, inLen: len)
        _ = try poll(0x04)
        let d = try bridge(0x02, 0x02, phase.rawValue, inLen: len)
        try post()
        return d
    }

    private func statusPhase(_ cdb: [UInt8]) throws {
        let s = try readPhase(4, .status)
        if s[0] != 0 { throw ScanError.scsiStatus(s[0], cdb: cdb) }
    }

    private func sendCDB(_ bytes: [UInt8]) throws {
        try pre()
        _ = try bridge(0x02, 0x03, out: bytes)
        try post()
    }

    /// Runs a tunneled Avision command. `bytes` = 10-byte CDB plus any outgoing data.
    @discardableResult
    func avision(_ bytes: [UInt8], read: Int = 0) throws -> [UInt8] {
        let cdb = Array(bytes.prefix(10))
        log?("> \(bytes.hex)")
        try sendCDB(bytes)
        var data: [UInt8] = []
        if read > 0 {
            data = try readPhase(read, .data)
            log?("< \(data.hex)")
        }
        try statusPhase(cdb)
        return data
    }

    /// Novatek memory read: C3 07 <addr BE32> <len BE32>  (trace: c3 07 00462240 00010000).
    static func memReadCDB(address: UInt32, length: Int) -> [UInt8] {
        let l = UInt32(length)
        return [0xC3, 0x07,
                UInt8(address >> 24), UInt8((address >> 16) & 0xFF), UInt8((address >> 8) & 0xFF), UInt8(address & 0xFF),
                UInt8(l >> 24), UInt8((l >> 16) & 0xFF), UInt8((l >> 8) & 0xFF), UInt8(l & 0xFF),
                0, 0, 0, 0, 0, 0]
    }

    private func memRead(address: UInt32, length: Int) throws -> [UInt8] {
        let cdb = Self.memReadCDB(address: address, length: length)
        return try t.execute(cdb: cdb, dataIn: length, dataOut: [])
    }

    // MARK: Avision commands

    static func bridgeCDB(_ a: UInt8, _ b: UInt8, _ c: UInt8, length len: Int) -> [UInt8] {
        [0xC5, 0x07, 0, 0, 0, 0, 0, 0, UInt8(len >> 8), UInt8(len & 0xFF), a, b, c, 0, 0, 0]
    }

    static func cdb10(_ op: UInt8, type: UInt8 = 0, qualifier: UInt16 = 0, length: Int = 0) -> [UInt8] {
        [op, 0, type, 0, UInt8(qualifier >> 8), UInt8(qualifier & 0xFF),
         UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF), 0]
    }

    public func inquiry() throws -> [UInt8] {
        try avision([0x12, 0, 0, 0, 0xA5, 0, 0, 0, 0, 0], read: 96)
    }

    /// Product string from the INQUIRY reply, e.g. "IRIS IRIScanExpress4 0.11".
    public static func describe(inquiry d: [UInt8]) -> String {
        guard d.count >= 36 else { return d.hex }
        func s(_ r: Range<Int>) -> String {
            String(decoding: d[r], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        return "\(s(8..<16)) \(s(16..<32)) \(s(32..<36))"
    }

    /// Device info block (READ10 type 0x69, 128 bytes). Serial at offset 46.
    public func deviceInfo() throws -> [UInt8] {
        try avision(Self.cdb10(0x28, type: 0x69, qualifier: 0x0A0D, length: 0x80), read: 0x80)
    }

    /// MEDIA CHECK. true = paper in the feeder.
    public func paperPresent() throws -> Bool {
        let r = try avision([0x08, 0, 0, 0, 0x02, 0, 0, 0, 0, 0], read: 2)
        return r[0] & 1 == 1
    }

    /// READ10 type 0xA0, 2 bytes (seen before scans; meaning not yet known).
    public func statusA0() throws -> [UInt8] {
        try avision(Self.cdb10(0x28, type: 0xA0, qualifier: 0x0A0D, length: 2), read: 2)
    }

    /// READ10 type 0xA1, 16 bytes: button status on Avision devices (unverified here).
    public func buttonStatus() throws -> [UInt8] {
        try avision(Self.cdb10(0x28, type: 0xA1, qualifier: 0x0A0D, length: 16), read: 16)
    }

    // MARK: Scan

    /// SET WINDOW exactly as captured (10-byte CDB + 79-byte window, 300x300 dpi, 8 bpp).
    static let setWindow300Gray = hexBytes(
        "24000000000000004f00" +
        "00000000000000470000012c012c0000000000000000000028800000438080808005080000030000" +
        "0000000000000000ff1de0ff001e6010e01000006400640064c00000000b000000000000000000")

    public struct Page: Sendable {
        public let width: Int       // pixels (= bytes, 8-bit gray)
        public let height: Int
        public let pixels: [UInt8]
        /// Seconds from SCAN to the first image band (long = paper not picked up quickly).
        public var firstBandAfter: TimeInterval = 0
        public var duration: TimeInterval = 0
        public var gray: GrayImage { GrayImage(width: width, height: height, pixels: pixels) }
    }

    /// Top-button event decoded from READ10 type 0xA1 (latched, cleared on read).
    public enum ButtonEvent: Sendable, Equatable { case short, long }

    public func readButton() throws -> ButtonEvent? {
        let b = try buttonStatus()
        guard b[0] & 0x80 != 0 else { return nil }
        return b[0] & 0x40 != 0 ? .long : .short
    }

    /// One simplex 300 dpi 8-bit gray page, replaying Capture Tool's exact setup (trace scan1).
    /// `firstBandTimeout` is short on purpose: a sheet the rollers did not take shows up as
    /// no data, which is reported as `ScanError.timeout` (a misfeed signal).
    public func scanPage(firstBandTimeout: TimeInterval = 12, bandTimeout: TimeInterval = 30,
                         progress: ((Int) -> Void)? = nil) throws -> Page {
        let started = Date()
        var firstBand: TimeInterval?
        guard try paperPresent() else { throw ScanError.protocolError("no paper in feeder") }
        _ = try statusA0()

        try avision([0x2A, 0x00, 0x95, 0, 0, 0x01, 0, 0, 0x02, 0, 0x00, 0x78])
        try avision([0x2A, 0x00, 0x96, 0, 0, 0x01, 0, 0, 0x02, 0, 0x00, 0x78])
        try avision(hexBytes("2a008300000000001200" + "040000000000000004000000000000000400"))
        try avision(Self.setWindow300Gray)
        try avision([0x16, 0, 0, 0, 0, 0, 0, 0, 0, 0])            // RESERVE UNIT
        defer {
            _ = try? avision([0x17, 0, 0, 0, 0, 0, 0, 0, 0, 0])   // RELEASE UNIT (ejects)
        }
        try avision([0x1B, 0, 0, 0, 0, 0x80, 0, 0, 0, 0])         // SCAN

        var pixels: [UInt8] = []
        var width = 0
        let readCDB = Self.cdb10(0x28, type: 0x00, qualifier: 0x0A0D, length: 0x1FEAE0)
        bands: while true {
            log?("> \(readCDB.hex) (image)")
            try sendCDB(readCDB)
            // Poll the band header until a band is ready (1) or the page ended (3).
            let deadline = Date().addingTimeInterval(firstBand == nil ? firstBandTimeout : bandTimeout)
            while true {
                let st = try readPhase(24, .band)
                switch st[0] {
                case 0:
                    if Date() > deadline {
                        throw ScanError.timeout(firstBand == nil ? "no image: paper not fed" : "image data stopped")
                    }
                    continue
                case 1:
                    if firstBand == nil { firstBand = Date().timeIntervalSince(started) }
                    let bpl = Int(le32(st, 12)), lines = Int(le32(st, 16))
                    let addr = le32(st, 20)
                    width = bpl
                    var remaining = bpl * lines, a = addr
                    while remaining > 0 {
                        let n = min(0x10000, remaining)
                        pixels += try memRead(address: a, length: n)
                        a &+= UInt32(n); remaining -= n
                    }
                    try statusPhase(readCDB)
                    progress?(pixels.count / max(width, 1))
                    continue bands
                case 3:
                    break bands
                default:
                    throw ScanError.protocolError("unknown band status \(st.hex)")
                }
            }
        }
        guard width > 0 else { throw ScanError.protocolError("no image data") }
        return Page(width: width, height: pixels.count / width, pixels: pixels,
                    firstBandAfter: firstBand ?? 0, duration: Date().timeIntervalSince(started))
    }

    /// After a scan the bridge stays busy while the page ejects; wait for it.
    public func waitReady(timeout: TimeInterval = 30) throws { try pre(timeout: timeout); try post() }
}

func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
}

func hexBytes(_ s: String) -> [UInt8] {
    let h = s.filter { !$0.isWhitespace }
    var out: [UInt8] = []
    var i = h.startIndex
    while i < h.endIndex {
        let j = h.index(i, offsetBy: 2)
        out.append(UInt8(h[i..<j], radix: 16)!)
        i = j
    }
    return out
}
