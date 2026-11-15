import AppKit
import Observation
import SwiftUI

/// Zoom state shared by the viewer and its controls / menu commands.
@MainActor @Observable
final class ZoomController {
    var fitMode = true
    var magnification: CGFloat = 1
    var fitOnNextImage = false
    @ObservationIgnored weak var scrollView: NSScrollView?

    var label: String { fitMode ? "Fit" : "\(Int((magnification * 100).rounded()))%" }

    func zoomIn() { set(magnification * 1.25) }
    func zoomOut() { set(magnification / 1.25) }
    func actualSize() { set(1) }

    func fit() {
        fitMode = true
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let inset: CGFloat = 28
        let avail = NSSize(width: max(40, sv.contentSize.width - inset * 2), height: max(40, sv.contentSize.height - inset * 2))
        let size = doc.frame.size
        guard size.width > 0, size.height > 0 else { return }
        let m = min(avail.width / size.width, avail.height / size.height, 4)
        sv.magnification = max(sv.minMagnification, m)
        magnification = sv.magnification
        centre()
    }

    private func set(_ m: CGFloat) {
        guard let sv = scrollView else { return }
        fitMode = false
        let clamped = min(max(m, sv.minMagnification), sv.maxMagnification)
        let centre = NSPoint(x: sv.contentView.bounds.midX, y: sv.contentView.bounds.midY)
        sv.setMagnification(clamped, centeredAt: centre)
        magnification = clamped
    }

    func centre() {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let clip = sv.contentView.bounds.size
        let x = (doc.frame.width - clip.width) / 2
        let y = doc.isFlipped ? 0 : doc.frame.height - clip.height
        sv.contentView.scroll(to: NSPoint(x: x, y: max(0, y)))
        sv.reflectScrolledClipView(sv.contentView)
    }
}

/// Centres the document when it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return r }
        if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if r.height > doc.frame.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }
}

/// The receipt: white paper with a soft shadow; drag to pan.
final class PaperView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    private var dragStart: NSPoint?
    private var originStart: NSPoint?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        NSGraphicsContext.current?.imageInterpolation = .high
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.white.setFill()
        bounds.fill()
        NSGraphicsContext.restoreGraphicsState()
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with e: NSEvent) {
        dragStart = e.locationInWindow
        originStart = enclosingScrollView?.contentView.bounds.origin
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with e: NSEvent) {
        guard let start = dragStart, let o = originStart, let sv = enclosingScrollView else { return }
        let m = sv.magnification
        let dx = (e.locationInWindow.x - start.x) / m
        let dy = (e.locationInWindow.y - start.y) / m
        sv.contentView.scroll(to: NSPoint(x: o.x - dx, y: o.y + dy))
        sv.reflectScrolledClipView(sv.contentView)
    }

    override func mouseUp(with e: NSEvent) {
        dragStart = nil
        NSCursor.pop()
    }
}

struct ReceiptViewer: NSViewRepresentable {
    let url: URL?
    var revision = 0
    let zoom: ZoomController

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.contentView = CenteringClipView()
        sv.drawsBackground = false
        sv.contentView.drawsBackground = false
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.allowsMagnification = true
        sv.minMagnification = 0.1
        sv.maxMagnification = 6
        sv.documentView = PaperView(frame: .zero)
        sv.postsFrameChangedNotifications = true
        context.coordinator.observe(sv)
        zoom.scrollView = sv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        zoom.scrollView = sv
        guard context.coordinator.shownURL != url || context.coordinator.shownRevision != revision else { return }
        context.coordinator.shownURL = url
        context.coordinator.shownRevision = revision
        let paper = sv.documentView as! PaperView
        if let url, let data = try? Data(contentsOf: url), let img = NSImage(data: data), let rep = img.representations.first {
            // 1:1 = one image pixel per point.
            let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            img.size = size
            paper.image = img
            paper.frame = NSRect(origin: .zero, size: size)
        } else {
            paper.image = nil
            paper.frame = .zero
        }
        DispatchQueue.main.async {
            if zoom.fitMode || zoom.fitOnNextImage { zoom.fitOnNextImage = false; zoom.fit() } else { zoom.centre() }
        }
    }

    /// Take exactly the space offered: never let the (tall) receipt size the window.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }

    func makeCoordinator() -> Coordinator { Coordinator(zoom: zoom) }

    @MainActor final class Coordinator: NSObject {
        let zoom: ZoomController
        var shownURL: URL??
        var shownRevision = -1
        init(zoom: ZoomController) { self.zoom = zoom }

        func observe(_ sv: NSScrollView) {
            NotificationCenter.default.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: sv)
            NotificationCenter.default.addObserver(self, selector: #selector(magnified), name: NSScrollView.didEndLiveMagnifyNotification, object: sv)
        }

        @objc func frameChanged() { if zoom.fitMode { zoom.fit() } }
        @objc func magnified(_ n: Notification) {
            guard let sv = n.object as? NSScrollView else { return }
            zoom.fitMode = false
            zoom.magnification = sv.magnification
        }
    }
}
