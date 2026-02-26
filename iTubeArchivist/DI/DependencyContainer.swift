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

        router = AppRouter(authState: authState)
    }

    // MARK: - ViewModel Factories

    func makeLoginViewModel() -> LoginViewModel {
        LoginViewModel(authRepository: authRepository, authState: authState, router: router)
    }

    func makeVideoListViewModel() -> VideoListViewModel {
        VideoListViewModel(videoRepository: videoRepository, authRepository: authRepository, router: router)
    }

    func makeVideoDetailViewModel(videoId: String) -> VideoDetailViewModel {
        VideoDetailViewModel(videoId: videoId, videoRepository: videoRepository, authState: authState, router: router)
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
}
