import DPScopeCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: ScopeModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScopeDisplayView(
                    frame: model.frame,
                    settings: model.settings,
                    mode: model.displayMode,
                    supplyVoltage: model.supplyVoltage
                )
                    .padding(10)
                if model.showMeasurements {
                    MeasurementsBar(model: model)
                }
                Divider()
                StatusBar(model: model)
            }
            .frame(minWidth: 520, minHeight: 380)

            Divider()
            ControlPanelView(model: model)
        }
        .frame(minWidth: 860, minHeight: 560)
        .toolbar { toolbarContent }
        .alert(
            "DPScope",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            ),
            presenting: model.errorMessage
        ) { _ in
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Source", selection: $model.selectedSource) {
                ForEach(model.availableSources, id: \.source) { entry in
                    Text(entry.label).tag(entry.source)
                }
            }
            .frame(minWidth: 200)
            .help("Switching source reconnects to it")
        }

        ToolbarItem {
            Button {
                model.refreshDevices()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .help("Look for attached scopes again")
        }

        ToolbarItem {
            Button(model.isConnected ? "Disconnect" : "Connect") {
                model.toggleConnection()
            }
        }

        ToolbarItem {
            Button {
                model.toggleRun()
            } label: {
                Label(model.isRunning ? "Stop" : "Run", systemImage: model.isRunning ? "stop.fill" : "play.fill")
            }
            .disabled(!model.isConnected)
        }

        ToolbarItem {
            Button {
                model.single()
            } label: {
                Label("Single", systemImage: "camera")
            }
            .disabled(!model.isConnected || model.isRunning || model.settings.mode == .datalog)
            .help("Acquire a single sweep")
        }

        ToolbarItem {
            Button {
                model.exportCSV()
            } label: {
                Label("Export", systemImage: "square.and.arrow.down")
            }
            .disabled(model.frame.isEmpty)
            .help("Export the current trace as CSV")
        }
    }
}

/// Per-channel readouts under the screen.
struct MeasurementsBar: View {
    @ObservedObject var model: ScopeModel

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ForEach(0..<2, id: \.self) { channel in
                if model.channelSettings(channel).isEnabled {
                    measurements(for: channel)
                }
            }
            Spacer()
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func measurements(for channel: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle().fill(Theme.color(forChannel: channel)).frame(width: 7, height: 7)
                Text("Ch\(channel + 1)").fontWeight(.semibold)
            }
            if model.frame.isClipped(channel) {
                Text("CLIP — out of range")
                    .foregroundStyle(.red)
            }
            if let frequency = model.frequency(forChannel: channel) {
                Text("freq \(Format.frequency(frequency))")
            }
            if let statistics = model.statistics(forChannel: channel) {
                Text("Vpp  \(Format.voltage(statistics.peakToPeak))")
                Text("mean \(Format.voltage(statistics.mean))")
                Text("rms  \(Format.voltage(statistics.rms))")
                Text("min  \(Format.voltage(statistics.minimum))")
                Text("max  \(Format.voltage(statistics.maximum))")
            } else {
                Text("no data").foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusBar: View {
    @ObservedObject var model: ScopeModel

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)
            Text(model.connectionSummary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(model.status)
                .foregroundStyle(.secondary)
            Text(model.sampleRateDescription)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            if model.isConnected {
                Text(String(format: "%.2f V rail", model.supplyVoltage))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var indicatorColor: Color {
        switch model.connection {
        case .connected: return model.isRunning ? .green : .yellow
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .gray
        }
    }
}
