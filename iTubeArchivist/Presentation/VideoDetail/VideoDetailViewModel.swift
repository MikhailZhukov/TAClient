import Foundation
import AVFoundation

@Observable
final class VideoDetailViewModel {
    let videoId: String
    var video: Video?
    var comments: [Comment] = []
    var isLoading = true
    var isLoadingComments = false
    var errorMessage: String?
    var showDeleteDialog = false
    var selectedTab = 0
    var isPinned = false

    private let videoRepository: VideoRepositoryProtocol
    private let authState: AuthState
    private let router: AppRouter

    init(videoId: String, videoRepository: VideoRepositoryProtocol, authState: AuthState, router: AppRouter) {
        self.videoId = videoId
        self.videoRepository = videoRepository
        self.authState = authState
        self.router = router
    }

    var playerAsset: AVURLAsset? {
        guard let video, let url = URL(string: video.mediaUrl), let token = authState.token else { return nil }
        return AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": "Token \(token)"]]
        )
    }

    var startPosition: Double {
        video?.position ?? 0
    }

    func loadVideo() async {
        isLoading = true
        errorMessage = nil

        do {
            video = try await videoRepository.getVideo(id: videoId)
        } catch let error as AppError {
            if case .unauthorized = error {
                router.handleUnauthorized()
            } else {
                errorMessage = error.errorDescription
            }
        } catch {
            errorMessage = String(localized: "error_generic")
        }

        isLoading = false
    }

    func loadComments() async {
        isLoadingComments = true
        do {
            comments = try await videoRepository.getComments(videoId: videoId)
        } catch {}
        isLoadingComments = false
    }

    func saveProgress(position: Double) async {
        do {
            try await videoRepository.updateProgress(videoId: videoId, position: position)
        } catch {}
    }

    func deleteVideo() async {
        do {
            try await videoRepository.deleteVideo(id: videoId)
            router.goBack()
        } catch let error as AppError {
            if case .unauthorized = error {
                router.handleUnauthorized()
            }
        } catch {}
    }

    func deleteAndIgnoreVideo() async {
        do {
            try await videoRepository.deleteVideo(id: videoId)
            try await videoRepository.ignoreVideo(id: videoId)
            router.goBack()
        } catch let error as AppError {
            if case .unauthorized = error {
                router.handleUnauthorized()
            }
        } catch {}
    }

    func navigateToChannel(_ channelId: String) {
        router.navigate(to: .channelDetail(channelId: channelId))
    }
}
