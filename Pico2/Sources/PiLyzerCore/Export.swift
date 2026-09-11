import Foundation

/// Everything on screen, as text that a spreadsheet or a script can read.
public enum Export {
    public static func csv(scope frame: ScopeFrame) -> String {
        guard !frame.isEmpty else { return "" }
        var lines = ["time_s," + frame.traces.map { "channel\($0.index + 1)_V" }.joined(separator: ",")]
        for index in 0..<frame.sampleCount {
            var row = [String(format: "%.9g", frame.time(at: index))]
            for trace in frame.traces {
                row.append(index < trace.samples.count ? String(format: "%.7g", trace.samples[index]) : "")
            }
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func csv(spectra: [ChannelSpectrum], scale: SpectrumScale) -> String {
        guard let first = spectra.first, first.spectrum.count > 0 else { return "" }
        var header = ["frequency_Hz"]
        for entry in spectra {
            header += ["channel\(entry.channel + 1)_Vpeak", "channel\(entry.channel + 1)_\(scale.unit)"]
        }
        var lines = [header.joined(separator: ",")]
        for index in 0..<first.spectrum.count {
            var row = [String(format: "%.9g", Double(index) * first.spectrum.binWidth)]
            for entry in spectra {
                guard index < entry.spectrum.count else { row += ["", ""]; continue }
                let amplitude = entry.spectrum.amplitudes[index]
                row += [String(format: "%.7g", amplitude),
                        String(format: "%.5g", Spectrum.convert(amplitude: amplitude, scale: scale,
                                                                fullScale: entry.fullScale))]
            }
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func csv(logic frame: LogicFrame) -> String {
        guard !frame.isEmpty else { return "" }
        let channels = (0..<frame.channelCount).map { "D\($0)" }.joined(separator: ",")
        var lines = ["time_s,\(channels)"]
        for index in 0..<frame.samples.count {
            var row = [String(format: "%.9g", frame.time(at: index))]
            for channel in 0..<frame.channelCount {
                row.append(frame.level(channel, at: index) ? "1" : "0")
            }
            lines.append(row.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Only the transitions, which is a far smaller file than every sample and
    /// usually what a timing question actually needs.
    public static func csv(logicTransitions frame: LogicFrame) -> String {
        guard !frame.isEmpty else { return "" }
        var lines = ["time_s,channel,level"]
        for channel in 0..<frame.channelCount {
            for index in LogicAnalysis.transitions(of: frame, channel: channel) {
                lines.append(String(format: "%.9g,D%d,%d", frame.time(at: index), channel,
                                    frame.level(channel, at: index) ? 1 : 0))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func csv(decoded items: [DecodedItem], frame: LogicFrame) -> String {
        guard !items.isEmpty else { return "" }
        var lines = ["time_s,kind,value"]
        for item in items {
            let text = item.text.contains(",") ? "\"\(item.text)\"" : item.text
            lines.append(String(format: "%.9g,%@,%@", frame.time(at: item.start), item.kind.rawValue, text))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
