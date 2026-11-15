// ScanlineHelper: gives the Scanline app raw USB access to the IRIScan Express 4.
// Started by the app as `sudo -n local.scanline.helper --stdio` (root, in the user's session),
// it serves one client over stdin/stdout and exits when the pipe closes. No kext involved.
// Links only ScanlineUSB, so its bytes change only when helper code changes.
import Darwin
import Foundation
import ScanlineUSB

func log(_ s: String) { FileHandle.standardError.write(Data("ScanlineHelper: \(s)\n".utf8)) }

guard CommandLine.arguments.dropFirst().first == ScanlineHelper.argument else {
    log("usage: \(CommandLine.arguments[0]) \(ScanlineHelper.argument)")
    exit(64)
}
signal(SIGPIPE, SIG_IGN)

let result = HelperServer(input: STDIN_FILENO, output: STDOUT_FILENO, log: log) { try USBTransport() }.run()
exit(result == .closed ? 0 : 1)
