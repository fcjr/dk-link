import SwiftUI
import ServiceManagement

/// Open at Login, backed by SMAppService so the System Settings > Login Items
/// list stays the source of truth. Off until the user turns it on.
final class LoginItem: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var error: String?

    /// Only a real app bundle can register itself; `swift run` cannot.
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    init() { refresh() }

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        error = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }
}

struct LoginItemToggle: View {
    @StateObject private var item = LoginItem()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open at login", isOn: Binding(get: { item.isEnabled }, set: { item.setEnabled($0) }))
            if item.status == .requiresApproval {
                HStack(spacing: 4) {
                    Text("Allow DK Link in Login Items to finish.").font(.caption).foregroundStyle(.secondary)
                    Button("Open Settings…") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            if let error = item.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { item.refresh() }
    }
}
