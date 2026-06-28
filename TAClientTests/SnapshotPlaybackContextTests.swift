import Foundation
import Testing
@testable import TAClient

/// Coverage for `VideoDetailViewModel.snapshotPlaybackContext(url:token:)`,
/// the locked-write helper introduced in the reseed-trigger plan
/// (`docs/plans/20260526-fix-preloader-follow-large-scrub.md`, Task 5).
///
/// The 1Hz reseed trigger (Task 6) reads `streamingURL` and `authToken` under
/// `progressStateLock` and passes them to `VideoCachePreloader.reseedMain`.
/// Snapshotting in `configureAsset` — the single asset-construction
/// chokepoint shared by `startAVPlayback` AND `handleAirPlayBecameActive` —
/// keeps the snapshot consistent with the AVPlayer's actual current asset,
/// including across AirPlay swaps. This file pins the helper's contract so a
/// regression that re-inlines or skips the locked write surfaces immediately.
///
/// **Accessor strategy:** uses `@testable import TAClient` to call the
/// helper directly (the method is `internal`, not `private`, expressly so
/// that `@testable` exposes it without a `_test` shim), then `Mirror` to
/// read the `nonisolated(unsafe) private var` storage. Same precedent as
/// `SeekTimestampInitTests` and `CoordinatorEndFlagWiringTests`.
@MainActor
struct SnapshotPlaybackContextTests {

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

    /// Pulls a stored property by name. Returns `nil` if the field is missing
    /// or has an unexpected type — failing the calling test loudly instead of
    /// silently passing.
    private func readChild<T>(_ vm: VideoDetailViewModel, label: String, as: T.Type) -> T? {
        let mirror = Mirror(reflecting: vm)
        for child in mirror.children where child.label == label {
            return child.value as? T
        }
        return nil
    }

    /// Read the stored `streamingURL` field. Returns `nil` either when the
    /// field exists but holds `nil`, OR when the cast fails / the field is
    /// missing — the `mirrorDiscoversSnapshotFields` sanity test below
    /// explicitly pins that the field is reachable by name, so a
    /// rename/move regression fails there rather than silently collapsing
    /// into the same `nil` return path here.
    private func readStreamingURL(_ vm: VideoDetailViewModel) -> URL? {
        let mirror = Mirror(reflecting: vm)
        for child in mirror.children where child.label == "streamingURL" {
            return child.value as? URL
        }
        return nil
    }

    private func readAuthToken(_ vm: VideoDetailViewModel) -> String? {
        let mirror = Mirror(reflecting: vm)
        for child in mirror.children where child.label == "authToken" {
            return child.value as? String
        }
        return nil
    }

    /// Sanity check that pins field reachability by name. If a future
    /// refactor renames or moves `streamingURL`/`authToken`, the simplified
    /// single-optional accessors above can no longer distinguish "field
    /// missing" from "field holds nil" — this test catches the structural
    /// regression independently of any value-write test.
    @Test func mirrorDiscoversSnapshotFields() {
        let vm = makeSUT()
        let labels = Mirror(reflecting: vm).children.compactMap { $0.label }
        #expect(labels.contains("streamingURL"),
                "Mirror could not find streamingURL — field renamed/moved?")
        #expect(labels.contains("authToken"),
                "Mirror could not find authToken — field renamed/moved?")
    }

    /// Baseline: freshly-constructed VM has nil URL + nil token (the snapshot
    /// has never been taken). Guards against any future change that
    /// pre-populates the fields in init from `authState.token` or similar —
    /// the contract is "set by configureAsset, cleared by stopPlayback,
    /// otherwise nil."
    @Test func freshVM_snapshotFields_areNil() {
        let vm = makeSUT()
        #expect(readStreamingURL(vm) == nil, "Fresh VM had non-nil streamingURL")
        #expect(readAuthToken(vm) == nil, "Fresh VM had non-nil authToken")
    }

    /// Happy path: snapshot writes both fields atomically — after one call
    /// with concrete URL + token, both Mirror reads observe the new values.
    @Test func snapshot_setsBothFields() {
        let vm = makeSUT()
        let url = URL(string: "https://archive.example/media/abc.mp4")!
        let token = "token-abc-123"

        vm.snapshotPlaybackContext(url: url, token: token)

        #expect(readStreamingURL(vm) == url)
        #expect(readAuthToken(vm) == token)
    }

    /// Idempotent overwrite: the second call replaces the first. Pins the
    /// "latest call wins" contract — important for the AirPlay swap path
    /// where `handleAirPlayBecameActive` rebuilds the asset and re-calls
    /// `configureAsset` with potentially-different auth context.
    @Test func snapshot_secondCall_overwritesFirst() {
        let vm = makeSUT()
        let firstURL = URL(string: "https://archive.example/media/first.mp4")!
        let secondURL = URL(string: "https://archive.example/media/second.mp4")!

        vm.snapshotPlaybackContext(url: firstURL, token: "token-first")
        vm.snapshotPlaybackContext(url: secondURL, token: "token-second")

        #expect(readStreamingURL(vm) == secondURL)
        #expect(readAuthToken(vm) == "token-second")
    }

    /// Clearing path: passing nil for both arguments wipes the snapshot.
    /// This is the exact shape `stopPlayback` relies on — if a future
    /// engineer ever changes the helper to ignore nil inputs (e.g. "only
    /// overwrite when both are non-nil"), `stopPlayback`'s clear becomes a
    /// silent no-op and the 1Hz trigger keeps firing after teardown.
    /// (The production clear in `stopPlayback` writes nil directly under
    /// `progressStateLock` rather than going through the helper, but this
    /// test pins the helper's own nil-clearing semantics for future callers.)
    @Test func snapshot_withNilInputs_clearsBothFields() {
        let vm = makeSUT()
        let url = URL(string: "https://archive.example/media/abc.mp4")!
        vm.snapshotPlaybackContext(url: url, token: "tok")

        vm.snapshotPlaybackContext(url: nil, token: nil)

        #expect(readStreamingURL(vm) == nil)
        #expect(readAuthToken(vm) == nil)
    }

    /// Mixed nil: passing nil for ONE argument writes nil for that side
    /// without affecting the other independently. Confirms the helper does
    /// NOT silently coalesce ("only overwrite when both are non-nil") —
    /// each field tracks its own argument verbatim.
    @Test func snapshot_withMixedNil_writesPerArgument() {
        let vm = makeSUT()
        let url = URL(string: "https://archive.example/media/abc.mp4")!
        vm.snapshotPlaybackContext(url: url, token: "tok-1")

        vm.snapshotPlaybackContext(url: url, token: nil)

        #expect(readStreamingURL(vm) == url)
        #expect(readAuthToken(vm) == nil)
    }
}
