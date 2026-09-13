import AppKit
import Foundation

/// The application's own icon, drawn rather than stored.
///
/// It is the same drawing in both places it is needed: `make-app.sh` asks the
/// built binary for an `.icns` to put in the bundle, and the application sets
/// it on itself at launch. That second one matters because a binary run
/// straight out of `.build` — `swift run PiLyzer` — has no bundle for the Dock
/// to read an icon from, and shows a generic one instead.
enum AppIcon {
    static func draw(size: CGFloat) -> NSBitmapImageRep {
        let pixels = Int(size)
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)

        let inset = size * 0.06
        let body = NSBezierPath(
            roundedRect: NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset),
            xRadius: size * 0.2, yRadius: size * 0.2
        )
        NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.16, alpha: 1).setFill()
        body.fill()

        let screenInset = size * 0.16
        let screenRect = NSRect(
            x: screenInset, y: screenInset,
            width: size - 2 * screenInset, height: size - 2 * screenInset
        )
        let screen = NSBezierPath(roundedRect: screenRect, xRadius: size * 0.06, yRadius: size * 0.06)
        NSColor(calibratedRed: 0.03, green: 0.06, blue: 0.08, alpha: 1).setFill()
        screen.fill()

        // Grid.
        NSColor(white: 1, alpha: 0.12).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = max(1, size * 0.004)
        for step in 1..<4 {
            let fraction = CGFloat(step) / 4
            let x = screenRect.minX + screenRect.width * fraction
            let y = screenRect.minY + screenRect.height * fraction
            grid.move(to: NSPoint(x: x, y: screenRect.minY))
            grid.line(to: NSPoint(x: x, y: screenRect.maxY))
            grid.move(to: NSPoint(x: screenRect.minX, y: y))
            grid.line(to: NSPoint(x: screenRect.maxX, y: y))
        }
        grid.stroke()

        // Trace.
        let trace = NSBezierPath()
        trace.lineWidth = max(2, size * 0.028)
        trace.lineCapStyle = .round
        trace.lineJoinStyle = .round
        let steps = 200
        for step in 0...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            let x = screenRect.minX + screenRect.width * fraction
            let phase = Double(fraction) * 2 * Double.pi * 1.6
            let y = screenRect.midY + screenRect.height * 0.30 * CGFloat(sin(phase))
            if step == 0 { trace.move(to: NSPoint(x: x, y: y)) } else { trace.line(to: NSPoint(x: x, y: y)) }
        }
        NSColor(calibratedRed: 1.0, green: 0.83, blue: 0.15, alpha: 1).setStroke()
        trace.stroke()

        NSGraphicsContext.restoreGraphicsState()
        return representation
    }

    static func image(size: CGFloat = 512) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(draw(size: size))
        return image
    }

    /// Writes the icon set a bundle wants, through the tool that packs one.
    static func writeICNS(to output: URL) throws {
        let iconset = output.deletingPathExtension().appendingPathExtension("iconset")
        try? FileManager.default.removeItem(at: iconset)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            guard let data = draw(size: CGFloat(size)).representation(using: .png, properties: [:])
            else { continue }
            let retina = size >= 32 && size % 2 == 0 ? "\(size / 2)x\(size / 2)@2x" : "\(size)x\(size)"
            try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
            try data.write(to: iconset.appendingPathComponent("icon_\(retina).png"))
        }
        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
        try iconutil.run()
        iconutil.waitUntilExit()
        try? FileManager.default.removeItem(at: iconset)
        guard iconutil.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
