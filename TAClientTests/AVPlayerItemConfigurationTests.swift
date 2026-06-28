import Testing
import Foundation
import AVFoundation
@testable import TAClient

/// Pins the AVPlayer appetite caps applied in `VideoDetailViewModel.startAVPlayback`
/// via the extracted `configurePlayerItemAppetite(_:)` helper.
///
/// Rationale: a 4K AV1 spike on iPad reached ~3.89 GB during initial buffering
/// because AVPlayer mis-measured `observedBitrate` as multi-Gbps during the
/// first HTTPS chunks and pre-fetched aggressively. Capping
/// `preferredPeakBitRate = 25 Mbps` (covers 4K AV1's 12-20 Mbps typical
/// envelope with VBR headroom) plus lowering `preferredForwardBufferDuration`
/// from 30s → 10s defeats both the appetite measurement bug and the
/// coded-stream pre-buffer. See
/// `docs/plans/20260527-fix-memory-pressure-recovery.md` Task 2 for context.
///
/// **Accessor strategy:** uses `@testable import TAClient` to call the
/// `internal` helper directly (the method is intentionally not `private` so
/// these tests can target it without spinning up `startAVPlayback`). Same
/// precedent as `SnapshotPlaybackContextTests` for `internal` helper access.
@MainActor
struct AVPlayerItemConfigurationTests {

    private func makeSUT() -> VideoDetailViewModel {
        let keychain = KeychainService()
        keychain.clearAll()
        let authState = AuthState(keychainService: keychain)
        let router = AppRouter(authState: authState)
        return VideoDetailViewModel(
            videoId: "test-video-id",
            videoRepository: MockVideoRepository(),
            authState: authState,
            router: router
        )
    }

    /// `AVURLAsset` constructed with a fake URL does NOT make network calls
    /// until something asks the asset to load (`AVPlayerItem.status` KVO,
    /// `loadValuesAsynchronously`, etc.). Just constructing the asset +
    /// item is safe and synchronous.
    private func makePlayerItem() -> AVPlayerItem {
        let url = URL(string: "https://example.com/test.mp4")!
        let asset = AVURLAsset(url: url)
        return AVPlayerItem(asset: asset)
    }

    @Test func playerItem_hasPreferredPeakBitRate25Mbps() {
        let vm = makeSUT()
        let item = makePlayerItem()

        vm.configurePlayerItemAppetite(item)

        #expect(item.preferredPeakBitRate == 25_000_000)
    }

    @Test func playerItem_hasPreferredForwardBufferDuration10s() {
        let vm = makeSUT()
        let item = makePlayerItem()

        vm.configurePlayerItemAppetite(item)

        #expect(item.preferredForwardBufferDuration == 10)
    }
}
