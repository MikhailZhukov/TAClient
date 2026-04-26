import SwiftUI

struct LoginView: View {
    @Bindable var viewModel: LoginViewModel
    @FocusState private var serverURLFocused: Bool

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image("SplashLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)

            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(String(localized: "login_server_url"), text: $viewModel.serverURL)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .focused($serverURLFocused)
                        .onChange(of: serverURLFocused) { _, focused in
                            if focused && viewModel.serverURL.isEmpty {
                                viewModel.serverURL = "https://"
                            }
                        }
                        .onChange(of: viewModel.serverURL) {
                            let url = viewModel.serverURL
                            for scheme in ["https://", "http://"] {
                                let doubled = scheme + scheme
                                if url.hasPrefix(doubled) {
                                    viewModel.serverURL = String(url.dropFirst(scheme.count))
                                    return
                                }
                            }
                        }
                    Text(String(localized: "login_server_url_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField(String(localized: "login_username"), text: $viewModel.username)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                SecureField(String(localized: "login_password"), text: $viewModel.password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)

                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }

                Button {
                    Task {
                        await viewModel.login()
                    }
                } label: {
                    if viewModel.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text(String(localized: "login_button"))
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isLoading || viewModel.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.password.isEmpty)
            }
            .frame(maxWidth: 400)
            .padding(.horizontal)

            Spacer()
        }
        .geometryGroup()
    }
}
