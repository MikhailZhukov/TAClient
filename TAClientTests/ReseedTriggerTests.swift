import Testing
import Foundation
@testable import TAClient

/// Pure-logic tests for `ReseedTrigger.shouldReseed(...)` and
/// `ReseedTrigger.shouldDebounce(...)`.
///
/// These guard the trigger condition that the VM's 1Hz time observer
/// uses to decide whether playback has drifted far enough outside the
/// cached `.main` region to warrant asking
/// `VideoCachePreloader.reseedMain(...)` to drop the old region and
/// re-anchor at the new byte.
///
/// **Test setup convention**: a "1 MB/s CBR-like file" is used throughout
/// (`totalSize = 1_000_000_000`, `duration = 1000` → `avgByterate = 1 MB/s`).
/// This makes seconds and megabytes line up cleanly in assertions: a
/// main region anchored at `[100_000_000 .. 200_000_000)` corresponds
/// to seconds `[100 .. 200)`. With the default `guardSeconds = 30`,
/// the "outside-with-margin" thresholds are seconds 70 and 230.
struct ReseedTriggerTests {

    // MARK: - shouldReseed

    /// Inside main range mid-region (s = 150, main = [100..200) in seconds) → false.
    @Test func inside_main_returnsFalse() {
        let result = ReseedTrigger.shouldReseed(
            currentSeconds: 150,
            mainStartOffset: 100_000_000,
            mainEndOffset: 200_000_000,
            totalSize: 1_000_000_000,
            duration: 1000
        )
        #expect(result == false)
    }

    /// At exact start of main range → false (lower bound inclusive).
    @Test func inside_main_at_lower_bound_returnsFalse() {
        let result = ReseedTrigger.shouldReseed(
            currentSeconds: 100,
            mainStartOffset: 100_000_000,
            mainEndOffset: 200_000_000,
            totalSize: 1_000_000_000,
            duration: 1000
        )
        #expect(result == false)
    }

    /// 20 s below start (within 30 s guard band) → false.
    @Test func within_guard_band_below_returnsFalse() {
        let result = ReseedTrigger.shouldReseed(
            currentSeconds: 80, // startSec=100, guard=30 → threshold=70
            mainStartOffset: 100_000_000,
            mainEndOffset: 200_000_000,
            totalSize: 1_000_000_000,
            duration: 1000
        )
        #expect(result == false)
    }

    /// 40 s below start (beyond 30 s guard band) → true.
    @Test func outside_guard_band_below_returnsTrue() {
        let result = ReseedTrigger.shouldReseed(
            currentSeconds: 60, // startSec=100, guard=30 → threshold=70; 60 < 70
            mainStartOffset: 100_000_000,
            mainEndOffset: 200_000_000,
            totalSize: 1_000_000_000,
            duration: 1000
        )
        #expect(result == true)
    }

    /// 20 s above end (within 30 s guard band) → false.
    @Test func within_guard_band_above_returnsFalse() {
        let result = ReseedTrigger.shouldReseed(
            currentSeconds: 220, // endSec=200, guard=30 → threshold=230
            mainStartOffset: 100_000_000,
            mainEndOffset: 200_000_000,
            totalSize: 1_000_000_000,
            duration: 1000
        )
        #expect(result == false)
    }

    /// 40 s above end (beyond 30 s guard band) → true.
    @Test func outside_guard_band_above_returnsTrue() {
        let result = ReseedTrigger.shouldReseed(
            currentSeconds: 240, // endSec=200, guard=30 → threshold=230; 240 >= 230
            mainStartOffset: 100_000_000,
            mainEndOffset: 200_000_000,
            totalSize: 1_000_000_000,
            duration: 1000
        )
        #expect(result == true)
    }

    /// Huge forward scrub far past endSec → true.
    @Test func forward_huge_jump_returnsTrue() {
        let result = ReseedTrigger.shouldReseed(
            currentSeconds: 800,
            mainStartOffset: 100_000_000,
            mainEndOffset: 200_000_000,
            totalSize: 1_000_000_000,
            duration: 1000
        )
        #expect(result == true)
    }

    /// Empty main (start == end) → false regardless of currentSeconds.
    @Test func empty_main_returnsFalse() {
        let result = ReseedTrigger.shouldReseed(
            currentSeconds: 500,
            mainStartOffset: 100_000_000,
            mainEndOffset: 100_000_000,
            totalSize: 1_000_000_000,
            duration: 1000
        )
        #expect(result == false)
    }

    /// Degenerate `duration = 0` → false (defensive; avoids divide-by-zero).
    @Test func zero_duration_returnsFalse() {
        let result = ReseedTrigger.shouldReseed(
            currentSeconds: 500,
            mainStartOffset: 100_000_000,
            mainEndOffset: 200_000_000,
            totalSize: 1_000_000_000,
            duration: 0
        )
        #expect(result == false)
    }

    /// Degenerate `totalSize = 0` → false (defensive; avoids 0/duration giving 0 byterate).
    @Test func zero_totalSize_returnsFalse() {
        let result = ReseedTrigger.shouldReseed(
            currentSeconds: 500,
            mainStartOffset: 100_000_000,
            mainEndOffset: 200_000_000,
            totalSize: 0,
            duration: 1000
        )
        #expect(result == false)
    }

    /// Caller-provided `guardSeconds = 5` makes a 10 s out-of-bounds jump trip the
    /// trigger even though it wouldn't with the default 30 s band.
    @Test func custom_guard_band_respected() {
        let result = ReseedTrigger.shouldReseed(
            currentSeconds: 90, // startSec=100, custom guard=5 → threshold=95; 90 < 95
            mainStartOffset: 100_000_000,
            mainEndOffset: 200_000_000,
            totalSize: 1_000_000_000,
            duration: 1000,
            guardSeconds: 5
        )
        #expect(result == true)
    }

    // MARK: - shouldDebounce

    /// Reseed just fired (1 s ago) to identical byte target → debounce (suppress).
    @Test func same_target_within_window_returnsTrue() {
        let result = ReseedTrigger.shouldDebounce(
            now: 1000.0,
            lastReseedAt: 999.0,
            targetByte: 500_000_000,
            lastTargetByte: 500_000_000,
            debounceInterval: 2.0,
            similarityBytes: 10_000_000
        )
        #expect(result == true)
    }

    /// Reseed fired 3 s ago to identical byte target → debounce window expired,
    /// allow new dispatch.
    @Test func same_target_after_window_returnsFalse() {
        let result = ReseedTrigger.shouldDebounce(
            now: 1000.0,
            lastReseedAt: 997.0,
            targetByte: 500_000_000,
            lastTargetByte: 500_000_000,
            debounceInterval: 2.0,
            similarityBytes: 10_000_000
        )
        #expect(result == false)
    }

    /// Reseed fired 1 s ago but new target is 20 MB away (> 10 MB similarity) →
    /// allow new dispatch despite being inside the time window.
    @Test func different_target_within_window_returnsFalse() {
        let result = ReseedTrigger.shouldDebounce(
            now: 1000.0,
            lastReseedAt: 999.0,
            targetByte: 520_000_000,
            lastTargetByte: 500_000_000,
            debounceInterval: 2.0,
            similarityBytes: 10_000_000
        )
        #expect(result == false)
    }
}
