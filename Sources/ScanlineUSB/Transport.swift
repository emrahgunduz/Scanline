import Foundation

public enum ScanError: Error, Equatable, CustomStringConvertible {
    case deviceNotFound
    case io(String, kern_return_t)
    case protocolError(String)
    case scsiStatus(UInt8, cdb: [UInt8])
    case timeout(String)
    /// The installed helper speaks an older wire protocol than this app needs.
    case helperOutdated(installed: UInt32)
    /// sudo won't run the installed helper for this user (rule missing, for another user, or
    /// pinned to different bytes).
    case helperNotAuthorised

    public var description: String {
        switch self {
        case .deviceNotFound: return "scanner not found (is it plugged in, and is Capture Tool closed?)"
        case let .io(what, kr): return "\(what) failed: 0x\(String(UInt32(bitPattern: kr), radix: 16))"
        case let .protocolError(s): return "protocol error: \(s)"
        case let .scsiStatus(s, cdb): return "SCSI status 0x\(String(s, radix: 16)) for \(cdb.hex)"
        case let .timeout(s): return "timeout: \(s)"
        case let .helperOutdated(v): return "the Scanline helper is out of date (protocol \(v)); update it in Settings"
        case .helperNotAuthorised: return "the Scanline helper is not authorised; repair it in Settings"
        }
    }
}

/// Moves raw 16-byte CDBs and their data to the device.
public protocol ScannerTransport: AnyObject {
    /// Sends `cdb`; if `dataIn > 0` reads that many bytes back, else writes `dataOut`.
    func execute(cdb: [UInt8], dataIn: Int, dataOut: [UInt8]) throws -> [UInt8]
    func close()
}

extension Array where Element == UInt8 {
    public var hex: String { map { String(format: "%02x", $0) }.joined() }
}
