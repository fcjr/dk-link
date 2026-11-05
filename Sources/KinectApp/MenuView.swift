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
                    ForEach(DepthMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Color", selection: $model.configuration.colorResolution) {
                    ForEach(ColorResolution.allCases) { Text($0 == .off ? "Off" : $0.rawValue).tag($0) }
                }
                Picker("Frame rate", selection: $model.configuration.frameRate) {
                    ForEach(FrameRate.allCases) { Text("\($0.rawValue) fps").tag($0) }
                }
            }
            .onChange(of: model.configuration) { _, _ in model.restart() }
            VStack(alignment: .leading, spacing: 2) {
                Text(depthSummary).font(.caption).foregroundStyle(.secondary)
                Button("What the depth data means…") { openWindow(id: "depthGuide"); NSApp.activate(ignoringOtherApps: true) }
                    .buttonStyle(.link).font(.caption)
            }
            Divider()
            Text("Syphon outputs, for apps without the TouchDesigner plugin").font(.caption).foregroundStyle(.secondary)
            ForEach(SyphonOutput.Stream.allCases) { stream in
                Toggle(stream.rawValue, isOn: Binding(
                    get: { model.output.streams.contains(stream) },
                    set: { on in if on { model.output.streams.insert(stream) } else { model.output.streams.remove(stream) } }))
                    .help(DepthCopy.help(for: stream))
            }
            Toggle("Flip vertically", isOn: $model.output.flipVertically)
                .help("Turn every Syphon image upside down, for apps that read the first row as the bottom.")
            HStack {
                Text("Color range")
                Slider(value: $model.output.previewRangeMillimetres, in: 500...10000, step: 100)
                Text(String(format: "%.1f m", model.output.previewRangeMillimetres / 1000)).font(.caption).monospacedDigit()
            }
            .help("The distance at the far end of the depth colours, in the colorized preview and the 8-bit preview channel. Display only; the data is unchanged.")
            Divider()
            Toggle("Send skeletons over OSC", isOn: $model.output.bodyTracking)
                .help("Joint positions of each tracked person as OSC messages over UDP. TouchDesigner's Kinect Azure CHOP does not need this.")
            if model.output.bodyTracking {
                HStack {
                    TextField("Host", text: $model.output.oscHost).frame(width: 120)
                    TextField("Port", value: $model.output.oscPort, format: .number.grouping(.never)).frame(width: 60)
                }
            }
            if model.state.isRunning && (model.output.bodyTracking || model.frameClientCount > 0) {
                Text("Body tracking: \(model.bodyCount) bod\(model.bodyCount == 1 ? "y" : "ies") · \(Int(model.bodyMilliseconds)) ms per frame")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            TouchDesignerSection()
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

    /// One line on what the chosen depth mode delivers, and the rate it really runs at.
    private var depthSummary: String {
        let mode = model.configuration.depthMode
        var parts: [String] = []
        if let range = DepthCopy.rangeText(mode) { parts.append("Reliable from \(range)") }
        let effective = model.configuration.effectiveFrameRate
        if effective != model.configuration.frameRate {
            parts.append("runs at \(effective.rawValue) fps, the fastest this setup allows")
        }
        let line = parts.joined(separator: "; ")
        return line.isEmpty ? mode.detail : line + ". " + mode.detail
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
