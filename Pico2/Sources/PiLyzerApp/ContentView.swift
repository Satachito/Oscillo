import PiLyzerCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: ScopeModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                screen
                statusBar
            }
            Divider()
            ControlPanelView(model: model)
        }
        .frame(minWidth: 1040, minHeight: 640)
        .toolbar { toolbar }
        .alert("Instrument", isPresented: Binding(
            get: { model.errorText != nil },
            set: { if !$0 { model.errorText = nil } })) {
            Button("OK", role: .cancel) { model.errorText = nil }
        } message: {
            Text(model.errorText ?? "")
        }
    }

    @ViewBuilder private var screen: some View {
        switch model.settings.mode {
        case .scope: ScopeDisplayView(model: model)
        case .spectrum: SpectrumView(model: model)
        case .logic: LogicView(model: model)
        case .meter: MeterView(model: model)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.isConnected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(model.statusText)
            if !model.isConnected, let hint = model.busHint {
                Text("·").foregroundStyle(.secondary)
                Text(hint).foregroundStyle(.orange)
            }
            Spacer()
            if model.isRunning {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 14, height: 14)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(.bar)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Picker("", selection: $model.selectedSource) {
                ForEach(model.sources, id: \.source) { entry in
                    Text(entry.label).tag(entry.source)
                }
            }
            .labelsHidden()
            .frame(minWidth: 190)
            .disabled(model.isConnected)

            Button(model.isConnected ? "Disconnect" : "Connect") { model.toggleConnection() }
                .keyboardShortcut("k")
        }

        ToolbarItemGroup {
            Button { model.toggleRun() } label: {
                Label(model.isRunning ? "Stop" : "Run",
                      systemImage: model.isRunning ? "stop.fill" : "play.fill")
            }
            .disabled(!model.isConnected)

            Button { model.single() } label: {
                Label("Single", systemImage: "playpause")
            }
            .disabled(!model.isConnected || model.isRunning)

            Button { export() } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("e")
        }
    }

    private func export() {
        let document = model.exportText()
        guard !document.contents.isEmpty else {
            model.errorText = "There is nothing on screen to export yet."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.name
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.errorText = error.localizedDescription
        }
    }
}
