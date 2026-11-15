import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import ScanlineCore

@Test func fileNamerContinuesFromHighestCounter() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    for n in ["2026-11-01 0000041.jpg", "2026-11-14 0000007.jpg", "notes.txt", "2026-11-14 12.jpg"] {
        FileManager.default.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data())
    }
    #expect(FileNamer.counter(of: "2026-11-15 0000123.jpg") == 123)
    #expect(FileNamer.counter(of: "2026-11-15 123.jpg") == nil)
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12))!
    #expect(FileNamer.nextURL(in: dir, date: date).lastPathComponent == "2026-11-15 0000042.jpg")
}

@Test func processorStraightensCropsAndRescales() {
    let raw = SimulatedScanner.syntheticReceipt(widthPx: 640, heightPx: 1500, tiltDegrees: 2)
    let r = ReceiptProcessor().process(raw)
    #expect(r.paperFound)
    #expect(abs(abs(r.skewDegrees) - 2) < 0.3)
    #expect(abs(r.image.width - 640) < 20)
    #expect(abs(r.image.height - 1500) < 25)
}

@Test func simulatedScanThroughCommandLayer() throws {
    let sim = SimulatedScanner()
    sim.paper = true
    sim.nextPage = GrayImage(width: 2592, height: 1000, fill: 200)
    let s = IRIScanExpress4(transport: sim)
    #expect(try s.identify() == "NOVA")
    #expect(IRIScanExpress4.describe(inquiry: try s.inquiry()) == "IRIS IRIScanExpress4 0.11")
    let page = try s.scanPage()
    #expect(page.width == 2592 && page.height == 1000)
    #expect(page.pixels.allSatisfy { $0 == 200 })
    #expect(try s.paperPresent() == false)        // ejected on RELEASE
}

@Test func simulatedMisfeedTimesOut() throws {
    let sim = SimulatedScanner()
    sim.paper = true
    sim.failNextFeed = true
    let s = IRIScanExpress4(transport: sim)
    #expect(throws: ScanError.self) { try s.scanPage(firstBandTimeout: 0.3) }
}

@Test func buttonDecoding() throws {
    let sim = SimulatedScanner()
    let s = IRIScanExpress4(transport: sim)
    #expect(try s.readButton() == nil)
    sim.pressButton()
    #expect(try s.readButton() == .short)
    #expect(try s.readButton() == nil)            // latched once
    sim.pressButton(long: true)
    #expect(try s.readButton() == .long)
}

@Test func sessionAutoLoadsAndSaves() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let sim = SimulatedScanner()
    sim.nextPage = SimulatedScanner.syntheticReceipt(heightPx: 900, tiltDegrees: 1)
    var settings = ScanSession.Settings()
    settings.folder = dir
    settings.autoLoadDelay = 0.3
    settings.pollInterval = 0.05

    let saved = Locked<[URL]>([])
    let session = ScanSession(settings: settings, logURL: nil, transport: { sim }) { e in
        if case .saved(let url, _, _, _, _) = e { saved.withLock { $0.append(url) } }
    }
    session.start()
    defer { session.stop() }
    try await Task.sleep(for: .milliseconds(200))
    sim.paper = true                                  // user inserts a receipt
    for _ in 0..<100 where saved.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(100)) }
    let urls = saved.withLock { $0 }
    #expect(urls.count == 1)
    #expect(urls.first.map { FileNamer.counter(of: $0.lastPathComponent) } == 1)
    #expect(urls.first.map { FileManager.default.fileExists(atPath: $0.path) } == true)
}

final class Locked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func withLock<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}

@Test func cutOffScanIsDetected() {
    let full = SimulatedScanner.syntheticReceipt(heightPx: 900, tiltDegrees: 1)
    #expect(ReceiptProcessor().process(full).cutOff == false)
    // Scanner stops half-way: keep only the first half of the raw rows.
    let half = GrayImage(width: full.width, height: full.height / 2,
                         pixels: Array(full.pixels[0..<(full.width * (full.height / 2))]))
    let r = ReceiptProcessor().process(half)
    #expect(r.cutOff == true)
}

@Test func longPressTogglesAutoScanAndButtonScans() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let sim = SimulatedScanner()
    sim.nextPage = SimulatedScanner.syntheticReceipt(heightPx: 700, tiltDegrees: 0.5)
    var settings = ScanSession.Settings()
    settings.folder = dir
    settings.autoLoadDelay = 0.2
    settings.pollInterval = 0.05
    let log = Locked<[String]>([])
    let session = ScanSession(settings: settings, logURL: nil, transport: { sim }) { e in
        switch e {
        case .autoScanChanged(let on): log.withLock { $0.append("auto:\(on)") }
        case .saved: log.withLock { $0.append("saved") }
        case .state(.paperWaiting): log.withLock { $0.append("waiting") }
        default: break
        }
    }
    session.start()
    defer { session.stop() }
    try await Task.sleep(for: .milliseconds(200))
    sim.pressButton(long: true)                       // auto-scan off
    try await Task.sleep(for: .milliseconds(300))
    sim.paper = true                                  // no countdown now
    try await Task.sleep(for: .milliseconds(800))
    #expect(log.withLock { $0 } == ["auto:false", "waiting"])
    sim.pressButton()                                 // short press scans
    for _ in 0..<80 where !log.withLock({ $0.contains("saved") }) { try await Task.sleep(for: .milliseconds(100)) }
    #expect(log.withLock { $0.contains("saved") })
    #expect(session.settings.autoScan == false)
}

/// Draws a few receipt-like text lines (upright) into a gray image.
func textReceipt() -> GrayImage {
    let w = 640, h = 900
    var img = GrayImage(width: w, height: h, fill: 255)
    img.pixels.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let lines = ["CORNER MARKET", "TARIH: 04/11/2026  SAAT: 13:53", "FIS NO: 0139", "Bread        24,50",
                     "Milk 1 L     38,90", "Coffee      190,00", "TOPKDV       23,64", "TOPLAM      260,00", "KREDI KART  260,00"]
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, 30, nil)
        for (i, line) in lines.enumerated() {
            let attr = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            ctx.textPosition = CGPoint(x: 30, y: CGFloat(h - 80 - i * 80))
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
    }
    return img
}

@Test func upsideDownReceiptIsDetected() {
    let upright = textReceipt()
    #expect(Orientation.isUpsideDown(upright) == false)
    #expect(Orientation.isUpsideDown(Orientation.rotated180(upright)) == true)
}

@Test func sidewaysReceiptIsDetected() {
    let upright = textReceipt()
    // A receipt fed sideways arrives turned a quarter; the fix is the opposite quarter turn.
    #expect(Orientation.bestTurn(Orientation.rotated90(upright, clockwise: true)) == .left)
    #expect(Orientation.bestTurn(Orientation.rotated90(upright, clockwise: false)) == .right)
    let back = Orientation.rotated90(Orientation.rotated90(upright, clockwise: true), clockwise: false)
    #expect(back.pixels == upright.pixels)
}
