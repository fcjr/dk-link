import XCTest
@testable import KinectKit

final class TouchDesignerInstallerTests: XCTestCase {
    private func makeFolder(_ name: String, in root: URL, stamp: String?) throws -> URL {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("KinectAzureTOP.plugin/Contents/Frameworks"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("KinectAzureCHOP.plugin/Contents/MacOS"), withIntermediateDirectories: true)
        try Data("lib".utf8).write(to: folder.appendingPathComponent("KinectAzureTOP.plugin/Contents/Frameworks/libKinectTD.dylib"))
        if let stamp { try (stamp + "\n").write(to: folder.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8) }
        return folder
    }

    func testVersionComparison() {
        XCTAssertTrue(TouchDesignerPluginInstaller.isNewer("0.2.0+abc", than: "0.1.0+abc"))
        XCTAssertFalse(TouchDesignerPluginInstaller.isNewer("0.1.0+abc", than: "0.2.0+abc"))
        XCTAssertFalse(TouchDesignerPluginInstaller.isNewer("0.1.0+abc", than: "0.1.0+abc"))
        XCTAssertTrue(TouchDesignerPluginInstaller.isNewer("0.1.0+def", than: "0.1.0+abc"), "same version, different build: the app's copy wins")
        XCTAssertTrue(TouchDesignerPluginInstaller.isNewer("0.1.0+abc", than: "unknown"))
        XCTAssertTrue(TouchDesignerPluginInstaller.isNewer("0.1.1", than: "0.1.0+abc"))
        XCTAssertTrue(TouchDesignerPluginInstaller.isNewer("0.1.0.1", than: "0.1.0"))
    }

    func testInstallUpdateRemoveInAScratchPluginsFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-installer-\(UUID().uuidString)")
        let bundled = try makeFolder("bundled", in: root, stamp: "0.1.0+aaa")
        let plugins = root.appendingPathComponent("Plugins")
        let installer = TouchDesignerPluginInstaller(bundledFolder: bundled, pluginsRoot: plugins)
        XCTAssertEqual(installer.bundledVersion, "0.1.0+aaa")
        XCTAssertNil(installer.installedVersion)
        XCTAssertEqual(installer.installedFolder.lastPathComponent, "Kinect Azure")

        XCTAssertEqual(try installer.install(), "0.1.0+aaa")
        XCTAssertEqual(installer.installedVersion, "0.1.0+aaa")
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.installedFolder.appendingPathComponent("KinectAzureTOP.plugin/Contents/Frameworks/libKinectTD.dylib").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.installedFolder.appendingPathComponent("KinectAzureCHOP.plugin/Contents/MacOS").path))
        // No staging leftovers.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: plugins.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [])

        // A newer bundled copy replaces it atomically; an older one is not an update.
        try "0.1.0+bbb\n".write(to: bundled.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        if case .updateAvailable(let installed, let candidate) = stateIgnoringTouchDesigner(installer) {
            XCTAssertEqual(installed, "0.1.0+aaa"); XCTAssertEqual(candidate, "0.1.0+bbb")
        } else { XCTFail("expected an update") }
        XCTAssertEqual(try installer.install(), "0.1.0+bbb")
        XCTAssertEqual(installer.installedVersion, "0.1.0+bbb")
        try "0.0.9\n".write(to: bundled.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        XCTAssertFalse(TouchDesignerPluginInstaller.isNewer(installer.bundledVersion!, than: installer.installedVersion!))

        // A hand-installed folder without a stamp reads as "unknown" and is updatable.
        try installer.remove()
        XCTAssertNil(installer.installedVersion)
        _ = try makeFolder("Kinect Azure", in: plugins, stamp: nil)
        XCTAssertEqual(installer.installedVersion, "unknown")
        XCTAssertTrue(TouchDesignerPluginInstaller.isNewer("0.0.9", than: "unknown"))
        try installer.remove()
        try installer.remove() // idempotent
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.installedFolder.path))
    }

    func testNothingBundled() {
        let installer = TouchDesignerPluginInstaller(bundledFolder: nil, pluginsRoot: FileManager.default.temporaryDirectory)
        XCTAssertNil(installer.bundledVersion)
        XCTAssertThrowsError(try installer.install())
    }

    /// The real state() also requires TouchDesigner on the machine; this
    /// evaluates the version logic alone.
    private func stateIgnoringTouchDesigner(_ installer: TouchDesignerPluginInstaller) -> TouchDesignerPluginInstaller.State {
        guard let bundled = installer.bundledVersion else { return .noBundledPlugin }
        guard let installed = installer.installedVersion else { return .notInstalled(bundled: bundled) }
        return TouchDesignerPluginInstaller.isNewer(bundled, than: installed) ? .updateAvailable(installed: installed, bundled: bundled) : .installed(version: installed)
    }
}
