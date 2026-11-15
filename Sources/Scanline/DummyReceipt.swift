import SwiftUI

/// Stand-in shown while a receipt is being scanned: a stylized receipt, with a scan line
/// sweeping the whole viewer continuously (coral while scanning, amber while cleaning up).
/// The real image replaces it once it is saved.
struct ScanningStage: View {
    enum Phase: Equatable { case feeding, scanning(inches: Double), cleaning }
    let phase: Phase

    var body: some View {
        GeometryReader { g in
            let paperH = max(160, g.size.height - 60)
            let paperW = min(240, g.size.width * 0.5, paperH * 0.42)
            DummyReceipt(rows: 60, finished: phase == .cleaning)
                .frame(width: paperW, height: paperH, alignment: .top)
                .clipped()
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay {
            ScanBeam(color: phase == .cleaning ? Theme.cleaning : Theme.scanning)
                .id(phase == .cleaning)   // restart the sweep when the colour changes
                .allowsHitTesting(false)
        }
    }
}

/// The stylized receipt: torn top edge, header, item rows, total and barcode.
struct DummyReceipt: View {
    let rows: Int
    var finished = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 7) {
                bar(0.62, 10, dark: true)
                bar(0.78, 6)
                bar(0.5, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
            dashed.padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(0..<rows, id: \.self) { i in
                    HStack {
                        bar([0.42, 0.55, 0.36, 0.48, 0.3][i % 5], 6)
                        Spacer()
                        bar(0.18, 6, dark: i % 7 == 3)
                    }
                    if i % 6 == 5 { dashed.padding(.vertical, 4) }
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.white)
        .clipShape(TornEdge())
        .overlay(alignment: .top) {
            if finished {
                LinearGradient(colors: [.clear, Theme.cleaning.opacity(0.06), .clear], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            }
        }
    }

    private func bar(_ fraction: CGFloat, _ h: CGFloat, dark: Bool = false) -> some View {
        GeometryReader { g in
            Capsule().fill(dark ? Color(white: 0.17) : Color(white: 0.74))
                .frame(width: g.size.width * fraction, height: h)
        }
        .frame(height: h)
    }

    private var dashed: some View {
        Line().stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Color(white: 0.55)).frame(height: 1)
    }

    private struct Line: Shape {
        func path(in r: CGRect) -> Path { Path { $0.move(to: CGPoint(x: 0, y: r.midY)); $0.addLine(to: CGPoint(x: r.maxX, y: r.midY)) } }
    }
}

/// Rectangle with a zig-zag (torn) top edge.
private struct TornEdge: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let tooth: CGFloat = 10
        p.move(to: CGPoint(x: r.minX, y: r.minY + tooth / 2))
        var x = r.minX
        var up = true
        while x < r.maxX {
            x = min(r.maxX, x + tooth)
            p.addLine(to: CGPoint(x: x, y: r.minY + (up ? 0 : tooth / 2)))
            up.toggle()
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
