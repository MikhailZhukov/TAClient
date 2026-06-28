import Foundation

/// Pure-function decision helpers for the preloader-reseed flow.
///
/// `VideoDetailViewModel`'s 1Hz AVPlayer time observer calls these on every
/// tick to decide whether a large playback-position jump warrants asking
/// `VideoCachePreloader.shared.reseedMain(...)` to drop and re-anchor the
/// `.main` cache region at the new byte. Extracted to a standalone struct
/// for testability — same pattern as
/// `AVPlayerView.Coordinator.shouldClampToEnd(...)` and
/// `VideoDetailViewModel.shouldSaveProgress(...)`.
///
/// Both methods are `static` and `nonisolated`-safe (no MainActor / actor
/// dependencies; struct itself has no stored state). Marked `Sendable` so
/// the call sites in the 1Hz observer's `progressQueue` closure stay clean
/// under Swift 6 strict concurrency.
nonisolated struct ReseedTrigger: Sendable {

    /// Guard band (in seconds) absorbing VBR linear-interpolation error
    /// when comparing playback position against region bounds expressed
    /// in seconds-space. The production code computes
    /// `byte = seconds * (totalSize / duration)`, which can overshoot or
    /// undershoot by up to ~300 MB on VBR content (per CLAUDE.md note on
    /// VBR-safe trim). Comparing in seconds-space with this guard band
    /// means the same systematic estimation error appears on both sides
    /// of the inequality and is tolerated. 30 seconds at typical bitrate
    /// equals roughly 10-150 MB of file bytes — well above the slop, well
    /// below the size of a meaningful scrub jump.
    static let guardSeconds: Double = 30.0

    /// Returns true when playback is so far outside the cached `.main`
    /// region in seconds-space that, even accounting for VBR estimation
    /// error, a reseed is warranted.
    ///
    /// Region bounds (in bytes) are converted to seconds using
    /// `avgByterate = totalSize / duration` — the SAME formula production
    /// uses elsewhere (`logCacheHealth` and the `currentByte` computation
    /// in the time observer). Estimation error is therefore systematic
    /// on both sides of the comparison.
    ///
    /// Defensive: returns `false` for degenerate inputs
    /// (`mainEndOffset <= mainStartOffset` — empty/inverted main region,
    /// `duration <= 0`, `totalSize <= 0`). Callers should treat `false`
    /// as "skip reseed for this tick".
    static func shouldReseed(
        currentSeconds: Double,
        mainStartOffset: Int64,
        mainEndOffset: Int64,
        totalSize: Int64,
        duration: Double,
        guardSeconds: Double = guardSeconds
    ) -> Bool {
        guard mainEndOffset > mainStartOffset, duration > 0, totalSize > 0 else { return false }
        let avgByterate = Double(totalSize) / duration
        let startSec = Double(mainStartOffset) / avgByterate
        let endSec = Double(mainEndOffset) / avgByterate
        return currentSeconds < startSec - guardSeconds
            || currentSeconds >= endSec + guardSeconds
    }

    /// Returns true when a reseed dispatch should be suppressed because a
    /// reseed to a similar byte target fired recently. Used by the VM's
    /// time-observer closure to coalesce rapid-scrub bursts into a small
    /// number of actual `reseedMain` calls.
    ///
    /// Both conditions must hold to suppress: (1) the last reseed was
    /// within `debounceInterval` seconds, AND (2) the new target byte is
    /// within `similarityBytes` of the last target. A scrub to a very
    /// different byte still fires immediately even within the window.
    static func shouldDebounce(
        now: CFAbsoluteTime,
        lastReseedAt: CFAbsoluteTime,
        targetByte: Int64,
        lastTargetByte: Int64,
        debounceInterval: CFAbsoluteTime,
        similarityBytes: Int64
    ) -> Bool {
        now - lastReseedAt < debounceInterval
            && abs(targetByte - lastTargetByte) < similarityBytes
    }
}
