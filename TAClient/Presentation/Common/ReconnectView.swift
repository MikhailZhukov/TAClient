import SwiftUI

/// Shown when the TA server is unreachable at startup (offline, restart, 5xx).
/// Credentials stay in the keychain — Retry re-runs the startup sequence and
/// Change server returns to login after a destructive confirmation.
struct ReconnectView: View {
    let serverName: String
    let retry: () async -> Void
    let changeServer: () -> Void

    @State private var isRetrying = false
    @State private var showChangeServerConfirmation = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(String(localized: "reconnect_title"))
                .font(.headline)
                .multilineTextAlignment(.center)
            if !serverName.isEmpty {
                Text(serverName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if isRetrying {
                ProgressView()
            }
            Button(String(localized: "reconnect_retry")) {
                isRetrying = true
                Task {
                    await retry()
                    isRetrying = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRetrying)
            Button(String(localized: "reconnect_change_server")) {
                showChangeServerConfirmation = true
            }
            .foregroundStyle(.secondary)
            // Disabled while a retry is in flight: confirming a server change
            // wipes credentials, and a late `attemptStartup()` completion must
            // not flip to `.authenticated` with an empty keychain.
            .disabled(isRetrying)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            String(localized: "reconnect_change_server_confirm_title"),
            isPresented: $showChangeServerConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "reconnect_change_server"), role: .destructive) {
                changeServer()
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "reconnect_change_server_confirm_message"))
        }
    }
}
