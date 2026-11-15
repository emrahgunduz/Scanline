import ScanlineCore
import SwiftUI

/// Settings in the same visual language as the main window: colored icon tiles, tinted cards.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            SettingsCard(title: "Scanning", symbol: "viewfinder", color: 0x5B4CF5) {
                SettingsRow("Auto-scan", detail: "Scan as soon as a receipt is inserted. Holding the scanner's button switches it too.") {
                    Toggle("Auto-scan", isOn: $model.autoScan).toggleStyle(.switch).labelsHidden().tint(Theme.saved)
                }
                Divider()
                SettingsRow("Start after", detail: "Time to straighten the receipt before the scanner pulls it in.") {
                    Picker("Start after", selection: $model.autoScanDelay) {
                        ForEach([1.0, 2, 3, 5], id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    .disabled(!model.autoScan)
                }
            }
            SettingsCard(title: "Appearance", symbol: "paintpalette", color: 0xFF5D3A) {
                SettingsRow("Theme", detail: nil) {
                    Picker("Theme", selection: $model.appearance) {
                        ForEach(Appearance.allCases) { a in Text(a == .system ? "System" : a.label).tag(a) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            UpdatesCard(updates: model.updates)
            SettingsCard(title: "Saving", symbol: "folder.fill", color: 0xF08C00) {
                SettingsRow(model.folder?.lastPathComponent ?? "No folder",
                            detail: model.folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Choose where scans are saved.") {
                    HStack(spacing: 8) {
                        Button("Select Folder…") { model.chooseFolder() }
                        Button("Open") { model.openFolder() }.disabled(model.folder == nil)
                    }
                }
                Divider()
                SettingsRow("File names", detail: "Date and a running number, continuing from the folder.") {
                    Text(model.nextFileName ?? "2026-01-01 0000001.jpg")
                        .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            SettingsCard(title: "Scanner", symbol: "scanner", color: connected ? 0x12B886 : 0x868B9C) {
                SettingsRow(connectionTitle, detail: connectionDetail) {
                    HStack(spacing: 6) {
                        Circle().fill(connected ? Theme.saved : Theme.stopped).frame(width: 8, height: 8)
                        Text(connected ? "Connected" : "Not connected").font(.callout.weight(.medium))
                    }
                }
                Divider()
                if model.access == .helper || model.helperStatus != nil {
                    SettingsRow("Helper", detail: helperDetail) {
                        Text(helperBadge).font(.callout.weight(.medium)).foregroundStyle(helperNeedsAction ? Theme.stopped : .secondary)
                    }
                    Divider()
                }
                HStack(spacing: 8) {
                    if helperNeedsAction {
                        Button(helperButton) { model.installHelper() }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                            .disabled(model.scannerBusy || model.helperStatus == .bundleMissing)
                    } else {
                        Button(helperButton) { model.installHelper() }
                            .disabled(model.scannerBusy || model.helperStatus == .bundleMissing)
                    }
                    Button("Open Scan Log") { if let u = ScanSession.defaultLogURL { NSWorkspace.shared.open(u) } }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear { model.refreshHelperStatus() }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Scanline").font(.title2.weight(.bold))
                Text("Version \(model.updates.build.displayVersion) · IRIScan Express 4")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var helperNeedsAction: Bool {
        if model.connectProblem != nil { return true }
        return switch model.helperStatus {
        case .notInstalled?, .ruleMissing?, .unpinned?, .outdated?: true
        default: false
        }
    }

    private var helperButton: String {
        if model.connectProblem == .helperNotAuthorised { return "Repair Helper…" }
        if model.connectProblem == .helperOutdated { return "Update Helper…" }
        return switch model.helperStatus {
        case .notInstalled?: "Install Helper…"
        case .ruleMissing?: "Repair Helper…"
        case .unpinned?, .outdated?: "Update Helper…"
        default: model.access == .helper ? "Reinstall Helper…" : "Install Helper…"
        }
    }

    private var helperBadge: String {
        if model.connectProblem == .helperNotAuthorised { return "Needs repair" }
        if model.connectProblem == .helperOutdated { return "Update needed" }
        return switch model.helperStatus {
        case .current?: "Up to date"
        case .outdated?: "Update available"
        case .unpinned?: "Update recommended"
        case .ruleMissing?: "Needs repair"
        case .notInstalled?: "Not installed"
        case .bundleMissing?: "Not bundled"
        case nil: "Checking…"
        }
    }

    private var helperDetail: String {
        if model.connectProblem == .helperNotAuthorised { return "macOS won't start the helper for this account." }
        if model.connectProblem == .helperOutdated { return "The installed helper is too old for this version of Scanline." }
        return switch model.helperStatus {
        case .current?: "The installed helper matches this version of Scanline."
        case .outdated?: "The installed helper is from a different Scanline build."
        case .unpinned?: "Its sudo rule isn't pinned to the helper's exact bytes yet."
        case .ruleMissing?: "The helper is installed, but its sudo rule is missing."
        case .notInstalled?: "Install it to connect the scanner without the vendor software."
        case .bundleMissing?: "This build of Scanline has no bundled helper."
        case nil: "Comparing the installed helper with this version of Scanline."
        }
    }

    private var connected: Bool {
        if case .disconnected = model.state { return false }
        return true
    }

    private var connectionTitle: String {
        switch model.access {
        case .helper: "Scanline helper"
        case .vendorDriver: "Vendor driver (temporary)"
        case .simulator: "Simulator"
        case .none: "Not set up"
        }
    }

    private var connectionDetail: String {
        switch model.access {
        case .helper: "Direct USB. No vendor software, kernel extension or Rosetta."
        case .vendorDriver: "Install the helper to stop using the old vendor software."
        case .simulator: "A simulated scanner for testing."
        case .none: "Install the helper to connect the scanner."
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    let color: UInt32
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: NSColor(hex: color)))
                    .frame(width: 28, height: 28)
                    .shadow(color: Color(nsColor: NSColor(hex: color)).opacity(0.35), radius: 4, y: 2)
                    .overlay(Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white))
                Text(title).font(.headline)
            }
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.tint(color), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: Control

    init(_ title: String, detail: String?, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            control
        }
    }
}

/// Once-a-day check for a newer release on GitHub.
struct UpdatesCard: View {
    @Bindable var updates: UpdateController

    var body: some View {
        SettingsCard(title: "Updates", symbol: "arrow.down.circle", color: 0x1C7ED6) {
            SettingsRow("Check for updates", detail: "Once a day Scanline asks GitHub for the latest release. Nothing about you or this Mac is sent.") {
                Toggle("Check for updates", isOn: $updates.enabled).toggleStyle(.switch).labelsHidden().tint(Theme.saved)
            }
            Divider()
            SettingsRow(title, detail: detail) {
                HStack(spacing: 8) {
                    if updates.available != nil {
                        Button("View Release") { updates.openRelease() }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                    }
                    Button("Check Now") { updates.checkNow() }.disabled(updates.status == .checking)
                }
            }
        }
    }

    private var title: String {
        if let a = updates.available { return "Scanline \(ReleaseVersion(a.tag)?.description ?? a.tag) is available" }
        return switch updates.status {
        case .checking: "Checking…"
        case .upToDate: "Up to date"
        case .unavailable: "No public release found"
        case .rateLimited: "Checked too often"
        case .failed: "Couldn't check"
        case .idle: updates.build.kind == .dev && !updates.enabled ? "Development build" : "Not checked yet"
        }
    }

    private var detail: String? {
        if updates.available != nil { return "You have \(updates.build.version). Nothing is installed automatically." }
        return switch updates.status {
        case .upToDate(let d), .unavailable(let d): "Checked \(Self.relative(d))."
        case .rateLimited(let until): "GitHub asked to wait; trying again \(Self.relative(until))."
        case .failed(let d, let why): "Checked \(Self.relative(d)): \(why)."
        case .idle where updates.build.kind == .dev && !updates.enabled:
            "\(updates.build.describe ?? updates.build.version): automatic checks are off."
        default: nil
        }
    }

    private static func relative(_ date: Date) -> String {
        abs(date.timeIntervalSinceNow) < 60 ? "just now" : RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}
