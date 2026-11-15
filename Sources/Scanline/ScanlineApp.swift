import AppKit
import Quartz
import ScanlineCore
import SwiftUI

@main
struct ScanlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Scanline", id: "main") {
            MainView(model: model)
                .frame(minWidth: 760, minHeight: 520)
                .tint(Theme.accent)
                .onAppear { model.applyAppearance(); delegate.model = model }
        }
        .defaultSize(width: 1240, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Select Folder…") { model.chooseFolder() }.keyboardShortcut("o")
                Button("Open Folder in Finder") { model.openFolder() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                // No bare Return/Space here: a menu key equivalent would take them from the rename field.
                Button("Rename (Return)") { model.beginRename() }
                    .disabled(model.selectedFile == nil || model.isRenaming)
                Button("Show in Finder") { model.revealSelected() }
                    .disabled(model.selectedFile == nil)
                // Disabled while renaming, or ⌘⌫ would trash the file instead of editing the name.
                Button("Move to Trash") { model.trashSelected() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selectedFile == nil || model.isRenaming)
            }
            CommandMenu("Image") {
                Button(model.quickLookURL == nil ? "Quick Look" : "Close Quick Look") { model.toggleQuickLook() }
                    .keyboardShortcut("y")
                    .disabled(model.selectedFile == nil || model.isRenaming)
                Divider()
                Group {
                    Button("Rotate Left") { model.rotateSelected(.left) }.keyboardShortcut("l")
                    Button("Rotate Right") { model.rotateSelected(.right) }.keyboardShortcut("r")
                    Button("Rotate 180°") { model.rotateSelected(.upsideDown) }
                }
                .disabled(model.selectedFile == nil || model.isRenaming)
            }
            CommandMenu("Scan") {
                Button("Scan Now") { model.scanNow() }.keyboardShortcut(.return, modifiers: .command)
                Toggle("Auto-scan", isOn: Binding(get: { model.autoScan }, set: { model.autoScan = $0 }))
                    .keyboardShortcut("a", modifiers: [.command, .option])
            }
            if let sim = model.simulator {
                CommandMenu("Simulator") {
                    Button("Insert Receipt") { sim.nextPage = SimulatedScanner.syntheticReceipt(heightPx: Int.random(in: 700...1700), tiltDegrees: Double.random(in: -2.5...2.5)); sim.paper = true }
                        .keyboardShortcut("i", modifiers: [.command, .control])
                    Button("Insert Receipt (misfeed)") { sim.nextPage = SimulatedScanner.syntheticReceipt(); sim.failNextFeed = true; sim.paper = true }
                    Button("Insert Receipt (stops early)") {
                        let full = SimulatedScanner.syntheticReceipt(heightPx: 1400)
                        sim.nextPage = GrayImage(width: full.width, height: full.height / 2, pixels: Array(full.pixels[0..<(full.width * (full.height / 2))]))
                        sim.paper = true
                    }
                    Button("Remove Sheet") { sim.paper = false }
                    Divider()
                    Button("Press Scanner Button") { sim.pressButton() }
                    Button("Hold Scanner Button") { sim.pressButton(long: true) }
                }
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { model.zoom.zoomIn() }.keyboardShortcut("+")
                Button("Zoom Out") { model.zoom.zoomOut() }.keyboardShortcut("-")
                Button("Fit") { model.zoom.fit() }.keyboardShortcut("0")
                Button("Actual Size") { model.zoom.actualSize() }.keyboardShortcut("1")
                Divider()
                Picker("Appearance", selection: Binding(get: { model.appearance }, set: { model.appearance = $0 })) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
            }
        }

        Settings {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)   // writes to a closed helper pipe return an error instead of killing the app
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The Quick Look panel takes keyboard focus; like Finder, let ↑/↓ there move the scan list
        // (the panel follows the selection). ←/→ are the panel's own and already sync back.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard NSApp.keyWindow is QLPreviewPanel, let model = self?.model,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
            switch event.keyCode {
            case 125: model.selectAdjacent(1); return nil     // ↓
            case 126: model.selectAdjacent(-1); return nil    // ↑
            default: return event
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

