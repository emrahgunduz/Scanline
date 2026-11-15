import Foundation
import Testing
@testable import ScanlineCore

// The scan list's file operations, each in its own temp folder. Trash goes through a fake
// trasher, so tests never touch the real ~/.Trash.

private func tempFolder() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scanfolder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@discardableResult
private func touch(_ dir: URL, _ name: String, _ text: String = "x") throws -> URL {
    let url = dir.appendingPathComponent(name)
    try Data(text.utf8).write(to: url)
    return url
}

@Test(arguments: [
    ("new", "new.jpg"),                    // extension kept
    ("  spaced  ", "spaced.jpg"),          // trimmed
    ("Upper", "Upper.jpg"),
    ("receipt.png", "receipt.png"),        // an explicit extension is kept as typed
    ("v1.2 final", "v1.2 final.jpg"),      // "2 final" isn't an extension
])
func renameTargets(input: String, expected: String) throws {
    let url = URL(fileURLWithPath: "/tmp/x/2026-11-15 0000001.jpg")
    #expect(try ScanFolder.renameTarget(for: url, newName: input).lastPathComponent == expected)
}

@Test func renameKeepsAnUppercaseExtension() throws {
    let url = URL(fileURLWithPath: "/tmp/x/SCAN.JPG")
    #expect(try ScanFolder.renameTarget(for: url, newName: "a").lastPathComponent == "a.JPG")
}

@Test func renameRejectsBadNames() {
    let url = URL(fileURLWithPath: "/tmp/x/a.jpg")
    #expect(throws: ScanFolder.RenameError.empty) { try ScanFolder.renameTarget(for: url, newName: "  \n") }
    #expect(throws: ScanFolder.RenameError.invalid) { try ScanFolder.renameTarget(for: url, newName: "a/b") }
    #expect(throws: ScanFolder.RenameError.invalid) { try ScanFolder.renameTarget(for: url, newName: "a:b") }
    #expect(throws: ScanFolder.RenameError.hidden) { try ScanFolder.renameTarget(for: url, newName: ".secret") }
    #expect(throws: ScanFolder.RenameError.hidden) { try ScanFolder.renameTarget(for: url, newName: ".jpg") }
}

@Test func renameMovesAndRefusesToOverwrite() throws {
    let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
    let a = try touch(dir, "a.jpg", "A"), b = try touch(dir, "b.jpg", "B")
    #expect(throws: ScanFolder.RenameError.exists("b.jpg")) { try ScanFolder.rename(a, to: "b") }
    #expect(try String(contentsOf: b, encoding: .utf8) == "B")         // untouched
    #expect(try ScanFolder.rename(a, to: "a") == a)                      // same name: no move
    let c = try ScanFolder.rename(a, to: "c")
    #expect(c.lastPathComponent == "c.jpg")
    #expect(!FileManager.default.fileExists(atPath: a.path))
    #expect(try String(contentsOf: c, encoding: .utf8) == "A")
}

@Test func renameCanChangeOnlyTheCase() throws {
    let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
    let a = try touch(dir, "receipt.jpg")
    let upper = try ScanFolder.rename(a, to: "Receipt")
    #expect(upper.lastPathComponent == "Receipt.jpg")
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(names == ["Receipt.jpg"])
}

@Test func aTooLongNameFailsAndKeepsTheFile() throws {
    let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
    let a = try touch(dir, "a.jpg")
    #expect(throws: (any Error).self) { try ScanFolder.rename(a, to: String(repeating: "x", count: 300)) }
    #expect(FileManager.default.fileExists(atPath: a.path))
}

@Test func trashAndRestoreWithAFakeTrash() throws {
    let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
    let bin = dir.appendingPathComponent(".bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let a = try touch(dir, "a.jpg", "A")
    let trashed = try #require(try ScanFolder.trash(a) { url in
        let dest = bin.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: dest)
        return dest
    })
    #expect(!FileManager.default.fileExists(atPath: a.path))
    try ScanFolder.restore(from: trashed, to: a)
    #expect(try String(contentsOf: a, encoding: .utf8) == "A")
}

