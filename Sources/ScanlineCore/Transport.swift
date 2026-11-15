import Foundation
import IOKit

public enum ScanError: Error, CustomStringConvertible {
    case deviceNotFound
    case io(String, kern_return_t)
    case protocolError(String)
    case scsiStatus(UInt8, cdb: [UInt8])
    case timeout(String)

    public var description: String {
        switch self {
        case .deviceNotFound: return "scanner not found (is it plugged in, and is Capture Tool closed?)"
        case let .io(what, kr): return "\(what) failed: 0x\(String(UInt32(bitPattern: kr), radix: 16))"
        case let .protocolError(s): return "protocol error: \(s)"
        case let .scsiStatus(s, cdb): return "SCSI status 0x\(String(s, radix: 16)) for \(cdb.hex)"
        case let .timeout(s): return "timeout: \(s)"
        }
    }
}

/// Moves raw 16-byte CDBs and their data to the device.
public protocol ScannerTransport: AnyObject {
    /// Sends `cdb`; if `dataIn > 0` reads that many bytes back, else writes `dataOut`.
    func execute(cdb: [UInt8], dataIn: Int, dataOut: [UInt8]) throws -> [UInt8]
    func close()
}

/// Transport through the vendor kext's user client (`com_AvKernel`). Used by the probe
/// while the kext is still installed; a direct USB transport replaces it later.
///
/// User-client ABI (from the vendor driver):
///   sel 0 lock, sel 1 unlock,
///   sel 2 submit 0x4C-byte SCSI_PASS_THROUGH-like block,
///   sel 3 host->device data (input struct, <=4096 B per call),
///   sel 4 device->host data (output struct, <=4096 B per call).
public final class AvKernelTransport: ScannerTransport {
    private var connect: io_connect_t = 0
    private static let chunk = 4096

    public init() throws {
        let matching = IOServiceMatching("com_AvKernel")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { throw ScanError.deviceNotFound }
        defer { IOObjectRelease(service) }
        var c: io_connect_t = 0
        let kr = IOServiceOpen(service, mach_task_self_, 0, &c)
        guard kr == KERN_SUCCESS else { throw ScanError.io("IOServiceOpen", kr) }
        connect = c
        try call(0)
    }

    deinit { close() }

    public func close() {
        guard connect != 0 else { return }
        _ = try? call(1)
        IOServiceClose(connect)
        connect = 0
    }

    @discardableResult
    private func call(_ sel: UInt32, input: UnsafeRawPointer? = nil, inputSize: Int = 0,
                      output: UnsafeMutableRawPointer? = nil, outputSize: Int = 0) throws -> Int {
        var outSize = outputSize
        let kr = output == nil
            ? IOConnectCallStructMethod(connect, sel, input, inputSize, nil, nil)
            : IOConnectCallStructMethod(connect, sel, input, inputSize, output, &outSize)
        guard kr == KERN_SUCCESS else { throw ScanError.io("user client selector \(sel)", kr) }
        return outSize
    }

    public func execute(cdb: [UInt8], dataIn: Int, dataOut: [UInt8]) throws -> [UInt8] {
        precondition(cdb.count <= 16)
        let isIn = dataIn > 0
        let length = isIn ? dataIn : dataOut.count
        var block = [UInt8](repeating: 0, count: 0x4C)
        block[0x00] = 0x28                 // struct length
        block[0x04] = 0x01                 // target id (as the vendor driver sets it)
        block[0x06] = 0x10                 // CDB length
        block[0x07] = 0x18                 // sense length
        block[0x08] = isIn ? 1 : 0         // data direction
        withUnsafeBytes(of: UInt32(length).littleEndian) { block.replaceSubrange(0x0C..<0x10, with: $0) }
        withUnsafeBytes(of: UInt32(15).littleEndian) { block.replaceSubrange(0x10..<0x14, with: $0) }  // timeout, s
        withUnsafeBytes(of: UInt32(0x2C).littleEndian) { block.replaceSubrange(0x14..<0x18, with: $0) } // sense offset
        block.replaceSubrange(0x18..<(0x18 + cdb.count), with: cdb)
        _ = try block.withUnsafeBytes { try call(2, input: $0.baseAddress, inputSize: $0.count) }

        if isIn {
            var out = [UInt8](repeating: 0, count: dataIn)
            var off = 0
            try out.withUnsafeMutableBytes { buf in
                while off < dataIn {
                    let n = min(Self.chunk, dataIn - off)
                    let got = try call(4, output: buf.baseAddress! + off, outputSize: n)
                    guard got > 0 else { throw ScanError.protocolError("short read at \(off)/\(dataIn)") }
                    off += got
                }
            }
            return out
        }
        var off = 0
        try dataOut.withUnsafeBytes { buf in
            while off < dataOut.count {
                let n = min(Self.chunk, dataOut.count - off)
                try call(3, input: buf.baseAddress! + off, inputSize: n)
                off += n
            }
        }
        return []
    }
}

extension Array where Element == UInt8 {
    public var hex: String { map { String(format: "%02x", $0) }.joined() }
}
