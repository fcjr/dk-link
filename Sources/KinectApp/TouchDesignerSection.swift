import SwiftUI
import KinectKit

/// The menu's TouchDesigner section: the plugin the app carries, installed
/// into TouchDesigner's Plugins folder with one click, kept up to date.
@MainActor
final class TouchDesignerSectionModel: ObservableObject {
    @Published var state: TouchDesignerPluginInstaller.State = .touchDesignerNotFound
    @Published var touchDesignerRunning = false
    @Published var touchDesignerVersion: String?
    @Published var message: String?
    let installer = TouchDesignerPluginInstaller()

    func refresh() {
        state = installer.state()
        touchDesignerRunning = installer.isTouchDesignerRunning
        touchDesignerVersion = installer.touchDesigner()?.version
    }

    func install() {
        do {
            let version = try installer.install()
            message = "Installed \(version). " + (touchDesignerRunning ? "Restart TouchDesigner to load it." : "TouchDesigner will ask once to allow it.")
        } catch {
            message = "\(error)"
        }
        refresh()
    }

    func remove() {
        do {
            try installer.remove()
            message = touchDesignerRunning ? "Removed; restart TouchDesigner." : "Removed."
        } catch {
            message = "\(error)"
        }
        refresh()
    }
}

struct TouchDesignerSection: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var td = TouchDesignerSectionModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TouchDesigner").font(.caption).foregroundStyle(.secondary)
                if let version = td.touchDesignerVersion {
                    Text(version).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            HStack {
                Text(td.state.label).font(.callout).lineLimit(2)
                Spacer()
                switch td.state {
                case .notInstalled:
                    Button("Install") { td.install() }
                case .updateAvailable:
                    Button("Update") { td.install() }
                case .installed:
                    Text("Installed ✓").font(.callout).foregroundStyle(.green)
                case .touchDesignerNotFound, .noBundledPlugin:
                    EmptyView()
                }
            }
            if case .installed = td.state {
                HStack {
                    Button("Remove") { td.remove() }.controlSize(.small)
                    Spacer()
                }
            }
            if let message = td.message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if case .installed = td.state, model.frameClientCount == 0 {
                Text("In TouchDesigner, add a Kinect Azure (Mac) TOP or CHOP. Restart it if they are missing.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.frameClientCount > 0 {
                Text("\(model.frameClientCount) TouchDesigner client\(model.frameClientCount == 1 ? "" : "s") connected")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { td.refresh() }
    }
}
