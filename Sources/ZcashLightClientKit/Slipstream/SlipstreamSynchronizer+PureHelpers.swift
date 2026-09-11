//
//  SlipstreamSynchronizer+PureHelpers.swift
//  ZcashLightClientKit
//
//  Created for Slipstream task [#1755].
//
//  Pure static helpers for `SlipstreamSynchronizer` — no instance state, no side effects.
//  Extracted so the decision logic stays unit-testable in OfflineTests without an engine.
//

import Foundation

extension SlipstreamSynchronizer {
    // [v2.1 E-5] `counterProgress` is GONE with `forceCounterProgressUntilDone`: the engine
    // re-baselines its session floor on scope expansion (import/rewind), so the blessed
    // `progressPermille` needs no host-side raw-counter bypass.

    // [v2.1 E-3] `composeProgress` / `summaryProgress` / `isRecovering(summary)` are GONE:
    // the snapshot is truthful from open() (the engine seeds `is_recovering`, the permille
    // floor, the persisted tip and spendability from the wallet DB), so no host re-derives
    // progress or the recovery flag from a summary — `progress_permille` is the one blessed
    // progress source (ENGINE_API_V2.md §0.3).

    /// [v2.1 E-3] The `SynchronizerState` that `prepare()` emits right after opening the
    /// engine — a TRIVIAL mapping of the truthful-from-open snapshot (progress, recovery,
    /// spendability, persisted tip) plus the unified summary's balances. A zero snapshot
    /// (fresh wallet: no tip, no floor) emits cold `.disconnected`, as before.
    /// - Parameter isSpendableMasked: whether the [#1591] mask was applied to `accountsBalances`.
    ///   Passed in rather than re-derived from `snapshot` so the mask predicate keeps a single
    ///   definition, in `walletBalanceSnapshots()`, which is what produced these balances. The
    ///   default exists only to keep this function's parameter count under SwiftLint's
    ///   `function_parameter_count` limit and fails SAFE: a call site that forgets the argument
    ///   gets a masked, never an over-trusted, state — every existing call site passes it
    ///   explicitly regardless.
    static func initialState(
        snapshot: SlipstreamSnapshot?,
        accountsBalances: [AccountUUID: AccountBalance],
        localAccountsBalances: [AccountUUID: AccountBalance],
        fullyScannedHeight: BlockHeight?,
        syncSessionID: UUID,
        isSpendableMasked: Bool = true
    ) -> SynchronizerState {
        guard let snap = snapshot, snap.chainTip != 0 || snap.progressPermille != 0 else {
            return SynchronizerState(
                syncSessionID: syncSessionID,
                accountsBalances: [:],
                localAccountsBalances: localAccountsBalances,
                internalSyncStatus: .disconnected,
                latestBlockHeight: .zero
                // Balances are dropped entirely here, so nothing is being hidden: `false`.
            )
        }
        return SynchronizerState(
            syncSessionID: syncSessionID,
            accountsBalances: accountsBalances,
            localAccountsBalances: localAccountsBalances,
            internalSyncStatus: .syncing(Float(snap.progressPermille) / 1000, snap.spendableHint != 0),
            latestBlockHeight: BlockHeight(snap.chainTip),
            fullyScannedHeight: fullyScannedHeight ?? .zero,
            isRecovering: snap.isRecovering == 1,
            isSpendableMasked: isSpendableMasked
        )
    }

    /// T8.3.6 (UX): return `raw` with each transaction's `state` populated from
    /// `currentHeight` (via `Overview.getState`). Pure — the height resolution stays in the
    /// synchronizer (it needs `latestState`/the backend). Without populating `state`, Zashi
    /// maps an INCOMING tx via `transaction.state == .pending` → `nil == .pending` → false →
    /// ".received", so a 0-conf mempool tx wrongly shows "received" instead of "receiving".
    static func transactionsWithState(
        _ raw: [ZcashTransaction.Overview],
        currentHeight: BlockHeight
    ) -> [ZcashTransaction.Overview] {
        raw.map { tx in
            var copy = tx
            copy.state = tx.getState(for: currentHeight)
            return copy
        }
    }

    // [v2.1 Phase 2] `shouldMarkChainTipUpdated` is GONE: tip freshness is the engine-owned
    // snapshot fact `tipFresh` (E-2), which the engine reports only once the refreshed tip's
    // ChainTip-priority range has also been scanned, or the pass reached Done.

    // ── B4 (#1755 failure-path hardening): stall watchdog ─────────────────────

