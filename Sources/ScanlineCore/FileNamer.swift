import Foundation

/// Output names: `YYYY-MM-DD NNNNNNN.jpg`. The counter continues from the highest number
/// already in the folder, regardless of date.
public struct FileNamer {
    public static let digits = 7

    /// Counter of a file name in our format, or nil. The counter has at least 7 digits
    /// (it grows past 9,999,999); the date part is `dddd-dd-dd`. ASCII digits only.
    public static func counter(of name: String) -> Int? {
        // "2026-11-15 0000001.jpg"
        let parts = name.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let date = Array(parts[0].utf8)
        guard date.count == 10 else { return nil }
        for (i, c) in date.enumerated() {
            if i == 4 || i == 7 { guard c == UInt8(ascii: "-") else { return nil } }
            else { guard isDigit(c) else { return nil } }
        }
        let tail = parts[1]
        guard tail.lowercased().hasSuffix(".jpg") else { return nil }
        let num = Array(tail.dropLast(4).utf8)
        guard num.count >= digits, num.count <= 18, num.allSatisfy(isDigit) else { return nil }
        return Int(String(decoding: num, as: UTF8.self))
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }

    /// The calendar names use: Gregorian whatever the Mac's calendar (a Japanese or Buddhist
    /// calendar would otherwise give year 8 or 2569), in the current time zone.
    public static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    public static func highestCounter(in folder: URL, fileManager: FileManager = .default) -> Int {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap(counter(of:)).max() ?? 0
    }

    public static func name(counter: Int, date: Date, calendar: Calendar = FileNamer.calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d %07d.jpg", c.year!, c.month!, c.day!, counter)
    }

    /// Next free URL in `folder` for a scan made at `date`.
    public static func nextURL(in folder: URL, date: Date = Date(), fileManager: FileManager = .default) -> URL {
        var n = highestCounter(in: folder, fileManager: fileManager) + 1
        while true {
            let url = folder.appendingPathComponent(name(counter: n, date: date))
            if !fileManager.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }
}
