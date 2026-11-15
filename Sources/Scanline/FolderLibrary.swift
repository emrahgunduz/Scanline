import AppKit
import ImageIO
import Observation
import ScanlineCore

/// One image file in the output folder.
struct ScanFile: Identifiable, Hashable {
    var url: URL
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var date: Date
    var bytes: Int
    var pixelHeight: Int
    var inches: Double { Double(pixelHeight) / 300 }

    var meta: String {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        var parts = [f.string(from: date)]
        if pixelHeight > 0 { parts.append(String(format: "%.1f in", inches)) }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        return parts.joined(separator: " · ")
    }
}

/// Live, newest-first list of the images in a folder, with rename and trash/undo.
@MainActor @Observable
final class FolderLibrary {
    private(set) var files: [ScanFile] = []
    private(set) var folder: URL?
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var thumbs: [URL: NSImage] = [:]
    @ObservationIgnored private var reloadPending = false
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff"]

    func watch(_ url: URL?) {
        source?.cancel()
        source = nil
        folder = url
        thumbs = [:]
        reload()
        guard let url else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                            queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func scheduleReload() {
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                self?.reloadPending = false
                self?.reload()
            }
        }
    }

    func reload() {
        guard let folder else { files = []; return }
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        let old = Dictionary(uniqueKeysWithValues: files.map { ($0.url, $0) })
        var list: [ScanFile] = []
        for u in urls where Self.imageExtensions.contains(u.pathExtension.lowercased()) {
            let v = try? u.resourceValues(forKeys: Set(keys))
            guard v?.isRegularFile == true else { continue }
            let date = v?.creationDate ?? v?.contentModificationDate ?? .distantPast
            let bytes = v?.fileSize ?? 0
            let h: Int
            if let o = old[u], o.bytes == bytes { h = o.pixelHeight } else { h = Self.pixelHeight(u) }
            list.append(ScanFile(url: u, date: date, bytes: bytes, pixelHeight: h))
        }
        list.sort { $0.date != $1.date ? $0.date > $1.date : $0.name > $1.name }
        files = list
    }

    static func pixelHeight(_ url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return 0 }
        return p[kCGImagePropertyPixelHeight] as? Int ?? 0
    }

    func thumbnail(_ file: ScanFile) -> NSImage? {
        if let t = thumbs[file.url] { return t }
        guard let src = CGImageSourceCreateWithURL(file.url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 160,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbs[file.url] = img
        return img
    }

    enum RenameError: LocalizedError {
        case empty, exists(String), invalid
        var errorDescription: String? {
            switch self {
            case .empty: "The name can't be empty."
            case .exists(let n): "“\(n)” already exists in this folder."
            case .invalid: "Names can't contain “/” or “:”."
            }
        }
    }

    /// Renames, keeping the original extension when the new name has none. Returns the new URL.
    @discardableResult
    func rename(_ file: ScanFile, to newName: String) throws -> URL {
        var name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RenameError.empty }
        guard !name.contains("/"), !name.contains(":") else { throw RenameError.invalid }
        if (name as NSString).pathExtension.isEmpty { name += "." + file.url.pathExtension }
        let target = file.url.deletingLastPathComponent().appendingPathComponent(name)
        if target == file.url { return target }
        guard !FileManager.default.fileExists(atPath: target.path) else { throw RenameError.exists(name) }
        try FileManager.default.moveItem(at: file.url, to: target)
        thumbs[target] = thumbs.removeValue(forKey: file.url)
        reload()
        return target
    }

    /// Moves to the Trash; returns where it went (for Undo).
    func trash(_ file: ScanFile) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: file.url, resultingItemURL: &resulting)
        thumbs[file.url] = nil
        reload()
        return resulting as URL?
    }

    /// Turns an image in place (for receipts saved upside down or sideways).
    func rotate(_ file: ScanFile, _ turn: Orientation.Turn) throws {
        guard let img = GrayImage.read(file.url) else { throw CocoaError(.fileReadCorruptFile) }
        let created = (try? FileManager.default.attributesOfItem(atPath: file.url.path))?[.creationDate]
        try turn.apply(img).writeJPEG(file.url)
        // Keep the scan's place in the newest-first list.
        if let created { try? FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: file.url.path) }
        thumbs[file.url] = nil
        reload()
    }

    func restore(from trashed: URL, to original: URL) throws {
        try FileManager.default.moveItem(at: trashed, to: original)
        reload()
    }
}
