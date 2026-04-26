import Foundation
import Testing
import AVFoundation
import MediaPlayer
@testable import TAClient

struct VideoDetailViewModelTests {

    private func makeSUT(
        videoId: String = "test-video-id",
        videoRepo: MockVideoRepository = MockVideoRepository()
    ) -> (VideoDetailViewModel, AppRouter) {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        let router = AppRouter(authState: authState)
        let vm = VideoDetailViewModel(videoId: videoId, videoRepository: videoRepo, authState: authState, router: router)
        return (vm, router)
    }

    @Test func loadVideo_success_setsVideo() async {
        let repo = MockVideoRepository()
        let expectedVideo = TestData.video(youtubeId: "v1", title: "My Video")
        repo.getVideoHandler = { _ in expectedVideo }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadVideo()

        #expect(vm.video?.youtubeId == "v1")
        #expect(vm.video?.title == "My Video")
        #expect(vm.isLoading == false)
        #expect(vm.errorMessage == nil)
    }

    @Test func loadVideo_unauthorized_routerHandles() async {
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in throw AppError.unauthorized }
        let (vm, router) = makeSUT(videoRepo: repo)

        await vm.loadVideo()

        #expect(router.appState == .login)
    }

    @Test func loadVideo_error_setsErrorMessage() async {
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in
            throw AppError.serverError(statusCode: 404, message: "Not Found")
        }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadVideo()

        #expect(vm.errorMessage != nil)
        #expect(vm.isLoading == false)
    }

    @Test func loadComments_success_populatesComments() async {
        let repo = MockVideoRepository()
        repo.getCommentsHandler = { _ in
            [TestData.comment(id: "c1"), TestData.comment(id: "c2")]
        }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadComments()

        #expect(vm.comments.count == 2)
        #expect(vm.isLoadingComments == false)
    }

    @Test func loadComments_failure_silentlyCaught() async {
        let repo = MockVideoRepository()
        repo.getCommentsHandler = { _ in
            throw AppError.network(underlying: nil)
        }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadComments()

        #expect(vm.comments.isEmpty)
        #expect(vm.isLoadingComments == false)
    }

    @Test func saveProgress_callsRepo() async {
        var capturedVideoId: String?
        var capturedPosition: Double?
        let repo = MockVideoRepository()
        repo.updateProgressHandler = { videoId, position in
            capturedVideoId = videoId
            capturedPosition = position
        }
        let (vm, _) = makeSUT(videoId: "my-video", videoRepo: repo)

        await vm.saveProgress(position: 42.5)

        #expect(capturedVideoId == "my-video")
        #expect(capturedPosition == 42.5)
    }

    @Test func toggleWatched_success_updatesVideo() async {
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(watched: false) }
        var capturedIsWatched: Bool?
        repo.setWatchedHandler = { _, isWatched in
            capturedIsWatched = isWatched
        }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadVideo()
        #expect(vm.video?.watched == false)

        await vm.toggleWatched()

        #expect(vm.video?.watched == true)
        #expect(capturedIsWatched == true)
    }

    @Test func toggleWatched_error_revertsState() async {
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(watched: true) }
        repo.setWatchedHandler = { _, _ in
            throw AppError.serverError(statusCode: 500, message: "Error")
        }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadVideo()
        #expect(vm.video?.watched == true)

        await vm.toggleWatched()

        #expect(vm.video?.watched == true)
        #expect(vm.errorMessage != nil)
    }

    @Test func startPosition_returnsVideoPosition() async {
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(position: 123.0) }
        let (vm, _) = makeSUT(videoRepo: repo)

        #expect(vm.startPosition == 0)

        await vm.loadVideo()
        #expect(vm.startPosition == 123.0)
    }

    @MainActor
    @Test func handlePlaybackFailure_setsErrorAndStopsPlayback() async {
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in TestData.video(youtubeId: "v1") }
        let (vm, _) = makeSUT(videoRepo: repo)

        await vm.loadVideo()

        #expect(vm.playbackError == nil)
        #expect(vm.isPlaying == false)

        vm.handlePlaybackFailure(message: "Test error message")

        #expect(vm.playbackError == "Test error message")
        #expect(vm.player == nil)
        #expect(vm.isPlaying == false)
        #expect(vm.isBuffering == false)
    }

    @MainActor
    @Test func handlePlaybackFailure_genericKeyResolves() async {
        let genericMessage = String(localized: "player_error_generic")
        let networkMessage = String(localized: "player_error_network")
        let mediaResetMessage = String(localized: "player_error_media_reset")

        // Ensure both localization keys resolve to non-empty strings (neither is raw key)
        #expect(!genericMessage.isEmpty)
        #expect(genericMessage != "player_error_generic")
        #expect(!networkMessage.isEmpty)
        #expect(networkMessage != "player_error_network")
        #expect(!mediaResetMessage.isEmpty)
        #expect(mediaResetMessage != "player_error_media_reset")
    }

    // MARK: - VM + PlayerSessionCoordinator integration
    //
    // Shared `waitForCondition` helper lives in `TestHelpers.swift`.

    /// Creates a VM with a valid token + loaded video so `startPlayback()` can
    /// create an AVPlayer. The mock repository returns a video with a valid
    /// URL; no actual streaming happens because the test doesn't attach the
    /// player to a UI and we stop playback before deallocation.
    @MainActor
    private func makePlayingVM() async -> (VideoDetailViewModel, AppRouter) {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        authState.setCredentials(token: "test-token", serverURL: "https://example.com")
        let router = AppRouter(authState: authState)
        let repo = MockVideoRepository()
        repo.getVideoHandler = { _ in
            TestData.video(youtubeId: "v1")
        }
        let vm = VideoDetailViewModel(videoId: "v1", videoRepository: repo, authState: authState, router: router)
        await vm.loadVideo()
        vm.startPlayback()
        return (vm, router)
    }

    @MainActor
    @Test func vm_mediaServicesReset_stopsPlayback_setsError() async {
        let (vm, _) = await makePlayingVM()
        // startPlayback creates the session coordinator inline; post the
        // mediaServicesWereResetNotification and confirm VM reacts.
        guard vm.player != nil else {
            Issue.record("AVPlayer was not created — startPlayback guard failed")
            return
        }

        NotificationCenter.default.post(
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )

        let cleared = await waitForCondition({ vm.player == nil })
        #expect(cleared, "Expected player to be cleared after mediaServicesWereReset")
        #expect(vm.playbackError == String(localized: "player_error_media_reset"))
        #expect(vm.isPlaying == false)
    }

    @MainActor
    @Test func vm_interruption_pausesPlayer() async {
        let (vm, _) = await makePlayingVM()
        guard let player = vm.player else {
            Issue.record("AVPlayer was not created — startPlayback guard failed")
            return
        }

        // Drive rate up so we can observe the pause() effect.
        player.play()

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: UInt(AVAudioSession.InterruptionType.began.rawValue)
            ]
        )

        let paused = await waitForCondition({ player.rate == 0 })
        #expect(paused, "Expected player.rate == 0 after interruption began")

        vm.stopPlayback()
    }

    @MainActor
    @Test func vm_headphonesUnplugged_pausesPlayer() async {
        let (vm, _) = await makePlayingVM()
        guard let player = vm.player else {
            Issue.record("AVPlayer was not created — startPlayback guard failed")
            return
        }
        player.play()

        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [
                AVAudioSessionRouteChangeReasonKey: UInt(AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue)
            ]
        )

        let paused = await waitForCondition({ player.rate == 0 })
        #expect(paused, "Expected player.rate == 0 after headphones unplugged")

        vm.stopPlayback()
    }

    @MainActor
    @Test func vm_stopPlayback_clearsSessionCoordinator() async {
        let (vm, _) = await makePlayingVM()
        guard vm.player != nil else {
            Issue.record("AVPlayer was not created — startPlayback guard failed")
            return
        }

        vm.stopPlayback()

        // Post interruption after stop — VM must NOT react (coordinator torn down)
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: UInt(AVAudioSession.InterruptionType.began.rawValue)
            ]
        )

        // Brief wait to let any stale observer fire (which would crash on nil player)
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(vm.player == nil)
        #expect(vm.isPlaying == false)
    }

    // MARK: - Task 7 (A2) — VM + NowPlayingController integration

    @MainActor
    @Test func vm_startAVPlayback_createsNowPlayingController() async {
        // Clear any lingering now-playing info from a previous test.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        let (vm, _) = await makePlayingVM()
        guard vm.player != nil else {
            Issue.record("AVPlayer was not created — startPlayback guard failed")
            return
        }

        // NowPlayingController.start() publishes info synchronously. Title
        // should match the fixture video's title from TestData.video.
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        #expect(info != nil, "nowPlayingInfo must be populated after startPlayback()")
        #expect(info?[MPMediaItemPropertyTitle] as? String == vm.video?.title)

        vm.stopPlayback()
    }

    // MARK: - Task 13 (D2) — DidPlayToEnd final save

    @MainActor
    @Test func vm_endOfPlayback_savesFinalPosition() async {
        // Build a VM with a mock repo that captures updateProgress calls and
        // a video with a known duration. We don't need an actual AVPlayer —
        // handleDidPlayToEnd() is driven directly to exercise the save path.
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        authState.setCredentials(token: "test-token", serverURL: "https://example.com")
        let router = AppRouter(authState: authState)
        let repo = MockVideoRepository()
        let fixture = TestData.video(youtubeId: "v-end", duration: 600)
        repo.getVideoHandler = { _ in fixture }

        var capturedVideoId: String?
        var capturedPosition: Double?
        repo.updateProgressHandler = { videoId, position in
            capturedVideoId = videoId
            capturedPosition = position
        }

        let vm = VideoDetailViewModel(
            videoId: "v-end",
            videoRepository: repo,
            authState: authState,
            router: router
        )
        await vm.loadVideo()

        // Drive the end-of-playback path synchronously.
        vm.handleDidPlayToEnd()

        // saveProgress is dispatched on a detached Task — poll until the
        // mock captures the call.
        let captured = await waitForCondition({ capturedPosition != nil }, timeoutSeconds: 2.0)
        #expect(captured, "Expected updateProgress to be called after handleDidPlayToEnd")
        #expect(capturedVideoId == "v-end")
        #expect(capturedPosition == Double(fixture.duration))
    }

    @MainActor
    @Test func vm_stopPlayback_clearsNowPlayingInfo() async {
        // Seed so we can observe the clear.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: "Leftover"
        ]

        let (vm, _) = await makePlayingVM()
        guard vm.player != nil else {
            Issue.record("AVPlayer was not created — startPlayback guard failed")
            return
        }

        vm.stopPlayback()

        #expect(MPNowPlayingInfoCenter.default().nowPlayingInfo == nil,
                "nowPlayingInfo must be cleared after stopPlayback()")
    }
}
