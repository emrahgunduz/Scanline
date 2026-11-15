import ScanlineCore
import SwiftUI

struct MainView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            DetailView(model: model)
        }
        .navigationTitle(model.folder?.lastPathComponent ?? "Scanline")
        .navigationSubtitle(model.folder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "No folder chosen")
        .toolbar { toolbar }
        .alert("Scanline", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(model.errorMessage ?? "") }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("Appearance", selection: $model.appearance) {
                ForEach(Appearance.allCases) { a in
                    Label(a.label, systemImage: a.symbol).labelStyle(.iconOnly)
                        .accessibilityLabel(a.label).help(a.label).tag(a)
                }
            }
            .pickerStyle(.segmented)
            .help("Appearance: Light, Dark or Match System")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 8) {
                Text("Auto-scan").font(.callout.weight(.medium))
                Toggle("Auto-scan", isOn: $model.autoScan)
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .tint(Theme.saved)
            }
            .padding(.horizontal, 10)
            .help("Scan automatically when paper is inserted. Hold the scanner's button to switch.")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button { model.scanNow() } label: {
                Label("Scan Now", systemImage: "viewfinder").labelStyle(.titleAndIcon)
            }
            .buttonStyle(AccentPillStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .help("Scan the sheet in the feeder now (⌘↩)")
        }
    }
}

// MARK: Sidebar

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            folderHeader.padding(16)
            HStack(alignment: .firstTextBaseline) {
                Text("SCANS · NEWEST FIRST").font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.library.files.count) files").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.bottom, 6)
            FileListView(model: model)
                .frame(minHeight: 120, idealHeight: 320, maxHeight: .infinity)
            if model.access == .vendorDriver || model.access == .none {
                HelperBanner(model: model).padding(12)
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
    }

    private var folderHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 11).fill(Theme.folderGradient)
                    .frame(width: 40, height: 40)
                    .overlay(Image(systemName: "folder.fill").foregroundStyle(.white).font(.system(size: 18)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("SAVING TO").font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                    Text(model.folder?.lastPathComponent ?? "No folder").font(.headline)
                }
            }
            HStack(spacing: 8) {
                Button("Select Folder…") { model.chooseFolder() }.frame(maxWidth: .infinity)
                Button("Open in Finder") { model.openFolder() }.frame(maxWidth: .infinity).disabled(model.folder == nil)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            if let next = model.nextFileName {
                HStack {
                    Text("Next file").foregroundStyle(.secondary)
                    Spacer()
                    Text(next).font(.system(.caption, design: .monospaced).weight(.medium))
                }
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.nextBox, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Theme.line))
            }
        }
    }
}

