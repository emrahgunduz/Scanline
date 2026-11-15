import AppKit
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
                .onAppear { model.applyAppearance() }
        }
        .defaultSize(width: 1240, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Select Folder…") { model.chooseFolder() }.keyboardShortcut("o")
                Button("Open Folder in Finder") { model.openFolder() }.keyboardShortcut("o", modifiers: [.command, .shift])
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
    func applicationWillFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)   // writes to a closed helper pipe return an error instead of killing the app
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