@Test func restoreNeverOverwrites() throws {
    let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
    let trashed = try touch(dir, "old.jpg", "OLD")
    let taken = try touch(dir, "a.jpg", "NEW")                           // a new scan took the name
    #expect(throws: (any Error).self) { try ScanFolder.restore(from: trashed, to: taken) }
    #expect(try String(contentsOf: taken, encoding: .utf8) == "NEW")
    #expect(throws: (any Error).self) { try ScanFolder.restore(from: dir.appendingPathComponent("gone.jpg"), to: dir.appendingPathComponent("x.jpg")) }
}

@Test func listFiltersAndSortsNewestFirst() throws {
    let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
    let fm = FileManager.default
    let old = try touch(dir, "old.jpg"), new = try touch(dir, "new.PNG"), tie = try touch(dir, "zz.jpeg")
    try touch(dir, "notes.txt"); try touch(dir, ".hidden.jpg"); try touch(dir, "._2026-11-15 0000001.jpg")
    try fm.createDirectory(at: dir.appendingPathComponent("folder.jpg"), withIntermediateDirectories: true)
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    try fm.setAttributes([.creationDate: t], ofItemAtPath: old.path)
    try fm.setAttributes([.creationDate: t.addingTimeInterval(100)], ofItemAtPath: new.path)
    try fm.setAttributes([.creationDate: t], ofItemAtPath: tie.path)
    let names = ScanFolder.list(dir).map(\.name)
    #expect(names == ["new.PNG", "zz.jpeg", "old.jpg"])                  // same date: name descending
    #expect(ScanFolder.list(dir.appendingPathComponent("missing")).isEmpty)
}

@Test func listReusesKnownPixelHeights() throws {
    let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
    let a = try touch(dir, "a.jpg", "not really a jpeg")
    let first = try #require(ScanFolder.list(dir).first)
    #expect(first.pixelHeight == 0)
    var known = first; known.pixelHeight = 1234
    #expect(ScanFolder.list(dir, previous: [first.url: known]).first?.pixelHeight == 1234)   // same size: reused
    try Data("a different size".utf8).write(to: a)
    #expect(ScanFolder.list(dir, previous: [first.url: known]).first?.pixelHeight == 0)      // changed: re-read
}

@Test func rotateTurnsTheImageAndKeepsItsPlace() throws {
    let dir = try tempFolder(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("r.jpg")
    var img = GrayImage(width: 30, height: 20, fill: 255)
    for y in 0..<20 { for x in 0..<5 { img[x, y] = 0 } }                 // dark band on the left
    try img.writeJPEG(url)
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: url.path)
    try ScanFolder.rotate(url, .right)
    let out = try #require(GrayImage.read(url))
    #expect(out.width == 20 && out.height == 30)
    #expect(out[10, 1] < 64 && out[10, 28] > 192)                         // the band is now on top
    let after = try FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date
    #expect(after == created)
    #expect(throws: (any Error).self) { try ScanFolder.rotate(dir.appendingPathComponent("missing.jpg"), .left) }
}

@Test func metaIsFormattedForTheGivenLocale() {
    let f = ScanFile(url: URL(fileURLWithPath: "/x/a.jpg"), date: Date(timeIntervalSince1970: 0), bytes: 481_000, pixelHeight: 600)
    let text = f.meta(locale: Locale(identifier: "en_US_POSIX"), timeZone: TimeZone(identifier: "UTC")!)
        .replacingOccurrences(of: "\u{202F}", with: " ")
    #expect(text.hasPrefix("1/1/70"))
    #expect(text.contains("2.0 in"))
    #expect(text.hasSuffix("481 KB"))
    let noHeight = ScanFile(url: f.url, date: f.date, bytes: 10, pixelHeight: 0).meta(locale: Locale(identifier: "en_US_POSIX"))
    #expect(!noHeight.contains(" in "))
}
