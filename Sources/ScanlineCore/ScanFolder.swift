import Foundation
import ImageIO

/// One image file in the output folder.
public struct ScanFile: Identifiable, Hashable, Sendable {
    public var url: URL
    public var id: URL { url }
    public var name: String { url.lastPathComponent }
    public var date: Date
    public var bytes: Int
    public var pixelHeight: Int
    public var inches: Double { Double(pixelHeight) / 300 }

    public init(url: URL, date: Date, bytes: Int, pixelHeight: Int) {
        self.url = url; self.date = date; self.bytes = bytes; self.pixelHeight = pixelHeight
    }

    /// "Today, 08:45 · 8.3 in · 481 KB"
    public var meta: String { meta() }

    public func meta(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        var parts = [f.string(from: date)]
        if pixelHeight > 0 { parts.append(String(format: "%.1f in", locale: Locale(identifier: "en_US_POSIX"), inches)) }
        let bytesFormatter = ByteCountFormatter()
        bytesFormatter.countStyle = .file
        parts.append(bytesFormatter.string(fromByteCount: Int64(bytes)))
        return parts.joined(separator: " · ")
    }
}

/// The file operations behind the scan list: listing, rename, trash/restore, rotate.
/// Pure Foundation, so it is tested directly; the app's FolderLibrary watches and caches.
public enum ScanFolder {
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff"]

    /// Newest first (by creation date, then name). `previous` reuses pixel heights of files
    /// whose size hasn't changed, so a reload doesn't re-read every image.
    public static func list(_ folder: URL, previous: [URL: ScanFile] = [:], fileManager: FileManager = .default) -> [ScanFile] {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles])) ?? []
        var list: [ScanFile] = []
        for u in urls where imageExtensions.contains(u.pathExtension.lowercased()) {
            let v = try? u.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true else { continue }
            let date = v?.creationDate ?? v?.contentModificationDate ?? .distantPast
            let bytes = v?.fileSize ?? 0
            let h: Int
            if let o = previous[u], o.bytes == bytes { h = o.pixelHeight } else { h = pixelHeight(u) }
            list.append(ScanFile(url: u, date: date, bytes: bytes, pixelHeight: h))
        }
        list.sort { $0.date != $1.date ? $0.date > $1.date : $0.name > $1.name }
        return list
    }

    public static func pixelHeight(_ url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return 0 }
        return p[kCGImagePropertyPixelHeight] as? Int ?? 0
    }

    public enum RenameError: LocalizedError, Equatable {
        case empty, exists(String), invalid, hidden
        public var errorDescription: String? {
            switch self {
            case .empty: "The name can't be empty."
            case .exists(let n): "“\(n)” already exists in this folder."
            case .invalid: "Names can't contain “/” or “:”."
            case .hidden: "Names can't start with a dot; the file would be hidden."
            }
        }
    }

    /// Where a rename would put the file. Keeps the original extension when the new name has none.
    public static func renameTarget(for url: URL, newName: String) throws -> URL {
        var name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RenameError.empty }
        guard !name.contains("/"), !name.contains(":") else { throw RenameError.invalid }
        // A leading dot hides the file (and ".jpg" alone has no extension): it would vanish from the list.
        guard !name.hasPrefix(".") else { throw RenameError.hidden }
        if (name as NSString).pathExtension.isEmpty { name += "." + url.pathExtension }
        return url.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// Renames; returns the new URL. A change of case only ("a.jpg" → "A.jpg") is allowed.
    @discardableResult
    public static func rename(_ url: URL, to newName: String, fileManager: FileManager = .default) throws -> URL {
        let target = try renameTarget(for: url, newName: newName)
        if target.lastPathComponent == url.lastPathComponent { return url }
        if fileManager.fileExists(atPath: target.path), !sameFile(url, target) {
            throw RenameError.exists(target.lastPathComponent)
        }
        try fileManager.moveItem(at: url, to: target)
        return target
    }

    /// True when both paths name the same file (e.g. differ only in case on a case-insensitive volume).
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        guard let ia = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let ib = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else { return false }
        return ia.isEqual(ib)
    }

    public typealias Trasher = @Sendable (URL) throws -> URL?

    /// The system Trash; returns where the file went.
    public static let systemTrash: Trasher = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// Moves to the Trash; returns where it went (for Undo).
    public static func trash(_ url: URL, trasher: Trasher = systemTrash) throws -> URL? {
        try trasher(url)
    }

    /// Puts a trashed file back. Never overwrites: fails if something now has its name.
    public static func restore(from trashed: URL, to original: URL, fileManager: FileManager = .default) throws {
        try fileManager.moveItem(at: trashed, to: original)
    }

    /// Turns an image in place, keeping its creation date (its place in the newest-first list).
    public static func rotate(_ url: URL, _ turn: Orientation.Turn, fileManager: FileManager = .default) throws {
        guard let img = GrayImage.read(url) else { throw CocoaError(.fileReadCorruptFile) }
        let created = (try? fileManager.attributesOfItem(atPath: url.path))?[.creationDate]
        try turn.apply(img).writeJPEG(url)
        if let created { try? fileManager.setAttributes([.creationDate: created], ofItemAtPath: url.path) }
    }
}
