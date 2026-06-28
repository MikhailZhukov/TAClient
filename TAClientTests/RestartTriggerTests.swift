import Testing
import Foundation
@testable import TAClient

/// Pure-logic tests for `RestartTrigger.shouldRestart(...)`.
///
/// These guard the trigger condition that the VM's 1Hz time observer uses
/// to decide whether the `.main` cache region has shrunk far enough — for
/// example after a `.critical` memory-pressure emergency-trim — that a
/// fresh preload restart from the current playhead is warranted.
///
/// **Constants under test**:
/// - `mainCachedByteThreshold = 16 MB` (strict `<`).
/// - Default `cooldown = 15.0 s` (inclusive `>=`).
/// Times use `CFAbsoluteTime` (Double); byte counts use `Int64`.
struct RestartTriggerTests {

    // MARK: - Cache-threshold + cooldown combinations

    /// Cache thin (8 MB < 16 MB) and cooldown elapsed (100 s since
    /// `lastRestartAt = 0` >> 15 s) → true.
    @Test func cacheBelowThreshold_andCooldownElapsed_returnsTrue() {
        let result = RestartTrigger.shouldRestart(
            mainCachedByteCount: 8 * 1024 * 1024,
            lastRestartAt: 0,
            now: 100,
            cooldown: 15
        )
        #expect(result == true)
    }

    /// Cache thin (8 MB) but only 5 s elapsed since lastRestartAt → false
    /// (cooldown not yet elapsed).
    @Test func cacheBelowThreshold_butCooldownNotElapsed_returnsFalse() {
        let result = RestartTrigger.shouldRestart(
            mainCachedByteCount: 8 * 1024 * 1024,
            lastRestartAt: 95,
            now: 100,
            cooldown: 15
        )
        #expect(result == false)
    }

    /// Cache above threshold (32 MB > 16 MB) and cooldown elapsed → false.
    @Test func cacheAboveThreshold_returnsFalse() {
        let result = RestartTrigger.shouldRestart(
            mainCachedByteCount: 32 * 1024 * 1024,
            lastRestartAt: 0,
            now: 100,
            cooldown: 15
        )
        #expect(result == false)
    }

    /// Cache exactly at the 16 MB threshold → false (strict `<`; "exactly
    /// enough" is enough).
    @Test func cacheAtExactThreshold_returnsFalse() {
        let result = RestartTrigger.shouldRestart(
            mainCachedByteCount: 16 * 1024 * 1024,
            lastRestartAt: 0,
            now: 100,
            cooldown: 15
        )
        #expect(result == false)
    }

    /// Cache empty (0 bytes), elapsed time exactly 15 s → true (inclusive
    /// `>=` boundary).
    @Test func cooldownAtExactBoundary_returnsTrue() {
        let result = RestartTrigger.shouldRestart(
            mainCachedByteCount: 0,
            lastRestartAt: 85,
            now: 100,
            cooldown: 15
        )
        #expect(result == true)
    }

    /// Defensive: clock skew where `now < lastRestartAt` makes the elapsed
    /// time negative → false. We never want to treat a backward clock jump
    /// as "cooldown satisfied".
    @Test func negativeElapsed_returnsFalse() {
        let result = RestartTrigger.shouldRestart(
            mainCachedByteCount: 0,
            lastRestartAt: 200,
            now: 100,
            cooldown: 15
        )
        #expect(result == false)
    }
}
