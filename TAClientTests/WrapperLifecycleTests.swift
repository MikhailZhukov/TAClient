import Foundation
import Testing
import SwiftUI
@testable import TAClient

/// Structural contract for the screen-wrapper pattern introduced to fix the
/// VM-recreation antipattern in `TAClientApp`.
///
/// **What these tests catch:** the wrappers (e.g. `VideoDetailScreen`) take a
/// `make: () -> VM` factory closure and call it exactly once inside their
/// public init (`_viewModel = State(wrappedValue: make())`). These tests prove
/// that contract by counting closure invocations. They catch the most likely
/// regressions:
/// - someone caches VMs by id in a static (factory called 0 times on cache hit)
/// - someone forgets to call `make()` at all
/// - someone accidentally calls `make()` twice (e.g. one for `@State`, one for
///   a redundant stored property)
///
/// **What these tests do NOT catch** (acknowledged gap):
/// - A refactor like `init(make: () -> VM) { _ = make(); _viewModel =
///   State(wrappedValue: defaultVM) }` would still pass — the factory result
///   is not stored, but the closure was invoked once. We accept this gap
///   because the alternative (poking at private `@State` storage) is overkill
///   relative to the regression risk; any reviewer reading the wrapper file
///   would notice the discarded result immediately.
/// - The actual "VM created once per push despite N body re-evals" SwiftUI
///   runtime property — that requires `UIHostingController` lifecycle driving
///   or `ViewInspector`. We verify it manually on a real device via Console
///   log capture (see plan Task 7).
///
/// The wrappers themselves do not need SwiftUI lifecycle to be driven — the
/// `@State(wrappedValue:)` storage is initialised eagerly by the public init.
@MainActor
struct WrapperLifecycleTests {

    // MARK: - Helpers

    private func makeMockVideoDetailViewModel(videoId: String = "test-video-id") -> VideoDetailViewModel {
        let (_, authState, router) = makeMockRouter()
        return VideoDetailViewModel(
            videoId: videoId,
            videoRepository: MockVideoRepository(),
            authState: authState,
            router: router
        )
    }

    private func makeMockChannelDetailViewModel(channelId: String = "test-channel-id") -> ChannelDetailViewModel {
        let (_, _, router) = makeMockRouter()
        return ChannelDetailViewModel(
            channelId: channelId,
            channelRepository: MockChannelRepository(),
            videoRepository: MockVideoRepository(),
            router: router
        )
    }

    private func makeMockPlaylistDetailViewModel(playlistId: String = "test-playlist-id") -> PlaylistDetailViewModel {
        let (_, _, router) = makeMockRouter()
        return PlaylistDetailViewModel(
            playlistId: playlistId,
            playlistRepository: MockPlaylistRepository(),
            videoRepository: MockVideoRepository(),
            router: router
        )
    }

    private func makeMockSearchViewModel() -> SearchViewModel {
        let (_, _, router) = makeMockRouter()
        return SearchViewModel(
            searchRepository: MockSearchRepository(),
            router: router
        )
    }

    private func makeMockDownloadQueueViewModel() -> DownloadQueueViewModel {
        let (_, _, router) = makeMockRouter()
        return DownloadQueueViewModel(
            downloadRepository: MockDownloadRepository(),
            router: router
        )
    }

    private func makeMockPlaylistListViewModel() -> PlaylistListViewModel {
        let (_, _, router) = makeMockRouter()
        return PlaylistListViewModel(
            playlistRepository: MockPlaylistRepository(),
            router: router
        )
    }

    private func makeMockSettingsViewModel() -> SettingsViewModel {
        SettingsViewModel(settings: SponsorBlockSettings())
    }

    private func makeMockVideoListViewModel() -> VideoListViewModel {
        let (_, _, router) = makeMockRouter()
        return VideoListViewModel(
            videoRepository: MockVideoRepository(),
            authRepository: MockAuthRepository(),
            downloadRepository: MockDownloadRepository(),
            router: router
        )
    }

    private func makeMockLoginViewModel() -> LoginViewModel {
        let (_, _, router) = makeMockRouter()
        return LoginViewModel(
            authRepository: MockAuthRepository(),
            router: router
        )
    }

    // MARK: - VideoDetailScreen

    @Test func videoDetailScreen_callsFactoryExactlyOncePerInit() {
        var callCount = 0
        _ = VideoDetailScreen {
            callCount += 1
            return self.makeMockVideoDetailViewModel(videoId: "v1")
        }
        #expect(callCount == 1)
    }

    @Test func videoDetailScreen_twoInstancesProduceTwoFactoryInvocations() {
        var callCount = 0
        _ = VideoDetailScreen {
            callCount += 1
            return self.makeMockVideoDetailViewModel(videoId: "v1")
        }
        _ = VideoDetailScreen {
            callCount += 1
            return self.makeMockVideoDetailViewModel(videoId: "v2")
        }
        #expect(callCount == 2)
    }

    // MARK: - ChannelDetailScreen

    @Test func channelDetailScreen_callsFactoryExactlyOncePerInit() {
        var callCount = 0
        _ = ChannelDetailScreen {
            callCount += 1
            return self.makeMockChannelDetailViewModel(channelId: "c1")
        }
        #expect(callCount == 1)
    }

