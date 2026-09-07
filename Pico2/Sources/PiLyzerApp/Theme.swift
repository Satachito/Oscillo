import PiLyzerCore
import SwiftUI

/// The screen keeps an instrument's own dark face whatever the system theme
/// is; the panel around it follows the system.
enum Theme {
    static let screen = Color(red: 0.04, green: 0.05, blue: 0.06)
    static let grid = Color.white.opacity(0.10)
    static let gridStrong = Color.white.opacity(0.22)
    static let readout = Color.white.opacity(0.75)

    static let channel: [Color] = [
        Color(red: 1.00, green: 0.84, blue: 0.25),
        Color(red: 0.35, green: 0.85, blue: 1.00),
        Color(red: 0.90, green: 0.55, blue: 1.00),
    ]

    static let logic: [Color] = [
        Color(red: 0.98, green: 0.55, blue: 0.35),
        Color(red: 0.99, green: 0.78, blue: 0.32),
        Color(red: 0.72, green: 0.89, blue: 0.40),
        Color(red: 0.40, green: 0.87, blue: 0.62),
        Color(red: 0.38, green: 0.82, blue: 0.95),
        Color(red: 0.55, green: 0.68, blue: 0.99),
        Color(red: 0.78, green: 0.60, blue: 0.97),
        Color(red: 0.97, green: 0.58, blue: 0.78),
    ]

    static func channelColor(_ index: Int) -> Color {
        channel[index % channel.count]
    }

    static func logicColor(_ index: Int) -> Color {
        logic[index % logic.count]
    }

    static let trigger = Color(red: 0.55, green: 1.0, blue: 0.55)
    static let cursor = Color(red: 1.0, green: 0.45, blue: 0.45)
}

/// The grid every screen in the application is drawn on.
struct ScopeGrid {
    var columns: Int
    var rows: Int

    func draw(in context: inout GraphicsContext, size: CGSize) {
        let width = size.width, height = size.height
        var minor = Path()
        for column in 1..<columns {
            let x = width * CGFloat(column) / CGFloat(columns)
            minor.move(to: CGPoint(x: x, y: 0))
            minor.addLine(to: CGPoint(x: x, y: height))
        }
        for row in 1..<rows {
            let y = height * CGFloat(row) / CGFloat(rows)
            minor.move(to: CGPoint(x: 0, y: y))
            minor.addLine(to: CGPoint(x: width, y: y))
        }
        context.stroke(minor, with: .color(Theme.grid), lineWidth: 1)

        var centre = Path()
        centre.move(to: CGPoint(x: width / 2, y: 0))
        centre.addLine(to: CGPoint(x: width / 2, y: height))
        centre.move(to: CGPoint(x: 0, y: height / 2))
        centre.addLine(to: CGPoint(x: width, y: height / 2))
        context.stroke(centre, with: .color(Theme.gridStrong), lineWidth: 1)
    }
}

extension GraphicsContext {
    /// Draws a polyline. Callers reduce long records with `envelope(_:width:)`
    /// first, so a 16 000 point record costs one segment a pixel column.
    mutating func strokeTrace(_ points: [CGPoint], color: Color, width: CGFloat = 1.4) {
        guard points.count > 1 else { return }
        var path = Path()
        path.addLines(points)
        stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineJoin: .round))
    }
}

/// Reduces a sample series to one column of pixels per screen column, keeping
/// the extremes so a fast signal still shows its envelope.
func envelope(_ samples: [Double], width: Int) -> [(low: Double, high: Double)] {
    guard !samples.isEmpty, width > 0 else { return [] }
    if samples.count <= width { return samples.map { ($0, $0) } }
    var result: [(Double, Double)] = []
    result.reserveCapacity(width)
    for column in 0..<width {
        let start = samples.count * column / width
        let end = max(samples.count * (column + 1) / width, start + 1)
        var low = samples[start], high = samples[start]
        for index in start..<min(end, samples.count) {
            low = min(low, samples[index])
            high = max(high, samples[index])
        }
        result.append((low, high))
    }
    return result
}

/// The strip under every screen.
///
/// All four screens put something different down here — readings, distortion
/// figures, per-channel activity, decoded bytes — and each of those grows and
/// shrinks as measurements come and go. The trace above must not move when
/// they do, so the strip is sized by a hidden template of the tallest thing
/// any screen shows rather than by whatever is in it at the moment. Using a
/// template instead of a fixed number keeps it right if the font, the type
/// size or the translation changes.
struct Footer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            template.hidden().accessibilityHidden(true)
            content()
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.thinMaterial)
    }

    /// One channel's worth of readings: a heading and seven values, which is
    /// the tallest footer in the application.
    private var template: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("CH1").bold()
            ForEach(0..<7, id: \.self) { _ in Text("Vpp") }
        }
    }
}
