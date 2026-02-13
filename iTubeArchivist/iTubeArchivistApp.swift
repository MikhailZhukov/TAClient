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

        Group {
            if router.showLogin {
                LoginView(viewModel: container.makeLoginViewModel())
            } else {
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
    }
}