struct FileListView: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.library.files) { file in
                row(file).tag(file.url)
                    .contextMenu {
                        Button("Open") { NSWorkspace.shared.open(file.url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                        Divider()
                        Button("Rename") { startRename(file) }
                        Menu("Rotate") {
                            Button("Rotate Left (90°)") { model.rotate(file, .left) }
                            Button("Rotate Right (90°)") { model.rotate(file, .right) }
                            Button("Rotate 180°") { model.rotate(file, .upsideDown) }
                        }
                        Button("Move to Trash", role: .destructive) { model.trash(file) }
                    }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { if let f = selectedFile { model.trash(f) } }
        .overlay {
            if model.folder == nil {
                ContentUnavailableView("No folder", systemImage: "folder.badge.questionmark",
                                       description: Text("Choose where scans are saved."))
            } else if model.library.files.isEmpty {
                ContentUnavailableView("No scans yet", systemImage: "doc.viewfinder",
                                       description: Text("Insert a receipt to start."))
            }
        }
    }

    private var selectedFile: ScanFile? { model.library.files.first { $0.url == model.selection } }

    private func startRename(_ file: ScanFile) {
        draft = (file.name as NSString).deletingPathExtension
        model.selection = file.url
        model.renaming = file.url
        renameFocused = true
    }

    @ViewBuilder private func row(_ file: ScanFile) -> some View {
        HStack(spacing: 10) {
            Thumb(image: model.library.thumbnail(file), inches: file.inches)
            VStack(alignment: .leading, spacing: 2) {
                if model.renaming == file.url {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        .focused($renameFocused)
                        .onSubmit { model.rename(file, to: draft) }
                        .onExitCommand { model.renaming = nil }
                } else {
                    Text(file.name).font(.system(.callout, design: .monospaced).weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                }
                Text(file.meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.selection == file.url && model.renaming != file.url {
                Button { startRename(file) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless).foregroundStyle(Theme.accentText).help("Rename")
                    .accessibilityLabel("Rename")
                Button { model.trash(file) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).foregroundStyle(Theme.danger).help("Move to Trash")
                    .accessibilityLabel("Move to Trash")
            }
        }
        .padding(.vertical, 3)
    }
}

struct Thumb: View {
    let image: NSImage?
    let inches: Double
    var body: some View {
        let h = min(44, max(16, inches * 4.6))
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
            } else {
                Color.white
            }
        }
        .frame(width: 24, height: h)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
        .frame(width: 30, height: 44, alignment: .top)
    }
}

struct HelperBanner: View {
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.access == .vendorDriver ? "Using the old vendor driver" : "Scanner access needed",
                  systemImage: "bolt.shield")
                .font(.callout.weight(.semibold))
            Text("Install the Scanline helper so the scanner works without the vendor software. You'll be asked for your password once.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Install Helper…") { model.installHelper() }
                .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.tint(0x5B4CF5), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: Detail

struct DetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ActivityCard(activity: model.activity, autoScan: model.autoScan)
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            header.padding(.horizontal, 20).padding(.bottom, 10)
            viewer.padding(.horizontal, 20).padding(.bottom, 20)
                .frame(minHeight: 200, idealHeight: 400, maxHeight: .infinity)
        }
        .frame(minWidth: 460, minHeight: 420, maxHeight: .infinity, alignment: .top)
    }

    private var selected: ScanFile? { model.library.files.first { $0.url == model.selection } }

    private var header: some View {
        HStack(spacing: 10) {
            if scanningStage != nil {
                Text("New scan").font(.system(.body).weight(.bold))
                if let next = model.scanningName ?? model.nextFileName {
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    Text(next).font(.system(.body, design: .monospaced).weight(.medium)).foregroundStyle(.secondary)
                }
                Spacer()
            } else if let f = selected {
                Text(f.name).font(.system(.body, design: .monospaced).weight(.bold)).lineLimit(1)
                if f.url == model.library.files.first?.url {
                    Text("Latest scan").font(.caption.weight(.semibold)).foregroundStyle(Theme.latestInk)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.latestBg, in: Capsule())
                }
                Text(f.meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                HStack(spacing: 10) {
                    Button { model.rotate(f, .left) } label: { Image(systemName: "rotate.left") }
                        .help("Rotate Left (90°)").accessibilityLabel("Rotate left")
                    Button { model.rotate(f, .right) } label: { Image(systemName: "rotate.right") }
                        .help("Rotate Right (90°)").accessibilityLabel("Rotate right")
                    Button { model.rotate(f, .upsideDown) } label: { Image(systemName: "arrow.up.arrow.down") }
                        .help("Rotate 180°").accessibilityLabel("Rotate 180 degrees")
                }
                .buttonStyle(.borderless)
                .imageScale(.large)
                .foregroundStyle(Theme.accentText)
                .padding(.trailing, 12)
                Button { NSWorkspace.shared.activateFileViewerSelecting([f.url]) } label: {
                    Label("Show in Finder", systemImage: "magnifyingglass")
                }
                .buttonStyle(.link)
            } else {
                Text("No scan selected").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(height: 22)
    }

    private var viewer: some View {
        ZStack(alignment: .bottom) {
            DotGrid().clipShape(RoundedRectangle(cornerRadius: 14))
            if let stage = scanningStage {
                ScanningStage(phase: stage)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .transition(.opacity)
            } else {
                ReceiptViewer(url: model.selection, revision: model.imageRevision, zoom: model.zoom)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .transition(.opacity)
            }
            if model.selection == nil && scanningStage == nil {
                ContentUnavailableView("Nothing to show", systemImage: "doc.text.image",
                                       description: Text("Your latest scan appears here."))
            }
            if scanningStage == nil {
                ZoomPill(zoom: model.zoom).padding(.bottom, 14)
            }
            if model.undo != nil {
                UndoToast(model: model).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(14)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
        .animation(.easeInOut(duration: 0.3), value: scanningStage == nil)
    }

    /// While the scanner works, the viewer shows a stylized receipt instead of the last scan.
    private var scanningStage: ScanningStage.Phase? {
        switch model.state {
        case .scanning(let lines): lines == 0 ? .feeding : .scanning(inches: Double(lines) / (300 * 2.98))
        case .processing: .cleaning
        default: nil
        }
    }
}

struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.canvas))
            let step: CGFloat = 18
            var y: CGFloat = step / 2
            while y < size.height {
                var x: CGFloat = step / 2
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)), with: .color(Theme.canvasDot))
                    x += step
                }
                y += step
            }
        }
    }
}

struct ScanBeam: View {
    var color: Color = Theme.scanning
    @State private var down = false
    var body: some View {
        GeometryReader { g in
            Rectangle().fill(color).frame(height: 3)
                .shadow(color: color.opacity(0.7), radius: 10)
                .offset(y: down ? g.size.height : 0)
                .animation(.linear(duration: 1.6).repeatForever(autoreverses: false), value: down)
                .onAppear { down = true }
        }
    }
}

