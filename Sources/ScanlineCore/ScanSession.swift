import Foundation

/// What the session is doing, for the UI.
public enum SessionState: Sendable, Equatable {
    case disconnected(String)
    case idle                                   // ready, no paper
    case countdown(seconds: Double)             // paper in, scan starts soon
    case paperWaiting                           // paper in, auto-scan off: waiting for the button
    case scanning(lines: Int)
    case processing
    case removePaper(String)                    // sheet still in the feeder; take it out
}

public enum ProblemKind: String, Sendable {
    case misfeed        // rollers did not take the sheet / data stopped
    case cutOff         // scanner ended the page mid-receipt
    case noReceipt      // scan holds no receipt
    case sheetLeft      // sheet still in the feeder after a scan
    case noPaper        // scan asked for with an empty feeder
    case noFolder
    case error
    /// The scan failed and nothing was saved.
    public var isScanFailure: Bool { [.misfeed, .cutOff, .noReceipt].contains(self) }
}

public enum SessionEvent: Sendable {
    case state(SessionState)
    case saved(url: URL, image: GrayImage, inches: Double, skewDegrees: Double, note: String)
    case problem(ProblemKind, String)            // shown to the user
    case autoScanChanged(Bool)                   // long press on the scanner button
}

/// Runs the scanner on its own thread: polls paper and button, auto-loads after a delay,
/// scans, processes and saves. Never interrupts the bridge mid-command (stops between steps).
public final class ScanSession: @unchecked Sendable {
    public typealias TransportFactory = @Sendable () throws -> ScannerTransport

    public struct Settings: Sendable {
        public var folder: URL?
        public var autoScan = true
        public var autoLoadDelay: TimeInterval = 2
        public var pollInterval: TimeInterval = 0.25
        public var processor = ReceiptProcessor.Options()
        public var jpegQuality: Double = 0.85
        public init() {}
    }

    private let makeTransport: TransportFactory
    private let onEvent: @Sendable (SessionEvent) -> Void
    private let lock = NSLock()
    private var _settings: Settings
    private var scanNowRequested = false
    private var running = false
    private var thread: Thread?
    private let logURL: URL?

    public init(settings: Settings, logURL: URL? = ScanSession.defaultLogURL,
                transport: @escaping TransportFactory,
                onEvent: @escaping @Sendable (SessionEvent) -> Void) {
        _settings = settings
        makeTransport = transport
        self.onEvent = onEvent
        self.logURL = logURL
    }

