import PiLyzerCore
import SwiftUI

/// One palette for both applications.
///
/// The browser application in `Web/` and this one are the same instrument seen
/// through two windows, so they are drawn in the same colours: the values here
/// are the custom properties at the top of `Web/style.css`. The screen keeps an
/// instrument's own dark face whatever the system theme is, and the panel
/// around it is the same off-white paper the web page uses rather than the
/// system window colour — otherwise the two look like different products.
enum Theme {
    private static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }

    // The page around the instrument.
    static let page = hex(0xF2F3ED)
    static let panel = hex(0xFAFBF6)
    static let line = hex(0xDFE3D9)
    static let ink = hex(0x253329)
    static let muted = hex(0x778074)
    static let accent = hex(0x284A32)
    static let accentSoft = hex(0xC4EDA0)

    // The screen itself.
    static let screen = hex(0x101917)
    static let screenEdge = hex(0x25332C)
    static let grid = hex(0x344238)
    static let gridStrong = hex(0x607160)
    static let readout = hex(0x8C9E90)
    static let screenInk = hex(0xD4E0D3)

    /// The eight trace colours of `COLORS` in `Web/src/plot.mjs`. The analogue
    /// channels take the first three; the logic inputs take all eight, so D0
    /// and CH1 share a colour exactly as they do in the browser.
    static let traces: [Color] = [
        hex(0xE9C96B), hex(0x79CDD8), hex(0xC0A1EF), hex(0x9ED190),
        hex(0xD8AD7F), hex(0xA6BCEC), hex(0xD592B9), hex(0xAFBF7A),
    ]

    static func channelColor(_ index: Int) -> Color { traces[index % traces.count] }
    static func logicColor(_ index: Int) -> Color { traces[index % traces.count] }

    static let trigger = hex(0xA3CD87)
    static let live = hex(0xB8EF83)
    static let connected = hex(0x77AD4C)
    static let clip = hex(0xE69B7F)
    static let cursor = hex(0xE58B72)

    static let mono = Font.system(size: 11, design: .monospaced)
    static let monoSmall = Font.system(size: 10, design: .monospaced)
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
