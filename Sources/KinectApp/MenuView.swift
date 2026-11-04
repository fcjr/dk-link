import SwiftUI
import KinectKit

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text(model.state.label).font(.headline).lineLimit(2)
            }
            if model.state.isRunning {
                Text(String(format: "%.0f fps · %.1f ms/frame · %.0f °C", model.statistics.capturesPerSecond,
                            model.processingMilliseconds, model.statistics.sensorTemperatureCelsius))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if model.state.isRunning {
                    Button("Stop") { model.stop() }
                } else {
                    Button("Start") { model.start() }.disabled({ if case .noDevice = model.state { return true } else { return false } }())
                }
                Button("Preview…") { openWindow(id: "preview"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
            }
            Divider()
            Group {
                Picker("Depth", selection: $model.configuration.depthMode) {
                    ForEach(DepthMode.allCases) { Text($0 == .off ? "Off" : $0.rawValue).tag($0) }
                }
                Picker("Color", selection: $model.configuration.colorResolution) {
                    ForEach(ColorResolution.allCases) { Text($0 == .off ? "Off" : $0.rawValue).tag($0) }
                }
                Picker("Rate", selection: $model.configuration.frameRate) {
                    ForEach(FrameRate.allCases) { Text("\($0.rawValue) fps").tag($0) }
                }
            }
            .onChange(of: model.configuration) { _, _ in model.restart() }
            Divider()
            Text("Syphon outputs").font(.caption).foregroundStyle(.secondary)
            ForEach(SyphonOutput.Stream.allCases) { stream in
                Toggle(stream.rawValue, isOn: Binding(
                    get: { model.output.streams.contains(stream) },
                    set: { on in if on { model.output.streams.insert(stream) } else { model.output.streams.remove(stream) } }))
            }
            Toggle("Flip vertically", isOn: $model.output.flipVertically)
            HStack {
                Text("Preview range")
                Slider(value: $model.output.previewRangeMillimetres, in: 500...10000, step: 100)
                Text("\(Int(model.output.previewRangeMillimetres)) mm").font(.caption).monospacedDigit()
            }
            Divider()
            Toggle("Body tracking → OSC", isOn: $model.output.bodyTracking)
            if model.output.bodyTracking {
                HStack {
                    TextField("Host", text: $model.output.oscHost).frame(width: 120)
                    TextField("Port", value: $model.output.oscPort, format: .number.grouping(.never)).frame(width: 60)
                    Text(model.state.isRunning ? "\(model.bodyCount) bod\(model.bodyCount == 1 ? "y" : "ies") · \(Int(model.bodyMilliseconds)) ms" : "")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Toggle("Start when a Kinect is plugged in", isOn: $model.autoStart)
            if let firmware = model.firmware {
                Text("Firmware \(firmware.depth) depth · \(firmware.rgb) rgb").font(.caption2).foregroundStyle(.tertiary)
            }
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 320)
    }

    private var statusColor: Color {
        switch model.state {
        case .running: return .green
        case .starting: return .yellow
        case .failed: return .red
        default: return .gray
        }
    }
}
