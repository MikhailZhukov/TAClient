import SwiftUI

struct AuthenticatedAsyncImage: View {
    let url: String?
    var placeholderColor: Color = Color(hex: 0x2A2A2A)
    @Environment(AuthState.self) private var authState
    @State private var image: UIImage?
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholderColor
            }
        }
        .onAppear {
            loadIfNeeded()
        }
        .onChange(of: url) {
            image = nil
            loadIfNeeded()
        }
        .onDisappear {
            loadTask?.cancel()
        }
    }

    private func loadIfNeeded() {
        guard image == nil,
              let urlString = url,
              let imageURL = URL(string: urlString) else { return }

        loadTask?.cancel()
        loadTask = Task {
            let loaded = await ImageCache.shared.image(for: imageURL, token: authState.token)
            if !Task.isCancelled {
                self.image = loaded
            }
        }
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
