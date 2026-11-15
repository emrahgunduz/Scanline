import Foundation
import Testing
@testable import ScanlineCore

@Test(arguments: [
    ("2026-11-15 0000001.jpg", 1),
    ("2026-11-15 0000123.JPG", 123),
    ("2026-11-15 10000000.jpg", 10_000_000),        // past seven digits
    ("2026-11-15 123.jpg", nil),                     // too short
    ("2026-11-15 000001.jpg", nil),
    ("2026-11-15 0000001.jpeg", nil),
    ("2026-11-15 0000001 (1).jpg", nil),             // Finder duplicate
    ("2026-11-15_0000001.jpg", nil),
    ("2026-11-15  0000001.jpg", nil),                // double space
    ("._2026-11-15 0000005.jpg", nil),               // AppleDouble on external volumes
    ("2026-1115-- 0000001.jpg", nil),                // dashes in the wrong places
    ("20261115-- 0000001.jpg", nil),
    ("2026-11-15 ٠٠٠٠٠٠١.jpg", nil),                 // Arabic-Indic digits
    ("2026-11-15 ０００００００１.jpg", nil),           // fullwidth digits
    ("２026-11-15 0000001.jpg", nil),
    ("2026-11-15 000000²1.jpg", nil),                // superscript
    ("2026-11-15 0000001.jpg.txt", nil),
    ("notes.jpg", nil),
    ("", nil),
] as [(String, Int?)])
func counterTable(name: String, expected: Int?) {
    #expect(FileNamer.counter(of: name) == expected)
}

private func folder(_ names: [String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("namer-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for n in names { try Data().write(to: dir.appendingPathComponent(n)) }
    return dir
}

private let day = Date(timeIntervalSince1970: 1_794_700_800)   // 2026-11-15 00:00 UTC

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
}

@Test func countersContinueFromTheHighestAndNeverFillGaps() throws {
    let dir = try folder(["2026-11-15 0000001.jpg", "2026-11-15 0000002.jpg", "2026-11-15 0000005.jpg", "2025-01-01 0000009.jpg"])
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(FileNamer.highestCounter(in: dir) == 9)                     // an older date still counts
    #expect(FileNamer.counter(of: FileNamer.nextURL(in: dir).lastPathComponent) == 10)
    #expect(FileNamer.highestCounter(in: dir.appendingPathComponent("missing")) == 0)
}

@Test func countersKeepGoingPastSevenDigits() throws {
    let dir = try folder(["2026-11-15 9999999.jpg", "2026-11-15 10000000.jpg"])
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(FileNamer.highestCounter(in: dir) == 10_000_000)
    #expect(FileNamer.nextURL(in: dir).lastPathComponent.hasSuffix(" 10000001.jpg"))
}

/// A listing that misses a file (a save racing the read): nextURL must still not overwrite it.
private final class HidingFileManager: FileManager, @unchecked Sendable {
    let hidden: String
    init(hiding: String) { hidden = hiding; super.init() }
    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        try super.contentsOfDirectory(atPath: path).filter { $0 != hidden }
    }
}

@Test func aNameTakenBehindTheListingsBackIsSkipped() throws {
    let now = Date()                                                    // one clock read: no midnight race
    let today = FileNamer.name(counter: 2, date: now)
    let dir = try folder(["2026-11-15 0000001.jpg", today])
    defer { try? FileManager.default.removeItem(at: dir) }
    let fm = HidingFileManager(hiding: today)
    #expect(FileNamer.counter(of: FileNamer.nextURL(in: dir, date: now, fileManager: fm).lastPathComponent) == 3)
}

@Test func namesUseTheGregorianYearWhateverTheMacsCalendar() {
    #expect(FileNamer.name(counter: 1, date: day, calendar: utc) == "2026-11-15 0000001.jpg")
    #expect(FileNamer.calendar.identifier == .gregorian)
    var japanese = Calendar(identifier: .japanese); japanese.timeZone = TimeZone(identifier: "UTC")!
    #expect(japanese.component(.year, from: day) == 8)                 // why the default isn't .current
}

@Test func theTimeZoneDecidesTheDate() {
    let lateUTC = day.addingTimeInterval(23.5 * 3600)                   // 23:30 UTC on the 15th
    var istanbul = Calendar(identifier: .gregorian); istanbul.timeZone = TimeZone(identifier: "Europe/Istanbul")!
    #expect(FileNamer.name(counter: 7, date: lateUTC, calendar: utc) == "2026-11-15 0000007.jpg")
    #expect(FileNamer.name(counter: 7, date: lateUTC, calendar: istanbul) == "2026-11-16 0000007.jpg")
}