    public static var defaultLogURL: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Scanline/scan.log")
    }

    public var settings: Settings {
        get { lock.withLock { _settings } }
        set { lock.withLock { _settings = newValue } }
    }

    public func scanNow() { lock.withLock { scanNowRequested = true } }

    public func start() {
        lock.withLock {
            guard !running else { return }
            running = true
            let t = Thread { [weak self] in self?.run() }
            t.name = "ScanSession"
            thread = t
            t.start()
        }
    }

    /// Stops after the current step; the transport is closed on the worker thread.
    public func stop() { lock.withLock { running = false } }

    private var isRunning: Bool { lock.withLock { running } }
    private func takeScanNow() -> Bool { lock.withLock { defer { scanNowRequested = false }; return scanNowRequested } }

    // MARK: worker

    private enum Phase { case idle, countdown(until: Date), removal(String) }

    private func run() {
        var transport: ScannerTransport?
        var scanner: IRIScanExpress4?
        var phase = Phase.idle
        var lastState: SessionState?

        func emit(_ s: SessionState) {
            if s != lastState { lastState = s; onEvent(.state(s)) }
        }
        var lastWhy: String?
        func disconnect(_ why: String) {
            transport?.close(); transport = nil; scanner = nil
            if why != lastWhy { lastWhy = why; log("not connected: \(why)") }
            emit(.disconnected(why))
        }

        while isRunning {
            if scanner == nil {
                do {
                    let t = try makeTransport()
                    let s = IRIScanExpress4(transport: t)
                    _ = try s.identify()
                    transport = t; scanner = s; phase = .idle; lastWhy = nil
                    log("connected")
                } catch {
                    disconnect("\(error)")
                    sleep(2)
                    continue
                }
            }
            guard let s = scanner else { continue }
            let cfg = settings

            do {
                let paper = try s.paperPresent()
                let button = try s.readButton()
                let wantScan = takeScanNow() || button == .short
                if button == .long {
                    var updated = settings
                    updated.autoScan.toggle()
                    settings = updated
                    log("button: long press -> auto-scan \(updated.autoScan ? "on" : "off")")
                    onEvent(.autoScanChanged(updated.autoScan))
                }
                let auto = settings.autoScan

                switch phase {
                case .idle:
                    if paper {
                        if wantScan { phase = try scan(s, cfg, emit: emit) }
                        else if auto { phase = .countdown(until: Date().addingTimeInterval(cfg.autoLoadDelay)) }
                        else { emit(.paperWaiting) }
                    } else {
                        if wantScan { onEvent(.problem(.noPaper, "No paper in the feeder.")) }
                        emit(.idle)
                    }
                case .countdown(let until):
                    if !paper { phase = .idle; emit(.idle) }
                    else if !auto && !wantScan { phase = .idle; emit(.paperWaiting) }
                    else if wantScan || Date() >= until { phase = try scan(s, cfg, emit: emit) }
                    else { emit(.countdown(seconds: max(0, until.timeIntervalSinceNow).rounded(.up))) }
                case .removal(let why):
                    if !paper { phase = .idle; emit(.idle) } else { emit(.removePaper(why)) }
                }
            } catch {
                log("error: \(error)")
                onEvent(.problem(.error, "Scanner error: \(error)"))
                disconnect("\(error)")
                sleep(1)
                continue
            }
            Thread.sleep(forTimeInterval: cfg.pollInterval)
        }
        transport?.close()
    }

    /// One scan → process → save. Returns the next phase.
    private func scan(_ s: IRIScanExpress4, _ cfg: Settings, emit: (SessionState) -> Void) throws -> Phase {
        guard let folder = cfg.folder else {
            onEvent(.problem(.noFolder, "Choose a folder first."))
            return .removal("Choose a folder, then insert the sheet again.")
        }
        emit(.scanning(lines: 0))
        let page: IRIScanExpress4.Page
        do {
            page = try withoutActuallyEscaping(emit) { e in try s.scanPage { e(.scanning(lines: $0)) } }
        } catch ScanError.timeout(let why) {
            // Misfeed: rollers did not take the sheet (or stopped).
            try? s.waitReady(timeout: 15)
            let still = (try? s.paperPresent()) ?? false
            log("MISFEED timeout: \(why); paper still in: \(still)")
            onEvent(.problem(.misfeed, "The scanner did not feed the receipt (\(why)). \(still ? "Take it out and insert it again." : "Insert it again.")"))
            return still ? .removal("The scanner did not take the sheet.") : .idle
        }
        try s.waitReady(timeout: 30)
        let paperAfter = try s.paperPresent()

        emit(.processing)
        let result = ReceiptProcessor(options: cfg.processor).process(page.gray)
        let inches = Double(result.image.height) / 300
        var diag = String(format: "raw %dx%d, first band %.2fs, scan %.1fs, out %dx%d (%.1f in), skew %.2f°, paper after: %@",
                          page.width, page.height, page.firstBandAfter, page.duration,
                          result.image.width, result.image.height, inches, result.skewDegrees, paperAfter ? "yes" : "no")

        if !result.paperFound || result.image.height < 150 {
            log("MISFEED no receipt in image: \(diag)")
            onEvent(.problem(.noReceipt, "No receipt was found in the scan. Insert it again."))
            return paperAfter ? .removal("No receipt was found in the scan.") : .idle
        }

        if result.cutOff {
            log("MISFEED cut off: \(diag)")
            onEvent(.problem(.cutOff, "Nothing was saved. The receipt may be stuck in the scanner: pull it out, then insert it again."))
            return paperAfter ? .removal("The scan stopped before the end of the receipt.") : .idle
        }

        let url = FileNamer.nextURL(in: folder)
        try result.image.writeJPEG(url, quality: cfg.jpegQuality)
        diag += (result.turnedUpright ? ", turn \(result.turn.rawValue)" : "") + " -> \(url.lastPathComponent)"
        log("saved: \(diag)")
        var note = String(format: "%.1f in long, straightened %.1f°", inches, abs(result.skewDegrees))
        switch result.turn {
        case .upsideDown: note += ", turned upright"
        case .left, .right: note += ", turned from sideways"
        case .none: break
        }
        if paperAfter { note += ". Sheet still in feeder?" }
        onEvent(.saved(url: url, image: result.image, inches: inches, skewDegrees: result.skewDegrees, note: note))
        if paperAfter {
            log("WARN paper still present after scan")
            onEvent(.problem(.sheetLeft, "The sheet seems to still be in the feeder. Take it out."))
            return .removal("The sheet is still in the feeder.")
        }
        return .idle
    }

    private func log(_ line: String) {
        guard let url = logURL else { return }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let data = Data("\(f.string(from: Date())) \(line)\n".utf8)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
