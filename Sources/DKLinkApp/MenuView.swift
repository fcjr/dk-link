import SwiftUI
import DKKit

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            section("Camera") {
                Picker("Depth", selection: $model.configuration.depthMode) {
                    ForEach(DepthMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("Color", selection: $model.configuration.colorResolution) {
                    ForEach(ColorResolution.allCases) { Text($0 == .off ? "Off" : $0.rawValue).tag($0) }
                }
                Picker("Frame rate", selection: $model.configuration.frameRate) {
                    ForEach(FrameRate.allCases) { Text("\($0.rawValue) fps").tag($0) }
                }
                Text(depthSummary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("What the depth data means…") { openWindow(id: "depthGuide"); NSApp.activate(ignoringOtherApps: true) }
                    .buttonStyle(.link).font(.caption)
            }
            .onChange(of: model.configuration) { _, _ in model.restart() }
            Divider()
            TouchDesignerSection()
            Divider()
            section("Syphon, for apps without the plugin") {
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
            }
            Divider()
            section("Skeletons") {
                Toggle("Send over OSC", isOn: $model.output.bodyTracking)
                    .help("Joint positions of each tracked person as OSC messages over UDP. TouchDesigner's DK Link CHOP does not need this.")
                if model.output.bodyTracking {
                    HStack {
                        TextField("Host", text: $model.output.oscHost).frame(width: 120)
                        TextField("Port", value: $model.output.oscPort, format: .number.grouping(.never)).frame(width: 60)
                    }
                }
                if model.state.isRunning && (model.output.bodyTracking || model.frameClientCount > 0) {
                    Text("Tracking \(model.bodyCount) \(model.bodyCount == 1 ? "person" : "people"), \(Int(model.bodyMilliseconds)) ms per frame")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            Toggle("Start when the camera is plugged in", isOn: $model.autoStart)
            if LoginItem.isAvailable { LoginItemToggle() }
            HStack(alignment: .firstTextBaseline) {
                Text(footer).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if let updater = Updates.controller?.updater {
                    CheckForUpdatesButton(updater: updater).controlSize(.small)
                }
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q").controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 9, height: 9)
                Text(model.state.label).font(.headline).lineLimit(2)
            }
            if model.state == .slowLink {
                Text("Depth needs USB 3. Plug the camera straight into the Mac with a USB 3 cable (the one in the box works), not through a hub, and connect its power supply.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.state.isRunning {
                Text(String(format: "%.0f fps, %.1f ms per frame, sensor %.0f °C", model.statistics.capturesPerSecond,
                            model.processingMilliseconds, model.statistics.sensorTemperatureCelsius))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if model.state.isRunning {
                    Button("Stop") { model.stop() }
                } else {
                    Button("Start") { model.start() }.disabled(model.state == .noDevice || model.state == .slowLink)
                }
                Button("Preview…") { openWindow(id: "preview"); NSApp.activate(ignoringOtherApps: true) }
                Spacer()
            }
        }
    }

    private var footer: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        var parts = ["DK Link \(version)".trimmingCharacters(in: .whitespaces)]
        if let firmware = model.firmware { parts.append("firmware \(firmware.depth)") }
        return parts.joined(separator: ", ")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
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
        case .slowLink: return .orange
        default: return .gray
        }
    }
}
