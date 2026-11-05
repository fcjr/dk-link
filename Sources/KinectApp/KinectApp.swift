import SwiftUI
import AppKit
import KinectKit

@main
struct KinectApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            Image(systemName: model.state.isRunning ? "camera.metering.matrix" : "camera.metering.none")
        }
        .menuBarExtraStyle(.window)

        Window("Kinect Preview", id: "preview") {
            PreviewWindow().environmentObject(model)
        }
        .defaultSize(width: 1000, height: 460)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app: no Dock icon, no main window on launch.
        NSApp.setActivationPolicy(.accessory)

        // Hidden: install the TouchDesigner plugin from the command line and quit.
        //   open -W "Kinect for Mac.app" --args --install-touchdesigner-plugin
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
