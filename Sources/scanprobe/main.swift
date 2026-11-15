import Foundation
import ScanlineCore

let usage = """
usage: scanprobe <command> [-v] [--usb]
  --usb           talk to the scanner directly over USB (no kext; run with sudo)
  info            bridge identity, INQUIRY, device info
  paper           print paper sensor state every 0.25 s (Ctrl-C to stop)
  button          print button-status bytes whenever they change (Ctrl-C to stop)
  monitor         print paper and button changes (Ctrl-C to stop)
  scan [out.pgm]  scan one page (paper must be loaded) to an 8-bit gray PGM
  process in.pgm out.jpg   crop, straighten, rescale, B/W (no scanner needed)
  orient files…   report which images are upside down
"""

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
let verbose = args.contains("-v")
let useUSB = args.contains("--usb")
let positional = args.filter { $0 != "-v" && $0 != "--usb" }
guard let command = positional.first else { print(usage); exit(2) }

// Loops stop between commands on Ctrl-C / kill, so the bridge is never cut mid-exchange.
nonisolated(unsafe) var stopRequested = false
signal(SIGINT) { _ in stopRequested = true }
signal(SIGTERM) { _ in stopRequested = true }

func timestamp() -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date())
}

if command == "orient" {
    for path in positional.dropFirst() {
        guard let img = GrayImage.read(URL(fileURLWithPath: path)) else { print("unreadable: \(path)"); continue }
        let small = Orientation.downscale(img, maxSide: 1800)
        let scores = Orientation.Turn.allCases.map { "\($0.rawValue) \(Orientation.sense($0.apply(small)))" }.joined(separator: ", ")
        print(String(Orientation.bestTurn(img).rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)), scores, (path as NSString).lastPathComponent)
    }
    exit(0)
}

if command == "process" {
    guard positional.count >= 3 else { print(usage); exit(2) }
    do {
        let t0 = Date()
        let raw = try GrayImage.readPGM(URL(fileURLWithPath: positional[1]))
        let r = ReceiptProcessor().process(raw)
        try r.image.writeJPEG(URL(fileURLWithPath: positional[2]))
        print(String(format: "%dx%d -> %dx%d, skew %.2f°, paper %@, cut off %@, upright-turn %@, %.2fs", raw.width, raw.height,
                     r.image.width, r.image.height, r.skewDegrees, r.paperFound ? "found" : "NOT found", r.cutOff ? "YES" : "no", r.turn.rawValue,
                     Date().timeIntervalSince(t0)))
        exit(0)
    } catch { FileHandle.standardError.write(Data("error: \(error)\n".utf8)); exit(1) }
}

do {
    let transport: ScannerTransport = useUSB ? try USBTransport() : try AvKernelTransport()
    if verbose { print("transport:", useUSB ? "direct USB" : "AvKernel kext") }
    defer { transport.close() }
    let scanner = IRIScanExpress4(transport: transport)
    if verbose { scanner.log = { print("   \($0)") } }

    switch command {
    case "info":
        print("bridge:", try scanner.identify())
        let inq = try scanner.inquiry()
        print("inquiry:", IRIScanExpress4.describe(inquiry: inq))
        let info = try scanner.deviceInfo()
        print("device info:", info.hex)
        print("paper present:", try scanner.paperPresent())

    case "paper":
        var last: Bool?
        while !stopRequested {
            let p = try scanner.paperPresent()
            if p != last { print(timestamp(), p ? "PAPER IN" : "no paper"); last = p }
            Thread.sleep(forTimeInterval: 0.25)
        }

    case "button":
        var last: [UInt8]?
        print("press the scanner's top button; changes are printed")
        while !stopRequested {
            let b = try scanner.buttonStatus()
            if b != last { print(timestamp(), b.hex); last = b }
            Thread.sleep(forTimeInterval: 0.2)
        }

    case "monitor":
        var lastPaper: Bool?
        var lastButton: [UInt8]?
        print("watching paper sensor and button; Ctrl-C to stop")
        while !stopRequested {
            let p = try scanner.paperPresent()
            if p != lastPaper { print(timestamp(), "paper:", p ? "IN" : "none"); lastPaper = p }
            let b = try scanner.buttonStatus()
            if b != lastButton { print(timestamp(), "button:", b.hex); lastButton = b }
            Thread.sleep(forTimeInterval: 0.2)
        }

    case "scan":
        let out = positional.count > 1 ? positional[1] : "scan.pgm"
        if !(try scanner.paperPresent()) {
            print("waiting for paper…")
            while !stopRequested, !(try scanner.paperPresent()) { Thread.sleep(forTimeInterval: 0.25) }
            if stopRequested { exit(130) }
        }
        print("paper detected, scanning in 2 s")
        Thread.sleep(forTimeInterval: 2)
        let start = Date()
        let page = try scanner.scanPage { lines in
            print("\r  \(lines) lines", terminator: ""); fflush(stdout)
        }
        print()
        var file = Data("P5\n\(page.width) \(page.height)\n255\n".utf8)
        file.append(contentsOf: page.pixels)
        try file.write(to: URL(fileURLWithPath: out))
        print(String(format: "%dx%d in %.1fs -> %@", page.width, page.height, Date().timeIntervalSince(start), out))
        try scanner.waitReady()

    default:
        print(usage); exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
