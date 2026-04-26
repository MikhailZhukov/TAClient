import UIKit
import SwiftUI
import Security
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    private var hostingController: UIHostingController<ShareOverlayView>?
    private let viewModel = ShareViewModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        let overlay = ShareOverlayView(viewModel: viewModel)
        let host = UIHostingController(rootView: overlay)
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        hostingController = host

        processShareInput()
    }

    private func processShareInput() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            finish(error: .invalidURL)
            return
        }

        // Collect all attachment providers
        let providers = extensionItems.compactMap(\.attachments).flatMap { $0 }

        // Try URL type first
        if let urlProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
            urlProvider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, _ in
                DispatchQueue.main.async {
                    if let url = item as? URL {
                        self?.handleURL(url)
                    } else {
                        self?.finish(error: .invalidURL)
                    }
                }
            }
            return
        }

        // Fallback: try plain text (YouTube app often shares URL as text)
        if let textProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
            textProvider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { [weak self] item, _ in
                DispatchQueue.main.async {
                    if let text = item as? String, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        self?.handleURL(url)
                    } else {
                        self?.finish(error: .invalidURL)
                    }
                }
            }
            return
        }

        finish(error: .invalidURL)
    }

    private func handleURL(_ url: URL) {
        guard let host = url.host?.lowercased(),
              host.contains("youtube.com") || host.contains("youtu.be") else {
            finish(error: .invalidURL)
            return
        }

        guard let (token, serverURL) = readCredentials() else {
            finish(error: .notLoggedIn)
            return
        }

        addToQueue(urlString: url.absoluteString, token: token, serverURL: serverURL)
    }

    // MARK: - Keychain (inline)

    private func readCredentials() -> (token: String, serverURL: String)? {
        guard let token = keychainLoad("auth_token"),
              let serverURL = keychainLoad("server_url") else {
            return nil
        }
        return (token, serverURL)
    }

    private func keychainLoad(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ru.mzhukov.TAClient",
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: "5AS4WKH94K.ru.mzhukov.TAClient",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - API Call (inline)

    private func addToQueue(urlString: String, token: String, serverURL: String) {
        guard let apiURL = URL(string: "\(serverURL)/api/download/") else {
            finish(error: .network)
            return
        }

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "data": [["youtube_id": urlString, "status": "pending"]]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            finish(error: .network)
            return
        }

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)

        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if error != nil {
                    self?.finish(error: .network)
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self?.finish(error: .network)
                    return
                }

                switch httpResponse.statusCode {
                case 200...299:
                    self?.finish()
                case 401, 403:
                    self?.finish(error: .unauthorized)
                default:
                    self?.finish(error: .server)
                }
            }
        }.resume()
    }

    // MARK: - Result handling

    private func finish(error: ShareError? = nil) {
        if let error {
            viewModel.state = .error(error)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.extensionContext?.cancelRequest(withError: NSError(domain: "ShareExtension", code: 1))
            }
        } else {
            viewModel.state = .success
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }
}

// MARK: - View Model

enum ShareError {
    case invalidURL
    case notLoggedIn
    case unauthorized
    case network
    case server

    var localizedMessage: String {
        switch self {
        case .invalidURL: String(localized: "share_error_invalid_url")
        case .notLoggedIn: String(localized: "share_error_not_logged_in")
        case .unauthorized: String(localized: "share_error_unauthorized")
        case .network: String(localized: "share_error_network")
        case .server: String(localized: "share_error_server")
        }
    }
}

enum ShareState {
    case loading
    case success
    case error(ShareError)
}

@Observable
class ShareViewModel {
    var state: ShareState = .loading
}

// MARK: - SwiftUI Overlay

struct ShareOverlayView: View {
    let viewModel: ShareViewModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                switch viewModel.state {
                case .loading:
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)

                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)

                case .error(let error):
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    Text(error.localizedMessage)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(32)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
