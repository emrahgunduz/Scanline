import AppKit
import Observation
import ScanlineCore

/// Live, newest-first list of the images in a folder, with rename and trash/undo.
@MainActor @Observable
final class FolderLibrary {
    private(set) var files: [ScanFile] = []
    private(set) var folder: URL?
    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var thumbs: [URL: NSImage] = [:]
    @ObservationIgnored private var reloadPending = false

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
        files = ScanFolder.list(folder, previous: Dictionary(uniqueKeysWithValues: files.map { ($0.url, $0) }))
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

    /// Renames, keeping the original extension when the new name has none. Returns the new URL.
    @discardableResult
    func rename(_ file: ScanFile, to newName: String) throws -> URL {
        let target = try ScanFolder.rename(file.url, to: newName)
        if target != file.url { thumbs[target] = thumbs.removeValue(forKey: file.url) }
        reload()
        return target
    }

    /// Moves to the Trash; returns where it went (for Undo).
    func trash(_ file: ScanFile) throws -> URL? {
        let resulting = try ScanFolder.trash(file.url)
        thumbs[file.url] = nil
        reload()
        return resulting
    }

    /// Turns an image in place (for receipts saved upside down or sideways).
    func rotate(_ file: ScanFile, _ turn: Orientation.Turn) throws {
        try ScanFolder.rotate(file.url, turn)
        thumbs[file.url] = nil
        reload()
    }

    func restore(from trashed: URL, to original: URL) throws {
        try ScanFolder.restore(from: trashed, to: original)
        reload()
    }
}