    /// Pure staleness predicate: the engine claims to be Syncing (`state == 1`) but
    /// NO progress counter has changed for at least `threshold` seconds.
    ///
    /// Field failure 2 (2026-06-12): the UI froze at one chunk with the state stuck
    /// "Syncing" — no logs, no error, forever. This predicate makes such silent
    /// stalls VISIBLE (a loud `Logger.error` in `tickPoll`). It answers only WHETHER
    /// the pass is stalled; what to do about it is `stallRecoveryDecision`'s call.
    ///
    /// - Parameters:
    ///   - state: `snap.state` (0=idle, 1=syncing, 2=error, 3=done). Only Syncing
    ///     can stall silently; Done/Error/Idle are legitimate steady states.
    ///   - secondsSinceLastCounterChange: elapsed wall time since any engine counter
    ///     last moved (the engine-stamped `snap.stalledSeconds`, Phase D).
    ///   - threshold: the stall window (`stallWatchdogThresholdSeconds`, 120 s — far
    ///     above any legitimate counter gap: the slowest observed device chunk is
    ///     ~36 s on iPad A10, and treestate/scan boundaries bump counters within it).
    /// - Returns: true when the stall warning should fire.
    static func isSyncStalled(
        state: UInt8,
        secondsSinceLastCounterChange: TimeInterval,
        threshold: TimeInterval
    ) -> Bool {
        state == 1 && secondsSinceLastCounterChange >= threshold
    }

    /// What the poll loop should do about a stall it just observed.
    ///
    /// The watchdog used to only log — recovery was left entirely to the app, which meant a pass
    /// whose transport had died sat at "Syncing" until the user noticed and restarted the wallet
    /// themselves. The SDK now reconnects on its own, and this is the policy that keeps that
    /// reconnect from becoming a worse failure than the stall.
    enum StallRecoveryDecision: Equatable {
        /// Nothing to do: the pass is healthy, or a restart already fired and its backoff
        /// window has not elapsed yet.
        case none
        /// Restart the pass now. `attempt` is 1-based and counts restarts of the CURRENT handle.
        case restart(attempt: Int)
        /// The restart budget for this handle is spent. Stop trying and report it once.
        case giveUp
    }

    /// The pure stall-recovery policy: given the stall fact and the restart history of the current
    /// handle, decide whether to restart the pass, wait, or give up.
    ///
    /// Two properties matter and both live here rather than in the poll loop, so they are testable
    /// without an engine handle:
    ///
    /// - A **cap** (`maxAttempts`). A stall the SDK cannot fix — a server that is down, a device
    ///   that lost its network — would otherwise be met with an unbounded restart loop that costs
    ///   battery and hides the problem from the user. Past the cap the SDK stops and says so, so
    ///   the host can offer a server switch instead.
    /// - An **exponential backoff** between attempts. The poll loop asks every 2 s and the stall
    ///   fact stays true across ticks, so without a wait the whole budget would burn in a few
    ///   seconds while the underlying cause had no chance to clear. The window after attempt *n*
    ///   is `backoffBase * 2^(n-1)`. The function doubles for as long as the caller's cap allows;
    ///   the shipped configuration (base 60 s, cap 3) reaches only the first two windows, 60 s and
    ///   120 s, because three restarts have two waits between them and the cap is checked before
    ///   any window is computed.
    ///
    /// - Parameters:
    ///   - isStalled: what `checkStallWatchdog` just decided for this tick.
    ///   - attemptsSoFar: restarts already performed for the current handle (0 on a fresh handle).
    ///   - maxAttempts: the per-handle cap (`maxStallRestartsPerHandle`).
    ///   - secondsSinceLastRestart: wall time since the last recovery restart, or nil when this
    ///     handle has not been restarted yet — in which case the restart is due immediately.
    ///   - backoffBase: the first window's length (`stallRestartBackoffBase`).
    /// - Returns: the action the poll loop should take on this tick.
    static func stallRecoveryDecision(
        isStalled: Bool,
        attemptsSoFar: Int,
        maxAttempts: Int,
        secondsSinceLastRestart: TimeInterval?,
        backoffBase: TimeInterval
    ) -> StallRecoveryDecision {
        guard isStalled else { return .none }
        guard attemptsSoFar < maxAttempts else { return .giveUp }
        guard let secondsSinceLastRestart else { return .restart(attempt: attemptsSoFar + 1) }
        let window = backoffBase * pow(2, Double(attemptsSoFar - 1))
        guard secondsSinceLastRestart >= window else { return .none }
        return .restart(attempt: attemptsSoFar + 1)
    }

    /// The handle-lifetime clamp on the engine-reported stall span, feeding `isSyncStalled`'s
    /// `secondsSinceLastCounterChange` input.
    ///
    /// Field failure 2026-08-02: the engine-owned stall clock (`snap.stalledSeconds`) survived a
    /// stop→start, so the restarted handle's first snapshots carried a span accumulated before —
    /// and across — a deliberate stop (497 s, of which ~4.5 min the engine was stopped behind the
    /// migration gate), and the watchdog fired its loud log at the exact moment recovery was
    /// working. Only stall time the CURRENT handle could actually have accrued may count.
    ///
    /// - Parameters:
    ///   - engineReported: `snap.stalledSeconds` as stamped by the engine.
    ///   - secondsSinceHandleStart: wall time since `resetStallWatchdog()` last re-armed (start /
    ///     switchTo / wipe). Clamped below at zero so a clock adjustment can never yield a
    ///     negative span.
    /// - Returns: the span `checkStallWatchdog` should evaluate against the threshold.
    static func effectiveStallSeconds(
        engineReported: TimeInterval,
        secondsSinceHandleStart: TimeInterval
    ) -> TimeInterval {
        min(engineReported, max(0, secondsSinceHandleStart))
    }
}