struct ZoomPill: View {
    @Bindable var zoom: ZoomController
    var body: some View {
        HStack(spacing: 2) {
            Button { zoom.zoomOut() } label: { Image(systemName: "minus").frame(width: 28, height: 24) }
                .help("Zoom Out (⌘−)").accessibilityLabel("Zoom out")
            Text("\(Int((zoom.magnification * 100).rounded()))%").font(.caption.weight(.semibold)).monospacedDigit().frame(minWidth: 48)
            Button { zoom.zoomIn() } label: { Image(systemName: "plus").frame(width: 28, height: 24) }
                .help("Zoom In (⌘+)").accessibilityLabel("Zoom in")
            Divider().frame(height: 16).padding(.horizontal, 4)
            Button { zoom.fit() } label: { Text("Fit").font(.caption.weight(.semibold)).padding(.horizontal, 8).frame(height: 24) }
                .background(zoom.fitMode ? Theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: 7))
                .foregroundStyle(zoom.fitMode ? Theme.accentText : .primary)
                .help("Fit (⌘0)")
            Button { zoom.actualSize() } label: { Text("1:1").font(.caption.weight(.semibold)).padding(.horizontal, 8).frame(height: 24) }
                .help("Actual Size (⌘1)")
        }
        .buttonStyle(.borderless)
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

struct UndoToast: View {
    let model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            Text("Moved “\(model.undo?.original.lastPathComponent ?? "")” to Trash").font(.callout)
            Button("Undo") { model.undoTrash() }.buttonStyle(.borderless).fontWeight(.bold).foregroundStyle(Theme.accentText)
            Button { model.undo = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .task(id: model.undo?.trashed) {
            try? await Task.sleep(for: .seconds(8))
            model.undo = nil
        }
    }
}

// MARK: Activity card

struct ActivityCard: View {
    let activity: Activity
    let autoScan: Bool

    var body: some View {
        let color = Color(nsColor: NSColor(hex: activity.color))
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 15).fill(color)
                .frame(width: 52, height: 52)
                .shadow(color: color.opacity(0.35), radius: 8, y: 4)
                .overlay { icon }
            VStack(alignment: .leading, spacing: 3) {
                Text(activity.title).font(.title3.weight(.bold)).lineLimit(1)
                Text(activity.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                if activity.busy {
                    BusyBar(color: color).frame(height: 6).padding(.top, 5)
                } else if activity.showButtonHint {
                    Text("Scanner button: press to scan now · hold to turn Auto-scan \(autoScan ? "off" : "on")")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 3)
                }
            }
            Spacer(minLength: 8)
            StepTrack(activity: activity, color: color)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(Theme.tint(activity.color), in: RoundedRectangle(cornerRadius: 16))
        .animation(.easeInOut(duration: 0.25), value: activity)
    }

    @ViewBuilder private var icon: some View {
        switch activity.icon {
        case .ring(let s):
            ZStack {
                Circle().stroke(.white.opacity(0.35), lineWidth: 4)
                Circle().trim(from: 0, to: CGFloat(s) / 2).stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: s)
                Text("\(s)").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
        case .symbol(let name):
            Image(systemName: name).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
        }
    }
}

struct BusyBar: View {
    let color: Color
    @State private var phase = false
    var body: some View {
        GeometryReader { g in
            Capsule().fill(.primary.opacity(0.08))
                .overlay(alignment: .leading) {
                    Capsule().fill(color).frame(width: g.size.width * 0.4)
                        .offset(x: phase ? g.size.width : -g.size.width * 0.4)
                        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false), value: phase)
                }
                .clipShape(Capsule())
                .onAppear { phase = true }
        }
    }
}

struct StepTrack: View {
    let activity: Activity
    let color: Color
    private let names = ["Paper", "Feed", "Scan", "Clean up", "Saved"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                let n = i + 1
                let done = activity.step == 5 || n < activity.step || (activity.failedStep.map { n < $0 } ?? false)
                let active = n == activity.step && activity.step != 5
                let failed = activity.failedStep == n
                let c: Color = failed ? Theme.stopped : done ? Theme.saved : active ? color : Theme.todo
                VStack(spacing: 5) {
                    Circle()
                        .fill(done || active || failed ? c : .clear)
                        .overlay(Circle().strokeBorder(c, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(active ? color.opacity(0.25) : .clear).frame(width: 22, height: 22))
                    Text(name).font(.caption2.weight(active || failed ? .bold : .medium))
                        .foregroundStyle(done || active || failed ? .primary : .secondary)
                }
                .frame(width: 54)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(name): \(failed ? "failed" : done ? "done" : active ? "in progress" : "waiting")")
            }
        }
    }
}

/// The violet Scan Now pill (toolbar buttons ignore .borderedProminent).
struct AccentPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 30)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 9))
            .shadow(color: Theme.accent.opacity(0.35), radius: 4, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}
