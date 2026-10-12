import Foundation
import Testing
@testable import PiLyzerCore

@Suite("Code density")
struct CodeDensityTests {
    /// A sweep that is not a straight ramp: its density rises across the range.
    private func sweep(_ width: (Int) -> Double) -> [Int] {
        (0..<4096).map { code in Int((1000 + Double(code) / 4) * width(code)) }
    }

    @Test("An even converter reads one everywhere, whatever the sweep's shape")
    func even() {
        let density = CodeDensity.of(histogram: sweep { _ in 1 }, codes: 150..<3950)
        #expect(density.codes == 150..<3950)
        #expect(density.widths.allSatisfy { abs($0 - 1) < 0.02 })
        #expect(density.rmsDifferential < 0.01)
        #expect(density.codes { $0 > 1.5 }.isEmpty)
    }

    @Test("A wide code, a missing one and every eighth one narrow are each found")
    func uneven() {
        let density = CodeDensity.of(histogram: sweep { code in
            code == 511 ? 9 : code == 2047 ? 0 : code % 8 == 7 ? 0.25 : 1
        }, codes: 150..<3950)
        #expect(abs((density.width(of: 511) ?? 0) - 9) < 0.1)
        #expect(density.width(of: 2047) == 0)
        #expect(abs((density.width(of: 1000) ?? 0) - 1) < 0.02)
        #expect(density.codes { $0 > 1.5 } == [511])
        #expect(density.codes { $0 < 0.1 } == [2047])
        #expect(abs((density.typicalWidth { $0 % 8 == 7 } ?? 0) - 0.25) < 0.01)
        // One wide code puts a step of its extra width in the line.
        #expect(density.line.upperBound - density.line.lowerBound > 7)
        #expect(density.width(of: 100) == nil)
    }

    @Test("The differential is in LSB: the mean code is one wide")
    func differential() {
        let density = CodeDensity(firstCode: 0, widths: [1, 1, 0.5, 1.5, 4, 1])
        let errors = density.differential
        #expect(abs(errors.reduce(0, +)) < 1e-9)
        // Six codes, nine neighbour-widths between them: a neighbour is 2/3 LSB.
        #expect(abs(errors[4] - (4.0 * 6 / 9 - 1)) < 1e-9)
    }

    @Test("Sweeps are averaged, and how far apart they were is kept")
    func sweeps() {
        let first = CodeDensity(firstCode: 10, widths: [1, 2, 0])
        let second = CodeDensity(firstCode: 10, widths: [1, 4, 0])
        #expect(CodeDensity.mean([first, second]) == CodeDensity(firstCode: 10, widths: [1, 3, 0]))
        #expect(abs((CodeDensity.scatter([first, second]) ?? 0) - (2.0 / 6).squareRoot()) < 1e-9)
        #expect(CodeDensity.mean([first, CodeDensity(firstCode: 11, widths: [1, 2, 0])]) == nil)
    }
}
