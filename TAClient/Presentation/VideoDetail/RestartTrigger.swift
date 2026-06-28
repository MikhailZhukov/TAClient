import Foundation

/// Pure-function decision helper for the preloader-restart-after-clear flow.
///
/// `VideoDetailViewModel`'s 1Hz AVPlayer time observer calls this on every
/// tick to decide whether the `.main` cache region has shrunk far enough
/// (e.g. after a `.critical` memory-pressure emergency-trim) that a fresh
/// preload restart from the current playhead is warranted.
///
/// Extracted to a standalone struct for testability — same pattern as
/// `ReseedTrigger`, `AVPlayerView.Coordinator.shouldClampToEnd(...)` and
/// `VideoDetailViewModel.shouldSaveProgress(...)`.
///
/// The method is `static` and `nonisolated`-safe (no MainActor / actor
/// dependencies; struct itself has no stored state). Marked `Sendable` so
/// the call sites in the 1Hz observer's `progressQueue` closure stay clean
/// under Swift 6 strict concurrency.
nonisolated struct RestartTrigger: Sendable {

    /// Cache threshold below which the restart hook fires. Single source of
    /// truth — the preloader's doc comments reference this constant rather
    /// than maintaining a duplicate copy.
    static let mainCachedByteThreshold: Int64 = 16 * 1024 * 1024

    /// Returns true when the VM's 1Hz observer should dispatch a preload
    /// restart. Pure function of cache state + time — does NOT consult
    /// AirPlay state or URL/token presence; the caller checks those
    /// before invoking.
    ///
    /// Logic: cache is too thin (`mainCachedByteCount < threshold`) AND
    /// cooldown has elapsed since the last restart attempt
    /// (`now - lastRestartAt >= cooldown`). The `<` on the threshold is
    /// strict (16 MB exactly is "enough"); the `>=` on the cooldown
    /// boundary is inclusive (exactly 15 s elapsed is "cooled down").
    ///
    /// Defensive: a negative elapsed time (clock skew where
    /// `now < lastRestartAt`) returns `false`. Callers should treat
    /// `false` as "skip restart for this tick".
    static func shouldRestart(
        mainCachedByteCount: Int64,
        lastRestartAt: CFAbsoluteTime,
        now: CFAbsoluteTime,
        cooldown: CFAbsoluteTime = 15.0,
        threshold: Int64 = mainCachedByteThreshold
    ) -> Bool {
        mainCachedByteCount < threshold && (now - lastRestartAt) >= cooldown
    }
}
