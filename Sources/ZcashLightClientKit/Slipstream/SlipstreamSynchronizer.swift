//
//  SlipstreamSynchronizer.swift
//  ZcashLightClientKit
//
//  Created for Slipstream task [#1755].
//
//  Implements the `Synchronizer` protocol using:
//    - Sync members  → `SlipstreamEngine` (open / start / stop / snapshot / drainEvents)
//    - Data members  → `TransactionRepository` + `ZcashRustBackendWelding`
//                      resolved from the SAME `DIContainer` as `SDKSynchronizer`
//    - State stream  → `CurrentValueSubject<SynchronizerState, Never>` updated by a 2-second
//                      polling `Task` that calls `engine.snapshot()` and `engine.drainEvents()`
//    - Event stream  → `PassthroughSubject<SynchronizerEvent, Never>` emits `foundTransactions`
//                      from the polling tick when the engine reports SyncDone with txs
//
//  Delegation notes (T4.3 / T4.6):
//    Sync-side:      prepare / start / stop / stateStream / eventStream / rescanFrom /
//                    rewind / wipe / switchTo / latestHeight (9 members on engine + light service)
//    Delegated:      ~40 data-model members delegated to transactionRepository / rustBackend /
//                    transactionEncoder / broadcaster / checkpointSource / torClient
//    Honest-unsupported (throw or log): switchTo only (T4.6 ships real wipe)
//

import Combine
import Foundation

// swiftlint:disable type_body_length

