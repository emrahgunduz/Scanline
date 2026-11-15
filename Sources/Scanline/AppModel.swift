import AppKit
import IOKit
import Observation
import ScanlineCore
import SwiftUI

/// What the activity card shows.
struct Activity: Equatable {
    enum Icon: Equatable { case ring(Int), symbol(String) }
    var title: String
    var detail: String
    var color: UInt32
    var icon: Icon
    /// 0 none, 1 Paper, 2 Feed, 3 Scan, 4 Clean up, 5 Saved (all done)
    var step: Int
    var busy = false
    var failedStep: Int? = nil
    var showButtonHint = false
}

enum DeviceAccess: Equatable { case helper, vendorDriver, simulator, none }

@MainActor @Observable
final class AppModel {
    // Settings (persisted)
    var folder: URL? { didSet { persist(); library.watch(folder); pushSettings() } }
    var autoScan: Bool { didSet { persist(); pushSettings() } }
    var autoScanDelay: Double { didSet { persist(); pushSettings() } }
    var appearance: Appearance { didSet { persist(); applyAppearance() } }

    // Live state
    var state: SessionState = .disconnected("Starting…")
    var outcome: Outcome?
    var selection: URL?
    var renaming: URL?
    var undo: (trashed: URL, original: URL)?
    var errorMessage: String?
    /// Bumped when the selected image changes on disk (forces the viewer to reload).
    var imageRevision = 0
    /// Name the scan in progress will get (fixed when it starts).
    var scanningName: String?
    private(set) var access: DeviceAccess = .none
    let library = FolderLibrary()
    let zoom = ZoomController()
    let simulator: SimulatedScanner?

    enum Outcome: Equatable {
        case saved(name: String, inches: Double, skew: Double)
        case problem(ProblemKind, String)
    }

    @ObservationIgnored private var session: ScanSession?
    private let defaults = UserDefaults.standard
    /// Simulator and folder-override runs (tests, screenshots) never write the user's settings.
    @ObservationIgnored private let persistent: Bool

    init() {
        let env = ProcessInfo.processInfo.environment
        persistent = env["SCANLINE_SIMULATE"] != "1" && env["SCANLINE_FOLDER"] == nil
        simulator = env["SCANLINE_SIMULATE"] == "1" ? SimulatedScanner() : nil
        folder = defaults.string(forKey: "folder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let override = ProcessInfo.processInfo.environment["SCANLINE_FOLDER"] {
            folder = URL(fileURLWithPath: override, isDirectory: true)   // testing: not persisted
        }
        simulator?.bandDelay = 0.17
        autoScan = defaults.object(forKey: "autoScan") as? Bool ?? true
        autoScanDelay = defaults.object(forKey: "autoScanDelay") as? Double ?? 2
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        library.watch(folder)
        selection = library.files.first?.url
        applyAppearance()
        startSession()
    }

    private func persist() {
        guard persistent else { return }
        defaults.set(folder?.path, forKey: "folder")
        defaults.set(autoScan, forKey: "autoScan")
        defaults.set(autoScanDelay, forKey: "autoScanDelay")
        defaults.set(appearance.rawValue, forKey: "appearance")
    }

    func applyAppearance() { NSApp?.appearance = appearance.nsAppearance }

    // MARK: Session

    func startSession() {
        session?.stop()
        var s = ScanSession.Settings()
        s.folder = folder
        s.autoScan = autoScan
        s.autoLoadDelay = autoScanDelay
        let sim = simulator
        let helperInstalled = ScanlineHelper.isInstalled
        access = sim != nil ? .simulator : helperInstalled ? .helper : Self.vendorDriverLoaded() ? .vendorDriver : .none
        let mode = access
        let session = ScanSession(settings: s, transport: {
            if let sim { return sim }
            if Self.captureToolRunning() { throw ScanError.protocolError("Capture Tool is open. Quit it to use Scanline.") }
            switch mode {
            case .helper:
                do { return try HelperTransport() }
                catch {
                    // Not authorised yet (or broken): keep scanning through the vendor driver if it's there.
                    if "\(error)".contains("not authorised"), Self.vendorDriverLoaded() { return try AvKernelTransport() }
                    throw error
                }
            case .vendorDriver: return try AvKernelTransport()
            default: throw ScanError.protocolError("Install the Scanline helper to connect the scanner.")
            }
        }) { [weak self] e in
            Task { @MainActor in self?.handle(e) }
        }
        self.session = session
        session.start()
    }

