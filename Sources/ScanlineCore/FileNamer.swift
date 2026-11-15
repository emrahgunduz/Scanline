import Foundation

/// Output names: `YYYY-MM-DD NNNNNNN.jpg`. The counter continues from the highest number
/// already in the folder, regardless of date.
public struct FileNamer {
    public static let digits = 7

    /// Counter of a file name in our format, or nil.
    public static func counter(of name: String) -> Int? {
        // "2026-11-15 0000001.jpg"
        let parts = name.split(separator: " ")
        guard parts.count == 2, parts[0].count == 10,
              parts[0].allSatisfy({ $0.isNumber || $0 == "-" }) else { return nil }
        let tail = parts[1]
        guard tail.lowercased().hasSuffix(".jpg") else { return nil }
        let num = tail.dropLast(4)
        guard num.count == digits, num.allSatisfy(\.isNumber) else { return nil }
        return Int(num)
    }

    public static func highestCounter(in folder: URL, fileManager: FileManager = .default) -> Int {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap(counter(of:)).max() ?? 0
    }

    public static func name(counter: Int, date: Date, calendar: Calendar = .current) -> String {
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
