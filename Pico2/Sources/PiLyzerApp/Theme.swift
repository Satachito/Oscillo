import AppKit
import PiLyzerCore
import SwiftUI

/// One palette for both applications.
///
/// The browser application in `Web/` and this one are the same instrument seen
/// through two windows, so they are drawn in the same colours: the values here
/// are the custom properties at the top of `Web/style.css`, light and dark
/// alike.
///
/// Only the paper around the instrument follows the system appearance. The
/// screen does not: an oscilloscope's face is dark on a bench under any
/// lighting, the trace colours are chosen against that dark, and a screen that
/// inverted with the system would make every reading a different colour from
/// the one the user learned.
enum Theme {
    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255, alpha: 1)
    }

    /// Resolved against whatever appearance the view is drawn in, so the window
    /// follows the system live rather than at launch.
    private static func paper(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light)
        })
    }

    private static func fixed(_ value: UInt32) -> Color { Color(nsColor: rgb(value)) }

    // The page around the instrument.
    static let page = paper(0xF2F3ED, 0x171C1A)
    static let panel = paper(0xFAFBF6, 0x1E2522)
    static let line = paper(0xDFE3D9, 0x2F3833)
    static let ink = paper(0x253329, 0xE2E8DF)
    static let muted = paper(0x778074, 0x8D9789)
    static let accent = paper(0x284A32, 0xA9D18C)
    static let accentSoft = paper(0xC4EDA0, 0x35513A)

    // The screen itself, the same under either appearance.
    static let screen = fixed(0x101917)
    static let screenEdge = fixed(0x25332C)
    static let grid = fixed(0x344238)
    static let gridStrong = fixed(0x607160)
    static let readout = fixed(0x8C9E90)
    static let screenInk = fixed(0xD4E0D3)

    /// The eight trace colours of `COLORS` in `Web/src/plot.mjs`. The analogue
    /// channels take the first three; the logic inputs take all eight, so D0
    /// and CH1 share a colour exactly as they do in the browser.
    static let traces: [Color] = [
        fixed(0xE9C96B), fixed(0x79CDD8), fixed(0xC0A1EF), fixed(0x9ED190),
        fixed(0xD8AD7F), fixed(0xA6BCEC), fixed(0xD592B9), fixed(0xAFBF7A),
    ]

    static func channelColor(_ index: Int) -> Color { traces[index % traces.count] }
    static func logicColor(_ index: Int) -> Color { traces[index % traces.count] }

    static let trigger = fixed(0xA3CD87)
    static let live = fixed(0xB8EF83)
    static let connected = fixed(0x77AD4C)
    static let clip = fixed(0xE69B7F)
    static let cursor = fixed(0xE58B72)

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
