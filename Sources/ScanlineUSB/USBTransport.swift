import CUSBHost
import Foundation

/// Direct USB transport: SCSI over USB Bulk-Only Transport (BOT), no kext.
/// Captures the device from macOS's mass-storage driver (requires root); on close,
/// macOS resets the device and its normal drivers attach again.
public final class USBTransport: ScannerTransport {
    public static let vendorID: UInt16 = 0x0A38
    public static let productID: UInt16 = 0x0161

    private var dev: OpaquePointer?
    private var tag: UInt32 = 1
    /// CDB length put in the CBW. The kext sent 16-byte CDBs; the scanner ignores the padding.
    public var cdbLength: UInt8 = 16
    public var timeout: Double = 15

    public init(vendorID: UInt16 = vendorID, productID: UInt16 = productID) throws {
        var err = [CChar](repeating: 0, count: 256)
        guard let d = usbh_open(vendorID, productID, 0, &err, err.count) else {
            throw ScanError.protocolError(errString(err))
        }
        dev = d
    }

    deinit { close() }

    public func close() {
        if let d = dev { usbh_close(d); dev = nil }
    }

    private func bulk(_ inDir: Bool, _ buf: UnsafeMutableRawPointer, _ len: Int) throws -> (Int, Bool) {
        var err = [CChar](repeating: 0, count: 256)
        var stalled = false
        let n = usbh_bulk(dev, inDir, buf, len, timeout, &stalled, &err, err.count)
        if n < 0 { throw ScanError.protocolError(errString(err)) }
        return (n, stalled)
    }

    private func resetRecovery() {
        var err = [CChar](repeating: 0, count: 256)
        _ = usbh_bot_reset(dev, 0, &err, err.count)
    }

    public func execute(cdb: [UInt8], dataIn: Int, dataOut: [UInt8]) throws -> [UInt8] {
        guard dev != nil else { throw ScanError.protocolError("USB transport closed") }
        let isIn = dataIn > 0
        let length = isIn ? dataIn : dataOut.count
        tag &+= 1

        // Command Block Wrapper, 31 bytes.
        var cbw = [UInt8](repeating: 0, count: 31)
        cbw.replaceSubrange(0..<4, with: [0x55, 0x53, 0x42, 0x43])  // "USBC"
        withUnsafeBytes(of: tag.littleEndian) { cbw.replaceSubrange(4..<8, with: $0) }
        withUnsafeBytes(of: UInt32(length).littleEndian) { cbw.replaceSubrange(8..<12, with: $0) }
        cbw[12] = isIn ? 0x80 : 0x00
        cbw[13] = 0                                                  // LUN
        cbw[14] = cdbLength
        cbw.replaceSubrange(15..<(15 + min(cdb.count, 16)), with: cdb.prefix(16))
        let (sent, st0) = try cbw.withUnsafeMutableBytes { try bulk(false, $0.baseAddress!, 31) }
        if st0 || sent != 31 { resetRecovery(); throw ScanError.protocolError("CBW not accepted (\(cdb.hex))") }

        // Data stage.
        var data = [UInt8](repeating: 0, count: isIn ? dataIn : 0)
        var moved = 0
        if length > 0 {
            if isIn {
                (moved, _) = try data.withUnsafeMutableBytes { try bulk(true, $0.baseAddress!, dataIn) }
            } else {
                var out = dataOut
                let n = out.count
                (moved, _) = try out.withUnsafeMutableBytes { try bulk(false, $0.baseAddress!, n) }
            }
        }

        // Command Status Wrapper, 13 bytes (retry once after a stall).
        var csw = [UInt8](repeating: 0, count: 13)
        var (got, st) = try csw.withUnsafeMutableBytes { try bulk(true, $0.baseAddress!, 13) }
        if st || got == 0 { (got, st) = try csw.withUnsafeMutableBytes { try bulk(true, $0.baseAddress!, 13) } }
        guard got == 13, csw[0..<4] == [0x55, 0x53, 0x42, 0x53] else {
            resetRecovery(); throw ScanError.protocolError("bad CSW \(csw.hex) for \(cdb.hex)")
        }
        let cswTag = UInt32(csw[4]) | UInt32(csw[5]) << 8 | UInt32(csw[6]) << 16 | UInt32(csw[7]) << 24
        guard cswTag == tag else { resetRecovery(); throw ScanError.protocolError("CSW tag mismatch") }
        let status = csw[12]
        if status != 0 {
            if status == 2 { resetRecovery() }
            throw ScanError.protocolError("command failed, CSW status \(status), cdb \(cdb.hex)")
        }
        if isIn && moved < dataIn { data.removeLast(dataIn - moved) }
        return data
    }
}

private func errString(_ e: [CChar]) -> String {
    String(decoding: e.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
