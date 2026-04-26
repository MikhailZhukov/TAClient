import Foundation

@Observable
final class DependencyContainer {
    static let shared = DependencyContainer()

    // Local
    let keychainService: KeychainService
    let authState: AuthState

    // Network
    let apiClient: APIClient

    // Repositories
    let authRepository: AuthRepositoryProtocol
    let videoRepository: VideoRepositoryProtocol
    let searchRepository: SearchRepositoryProtocol
    let channelRepository: ChannelRepositoryProtocol
    let downloadRepository: DownloadRepositoryProtocol
    let playlistRepository: PlaylistRepositoryProtocol

    // Settings
    let sponsorBlockSettings: SponsorBlockSettings

    // Navigation
    let router: AppRouter

    private init() {
        keychainService = KeychainService()
        authState = AuthState(keychainService: keychainService)
        apiClient = APIClient(authState: authState)

        authRepository = AuthRepositoryImpl(apiClient: apiClient, authState: authState)
        videoRepository = VideoRepositoryImpl(apiClient: apiClient, authState: authState)
        searchRepository = SearchRepositoryImpl(apiClient: apiClient, authState: authState)
        channelRepository = ChannelRepositoryImpl(apiClient: apiClient, authState: authState)
        downloadRepository = DownloadRepositoryImpl(apiClient: apiClient, authState: authState)
        playlistRepository = PlaylistRepositoryImpl(apiClient: apiClient, authState: authState)

        sponsorBlockSettings = SponsorBlockSettings()
        router = AppRouter(authState: authState)
    }

    // MARK: - ViewModel Factories

    func makeLoginViewModel() -> LoginViewModel {
        LoginViewModel(authRepository: authRepository, router: router)
    }

    func makeVideoListViewModel() -> VideoListViewModel {
        VideoListViewModel(videoRepository: videoRepository, authRepository: authRepository, downloadRepository: downloadRepository, router: router)
    }

    func makeVideoDetailViewModel(videoId: String) -> VideoDetailViewModel {
        VideoDetailViewModel(videoId: videoId, videoRepository: videoRepository, authState: authState, router: router, sponsorBlockSettings: sponsorBlockSettings, playlistRepository: playlistRepository)
    }

    func makeSearchViewModel() -> SearchViewModel {
        SearchViewModel(searchRepository: searchRepository, router: router)
    }

    func makeChannelDetailViewModel(channelId: String) -> ChannelDetailViewModel {
        ChannelDetailViewModel(channelId: channelId, channelRepository: channelRepository, videoRepository: videoRepository, router: router)
    }

    func makeDownloadQueueViewModel() -> DownloadQueueViewModel {
        DownloadQueueViewModel(downloadRepository: downloadRepository, router: router)
    }

    func makePlaylistListViewModel() -> PlaylistListViewModel {
        PlaylistListViewModel(playlistRepository: playlistRepository, router: router)
    }

    func makePlaylistDetailViewModel(playlistId: String) -> PlaylistDetailViewModel {
        PlaylistDetailViewModel(playlistId: playlistId, playlistRepository: playlistRepository, videoRepository: videoRepository, router: router)
    }

    func makeSettingsViewModel() -> SettingsViewModel {
        SettingsViewModel(settings: sponsorBlockSettings)
    }
}
