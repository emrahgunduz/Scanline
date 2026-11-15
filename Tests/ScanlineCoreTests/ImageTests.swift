import Foundation
import Testing
@testable import ScanlineCore

// Exact-pixel tests on tiny images (no Vision), plus the real scanner pages when present.

private let tiny = GrayImage(width: 3, height: 2, pixels: [0, 1, 2,
                                                          3, 4, 5])

@Test func quarterTurnsAreExact() {
    let cw = Orientation.Turn.right.apply(tiny)
    #expect(cw.width == 2 && cw.height == 3)
    #expect(cw.pixels == [3, 0,
                          4, 1,
                          5, 2])
    let ccw = Orientation.Turn.left.apply(tiny)
    #expect(ccw.pixels == [2, 5,
                           1, 4,
                           0, 3])
    #expect(Orientation.Turn.upsideDown.apply(tiny).pixels == [5, 4, 3, 2, 1, 0])
    #expect(Orientation.Turn.none.apply(tiny).pixels == tiny.pixels)
}

@Test func turnsUndoEachOther() {
    let r = Orientation.Turn.right, l = Orientation.Turn.left, u = Orientation.Turn.upsideDown
    #expect(l.apply(r.apply(tiny)).pixels == tiny.pixels)
    #expect(u.apply(u.apply(tiny)).pixels == tiny.pixels)
    #expect(r.apply(r.apply(tiny)).pixels == u.apply(tiny).pixels)
    var t = tiny; for _ in 0..<4 { t = r.apply(t) }
    #expect(t.pixels == tiny.pixels && t.width == 3)
}

@Test func downscaleKeepsAspectAndSmallImages() {
    #expect(Orientation.downscale(tiny, maxSide: 10).pixels == tiny.pixels)
    let big = GrayImage(width: 400, height: 100, fill: 9)
    let s = Orientation.downscale(big, maxSide: 100)
    #expect(s.width == 100 && s.height == 25)
    #expect(s.pixels.allSatisfy { $0 == 9 })
}

/// A dark background with a paper-wide light band over rows `paper`.
private func page(width: Int = 200, height: Int = 60, paper: Range<Int>, left: Int = 40, right: Int = 160) -> GrayImage {
    var img = GrayImage(width: width, height: height, fill: 10)
    for y in paper { for x in left..<right { img[x, y] = 220 } }
    return img
}

@Test func edgesFindThePaperOrNothing() {
    let img = page(paper: 0..<60)
    let e = ReceiptProcessor.edges(img, row: 5, threshold: 100)
    #expect(e?.0 == 40 && e?.1 == 159)
    #expect(ReceiptProcessor.edges(page(paper: 0..<60, left: 90, right: 120), row: 5, threshold: 100) == nil)  // too narrow
    #expect(ReceiptProcessor.edges(GrayImage(width: 200, height: 1, fill: 10), row: 0, threshold: 100) == nil)
}

@Test func paperRunningOffTheBottomMeansCutOff() {
    #expect(ReceiptProcessor.paperAtBottom(page(paper: 5..<60), threshold: 100))        // paper to the last row
    #expect(!ReceiptProcessor.paperAtBottom(page(paper: 5..<50), threshold: 100))       // background after it
    #expect(ReceiptProcessor.paperAtBottom(page(paper: 5..<58), threshold: 100))        // within the last 4 rows
    #expect(!ReceiptProcessor.paperAtBottom(page(paper: 5..<56), threshold: 100))
    #expect(!ReceiptProcessor.paperAtBottom(page(height: 3, paper: 0..<3), threshold: 100))  // too short to tell
}

@Test func pgmAndJPEGRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("img-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let pgm = dir.appendingPathComponent("t.pgm")
    try tiny.writePGM(pgm)
    let back = try GrayImage.readPGM(pgm)
    #expect(back.width == 3 && back.height == 2 && back.pixels == tiny.pixels)
    let flat = GrayImage(width: 16, height: 8, fill: 200)
    let jpg = dir.appendingPathComponent("t.jpg")
    try flat.writeJPEG(jpg)
    let j = try #require(GrayImage.read(jpg))
    #expect(j.width == 16 && j.height == 8)
    #expect(j.pixels.allSatisfy { abs(Int($0) - 200) <= 2 })
    #expect(ScanFolder.pixelHeight(jpg) == 8)
}

// MARK: Real pages (this Mac only; the traces hold real receipts and are never committed)

private let traces = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("_private/traces")

@Test(.enabled(if: FileManager.default.fileExists(atPath: traces.appendingPathComponent("usb1_cut.pgm").path)))
func realPagesAreCroppedAndCutOffsDetected() throws {
    var options = ReceiptProcessor.Options(); options.autoOrient = false
    let p = ReceiptProcessor(options: options)
    let cut = p.process(try GrayImage.readPGM(traces.appendingPathComponent("usb1_cut.pgm")))
    #expect(cut.paperFound)
    #expect(cut.cutOff)
    let full = p.process(try GrayImage.readPGM(traces.appendingPathComponent("usb1.pgm")))
    #expect(full.paperFound)
    #expect(!full.cutOff)
    #expect(abs(full.skewDegrees) < 5)
    #expect(full.image.width > 400 && full.image.width < 1000)          // an 80 mm roll at 300 dpi is ~900 px
}
