import Foundation
import OSLog

private nonisolated let logger = Logger(subsystem: "ru.mzhukov.TAClient", category: "VideoCachePreloader")

/// Actor wrapper around the synchronous `CacheStore`. Owns the in-flight
/// `preloadTask` and memory-pressure subscription. All cache state lives in
/// `store` so that non-actor code paths (e.g. `CachingResourceLoader`'s hot
/// read path) can access it without an executor hop.
///
/// Renamed from `VideoCache` in Task 10 (C1b). The loader and VM now read
/// `store` directly (sync, NSLock-guarded); this actor is strictly a
/// download orchestrator that owns lifecycle of the in-flight HTTP task.
actor VideoCachePreloader {
    static let shared = VideoCachePreloader()

    /// Synchronous storage — exposed to the actor and to the
    /// `CachingResourceLoader`. All mutable state lives behind its `NSLock`.
    nonisolated let store = CacheStore()

    private var preloadTask: Task<Void, Never>?
    /// VideoId associated with the currently-installed `preloadTask`. Kept
    /// strictly in sync with `preloadTask` assignments — set when assigning
    /// a new task, cleared when nilling. Used by `reseedMain`'s drain loop
    /// to refuse to cancel a peer video's task installed during our
    /// suspension window.
    ///
    /// Without this mirror, the drain loop scenario is:
    ///   1. `reseedMain(X)` enters, sees `preloadTask = T_X`, calls
    ///      `T_X.cancel()`, awaits `T_X.value` (SUSPENDS).
    ///   2. While suspended, peer `cancelPreload(X)` runs: nils
    ///      `preloadTask`, records `lastCancelledVideoId = X`.
    ///   3. User lands on a different video Y. Peer
    ///      `startPreloadWithRetry(Y)` runs: clears `lastCancelledVideoId`
    ///      (so the post-drain mirror check is silent), bumps generation,
    ///      installs `preloadTask = T_Y`.
    ///   4. `reseedMain(X)` resumes. Without the videoId check, the drain
    ///      loop sees `preloadTask = T_Y`, calls `T_Y.cancel()` and awaits
    ///      it — killing Y's preload before it can download a single byte.
    /// With the videoId mirror, step 4's loop sees
    /// `preloadTaskVideoId = Y != X` and exits the loop without touching
    /// the peer task.
    ///
    /// Exposed `internal` so `VideoCachePreloaderTests` can assert no
    /// peer-video task got killed by a stale reseed drain. The
    /// `@testable import` already restricts visibility to test-linked builds.
    var preloadTaskVideoId: String?
    /// Monotonic generation for the currently-stored `preloadTask`. The
    /// retry-wrapper Task captures its generation on spawn and clears
    /// `preloadTask` on exit **only** if the stored generation still matches
    /// — preventing a completing orphan from dropping a newer live preload.
    ///
    /// Exposed `internal` (not `private`) so `VideoCachePreloaderTests` can
    /// observe the bump that `reseedMain` performs without relying on
    /// indirect side-effects. The `@testable import` already restricts
    /// visibility to test-linked builds.
    var preloadGeneration: Int = 0
    /// VideoId of the most recent `cancelPreload(videoId:)` call. Used by
    /// `reseedMain` AFTER its drain-loop suspension to detect navigate-away
    /// races: the drain `await oldTask.value` suspends the actor; while
    /// suspended, a peer `cancelPreload(videoId:)` on this same actor can
    /// nil `preloadTask` AND record its videoId here. When the drain resumes
    /// it sees `preloadTask == nil` (correct exit), but the orphan-guard at
    /// the top of `reseedMain` already passed — without this field, the
    /// post-drain `store.currentVideoId() == videoId` check alone is not
    /// enough because `cancelPreload` does NOT clear the store entry.
    ///
    /// Scope: only the cancelPreload-style navigate-away path is covered.
    /// `.critical` memory-pressure mid-drain via `invalidatePreload` ALSO
    /// records here (the `invalidatePreload` body captures whatever
    /// videoId was associated with the cancelled task) so reseed bails for
    /// that case too. The drain loop's `preloadTaskVideoId == videoId`
    /// check covers cross-video navigate-away (peer startPreloadWithRetry
    /// for a different video during our suspension) — see `reseedMain`.
    ///
    /// Lifecycle: set in `cancelPreload` and `invalidatePreload`, cleared
    /// in `startPreloadWithRetry` on entry for the new videoId (the new
    /// preload supersedes the stale cancel record). Reading-and-comparing
    /// happens on the actor so no lock is needed — the actor's serial
    /// executor already provides mutual exclusion across hops.
    ///
    /// Exposed `internal` (not `private`) so `VideoCachePreloaderTests` can
    /// assert that `.critical` memory pressure records the cancelled videoId
    /// (Task 4 of `20260527-fix-memory-pressure-recovery.md`). The
    /// `@testable import` already restricts visibility to test-linked builds.
    var lastCancelledVideoId: String?
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    /// Defensive belt-and-suspenders bound for `reseedMain`'s drain loop. A
    /// pathological peer (e.g. a future bug that re-installs `preloadTask`
    /// from a non-actor caller without honouring cancellation) could
    /// theoretically spin the loop; the cap logs and bails rather than
    /// livelocking. In practice every live installer on the actor today
    /// honours cancellation so the loop drains in 1-2 iterations.
    private static let drainAttemptCap = 8

    /// Target size that `.critical` memory pressure trims `.main` down to.
    /// Softer than the previous `store.clear()` policy — the entry (videoId,
    /// totalSize, contentType, prefix region, lastPlaybackOffset) survives,
    /// which is what the restart hook needs to recover after the pressure
    /// subsides. See Task 4 of `20260527-fix-memory-pressure-recovery.md`.
    ///
    /// LOAD-BEARING value (8 MB, not 64 MB): the restart hook only fires
    /// when `.main` cached count is STRICTLY LESS than
    /// `RestartTrigger.mainCachedByteThreshold` (16 MB). If the trim target
    /// sits at or above the restart threshold, post-`.critical` steady
    /// state is "main has ~64 MB and no preload" —
    /// `RestartTrigger.shouldRestart` returns `false` forever, the cache
    /// permanently stalls at 64 MB, and the "rebuilds from current
    /// playhead" recovery never fires. 8 MB guarantees post-trim cache is
    /// below the threshold so the next 1Hz tick after the cooldown can
    /// dispatch a restart. See the code-review "threshold-vs-target
    /// mismatch" finding.
    private static let criticalTrimTargetBytes: Int = 8 * 1024 * 1024  // 8 MB

    /// Test hook: when non-nil, replaces the internal `URLSessionConfiguration.default`
    /// used by `downloadVideo`. Allows `MockURLProtocol` to intercept preload
    /// requests for unit tests covering auth-failure dispatch etc.
    ///
    /// Production code **MUST** leave this nil — it's read once on every
    /// `downloadVideo` entry. Setting it at runtime would route all future
    /// preloads through the test mock's URLProtocol and break real playback.
    /// The `nonisolated(unsafe)` marker is a Swift 6 concurrency opt-out
    /// acknowledged here because test setup/teardown runs serially on the
    /// MainActor — production reads from the preloader actor, but production
    /// never writes. Not gated with `#if DEBUG` because `@testable import`
    /// already restricts visibility to test-linked builds.
    nonisolated(unsafe) static var testSessionConfigurationOverride: URLSessionConfiguration?

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        memoryPressureSource = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            self.handleMemoryPressure(event: event)
        }
        source.resume()
    }

    /// Memory-pressure dispatch. Split from the raw handler so unit tests can
    /// drive the same logic path without synthesising a real DispatchSource
    /// pressure event (there is no public API to trigger one).
    ///
    /// - `.critical`: emergency-trim `.main` down to `criticalTrimTargetBytes`
    ///   (8 MB) AND cancel any in-flight preload. The prefix region is
    ///   pinned (only `emergencyTrim`'s main-only behaviour applies), and the
    ///   entry itself (videoId, totalSize, contentType, lastPlaybackOffset)
    ///   survives so the VM's restart hook can rebuild the cache from the
    ///   current playhead once the pressure subsides. The 8 MB target is
    ///   deliberately below `RestartTrigger.mainCachedByteThreshold` (16 MB)
    ///   so the next post-cooldown 1Hz tick observes `mainBytes < threshold` and fires
    ///   the restart — without that ordering the cache would permanently
    ///   stall at the trim target. Previous policy was
    ///   `store.clear()` — observed in real-device testing to wastefully nuke
    ///   recoverable state because the user's app routinely survived the
    ///   transient .critical spike. See Task 4 of
    ///   `20260527-fix-memory-pressure-recovery.md`.
    /// - `.warning` (anything else): trim the cache down to half of
    ///   `maxCacheSize`, keeping recently-played bytes. Preload keeps
    ///   running; `writeChunk` will re-trim if we overshoot again.
    nonisolated func handleMemoryPressure(event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical) {
            logger.info("[Mem] critical event rss=\(MemoryDiagnostics.residentMBString())")
            if let videoId = store.currentVideoId() {
                let removed = store.emergencyTrim(
                    videoId: videoId,
                    targetSize: Self.criticalTrimTargetBytes
                )
                if removed > 0 {
                    logger.info("[Mem] critical: emergency-trimmed \(removed / 1_000_000)MB (target \(Self.criticalTrimTargetBytes / 1_000_000)MB)")
                }
            }
            // Always cancel any in-flight preload — same as the prior
            // `store.clear()` + `invalidatePreload()` policy. `invalidatePreload`
            // records `lastCancelledVideoId` so a suspended `reseedMain` bails
            // on its post-drain mirror check.
            Task { await self.invalidatePreload() }
        } else {
            // .warning (or any non-critical signalled state)
            logger.info("[Mem] warning event rss=\(MemoryDiagnostics.residentMBString())")
            guard let videoId = store.currentVideoId() else { return }
            let targetSize = CacheStore.maxCacheSize / 2
            let removed = store.emergencyTrim(videoId: videoId, targetSize: targetSize)
            if removed > 0 {
                logger.info("[Mem] warning: emergency-trimmed \(removed / 1_000_000)MB (target \(targetSize / 1_000_000)MB)")
            }
        }
    }

    /// Cancel any in-flight preload task. Called after the store is cleared
    /// under memory pressure so we don't keep downloading into a nil entry.
    ///
    /// Also records `lastCancelledVideoId` so a `reseedMain` hop already
    /// past its pre-drain guard and suspended on `await oldTask.value`
    /// trips the post-drain mirror check and bails — without it, the
    /// memory-pressure-mid-drain case would re-spawn a download into the
    /// `.critical`-cleared store entry. We capture the cancelled videoId
    /// from `store.currentVideoId()` BEFORE the caller's `store.clear()`
    /// nils it out; the only public caller (`handleMemoryPressure` on
    /// `.critical`) calls us right after clearing, so we have to capture
    /// from the store directly here as a fallback when the entry is gone.
    private func invalidatePreload() {
        if let cancelledVideoId = preloadTaskVideoId ?? store.currentVideoId() {
            lastCancelledVideoId = cancelledVideoId
        }
        preloadTask?.cancel()
        preloadTask = nil
        preloadTaskVideoId = nil
    }

    // MARK: - Preloading

    func cancelPreload(videoId: String) {
        guard store.currentVideoId() == videoId else { return }
        preloadTask?.cancel()
        preloadTask = nil
        preloadTaskVideoId = nil
        // Record the cancelled videoId so `reseedMain` can detect a
        // mid-drain navigate-away race. Cleared by the next
        // `startPreloadWithRetry` for the same videoId (the new preload
        // supersedes the stale cancel record).
        lastCancelledVideoId = videoId
        logger.info("Cancelled preload for \(videoId)")
    }

    // MARK: - Data Access (test-only scaffolding)
    //
    // Production code reads `store.*` directly (sync, NSLock-guarded) — the
    // actor hop is unnecessary on the hot paths in `CachingResourceLoader`
    // and `VideoDetailViewModel`. These async delegates exist ONLY so that
    // `VideoCachePreloaderTests` can continue to exercise the end-to-end
    // preloader → store path through the actor. Do not call from production;
    // use `VideoCachePreloader.shared.store` instead.

    func readData(videoId: String, offset: Int64, length: Int) -> Data? {
        store.readData(videoId: videoId, offset: offset, length: length)
    }

    func cacheStatus(videoId: String) -> (startOffset: Int64, endOffset: Int64, totalSize: Int64, contentType: String)? {
        store.cacheStatus(videoId: videoId)
    }

    func updatePlaybackPosition(videoId: String, seconds: Double, duration: Double) {
        store.updatePlaybackPosition(videoId: videoId, seconds: seconds, duration: duration)
    }

    func isPreloading(videoId: String) -> Bool {
        guard store.currentVideoId() == videoId, let preloadTask else { return false }
        return !preloadTask.isCancelled
    }

    func clear() {
        preloadTask?.cancel()
        preloadTask = nil
        preloadTaskVideoId = nil
        store.clear()
    }

    // MARK: - Reseed

    /// Cancel the current preload, reset the `.main` region to a fresh empty
    /// region anchored at `atByte`, and restart download of
    /// `[atByte..<totalSize]` into `.main`. Prefix stays untouched.
    ///
    /// Used by `VideoDetailViewModel` when AVPlayer's playback position drifts
    /// outside the cached `.main` region (large forward scrub past
    /// `endOffset`, or backward scrub before `startOffset`). The store's
    /// `resetMainRegion` handles clamping; this method orchestrates the
    /// download lifecycle around it.
    ///
    /// No-op for:
    /// - `videoId` mismatch with the current entry
    /// - `atByte >= totalSize` (EOF reseed — nothing to download)
    /// - no `.main` region exists (small-file case, file fits in `.prefix`)
    ///
    /// No retry-wrapper: `StreamingSession` handles transport-level retry, and
    /// reseed is itself a recovery action — falling back to another reseed
    /// would just spin. Generation guard ensures a stale `downloadVideo`
    /// completing after we've reseeded does not clobber the new region.
    ///
    /// Logs `[Reseed] main reset @byte=N (was [start..end))` via the store —
    /// PERMANENT telemetry, NOT part of the v0.9.1 diagnostic-cleanup bucket.
    func reseedMain(videoId: String, atByte: Int64, url: URL, token: String) async {
        // Guard: videoId mismatch — preloader isn't tracking this video.
        guard store.currentVideoId() == videoId else { return }

        // Orphan-reseed guard: only reseed when a preload task is actually
        // active. A nil `preloadTask` means either (a) `stopPlayback` →
        // `cancelPreload` already ran BEFORE this reseed hop entered the
        // actor (user navigated away while this reseed hop was queued), or
        // (b) `.critical` memory pressure dropped the preload. In both
        // cases, dispatching a fresh download for a video the user has
        // stopped watching wastes bandwidth and may keep the session alive
        // past app suspend. The store's `currentVideoId()` check alone is
        // insufficient — `cancelPreload` does NOT clear the store entry,
        // so `currentVideoId()` would still match after the user navigated
        // away. The two-check pair (store still tracking AND preloadTask
        // still set) is the actual "is there a live preload to follow?"
        // signal AT THIS POINT.
        //
        // This guard catches navigate-away that happened BEFORE actor entry.
        // The mirror check AFTER the drain (`lastCancelledVideoId == videoId`)
        // catches navigate-away that happens DURING the drain's suspension —
        // see the post-drain block below.
        guard preloadTask != nil else { return }

        // Snapshot generation at entry. Used post-drain to bail if any peer
        // mutation (cancelPreload + startPreloadWithRetry for the SAME video,
        // concurrent reseedMain) bumped generation while we were suspended.
        // This is strictly stronger than the lastCancelledVideoId mirror: the
        // mirror gets cleared when `startPreloadWithRetry` re-installs a
        // preload for the same videoId during our suspension, silently
        // letting the drain loop kill the fresh task on resume. Generation
        // is monotonic and bumped by EVERY peer install path
        // (startPreloadWithRetry, reseedMain itself) — so any peer activity
        // for any video flips this snapshot. See the post-drain check below.
        let entryGeneration = preloadGeneration

        // Cancel current preload and AWAIT its completion before mutating
        // `.main`. Task cancellation is cooperative — without the await, the
        // cancelled task may still be inside `downloadRange`'s inner
        // chunk-writing loop and could call `writeChunk(toRegion: .main)`
        // AFTER `resetMainRegion` has anchored a fresh empty `.main` at a new
        // offset. Those stale bytes (from the OLD byte range) would land in
        // the NEW region as if they were at the new offset, corrupting
        // playback at the reseed target. Awaiting `.value` here yields the
        // actor so the cancelled task can drain — its `Task.sleep` calls in
        // the pause-gate are cancellation-aware, and the `for try await chunk
        // in chunks` loop checks `Task.isCancelled` on the next iteration, so
        // termination is fast. `downloadRange`'s inner `while
        // buffer.count >= chunkSize` loop also has an explicit
        // `Task.isCancelled` check before each `writeChunk` — that's
        // defense-in-depth for the case where a future caller spawns a
        // direct download task (not via `preloadTask`) and cancels it
        // without an await.
        //
        // **Drain loop** (not a single `if let`) — this loop EXISTS TO SOLVE
        // the following bug that a single `if let oldTask = preloadTask`
        // would expose: `await t.value` SUSPENDS the actor, and while we are
        // suspended, another `reseedMain` call for the SAME videoId
        // dispatched from the 1Hz observer can run on the actor, install
        // its own `newPreloadTask`, and drain. When THIS call resumes after
        // the suspension, a single `if let` would have already left the
        // cancel/await branch — we'd proceed to overwrite `preloadTask = nil`
        // (leaking the live newer task) and reset `.main` for the wrong
        // target. Looping `while let t = preloadTask` past every suspension
        // drains any same-video task installed during our suspension windows.
        //
        // **videoId-mirror exit** (`preloadTaskVideoId == videoId`): a peer
        // `startPreloadWithRetry(Y)` for a DIFFERENT video Y can also run
        // during our suspension (user navigated away from X to Y in between
        // our cancel and our resume). The peer's `cancelPreload(X)` clears
        // `preloadTask` first, and its `startPreloadWithRetry(Y)` installs
        // a new `preloadTask` for video Y. In this cross-video case the
        // post-drain `lastCancelledVideoId == videoId(X)` mirror check
        // below WOULD also fire (startPreloadWithRetry only clears the
        // record when `lastCancelledVideoId == newVideoId(Y)`, and here
        // it's `X != Y` so the record stays), but only AFTER the drain
        // loop has run — and a blind `while let oldTask = preloadTask`
        // would have already cancelled + awaited T_Y inside the loop
        // before we reach the post-drain check, killing Y's preload. The
        // videoId-mirror in the loop condition is the load-bearing
        // protection: it requires BOTH `preloadTask` non-nil AND
        // `preloadTaskVideoId == videoId`, so a peer video's task makes
        // us exit the loop cleanly without touching the peer.
        //
        // Iteration cap (`Self.drainAttemptCap`): see the declaration on the
        // type — defensive bound against pathological peers that re-install
        // `preloadTask` without honouring cancellation.
        var drainAttempts = 0
        while let oldTask = preloadTask, preloadTaskVideoId == videoId {
            if drainAttempts >= Self.drainAttemptCap {
                logger.error("[Reseed] drain loop exceeded \(Self.drainAttemptCap) iterations for \(videoId) — bailing out to avoid livelock")
                return
            }
            drainAttempts += 1
            oldTask.cancel()
            await oldTask.value
            // After resuming, re-check the actor's preloadTask pointer.
            // If another reseed/startPreload installed a new task during our
            // suspension, drain it too on the next loop iteration — but
            // only if it still belongs to OUR videoId.
        }
        // Loop exited because either: (a) preloadTask is nil (our own
        // drain finished and no peer re-installed), or (b) a peer
        // installed a different video's task — in which case the
        // post-drain `currentVideoId() == videoId` guard below will catch
        // it. Both exits are safe.

        // Post-drain navigate-away check. The pre-drain `guard preloadTask
        // != nil` (above) only catches navigate-away that happened BEFORE
        // we entered the actor. It does NOT catch navigate-away that
        // happens DURING the drain's `await oldTask.value` suspension:
        //   1. We enter `reseedMain` with `preloadTask` non-nil → guard
        //      passes.
        //   2. `await oldTask.value` suspends. While suspended, a peer
        //      `cancelPreload(videoId:)` runs on the actor (e.g.
        //      `stopPlayback` fired): it nils `preloadTask` and records
        //      `lastCancelledVideoId = videoId`. The store entry is NOT
        //      cleared (`cancelPreload` doesn't touch the store).
        //   3. The drain `while let` exits because `preloadTask` is nil.
        //   4. Without this check, `store.currentVideoId() == videoId`
        //      still passes (store entry was preserved), generation bumps,
        //      `resetMainRegion` runs, a fresh download spawns — and the
        //      user has navigated away. Wasted bandwidth + ghost URLSession.
        // The `lastCancelledVideoId` mirror lets us notice "this videoId
        // was cancelled during our suspension" cleanly.
        if lastCancelledVideoId == videoId { return }

        // Generation-bump bail. Covers the navigate-away-and-back race for
        // the SAME videoId that the mirror check above MISSES:
        //   1. `reseedMain(X)` enters, pre-drain guard passes, suspends on
        //      `await oldTask.value`.
        //   2. Peer `cancelPreload(X)` runs: nils `preloadTask`, sets
        //      `lastCancelledVideoId = X`.
        //   3. Peer `startPreloadWithRetry(X)` runs (user re-opened X
        //      quickly): clears `lastCancelledVideoId` (line ~743 — the
        //      "fresh preload supersedes prior cancel" reset), bumps
        //      `preloadGeneration`, installs a NEW `preloadTask = T_X2,
        //      preloadTaskVideoId = X`.
        //   4. `reseedMain(X)` resumes. Drain loop's `preloadTaskVideoId
        //      == videoId(X)` predicate holds, so the loop CANCELS T_X2 +
        //      awaits its value — killing the user's just-restarted
        //      preload. Mirror check above is silent (cleared at step 3).
        //      `resetMainRegion(atByte)` then runs with the stale atByte
        //      captured at step 1, anchoring a download at the previous
        //      session's reseed target — corrupting the fresh session.
        //
        // Generation is monotonic and bumped by every install path:
        // `startPreloadWithRetry` always bumps on entry (whether the prior
        // call was for the same or different video), and concurrent
        // `reseedMain` siblings bump just before they call `resetMainRegion`.
        // If generation has moved since entry, SOMEONE installed a fresh
        // preload state on this video — refuse to mutate it with our stale
        // atByte. Place this BEFORE our own `preloadGeneration &+= 1` bump
        // below so we don't compare our own bump.
        if preloadGeneration != entryGeneration { return }

        // Re-check invariants AFTER the drain. During our suspensions, the
        // user may have navigated away (cancelPreload nilled preloadTask and
        // we observed the nil exit), or the store entry may have been
        // cleared by `.critical` memory pressure. We must NOT seed a fresh
        // `.main` for a video the system has abandoned. We also refetch the
        // `.main` regionStatus — the pre-drain snapshot at line 176 is now
        // stale; `previousStart`/`previousEnd` for the resume-from-tail fast
        // path below must reflect post-drain reality.
        guard store.currentVideoId() == videoId else { return }
        guard let mainStatus = store.regionStatus(videoId: videoId, region: .main) else { return }
        let totalSize = mainStatus.totalSize

        // Guard: at or past EOF — nothing to download. The store would clamp
        // and remove `.main` entirely; rather than reseed-then-do-nothing,
        // skip the whole dance.
        guard atByte < totalSize else { return }

        // Bump generation so any in-flight `downloadVideo` from the previous
        // preload (which captured the old generation) sees the mismatch in
        // its tail check and skips the orphan `store.clear()` — preserving
        // both `.prefix` and the fresh `.main` we're about to seed.
        preloadGeneration &+= 1
        let generation = preloadGeneration

        // Reset `.main` to a fresh empty region at `atByte`. The store's
        // resetMainRegion handles clamping into `[prefixEnd, totalSize]` and
        // logs `[Reseed] main reset @byte=N (was [start..end))`. The store
        // additionally short-circuits when the clamped target equals the
        // existing `.main.startOffset` — backward scrubs into the prefix
        // region keep their accumulated `.main` bytes instead of being
        // wiped + re-downloaded from the same anchor.
        let previousStart = mainStatus.startOffset
        let previousEnd = mainStatus.endOffset
        store.resetMainRegion(videoId: videoId, newStartOffset: atByte)

        // Refetch the post-reset main start so we anchor the download at the
        // CLAMPED byte (resetMainRegion may have raised it to `prefixEnd`).
        // If `.main` is gone after reset (clamped == totalSize edge), the
        // earlier `atByte < totalSize` guard should have prevented this; bail
        // defensively rather than constructing an empty range.
        guard let newMain = store.regionStatus(videoId: videoId, region: .main) else { return }
        let mainStart = newMain.startOffset
        guard mainStart < totalSize else { return }

        // Resume-from-end fast path: when `resetMainRegion`'s clamp + no-op
        // short-circuit kept the old region intact, mainStart equals the
        // previous startOffset AND the old endOffset survived. Re-spawning
        // a download starting at mainStart would re-fetch bytes we already
        // have. Resume from the live tail instead (downloadRange handles
        // the empty-range no-op when endOffset==totalSize).
        let downloadStart = (mainStart == previousStart && newMain.endOffset == previousEnd)
            ? newMain.endOffset
            : mainStart
        guard downloadStart < totalSize else { return }

        let config = makeDownloadConfig()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.downloadRange(
                    videoId: videoId,
                    url: url,
                    token: token,
                    range: downloadStart..<totalSize,
                    into: .main,
                    config: config
                )
            } catch is CancellationError {
                // Cancellation observability lives in `downloadRange`'s
                // existing `Preload (\(region.name)) cancelled` log — no need
                // to log here.
            } catch {
                logger.error("Reseed main download error for \(videoId): \(error.localizedDescription)")
            }
            await self.finalizePreloadIfCurrent(generation: generation)
        }
        preloadTask = task
        preloadTaskVideoId = videoId
    }

    // MARK: - Restart

    /// Re-establish preload from the given playback position. Idempotent;
    /// cooldown enforcement lives on the VM side (avoids dual-timestamp
    /// confusion across files).
    ///
    /// No-op (returns `false`) when:
    /// - a preload is already in flight (`preloadTask != nil`),
    /// - the store has no entry for `videoId` (caller's responsibility to
    ///   not call us after a full `store.clear`),
    /// - `byteForStartPosition >= totalSize` (defensive — clock skew, rounded
    ///   `startPosition`, or a re-encoded file shrinking under us).
    ///
    /// Otherwise:
    /// 1. Compute `byteForStartPosition = Int64(startPosition * (totalSize / duration))`.
    /// 2. Call `store.resetMainRegion(videoId:, newStartOffset: byteForStartPosition)`.
    ///    This drops any post-`.critical`-trim leftover bytes that are at the
    ///    wrong anchor, ensuring `startPreloadWithRetry`'s `isCacheSufficient`
    ///    check doesn't short-circuit on stale-anchored cache.
    /// 3. Call `startPreloadWithRetry(...)`. The generation bump and
    ///    orphan-guard pattern are inherited from `startPreloadWithRetry`.
    ///
    /// Returns `true` if steps b–c ran (the restart was scheduled).
    ///
    /// Logs `[Restart] preload videoId=... startPosition=... rss=NNN MB`.
    /// Marker is PERMANENT (not v0.9.1 cleanup).
    ///
    /// # Design note: no `lastCancelledVideoId == videoId` guard
    ///
    /// Review iter 1 (commit 609e642) added a guard
    /// `if lastCancelledVideoId == videoId { return false }` at the top of
    /// this function to defend against a narrow restart-vs-stopPlayback race
    /// (observer dispatches restart → user pops VideoDetail → stopPlayback
    /// calls `cancelPreload(videoId:)`, which records the cancel). Review
    /// iter 2 REMOVED that guard because it broke the dominant scenario the
    /// entire restart-hook plan exists to fix:
    /// `handleMemoryPressure(.critical)` calls `invalidatePreload`, which
    /// records `lastCancelledVideoId = videoId` for the currently-playing
    /// video. After the 15 s VM-side cooldown the 1 Hz restart hook would
    /// trip Guard 2 and bail FOREVER (no code path clears
    /// `lastCancelledVideoId` before reaching `startPreloadWithRetry`,
    /// because the guard short-circuited the restart path). The narrow
    /// stopPlayback race is already covered on the VM side: stopPlayback
    /// nils `streamingURL` + `authToken` synchronously before the
    /// `cancelPreload` Task lands, and `evaluateRestartDispatch` returns
    /// `nil` when either is `nil` — so the observer never even dispatches
    /// a restart Task after stopPlayback. The residual window (Task already
    /// dispatched, then stopPlayback) at worst installs one preload Task
    /// that gets superseded by the next `loadVideo`/`startPreloadWithRetry`
    /// for a different videoId (which calls `store.clear()`). Do NOT
    /// re-introduce the guard without auditing the `.critical` recovery
    /// path. See `restartPreloadIfNeeded_afterCritical_succeeds` test.
    @discardableResult
    func restartPreloadIfNeeded(
        videoId: String,
        url: URL,
        token: String,
        startPosition: Double,
        duration: Double
    ) async -> Bool {
        // Guard 1: preload already in flight — VM cooldown should normally
        // prevent this, but a 1Hz observer + slow startPreloadWithRetry
        // could race. Refuse to clobber a live task.
        guard preloadTask == nil else { return false }

        // Guard 2: no entry — caller must seed via setEntry or a prior
        // startPreloadWithRetry. After a full `store.clear` (no longer the
        // `.critical` policy, but still possible via explicit `clear()`)
        // there's nothing for us to restart against.
        guard let anyRegionStatus = store.regionStatus(videoId: videoId, region: .main)
                ?? store.regionStatus(videoId: videoId, region: .prefix)
        else { return false }
        let totalSize = anyRegionStatus.totalSize
        guard totalSize > 0, duration > 0 else { return false }

        // Guard 3: byte at or past EOF — degenerate range; nothing to
        // download. Cheaper than letting `setEntry` clamp and then having
        // `downloadVideo` skip the empty main range.
        let byteForStartPosition = Int64(startPosition * (Double(totalSize) / duration))
        guard byteForStartPosition < totalSize else { return false }

        logger.info("[Restart] preload videoId=\(videoId) startPosition=\(startPosition)s rss=\(MemoryDiagnostics.residentMBString())")

        // Drop any post-`.critical`-trim leftover at the wrong anchor.
        // LOAD-BEARING: without this, `startPreloadWithRetry`'s
        // `isCacheSufficient` check would observe the residual main bytes
        // (up to `criticalTrimTargetBytes`, currently 8 MB) cached at the
        // OLD anchor and short-circuit, silently no-op'ing the restart.
        // By resetting main first, we force a fresh download from the
        // current playhead. Sacrificing those bytes is acceptable — they
        // were at the wrong anchor anyway.
        store.resetMainRegion(videoId: videoId, newStartOffset: byteForStartPosition)

        // startPreloadWithRetry handles generation bump, orphan guard,
        // and lastCancelledVideoId reset (the "fresh preload supersedes
        // prior cancel" path on entry).
        startPreloadWithRetry(
            videoId: videoId,
            url: url,
            token: token,
            startPosition: startPosition,
            duration: duration
        )
        return true
    }

    // MARK: - Download

    /// Build the URLSession configuration used by the preloader's GET and HEAD
    /// requests. Honors the `testSessionConfigurationOverride` test hook so
    /// `MockURLProtocol` can intercept network traffic; production code paths
    /// build a fresh `URLSessionConfiguration.default` with cookie storage and
    /// response caching disabled (we manage our own cache).
    private func makeDownloadConfig() -> URLSessionConfiguration {
        Self.testSessionConfigurationOverride ?? {
            let c = URLSessionConfiguration.default
            c.httpCookieStorage = nil
            c.urlCache = nil
            return c
        }()
    }

    /// Perform a HEAD probe to discover `totalSize` and `contentType`. Returns
    /// `nil` if the probe is unauthorized (401/403; notification already
    /// posted) or fails for any reason — callers should treat that as an
    /// abort signal for the entire preload.
    private func probeTotalSize(videoId: String, url: URL, token: String, config: URLSessionConfiguration) async -> (totalSize: Int64, contentType: String)? {
        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"
        headRequest.setValue("Token \(token)", forHTTPHeaderField: "Authorization")

        let headSession = URLSession(configuration: config)
        defer { headSession.finishTasksAndInvalidate() }

        guard
            let (_, headResponse) = try? await headSession.data(for: headRequest),
            let http = headResponse as? HTTPURLResponse
        else {
            return nil
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            logger.error("Preload HEAD unauthorized for \(videoId): \(http.statusCode)")
            // Post with `videoId` as `object` so tests can scope
            // observers by sender and avoid cross-test bleed.
            NotificationCenter.default.post(name: .taAuthUnauthorized, object: videoId)
            return nil
        }
        guard (200...299).contains(http.statusCode) else {
            logger.error("Preload HEAD failed for \(videoId): status \(http.statusCode)")
            return nil
        }
        let totalSize = http.expectedContentLength
        guard totalSize > 0 else { return nil }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "video/mp4"
        return (totalSize, contentType)
    }

    /// Download a byte range and stream it into the named region of the
    /// `videoId` entry. Used twice per preload — once for the prefix region
    /// (`0..<prefixSize`) and once for the main region
    /// (`mainStartByte..<totalSize`). Each call is independent: a failure or
    /// auth error in one region must not affect the other (the caller awaits
    /// both via `try?` so a thrown error here does not cancel the sibling
    /// task).
    ///
    /// On `Task.isCancelled` the loop exits cleanly without throwing
    /// `CancellationError` — the parent `preloadTask` propagates cancellation
    /// via structured concurrency. On 401/403 we post `.taAuthUnauthorized`
    /// (with `videoId` as `object`) and exit without throwing. On non-2xx
    /// statuses we log and exit. Throws only when `StreamingSession.stream`
    /// or the chunk iterator throws (i.e. transport errors), which lets the
    /// retry wrapper in `startPreloadWithRetry` decide whether to retry —
    /// but with the parallel structure, retry currently re-runs both tasks.
    ///
    // MARK: cancellation hardening — three sites, all load-bearing
    //
    // The three `if Task.isCancelled { return }` guards inside this method
    // (outer-loop entry, inner-loop pre-write, post-loop residual write)
    // are intentionally NOT consolidated into a helper. Each guards a
    // distinct write opportunity: a single delivery containing multiple
    // chunkSize-worth of bytes would otherwise write every full chunk into
    // the store before the outer iterator could observe cancellation; a
    // sub-chunkSize residual buffer post-loop is another write site. Stale
    // bytes from a cancelled task landing in a region that `reseedMain` just
    // reset would corrupt playback at the new anchor.
    private func downloadRange(
        videoId: String,
        url: URL,
        token: String,
        range: Range<Int64>,
        into region: CacheStore.RegionID,
        config: URLSessionConfiguration
    ) async throws {
        guard range.lowerBound < range.upperBound else { return }

        var request = URLRequest(url: url)
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        // Inclusive end byte for HTTP `Range:` header (RFC 7233).
        let endByte = range.upperBound - 1
        request.setValue("bytes=\(range.lowerBound)-\(endByte)", forHTTPHeaderField: "Range")

        let streamer = StreamingSession()
        let (httpResponse, chunks) = try await streamer.stream(request: request, configuration: config)

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            logger.error("Preload (\(region.name)) unauthorized for \(videoId): \(httpResponse.statusCode)")
            NotificationCenter.default.post(name: .taAuthUnauthorized, object: videoId)
            return
        }

        guard (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 206 else {
            logger.error("Preload (\(region.name)) failed for \(videoId): bad status \(httpResponse.statusCode)")
            return
        }

        var buffer = Data()
        buffer.reserveCapacity(CacheStore.chunkSize)

        do {
            for try await chunk in chunks {
                if Task.isCancelled { return }

                buffer.append(chunk)

                while buffer.count >= CacheStore.chunkSize {
                    // Inner-loop cancellation check: the outer
                    // `for try await chunk` only observes cancellation when a
                    // new chunk is delivered. A single delivery containing
                    // multiple `chunkSize` worth of bytes would otherwise
                    // write every full chunk into the store before the next
                    // outer iteration could bail. After cancellation we MUST
                    // stop writing — otherwise stale bytes from the cancelled
                    // task's byte range would land in a region that
                    // `reseedMain` just reset to a new anchor, producing
                    // off-by-many-bytes corruption at the reseed target.
                    if Task.isCancelled { return }
                    let cacheChunk = Data(buffer.prefix(CacheStore.chunkSize))
                    buffer = Data(buffer.dropFirst(CacheStore.chunkSize))
                    // writeChunk handles auto-trim of `.main` internally; for
                    // `.prefix` it appends without trimming (prefix is pinned).
                    _ = store.writeChunk(videoId: videoId, toRegion: region, chunk: cacheChunk)

                    // Per-region pause gate. Only the `.main` task observes
                    // the pause threshold — it's the only region that can
                    // actually exceed it (prefix is bounded by
                    // `maxPrefixSize = 50 MB` ≪ `pauseThreshold = 384 MB` by
                    // construction). If we instead summed both regions, a
                    // main task that filled past pauseThreshold while
                    // playback was still at byte 0 (user hasn't pressed play
                    // → `lastPlaybackOffset == 0` → `trimFront` returns 0)
                    // would deadlock the prefix task in this Task.sleep loop
                    // forever, since prefix has no `trimFront` lever to pull.
                    if region == .main {
                        while store.cachedByteCount(videoId: videoId) > CacheStore.pauseThreshold, !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(2))
                            store.trimFront(videoId: videoId)
                        }
                    }
                }
            }
        } catch is CancellationError {
            logger.info("Preload (\(region.name)) cancelled for \(videoId)")
            return
        }

        // Same cancellation invariant as the inner while loop — a residual
        // sub-chunkSize buffer from a cancelled task must not be written
        // into a region that may have been reset under us.
        if !buffer.isEmpty, !Task.isCancelled {
            _ = store.writeChunk(videoId: videoId, toRegion: region, chunk: buffer)
        }
    }

    /// Orchestrate the full preload for `videoId`: HEAD probe to discover
    /// `totalSize`, seed both regions via `store.setEntry`, then launch the
    /// prefix and main downloads as parallel `async let` tasks.
    ///
    /// Cancellation propagates through structured concurrency — when the
    /// enclosing `preloadTask` is cancelled, both inner `async let` tasks
    /// observe `Task.isCancelled` and exit. Per-task failures (e.g. main
    /// returns 503) do not affect the sibling task because the caller awaits
    /// each with `try?`.
    private func downloadVideo(videoId: String, url: URL, token: String, startPosition: Double, duration: Double, generation: Int) async {
        // NOTE: `preloadTask` lifecycle is owned by the retry-wrapper Task in
        // `startPreloadWithRetry`. It is NOT cleared here — a prior
        // `defer { preloadTask = nil }` at this point would nil the reference
        // to the enclosing retry-wrapper Task *between* retry attempts, making
        // subsequent `cancelPreload` / `isPreloading` checks see a stale nil
        // and allowing orphan retries to write into a different video's entry.

        let config = makeDownloadConfig()

        // Always probe to learn `totalSize`; we need it to compute the prefix
        // size and (when resuming) the main region's start byte. The probe is
        // unconditional now — previously it was gated on `startPosition > 0`,
        // but with parallel prefix+main downloads we always need the size to
        // pick the prefix/main boundary.
        guard let probe = await probeTotalSize(videoId: videoId, url: url, token: token, config: config) else {
            // Either an auth failure (notification already posted) or a HEAD
            // failure — either way, abort the preload cleanly.
            return
        }

        let totalSize = probe.totalSize
        let contentType = probe.contentType
        let prefixSize = CacheStore.computePrefixSize(totalSize: totalSize)

        let rawResumeByte: Int64
        if startPosition > 0, duration > 0 {
            let fraction = startPosition / duration
            rawResumeByte = Int64(Double(totalSize) * fraction)
        } else {
            rawResumeByte = 0
        }
        // Clamp into the file's byte range. Without this clamp, a corrupt
        // saved progress, a re-encoded video that shrunk under us, or simple
        // rounding past duration would push `resumeByte` past `totalSize` and
        // make the later `mainStartByte..<totalSize` range construction trap
        // (Swift Range requires `lowerBound <= upperBound`). `CacheStore.setEntry`
        // applies the same clamp internally; we apply it here so the range
        // expression below is provably safe.
        let resumeByte = min(max(rawResumeByte, 0), totalSize)
        let mainStartByte = max(prefixSize, resumeByte)

        store.setEntry(
            videoId: videoId,
            totalSize: totalSize,
            contentType: contentType,
            resumeByte: resumeByte
        )

        logger.info("Preload \(videoId): totalSize=\(totalSize / 1_000_000)MB, prefixSize=\(prefixSize / 1_000_000)MB, mainStart=\(mainStartByte / 1_000_000)MB (resume=\(resumeByte / 1_000_000)MB)")
        logger.info("[Mem] preload start videoId=\(videoId) rss=\(MemoryDiagnostics.residentMBString())")

        // Parallel prefix + main downloads. Each is independently retried at
        // the transport level by `StreamingSession`; per-task auth failure or
        // 5xx errors post the notification (auth) or log + exit (other) but
        // do not propagate to the sibling task.
        async let prefixResult: Void = downloadRange(
            videoId: videoId,
            url: url,
            token: token,
            range: 0..<prefixSize,
            into: .prefix,
            config: config
        )
        // Skip main when the file fits in the prefix (`totalSize <= prefixSize`)
        // OR when the resume position lands at/past EOF (`mainStartByte >=
        // totalSize`). Both produce degenerate empty ranges that we never
        // want to hand to `downloadRange`.
        let shouldDownloadMain = totalSize > prefixSize && mainStartByte < totalSize
        async let mainResult: Void? = shouldDownloadMain
            ? downloadRange(
                videoId: videoId,
                url: url,
                token: token,
                range: mainStartByte..<totalSize,
                into: .main,
                config: config
            )
            : nil

        // Independent failure: prefix or main can throw without affecting the
        // other. `try?` swallows per-task errors; we log them via the
        // downloadRange logger calls. `await` here keeps the structured-
        // concurrency cancellation propagation intact.
        do {
            try await prefixResult
        } catch is CancellationError {
            logger.info("Prefix preload cancelled for \(videoId)")
        } catch {
            logger.error("Prefix preload error for \(videoId): \(error.localizedDescription)")
        }
        do {
            _ = try await mainResult
        } catch is CancellationError {
            logger.info("Main preload cancelled for \(videoId)")
        } catch {
            logger.error("Main preload error for \(videoId): \(error.localizedDescription)")
        }

        // Generation guard: only clear when this `downloadVideo` invocation
        // is still the "current" preload for the store. If a newer
        // `startPreloadWithRetry` for the same `videoId` has already
        // cancelled us and seeded a fresh entry, `generation` will no longer
        // match `preloadGeneration` and clearing would wipe the new task's
        // seeded entry. The store's `currentVideoId()` check isn't enough on
        // its own — same videoId can be re-seeded under a fresh generation
        // before we get here.
        if generation == preloadGeneration,
           store.cachedByteCount(videoId: videoId) == 0,
           store.currentVideoId() == videoId {
            // Nothing landed in either region (e.g. both transports failed)
            // — clear the entry so the next retry attempt restarts fresh.
            store.clear()
        }

        let cached = store.cachedByteCount(videoId: videoId)
        logger.info("Preload complete for \(videoId): \(cached / 1_000_000)MB cached (prefix=\(prefixSize / 1_000_000)MB, mainStart=\(mainStartByte / 1_000_000)MB)")
        logger.info("[Mem] preload complete videoId=\(videoId) rss=\(MemoryDiagnostics.residentMBString()) cached=\(cached / 1_000_000)MB")

        // `preloadTask = nil` is handled by the retry-wrapper Task in
        // `startPreloadWithRetry` after the retry loop exits — see the note
        // at the top of this function.
    }

    /// Retry wrapper: retries transient network errors with exponential backoff.
    ///
    /// Skips the new preload if the cache already covers the requested start
    /// position for this `videoId` (migrated from the removed `startPreload`
    /// fast-path). Otherwise cancels any in-flight preload, clears the store,
    /// and kicks off a fresh download loop with retry on transient errors.
    func startPreloadWithRetry(videoId: String, url: URL, token: String, startPosition: Double = 0, duration: Double = 0, maxRetries: Int = 2) {
        if isCacheSufficient(videoId: videoId, startPosition: startPosition, duration: duration) {
            return
        }

        // Clear the stale-cancel record for this videoId — a fresh preload
        // supersedes any prior `cancelPreload(videoId:)` and we don't want
        // a queued `reseedMain` hop to short-circuit on a record from the
        // PREVIOUS playback session of the same video.
        if lastCancelledVideoId == videoId {
            lastCancelledVideoId = nil
        }

        // Cancel any in-flight preload; clear only if it belongs to a different video.
        preloadTask?.cancel()
        preloadTask = nil
        preloadTaskVideoId = nil
        if store.currentVideoId() != videoId {
            store.clear()
        }

        preloadGeneration &+= 1
        let generation = preloadGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            for attempt in 0...maxRetries {
                if Task.isCancelled { break }
                if attempt > 0 {
                    let delay = Double(1 << (attempt - 1)) // 1s, 2s
                    logger.info("Retry \(attempt)/\(maxRetries) for \(videoId) in \(Int(delay))s")
                    try? await Task.sleep(for: .seconds(delay))
                    if Task.isCancelled { break }
                }
                await self.downloadVideo(videoId: videoId, url: url, token: token, startPosition: startPosition, duration: duration, generation: generation)
                // If we got data or task was cancelled, don't retry
                let cached = self.store.cachedByteCount(videoId: videoId)
                if cached > 0 { break }
                if Task.isCancelled { break }
            }
            // Generation-guarded clear: only nil `preloadTask` if no newer
            // `startPreloadWithRetry` has bumped the generation. Otherwise
            // the live preload's reference would be dropped, breaking
            // `cancelPreload` / `isPreloading`.
            await self.finalizePreloadIfCurrent(generation: generation)
        }
        preloadTask = task
        preloadTaskVideoId = videoId
    }

    /// Compare-and-clear `preloadTask` against the generation recorded when
    /// the retry wrapper Task was spawned. Runs on the actor so the check
    /// and the subsequent assignment are serialized with
    /// `startPreloadWithRetry` and `cancelPreload`.
    private func finalizePreloadIfCurrent(generation: Int) {
        guard generation == preloadGeneration else { return }
        preloadTask = nil
        preloadTaskVideoId = nil
    }

    /// Returns `true` when the cache already covers what playback needs for
    /// `videoId` at `startPosition` (seconds): BOTH `.prefix` and `.main`
    /// regions populated, AND `.main` covers the byte offset for the
    /// requested start position. Used by `startPreloadWithRetry` to skip
    /// redundant preload on re-open.
    ///
    /// The fast-path must be region-aware: a prior `.critical` memory
    /// pressure event may have dropped the `.prefix` region, and re-using
    /// the cache without re-downloading prefix would silently re-introduce
    /// the scrub-after-resume freeze (no cached moov atom). Require BOTH
    /// `.prefix` populated AND `.main` covering the requested byte before
    /// we declare the cache "good enough" to skip.
    private func isCacheSufficient(videoId: String, startPosition: Double, duration: Double) -> Bool {
        guard duration > 0,
              let mainStatus = store.regionStatus(videoId: videoId, region: .main),
              mainStatus.endOffset > mainStatus.startOffset,
              let prefixStatus = store.regionStatus(videoId: videoId, region: .prefix),
              prefixStatus.endOffset > 0
        else {
            return false
        }
        let avgByterate = Double(mainStatus.totalSize) / duration
        let requestedByte = Int64(startPosition * avgByterate)
        guard requestedByte >= mainStatus.startOffset, requestedByte < mainStatus.endOffset else {
            return false
        }
        if isPreloading(videoId: videoId) {
            logger.info("Preload for \(videoId) already active, skipping")
            return true
        }
        let cachedBytes = Int(mainStatus.endOffset - mainStatus.startOffset)
        logger.info("Cache for \(videoId) already covers position \(Int(startPosition))s (\(cachedBytes / 1_000_000)MB main + \(prefixStatus.endOffset / 1_000_000)MB prefix), skipping preload")
        return true
    }
}
