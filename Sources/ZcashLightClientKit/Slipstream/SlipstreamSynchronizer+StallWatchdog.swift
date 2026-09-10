//
//  SlipstreamSynchronizer+StallWatchdog.swift
//  ZcashLightClientKit
//
//  Created for Slipstream task [#1755] — B4 failure-path hardening.
//
//  Detects the silent-freeze failure mode (field report 2026-06-12): the engine
//  state stuck at Syncing while NO progress counter moves — the Rust sync task
//  hung (transport stall) or died (panic; the Rust-side B1 supervisor now also
//  surfaces panics as Error state). The watchdog LOGS — one loud `Logger.error`
//  per stall episode, carrying the full last snapshot — and REPORTS the stall
//  fact to the poll loop, which restarts the pass under the bounded policy in
//  SlipstreamSynchronizer+PureHelpers.swift (`stallRecoveryDecision`, MOB-1850).
//
//  The pure decision predicate (`isSyncStalled`) lives in
//  SlipstreamSynchronizer+PureHelpers.swift and is unit-tested in OfflineTests.
//

import Foundation

extension SlipstreamSynchronizer {
    /// B4 (#1755): stall-watchdog tick. Tracks the engine's progress-counter
    /// signature across poll ticks; when the state claims Syncing but NO counter
    /// has moved for `stallWatchdogThresholdSeconds`, logs ONE loud error per
    /// stall episode (the episode flag re-arms as soon as any counter moves
    /// again).
    ///
    /// - Returns: whether the pass is stalled RIGHT NOW. [MOB-1850] The loud log is
    ///   once-per-episode, but recovery needs the fact on every tick — the poll loop feeds
    ///   this into `stallRecoveryDecision`, which owns what to do about it. The two are
    ///   deliberately separate: this method reports, the policy decides, and `tickPoll` acts.
    func checkStallWatchdog(_ snap: SlipstreamSnapshot) -> Bool {
        // [Engine API v2 §4.4 / Phase D] The stall FACT is engine-owned now: `snap.stalledSeconds`
        // is stamped by the engine's own counters (0 unless state == Syncing). The watchdog keeps
        // only the POLICY — the once-per-episode loud log — re-armed whenever progress resumes.
        //
        // CLAMPED to the current handle's lifetime: the engine-reported span can predate this
        // handle (a restart resurfaces stall time accumulated before — and across — a deliberate
        // stop, which fired the log at the precise moment recovery was succeeding; field-caught
        // 2026-08-02). Only stall time the CURRENT handle actually accrued may fire it.
        let elapsed = Self.effectiveStallSeconds(
            engineReported: TimeInterval(snap.stalledSeconds),
            secondsSinceHandleStart: Date().timeIntervalSince(watchdogHandleStartedAt)
        )
        if elapsed < Self.stallWatchdogThresholdSeconds {
            watchdogStallLogged = false
            return false
        }
        let stalled = Self.isSyncStalled(
            state: snap.state,
            secondsSinceLastCounterChange: elapsed,
            threshold: Self.stallWatchdogThresholdSeconds
        )
        guard stalled, !watchdogStallLogged else { return stalled }

        watchdogStallLogged = true
        watchdogLogger.error(
            """
            Slipstream stall watchdog: state==Syncing but NO progress counter changed for \(Int(elapsed))s. \
            Last snapshot: chainTip=\(snap.chainTip) fetched=\(snap.fetchedBlocks) scanned=\(snap.scannedBlocks) \
            enhanced=\(snap.enhancedTxs) rangesCompleted=\(snap.rangesCompleted) passTotal=\(snap.passTotalBlocks) \
            rangeEnd=\(snap.currentRangeEnd). The engine sync task appears hung (transport stall) or dead (panic). \
            The SDK restarts the pass up to \(Self.maxStallRestartsPerHandle) times for this handle, then gives up and reports it.
            """,
            file: #file,
            function: #function,
            line: #line
        )
        return true
    }

    /// [MOB-1850] Test-only seam: backdates the handle-lifetime baseline, so the next
    /// `checkStallWatchdog` evaluates the engine-reported stall span at face value instead of
    /// clamping it to a handle that was opened moments ago.
    ///
    /// It is only HALF of what a test needs, because the predicate takes the minimum of two spans
    /// (`effectiveStallSeconds`): the snapshot the engine serves must also carry a
    /// `stalledSeconds` at or above `stallWatchdogThresholdSeconds`. There is no seam for that half
    /// and there should not be — the stall FACT is engine-owned, so a test states it by scripting
    /// the snapshot (`SlipstreamSnapshot.testSyncing(stalledSeconds:)`), which is what a stalled
    /// engine really does. Only the clamp, which is Swift-side policy, needs a way in.
    ///
    /// The MOMENT it is called matters as much as the value: every tick from here on sees a stall,
    /// so a test that wants a particular tick to be the one that observes it must arrange for that
    /// tick to be the next one.
    func seedStallClockForTesting(secondsAgo: TimeInterval) {
        watchdogHandleStartedAt = Date().addingTimeInterval(-secondsAgo)
    }

    /// B4: re-arms the stall watchdog for a new run/handle (start, switchTo, wipe), including
    /// the [MOB-1850] recovery budget — the caller is opening a handle whose stall history is
    /// its own. (The stall clock itself is engine-owned and resets with the pass; only the
    /// once-per-episode log flag — and the handle-lifetime clamp's baseline — live in Swift.)
    func resetStallWatchdog() {
        resetStallWatchdog(resetRecoveryBudget: true)
    }

    /// [MOB-1850] The re-arm with the recovery budget under the caller's control.
    ///
    /// The recovery restart calls `start()`, and `start()` re-arms the watchdog — so without this
    /// distinction the restart would zero the very budget that is bounding it, and a permanently
    /// stalled server would be retried forever instead of three times. `resetRecoveryBudget:
    /// false` re-arms the LOG and the handle-lifetime baseline (the new pass genuinely starts its
    /// stall clock now) while leaving the attempt count, the backoff stamp and the give-up flag
    /// carried over from the handle being recovered.
    ///
    /// - Parameter resetRecoveryBudget: whether this re-arm also clears the per-handle restart
    ///   budget. True for a genuine new handle (`switchTo`, `wipe`, an app-driven `start()`),
    ///   false for the `start()` that a recovery restart performs itself.
    func resetStallWatchdog(resetRecoveryBudget: Bool) {
        watchdogStallLogged = false
        watchdogHandleStartedAt = Date()
        guard resetRecoveryBudget else { return }
        resetStallRecoveryBudget()
    }
}
