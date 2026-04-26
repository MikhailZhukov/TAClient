import SwiftUI

struct AuthenticatedAsyncImage: View {
    let url: String?
    var placeholderColor: Color = Color(.secondarySystemBackground)
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