    private func pushSettings() {
        guard let session else { return }
        var s = session.settings
        s.folder = folder
        s.autoScan = autoScan
        s.autoLoadDelay = autoScanDelay
        session.settings = s
    }

    private func handle(_ e: SessionEvent) {
        switch e {
        case .state(let s):
            state = s
            switch s {
            case .countdown: outcome = nil
            case .scanning(let lines):
                outcome = nil
                if lines == 0 { scanningName = nextFileName }
            default: break
            }
        case .saved(let url, _, let inches, let skew, _):
            outcome = .saved(name: url.lastPathComponent, inches: inches, skew: skew)
            library.reload()
            selection = url
            renaming = nil
            zoom.fitOnNextImage = true
        case .problem(let kind, let msg):
            outcome = .problem(kind, msg)
        case .autoScanChanged(let on):
            if autoScan != on { autoScan = on }
        }
    }

    func scanNow() { session?.scanNow() }

    nonisolated static func captureToolRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "Avision.Capture-Tool").isEmpty
    }

    nonisolated static func vendorDriverLoaded() -> Bool {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("com_AvKernel"))
        defer { if s != 0 { IOObjectRelease(s) } }
        return s != 0
    }

    // MARK: Activity

    var activity: Activity {
        switch state {
        case .disconnected(let why):
            let detail = why.contains("Capture Tool") ? "Capture Tool is open. Quit it to use Scanline."
                : why.contains("Install the Scanline helper") ? "Install the Scanline helper (below) to connect the scanner."
                : why.contains("not found") && !why.contains("interface") ? "Plug in the IRIScan Express 4. Scanline reconnects on its own."
                : "Plug in the IRIScan Express 4 — retrying. (\(why))"
            return Activity(title: "Scanner not connected", detail: detail, color: 0x868B9C, icon: .symbol("powerplug"), step: 0)
        case .countdown(let s):
            return Activity(title: "Paper detected — scanning in \(Int(s)) s", detail: "Pull the sheet back out to cancel.",
                            color: 0x5B4CF5, icon: .ring(Int(s)), step: 1, showButtonHint: true)
        case .paperWaiting:
            return Activity(title: "Paper in — press the scanner button", detail: "Auto-scan is off. Or click Scan Now.",
                            color: 0x5B4CF5, icon: .symbol("hand.point.down"), step: 1, showButtonHint: true)
        case .scanning(let lines):
            if lines == 0 {
                return Activity(title: "Feeding…", detail: "The scanner is pulling the receipt in.",
                                color: 0xFF5D3A, icon: .symbol("arrow.down.doc"), step: 2, busy: true)
            }
            let inches = Double(lines) / (300 * 2.98)
            return Activity(title: "Scanning…", detail: String(format: "300 dpi · %.1f in so far", inches),
                            color: 0xFF5D3A, icon: .symbol("scanner"), step: 3, busy: true)
        case .processing:
            return Activity(title: "Cleaning up", detail: "Straightening, cropping, converting to black & white",
                            color: 0xF08C00, icon: .symbol("wand.and.stars"), step: 4, busy: true)
        case .removePaper(let why):
            return Activity(title: "Take the sheet out", detail: why, color: 0xE8590C,
                            icon: .symbol("exclamationmark.triangle.fill"), step: 0)
        case .idle:
            switch outcome {
            case .saved(let name, let inches, let skew):
                return Activity(title: "Saved \(name)",
                                detail: String(format: "%.1f in long · straightened %.1f°", inches, abs(skew)),
                                color: 0x12B886, icon: .symbol("checkmark"), step: 5, showButtonHint: true)
            case .problem(let kind, let msg) where kind.isScanFailure:
                let title = kind == .cutOff ? "Scan stopped before the end" : kind == .misfeed ? "The receipt didn't feed" : "No receipt in the scan"
                return Activity(title: title, detail: msg, color: 0xE8590C, icon: .symbol("exclamationmark.triangle.fill"),
                                step: 0, failedStep: kind == .misfeed ? 2 : 3)
            case .problem(_, let msg):
                return Activity(title: "Ready — insert a receipt", detail: msg, color: 0x5B4CF5, icon: .symbol("tray"),
                                step: 0, showButtonHint: true)
            case nil:
                return Activity(title: autoScan ? "Ready — insert a receipt" : "Ready — Auto-scan is off",
                                detail: autoScan ? String(format: "Scanning starts %.0f seconds after paper is detected.", autoScanDelay)
                                    : "Insert a receipt, then press the scanner button or Scan Now.",
                                color: 0x5B4CF5, icon: .symbol("tray"), step: 0, showButtonHint: true)
            }
        }
    }

    var nextFileName: String? {
        guard let folder else { return nil }
        return FileNamer.nextURL(in: folder).lastPathComponent
    }

    // MARK: Folder and files

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where Scanline saves your scans."
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            selection = library.files.first?.url
        }
    }

    func openFolder() { if let folder { NSWorkspace.shared.open(folder) } }

    func trash(_ file: ScanFile) {
        let files = library.files
        let i = files.firstIndex(of: file) ?? 0
        do {
            if let t = try library.trash(file) { undo = (t, file.url) }
            if selection == file.url {
                let rest = library.files
                selection = rest.isEmpty ? nil : rest[min(i, rest.count - 1)].url
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func undoTrash() {
        guard let u = undo else { return }
        do { try library.restore(from: u.trashed, to: u.original); selection = u.original }
        catch { errorMessage = error.localizedDescription }
        undo = nil
    }

    func rotate(_ file: ScanFile, _ turn: Orientation.Turn) {
        do {
            try library.rotate(file, turn)
            imageRevision += 1
        } catch { errorMessage = error.localizedDescription }
    }

    func rename(_ file: ScanFile, to name: String) {
        do {
            let new = try library.rename(file, to: name)
            if selection == file.url { selection = new }
            if case .saved(let n, let i, let k) = outcome, n == file.name { outcome = .saved(name: new.lastPathComponent, inches: i, skew: k) }
            renaming = nil
        } catch { errorMessage = error.localizedDescription }
    }

    // MARK: Helper

    func installHelper() {
        guard let bin = Bundle.main.url(forResource: "ScanlineHelper", withExtension: nil) else {
            errorMessage = "The helper is missing from the app bundle."; return
        }
        let rule = FileManager.default.temporaryDirectory.appendingPathComponent("local.scanline.helper.sudoers")
        do { try ScanlineHelper.sudoersRule(user: NSUserName()).write(to: rule, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription; return }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let H = ScanlineHelper.self
        let script = [
            // Stop the session so the old helper lets go of the scanner.
            "launchctl bootout system/\(H.legacyLabel) 2>/dev/null; rm -f \(q(H.legacyPlist))",
            "mkdir -p /Library/PrivilegedHelperTools",
            "cp \(q(bin.path)) \(q(H.installedBinary))",
            "chown root:wheel \(q(H.installedBinary))",
            "chmod 755 \(q(H.installedBinary))",
            "/usr/sbin/visudo -cf \(q(rule.path))",
            "install -m 0440 -o root -g wheel \(q(rule.path)) \(q(H.sudoersFile))",
            "rm -f \(q(H.legacySudoersFile))",
        ].joined(separator: " && ")
        session?.stop()
        let apple = "do shell script \"\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges with prompt \"Scanline needs to install its scanner helper.\""
        var err: NSDictionary?
        NSAppleScript(source: apple)?.executeAndReturnError(&err)
        if let err, (err[NSAppleScript.errorNumber] as? Int) != -128 {
            errorMessage = "Installing the helper failed: \(err[NSAppleScript.errorMessage] ?? err)"
        }
        try? FileManager.default.removeItem(at: rule)
        startSession()
    }
}