/// `Synchronizer` implementation that uses the Slipstream Rust engine for sync
/// while delegating all data-model operations to the existing SDK components.
/// This allows the two synchronizer implementations to share the same `data.db`.
///
/// [Phase E / audit SDK-2] An ACTOR: every mutable var (poll mirrors, the recovery gate, …)
/// is actor-isolated, retiring the class-era races between the poll task,
/// the summary-fetch tasks and the public API. The protocol's synchronous members are
/// `nonisolated` and touch only immutable lets (the thread-safe Combine subjects, the DI
/// handles) — except `stop()`, which registers its teardown in a lock-guarded slot so an
/// immediately-following `start()` can still await it (the SDK-1 ordering contract).
public actor SlipstreamSynchronizer: Synchronizer {
    // ── Alias ──────────────────────────────────────────────────────────────────
    public nonisolated var alias: ZcashSynchronizerAlias { initializer.alias }

    // ── Sync engine ────────────────────────────────────────────────────────────
    // [MOB-1850] The protocol, not the concrete actor: tests substitute a gated fake so the
    // lifecycle interleavings this file guards against can be reproduced without an FFI handle.
    private let engine: any SlipstreamEngineControlling

    // ── Shared infrastructure ──────────────────────────────────────────────────
    // `private` reaches the same-file private extension (Swift 4+ file-scope rule).
    private let initializer: Initializer
    private let transactionRepository: TransactionRepository
    private let transactionEncoder: TransactionEncoder
    private let broadcasterStorage: Broadcaster
    /// [#1976] Resolved once in `init` from the container (same singleton `broadcasterStorage`'s
    /// `SDKBroadcaster` uses) so `wipe()` can delete the plan database directly — mirrors
    /// `SDKSynchronizer`'s `submitPlanStore` property exactly.
    private let submitPlanStore: SubmitPlanStoring
    /// [#1975] The resubmission core shared with the old pipeline's `TxResubmissionAction`
    /// (same type, same retry policy, same 300 s throttle) — see the driver block below.
    private let txResubmitter: TxResubmitter

    /// The one migration host this synchronizer owns (see `OrchardMigrationHost`'s type doc: each
    /// synchronizer holds exactly one). Registered on `initializer.container` and resolved
    /// immediately in `init`, mirroring `SDKSynchronizer`'s exact idiom -- see that type's
    /// `migrationHost` property doc for the full registration-timing rationale. Two live
    /// synchronizers over one `Initializer` stay unsupported (round note N3): each synchronizer
    /// type registers its own host on its own initializer's container.
    private let migrationHost: OrchardMigrationHost

    // ── State subjects (mirrors SDKSynchronizer) ───────────────────────────────
    private let stateSubject = CurrentValueSubject<SynchronizerState, Never>(.zero)
    private let eventSubject = PassthroughSubject<SynchronizerEvent, Never>()
    private let exchangeRateSubject = CurrentValueSubject<FiatCurrencyResult?, Never>(nil)

    // ── Public read-only state (nonisolated: subjects are thread-safe lets) ────
    public nonisolated var latestState: SynchronizerState { stateSubject.value }
    // TODO: [#1755] never updated (engine has no connection-state callback yet; P5).
    public nonisolated var connectionState: ConnectionState { .idle }
    public nonisolated var stateStream: AnyPublisher<SynchronizerState, Never> { stateSubject.eraseToAnyPublisher() }
    public nonisolated var eventStream: AnyPublisher<SynchronizerEvent, Never> { eventSubject.eraseToAnyPublisher() }
    public nonisolated var exchangeRateUSDStream: AnyPublisher<FiatCurrencyResult?, Never> { exchangeRateSubject.eraseToAnyPublisher() }

    // ── Broadcaster (Synchronizer protocol requirement) ────────────────────────
    public nonisolated var broadcaster: Broadcaster { broadcasterStorage }

    // ── Endpoint (mutable for switchTo) ───────────────────────────────────────
    // Tracks the endpoint currently in use.  `engine.reopen(server:network:)` uses
    // this value; `initializer.endpoint` is the initial value.
    private var currentEndpoint: LightWalletEndpoint

    // ── Running state (for switchTo restart decision) ──────────────────────────
    private var isRunning: Bool = false

    // ── Polling task ───────────────────────────────────────────────────────────
    private var pollTask: Task<Void, Never>?
    /// [MOB-1850] Which poll LOOP a tick belongs to. `startPolling()` replaces the loop rather than
    /// adding one, and a replaced loop's last tick can still be suspended inside an engine call when
    /// its successor's first tick begins. Cancellation alone does not separate them — `Task.isCancelled`
    /// is observed only where the code looks, and a tick suspended in the engine resumes regardless —
    /// so each loop carries a number its ticks re-check. Together with `passGeneration` this is a
    /// tick's whole identity: which pass it was decided for, and which loop scheduled it.
    private var pollGeneration = 0

    // ── foundTransactions emission tracking (v2.1 E-4) ─────────────────────────
    // Last-seen `snap.txSetVersion` — the engine's monotonic tx-set version (per-handle,
    // survives start/stop cycles; reset only where the handle dies: wipe()/switchTo()).
    private var lastTxSetVersion: UInt64 = 0
    // The host reconcile FILTER's last-published scope (recovering on/off): the filter is
    // host policy (API v2 §0, applied in `droppingUnreconciled`), so its edge — which
    // changes the VISIBLE list with no engine write — is host-observed. Together with the
    // version compare this is the WHOLE emission rule.
    private var lastRevealRecovering = false

    // [v2.1 Phase 2] The F2 boundary-refresh mirror and the [#1591] chain-tip-flag parity
    // machinery are GONE: the engine refreshes the unified summary at its own boundaries
    // (E-1) and owns tip freshness as `snapshot.tipFresh` (E-2).

    // ── B4 (#1755): stall watchdog ─────────────────────────────────────────────
    // Detects the silent-freeze failure mode (field, 2026-06-12): state stuck at
    // Syncing while NO engine counter moves — the sync task hung (transport stall)
    // or died (panic — now also surfaced by the Rust-side B1 supervisor). The
    // watchdog LOGS (Logger.error, once per stall episode) and reports the stall to
    // the poll loop, which restarts the pass under the bounded policy below
    // ([MOB-1850]). The stall FACT is engine-owned (`snap.stalledSeconds`, Phase D) —
    // Swift keeps the once-per-episode log policy and the recovery policy. Methods live in
    // SlipstreamSynchronizer+StallWatchdog.swift; the pure predicate is
    // `isSyncStalled` (+PureHelpers.swift). State is `internal` (not private) so
    // the extension file can reach it.
    var watchdogStallLogged = false
    /// When the CURRENT engine handle came up (stamped by `resetStallWatchdog()` at start /
    /// switchTo / wipe). The engine-owned stall span (`snap.stalledSeconds`) can survive a
    /// stop→start — a restarted handle's first snapshots surfaced a span accumulated before
    /// (and across) a deliberate stop, which fired the watchdog at the exact moment recovery
    /// was WORKING (field-caught 2026-08-02: a 497 s "stall" of which ~4.5 min was a
    /// gate-stopped engine). `checkStallWatchdog` clamps the reported span to this handle's
    /// own lifetime, so only stall time the CURRENT handle actually accrued can fire the log.
    var watchdogHandleStartedAt = Date()
    /// Logger accessor for same-type extensions in other files (`initializer` is
    /// private; the StallWatchdog extension needs the injected logger).
    var watchdogLogger: Logger { initializer.logger }
    /// Stall window before the watchdog fires: 120 s with zero counter movement
    /// while Syncing. The slowest legitimate counter gap observed in the field is
    /// ~36 s (iPad A10 worst chunk), so 120 s is comfortably out of reach for a
    /// healthy sync. `internal` so tests can reference the constant.
    static let stallWatchdogThresholdSeconds: TimeInterval = 120

    // ── [MOB-1850] Stall recovery: restart the pass, don't only log it ─────────
    // The watchdog above proved the failure mode is real and self-inflicted damage is not: a
    // stalled pass is a dead transport, and re-opening the engine handle against the same
    // endpoint fixes it. So the SDK now restarts the pass itself rather than leaving every host
    // to reimplement the same recovery. The restart is bounded on both axes — a cap per handle
    // and a doubling wait between attempts (the pure policy is `stallRecoveryDecision`) — because
    // the poll loop re-decides every 2 s and the stall fact stays true across ticks.
    //
    // A `.syncStalled` event accompanies every decision so the host can see what the SDK is
    // doing: attempt 1 is the SDK reconnecting uncontested, later attempts say the reconnect is
    // not sticking, and the give-up event says the SDK has stopped trying.

    /// How many times a stalled pass may be restarted before the SDK gives up for this handle.
    /// The budget is per HANDLE, so a `switchTo`, a `wipe` or an app-driven `start()` hands the
    /// new handle a fresh one — a different server deserves its own three chances.
    /// `internal` so tests can reference the constant, like `stallWatchdogThresholdSeconds`.
    static let maxStallRestartsPerHandle = 3
    /// The first backoff window after a recovery restart; it doubles per attempt. Three restarts
    /// have exactly two waits between them, so with the shipped cap the SDK waits at least 60 and
    /// then at least 120 seconds — the doubling never reaches a third window.
    ///
    /// "At least", because with the shipped constants the window is a floor rather than the
    /// binding constraint: a restart re-stamps `watchdogHandleStartedAt`, so the new pass cannot
    /// even be OBSERVED to stall until `stallWatchdogThresholdSeconds` (120 s) of its life have
    /// elapsed — at least as long as either reachable window. The cadence a field log shows is
    /// therefore ~120 s throughout, not 60 s and then 120 s. The floor is kept because it is the
    /// only bound that does not depend on the watchdog's threshold: it is what keeps a stall the
    /// SDK cannot fix from being met with one restart per 2 s poll tick, whatever that threshold
    /// becomes.
    static let stallRestartBackoffBase: TimeInterval = 60

    /// Recovery restarts already performed for the current handle. Reset with the watchdog
    /// whenever the handle changes (`switchTo`, `wipe`, an app-driven `start()`), NOT by the
    /// `start()` the recovery itself performs — see `resetStallWatchdog(resetRecoveryBudget:)`.
    private var stallRestartAttempts = 0
    /// When the last recovery restart fired, or nil while this handle has never been restarted
    /// (which is what makes the first restart immediate). Feeds the backoff window.
    private var lastStallRestartAt: Date?
    /// Whether the give-up event has been sent for this handle. Deliberately INDEPENDENT of
    /// `watchdogStallLogged`, which re-arms the moment any counter moves: a pass that flickers
    /// back to life for one tick and stalls again must not re-announce the give-up on every
    /// subsequent tick, because the budget it exhausted is still exhausted.
    private var stallGaveUpReported = false
    /// Whether a recovery restart has been requested and not yet finished. Guards against a second
    /// restart being asked for by the next poll tick, and — through `passIntendedRunning` — tells an
    /// account mutation that a pass is wanted even while the wallet momentarily has none.
    /// [MOB-1850] Set at REQUEST time by `requestStallRecovery`, cleared by the queued operation's
    /// `defer`, so it covers the whole span including the wait for the queue.
    private var stallRecoveryInFlight = false
    /// [MOB-1850] Which PASS the engine is currently living for. Every lifecycle operation bumps it
    /// as its first act on the queue — an app-driven start, a stop teardown, a switch, an account
    /// import or delete, a rewind, a wipe, and the recovery restart — so the number changes exactly
    /// when the answer to "whose engine is this?" changes.
    ///
    /// It replaces the old `stopGeneration`, which counted only teardowns and which the recovery
    /// re-read after each of its own suspension points. That was a check on the wrong thing at the
    /// wrong time: a poll tick captured the counter AFTER a stop had already bumped it, so the tick
    /// it produced looked current to every guard downstream and restarted a synchronizer the app had
    /// deliberately stopped. Now a tick captures this number when it BEGINS and re-validates it
    /// after every suspension, and the recovery validates it once, before it touches anything.
    ///
    /// Only equality is ever asked of it, so the fact that a single queued operation may bump it
    /// twice (once on entry, once again through the `startImpl` it performs) costs nothing.
    private var passGeneration = 0
    /// Bumped by the two operations that stop a pass and bring none of their own back up: the
    /// deliberate `stop()` a host asks for, and `wipe()`.
    ///
    /// `passGeneration` cannot tell those apart from a takeover: a switch, an account import or
    /// delete and a rewind bump it too, and every one of them restarts a pass afterwards. So a
    /// recovery asks THIS counter whether the pass it was decided for is meant to stay down — a
    /// moved stop request means the app really does want a stopped (or wiped) synchronizer, while a
    /// mere takeover means the taking-over path owns the pass and a recovery restart would either
    /// duplicate it or fight it.
    private var stopRequestGeneration = 0
    /// `stopRequestGeneration` as it stood when the in-flight recovery was decided; meaningful
    /// only while `stallRecoveryInFlight`, and read only by `passIntendedRunning`. Captured at the
    /// decision rather than inside the restart, so a stop landing between the two is visible: an
    /// account mutation that takes the queue in that window must not conclude that a pass is wanted
    /// when a deliberate stop has already retired the recovery that wanted it.
    private var stallRecoveryStopRequestGeneration = 0

    /// Whether a sync pass is MEANT to be up, which is not the same question as `isRunning`.
    ///
    /// A stall recovery clears `isRunning` for the length of its teardown and reopen, and every
    /// "stop, mutate the wallet, restart it if it was running" path samples that flag to decide
    /// whether to restart. Sampling it during that window reads a mid-restart wallet as an idle
    /// one, and the outcome is a wallet with no pass at all: the path mutates, reopens and skips
    /// its restart, while the recovery — whose generation that same path has just retired —
    /// abandons on the grounds that someone else is bringing a pass up. Reading the INTENT closes
    /// that hole: a recovery in flight means a pass is wanted, whatever `isRunning` says today.
    ///
    /// [MOB-1850] The lifecycle queue closes the same hole from the other side: a mutation queued
    /// behind a recovery no longer samples anything mid-restart, because the recovery has finished
    /// by the time the mutation runs. The intent term still matters for the other order — a
    /// mutation that took the queue while a recovery was merely REQUESTED reads `stallRecoveryInFlight`,
    /// which the poll tick sets at request time, and correctly concludes that a pass is wanted.
    ///
    /// Unless a deliberate stop has retired that recovery in the meantime. It is then on its way
    /// to abandoning and the pass is meant to stay down, so restarting it would undo the stop.
    private var passIntendedRunning: Bool {
        isRunning || (stallRecoveryInFlight && stallRecoveryStopRequestGeneration == stopRequestGeneration)
    }

    // ── [#1975] Background transaction resubmission ────────────────────────────
    // Parity with the old pipeline's `TxResubmissionAction`, which ran once per sync pass:
    // unmined, unexpired transactions are re-broadcast through their recorded submit plans,
    // and plans whose transactions expired are pruned. `SlipstreamSynchronizer` has no action
    // list, so the poll loop drives it — `tickPoll` asks `maybeRunTxResubmission` on every
    // 2 s tick and the guards below decide.
    //
    // Two cadences, deliberately: the CHECK runs at most every
    // `resubmissionCheckInterval` (60 s — it walks the transaction table and the plan store),
    // while the actual re-broadcast is throttled to 300 s INSIDE `TxResubmitter`
    // (`Constants.thresholdToTrigger`, shared with the old pipeline). The prune runs on every
    // check. This host duplicates neither number.
    //
    // Teardown (`stopImpl`, `wipeImpl`) only CANCELS `resubmissionTask`; it never nils the
    // handle. The fired task clears it itself, as its last step, through the actor-isolated
    // `finishResubmissionCheck()` — a single writer. If teardown also nil'd the handle, a fast
    // stop→start could let a stale task's finish clear a NEWER task's handle and re-open the
    // spawn guard while that new task still runs (double-spawn). Cancel-only teardown keeps
    // the guard closed until the cancelled task's own finish clears it, which is benign and
    // self-healing. Note the LIMIT of that cancellation: only the SUBMIT stage observes it
    // (`SubmitPlanExecutor.submit` checks `Task.checkCancellation`, and `TxResubmitter` catches
    // per transaction). The prune stage has no cancellation checks at all and runs to
    // completion — which is why `wipeImpl` cancels AND joins (below), rather than trusting
    // cancellation to stop a check that would otherwise write to files it is deleting.
    //
    // The driver is also gated on the CALLER's cancellation (`isCancelled`, defaulted to
    // `Task.isCancelled` so it is evaluated in the caller's task context). `stopPolling()`
    // cancels `pollTask` without awaiting it, and teardown then suspends (`engine.stop()`,
    // `engine.close()`), so a `tickPoll` that was suspended mid-tick can RESUME inside the
    // teardown and walk on to this driver. Without that gate a wipe could spawn a fresh,
    // uncancelled check that reads `data.db` and re-creates the submit-plan database SQLite
    // just deleted (a connect resurrects the file), undoing [#1976] a few milliseconds later.
    /// Wall-clock stamp (`timeIntervalSince1970`) of the last check the driver FIRED; 0 = never.
    private var lastResubmissionCheckTime: TimeInterval = 0
    /// The in-flight check, if any. Doubles as the "one at a time" guard: a slow submit round
    /// must never be joined by a second concurrent pass over the same transactions.
    private var resubmissionTask: Task<Void, Never>?
    /// How often the poll loop may run a resubmission check: 60 s (the poll tick is 2 s).
    /// `internal` so tests can reference the constant, like `stallWatchdogThresholdSeconds`.
    static let resubmissionCheckInterval: TimeInterval = 60

    // [v2.1 E-3] The host-side summary cache is GONE: the engine caches the summary itself
    // (E-1) and the warm-start emissions it fed read the truthful-from-open snapshot instead.
    // [audit SDK-1 + SDK-2 → MOB-1850 R1/R2] Every pass-owning lifecycle operation runs here, one
    // at a time and in the order it was asked for. It generalises the `PendingStopSlot` it replaces:
    // that slot ordered stops against the next `start()`, which was the one instance of the problem
    // that had been found; this queue orders ALL of them, so a teardown can never interleave with a
    // start and an account mutation's stopped interval can never be entered by another operation.
    // A plain `let` of a Sendable lock-guarded object — reachable from the nonisolated `stop()`,
    // `rewind()` and `wipe()` as well as from the actor.
    private let lifecycle = LifecycleQueue()
    /// [#1755] Mirrors the wallet's deep-recovery state. Seeded from the persisted summary at
    /// prepare()/start(); ENGINE-OWNED during a run (tickPoll adopts `snap.isRecovering`, which embeds
    /// the terminal fail-safe latch — Done/Error force it 0). Drives the "Restoring"
    /// LABEL and the Activity gate: the Activity is gated PER-TRANSACTION by the `ext_slipstream_v_tx_reconciled`
    /// view (not held wholesale), so reconciled txs surface immediately while only the provisional ones
    /// wait. (Balance is NOT special-cased — live is correct on a fresh restore; see tickPoll.) Tracks the
    /// LIVE signal, so it self-corrects across rewind / truncate / stop.
    private var currentlyRecovering = false {
        didSet {
            // [#1755] Log only true⇄false transitions (every write site funnels through here). One line
            // per restore proves the engine's recovery→catch-up flip and the "Restoring"→"Syncing" label.
            guard currentlyRecovering != oldValue else { return }
            initializer.logger.info(
                currentlyRecovering
                    ? "[slipstream] recovery ACTIVE — restore backfill in progress (isRecovering=true)"
                    : "[slipstream] recovery COMPLETE — switching to catch-up sync (isRecovering=false)",
                file: #file,
                function: #function,
                line: #line
            )
        }
    }

    /// True while the [#1591] stale-tip mask is zeroing spendable — surfaced to clients as
    /// `SynchronizerState.isSpendableMasked`, which is the only signal that separates "cannot
    /// spend" from "not willing to say yet". Written wherever the unified summary is taken, read
    /// when emitting state; mirrors `currentlyRecovering` above, including its transition logging.
    private var currentlySpendableMasked = false {
        didSet {
            // Both edges are logged, so the mask window can be measured straight off the log —
            // and a stall shows up as an APPLIED with no LIFTED after it. Transition-only: the
            // mask is re-evaluated per poll tick, so logging every evaluation would bury it.
            guard currentlySpendableMasked != oldValue else { return }
            initializer.logger.info(
                currentlySpendableMasked
                    ? "[#1591] stale-tip mask APPLIED — spendable hidden until the tip refreshes"
                    : "[#1591] stale-tip mask LIFTED — spendable is authoritative again",
                file: #file,
                function: #function,
                line: #line
            )
        }
    }

    // [v2.1 E-5] `forceCounterProgressUntilDone` is GONE: the ENGINE re-baselines its
    // session progress floor when the scan scope expands (an import with an older birthday,
    // a rewind), so the blessed `progressPermille` reads the re-scan as a genuine climb by
    // itself — no host-side floor bypass.

    // ── Init ───────────────────────────────────────────────────────────────────

    /// Creates a `SlipstreamSynchronizer` instance.
    /// - Parameters:
    ///   - initializer: the same `Initializer` used for `SDKSynchronizer`; the
    ///     `SlipstreamSynchronizer` writes to the same `data.db` and uses the same
    ///     `ZcashRustBackend` for all data-model queries.
    ///   - alternateEndpoints: [v0.7 P1b] the host's full known-server list (the
    ///     selected `initializer.endpoint` may be in it — the engine dedupes).
    ///     Non-empty ⇒ every sync pass opens with a ~1 s parallel health probe
    ///     (commit to the healthiest server for the pass) and arms mid-pass
    ///     wire-collapse failover. Empty (the default) ⇒ single-server behavior,
    ///     exactly as before. Ignored on Tor passes (probe/failover dial direct,
    ///     which would bypass the circuit).
    public init(initializer: Initializer, alternateEndpoints: [LightWalletEndpoint] = []) {
        self.init(
            initializer: initializer,
            alternateEndpoints: alternateEndpoints,
            engine: SlipstreamEngine(
                dbURL: initializer.dataDbURL,
                server: initializer.endpoint,
                alternates: alternateEndpoints
            )
        )
    }

    /// [MOB-1850] The injecting initializer, for tests only.
    ///
    /// Identical to the public one in every respect but the engine: the public initializer builds a
    /// real `SlipstreamEngine` and calls straight through to here, so there is one construction path
    /// and a test's synchronizer is wired exactly like a shipped one. `alternateEndpoints` still
    /// arrives so the parameter list stays honest about what the engine was given, even though the
    /// engine itself is now the caller's.
    ///
    /// `internal` (not `private`) so `@testable` tests can hand in a gated fake and drive the
    /// lifecycle deterministically — see `SlipstreamEngineControlling` for why that seam exists.
    init(
        initializer: Initializer,
        alternateEndpoints: [LightWalletEndpoint],
        engine: any SlipstreamEngineControlling
    ) {
        self.engine = engine
        self.initializer = initializer
        self.currentEndpoint = initializer.endpoint
        self.transactionRepository = initializer.transactionRepository
        self.transactionEncoder = WalletTransactionEncoder(initializer: initializer)
        let eventSubjectRef = eventSubject

        let logger = initializer.logger

        // `[weak initializer]` breaks the initializer -> container -> closure -> initializer cycle
        // (`initializer` owns `container`, and `container` would otherwise hold this closure -- and
        // therefore `initializer` -- for its own lifetime). The `nil` branch is unreachable: this
        // closure only ever runs synchronously from `resolve`, on the next line, while `initializer`
        // is still alive; by the time anything could resolve this singleton again, `resolve` has
        // already cached the instance and will not invoke the factory a second time. Mirrors
        // `SDKSynchronizer.init`'s registration exactly (a strong capture here is a known,
        // review-flagged retain cycle -- B-1 in the round's review).
        initializer.container.register(type: OrchardMigrationHost.self, isSingleton: true) { [weak initializer] _ in
            guard let initializer else {
                preconditionFailure("OrchardMigrationHost resolved after its Initializer was released")
            }
            return OrchardMigrationHost(initializer: initializer)
        }
        self.migrationHost = initializer.container.resolve(OrchardMigrationHost.self)

        let transactionEncoderRef = WalletTransactionEncoder(initializer: initializer)
        // [#1976] Resolved once here (it's a singleton) and stored on `self` so `wipeImpl(_:)`
        // can wipe it directly; the same instance is handed to `SDKBroadcaster` below.
        self.submitPlanStore = initializer.container.resolve(SubmitPlanStoring.self)
        // [#1975] Same container, same singletons the old pipeline's `TxResubmissionAction`
        // resolves — so both synchronizers resubmit through one implementation.
        self.txResubmitter = TxResubmitter(container: initializer.container)
        // [#1755] zcash #1757 (multiserver submission) reworked SDKBroadcaster's init: it now
        // takes submitPlanStore + multiEndpointSubmitter (resolved from the container, same as
        // SDKSynchronizer) and no longer takes sdkFlags. Mirror SDKSynchronizer exactly.
        self.broadcasterStorage = SDKBroadcaster(
            transactionEncoder: transactionEncoderRef,
            initializer: initializer,
            logger: logger,
            eventSubject: eventSubjectRef,
            submitPlanStore: submitPlanStore,
            multiEndpointSubmitter: initializer.container.resolve(MultiEndpointSubmitter.self),
            statusCheck: {}
        )
    }

    // ── prepare ────────────────────────────────────────────────────────────────

    /// Initialises the wallet database (same as `SDKSynchronizer.prepare`) and opens the
    /// engine handle.  Handles `SeedRequired` migrations identically to `SDKSynchronizer`.
    public func prepare(
        with seed: [UInt8]?,
        walletBirthday: BlockHeight?,
        name: String,
        keySource: String?
    ) async throws -> Initializer.InitializationResult {
        // [v2.1 E-6] Route init-time provisioning (restore recover_until / new-wallet tree
        // state) through the engine's `restore_anchor` primitive — the offline fallback
        // policy and Tor privacy live ENGINE-side, one implementation for every host. The
        // legacy `SDKSynchronizer` path never sets this and keeps its frozen inline fetch.
        let anchorServer = currentEndpoint
        let anchorNetwork = initializer.network
        let anchorTorDir = await slipstreamTorDirPath()
        initializer.slipstreamAnchorSource = { isRestore, birthday, fallbackCheckpoint in
            await SlipstreamEngine.restoreAnchor(
                isRestore: isRestore,
                birthday: birthday,
                fallbackCheckpointHeight: fallbackCheckpoint,
                server: anchorServer,
                network: anchorNetwork,
                torDirPath: anchorTorDir
            )
        }
        if case .seedRequired = try await initializer.initialize(
            with: seed,
            walletBirthday: walletBirthday,
            name: name,
            keySource: keySource
        ) {
            return .seedRequired
        }
        try await engine.open(network: initializer.network)
        // [v2.1 E-3] The snapshot is truthful FROM OPEN: the engine seeds `isRecovering`,
        // the permille floor, the persisted chain tip and spendability from the wallet DB
        // (the same inputs the first suggest round would use), so the cold-launch emission
        // is a trivial snapshot→state mapping — the summary-derived warm-start math this
        // block used to carry (summaryProgress/isRecovering(summary)) is deleted. Balances
        // still come from the unified summary (recovery-safe at every phase, D-1/E-1).
        let snap = await engine.snapshot()
        currentlyRecovering = snap?.isRecovering == 1
        let summaries = await walletBalanceSnapshots()
        let summary = summaries.visible
        stateSubject.send(SlipstreamSynchronizer.initialState(
            snapshot: snap,
            accountsBalances: summary?.accountBalances ?? [:],
            localAccountsBalances: summaries.local ?? [:],
            fullyScannedHeight: summary?.fullyScannedHeight,
            syncSessionID: UUID(),
            isSpendableMasked: currentlySpendableMasked
        ))
        return .success
    }

    // ── start ──────────────────────────────────────────────────────────────────

    /// Starts a Slipstream sync pass.
    /// The account is already imported in `data.db` from `prepare`, so UFVK is passed as `nil`
    /// (keyless update — engine calls `ensure_account` only when `ufvk=Some`).
    public func start(retry: Bool = false) async throws {
        // [MOB-1850] On the lifecycle queue, like every other pass-owning operation. A start that
        // follows a stop therefore runs after that stop's teardown has finished — the [audit SDK-1]
        // ordering contract `pendingStop` used to hold up by hand — and, more importantly, a start
        // cannot land in the middle of a switch, a wipe or an account mutation's stopped interval.
        try await lifecycle.enqueueThrowing {
            try await self.startImpl(retry: retry, resetRecoveryBudget: true)
        }.value
    }

    /// The queued body of `start(retry:)`, and the restart every other lifecycle operation performs
    /// for itself.
    ///
    /// Never call this from outside a queued operation, and never call the public `start(retry:)`
    /// from inside one: the queued call would wait for a queue its own operation is holding.
    ///
    /// - Parameters:
    ///   - retry: unused by this engine; kept for `Synchronizer` parity.
    ///   - resetRecoveryBudget: whether this start also clears the per-handle stall-recovery budget.
    ///     True when the app is starting a run of its own or a takeover is bringing up a new handle;
    ///     false for the `startImpl` a recovery restart performs, because that budget is what bounds
    ///     the restart calling it, and clearing it would make the cap unreachable.
    private func startImpl(retry: Bool, resetRecoveryBudget: Bool) async throws {
        // T8.3 (T5.5 wart fix): a start() before prepare() must throw
        // .synchronizerNotPrepared — parity with SDKSynchronizer.start
        // (SDKSynchronizer.swift:189-192). Without this guard, start() reached
        // engine.start() on a nil handle and surfaced the internal
        // .rustSlipstreamNotOpen the user saw at launch. This makes that internal
        // error unreachable via the public Synchronizer API (it is kept only for
        // direct SlipstreamEngine misuse, covered by its own test).
        guard latestState.internalSyncStatus.isPrepared else {
            throw ZcashError.synchronizerNotPrepared
        }
        // Migration privacy gate — parity with SDKSynchronizer.start's `.stopped, .synced,
        // .disconnected, .error` branch: a sync session must not start while a migration
        // submission is still in flight. Only blocks a NEW start(); an already-running
        // engine is unaffected (this synchronizer has no separate "already syncing" branch to skip
        // into, unlike SDKSynchronizer's status switch), and stop() is untouched.
        if await migrationHost.isSyncBlocked() {
            throw ZcashError.migrationSyncBlocked
        }
        // [MOB-1850] Past the two refusals, so this start really is taking the pass over: every tick
        // decided for the previous one is retired here, before the first engine call. A start that
        // refused to run takes nothing over and retires nothing — it would otherwise cost the
        // running pass one silent poll tick every time a host started an already-started
        // synchronizer, or started one behind the migration gate.
        passGeneration += 1
        let birthday = BlockHeight(initializer.walletBirthday)
        // [v2.1 Phase 2] Tip freshness ([#1591]) is ENGINE-OWNED (snapshot.tipFresh, E-2):
        // the FFI start() captures the refresh baseline and keeps freshness across a <120 s
        // stop→start hop — the SDKFlags.sdkStarted()/chainTipAtRunStart parity machinery
        // this block used to carry is deleted.
        // B4: a new run starts with a fresh stall-watchdog window. [MOB-1850] The recovery
        // BUDGET only resets when the app is starting a run of its own: the stall recovery
        // restarts the pass by calling this very method, and letting that call clear the
        // attempt count would make the cap unreachable and the restart loop unbounded. The caller
        // says which it is — a flag beats the old `!stallRecoveryInFlight` inference, which could
        // not tell a recovery's own restart from an app start that merely happened to overlap one.
        resetStallWatchdog(resetRecoveryBudget: resetRecoveryBudget)
        // TODO: [#1755] Consider passing ufvk=Some after T4.4 integration tests confirm
        //   idempotency. Current strategy: ufvk=nil (keyless) since prepare() already
        //   imported the account and stored its birthday treestate.
        let slipstreamTorDir = await slipstreamTorDirPath()
        try await engine.start(ufvk: nil, birthday: birthday, torDir: slipstreamTorDir)
        isRunning = true
        startPolling()
        // [v2.1 E-3] Warm start emission straight off the truthful snapshot: the engine
        // seeded the permille floor / recovery flag / persisted tip at open(), so a
        // cold-launch catch-up reads its real near-100% position (never 0%) with no
        // summary math. Balances, and the mask flag describing them, carry over from
        // prepare()'s emission — read from `latestState` rather than `currentlySpendableMasked`,
        // which the reentrant actor may have already moved past this snapshot's balances (e.g. a
        // concurrent `getAccountsBalances()` call between the `await` above and here).
        let snap = await engine.snapshot()
        currentlyRecovering = snap?.isRecovering == 1
        stateSubject.send(SynchronizerState(
            syncSessionID: UUID(),
            accountsBalances: latestState.accountsBalances,
            localAccountsBalances: latestState.localAccountsBalances,
            internalSyncStatus: .syncing(
                Float(snap?.progressPermille ?? 0) / 1000,
                (snap?.spendableHint ?? 0) != 0
            ),
            latestBlockHeight: (snap?.chainTip).flatMap { $0 != 0 ? BlockHeight($0) : nil }
                ?? latestState.latestBlockHeight,
            isRecovering: currentlyRecovering,
            isSpendableMasked: latestState.isSpendableMasked
        ))
    }

    // ── stop ───────────────────────────────────────────────────────────────────

    /// Stops the in-flight sync.
    ///
    /// The protocol member is synchronous, so on the actor it is `nonisolated`: it appends the
    /// isolated teardown to the lifecycle queue SYNCHRONOUSLY and returns. The observable state
    /// change (`.stopped` emission) lands moments later, once whatever is ahead of it on the queue
    /// has finished.
    ///
    /// [MOB-1850] "Once whatever is ahead has finished" is the whole semantics, and it is
    /// deliberate. A stop asked for while a stall recovery is bringing a pass up does not race that
    /// recovery and does not abandon it — it waits, and then stops the pass the recovery started.
    /// A deliberate stop stays authoritative; it simply becomes the last word rather than a
    /// competing one. This also keeps `stopRequestGeneration`'s bump where the stop actually
    /// happens, so a recovery still in the queue behind it sees the request and abandons instead.
    public nonisolated func stop() {
        lifecycle.enqueue { await self.stopImpl() }
    }

    /// The queued body of `stop()`.
    private func stopImpl() async {
        // [MOB-1850] This teardown owns the engine now: retire every tick decided for the pass it
        // is taking down, before anything else happens.
        passGeneration += 1
        isRunning = false
        // [MOB-1850] The bump of the stop-REQUEST generation. `passGeneration` above says the
        // engine changed hands, which a switch, an import, a delete and a rewind all do too — and
        // every one of them brings a pass of its own back up. This counter separately records that
        // a stop was ASKED FOR, which is what a recovery queued behind this teardown needs in order
        // to tell "the app stopped me" from "another path took the engine over".
        stopRequestGeneration += 1
        stopPolling()
        // [#1975] Cancel, don't join: nothing is being deleted here, so a check that runs a
        //   moment longer is harmless, and `stop()` must stay prompt. Cancel ONLY — the fired
        //   task clears the handle itself (see the driver block).
        resubmissionTask?.cancel()
        // T8.3 (T5.5 wart fix): only emit .stopped if we were prepared. stop() on an
        // unprepared synchronizer (Zodl calls it unconditionally on didEnterBackground,
        // RootInitialization.swift:75-76) must NOT forge isPrepared by moving
        // .unprepared → .stopped — that springs the start-before-prepare wart on the
        // next foreground start(). The sdkStopped()/engine.stop() side effects below
        // stay unconditional (engine.stop() on a nil handle is a no-op). Mirrors
        // SDKSynchronizer.stop ordering (SDKSynchronizer.swift:243-249).
        if latestState.internalSyncStatus.isPrepared {
            stateSubject.send(SynchronizerState(
                syncSessionID: latestState.syncSessionID,
                accountsBalances: latestState.accountsBalances,
                localAccountsBalances: latestState.localAccountsBalances,
                internalSyncStatus: .stopped,
                latestBlockHeight: latestState.latestBlockHeight,
                // Balances carry over verbatim here, so their masked-ness must carry with them
                // rather than silently reading as authoritative.
                isSpendableMasked: latestState.isSpendableMasked
            ))
        }
        // [v2.1 Phase 2] Re-masking after a stop is ENGINE-OWNED: the FFI stop() stamps the
        // moment, and a start() more than 120 s later re-masks via snapshot.tipFresh (E-2).
        await engine.stop()
    }

    /// Test-only seam: overrides `latestState`'s `internalSyncStatus` directly, without touching the
    /// engine, the poll loop, or the lifecycle queue. `internal` (not `private`) so `@testable` tests can
    /// drive the actor into a specific status (e.g. `.disconnected` to satisfy `start(retry:)`'s
    /// `isPrepared` guard, or `.syncing` to exercise `throwIfSyncingForMigrationBroadcast()`)
    /// deterministically and instantly. `SDKSynchronizer` has an analogous production-code seam
    /// (`updateStatus(_:updateExternalStatus:)`) that its own tests reuse; `SlipstreamSynchronizer` has
    /// no equivalent single choke point (state is written from several call sites directly), and the
    /// only other way to reach a non-`.unprepared` status is the real `prepare()`/`start()` pair --
    /// which opens a real engine handle and spawns the real poll loop, unsuitable for fast, isolated
    /// migration-group tests (see `SlipstreamSynchronizerMigrationTests`: driving `.syncing` through a
    /// real `start()` left a background poll task whose `tickPoll()` → `engine.walletSummary()` call
    /// can run long against an unreachable server -- documented as unsafe "mid-scan" on `walletSummary()`
    /// itself -- and that in turn blocked `engine.stop()` behind it, since both share the
    /// `SlipstreamEngine` actor; the resulting slow teardown bled into unrelated later tests).
    func setInternalSyncStatusForTesting(_ status: InternalSyncStatus) {
        stateSubject.send(SynchronizerState(
            syncSessionID: latestState.syncSessionID,
            accountsBalances: latestState.accountsBalances,
            localAccountsBalances: latestState.localAccountsBalances,
            internalSyncStatus: status,
            latestBlockHeight: latestState.latestBlockHeight,
            // Status-only transition: the balances are the previous ones, so their masked-ness is too.
            isSpendableMasked: latestState.isSpendableMasked
        ))
    }

    // ── Polling (D8) ──────────────────────────────────────────────────────────

    /// [T-Tor.3 / E-6] The engine's dedicated Tor state directory when Tor is enabled, else
    /// nil (direct). A subdir of the SDK's torDirURL, SEPARATE from the old SDK's TorClient
    /// dir (arti holds a state lock). Used by both `start()` (sync metadata circuits) and
    /// the provisioning-anchor calls (identifying fetches ride Tor with the same state).
    /// The engine syncs at full speed regardless — bulk block fetch stays direct.
    private func slipstreamTorDirPath() async -> String? {
        let sdkFlags = initializer.container.resolve(SDKFlags.self)
        guard await sdkFlags.torEnabled else { return nil }
        let dir = initializer.torDirURL.appendingPathComponent("slipstream", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private func startPolling() {
        // REPLACES the loop, never adds one: a stall recovery's restart and a concurrent takeover's
        // both reach this, and two live loops would tick the same engine twice, decide two stall
        // recoveries and emit every state and event in duplicate.
        pollTask?.cancel()
        // [MOB-1850] The replacement gets its own number, and every tick it spawns carries it. The
        // cancel above does not retire the outgoing loop's last tick: a tick suspended inside an
        // engine call resumes whether its task is cancelled or not, and would otherwise go on to
        // emit state for a pass this loop's successor now owns.
        pollGeneration += 1
        let generation = pollGeneration
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // End the loop when the synchronizer is gone — without this the orphaned
                // task would keep sleeping/looping forever after dealloc.
                guard let self else { return }
                await self.tickPoll(pollGeneration: generation)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        // [v2.1 Phase 2] No host-side summary tasks to cancel — the engine owns the
        // refresh lifecycle (E-1); its background thread is handle-scoped and Arc-safe.
    }

    /// One poll tick, executed on behalf of exactly one pass and one poll loop.
    ///
    /// [MOB-1850] A tick suspends inside every engine call it makes, and the actor is reentrant, so
    /// a lifecycle operation can run to completion between two lines of this method. When it does,
    /// everything the tick has decided — the stall verdict, the state to publish, whether to
    /// re-fetch transactions — describes a pass that no longer exists. Acting on it is how a
    /// deliberately stopped synchronizer came back to life, and how a wiped wallet was told it was
    /// syncing.
    ///
    /// So the tick carries an identity and re-checks it after EVERY suspension: the pass it was
    /// scheduled for (`passGeneration`), the loop that scheduled it (`pollGeneration`), its own
    /// task's cancellation, and the fact that a pass is running at all. A tick that fails the check
    /// returns having done nothing — no watchdog update, no emission, no recovery request, no
    /// resubmission, no `foundTransactions`. Its successor, two seconds later, will see the world
    /// as it now is.
    ///
    /// - Parameter pollGeneration: the loop this tick belongs to, stamped by `startPolling()`.
    private func tickPoll(pollGeneration: Int) async {
        let owner = passGeneration

        /// Whether this tick still speaks for a live pass. Cheap, actor-isolated, and correct only
        /// immediately after it is called — which is why it is called after every `await`.
        func isCurrent() -> Bool {
            !Task.isCancelled && passGeneration == owner && self.pollGeneration == pollGeneration && isRunning
        }

        guard isCurrent(), let snap = await engine.snapshot() else { return }
        guard isCurrent() else { return }
        // [E-4] Ring hygiene only: the tx signal is the snapshot-carried `txSetVersion`
        // (loss-proof — a cumulative counter can't be evicted the way ring events can);
        // the ring stays drained so overflow warnings never fire for an idle consumer.
        // [MOB-1850] The capacity is spelled out because the seam is a protocol now, and a protocol
        // requirement cannot carry a default. 64 is the value the concrete engine defaults to
        // (Rust's EVENT_RING_CAP), so the drain is unchanged.
        _ = await engine.drainEvents(capacity: 64)
        guard isCurrent() else { return }

        // B4: surface silent stalls (state==Syncing, zero counter movement) loudly.
        // [MOB-1850] And act on them: the watchdog reports the fact, the pure policy decides
        // whether this tick restarts the pass, waits out a backoff window, or has run out of
        // budget, and the branches below carry that decision out.
        let stalled = checkStallWatchdog(snap)
        let decision = Self.stallRecoveryDecision(
            isStalled: stalled,
            attemptsSoFar: stallRestartAttempts,
            maxAttempts: Self.maxStallRestartsPerHandle,
            secondsSinceLastRestart: lastStallRestartAt.map { Date().timeIntervalSince($0) },
            backoffBase: Self.stallRestartBackoffBase
        )
        switch decision {
        case .restart(let attempt):
            // One restart at a time: the poll loop re-decides every 2 s and `stopPolling()` inside
            // the restart only takes effect once this tick yields, so without the gate a second
            // tick could spawn a second teardown against the same handle.
            if !stallRecoveryInFlight {
                // [MOB-1850] The tick DECIDES; it no longer acts, and it no longer announces. The
                // request carries this tick's identity so the queued restart can check, at the
                // moment it actually runs, that the pass it was decided for is still the one the
                // engine is living for — and the `.syncStalled` announcement moves there with it,
                // because a restart that turns out to be stale must not have promised anything.
                requestStallRecovery(
                    observedPassGeneration: owner,
                    observedStopRequestGeneration: stopRequestGeneration,
                    attempt: attempt
                )
            }
        case .giveUp:
            // Once per handle. `watchdogStallLogged` cannot stand in for this: it re-arms the
            // moment any counter moves, so a pass that twitches and stalls again would re-announce
            // a give-up whose budget is still, and permanently, spent.
            if !stallGaveUpReported {
                stallGaveUpReported = true
                eventSubject.send(.syncStalled(attempt: stallRestartAttempts, gaveUp: true))
            }
        case .none:
            break
        }

        // [v2.1 Phase 2] ONE summary source, refreshed every tick: the engine rations the
        // walk internally (E-1), so this is a cached serve on non-boundary ticks and carries
        // phase-correct balances at every state — recovery-safe Σ-view values while
        // recovering (re-read per call ⇒ the mid-restore climb stays per-tick), upstream
        // passthrough otherwise, [#1591]-masked while snapshot.tipFresh == 0 (E-2).
        // [E-3] A plain local: the host-side summary CACHE is gone with the warm-start
        // machinery it fed (the engine serves its own cache; a nil here only means
        // "engine mid-close", and every consumer falls back to `latestState`).
        let summaries = await walletBalanceSnapshots()
        // [MOB-1850] The last suspension before this tick publishes anything. Everything from here
        // to the end of the method is one uninterrupted actor turn plus the `foundTransactions`
        // fetch, so this is the check that keeps a stale tick from emitting state for a pass that
        // is gone, driving the resubmission check into a wipe's deleted files, or announcing
        // transactions for a wallet that no longer has them.
        guard isCurrent() else { return }
        let summary = summaries.visible

        // ── State-dispatch: Syncing vs Done vs other ──────────────────────────
        // Progress + spendability come from the snapshot (blessed `progressPermille` +
        // `spendableHint`); balances/fullyScannedHeight from the unified summary above.
        // The T5.5 no-walk-while-scanning protection lives in the ENGINE'S summary
        // rationing (E-1) — the walk never competes with rayon trial-decryption on
        // low-core devices regardless of how often the host asks.

        // [#1755] Deep-recovery gate. While the restore backfill is incomplete, Activity rows are
        // provisional (device data: phantom at every recov<100%, gone at 100%), so the reconcile
        // filter holds unlinked txs until their delta is final — forced, not a flag clients must
        // honor. A live signal ⇒ robust across rewind/truncate/stop.
        //
        // [Engine API v2 / Phase D] The recovery gate is ENGINE-OWNED: `snap.isRecovering` carries
        // the scheduler-computed flag WITH the fail-safe latch built in (terminal Done/Error force
        // 0 — the engine-side successor of the Swift resolveRecoveryGate/releasedByError machinery,
        // deleted in Phase E).
        // [E-3] Adopted UNCONDITIONALLY: the snapshot is truthful from open() (the engine seeds
        // the flag from the persisted `recover_until_height` + scan queue), so the first-seconds
        // adopt-guard that closed the pre-first-suggest lying window is retired.
        currentlyRecovering = snap.isRecovering == 1
        let recovering = currentlyRecovering

        // [v2.1 Phase 2] Balances come straight from the per-tick unified summary above —
        // the separate recovery Σ-computation (Direction B host-side) is DELETED; the engine
        // resolves the phase inside the FFI (same view, same mapping, one definition).

        if snap.state == 3 {
            // Done: emit .synced immediately.
            stateSubject.send(SynchronizerState(
                syncSessionID: latestState.syncSessionID,
                accountsBalances: summary?.accountBalances ?? latestState.accountsBalances,
                localAccountsBalances: summaries.local ?? latestState.localAccountsBalances,
                internalSyncStatus: .synced,
                latestBlockHeight: BlockHeight(snap.chainTip),
                fullyScannedHeight: summary?.fullyScannedHeight ?? latestState.fullyScannedHeight,
                isRecovering: recovering,
                isSpendableMasked: currentlySpendableMasked
            ))
            // Fall through to foundTransactions emission below (still needed on Done).
        } else if snap.state == 1 {
            // Syncing. [Engine API v2 / Phase E + v2.1 E-3/E-5] `progressPermille` is the ONE
            // blessed progress source: the pass-counter ratio, Done→100%, the session-monotonic
            // floor (seeded truthful-from-open, E-3), AND the scope-expansion re-baseline (E-5 —
            // an import/rewind re-scan reads as a genuine climb with no host-side floor bypass).
            let surfacedProgress = Float(snap.progressPermille) / 1000
            let spendable = snap.spendableHint != 0

            stateSubject.send(SynchronizerState(
                syncSessionID: latestState.syncSessionID,
                accountsBalances: summary?.accountBalances ?? latestState.accountsBalances,
                localAccountsBalances: summaries.local ?? latestState.localAccountsBalances,
                internalSyncStatus: .syncing(surfacedProgress, spendable),
                latestBlockHeight: BlockHeight(snap.chainTip),
                fullyScannedHeight: summary?.fullyScannedHeight ?? latestState.fullyScannedHeight,
                isRecovering: recovering,
                isSpendableMasked: currentlySpendableMasked
            ))
            // [v2.1 Phase 2] The F2 boundary refresh lives in the ENGINE now: the unified
            // summary refreshes itself (in a background thread) when ranges_completed moves,
            // and the per-tick call above serves it — no host-side boundary tracking.
        } else {
            // Disconnected (0) or Error (2): the per-tick unified summary keeps balances
            // fresh (engine-side 2 s idle TTL — the old host cadence, now engine-owned).
            let fullyScannedHeight = summary?.fullyScannedHeight ?? latestState.fullyScannedHeight
            let balances = summary?.accountBalances ?? latestState.accountsBalances

            let newStatus: InternalSyncStatus = {
                switch snap.state {
                case 2: return .error(ZcashError.rustSlipstreamSyncFailed(snap.chainTip))
                default: return .disconnected
                }
            }()

            stateSubject.send(SynchronizerState(
                syncSessionID: latestState.syncSessionID,
                accountsBalances: balances,
                localAccountsBalances: summaries.local ?? latestState.localAccountsBalances,
                internalSyncStatus: newStatus,
                latestBlockHeight: BlockHeight(snap.chainTip),
                fullyScannedHeight: fullyScannedHeight,
                isRecovering: recovering,
                isSpendableMasked: currentlySpendableMasked
            ))
        }

        // ── [#1975] Background resubmission ───────────────────────────────────
        // Non-blocking: the guards are evaluated inline and the work (if any) runs in its own
        // task, so a slow submit round can never stretch a poll tick.
        maybeRunTxResubmission(state: snap.state, chainTip: snap.chainTip)

        // ── foundTransactions: the E-4 one-line rule ──────────────────────────
        // The ENGINE versions the stored tx set (`snap.txSetVersion`: enhancement writes,
        // mempool hits, boundary reconcile-linkage transitions, post-submit pokes — a
        // cumulative counter carried in every snapshot, so nothing can be "lost" the way
        // ring events could). The HOST owns exactly one extra edge: its own reconcile
        // FILTER flipping scope (recovering on/off — visibility policy per API v2 §0,
        // applied in `droppingUnreconciled`), which changes the VISIBLE list with no
        // engine write. Version moved or filter flipped → re-fetch + publish. Replaces
        // the counter-watch + SyncDone-fallback + count-dedup strategy (R6).
        if snap.txSetVersion != lastTxSetVersion || recovering != lastRevealRecovering {
            lastTxSetVersion = snap.txSetVersion
            lastRevealRecovering = recovering
            let txs = await droppingUnreconciled(await enhanceWithState((try? await transactionRepository.find(offset: 0, limit: 50, kind: .all)) ?? []))
            eventSubject.send(.foundTransactions(txs, nil))
        }
    }

    /// [MOB-1850] Clears the per-handle stall-recovery budget. Called from
    /// `resetStallWatchdog(resetRecoveryBudget:)` in the watchdog extension, which cannot reach
    /// these `private` counters itself.
    func resetStallRecoveryBudget() {
        stallRestartAttempts = 0
        lastStallRestartAt = nil
        stallGaveUpReported = false
    }

    /// [MOB-1850] Asks for a stall recovery on behalf of the tick that decided one is due.
    ///
    /// Synchronous and side-effect-free beyond the two flags: it appends the restart to the
    /// lifecycle queue and returns, so the tick that called it goes on to finish its own work
    /// rather than performing a teardown inside the poll task the teardown is about to cancel.
    ///
    /// The two flags are set HERE, at request time, not when the restart runs:
    ///
    /// - `stallRecoveryInFlight` closes the "one restart at a time" gate immediately, so the next
    ///   tick — two seconds later, and quite possibly before the restart has reached the front of
    ///   the queue — does not ask for a second one.
    /// - `stallRecoveryStopRequestGeneration` records the stop-request generation as it stood when
    ///   the decision was taken, which is what `passIntendedRunning` compares: an account mutation
    ///   that takes the queue ahead of this restart must read "a pass is wanted" rather than the
    ///   `isRunning == false` a mid-teardown wallet would show.
    ///
    /// `internal` so tests can request a recovery at a chosen moment without having to arrange a
    /// stalled snapshot and wait out a poll tick.
    func requestStallRecovery(observedPassGeneration: Int, observedStopRequestGeneration: Int, attempt: Int) {
        stallRecoveryInFlight = true
        stallRecoveryStopRequestGeneration = observedStopRequestGeneration
        lifecycle.enqueue {
            await self.runStallRecovery(
                expectedPassGeneration: observedPassGeneration,
                expectedStopRequestGeneration: observedStopRequestGeneration,
                attempt: attempt
            )
        }
    }

    /// [MOB-1850] Restarts a stalled sync pass: tear the pass down, reopen the engine handle
    /// against the SAME endpoint, and start again.
    ///
    /// The endpoint is deliberately unchanged. A stall is a dead transport — the connection the
    /// engine holds stopped delivering while the engine still believes it is syncing — and a fresh
    /// handle against the same server fixes it. Choosing a different server is a separate decision
    /// with its own policy (`switchTo`, driven by the host's benchmark), and making it here would
    /// silently move a user off their configured server on a transient network glitch.
    ///
    /// This is the body of a QUEUED operation, and both halves of that matter:
    ///
    /// - It runs alone. No switch, wipe, account mutation, rewind, start or stop can interleave
    ///   with it, so the mid-flight generation re-checks the old restart carried around its
    ///   teardown and its reopen are gone: there is nothing left for them to catch.
    /// - It validates ONCE, before any side effect. Between the tick's decision and this turn, a
    ///   lifecycle operation may have run: a switch replaced the handle, a wipe deleted the
    ///   database, the app stopped the synchronizer. The old code tore the engine down FIRST and
    ///   compared generations after, which is precisely how a stale recovery stopped a pass a
    ///   switch had just brought up. The `.syncStalled` announcement moved here for the same
    ///   reason — a restart nobody performs must not be reported as one that is under way.
    ///
    /// - Parameters:
    ///   - expectedPassGeneration: `passGeneration` as the deciding tick saw it.
    ///   - expectedStopRequestGeneration: `stopRequestGeneration` as the deciding tick saw it. A
    ///     `stop()` or `wipe()` that has since been asked for moves this counter, and neither
    ///     brings a pass of its own back up, so this recovery must not either.
    ///   - attempt: the 1-based attempt number the policy decided on, carried into the event.
    ///
    /// `internal` (not `private`) so `@testable` tests can drive the restart directly, the way
    /// `maybeRunTxResubmission` and `setInternalSyncStatusForTesting` are reachable: the only
    /// production caller is `requestStallRecovery`, and a tick needs an engine snapshot, which needs
    /// a live FFI handle and therefore a real sync pass. Without the seam the whole failure half of
    /// this method — the half that decides whether a host is told anything at all — is untestable.
    func runStallRecovery(expectedPassGeneration: Int, expectedStopRequestGeneration: Int, attempt: Int) async {
        // Whatever happens below — abandon, failed reopen, failed start — the gate must reopen, or
        // no later stall of this handle could ever be recovered.
        defer { stallRecoveryInFlight = false }

        // Validate BEFORE any side effect. `isPrepared` is the third question and not a redundant
        // one: a wipe both bumps the stop-request generation and unprepares the synchronizer, but a
        // recovery reaching an unprepared wallet by any other route must also stop here, because
        // everything below it — the reopen, the restart, the error reporting — assumes a wallet
        // that exists.
        guard passGeneration == expectedPassGeneration,
              stopRequestGeneration == expectedStopRequestGeneration,
              latestState.internalSyncStatus.isPrepared else {
            initializer.logger.info(
                "[slipstream] stall recovery abandoned before it began: the pass it was decided for is no longer current",
                file: #file,
                function: #function,
                line: #line
            )
            return
        }

        // From here the recovery owns the pass, so it retires the ticks of the one it is replacing.
        passGeneration += 1
        stallRecoveryStopRequestGeneration = stopRequestGeneration
        // Announced only now, after validation: `attempt: 1` reads as "the SDK is reconnecting",
        // and it is only ever said when the SDK really is about to.
        eventSubject.send(.syncStalled(attempt: attempt, gaveUp: false))

        stopPolling()
        isRunning = false
        await engine.stop()

        do {
            try await engine.reopen(server: currentEndpoint, network: initializer.network)
        } catch {
            // A reopen that failed still spent an attempt. Not counting it would leave the backoff
            // unarmed and the cap unreachable, so an endpoint that cannot be reopened at all would
            // be retried on every poll tick for as long as the app stays in the foreground.
            stallRestartAttempts += 1
            lastStallRestartAt = Date()
            initializer.logger.error(
                "[slipstream] stall recovery could not reopen the engine handle: \(error.localizedDescription)",
                file: #file,
                function: #function,
                line: #line
            )
            // This is the end of the road, so it must be announced here — see
            // `reportStallRecoveryStopped(error:)` for why silence would strand the host.
            reportStallRecoveryStopped(error: error)
            return
        }

        // The new handle's engine-side counters start at zero, so the emission mirrors must too —
        // otherwise the first tick of the new pass reads the reset `txSetVersion` as "unchanged".
        lastTxSetVersion = 0
        lastRevealRecovering = false
        // Re-arm the log and the handle-lifetime clamp for the new pass, but KEEP the recovery
        // budget: it is what bounds this very restart, and a full re-arm would clear it.
        resetStallWatchdog(resetRecoveryBudget: false)
        stallRestartAttempts += 1
        lastStallRestartAt = Date()

        do {
            // `startImpl`, not the public `start()`: this operation is holding the queue, and a
            // queued call would wait for itself.
            try await startImpl(retry: false, resetRecoveryBudget: false)
            // No post-start re-stop, and none is needed. The old code had to ask, after its
            // `start()`, whether a deliberate stop had landed while the pass was coming up — the
            // stop ran concurrently and could be overtaken by the very pass it meant to prevent.
            // A stop asked for during this operation is now simply queued behind it and stops the
            // pass this restart just started, which is the same outcome reached in one place
            // instead of two.
        } catch {
            initializer.logger.error(
                "[slipstream] stall recovery restarted the handle but could not start the pass: \(error.localizedDescription)",
                file: #file,
                function: #function,
                line: #line
            )
            // A failed start leaves no poll loop to re-decide, so this is the last chance to tell
            // the host that the SDK has stopped trying — on the FIRST attempt as much as on the
            // last. `startImpl` throws before it reaches `startPolling()` on every one of its exits
            // (the `isPrepared` guard, the migration gate, and `engine.start()` itself, which is
            // exactly what a dead transport fails), so what ends the recovery here is the absence
            // of a loop, not the exhaustion of the budget. A migration-blocked start is reported
            // the same way: the recovery is over either way, and the host's own migration-gate
            // handling is what starts sync again once the gate reopens.
            reportStallRecoveryStopped(error: error)
        }
    }

    /// [MOB-1850] Test seam: `passGeneration` as a poll tick would capture it.
    func passGenerationForTesting() -> Int {
        passGeneration
    }

    /// [MOB-1850] Test seam: `stopRequestGeneration` as a poll tick would capture it.
    func stopRequestGenerationForTesting() -> Int {
        stopRequestGeneration
    }

    /// [MOB-1850] Test seam: recovery restarts spent on the current handle. The only way to tell a
    /// restart that preserved its budget from one that quietly reset it.
    func stallRestartAttemptsForTesting() -> Int {
        stallRestartAttempts
    }

    /// [MOB-1850] Test seam: `currentEndpoint` is private, so a test asserting `restartSync(at:)`
    /// recorded the right endpoint (or reusing the current one to rebuild a nil handle) needs a way
    /// to read it back.
    func currentEndpointForTesting() -> LightWalletEndpoint {
        currentEndpoint
    }

    /// [MOB-1850] Ends a recovery restart that could not complete, and tells the host so.
    ///
    /// Both failure exits of `runStallRecovery` land here, and both are terminal in the
    /// same way: `stopPolling()` has already run and no pass came up, so there is no tick left to
    /// re-decide and the `.giveUp` branch — which lives in `tickPoll` — can never fire. A host
    /// that has just received `.syncStalled(attempt: 1, gaveUp: false)` would otherwise wait
    /// forever for a resolution that nothing in the SDK can produce. That is why the report is
    /// NOT gated on the restart cap: what ends the recovery here is the missing loop, not a spent
    /// budget, and a failure on attempt 1 silences the synchronizer exactly as thoroughly as one
    /// on attempt 3.
    ///
    /// - Parameter error: the failure that ended the restart, carried on the state stream so a
    ///   host watching only `stateStream` sees it too.
    private func reportStallRecoveryStopped(error: Error) {
        // The guard keeps the give-up once per handle, as everywhere else. `stallRestartAttempts`
        // has already been incremented by the caller, so it names the attempt that just failed.
        if !stallGaveUpReported {
            stallGaveUpReported = true
            eventSubject.send(.syncStalled(attempt: stallRestartAttempts, gaveUp: true))
        }
        // Mirror it on the state stream, the way `tickPoll` surfaces the engine's own error
        // state: with no pass running, a host that watches only `stateStream` would otherwise
        // keep displaying the last `.syncing`. Gated on `isPrepared` for the same reason
        // `stopImpl` gates its `.stopped` emission — a `wipe` that landed while the restart was
        // suspended has already published `.unprepared`, and `.error` would forge prepared-ness
        // back onto a wiped wallet.
        if latestState.internalSyncStatus.isPrepared {
            stateSubject.send(SynchronizerState(
                syncSessionID: latestState.syncSessionID,
                accountsBalances: latestState.accountsBalances,
                localAccountsBalances: latestState.localAccountsBalances,
                internalSyncStatus: .error(error),
                latestBlockHeight: latestState.latestBlockHeight,
                fullyScannedHeight: latestState.fullyScannedHeight,
                isRecovering: currentlyRecovering,
                // Balances carry over verbatim here too, so their masked-ness must carry with them —
                // same reasoning as `stopImpl`'s `.stopped` emission above.
                isSpendableMasked: latestState.isSpendableMasked
            ))
        }
    }

    /// [#1975] The poll loop's background-resubmission driver: decides (via the pure
    /// `resubmissionCheckDue` gate) whether this tick runs a resubmission check, and if so fires
    /// it in `resubmissionTask`. Synchronous and non-blocking — the caller's tick never waits on
    /// the check. See the driver block at the top of the type for the two cadences and the
    /// cancel-only teardown rule.
    ///
    /// `internal` (not `private`) so `@testable` tests can drive the gate directly, mirroring
    /// `setInternalSyncStatusForTesting`; production's only caller is `tickPoll`.
    ///
    /// - Parameters:
    ///   - state: `snap.state` (0 = disconnected, 1 = syncing, 2 = error, 3 = done).
    ///   - chainTip: `snap.chainTip` — the resubmission candidates are selected `upTo:` it.
    ///   - isCancelled: whether the CALLING task is cancelled. Defaulted to `Task.isCancelled`,
    ///     which — because default arguments are evaluated at the call site — reads the poll
    ///     task's own flag when `tickPoll` calls this. A tick that resumes after teardown
    ///     cancelled `pollTask` therefore fires nothing; see the driver block above for the
    ///     wipe-resurrects-the-plan-database failure this closes. Tests pass it explicitly.
    func maybeRunTxResubmission(state: UInt8, chainTip: UInt64, isCancelled: Bool = Task.isCancelled) {
        let now = Date().timeIntervalSince1970
        guard SlipstreamSynchronizer.resubmissionCheckDue(
            isCancelled: isCancelled,
            state: state,
            chainTip: chainTip,
            secondsSinceLastCheck: now - lastResubmissionCheckTime,
            inFlight: resubmissionTask != nil
        ) else { return }

        // Stamped at FIRE time, not at completion: the cadence is "a check every 60 s", and a
        // check that takes a while must not push the next one further out.
        lastResubmissionCheckTime = now
        let latestBlockHeight = BlockHeight(chainTip)
        resubmissionTask = Task { [weak self] in
            guard let self else { return }
            await self.runResubmissionCheck(latestBlockHeight: latestBlockHeight)
        }
    }

    /// The actor-isolated body of one resubmission check: hops back onto the actor so
    /// `txResubmitter` never leaves it, and clears the in-flight handle on every exit path.
    private func runResubmissionCheck(latestBlockHeight: BlockHeight) async {
        defer { finishResubmissionCheck() }
        // Non-throwing: `TxResubmitter` logs and swallows both the candidate lookup and every
        // per-transaction submit failure (a cancelled submit included), so one dead endpoint —
        // or a teardown mid-check — can never escape as an unhandled error here.
        await txResubmitter.checkAndResubmit(latestBlockHeight: latestBlockHeight)
    }

    /// Clears the in-flight handle. THE single writer that nils `resubmissionTask` (teardown only
    /// cancels) — see the driver block for why that ordering is what keeps the spawn guard sound.
    private func finishResubmissionCheck() {
        resubmissionTask = nil
    }

    /// Test-only seam: awaits the in-flight resubmission check (if any) and returns the stamp of
    /// the last check the driver FIRED (0 = never). Lets `@testable` tests observe the interval
    /// gate deterministically instead of sleeping, and guarantees a follow-up call is gated by
    /// the interval rather than merely by "in flight". `internal`, never called by production.
    func awaitResubmissionCheckForTesting() async -> TimeInterval {
        await resubmissionTask?.value
        return lastResubmissionCheckTime
    }

    /// Test-only seam: whether a check is in flight. Pins the single-writer invariant — after a
    /// completed check this must read false (the task's own `finishResubmissionCheck()` cleared
    /// the handle), and it must NOT be false merely because teardown nil'd it. `internal`.
    var resubmissionCheckInFlightForTesting: Bool { resubmissionTask != nil }

    /// Pure gate for the background-resubmission driver. Static + pure so the truth table is
    /// unit-testable without an engine, mirroring `isSyncStalled`.
    ///
    /// - Parameters:
    ///   - isCancelled: whether the calling task is cancelled. Checked FIRST: a cancelled poll
    ///     task means teardown is in progress (possibly a `wipe()` deleting the very databases a
    ///     check would touch), so nothing else about the tick can make a check legitimate.
    ///   - state: `snap.state`. Only Syncing (1) and Done (3) check — those are the states with
    ///     a live server connection, and they mirror the old pipeline, which ran
    ///     `TxResubmissionAction` once per sync pass. Disconnected (0) / Error (2) have no
    ///     network, so a check there could only burn a database walk and log failures.
    ///   - chainTip: `snap.chainTip`; 0 means the server tip is not known yet, and candidates
    ///     are selected `upTo:` that height, so there is nothing to resolve.
    ///   - secondsSinceLastCheck: elapsed wall time since the last check FIRED (an elapsed span
    ///     rather than two timestamps, mirroring `isSyncStalled`). Enormous before the first
    ///     check (the stamp starts at 0), so the first eligible tick always fires; a backwards
    ///     clock adjustment can make it negative, which merely defers the next check.
    ///   - inFlight: whether a check is already running.
    /// - Returns: true when this tick should run a resubmission check.
    static func resubmissionCheckDue(
        isCancelled: Bool,
        state: UInt8,
        chainTip: UInt64,
        secondsSinceLastCheck: TimeInterval,
        inFlight: Bool
    ) -> Bool {
        guard !isCancelled else { return false }
        guard state == 1 || state == 3 else { return false }
        guard chainTip > 0 else { return false }
        guard !inFlight else { return false }
        return secondsSinceLastCheck >= resubmissionCheckInterval
    }

    /// [v2.1 Phase 2] THE summary source for the slipstream path: the engine's unified
    /// phase-resolving summary (`zcashlc_slipstream_wallet_summary`, ENGINE_API_V2.md §0.5) —
    /// correct at EVERY phase (recovering ⇒ per-account Σ-reconciled balances, never over-shows;
    /// else ⇒ upstream passthrough), and freely callable (per poll tick included): the engine
    /// rations the expensive walk internally (E-1 — serve-cached + background refresh at
    /// boundaries/idle-TTL; the recovery view is re-read every call, so the mid-restore climb
    /// stays per-tick).
    ///
    /// The [#1591] stale-tip spendable mask keys on the ENGINE-OWNED fact `snapshot.tipFresh`
    /// (E-2); only the 3-line transform stays host-side (the C `AccountBalance` cannot express
    /// the awaiting-resolution shift). Recovery balances are never masked — parity with the
    /// old path, where the recovery display bypassed the legacy summary's mask entirely.
    /// The visible summary is engine-owned and recovery-safe. The local snapshot always comes
    /// directly from the shared wallet database and is display-only; it remains available while
    /// the engine handle is closed during server replacement.
    private func walletBalanceSnapshots() async -> (
        visible: WalletSummary?,
        local: [AccountUUID: AccountBalance]?
    ) {
        // [MOB-1850] The policy is spelled out for the same reason the drain capacity is: it is the
        // concrete engine's own default, restated because a protocol requirement cannot carry one.
        let summary = await engine.walletSummary(confirmationsPolicy: ConfirmationsPolicy.defaultTransferPolicy())
        let provider = initializer.rustBackend as? LocalBalanceProviding
        let local = try? await provider?.getLocalAccountBalances()
        guard let summary else { return (nil, local) }
        let snap = await engine.snapshot()
        if snap?.isRecovering != 1 && snap?.tipFresh != 1 {
            currentlySpendableMasked = true
            return (summary.withSpendableMasked(), local)
        }
        currentlySpendableMasked = false
        return (summary, local)
    }

    // ── Accounts / Balances ────────────────────────────────────────────────────

    public func getAccountsBalances() async throws -> [AccountUUID: AccountBalance] {
        // [v2.1 Phase 2] ONE call, correct at every phase: the engine resolves recovery
        // (Σ-reconciled view values) vs normal (upstream passthrough) inside the unified
        // summary FFI and rations the expensive walk itself — no host-side branching.
        let summaries = await walletBalanceSnapshots()
        return summaries.visible?.accountBalances ?? [:]
    }

    public func getLocalAccountBalances() async throws -> [AccountUUID: AccountBalance]? {
        guard latestState.internalSyncStatus.isPrepared else { return nil }
        guard let provider = initializer.rustBackend as? LocalBalanceProviding else { return nil }
        return try await provider.getLocalAccountBalances()
    }

    public func transactionSubmissionStatus(for rawID: Data) async -> TransactionSubmissionStatus? {
        await submitPlanStore.plan(for: rawID)?.submissionStatus
    }

    public func listAccounts() async throws -> [Account] {
        try await initializer.rustBackend.listAccounts()
    }

    // swiftlint:disable:next function_parameter_count
    public func importAccount(
        ufvk: String,
        seedFingerprint: [UInt8]?,
        zip32AccountIndex: Zip32AccountIndex?,
        purpose: AccountPurpose,
        name: String,
        keySource: String?,
        birthday: BlockHeight? = nil
    ) async throws -> AccountUUID {
        let checkpointSource = initializer.container.resolve(CheckpointSource.self)
        // [v2.1 E-6] recover_until comes from the engine's `restore_anchor` primitive (live
        // tip; offline ⇒ the engine's max(checkpoint, birthday+1) fallback — an offline
        // import now keeps its recovery identity instead of provisioning recover_until=NULL).
        // Identifying fetches ride Tor when enabled (same engine state dir as start()).
        let anchor = await SlipstreamEngine.restoreAnchor(
            isRestore: true,
            birthday: birthday ?? 0,
            fallbackCheckpointHeight: checkpointSource.birthday(for: BlockHeight.max).height,
            server: currentEndpoint,
            network: initializer.network,
            torDirPath: await slipstreamTorDirPath()
        )
        let chainTipHeight = anchor.map { UInt32($0.height) }
        let effectiveBirthday = birthday ?? (chainTipHeight.map { BlockHeight($0) } ?? initializer.walletBirthday)

        // [MOB-1850] Everything from here on is one lifecycle operation. The anchor fetch above
        // stays OUTSIDE it deliberately: it is a network round trip with the engine still live and
        // no wallet write of its own, and holding the queue across it would make an unrelated
        // `stop()` wait on a server.
        return try await lifecycle.enqueueThrowing {
            try await self.importAccountOnLifecycleQueue(
                request: AccountImportRequest(
                    ufvk: ufvk,
                    seedFingerprint: seedFingerprint,
                    zip32AccountIndex: zip32AccountIndex,
                    purpose: purpose,
                    name: name,
                    keySource: keySource
                ),
                effectiveBirthday: effectiveBirthday,
                recoverUntil: chainTipHeight
            )
        }.value
    }

    /// The identity `importAccount` hands to its queued turn. A struct, not six more parameters:
    /// the queued body already carries the two derived heights, and SwiftLint's parameter cap is a
    /// reasonable proxy for "this call is no longer readable".
    private struct AccountImportRequest {
        let ufvk: String
        let seedFingerprint: [UInt8]?
        let zip32AccountIndex: Zip32AccountIndex?
        let purpose: AccountPurpose
        let name: String
        let keySource: String?
    }

    /// The queued body of `importAccount`: stop the pass, write the account, restart if a pass was
    /// wanted. Runs alone, so the stopped interval it opens is genuinely uninterrupted.
    private func importAccountOnLifecycleQueue(
        request: AccountImportRequest,
        effectiveBirthday: BlockHeight,
        recoverUntil: UInt32?
    ) async throws -> AccountUUID {
        passGeneration += 1
        let checkpointSource = initializer.container.resolve(CheckpointSource.self)
        let checkpoint = checkpointSource.birthday(for: effectiveBirthday)

        // [#1755 H2 / SCENARIO_MATRIX S22] Serialize with the engine BEFORE the wallet write.
        // The import force-re-queues [birthday, tip] as Historic (upstream `add_account`) so
        // already-scanned blocks get re-scanned with the new key — but with a pass still
        // running, an in-flight (uncancellable) write-behind commit could mark one of those
        // ranges Scanned AFTER the import's re-queue, and that range would never be re-scanned
        // with the new account's key: silently missing notes. Stopping first guarantees any
        // orphan commit lands BEFORE the import transaction (both serialize on the SQLite
        // write lock), so the force-re-queue is the last writer.
        // [MOB-1850] The INTENT, not the instantaneous flag: a stall recovery requested before this
        // turn clears `isRunning`, so sampling that alone would read this wallet as idle and skip
        // the restart below, leaving nothing running once the recovery abandons on the generation
        // this turn has just retired. See `passIntendedRunning`.
        let wasRunning = passIntendedRunning
        // [MOB-1850 hardening] Without this, `isRunning` stayed `true` and the poll loop stayed
        // alive across the stopped interval below: a tick spawned fresh by that still-alive loop
        // captures `passGeneration` at the top of its OWN call, so the `passGeneration += 1` above
        // does not retire it, and `isRunning` was the only guard left standing between it and
        // publishing state for an engine that is mid-import. `startImpl` (below, when `wasRunning`)
        // restores both.
        stopPolling()
        isRunning = false
        await engine.stop()

        let uuid: AccountUUID
        do {
            uuid = try await initializer.rustBackend.importAccount(
                ufvk: request.ufvk,
                seedFingerprint: request.seedFingerprint,
                zip32AccountIndex: request.zip32AccountIndex,
                treeState: checkpoint.treeState(),
                recoverUntil: recoverUntil,
                purpose: request.purpose,
                name: request.name,
                keySource: request.keySource
            )
        } catch {
            // A failed import must not leave the engine dead.
            if wasRunning {
                try? await startImpl(retry: false, resetRecoveryBudget: true)
            }
            throw error
        }

        // [#1755 → v2.1 E-5] Make the new account's re-scan VISIBLE + prompt. The re-scan's
        // progress needs NO host help anymore: the ENGINE detects the scope expansion (the
        // new account's older birthday drops the suggest-round seed far below the session
        // floor) and re-baselines the floor, so the blessed `progressPermille` reads the
        // re-scan as a genuine 0→100% climb (the `forceCounterProgressUntilDone` host bypass
        // is deleted). One host job remains: RESTART the pass — the follow loop only
        // re-syncs when the server tip advances (`session.rs` `should_resync`), so without a
        // restart the re-scan would wait for the next block (≤ ~75 s). `try?`: a restart
        // hiccup must never fail an otherwise-successful import.
        initializer.logger.debug(
            "[#1755] importAccount: wasRunning=\(wasRunning) "
            + (wasRunning ? "→ restarting sync pass now to surface the re-scan" : "→ next start() will re-scan")
        )
        if wasRunning {
            try? await startImpl(retry: false, resetRecoveryBudget: true)
        }

        return uuid
    }

    public func deleteAccount(_ accountUUID: AccountUUID) async throws {
        // [MOB-1850] One lifecycle operation: the stopped interval below exists so that no pass
        // scans across the deletion, and only the queue can make that interval real — a recovery
        // restart used to complete its `engine.start()` inside it.
        try await lifecycle.enqueueThrowing {
            try await self.deleteAccountOnLifecycleQueue(accountUUID)
        }.value
    }

    /// The queued body of `deleteAccount(_:)`.
    private func deleteAccountOnLifecycleQueue(_ accountUUID: AccountUUID) async throws {
        passGeneration += 1
        // [#1755 B4-16] Serialize with the engine — a raw pass-through here killed the wallet:
        // an in-flight pass scans with a PER-RANGE snapshot of the UFVK map + nullifier views
        // (`WriteBehindFacade::seed`, whose documented invariant is "accounts mutate only via
        // import/create, which cannot run during a range"). Deleting mid-range made the next
        // `put_blocks` write notes for a vanished account → non-transient pass error. So:
        // stop the engine first, delete, then restart. The restarted pass re-seeds without
        // the deleted key, and `WalletSession::open` prunes the account's orphaned Historic
        // scan ranges — a deep-birthday import's restore does NOT grind on after its account
        // is gone. `wasRunning` mirrors importAccount's restart contract, intent included.
        let wasRunning = passIntendedRunning
        // [MOB-1850 hardening] See the identical comment in `importAccountOnLifecycleQueue`: without
        // this, `isRunning` and the poll loop both survive the stopped interval below, and a tick the
        // still-alive loop spawns fresh can publish state for the engine mid-delete. `startImpl`
        // (below, when `wasRunning`) restores both.
        stopPolling()
        isRunning = false
        await engine.stop()
        try await initializer.rustBackend.deleteAccount(accountUUID)
        // `delete_account` removes the account's transactions — bump `tx_set_version`
        // (tag-5 poke) so hosts re-fetch and Activity drops the dead rows on the next tick.
        await engine.notifyTxChange()
        if wasRunning {
            try? await startImpl(retry: false, resetRecoveryBudget: true)
        }
    }

    // ── Addresses ─────────────────────────────────────────────────────────────

    public func getUnifiedAddress(accountUUID: AccountUUID) async throws -> UnifiedAddress {
        try await initializer.rustBackend.getCurrentAddress(accountUUID: accountUUID)
    }

    public func getSaplingAddress(accountUUID: AccountUUID) async throws -> SaplingAddress {
        try await getUnifiedAddress(accountUUID: accountUUID).saplingReceiver()
    }

    public func getTransparentAddress(accountUUID: AccountUUID) async throws -> TransparentAddress {
        try await getUnifiedAddress(accountUUID: accountUUID).transparentReceiver()
    }

    public func getCustomUnifiedAddress(accountUUID: AccountUUID, receivers: Set<ReceiverType>) async throws -> UnifiedAddress {
        try await initializer.rustBackend.getNextAvailableAddress(accountUUID: accountUUID, receiverFlags: receivers.toFlags())
    }

    public func getSingleUseTransparentAddress(accountUUID: AccountUUID) async throws -> SingleUseTransparentAddress {
        try await initializer.rustBackend.getSingleUseTransparentAddress(accountUUID: accountUUID)
    }

    // ── Proposals / Spending ──────────────────────────────────────────────────

    public func proposeTransfer(
        accountUUID: AccountUUID,
        recipient: Recipient,
        amount: Zatoshi,
        memo: Memo?
    ) async throws -> Proposal {
        // Parity with `start()`'s guard above and with `SDKSynchronizer.proposeTransfer`'s
        // `throwIfUnprepared()`: the encoder path below never touches the engine handle, so
        // without this check an unprepared call would fall straight through to the rust
        // backend instead of failing with the documented `synchronizerNotPrepared`.
        guard latestState.internalSyncStatus.isPrepared else {
            throw ZcashError.synchronizerNotPrepared
        }
        try recipient.ensureMemoIsAllowed(memo)
        return try await transactionEncoder.proposeTransfer(
            accountUUID: accountUUID,
            recipient: recipient.stringEncoded,
            amount: amount,
            memoBytes: memo?.asMemoBytes()
        )
    }

    public func proposeSendMax(
        accountUUID: AccountUUID,
        recipient: Recipient,
        memo: Memo?,
        mode: MaxSpendMode
    ) async throws -> Proposal {
        // Parity with `start()`'s guard above and with `SDKSynchronizer.proposeSendMax`'s
        // `throwIfUnprepared()`: the encoder path below never touches the engine handle, so
        // without this check an unprepared call would fall straight through to the rust
        // backend instead of failing with the documented `synchronizerNotPrepared`.
        guard latestState.internalSyncStatus.isPrepared else {
            throw ZcashError.synchronizerNotPrepared
        }
        try recipient.ensureMemoIsAllowed(memo)
        return try await transactionEncoder.proposeSendMax(
            accountUUID: accountUUID,
            recipient: recipient.stringEncoded,
            memoBytes: memo?.asMemoBytes(),
            mode: mode
        )
    }

    public func proposeOrchardToIronwoodMigration(accountUUID: AccountUUID) async throws -> Proposal {
        // Parity with `start()`'s guard above and with `SDKSynchronizer.proposeOrchardToIronwoodMigration`'s
        // `throwIfUnprepared()`: the encoder path below never touches the engine handle, so
        // without this check an unprepared call would fall straight through to the rust
        // backend instead of failing with the documented `synchronizerNotPrepared`.
        guard latestState.internalSyncStatus.isPrepared else {
            throw ZcashError.synchronizerNotPrepared
        }
        return try await transactionEncoder.proposeOrchardToIronwoodMigration(accountUUID: accountUUID)
    }

    public func proposeShielding(
        accountUUID: AccountUUID,
        shieldingThreshold: Zatoshi,
        memo: Memo,
        transparentReceiver: TransparentAddress? = nil
    ) async throws -> Proposal? {
        // Parity with `start()`'s guard above and with `SDKSynchronizer.proposeShielding`'s
        // `throwIfUnprepared()`: the encoder path below never touches the engine handle, so
        // without this check an unprepared call would fall straight through to the rust
        // backend instead of failing with the documented `synchronizerNotPrepared`.
        guard latestState.internalSyncStatus.isPrepared else {
            throw ZcashError.synchronizerNotPrepared
        }
        return try await transactionEncoder.proposeShielding(
            accountUUID: accountUUID,
            shieldingThreshold: shieldingThreshold,
            memoBytes: memo.asMemoBytes(),
            transparentReceiver: transparentReceiver?.stringEncoded
        )
    }

    public func proposefulfillingPaymentURI(
        _ uri: String,
        accountUUID: AccountUUID
    ) async throws -> Proposal {
        // Parity with `start()`'s guard above and with `SDKSynchronizer.proposefulfillingPaymentURI`'s
        // `throwIfUnprepared()`: the encoder path below never touches the engine handle, so
        // without this check an unprepared call would fall straight through to the rust
        // backend instead of failing with the documented `synchronizerNotPrepared`.
        guard latestState.internalSyncStatus.isPrepared else {
            throw ZcashError.synchronizerNotPrepared
        }

        return try await transactionEncoder.proposeFulfillingPaymentFromURI(
            uri,
            accountUUID: accountUUID
        )
    }

    public func createProposedTransactions(
        proposal: Proposal,
        spendingKey: UnifiedSpendingKey
    ) async throws -> AsyncThrowingStream<TransactionSubmitResult, Error> {
        let transactions = try await broadcaster.createProposedTransactions(
            proposal: proposal,
            spendingKey: spendingKey
        )
        return submitTransactions(transactions)
    }

    // ── PCZT ──────────────────────────────────────────────────────────────────

    public func createPCZTFromProposal(accountUUID: AccountUUID, proposal: Proposal) async throws -> Pczt {
        try await initializer.rustBackend.createPCZTFromProposal(
            accountUUID: accountUUID,
            proposal: proposal.inner
        )
    }

    public func redactPCZTForSigner(pczt: Pczt) async throws -> Pczt {
        try await initializer.rustBackend.redactPCZTForSigner(pczt: pczt)
    }

    public func PCZTRequiresSaplingProofs(pczt: Pczt) async -> Bool {
        await initializer.rustBackend.PCZTRequiresSaplingProofs(pczt: pczt)
    }

    public func addProofsToPCZT(pczt: Pczt) async throws -> Pczt {
        try await SaplingParameterDownloader.downloadParamsIfnotPresent(
            spendURL: initializer.spendParamsURL,
            spendSourceURL: initializer.saplingParamsSourceURL.spendParamFileURL,
            outputURL: initializer.outputParamsURL,
            outputSourceURL: initializer.saplingParamsSourceURL.outputParamFileURL,
            logger: initializer.logger
        )
        return try await initializer.rustBackend.addProofsToPCZT(pczt: pczt)
    }

    public func createTransactionFromPCZT(pcztWithProofs: Pczt, pcztWithSigs: Pczt) async throws -> AsyncThrowingStream<TransactionSubmitResult, Error> {
        let transactions = try await broadcaster.createTransactionFromPCZT(
            pcztWithProofs: pcztWithProofs,
            pcztWithSigs: pcztWithSigs
        )
        return submitTransactions(transactions)
    }

    // ── Transactions ──────────────────────────────────────────────────────────

    public var transactions: [ZcashTransaction.Overview] {
        get async { (try? await allTransactions()) ?? [] }
    }

    public var sentTransactions: [ZcashTransaction.Overview] {
        get async { (try? await allSentTransactions()) ?? [] }
    }

    public var receivedTransactions: [ZcashTransaction.Overview] {
        get async { (try? await allReceivedTransactions()) ?? [] }
    }

    public nonisolated func paginatedTransactions(of kind: TransactionKind = .all) -> PaginatedTransactionRepository {
        PagedTransactionRepositoryBuilder.build(initializer: initializer, kind: kind)
    }

    public func allTransactions() async throws -> [ZcashTransaction.Overview] {
        await droppingUnreconciled(try await enhanceWithState(transactionRepository.find(offset: 0, limit: Int.max, kind: .all)))
    }

    public func allTransactions(from transaction: ZcashTransaction.Overview, limit: Int) async throws -> [ZcashTransaction.Overview] {
        await droppingUnreconciled(try await enhanceWithState(transactionRepository.find(from: transaction, limit: limit, kind: .all)))
    }

    /// [#1755] During a recent-first RESTORE the scheduler scans a recent block that spends an older note
    /// before that note's origin block, so a self-send's change reads as a phantom "+receive" until the
    /// spend links. `ext_slipstream_v_tx_reconciled` flags those still-provisional txs, and we hold them out of
    /// the Activity list until their delta is final (genuine receives + already-linked sends still surface
    /// as soon as they appear).
    ///
    /// GATED ON `currentlyRecovering`: outside an active recovery this is a hard no-op — and we skip the
    /// view query entirely (this is the Activity-fetch hot path). A mined tx on an up-to-date wallet is real
    /// and must never be hidden. In the field the view was seen flagging a fresh Keystone send whose
    /// just-spent note stayed unlinked even after full sync AND an app restart, dropping the confirmed tx
    /// from Activity indefinitely — the "vanishing transaction" bug. The earlier "empty set outside
    /// recovery" assumption did not hold, so the recovery scope is now explicit (the transient dangling this
    /// guards against is a property of recent-first recovery scanning, not of a synced wallet).
    private func droppingUnreconciled(_ txs: [ZcashTransaction.Overview]) async -> [ZcashTransaction.Overview] {
        let recovering = currentlyRecovering
        // Optimization + fix: outside recovery `reconciledVisible` returns `txs` unchanged, so skip the
        // view query rather than fetch-then-discard on every Activity refresh.
        guard recovering else { return txs }
        let unreconciled = (try? await transactionRepository.unreconciledTxids()) ?? []
        let kept = Self.reconciledVisible(txs, unreconciled: unreconciled, recovering: recovering)
        // [#1755] Fires only during recovery now — provisional txs are gated and released as their spends
        // link, not held wholesale.
        initializer.logger.debug(
            "[slipstream] reconcile: holding \(txs.count - kept.count) provisional tx(s), surfacing \(kept.count)/\(txs.count)",
            file: #file,
            function: #function,
            line: #line
        )
        return kept
    }

    /// Pure: which txs the Activity list shows. Outside recovery (or with nothing flagged) every tx passes;
    /// during recovery the unreconciled txids (a dangling shielded spend per `ext_slipstream_v_tx_reconciled`)
    /// are held back until their delta is final. Static + pure so it is unit-testable.
    static func reconciledVisible(
        _ txs: [ZcashTransaction.Overview],
        unreconciled: Set<Data>,
        recovering: Bool
    ) -> [ZcashTransaction.Overview] {
        guard recovering, !unreconciled.isEmpty else { return txs }
        return txs.filter { !unreconciled.contains($0.rawID) }
    }

    /// T8.3.6 (UX): populate `ZcashTransaction.Overview.state` on fetched transactions (the
    /// Slipstream equivalent of `SDKSynchronizer.enhanceRawTransactionsWithState`). `find`
    /// leaves `state == nil`, so without this Zashi maps an INCOMING tx via
    /// `transaction.state == .pending` → `nil == .pending` → false → ".received" — a 0-conf
    /// mempool tx then wrongly shows "received" instead of "receiving". Pure mapping lives in
    /// `transactionsWithState`; here we just resolve the current chain height it needs.
    private func enhanceWithState(_ raw: [ZcashTransaction.Overview]) async -> [ZcashTransaction.Overview] {
        let tip = latestState.latestBlockHeight
        return Self.transactionsWithState(raw, currentHeight: tip != 0 ? tip : ((try? await initializer.rustBackend.maxScannedHeight()) ?? .zero))
    }

    public func getMemos(for rawID: Data) async throws -> [Memo] {
        try await transactionRepository.findMemos(for: rawID)
    }

    public func getMemos(for transaction: ZcashTransaction.Overview) async throws -> [Memo] {
        try await transactionRepository.findMemos(for: transaction.rawID)
    }

    public func getRecipients(for transaction: ZcashTransaction.Overview) async -> [TransactionRecipient] {
        (try? await transactionRepository.getRecipients(for: transaction.rawID)) ?? []
    }

    public func getTransactionOutputs(for transaction: ZcashTransaction.Overview) async -> [ZcashTransaction.Output] {
        (try? await transactionRepository.getTransactionOutputs(for: transaction.rawID)) ?? []
    }

    public func fetchTxidsWithMemoContaining(searchTerm: String) async throws -> [Data] {
        try await transactionRepository.fetchTxidsWithMemoContaining(searchTerm: searchTerm)
    }

    public func enhanceTransactionBy(txId: TxId) async throws {
        let txIdData = txId.id.data
        let sdkFlags = initializer.container.resolve(SDKFlags.self)
        let response = try await initializer.blockDownloaderService.fetchTransaction(
            txId: txIdData,
            mode: await sdkFlags.ifTor(ServiceMode.txIdGroup(prefix: "fetch", txId: txIdData))
        )
        if response.status == .txidNotRecognized {
            try await initializer.rustBackend.setTransactionStatus(txId: txIdData, status: .txidNotRecognized)
        } else if let fetchedTransaction = response.tx {
            _ = try await initializer.rustBackend.decryptAndStoreTransaction(
                txBytes: fetchedTransaction.raw.bytes,
                minedHeight: fetchedTransaction.minedHeight
            )
        }
    }

    // ── Height queries ────────────────────────────────────────────────────────

    public func latestHeight() async throws -> BlockHeight {
        let sdkFlags = initializer.container.resolve(SDKFlags.self)
        return try await initializer.lightWalletService.latestBlockHeight(mode: await sdkFlags.ifTor(.uniqueTor))
    }

    // ── UTXO refresh ──────────────────────────────────────────────────────────

    public func refreshUTXOs(address: TransparentAddress, from height: BlockHeight) async throws -> RefreshedUTXOs {
        // Delegate via blockDownloaderService — same path as CompactBlockProcessor.refreshUTXOs.
        let stream = try initializer.blockDownloaderService.fetchUnspentTransactionOutputs(
            tAddress: address.stringEncoded,
            startHeight: height,
            mode: .direct
        )
        var utxos: [UnspentTransactionOutputEntity] = []
        for try await utxo in stream {
            utxos.append(utxo)
        }
        var inserted: [UnspentTransactionOutputEntity] = []
        var skipped: [UnspentTransactionOutputEntity] = []
        for utxo in utxos {
            do {
                try await initializer.rustBackend.putUnspentTransparentOutput(
                    txid: utxo.txid.bytes,
                    index: utxo.index,
                    script: utxo.script.bytes,
                    value: Int64(utxo.valueZat),
                    height: utxo.height
                )
                inserted.append(utxo)
            } catch {
                skipped.append(utxo)
            }
        }
        return RefreshedUTXOs(inserted: inserted, skipped: skipped)
    }

    // ── Exchange rate ─────────────────────────────────────────────────────────

    public nonisolated func refreshExchangeRateUSD() {
        Task {
            let sdkFlags = initializer.container.resolve(SDKFlags.self)
            guard await sdkFlags.exchangeRateEnabled else { return }
            let torClient = initializer.container.resolve(TorClient.self)
            do {
                let isolatedClient = try await torClient.isolatedClient()
                exchangeRateSubject.send(try await isolatedClient.getExchangeRateUSD())
            } catch {
                // swallow exchange rate fetch errors (best-effort)
            }
        }
    }

    // ── Rescan / Rewind ───────────────────────────────────────────────────────

    public func rescanFrom(height: BlockHeight) async throws {
        let saplingActivationHeight = initializer.network.networkType == .mainnet
            ? ZcashMainnet().constants.saplingActivationHeight
            : ZcashTestnet().constants.saplingActivationHeight
        guard height >= saplingActivationHeight else {
            throw ZcashError.rescanFromHeightBellowSaplingActivation
        }
        let checkpointSource = initializer.container.resolve(CheckpointSource.self)
        let checkpoint = checkpointSource.birthday(for: height)
        try await initializer.rustBackend.truncateToChainState(chainState: checkpoint.treeState())
    }

    public nonisolated func rewind(_ policy: RewindPolicy) -> AnyPublisher<Void, Error> {
        let subject = PassthroughSubject<Void, Error>()
        Task {
            await self.rewindImpl(policy, subject)
        }
        return subject.eraseToAnyPublisher()
    }

    /// The actor-isolated body of `rewind(_:)`.
    private func rewindImpl(_ policy: RewindPolicy, _ subject: PassthroughSubject<Void, Error>) async {
        let height: BlockHeight?
        switch policy {
        case .quick:
            height = nil
        case .birthday:
            height = initializer.walletBirthday
        case .height(let rewindHeight):
            height = rewindHeight
        case .transaction(let transaction):
            guard let txHeight = transaction.anchor(network: initializer.network) else {
                subject.send(completion: .failure(ZcashError.synchronizerRewindUnknownArchorHeight))
                return
            }
            height = txHeight
        }

        // [MOB-1850] The stop/truncate/restart below is one lifecycle operation. The policy→height
        // resolution above is not: it touches no engine state and can fail the publisher outright.
        await lifecycle.enqueue {
            await self.rewindOnLifecycleQueue(to: height, subject)
        }.value
    }

    /// The queued body of `rewindImpl(_:_:)`, from the teardown to the restart.
    private func rewindOnLifecycleQueue(to height: BlockHeight?, _ subject: PassthroughSubject<Void, Error>) async {
        passGeneration += 1

        // [#1755 H1 / SCENARIO_MATRIX S15] Serialize with the engine — the same contract as
        // deleteAccount/importAccount: truncating while a pass is mid-write would let the
        // in-flight pass commit against the truncated chain state (the old SDK stopped the
        // processor inside `blockProcessor.rewind`; slipstream lost that parity). Stop →
        // truncate → restart. The restarted pass re-suggests from the truncated queue, and
        // the engine's scope-expansion re-baseline (E-5) makes the re-scan read as a genuine
        // climb. Restart on BOTH outcomes — a failed truncate must not leave the engine dead.
        let wasRunning = passIntendedRunning
        // [MOB-1850 hardening] See the identical comment in `importAccountOnLifecycleQueue`: without
        // this, `isRunning` and the poll loop both survive the stopped interval below, and a tick the
        // still-alive loop spawns fresh can publish state for the engine mid-truncate. `startImpl`
        // (below, on both outcomes when `wasRunning`) restores both.
        stopPolling()
        isRunning = false
        await engine.stop()

        do {
            let checkpointSource = initializer.container.resolve(CheckpointSource.self)
            if let height {
                let checkpoint = checkpointSource.birthday(for: height)
                try await initializer.rustBackend.truncateToChainState(chainState: checkpoint.treeState())
            } else {
                // Quick rewind: truncate to nearest checkpoint at the current latestBlockHeight.
                let currentHeight = latestState.latestBlockHeight
                let checkpoint = checkpointSource.birthday(for: currentHeight)
                try await initializer.rustBackend.truncateToChainState(chainState: checkpoint.treeState())
            }
            // [audit SDK-5 → E-3] No host cache to reset after a truncate: the summary is
            // engine-served per call (E-1). Engine COUNTERS are NOT reset here on purpose:
            // the handle survives a rewind, so `enhancedTxs`/`rangesCompleted` stay monotonic
            // and the SDK mirrors keep tracking them (mirrors reset only where the handle
            // dies: `wipe()` / `switchTo()`).
            if wasRunning {
                try? await startImpl(retry: false, resetRecoveryBudget: true)
            }
            subject.send(completion: .finished)
        } catch {
            if wasRunning {
                try? await startImpl(retry: false, resetRecoveryBudget: true)
            }
            subject.send(completion: .failure(error))
        }
    }

    /// Wipes all wallet data managed by this synchronizer.
    ///
    /// Mirrors `SDKSynchronizer.wipe()` + `CompactBlockProcessor.doWipe()`:
    /// 1. Stop the poll loop, then cancel AND await any in-flight background resubmission
    ///    check ([#1975]) — it must not still be reading or writing the files step 4 deletes.
    /// 2. `engine.stop()` — cancel any in-flight sync task.
    /// 3. `engine.close()` — free the Rust handle so no Rust-side state survives file deletion.
    /// 4. Delete `data.db` + its WAL (`-wal`) and shared-memory (`-shm`) siblings.
    /// 5. Delete the `fsBlockDbRoot` directory (parity with old SDK's `storage.clear()` +
    ///    FS-cache directory removal; Slipstream does not use it but the app may have created it).
    /// 6. Delete the submit-plan-store database file (`submitPlanStore.wipe()`) — restores the
    ///    documented `Synchronizer.wipe()` contract ("`Synchronizer.wipe()` deletes the plan
    ///    database file", MIGRATING.md) that only `SDKSynchronizer` used to honor ([#1976]).
    /// 7. Reset the state subject to `.zero` (status `.unprepared`).
    /// 8. Complete the returned publisher — or fail it if any file-removal throws.
    ///
    /// The publisher uses a `PassthroughSubject` driven from a `Task(priority: .high)`,
    /// mirroring the `SDKSynchronizer.wipe()` idiom.
    public nonisolated func wipe() -> AnyPublisher<Void, Error> {
        let subject = PassthroughSubject<Void, Error>()
        Task(priority: .high) { [weak self] in
            guard let self else {
                subject.send(completion: .finished)
                return
            }
            await self.wipeImpl(subject)
        }
        return subject.eraseToAnyPublisher()
    }

    /// The actor-isolated body of `wipe()`.
    ///
    /// [MOB-1850] The whole of it is one lifecycle operation. A wipe deletes the files every other
    /// operation reads and writes, so it is the one that most needs the queue: a recovery restart
    /// reopening a handle onto a database this method has just removed would recreate it (SQLite
    /// recreates a file on connect) and leave the wallet half-wiped.
    private func wipeImpl(_ subject: PassthroughSubject<Void, Error>) async {
        await lifecycle.enqueue {
            await self.wipeOnLifecycleQueue(subject)
        }.value
    }

    /// The queued body of `wipe()`.
    private func wipeOnLifecycleQueue(_ subject: PassthroughSubject<Void, Error>) async {
        passGeneration += 1
        // 1. Stop polling.
        stopPolling()
        // 1a. [#1975] Cancel AND JOIN any in-flight resubmission check — it reads and writes the
        //     very database files about to be deleted. Cancel alone is not enough: only the
        //     SUBMIT stage observes cancellation (`SubmitPlanExecutor.submit`), while the prune
        //     stage has no cancellation checks and would run on to `deletePlans` after the plan
        //     file was removed. Joining does not violate the single-writer rule (that forbids
        //     nil'ing the handle here, not awaiting it): the task's own `finishResubmissionCheck()`
        //     clears it, and has done so by the time `.value` returns. No deadlock — awaiting
        //     suspends `wipeImpl` and frees the actor for that finish hop. A tick that resumes
        //     during this wipe cannot start a new check: `pollTask` is cancelled, and the driver
        //     is gated on the caller's cancellation.
        resubmissionTask?.cancel()
        await resubmissionTask?.value

        // 2. Stop the in-flight sync (non-blocking cancel in Rust).
        // [MOB-1850] A wipe is a deliberate stop that brings no pass of its own back up, so a
        // recovery queued behind it must treat it like `stop()` and abandon: hence the stop-REQUEST
        // bump, on top of the `passGeneration` bump every takeover makes.
        stopRequestGeneration += 1
        await engine.stop()

        // 3. Free the engine handle (exact-once — close() guards against double-free).
        await engine.close()

        // 3a. Reset the per-handle tx-set-version mirror: the engine handle is being
        //     destroyed, so the Rust-side monotonic counter restarts at 0 on next open().
        lastTxSetVersion = 0
        lastRevealRecovering = false

        // 3a-B4. Re-arm the stall watchdog: the handle is destroyed.
        resetStallWatchdog()

        // 3b. Close Swift-side DB connections before deleting files — mirrors
        //     SDKSynchronizer.wipe() prewipe closure (SDKSynchronizer.swift:759-760).
        transactionEncoder.closeDBConnection()
        transactionRepository.closeDBConnection()

        do {
            let fileManager = FileManager.default

            // 4. Remove data.db and its SQLite WAL/SHM siblings.
            // E.g. /path/data.db  → /path/data.db-wal, /path/data.db-shm.
            let dataDb = initializer.dataDbURL
            for suffix in ["", "-wal", "-shm"] {
                let targetURL = suffix.isEmpty
                    ? dataDb
                    : URL(fileURLWithPath: dataDb.path + suffix)
                if fileManager.fileExists(atPath: targetURL.path) {
                    try fileManager.removeItem(at: targetURL)
                }
            }

            // 5. Remove the fsBlockDbRoot directory tree (parity with old SDK wipe).
            let fsRoot = initializer.fsBlockDbRoot
            if fileManager.fileExists(atPath: fsRoot.path) {
                try fileManager.removeItem(at: fsRoot)
            }

            // 6. Delete the submit-plan-store database file — mirrors SDKSynchronizer.wipe()
            //    (SDKSynchronizer.swift:815-818), which wipes the plan store only when the
            //    wallet wipe succeeded (this `do` block only reaches here on success).
            await submitPlanStore.wipe()

            // 7. Reset state to unprepared/zero.
            stateSubject.send(.zero)

            // 8. Signal completion.
            subject.send(completion: .finished)
        } catch {
            subject.send(completion: .failure(error))
        }
    }

    // ── Migration (Orchard -> Ironwood) ────────────────────────────────────────
    //
    // Thin forwards to `migrationHost.migration(for:)`'s per-account `OrchardMigration` actor (or,
    // for the three wallet-scope gate members, to the host itself) -- mirrors `SDKSynchronizer`'s
    // "MARK: Migration" section exactly. The two members that can broadcast (`submitNoteSplit`,
    // `performMigrationBroadcast`) are guarded here by `throwIfSyncingForMigrationBroadcast()`
    // -- an advisory point-in-time check, not a hard mutual-exclusion lock: sync and migration
    // broadcasts must never share a session, and hosts still sequence sessions themselves.
    // `proveMigrationTransactions` is deliberately NOT guarded: proving is what a SYNC session is
    // for. Neither is `takeMigrationPreparation`, which only RETRIEVES -- a proved preparation's
    // submission is the app's own ordinary path, not a delivery session of the engine's.
    // `recordMigrationPreparationBroadcast` is likewise unguarded: it RECORDS an outcome the app
    // already produced -- refusing the record because a sync is open would only delay the
    // engine's knowledge of a broadcast that already happened.

    public func migrationAdvanceStep(accountUUID: AccountUUID) async throws -> MigrationAdvance? {
        try await migrationHost.migration(for: accountUUID).advanceStep()
    }

    public func migrationProgress(accountUUID: AccountUUID) async throws -> MigrationProgress? {
        try await migrationHost.migration(for: accountUUID).migrationProgress()
    }

    public func proveMigrationTransactions(
        accountUUID: AccountUUID,
        _ instruction: [MigrationProveTarget],
        maxProofs: Int
    ) async throws -> MigrationProveOutcome {
        try await migrationHost.migration(for: accountUUID).proveTransactions(instruction, maxProofs: maxProofs)
    }

    public func takeMigrationPreparation(accountUUID: AccountUUID, byTxid txid: Data) async throws -> PreparedMigrationTransfer {
        try await migrationHost.migration(for: accountUUID).takePreparation(byTxid: txid)
    }

    public func recordMigrationPreparationBroadcast(
        accountUUID: AccountUUID,
        _ prepared: PreparedMigrationTransfer,
        result: MigrationTransferResult
    ) async throws {
        try await migrationHost.migration(for: accountUUID).recordPreparationBroadcast(prepared, result: result)
    }

    public func migrationSyncWakeups(accountUUID: AccountUUID) async throws -> [MigrationSyncWakeup] {
        try await migrationHost.migration(for: accountUUID).syncWakeups()
    }

    public func estimatedMigrationChainTip() async throws -> BlockHeight {
        // Wallet-scoped (the samples come from the shared blocks table), so this lives on the
        // host, not on a per-account actor.
        try await migrationHost.estimatedChainTip()
    }

    public func estimatedMigrationSecondsPerBlock() async throws -> Double {
        try await migrationHost.estimatedSecondsPerBlock()
    }

    public func migrationTransactionStatuses(accountUUID: AccountUUID) async throws -> [MigrationTransactionStatus] {
        try await migrationHost.migration(for: accountUUID).transactionStatuses()
    }

    public func isNoteSplitNeeded(accountUUID: AccountUUID) async throws -> Bool {
        try await migrationHost.migration(for: accountUUID).isNoteSplitNeeded()
    }

    public func prepareNoteSplit(accountUUID: AccountUUID) async throws -> NoteSplitProposal {
        try await migrationHost.migration(for: accountUUID).prepareNoteSplit()
    }

    public func submitNoteSplit(
        accountUUID: AccountUUID,
        proposal: NoteSplitProposal,
        usk: UnifiedSpendingKey,
        options: MigrationNetworkPrivacyOptions
    ) async throws -> MigrationTransferResult {
        try throwIfSyncingForMigrationBroadcast()
        return try await migrationHost.migration(for: accountUUID).submitNoteSplit(proposal: proposal, usk: usk, options: options)
    }

    public func proposeMigrationTransfers(accountUUID: AccountUUID) async throws -> MigrationSchedule {
        try await migrationHost.migration(for: accountUUID).proposeMigrationTransfers()
    }

    public func proposeImmediateMigration(accountUUID: AccountUUID) async throws -> ImmediateMigrationProposal {
        try await migrationHost.migration(for: accountUUID).proposeImmediateMigration()
    }

    public func recordImmediateMigration(accountUUID: AccountUUID, txid: Data) async throws {
        try await migrationHost.migration(for: accountUUID).recordImmediateMigration(txid: txid)
    }

    public func residualAfterMigration(accountUUID: AccountUUID) async throws -> Zatoshi? {
        try await migrationHost.migration(for: accountUUID).residualAfterMigration()
    }

    public func lockMigrationResidual(accountUUID: AccountUUID) async throws -> Zatoshi {
        try await migrationHost.migration(for: accountUUID).lockMigrationResidual()
    }

    public func unlockMigrationResidual(accountUUID: AccountUUID) async throws -> Int {
        try await migrationHost.migration(for: accountUUID).unlockMigrationResidual()
    }

    public func estimateMigrationRuns(accountUUID: AccountUUID) async throws -> MigrationRunEstimate {
        try await migrationHost.migration(for: accountUUID).estimateMigrationRuns()
    }

    public func signAndStoreMigrationSchedule(accountUUID: AccountUUID, _ schedule: MigrationSchedule, usk: UnifiedSpendingKey) async throws {
        try await migrationHost.migration(for: accountUUID).signAndStoreMigrationSchedule(schedule, usk: usk)
    }

    public func performMigrationBroadcast(
        accountUUID: AccountUUID,
        _ instruction: MigrationBroadcastInstruction,
        options: MigrationNetworkPrivacyOptions
    ) async throws -> MigrationTransferResult {
        try throwIfSyncingForMigrationBroadcast()
        return try await migrationHost.migration(for: accountUUID).performBroadcast(instruction, options: options)
    }

    public func isMigrationSyncBlocked() async -> Bool {
        await migrationHost.isSyncBlocked()
    }

    public nonisolated var migrationSyncBlockedStream: AnyPublisher<Bool, Never> {
        migrationHost.syncBlockedStream
    }

    public func hasOverdueMigrationTransfers(accountUUID: AccountUUID, useEstimatedTip: Bool) async throws -> Bool {
        try await migrationHost.migration(for: accountUUID).hasOverdueTransfers(useEstimatedTip: useEstimatedTip)
    }

    public func hasInvalidMigrationTransfers(accountUUID: AccountUUID) async throws -> Bool {
        try await migrationHost.migration(for: accountUUID).hasInvalidTransfers()
    }

    public func restartCurrentMigrationStep(accountUUID: AccountUUID) async throws -> MigrationSchedule {
        try await migrationHost.migration(for: accountUUID).restartCurrentMigrationStep()
    }

    public func refreshStaleMigrationTransfers(accountUUID: AccountUUID, usk: UnifiedSpendingKey?) async throws -> MigrationSchedule {
        try await migrationHost.migration(for: accountUUID).refreshStaleTransfers(usk: usk)
    }

    public func createUnsignedNoteSplitPCZTs(
        accountUUID: AccountUUID,
        for schedule: MigrationSchedule
    ) async throws -> [MigrationUnsignedTransferPczt] {
        try await migrationHost.migration(for: accountUUID).createUnsignedNoteSplitPCZTs(for: schedule)
    }

    public func storeSignedNoteSplitPCZTs(accountUUID: AccountUUID, _ signed: [MigrationSignedTransferPczt]) async throws -> PreparedMigrationTransfer {
        try await migrationHost.migration(for: accountUUID).storeSignedNoteSplitPCZTs(signed)
    }

    public func createUnsignedMigrationTransferPCZTs(
        accountUUID: AccountUUID,
        for schedule: MigrationSchedule
    ) async throws -> [MigrationUnsignedTransferPczt] {
        try await migrationHost.migration(for: accountUUID).createUnsignedTransferPCZTs(for: schedule)
    }

    public func storeSignedMigrationSchedulePCZTs(accountUUID: AccountUUID, _ signed: [MigrationSignedTransferPczt]) async throws {
        try await migrationHost.migration(for: accountUUID).storeSignedSchedulePCZTs(signed)
    }

    // ── Migration Keystone batch-signing (external signer ceremony) ───────────
    //
    // DB-free, account-free: unlike the migration group above, these forward straight to
    // `initializer.rustBackend` (no `migrationHost.migration(for:)` per-account actor) -- the same
    // way the ordinary PCZT operations above do (`createPCZTFromProposal`, `redactPCZTForSigner`,
    // ...) -- mirrors `SDKSynchronizer`'s "MARK: Migration Keystone batch-signing" section exactly.

    /// See ``Synchronizer/batchMigrationPcztsForSigning(_:maxActionsPerSession:)`` for the contract.
    public func batchMigrationPcztsForSigning(
        _ pczts: [MigrationUnsignedTransferPczt],
        maxActionsPerSession: Int
    ) async throws -> [[MigrationUnsignedTransferPczt]] {
        try await OrchardMigration.batchPcztsForSigning(
            welding: initializer.rustBackend,
            pczts: pczts,
            maxActionsPerSession: maxActionsPerSession
        )
    }

    /// See ``Synchronizer/buildKeystoneSignBatchQRParts(requestId:pczts:maxFragmentLen:)`` for the contract.
    public func buildKeystoneSignBatchQRParts(
        requestId: Data,
        pczts: [MigrationUnsignedTransferPczt],
        maxFragmentLen: Int
    ) async throws -> [String] {
        try await initializer.rustBackend.migrationKeystoneBuildSignBatchQrParts(
            requestId: requestId,
            pczts: pczts,
            maxFragmentLen: maxFragmentLen
        )
    }

    /// See ``Synchronizer/resetKeystoneSignBatchDecoder()`` for the contract.
    public func resetKeystoneSignBatchDecoder() async {
        await initializer.rustBackend.migrationKeystoneResetSignBatchDecoder()
    }

    /// See ``Synchronizer/decodeKeystoneSignBatchPart(_:expectedRequestId:)`` for the contract.
    public func decodeKeystoneSignBatchPart(_ part: String, expectedRequestId: Data) async throws -> KeystoneBatchDecodeResult {
        try await initializer.rustBackend.migrationKeystoneDecodeSignBatchPart(part, expectedRequestId: expectedRequestId)
    }

    /// See ``Synchronizer/applyKeystoneBatchSignatures(pczts:batchSignResponse:)`` for the contract.
    public func applyKeystoneBatchSignatures(
        pczts: [MigrationUnsignedTransferPczt],
        batchSignResponse: Data
    ) async throws -> [MigrationSignedTransferPczt] {
        try await initializer.rustBackend.migrationKeystoneApplyBatchSignatures(pczts: pczts, batchSignResponse: batchSignResponse)
    }

    /// Throws ``ZcashError/migrationBroadcastDuringSync`` when the synchronizer is actively syncing.
    ///
    /// Guards the two migration entry points that broadcast (``submitNoteSplit(accountUUID:proposal:usk:options:)``
    /// and ``performMigrationBroadcast(accountUUID:_:options:)``): sync and migration
    /// broadcasts must never share a session. Reads `latestState.internalSyncStatus` -- the same
    /// nonisolated status surface `start(retry:)`'s unprepared guard reads -- so the guard triggers on
    /// the syncing case only; unprepared/stopped/synced/disconnected/error all proceed. Advisory,
    /// point-in-time enforcement, not a hard mutual-exclusion lock: hosts still sequence sync and
    /// migration-broadcast sessions themselves.
    private func throwIfSyncingForMigrationBroadcast() throws {
        if case .syncing = latestState.internalSyncStatus {
            throw ZcashError.migrationBroadcastDuringSync
        }
    }

    // ── Server switch ─────────────────────────────────────────────────────────

    /// Switches the synchronizer to `endpoint` by re-opening the engine handle.
    ///
    /// Sequence:
    /// 1. F2: No-op immediately if `endpoint` equals `currentEndpoint` (same host + port + secure).
    ///    Prevents AutoServerSelection from restarting a sync pass when the benchmark selects the
    ///    same server already in use.
    /// 2. Snapshot whether the sync was running (to decide whether to restart).
    /// 3. F3: If a sync is active, log a warning — the pass will restart from the current scan
    ///    queue position (no data loss, but a brief latency cost until the engine reconnects).
    /// 4. Stop polling + await `engine.stop()` — cancel any in-flight sync task.
    /// 5. `engine.reopen(server:network:)` — close old handle + open new one bound
    ///    to the new endpoint (frees Rust-side tokio runtime, then allocates a fresh one).
    /// 6. Store `endpoint` in `currentEndpoint`.
    /// 7. If the engine was running before the switch, restart via `start(retry: false)`.
    public func switchTo(endpoint: LightWalletEndpoint) async throws {
        // [MOB-1850] One lifecycle operation, the no-op check included: `currentEndpoint` is what
        // the check reads and what a queued switch ahead of this one may be about to change, so the
        // comparison belongs in this operation's own turn rather than before it.
        try await lifecycle.enqueueThrowing {
            try await self.switchToOnLifecycleQueue(endpoint: endpoint)
        }.value
    }

    /// The queued body of `switchTo(endpoint:)`.
    private func switchToOnLifecycleQueue(endpoint: LightWalletEndpoint) async throws {
        // F2: No-op on identical endpoint — avoids an unnecessary restart. Same-server rule:
        // host, port and TLS flag must all match (`isSameServer`). [MOB-1850] Checked BEFORE the
        // generation bump: a switch that turns out to be a no-op changes nothing about who owns the
        // engine, so it must not retire the running pass's in-flight tick.
        if endpoint.isSameServer(as: currentEndpoint) {
            initializer.logger.debug(
                "switchTo: endpoint unchanged (\(endpoint.host):\(endpoint.port)) — no-op",
                file: #file, function: #function, line: #line
            )
            return
        }

        // [MOB-1850] A real switch: it owns the engine from here, so it retires the ticks decided
        // for the pass it is replacing — including any stall recovery those ticks asked for.
        passGeneration += 1
        let wasRunning = passIntendedRunning

        // F3: Warn when a switch fires while sync is active — the pass will restart.
        // This is not an error: the scan queue is durable and resumes after reopen.
        // The warning surfaces in device logs so we can correlate slow-progress reports
        // with mid-sync server switches (H-B investigation).
        if wasRunning {
            initializer.logger.warn(
                "switchTo during active sync — pass will restart (old: \(currentEndpoint.host):\(currentEndpoint.port), new: \(endpoint.host):\(endpoint.port))",
                file: #file, function: #function, line: #line
            )
        }

        // Stop poll loop and cancel in-flight sync (also cancels in-flight summary task).
        // [MOB-1850] The `passGeneration` bump at the top of this turn is what retires a recovery
        // decided for the pass being replaced: it would otherwise interleave a second reopen
        // against the OLD endpoint with this one.
        stopPolling()
        isRunning = false
        await engine.stop()

        // Re-open the engine handle against the new endpoint.
        try await engine.reopen(server: endpoint, network: initializer.network)

        // Record the new endpoint.
        currentEndpoint = endpoint

        // Also reset the tx-set-version mirror: the new handle's counter starts from zero.
        lastTxSetVersion = 0
        lastRevealRecovering = false
        // B4: re-arm the stall watchdog for the new handle.
        resetStallWatchdog()

        // Restart if the engine was previously running.
        if wasRunning {
            try await startImpl(retry: false, resetRecoveryBudget: true)
        }
    }

    // ── Bounded rebuild (restartSync) ───────────────────────────────────────────

    /// [MOB-1850] Rebuilds the engine at `endpoint` and starts a pass regardless of whether one was
    /// running. See `Synchronizer.restartSync(at:)`'s doc for when a host calls this.
    public func restartSync(at endpoint: LightWalletEndpoint) async throws {
        try await lifecycle.enqueueThrowing {
            try await self.restartSyncImpl(at: endpoint)
        }.value
    }

    /// The queued body of `restartSync(at:)`. `switchToOnLifecycleQueue`'s sibling: the same
    /// teardown/reopen/reset shape, but with neither of that operation's two conditions —
    /// `restartSync` is called precisely because the ordinary paths declined to rebuild: there is no
    /// same-endpoint no-op (the point is to rebuild a handle a failed reopen may have left closed,
    /// even at the endpoint already in use), and it starts unconditionally rather than only when
    /// `wasRunning` (the host calls this after a stall recovery gave up and stopped the pass, so
    /// nothing IS running by the time this runs).
    private func restartSyncImpl(at endpoint: LightWalletEndpoint) async throws {
        guard latestState.internalSyncStatus.isPrepared else {
            throw ZcashError.synchronizerNotPrepared
        }
        // [MOB-1850] Past the guard, so this really is taking the pass over: retire every tick
        // decided for whatever the engine was doing before (a live pass, or the aftermath of a
        // recovery that already gave up).
        passGeneration += 1
        stopPolling()
        isRunning = false
        await engine.stop()

        try await engine.reopen(server: endpoint, network: initializer.network)
        currentEndpoint = endpoint

        // The new handle's engine-side counters start at zero, so the emission mirrors must too —
        // same reasoning as `switchToOnLifecycleQueue` and the recovery restart.
        lastTxSetVersion = 0
        lastRevealRecovering = false
        resetStallWatchdog(resetRecoveryBudget: true)

        // `startImpl`, not the public `start()`: this operation is holding the queue, and a queued
        // call would wait for itself. Unconditional — unlike `switchToOnLifecycleQueue`'s
        // `if wasRunning`, this is the one lifecycle operation that starts a pass regardless of
        // whether one was running, which is the whole point of a "restart after nothing is left
        // running" API.
        try await startImpl(retry: false, resetRecoveryBudget: true)
    }

    /// [v0.7 P1b] Replaces the alternate-server list at runtime — the host calls this
    /// when the user's server-selection consent changes (e.g. Automatic ⇄ Manual).
    /// A non-empty list arms per-pass probe-then-commit + wire failover; an EMPTY list
    /// revokes it (probe skipped, failover disarmed — the configured endpoint is used
    /// exclusively, exact single-server behavior). Takes effect from the NEXT sync
    /// pass; an in-flight pass keeps the config it started with.
    public func setAlternateEndpoints(_ endpoints: [LightWalletEndpoint]) async {
        await engine.setAlternates(endpoints)
    }

    // ── Seed check ────────────────────────────────────────────────────────────

    public func isSeedRelevantToAnyDerivedAccount(seed: [UInt8]) async throws -> Bool {
        try await initializer.rustBackend.isSeedRelevantToAnyDerivedAccount(seed: seed)
    }

    // ── Server evaluation ─────────────────────────────────────────────────────

    /// Bounds every server-benchmark probe (`probe(_:timeoutSeconds:using:)`) so a slow or
    /// unreachable candidate cannot hold up `evaluateBestOf` / `evaluateServerSwitch` past this
    /// many seconds — the endpoint's own gRPC single-call default is a much longer 30 s, which
    /// is fine for a real request but far too slow for a benchmark that must return promptly.
    /// Matches the app-side `evaluationTimeoutSeconds`. `internal` so tests can reference it.
    static let serverProbeTimeoutSeconds: Double = 5

    public func evaluateBestOf(
        endpoints: [LightWalletEndpoint],
        fetchThresholdSeconds: Double = 60.0,
        nBlocksToFetch: UInt64 = 100,
        kServers: Int = 3,
        network: NetworkType = .mainnet
    ) async -> [LightWalletEndpoint] {
        let measured = await measureEndpoints(endpoints: endpoints, network: network)
        return measured
            .prefix(kServers)
            .map { $0.endpoint }
    }

    /// Slipstream benchmarks by a single `getInfo` round trip per candidate —
    /// `fetchThresholdSeconds` and `nBlocksToFetch` are accepted for protocol conformance but
    /// unused, because this conformer has no block-fetch phase.
    public func evaluateServerSwitch(
        current: LightWalletEndpoint,
        candidates: [LightWalletEndpoint],
        fetchThresholdSeconds _: Double,
        nBlocksToFetch _: UInt64,
        network: NetworkType
    ) async -> LightWalletEndpoint? {
        await ServerSwitchDecision.evaluate(
            current: current,
            candidates: candidates,
            thresholds: .roundTrip,
            logger: initializer.logger
        ) { endpoints in
            await self.measureEndpoints(endpoints: endpoints, network: network)
        }
    }

    /// Measures one candidate's `getInfo` round trip, bounded to `timeoutSeconds` so a slow or
    /// unreachable server cannot hold up the benchmark it is part of. Returns `nil` on timeout
    /// or any error — the caller ranks only the survivors. Closes `service`'s connections on
    /// every path: a bounded probe that leaked its ephemeral gRPC connection on timeout would
    /// defeat the point of bounding it. `internal` so tests can exercise it directly.
    static func probe(
        _ endpoint: LightWalletEndpoint,
        timeoutSeconds: Double,
        using service: LightWalletService
    ) async -> (roundTrip: TimeInterval, info: LightWalletdInfo)? {
        let start = DispatchTime.now()
        let info = try? await withTaskTimeout(UInt64(timeoutSeconds * 1_000_000_000)) {
            try await service.getInfo(mode: .direct)
        }
        let elapsed = DispatchTime.now().secondsSince(start)
        await service.closeConnections()
        guard let info else { return nil }
        return (roundTrip: elapsed, info: info)
    }

    /// Ranks `endpoints` by `getInfo` round-trip time, ascending (best first), applying the
    /// same health checks as `SDKSynchronizer`'s benchmark: chain name, consensus branch id,
    /// and the loose synced-height check — all skipped for custom networks, mirroring
    /// `ValidateServerAction`. Delegates to ephemeral gRPC connections.
    // TODO: [#1755] Hook into Tor when torEnabled; for now direct mode is used.
    private func measureEndpoints(
        endpoints: [LightWalletEndpoint],
        network: NetworkType
    ) async -> [ServerSwitchDecision.MeasuredEndpoint] {
        var results: [ServerSwitchDecision.MeasuredEndpoint] = []

        await withTaskGroup(of: (LightWalletEndpoint, TimeInterval, LightWalletdInfo)?.self) { group in
            for endpoint in endpoints {
                group.addTask {
                    let service = LightWalletGRPCService(endpoint: endpoint)
                    guard let probed = await Self.probe(endpoint, timeoutSeconds: Self.serverProbeTimeoutSeconds, using: service) else {
                        return nil
                    }
                    return (endpoint, probed.roundTrip, probed.info)
                }
            }

            let isCustomNetwork = initializer.network.customActivationHeights != nil

            for await result in group {
                guard let (endpoint, elapsed, info) = result, elapsed > 0 else { continue }

                if !isCustomNetwork {
                    guard (info.chainName == "main" && network == .mainnet)
                        || (info.chainName == "test" && network == .testnet)
                        || (info.chainName == "regtest" && network == .regtest) else {
                        continue
                    }

                    guard
                        let localBranchID = try? initializer.rustBackend.consensusBranchIdFor(
                            height: Int32(info.blockHeight)
                        ),
                        let remoteBranchID = ConsensusBranchID.fromString(info.consensusBranchID),
                        remoteBranchID == localBranchID
                    else {
                        continue
                    }
                }

                // Rule out servers that are syncing, stuck, or probably on the wrong fork.
                // Deliberately loose — `info.estimatedHeight` may be quite inaccurate.
                guard info.blockHeight + ZcashSDK.syncedThresholdBlocks >= info.estimatedHeight else {
                    continue
                }

                results.append(ServerSwitchDecision.MeasuredEndpoint(endpoint: endpoint, score: elapsed))
            }
        }

        return results.sorted { $0.score < $1.score }
    }

    // ── Birthday / timestamp ──────────────────────────────────────────────────

    public nonisolated func estimateBirthdayHeight(for date: Date) -> BlockHeight {
        initializer.container.resolve(CheckpointSource.self).estimateBirthdayHeight(for: date)
    }

    public nonisolated func estimateTimestamp(for height: BlockHeight) -> TimeInterval? {
        initializer.container.resolve(CheckpointSource.self).estimateTimestamp(for: height)
    }

    // ── Tor ───────────────────────────────────────────────────────────────────

    public func tor(enabled: Bool) async throws {
        let sdkFlags = initializer.container.resolve(SDKFlags.self)
        let torClient = initializer.container.resolve(TorClient.self)
        if enabled {
            try await torClient.prepare()
        } else {
            try await torClient.close()
        }
        await sdkFlags.torFlagUpdate(enabled)
    }

    public func exchangeRateOverTor(enabled: Bool) async throws {
        let sdkFlags = initializer.container.resolve(SDKFlags.self)
        let torClient = initializer.container.resolve(TorClient.self)
        if enabled {
            try await torClient.prepare()
        } else {
            // Only close if plain Tor is also disabled.
            let torEnabled = await sdkFlags.torEnabled
            if !torEnabled {
                try await torClient.close()
            }
        }
        await sdkFlags.exchangeRateFlagUpdate(enabled)
    }

    public func isTorSuccessfullyInitialized() async -> Bool? {
        let sdkFlags = initializer.container.resolve(SDKFlags.self)
        return await sdkFlags.torClientInitializationSuccessfullyDone
    }

    public func httpRequestOverTor(for request: URLRequest, retryLimit: UInt8) async throws -> (data: Data, response: HTTPURLResponse) {
        let sdkFlags = initializer.container.resolve(SDKFlags.self)
        let torEnabled = await sdkFlags.torEnabled
        let exchangeRateEnabled = await sdkFlags.exchangeRateEnabled
        guard torEnabled || exchangeRateEnabled else {
            throw ZcashError.torNotEnabled
        }
        let torClient = initializer.container.resolve(TorClient.self)
        return try await torClient.isolatedClient().httpRequest(for: request, retryLimit: retryLimit)
    }

    // ── Transparent / UTXO helpers ────────────────────────────────────────────

    // [G1, docs/slipstream/2026-07-08-grpc-privacy-map.md] These helpers send
    // wallet-identifying data (transparent addresses, UTXO queries) — with Tor
    // enabled they MUST ride isolated circuits, exactly like the old
    // SDKSynchronizer. The thin-host port hardcoded `.direct` here; restored
    // to `ifTor(.uniqueTor)` old-SDK parity 2026-07-08.

    public func checkSingleUseTransparentAddresses(accountUUID: AccountUUID) async throws -> TransparentAddressCheckResult {
        let dbData = initializer.dataDbURL.osStr()
        let sdkFlags = initializer.container.resolve(SDKFlags.self)
        return try await initializer.lightWalletService.checkSingleUseTransparentAddresses(
            dbData: dbData,
            networkType: initializer.network.networkType,
            accountUUID: accountUUID,
            mode: await sdkFlags.ifTor(.uniqueTor)
        )
    }

    public func updateTransparentAddressTransactions(address: String) async throws -> TransparentAddressCheckResult {
        let dbData = initializer.dataDbURL.osStr()
        let sdkFlags = initializer.container.resolve(SDKFlags.self)
        return try await initializer.lightWalletService.updateTransparentAddressTransactions(
            address: address,
            start: 0,
            end: -1,
            dbData: dbData,
            networkType: initializer.network.networkType,
            mode: await sdkFlags.ifTor(.uniqueTor)
        )
    }

    public func fetchUTXOsBy(address: String, accountUUID: AccountUUID) async throws -> TransparentAddressCheckResult {
        let dbData = initializer.dataDbURL.osStr()
        let sdkFlags = initializer.container.resolve(SDKFlags.self)
        return try await initializer.lightWalletService.fetchUTXOsByAddress(
            address: address,
            dbData: dbData,
            networkType: initializer.network.networkType,
            accountUUID: accountUUID,
            mode: await sdkFlags.ifTor(.uniqueTor)
        )
    }

    // ── Tree state ────────────────────────────────────────────────────────────

    public func getTreeState(height: UInt64) async throws -> Data {
        let sdkFlags = initializer.container.resolve(SDKFlags.self)
        let treeState = try await initializer.lightWalletService.getTreeState(
            BlockID(height: height),
            mode: await sdkFlags.ifTor(.uniqueTor)
        )
        return try treeState.serializedData()
    }

    // ── Database debug ────────────────────────────────────────────────────────

    public nonisolated func debugDatabase(sql: String) -> String {
        transactionRepository.debugDatabase(sql: sql)
    }

}

// MARK: - Private helpers

private extension SlipstreamSynchronizer {
    func allSentTransactions() async throws -> [ZcashTransaction.Overview] {
        try await enhanceWithState(transactionRepository.findSent(offset: 0, limit: Int.max))
    }

    func allReceivedTransactions() async throws -> [ZcashTransaction.Overview] {
        try await enhanceWithState(transactionRepository.findReceived(offset: 0, limit: Int.max))
    }


    // [#1755] Mirrors SDKSynchronizer.submitTransactions after zcash #1757 (multiserver
    // submission): consumes [CreatedTransaction] (was [ZcashTransaction.Overview]) and adopts the
    // "trust the network over the submit-side error" recovery branch. Submission is shared SDK
    // logic — slipstream only owns the sync path — so this stays byte-for-byte the SDK behaviour.
    func submitTransactions(_ transactions: [CreatedTransaction]) -> AsyncThrowingStream<TransactionSubmitResult, Error> {
        var iterator = transactions.makeIterator()
        var submitFailed = false

        return AsyncThrowingStream(unfolding: {
            guard let transaction = iterator.next() else { return nil }

            if submitFailed {
                return .notAttempted(txId: transaction.txId)
            } else {
                do {
                    try await self.transactionEncoder.submit(transaction: transaction.encodedTransaction)
                    // [Engine API v2 §4.5 / E-4] Surface the just-broadcast tx: poke the engine
                    // (`notify_tx_change`), which bumps the snapshot's `txSetVersion` (+ a tag-5
                    // ring event for ring consumers) — the poll loop's version compare re-fetches
                    // and emits on the next tick (≤ the poll cadence). One path for every host.
                    // Fire-and-forget; never delays the submit stream.
                    Task { await self.engine.notifyTxChange() }
                    return TransactionSubmitResult.success(txId: transaction.txId)
                } catch ZcashError.serviceSubmitFailed(let error) {
                    submitFailed = true
                    return TransactionSubmitResult.grpcFailure(txId: transaction.txId, error: error)
                } catch TransactionEncoderError.submitError(let code, let message) {
                    // If the server already has this tx, the broadcast landed — treat as success.
                    if await self.transactionEncoder.isTransactionKnownToServer(txId: transaction.txId) {
                        return TransactionSubmitResult.success(txId: transaction.txId)
                    }
                    submitFailed = true
                    return TransactionSubmitResult.submitFailure(txId: transaction.txId, code: code, description: message)
                }
            }
        })
    }
}
