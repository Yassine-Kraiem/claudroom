import SwiftUI
import ClaudroomCore

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchError: String?
    @State private var notificationResult: String?
    @State private var credentialResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .font(.caption)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        try LaunchAtLogin.set(newValue)
                        launchError = nil
                    } catch {
                        launchError = "Needs the bundled .app, not a raw binary"
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                }

            HStack(spacing: 8) {
                Button("Test notification") {
                    Task { notificationResult = await model.sendTestNotification() }
                }
                .controlSize(.small)
                if let notificationResult {
                    Text(notificationResult).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button("Forget stored credential") {
                    model.forgetStoredCredential()
                    credentialResult = "Deleted. Claude Code's own credential is untouched."
                }
                .controlSize(.small)
                if let credentialResult {
                    Text(credentialResult).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }

            if let launchError {
                Text(launchError).font(.system(size: 9)).foregroundStyle(.secondary)
            }

        }
    }
}
