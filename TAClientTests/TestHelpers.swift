import Foundation

/// Shared async polling helper for tests that observe state changes driven by
/// main-queue `NotificationCenter` observers or detached `Task`s. Polls the
/// supplied predicate at ~10ms intervals up to `timeoutSeconds`, yielding the
/// current thread between checks so main-queue observer callbacks and spawned
/// Tasks have a chance to drain.
///
/// Extracted so `PlayerSessionCoordinatorTests`, `VideoDetailViewModelTests`,
/// and future suites can share a single implementation instead of each
/// redefining a local `waitForCondition` / `waitForCallback`. The predicate
/// is `@MainActor`-isolated because both current call sites run inside
/// `@MainActor` suites and capture MainActor-isolated state (player rate,
/// notification-observer flags, etc.).
///
/// Signature mirrors the prior local helpers so call sites can be migrated
/// without re-ordering arguments: `waitForCondition({ flag }, timeoutSeconds: 2)`.
@MainActor
func waitForCondition(
    _ check: @escaping @MainActor () -> Bool,
    timeoutSeconds: Double = 1.0
) async -> Bool {
    let step: UInt64 = 10_000_000 // 10 ms
    let iterations = Int((timeoutSeconds * 1_000_000_000) / Double(step))
    for _ in 0..<iterations {
        if check() { return true }
        try? await Task.sleep(nanoseconds: step)
    }
    return check()
}