    @Test func channelDetailScreen_twoInstancesProduceTwoFactoryInvocations() {
        var callCount = 0
        _ = ChannelDetailScreen {
            callCount += 1
            return self.makeMockChannelDetailViewModel(channelId: "c1")
        }
        _ = ChannelDetailScreen {
            callCount += 1
            return self.makeMockChannelDetailViewModel(channelId: "c2")
        }
        #expect(callCount == 2)
    }

    // MARK: - PlaylistDetailScreen

    @Test func playlistDetailScreen_callsFactoryExactlyOncePerInit() {
        var callCount = 0
        _ = PlaylistDetailScreen {
            callCount += 1
            return self.makeMockPlaylistDetailViewModel(playlistId: "p1")
        }
        #expect(callCount == 1)
    }

    @Test func playlistDetailScreen_twoInstancesProduceTwoFactoryInvocations() {
        var callCount = 0
        _ = PlaylistDetailScreen {
            callCount += 1
            return self.makeMockPlaylistDetailViewModel(playlistId: "p1")
        }
        _ = PlaylistDetailScreen {
            callCount += 1
            return self.makeMockPlaylistDetailViewModel(playlistId: "p2")
        }
        #expect(callCount == 2)
    }

    // MARK: - SearchScreen

    @Test func searchScreen_callsFactoryExactlyOncePerInit() {
        var callCount = 0
        _ = SearchScreen {
            callCount += 1
            return self.makeMockSearchViewModel()
        }
        #expect(callCount == 1)
    }

    @Test func searchScreen_twoInstancesProduceTwoFactoryInvocations() {
        var callCount = 0
        _ = SearchScreen {
            callCount += 1
            return self.makeMockSearchViewModel()
        }
        _ = SearchScreen {
            callCount += 1
            return self.makeMockSearchViewModel()
        }
        #expect(callCount == 2)
    }

    // MARK: - DownloadQueueScreen

    @Test func downloadQueueScreen_callsFactoryExactlyOncePerInit() {
        var callCount = 0
        _ = DownloadQueueScreen {
            callCount += 1
            return self.makeMockDownloadQueueViewModel()
        }
        #expect(callCount == 1)
    }

    @Test func downloadQueueScreen_twoInstancesProduceTwoFactoryInvocations() {
        var callCount = 0
        _ = DownloadQueueScreen {
            callCount += 1
            return self.makeMockDownloadQueueViewModel()
        }
        _ = DownloadQueueScreen {
            callCount += 1
            return self.makeMockDownloadQueueViewModel()
        }
        #expect(callCount == 2)
    }

    // MARK: - PlaylistListScreen

    @Test func playlistListScreen_callsFactoryExactlyOncePerInit() {
        var callCount = 0
        _ = PlaylistListScreen {
            callCount += 1
            return self.makeMockPlaylistListViewModel()
        }
        #expect(callCount == 1)
    }

    @Test func playlistListScreen_twoInstancesProduceTwoFactoryInvocations() {
        var callCount = 0
        _ = PlaylistListScreen {
            callCount += 1
            return self.makeMockPlaylistListViewModel()
        }
        _ = PlaylistListScreen {
            callCount += 1
            return self.makeMockPlaylistListViewModel()
        }
        #expect(callCount == 2)
    }

    // MARK: - SettingsScreen

    @Test func settingsScreen_callsFactoryExactlyOncePerInit() {
        var callCount = 0
        _ = SettingsScreen {
            callCount += 1
            return self.makeMockSettingsViewModel()
        }
        #expect(callCount == 1)
    }

    @Test func settingsScreen_twoInstancesProduceTwoFactoryInvocations() {
        var callCount = 0
        _ = SettingsScreen {
            callCount += 1
            return self.makeMockSettingsViewModel()
        }
        _ = SettingsScreen {
            callCount += 1
            return self.makeMockSettingsViewModel()
        }
        #expect(callCount == 2)
    }

    // MARK: - VideoListScreen

    @Test func videoListScreen_callsFactoryExactlyOncePerInit() {
        var callCount = 0
        _ = VideoListScreen {
            callCount += 1
            return self.makeMockVideoListViewModel()
        }
        #expect(callCount == 1)
    }

    @Test func videoListScreen_twoInstancesProduceTwoFactoryInvocations() {
        var callCount = 0
        _ = VideoListScreen {
            callCount += 1
            return self.makeMockVideoListViewModel()
        }
        _ = VideoListScreen {
            callCount += 1
            return self.makeMockVideoListViewModel()
        }
        #expect(callCount == 2)
    }

    // MARK: - LoginScreen

    @Test func loginScreen_callsFactoryExactlyOncePerInit() {
        var callCount = 0
        _ = LoginScreen {
            callCount += 1
            return self.makeMockLoginViewModel()
        }
        #expect(callCount == 1)
    }

    @Test func loginScreen_twoInstancesProduceTwoFactoryInvocations() {
        var callCount = 0
        _ = LoginScreen {
            callCount += 1
            return self.makeMockLoginViewModel()
        }
        _ = LoginScreen {
            callCount += 1
            return self.makeMockLoginViewModel()
        }
        #expect(callCount == 2)
    }
}
