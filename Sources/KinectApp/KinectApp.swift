import SwiftUI
import AppKit

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Stop the cameras so the device is left idle for the next program.
        AppModel.shared?.stop()
    }
}
