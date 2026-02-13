import SwiftUI

@main
struct iTubeArchivistApp: App {
    @State private var container = DependencyContainer.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
                .environment(container.router)
                .environment(container.authState)
        }
    }
}

struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(DependencyContainer.self) private var container

    var body: some View {
        @Bindable var router = router

        switch router.appState {
        case .splash:
            SplashView()
                .task {
                    await autoLogin()
                }
        case .login:
            LoginView(viewModel: container.makeLoginViewModel())
        case .authenticated:
            NavigationStack(path: $router.path) {
                VideoListView(viewModel: container.makeVideoListViewModel())
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .videoList:
                            VideoListView(viewModel: container.makeVideoListViewModel())
                        case .videoDetail(let videoId):
                            VideoDetailView(viewModel: container.makeVideoDetailViewModel(videoId: videoId))
                        case .search:
                            SearchView(viewModel: container.makeSearchViewModel())
                        case .channelDetail(let channelId):
                            ChannelDetailView(viewModel: container.makeChannelDetailViewModel(channelId: channelId))
                        }
                    }
            }
        }
    }

    private func autoLogin() async {
        do {
            let isValid = try await container.authRepository.ping()
            if isValid {
                router.onLoginSuccess()
            } else {
                router.onAutoLoginFailed()
            }
        } catch {
            router.onAutoLoginFailed()
        }
    }
}
