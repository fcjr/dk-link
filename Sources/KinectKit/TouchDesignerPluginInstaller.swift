import Foundation
import AppKit

/// Installs, updates and removes the Kinect Azure TOP/CHOP plugins for
/// TouchDesigner from the copy the app carries. The app bundle holds the
/// plugin folder under Contents/PlugIns/TouchDesigner/Kinect Azure with a
/// VERSION stamp; TouchDesigner loads plugins from its own Plugins folder.
public final class TouchDesignerPluginInstaller {
    public static let folderName = "Kinect Azure"
    public static let stampName = "VERSION"
    public static let touchDesignerBundleID = "ca.derivative.TouchDesigner"

    public enum State: Equatable {
        case touchDesignerNotFound
        case noBundledPlugin
        case notInstalled(bundled: String)
        case installed(version: String)
        case updateAvailable(installed: String, bundled: String)

        public var label: String {
            switch self {
            case .touchDesignerNotFound: return "TouchDesigner not found in Applications"
            case .noBundledPlugin: return "This build carries no TouchDesigner plugin"
            case .notInstalled: return "Plugin not installed"
            case .installed(let version): return "Plugin installed (\(version))"
            case .updateAvailable(let installed, let bundled): return "Update available: \(installed) → \(bundled)"
            }
        }
    }

    public struct TouchDesignerApp: Equatable {
        public var url: URL
        public var version: String
    }

    /// Where the app's own copy lives. Nil when the build has none.
    public let bundledFolder: URL?
    /// TouchDesigner's Plugins directory (the user's, not a project's).
    public let pluginsRoot: URL
    private let fileManager = FileManager.default

    public init(bundledFolder: URL?, pluginsRoot: URL) {
        self.bundledFolder = bundledFolder
        self.pluginsRoot = pluginsRoot
    }

    /// The app's defaults: the bundled folder under Contents/PlugIns and the
    /// user's TouchDesigner099 Plugins directory.
    public convenience init() {
        let bundled = Bundle.main.builtInPlugInsURL?.appendingPathComponent("TouchDesigner").appendingPathComponent(TouchDesignerPluginInstaller.folderName)
        let exists = bundled.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent("Library/Application Support/Derivative/TouchDesigner099/Plugins")
        self.init(bundledFolder: exists ? bundled : nil, pluginsRoot: root)
    }

    public var installedFolder: URL { pluginsRoot.appendingPathComponent(TouchDesignerPluginInstaller.folderName) }

    public var bundledVersion: String? { bundledFolder.flatMap { version(in: $0) } }
    public var installedVersion: String? { version(in: installedFolder) }

    func version(in folder: URL) -> String? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent(TouchDesignerPluginInstaller.stampName), encoding: .utf8) else {
            // A folder without a stamp (installed by hand, or by build.sh) still counts as installed.
            return fileManager.fileExists(atPath: folder.appendingPathComponent("KinectAzureTOP.plugin").path) ? "unknown" : nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// TouchDesigner as installed: /Applications/TouchDesigner.app, else
    /// whatever Launch Services knows under its bundle id.
    public func touchDesigner() -> TouchDesignerApp? {
        var candidates: [URL] = [URL(fileURLWithPath: "/Applications/TouchDesigner.app")]
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TouchDesignerPluginInstaller.touchDesignerBundleID) {
            candidates.append(url)
        }
        for url in candidates where fileManager.fileExists(atPath: url.path) {
            let plist = url.appendingPathComponent("Contents/Info.plist")
            let version = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? "unknown"
            return TouchDesignerApp(url: url, version: version)
        }
        return nil
    }

    public var isTouchDesignerRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: TouchDesignerPluginInstaller.touchDesignerBundleID).isEmpty
    }

    public func state() -> State {
        guard touchDesigner() != nil else { return .touchDesignerNotFound }
        guard let bundled = bundledVersion else { return .noBundledPlugin }
        guard let installed = installedVersion else { return .notInstalled(bundled: bundled) }
        return TouchDesignerPluginInstaller.isNewer(bundled, than: installed) ? .updateAvailable(installed: installed, bundled: bundled) : .installed(version: installed)
    }

    /// Stamps look like "0.1.0+47c6d7e": a semantic version, optionally a
    /// build hash. A higher version wins; the same version with a different
    /// hash counts as newer (the bundled copy is what this app was built with);
    /// "unknown" is always older.
    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        if installed == "unknown" { return true }
        if candidate == installed { return false }
        let (cv, ch) = split(candidate), (iv, ih) = split(installed)
        for (a, b) in zip(cv, iv) where a != b { return a > b }
        if cv.count != iv.count { return cv.count > iv.count }
        return ch != ih
    }

    private static func split(_ stamp: String) -> ([Int], String) {
        let parts = stamp.split(separator: "+", maxSplits: 1)
        let numbers = parts.first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        return (numbers, parts.count > 1 ? String(parts[1]) : "")
    }

    public enum InstallError: Error, CustomStringConvertible {
        case nothingBundled
        case copyFailed(String)
        public var description: String {
            switch self {
            case .nothingBundled: return "This build carries no TouchDesigner plugin"
            case .copyFailed(let why): return "Could not install the plugin: \(why)"
            }
        }
    }

    /// Copies the bundled folder next to the target, then swaps it in, so a
    /// TouchDesigner that is scanning the folder never sees a half-written one.
    @discardableResult
    public func install() throws -> String {
        guard let bundled = bundledFolder else { throw InstallError.nothingBundled }
        do {
            try fileManager.createDirectory(at: pluginsRoot, withIntermediateDirectories: true)
            let staging = pluginsRoot.appendingPathComponent(".\(TouchDesignerPluginInstaller.folderName).installing-\(UUID().uuidString)")
            try fileManager.copyItem(at: bundled, to: staging)
            if fileManager.fileExists(atPath: installedFolder.path) {
                _ = try fileManager.replaceItemAt(installedFolder, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: installedFolder)
            }
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.copyFailed(error.localizedDescription)
        }
        return installedVersion ?? "unknown"
    }

    public func remove() throws {
        guard fileManager.fileExists(atPath: installedFolder.path) else { return }
        try fileManager.removeItem(at: installedFolder)
    }
}
