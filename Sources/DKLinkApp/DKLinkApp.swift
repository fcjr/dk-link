import SwiftUI
import AppKit
import DKKit

@main
struct DKLinkApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            MenuBarLabel(running: model.state.isRunning)
        }
        .menuBarExtraStyle(.window)

        Window("Preview", id: "preview") {
            PreviewWindow().environmentObject(model)
        }
        .defaultSize(width: 1000, height: 460)

        Window("What the depth data means", id: "depthGuide") {
            DepthGuideView().environmentObject(model)
        }
        .defaultSize(width: 640, height: 720)
    }
}

/// The menu bar icon; also where launch flags that need a window run, since
/// the label is the one view that exists as soon as the app does.
struct MenuBarLabel: View {
    let running: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: running ? "camera.metering.matrix" : "camera.metering.none")
            .onAppear {
                // Hidden: open the preview at launch, for screenshots and tests.
                if CommandLine.arguments.contains("--preview") {
                    openWindow(id: "preview")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app: no Dock icon, no main window on launch.
        NSApp.setActivationPolicy(.accessory)

        // Hidden: install the TouchDesigner plugin from the command line and quit.
        //   open -W "DK Link.app" --args --install-touchdesigner-plugin
        if CommandLine.arguments.contains("--install-touchdesigner-plugin") {
            let installer = TouchDesignerPluginInstaller()
            do {
                let version = try installer.install()
                print("installed TouchDesigner plugin \(version) into \(installer.installedFolder.path)")
            } catch {
                print("TouchDesigner plugin install failed: \(error)")
            }
            // Through terminate, so a camera the model may have auto-started is
            // stopped and closed rather than left claimed.
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop the cameras so the device is left idle for the next program.
        AppModel.shared?.stop()
    }
}
