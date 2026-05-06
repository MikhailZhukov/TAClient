import SwiftUI
import AVFoundation

@main
struct TAClientApp: App {
    @State private var container = DependencyContainer.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Configure audio session category once at app launch. Activation is
        // deferred to `PlayerSessionCoordinator.start()` when playback begins
        // — avoids stealing audio focus from Music/Podcasts while the user is
        // only browsing the app.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container)
                .environment(container.router)
                .environment(container.authState)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        forceLayoutUpdate()
                    }
                }
        }
    }

    private func forceLayoutUpdate() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.rootViewController?.view.setNeedsLayout()
                window.rootViewController?.view.layoutIfNeeded()
            }
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
            NavigationStack {
                SplashView()
                    .navigationTitle("Tube Archivist")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .task {
                await autoLogin()
            }
        case .login:
            NavigationStack {
                LoginScreen { container.makeLoginViewModel() }
                    .navigationTitle("Tube Archivist")
                    .navigationBarTitleDisplayMode(.inline)
            }
        case .authenticated:
            NavigationStack(path: $router.path) {
                VideoListScreen { container.makeVideoListViewModel() }
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .videoList:
                            VideoListScreen { container.makeVideoListViewModel() }
                        case .videoDetail(let videoId):
                            VideoDetailScreen { container.makeVideoDetailViewModel(videoId: videoId) }
                        case .search:
                            SearchScreen { container.makeSearchViewModel() }
                        case .channelDetail(let channelId):
                            ChannelDetailScreen { container.makeChannelDetailViewModel(channelId: channelId) }
                        case .downloadQueue:
                            DownloadQueueScreen { container.makeDownloadQueueViewModel() }
                        case .playlistList:
                            PlaylistListScreen { container.makePlaylistListViewModel() }
                        case .playlistDetail(let playlistId):
                            PlaylistDetailScreen { container.makePlaylistDetailViewModel(playlistId: playlistId) }
                        case .settings:
                            SettingsScreen { container.makeSettingsViewModel() }
                        case .about:
                            AboutView()
                        }
                    }
            }
        }
    }

    private func autoLogin() async {
        do {
            let isValid = try await container.authRepository.ping()
            if isValid {
                try? await container.authRepository.fetchUserAccount()
                router.onLoginSuccess()
            } else {
                router.onAutoLoginFailed()
            }
        } catch {
            router.onAutoLoginFailed()
        }
    }
}