// MARK: - LifecycleQueue (MOB-1850)

/// One FIFO for every pass-owning lifecycle operation of `SlipstreamSynchronizer`: an app-driven
/// start, a stop teardown, a server switch, an account import or delete, a rewind, a wipe, and the
/// stall recovery's restart. Operations run strictly one after another, so a teardown can never
/// interleave with a start, and an account mutation's stopped interval — the window that exists
/// precisely so no pass scans across the mutation — can never be entered by another operation.
///
/// Generalises the `PendingStopSlot` it replaces. That slot solved one instance of this problem (a
/// `stop()` landing after the `start()` that followed it) by chaining stop teardowns and having
/// `start()` await the chain; here the chained task simply IS the queue tail, and every lifecycle
/// operation joins it rather than only the stops. `start()` therefore no longer awaits anything
/// explicitly: ordering is structural.
///
/// Two properties are load-bearing:
///
/// - **The tail is a separate task.** `enqueue` returns the caller's task so the caller can await
///   its own result, while `tail` is a wrapper that swallows that result (and, in the throwing
///   case, the error). Making the tail the caller's own task would either force every waiter to
///   share a return type or let one operation's failure cancel the queue for the next.
/// - **Unstructured tasks, so cancellation does not inherit.** The recovery is requested from
///   inside `pollTask`, whose first act is to be cancelled by the very restart it asked for; a
///   child task would die with it. For the same reason `stop()` — called from a nonisolated,
///   possibly cancelled context — still runs its teardown to completion.
///
/// `NSLock` (not `OSAllocatedUnfairLock`) keeps the SDK's iOS 13 / macOS 12 deployment floor, as
/// `PendingStopSlot` did.
final class LifecycleQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    /// Appends a non-throwing operation. The returned task completes with the operation's value,
    /// once every operation enqueued before it has finished.
    @discardableResult
    func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> Task<T, Never> {
        lock.lock()
        defer { lock.unlock() }
        let previous = tail
        let task = Task<T, Never> {
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await task.value }
        return task
    }

    /// Appends a throwing operation. A failure is the caller's to handle: the queue itself only
    /// waits for the operation to end, so the next one runs whether this one threw or not.
    @discardableResult
    func enqueueThrowing<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) -> Task<T, Error> {
        lock.lock()
        defer { lock.unlock() }
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return task
    }
}

// MARK: - CancellationFlag (MOB-1850, MOB-1860)

/// A `Bool` set once from a `withTaskCancellationHandler`'s `onCancel`, and read later by whichever
/// unstructured or detached work would otherwise miss the calling task's cancellation: an operation
/// already sitting on `LifecycleQueue` (`SlipstreamSynchronizer.restartSync(at:)`) or a detached
/// proving closure that runs off the caller's executor. Neither is a child task, so cancellation
/// does not propagate to either on its own — this flag carries it across the boundary by hand,
/// checked as the first thing the queued or detached body does.
///
/// `NSLock`, not `OSAllocatedUnfairLock`, for the package's iOS 13 / macOS 12 floor, the same reason
/// `Gate` and `LifecycleQueue` use one.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false

    func markCancelled() {
        lock.lock()
        flagged = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flagged
    }
}

// MARK: - withTaskTimeout helper (F1)

/// Races `operation` against a nanosecond timer.  Returns the operation's value if it
/// completes first; throws `SummaryTimeoutError` when the timer wins.
///
/// Uses `Task.sleep(nanoseconds:)` for iOS 13+/macOS 12+ compatibility (the newer
/// `Task.sleep(for: Duration)` requires iOS 16+/macOS 13+).
///
/// Both the operation task and the timer task are cancelled when the other wins
/// (structured cancellation via `withThrowingTaskGroup`).  Structured concurrency
/// means this returns only once both child tasks have acknowledged cancellation.
///
/// `internal` (not `private`) so `@testable` test targets can exercise the timeout
/// behaviour directly without requiring a full `SlipstreamSynchronizer` instance.
/// (Moved here from SlipstreamSynchronizer.swift for file_length — B4 hardening.)
struct SummaryTimeoutError: Error {}

func withTaskTimeout<T: Sendable>(
    _ nanoseconds: UInt64,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: nanoseconds)
            throw SummaryTimeoutError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw SummaryTimeoutError()
        }
        return result
    }
}
