//
//  SlipstreamLifecycleOwnershipTests.swift
//  ZcashLightClientKitTests
//

import Combine
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

/// [MOB-1850] Who owns the engine, and for how long.
///
/// Two problems meet here. First, a poll tick decides things — that the pass has stalled,
/// what state to publish, whether to re-fetch transactions — and then suspends inside an engine
/// call. By the time it resumes, the pass it decided for may be gone: the app stopped the
/// synchronizer, a server switch replaced the handle, a wipe deleted the wallet. Acting on a
/// decision taken for a pass that no longer exists is how a deliberately stopped synchronizer came
/// back to life. Second, the stall recovery tears the engine down and brings it back up, and while
/// it was an unstructured task racing every other lifecycle path, it could tear down a pass a
/// switch had just started, or start the engine in the middle of an account mutation's stopped
/// interval — the interval that exists precisely because no pass may run across the mutation.
///
/// The fix has two halves, and this suite exercises both:
///
/// - Every pass-owning lifecycle operation (start, stop, switch, import, delete, rewind, wipe, and
///   the recovery restart) runs on one FIFO queue, so two of them can never interleave.
/// - A tick carries a run identity (`passGeneration` + `pollGeneration`) that it re-validates after
///   every suspension, so a stale tick returns having done nothing at all.
final class SlipstreamLifecycleOwnershipTests: ZcashTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() async throws {
        cancellables.removeAll()
        try await super.tearDown()
    }

    // MARK: - Stale tick cannot resurrect a stopped sync

    /// A tick that observed a stall, then suspended while a deliberate stop ran, must not schedule
    /// a recovery or emit `.syncStalled` when it resumes.
    ///
    /// This is the field failure the audit named: the user backgrounds the wallet, `stop()` lands,
    /// and a tick that was already inside `engine.snapshot()` wakes up holding a stall verdict for
    /// the pass that has just been torn down. It then restarts that pass — reopening the handle and
    /// starting a sync the app explicitly asked to end. The stop generation the old code compared
    /// could not catch it, because the tick captured the generation AFTER the stop had bumped it.
    func testStaleTickAfterStopSchedulesNoRecoveryAndEmitsNothing() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100, stalledSeconds: 400))
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        let events = RecordedEvents()
        sync.eventStream.sink { events.append($0) }.store(in: &cancellables)

        try await sync.start(retry: false)
        try await holdNextSnapshot(of: engine, description: "a tick is held inside snapshot")

        // Only NOW is the pass made to look stalled, and the ordering is the whole point: the tick
        // that will read this verdict is already suspended, so the verdict belongs to a pass that is
        // about to be stopped and to nothing else. Seeding before the hold would let an earlier,
        // perfectly current tick decide a recovery of its own — a legitimate one, which is what
        // `testCurrentPassStallStillRecovers` covers.
        //
        // The stall predicate clamps the engine-reported span to the CURRENT handle's lifetime
        // (`effectiveStallSeconds`), so a stalled snapshot alone proves nothing on a handle opened a
        // millisecond ago. Both halves are needed: the snapshot above carries the engine's span,
        // this seam backdates the handle so the clamp lets it through.
        await sync.seedStallClockForTesting(secondsAgo: 400)

        sync.stop()
        let stopped = await waitUntil { await engine.calls.contains("stop") }
        XCTAssertTrue(stopped, "the deliberate stop reached the engine while the tick was suspended")

        engine.snapshotGate.open()

        // A NEGATIVE claim — that the resumed tick does nothing — so real time has to pass. There is
        // no observable to wait on, because the whole assertion is that none is produced.
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(
            events.syncStalledEvents.isEmpty,
            "a tick whose pass was stopped must not announce a stall for it: \(events.syncStalledEvents)"
        )
        let calls = await engine.calls
        XCTAssertEqual(calls.filter { $0.hasPrefix("reopen(") }.count, 0, "and must not reopen the handle")
        XCTAssertEqual(calls.filter { $0 == "start" }.count, 1, "no recovery start after a deliberate stop")
        XCTAssertEqual(sync.latestState.internalSyncStatus, .stopped, "the synchronizer stays stopped")
    }

    /// The positive control for the test above: with nothing stopping it, a genuine stall on the
    /// CURRENT pass still recovers. The run-identity check has to reject stale ticks without
    /// rejecting live ones, and a guard that rejected everything would pass the test above.
    func testCurrentPassStallStillRecovers() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100, stalledSeconds: 400))
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        let events = RecordedEvents()
        sync.eventStream.sink { events.append($0) }.store(in: &cancellables)

        try await sync.start(retry: false)
        await sync.seedStallClockForTesting(secondsAgo: 400)

        let recovered = await waitUntil { await engine.calls.contains { $0.hasPrefix("reopen(") } }
        XCTAssertTrue(recovered, "a stalled current pass is restarted")

        let restarted = await waitUntil { await engine.calls.filter { $0 == "start" }.count == 2 }
        XCTAssertTrue(restarted, "and the restart brings a pass back up")
        XCTAssertEqual(
            events.syncStalledEvents,
            [SyncStalledReport(attempt: 1, gaveUp: false)],
            "the host is told once, naming the attempt"
        )
        let syncingAgain = await waitUntil { sync.latestState.internalSyncStatus.isSyncing }
        XCTAssertTrue(syncingAgain, "and the wallet is syncing again")

        // The restart re-stamps the handle-lifetime baseline, so the same stalled snapshot cannot
        // fire a second recovery: a NEGATIVE claim, hence the elapsed interval.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let reopens = await engine.calls.filter { $0.hasPrefix("reopen(") }.count
        XCTAssertEqual(reopens, 1, "the fresh handle's clock is its own; one stall, one recovery")

        sync.stop()
    }

    // MARK: - Recovery respects the pass that scheduled it

    /// A recovery decided before a server switch must not touch the engine at all once the switch
    /// has taken over.
    ///
    /// The old restart tore the engine down FIRST and only then compared generations, so a stale
    /// recovery stopped the pass the switch had just brought up on the new server — and then
    /// abandoned, leaving the wallet with no pass and a `.syncing` status that was a lie. Validation
    /// now happens before any side effect.
    func testStaleRecoveryAfterSwitchPerformsNoTeardown() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        let events = RecordedEvents()
        sync.eventStream.sink { events.append($0) }.store(in: &cancellables)

        try await sync.start(retry: false)

        // What a tick would have captured just before the switch.
        let generation = await sync.passGenerationForTesting()
        let stopRequest = await sync.stopRequestGenerationForTesting()

        let other = LightWalletEndpoint(address: "other.example.com", port: 443, secure: true)
        try await sync.switchTo(endpoint: other)
        let callsAfterSwitch = await Self.lifecycleCalls(engine.calls)

        await sync.runStallRecovery(
            expectedPassGeneration: generation,
            expectedStopRequestGeneration: stopRequest,
            attempt: 1
        )

        let callsAfterTheStaleRecovery = await Self.lifecycleCalls(engine.calls)
        XCTAssertEqual(callsAfterTheStaleRecovery, callsAfterSwitch, "a stale recovery must not call the engine at all")
        XCTAssertTrue(events.syncStalledEvents.isEmpty, "nor announce a stall it is not going to act on")
        XCTAssertTrue(sync.latestState.internalSyncStatus.isSyncing, "the switched pass is untouched")

        // And it is still ALIVE, not merely last-reported-as-syncing: the poll loop the stale
        // recovery would have cancelled keeps ticking. A positive claim, so it waits on the engine.
        let snapshotsSoFar = await engine.calls.filter { $0 == "snapshot" }.count
        let stillPolling = await waitUntil(timeout: 6) {
            await engine.calls.filter { $0 == "snapshot" }.count > snapshotsSoFar
        }
        XCTAssertTrue(stillPolling, "the switched pass keeps polling")

        sync.stop()
    }

    /// An account mutation's stopped interval cannot be entered by a recovery.
    ///
    /// `deleteAccount` stops the engine, mutates the wallet and restarts: the stop exists because a
    /// pass that scans across the mutation writes notes for an account that is being deleted, which
    /// is a non-transient pass error. A recovery that was already inside `engine.start()` when the
    /// mutation began used to complete that start INSIDE the interval — the engine came up on a
    /// wallet mid-delete. Serialising the two on one queue is what makes the interval real.
    ///
    /// The assertion is precisely that: at no point in the recorded trace does a teardown begin
    /// while an engine `start` is still in flight. (`deleteAccount` stands in for `importAccount`,
    /// which has the identical stop-mutate-restart shape but reaches the FFI's `restore_anchor`
    /// first — a real network call, and so not something an offline test may depend on.)
    func testStallRecoveryCannotStartTheEngineInsideAnAccountMutationsStoppedInterval() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let welding = ZcashRustBackendWeldingMock()
        welding.deleteAccountClosure = { _ in }
        let sync = try makeSlipstreamSynchronizer(engine: engine, welding: welding)
        await sync.setInternalSyncStatusForTesting(.disconnected)

        try await sync.start(retry: false)
        let generation = await sync.passGenerationForTesting()
        let stopRequest = await sync.stopRequestGenerationForTesting()

        // Park the recovery inside `engine.start()`, the window in which the old code let a
        // mutation open its stopped interval underneath a pass that was still coming up.
        await engine.closeGate(.start)
        await sync.requestStallRecovery(
            observedPassGeneration: generation,
            observedStopRequestGeneration: stopRequest,
            attempt: 1
        )
        let recoveryIsStarting = await waitUntil { await engine.calls.filter { $0 == "start" }.count == 2 }
        XCTAssertTrue(recoveryIsStarting, "the recovery reached its restart and is held there")

        let stopsBeforeTheDelete = await engine.calls.filter { $0 == "stop" }.count
        let delete = Task { try await sync.deleteAccount(TestsData.mockedAccountUUID) }

        // A NEGATIVE claim — the mutation has not begun, because the recovery still holds the
        // queue — so it is made by letting real time pass.
        try await Task.sleep(nanoseconds: 300_000_000)
        let stopsWhileHeld = await engine.calls.filter { $0 == "stop" }.count
        XCTAssertEqual(stopsWhileHeld, stopsBeforeTheDelete, "the delete waits for the recovery to finish")

        await engine.openGate(.start)
        try await delete.value

        let calls = await engine.calls
        XCTAssertNil(
            Self.firstTeardownWhileAStartIsInFlight(calls),
            "a teardown began while an engine start was still in flight: \(calls)"
        )
        XCTAssertEqual(calls.filter { $0 == "start" }.count, 3, "the app's pass, the recovery's, and the delete's")
        // And the wallet ends with a pass UP: the last completed start is later than the last
        // teardown. (`calls.last` would be whatever poll chatter arrived most recently.)
        let lastStartDone = try XCTUnwrap(calls.lastIndex(of: "start:done"))
        let lastStop = try XCTUnwrap(calls.lastIndex(of: "stop"))
        XCTAssertGreaterThan(lastStartDone, lastStop, "the mutation's own pass is the one left running: \(calls)")

        sync.stop()
    }

    // MARK: - A deliberate stop, and a wipe, stay authoritative

    /// A `stop()` asked for while a recovery is bringing a pass up runs after it and stops that
    /// pass — once.
    ///
    /// The queue is what makes "once" true. While the recovery was an unstructured task, the stop
    /// ran concurrently with the restart: it stopped an engine the restart then started anyway, and
    /// the restart's own post-start re-check had to stop it a second time. The wallet ended stopped
    /// either way, but through a pass that briefly ran after the user had asked for silence.
    func testStopDuringRecoveryEndsStopped() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)

        try await sync.start(retry: false)
        let generation = await sync.passGenerationForTesting()
        let stopRequest = await sync.stopRequestGenerationForTesting()

        await engine.closeGate(.start)
        await sync.requestStallRecovery(
            observedPassGeneration: generation,
            observedStopRequestGeneration: stopRequest,
            attempt: 1
        )
        let parked = await waitUntil { await engine.calls.filter { $0 == "start" }.count == 2 }
        XCTAssertTrue(parked, "the recovery is held inside its restart")
        let recoveryStartIndex = await engine.calls.lastIndex(of: "start")

        sync.stop()
        await engine.openGate(.start)

        let ended = await waitUntil { sync.latestState.internalSyncStatus == .stopped }
        XCTAssertTrue(ended, "a deliberate stop outlives the recovery it landed on")

        let calls = await engine.calls
        let index = try XCTUnwrap(recoveryStartIndex)
        let stopsAfterTheRestart = calls[index...].filter { $0 == "stop" }.count
        XCTAssertEqual(stopsAfterTheRestart, 1, "and stops the restarted pass exactly once: \(calls)")

        // Nothing re-starts behind the stop: a NEGATIVE claim, so it costs real time.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(sync.latestState.internalSyncStatus, .stopped)
        let startsAfterTheStop = await engine.calls.filter { $0 == "start" }.count
        XCTAssertEqual(startsAfterTheStop, 2, "no third pass was started")
    }

    /// A wipe that holds the lifecycle queue leaves the wallet `.unprepared`, and the recovery that
    /// was requested behind it abandons in silence — no `.syncStalled`, no `.error`.
    ///
    /// Silence is the contract: an abandoned recovery has not given up (nobody is retrying, because
    /// nothing is left to retry for), and announcing either a restart or a give-up would describe a
    /// synchronizer that no longer exists. The old code announced the restart from the poll tick,
    /// BEFORE the restart validated anything, so the announcement survived even when the restart
    /// itself was abandoned a moment later.
    func testWipeDuringRecoveryEndsUnpreparedWithoutErrorPublication() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        let events = RecordedEvents()
        sync.eventStream.sink { events.append($0) }.store(in: &cancellables)
        let statuses = RecordedSyncStatuses()
        sync.stateStream.sink { statuses.append($0.internalSyncStatus) }.store(in: &cancellables)

        try await sync.start(retry: false)
        let generation = await sync.passGenerationForTesting()
        let stopRequest = await sync.stopRequestGenerationForTesting()

        // Hold the wipe inside its `engine.stop()`, so it owns the queue while the recovery is
        // requested behind it.
        await engine.closeGate(.stop)
        let wiped = XCTestExpectation(description: "wipe completed")
        sync.wipe()
            .sink(receiveCompletion: { _ in wiped.fulfill() }, receiveValue: { _ in })
            .store(in: &cancellables)
        let wipeReachedTheEngine = await waitUntil { await engine.calls.contains("stop") }
        XCTAssertTrue(wipeReachedTheEngine, "the wipe is inside its teardown")

        await sync.requestStallRecovery(
            observedPassGeneration: generation,
            observedStopRequestGeneration: stopRequest,
            attempt: 1
        )

        await engine.openGate(.stop)
        await fulfillment(of: [wiped], timeout: 5)

        // A NEGATIVE claim about the abandoned recovery, so real time passes before it is made.
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(sync.latestState.internalSyncStatus, .unprepared, "the wipe's outcome stands")
        XCTAssertTrue(
            events.syncStalledEvents.isEmpty,
            "an abandoned recovery owes the host no stall report: \(events.syncStalledEvents)"
        )
        XCTAssertFalse(
            statuses.all.contains { if case .error = $0 { return true } else { return false } },
            "and must not forge an error onto a wiped wallet: \(statuses.all)"
        )
        let callsAfterTheWipe = await engine.calls
        XCTAssertFalse(callsAfterTheWipe.contains { $0.hasPrefix("reopen(") }, "no handle was reopened onto deleted files")
        XCTAssertEqual(callsAfterTheWipe.filter { $0 == "start" }.count, 1, "and no pass was started after the wipe")
    }

    // MARK: - restartSync(at:): the bounded rebuild after a terminal recovery failure

    /// The recovery path named in `restartSync(at:)`'s doc: a stall recovery's reopen fails, the
    /// handle is gone, and the host calls `restartSync` at the SAME endpoint to rebuild it and start
    /// a pass again.
    func testRestartSyncRebuildsANilHandleAtTheSameEndpointAndStarts() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let sync = try makeSlipstreamSynchronizer(engine: engine, container: mockContainer)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        try await sync.start(retry: false)

        // Simulate the terminal recovery failure: reopen fails, the handle is gone.
        await engine.setReopenError(ZcashError.rustSlipstreamOpen("boom"))
        await sync.runStallRecovery(
            expectedPassGeneration: await sync.passGenerationForTesting(),
            expectedStopRequestGeneration: await sync.stopRequestGenerationForTesting(),
            attempt: 1
        )
        let closedAfterFailedReopen = await engine.isOpen
        XCTAssertFalse(closedAfterFailedReopen, "the failed reopen left the handle closed")
        await engine.setReopenError(nil)

        let endpoint = await sync.currentEndpointForTesting()
        try await sync.restartSync(at: endpoint)

        let openAfterRestart = await engine.isOpen
        XCTAssertTrue(openAfterRestart, "restartSync rebuilds the handle")
        XCTAssertTrue(sync.latestState.internalSyncStatus.isSyncing, "and starts a pass")
        let calls = await engine.calls
        XCTAssertEqual(calls.filter { $0 == "start" }.count, 2, "the original start, then restartSync's own: \(calls)")

        sync.stop()
    }

    /// `restartSync(at:)` starts a pass even when nothing was running before it, and records the new
    /// endpoint — unlike `switchTo`, which only restarts a pass that was already up.
    func testRestartSyncAtAnotherEndpointStartsEvenWhenNothingWasRunning() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.stopped)

        let other = LightWalletEndpoint(address: "other.example.com", port: 443, secure: true)
        try await sync.restartSync(at: other)

        XCTAssertTrue(
            sync.latestState.internalSyncStatus.isSyncing,
            "restartSync starts a pass regardless of the prior status: \(sync.latestState.internalSyncStatus)"
        )
        let calls = await engine.calls
        XCTAssertTrue(calls.contains("reopen(other.example.com:443)"), "the handle is rebuilt at the new endpoint: \(calls)")
        let currentEndpoint = await sync.currentEndpointForTesting()
        XCTAssertEqual(currentEndpoint, other, "the new endpoint is recorded")

        sync.stop()
    }

    /// A `restartSync(at:)` that lands while a migration submission is in flight must propagate the
    /// same privacy gate `start(retry:)` enforces, and must not report a pass as syncing.
    func testRestartSyncPropagatesMigrationBlockedStart() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let welding = ZcashRustBackendWeldingMock()
        let blockedAccount = TestsData.mockedAccountUUID
        welding.listAccountsReturnValue = [
            Account(id: blockedAccount, name: nil, keySource: nil, seedFingerprint: nil, hdAccountIndex: nil, ufvk: nil, uivk: nil)
        ]
        let sync = try makeSlipstreamSynchronizer(engine: engine, welding: welding)
        await sync.setInternalSyncStatusForTesting(.disconnected)

        // Mark the account's migration broadcast as in flight, so the REAL `OrchardMigrationHost`
        // the synchronizer builds internally (wired to this `welding` and `generalStorageURL`)
        // reports `isSyncBlocked() == true` -- the same privacy gate `startImpl` consults.
        MigrationSyncGate(directory: testGeneralStorageDirectory, accountUUID: blockedAccount, logger: logger).markBroadcastInFlight()

        let other = LightWalletEndpoint(address: "other.example.com", port: 443, secure: true)
        do {
            try await sync.restartSync(at: other)
            XCTFail("expected restartSync to propagate the migration-blocked error")
        } catch ZcashError.migrationSyncBlocked {
            // expected
        }

        XCTAssertFalse(
            sync.latestState.internalSyncStatus.isSyncing,
            "a migration-blocked restart must not report a pass as syncing: \(sync.latestState.internalSyncStatus)"
        )
    }

    // MARK: - restartSync(at:): a caller cancelled while queued retires itself

    /// [MOB-1850] The field failure this closes: the app backgrounds while a terminal-recovery
    /// `restartSync(at:)` is still queued behind the stop the backgrounding itself triggered.
    /// `LifecycleQueue`'s tasks are unstructured and inherit no cancellation, so without help the
    /// restart would be admitted once the stop ahead of it finishes, and would reopen the engine
    /// and start a pass the app never asked for, behind its own stop.
    func testARestartWhoseCallerIsCancelledWhileQueuedNeverRunsAndLeavesTheEngineStopped() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        try await sync.start(retry: false)

        engine.stopGate.close() // the next stop parks inside the fake
        sync.stop() // the host's background stop holds the queue
        let stopped = await waitUntil { await engine.calls.contains("stop") }
        XCTAssertTrue(stopped, "the deliberate stop reached the engine and is held there")

        let endpoint = await sync.currentEndpointForTesting()
        let restart = Task { try await sync.restartSync(at: endpoint) }
        // Bounded, not observable: nothing in `calls` marks a restart that is queued but not yet
        // admitted, so this waits long enough for it to reach `enqueueThrowing` and suspend behind
        // the parked stop before it is cancelled.
        try await Task.sleep(nanoseconds: 50_000_000)
        restart.cancel()
        engine.stopGate.open()

        do {
            try await restart.value
            XCTFail("a restart whose caller was cancelled before it began must throw")
        } catch is CancellationError {
            // expected
        }

        let calls = await engine.calls
        let afterStop = calls.drop(while: { $0 != "stop" }).dropFirst()
        XCTAssertFalse(
            afterStop.contains(where: { $0.hasPrefix("reopen") }),
            "the retired restart must not reopen the engine: \(calls)"
        )
        XCTAssertFalse(afterStop.contains("start"), "the retired restart must not start a pass: \(calls)")
        let running = await sync.isRunningForTesting()
        XCTAssertFalse(running, "a retired restart leaves the synchronizer stopped")
    }

    /// The mirror image: a restart that has already begun executing — past the point cancellation
    /// can retire it — completes even though its caller is cancelled too late to matter, and a stop
    /// queued behind it still gets to run afterward and is the one left standing.
    func testAStopQueuedBehindARestartThatAlreadyBeganRemainsAuthoritative() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.stopped)

        engine.reopenGate.close() // the restart parks inside reopen once it has begun
        let endpoint = await sync.currentEndpointForTesting()
        let restart = Task { try await sync.restartSync(at: endpoint) }
        let reopening = await waitUntil { await engine.calls.contains(where: { $0.hasPrefix("reopen(") }) }
        XCTAssertTrue(reopening, "the restart has begun executing and is parked inside reopen")

        // Too late: the restart already passed the point where cancellation would have retired it.
        restart.cancel()
        sync.stop()
        engine.reopenGate.open()

        try await restart.value

        // isRunning retires the pass before the awaited engine stop finishes.
        // Observe the later stop's completion before inspecting its final trace.
        let settled = await waitUntil {
            let calls = await engine.calls
            return Self.lifecycleCalls(calls).last == "stop:done"
        }
        XCTAssertTrue(settled, "the stop queued behind the restart still runs")

        let calls = await engine.calls
        let lastStart = try XCTUnwrap(calls.lastIndex(of: "start"), "the restart's own start ran: \(calls)")
        let lastStop = try XCTUnwrap(calls.lastIndex(of: "stop"), "the later stop reached the engine: \(calls)")
        XCTAssertGreaterThan(
            lastStop,
            lastStart,
            "the stop queued behind the restart is the one left running: \(calls)"
        )
        let trace = Self.lifecycleCalls(calls)
        XCTAssertEqual(trace.last, "stop:done", "the later stop is the final lifecycle event: \(trace)")
        let running = await sync.isRunningForTesting()
        XCTAssertFalse(running, "the later stop remains authoritative")
    }

    // MARK: - Account mutations must not leave the poll loop alive across their stopped interval

    /// `deleteAccount`'s stopped interval must be genuinely silent. Before this hardening,
    /// `deleteAccountOnLifecycleQueue` left `isRunning == true` and the poll loop alive across its
    /// own teardown: a fresh tick spawned by that still-alive loop captures `passGeneration` FRESH
    /// (at the top of its own call), so the mutation's own generation bump does not retire it, and
    /// only `isRunning` stood between it and publishing state for an engine that is mid-delete.
    ///
    /// `deleteAccount` stands in for `importAccount`/`rewind`, which share the identical
    /// stop-mutate-restart shape (see `testStallRecoveryCannotStartTheEngineInsideAnAccountMutationsStoppedInterval`'s
    /// doc for why `deleteAccount` is the offline stand-in for `importAccount`).
    func testDeleteAccountsStoppedIntervalPublishesNoStrayState() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let welding = ZcashRustBackendWeldingMock()
        welding.deleteAccountClosure = { _ in }
        let sync = try makeSlipstreamSynchronizer(engine: engine, welding: welding)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        let statuses = RecordedSyncStatuses()
        sync.stateStream.sink { statuses.append($0.internalSyncStatus) }.store(in: &cancellables)

        try await sync.start(retry: false)
        // Establish that the poll loop is genuinely alive before the mutation begins.
        let firstTickSeen = await waitUntil { await engine.calls.filter { $0 == "snapshot" }.count >= 1 }
        XCTAssertTrue(firstTickSeen, "the poll loop must be running before the mutation starts")

        await engine.closeGate(.stop)
        let delete = Task { try await sync.deleteAccount(TestsData.mockedAccountUUID) }
        let stopped = await waitUntil { await engine.calls.contains("stop") }
        XCTAssertTrue(stopped, "the delete's turn reached its teardown and is held there")

        let emissionsAtHold = statuses.all.count

        // A NEGATIVE claim — that the held interval produces no emission — so real time has to
        // pass: long enough for a still-alive (pre-fix) poll loop to fire at least one more tick.
        try await Task.sleep(nanoseconds: 2_500_000_000)

        XCTAssertEqual(
            statuses.all.count,
            emissionsAtHold,
            "no state may be published while an account mutation holds the engine stopped: \(statuses.all)"
        )

        await engine.openGate(.stop)
        try await delete.value

        let restarted = await waitUntil { statuses.all.count > emissionsAtHold }
        XCTAssertTrue(restarted, "the mutation's own restart publishes state once it completes")
    }

    // MARK: - A mutation restarts the engine even when the mutation itself fails

    /// `deleteAccount` must not leave the engine dead when the FFI delete itself fails — mirroring
    /// `importAccountOnLifecycleQueue`'s catch-block restart and `rewindOnLifecycleQueue`'s
    /// restart-on-both-outcomes, which `deleteAccountOnLifecycleQueue` did not yet share: it
    /// restarted only after a successful delete, so a failed one left `isRunning` false and the
    /// engine stopped while the host still saw `.syncing`.
    func testDeleteAccountRestartsAfterAFailedDelete() async throws {
        struct DeleteFailure: Error {}
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let welding = ZcashRustBackendWeldingMock()
        welding.deleteAccountThrowableError = DeleteFailure()
        let sync = try makeSlipstreamSynchronizer(engine: engine, welding: welding)
        await sync.setInternalSyncStatusForTesting(.disconnected)

        try await sync.start(retry: false)

        do {
            try await sync.deleteAccount(TestsData.mockedAccountUUID)
            XCTFail("expected the delete's own FFI failure to propagate")
        } catch is DeleteFailure {
            // Expected: a failed delete must still be visible to its own caller.
        }

        let calls = await engine.calls
        let lastStop = try XCTUnwrap(calls.lastIndex(of: "stop"), "the failed delete still tore the engine down: \(calls)")
        let lastStartDone = try XCTUnwrap(calls.lastIndex(of: "start:done"), "a failed delete must not leave the engine dead: \(calls)")
        XCTAssertGreaterThan(lastStartDone, lastStop, "the restart after the failed delete is the one left running: \(calls)")

        let isRunning = await sync.isRunningForTesting()
        XCTAssertTrue(isRunning, "the restarted pass leaves the synchronizer running again")
    }

    /// A restart that fails after a mutation itself SUCCEEDED must not vanish silently: the
    /// mutation has nothing to throw its own caller, so the state stream is the only channel left —
    /// exactly the one `reportStallRecoveryStopped(error:)` already uses for a stall recovery's own
    /// restart failure. `deleteAccount` stands in for `importAccount`/`rewind`, whose success-path
    /// restarts share the same private `publishStoppedWithError(_:)` helper.
    func testDeleteAccountsRestartFailureAfterASuccessfulDeletePublishesErrorState() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let welding = ZcashRustBackendWeldingMock()
        welding.deleteAccountClosure = { _ in }
        let sync = try makeSlipstreamSynchronizer(engine: engine, welding: welding)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        let statuses = RecordedSyncStatuses()
        sync.stateStream.sink { statuses.append($0.internalSyncStatus) }.store(in: &cancellables)
        let events = RecordedEvents()
        sync.eventStream.sink { events.append($0) }.store(in: &cancellables)

        try await sync.start(retry: false)
        // Only the RESTART that follows the (successful) delete should fail — not the delete itself.
        await engine.setStartError(ZcashError.rustSlipstreamNotOpen)

        try await sync.deleteAccount(TestsData.mockedAccountUUID)

        let publishedError = await waitUntil {
            statuses.all.contains { if case .error = $0 { return true } else { return false } }
        }
        XCTAssertTrue(publishedError, "a restart failure after a successful mutation must reach the state stream: \(statuses.all)")
        XCTAssertTrue(
            events.syncStalledEvents.isEmpty,
            "the once-per-handle give-up credit belongs to stall recovery, not a mutation's own restart: \(events.syncStalledEvents)"
        )
    }

    // MARK: - wipe() clears isRunning like every other teardown

    /// `wipe()` must leave `isRunning` false, exactly like `stopImpl` and every account-mutation
    /// teardown already do. Before this fix, `wipeOnLifecycleQueue` was the one path that left it
    /// `true`, which `wasRunning` on a subsequent mutation would misread as a pass still owed a
    /// restart.
    func testWipeClearsIsRunning() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)

        try await sync.start(retry: false)
        let runningBeforeWipe = await sync.isRunningForTesting()
        XCTAssertTrue(runningBeforeWipe, "the pass is up before the wipe")

        let wiped = XCTestExpectation(description: "wipe completed")
        sync.wipe()
            .sink(receiveCompletion: { _ in wiped.fulfill() }, receiveValue: { _ in })
            .store(in: &cancellables)
        await fulfillment(of: [wiped], timeout: 5)

        let runningAfterWipe = await sync.isRunningForTesting()
        XCTAssertFalse(runningAfterWipe, "wipe must clear isRunning like every other teardown")
    }

    // MARK: - The failure half of a recovery

    /// A reopen that fails ends the recovery, and the give-up is reported exactly once.
    ///
    /// The restart calls `stopPolling()` first, so a failure leaves no tick to re-decide and no
    /// `.giveUp` branch that can ever fire: this report is the host's only resolution for the
    /// `.syncStalled(gaveUp: false)` it has just been handed. It is therefore NOT gated on the
    /// restart cap — a failure on attempt 1 silences the synchronizer exactly as thoroughly as one
    /// on attempt 3.
    func testFailedReopenReportsGiveUpOnce() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100, stalledSeconds: 400))
        await engine.setReopenError(ZcashError.rustSlipstreamNotOpen)
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)
        let events = RecordedEvents()
        sync.eventStream.sink { events.append($0) }.store(in: &cancellables)

        try await sync.start(retry: false)
        await sync.seedStallClockForTesting(secondsAgo: 400)

        let gaveUp = await waitUntil(timeout: 6) { events.syncStalledEvents.contains { $0.gaveUp } }
        XCTAssertTrue(gaveUp, "a recovery that cannot reopen the handle says so")

        // A NEGATIVE claim — that the give-up is not repeated — so real time passes.
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(
            events.syncStalledEvents,
            [SyncStalledReport(attempt: 1, gaveUp: false), SyncStalledReport(attempt: 1, gaveUp: true)],
            "one restart announcement, one give-up, both naming attempt 1"
        )
        guard case .error = sync.latestState.internalSyncStatus else {
            return XCTFail("a host watching only the state stream must see the failure: \(sync.latestState.internalSyncStatus)")
        }
        let calls = await engine.calls
        XCTAssertEqual(calls.filter { $0.hasPrefix("reopen(") }.count, 1, "the failed reopen spent its attempt and stopped")
        XCTAssertEqual(calls.filter { $0 == "start" }.count, 1, "no pass came up after it")
    }

    // MARK: - A non-quiescent stop refuses the operation stacked on top of it

    // The engine's stop drains its own wallet writer, bounded; when that budget runs out the FFI
    // now REPORTS it instead of logging it away, and every operation that was writing on the
    // strength of that stop refuses rather than proceeding. `deleteAccount` is the offline
    // stand-in for `importAccount` here for the reason the suite already relies on elsewhere:
    // `importAccount` fetches a restore anchor from a server before it reaches the lifecycle
    // queue, and the two share `importAccountOnLifecycleQueue`'s stop/mutate/restart shape
    // verbatim.

    /// A refused mutation leaves the wallet exactly as it found it — and leaves the pass running,
    /// because nothing about the wallet changed to justify stopping it.
    func testDeleteRefusesToMutateWhenTheStopWasNotQuiescent() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let welding = ZcashRustBackendWeldingMock()
        welding.deleteAccountClosure = { _ in }
        let sync = try makeSlipstreamSynchronizer(engine: engine, welding: welding)
        await sync.setInternalSyncStatusForTesting(.disconnected)

        try await sync.start(retry: false)
        engine.stopQuiescent = false

        do {
            try await sync.deleteAccount(TestsData.mockedAccountUUID)
            XCTFail("a non-quiescent stop must refuse the mutation")
        } catch let error as ZcashError {
            guard case .slipstreamEngineNotQuiescent = error else {
                return XCTFail("unexpected error \(error.code)")
            }
        }

        XCTAssertFalse(welding.deleteAccountCalled, "the wallet must not be mutated on top of a live writer")
        let calls = await engine.calls
        let lastStop = try XCTUnwrap(calls.lastIndex(of: "stop"), "the refusal still tore the pass down: \(calls)")
        let lastStartDone = try XCTUnwrap(calls.lastIndex(of: "start:done"), "the pass restarts because it was running: \(calls)")
        XCTAssertGreaterThan(lastStartDone, lastStop, "the restart after the refusal is the one left running: \(calls)")
        let isRunning = await sync.isRunningForTesting()
        XCTAssertTrue(isRunning, "a refused mutation leaves the synchronizer running, as it found it")
    }

    /// [MOB-1850] The refusal must not wear off. A stop whose budget ran out gave up waiting for a
    /// pass, but giving up is not the pass finishing, so the stop AFTER it faces the very same live
    /// writer and must refuse just as firmly. This is the shape that reached the field: the second
    /// attempt at a mutation the first attempt had refused went through, and the wallet was mutated
    /// under a pass that had never stopped writing.
    func testRepeatedNonQuiescentStopsKeepRefusingTheMutation() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let welding = ZcashRustBackendWeldingMock()
        welding.deleteAccountClosure = { _ in }
        let sync = try makeSlipstreamSynchronizer(engine: engine, welding: welding)
        await sync.setInternalSyncStatusForTesting(.disconnected)

        try await sync.start(retry: false)
        engine.stopQuiescent = false

        for attempt in 1...2 {
            do {
                try await sync.deleteAccount(TestsData.mockedAccountUUID)
                XCTFail("attempt \(attempt): a stop that stayed non-quiescent must refuse the mutation again")
            } catch let error as ZcashError {
                guard case .slipstreamEngineNotQuiescent = error else {
                    return XCTFail("attempt \(attempt): unexpected error \(error.code)")
                }
            }

            XCTAssertFalse(
                welding.deleteAccountCalled,
                "attempt \(attempt): the wallet must not be mutated on top of a writer that never finished"
            )
            let calls = await engine.calls
            XCTAssertEqual(
                calls.filter { $0 == "stop" }.count,
                attempt,
                "attempt \(attempt): each refused mutation stops the pass exactly once: \(calls)"
            )
            let lastStop = try XCTUnwrap(calls.lastIndex(of: "stop"), "attempt \(attempt): \(calls)")
            let lastStartDone = try XCTUnwrap(
                calls.lastIndex(of: "start:done"),
                "attempt \(attempt): a refusal must leave a restarted pass behind it: \(calls)"
            )
            XCTAssertGreaterThan(
                lastStartDone,
                lastStop,
                "attempt \(attempt): the restart after the refusal is the one left running: \(calls)"
            )
            let isRunning = await sync.isRunningForTesting()
            XCTAssertTrue(isRunning, "attempt \(attempt): a refused mutation leaves the synchronizer running")
        }
    }

    /// The same contract for the truncate: a rewind reports the refusal on its publisher, and the
    /// chain state is never truncated underneath a writer the engine could not account for.
    func testRewindRefusesToTruncateWhenTheStopWasNotQuiescent() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let welding = ZcashRustBackendWeldingMock()
        welding.truncateToChainStateChainStateClosure = { _ in }
        let sync = try makeSlipstreamSynchronizer(engine: engine, welding: welding)
        await sync.setInternalSyncStatusForTesting(.disconnected)

        try await sync.start(retry: false)
        engine.stopQuiescent = false

        let failed = XCTestExpectation(description: "rewind reported the refusal")
        var rewindError: Error?
        sync.rewind(.birthday)
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        rewindError = error
                    }
                    failed.fulfill()
                },
                receiveValue: { _ in }
            )
            .store(in: &cancellables)
        await fulfillment(of: [failed], timeout: 5)

        guard case .slipstreamEngineNotQuiescent = try XCTUnwrap(rewindError as? ZcashError) else {
            return XCTFail("a non-quiescent stop must refuse the truncate")
        }
        XCTAssertFalse(
            welding.truncateToChainStateChainStateCalled,
            "the chain state must not be truncated on top of a live writer"
        )
        let isRunning = await sync.isRunningForTesting()
        XCTAssertTrue(isRunning, "a refused rewind leaves the synchronizer running, as it found it")
    }

    /// [MOB-1850] The truncate half of the repeated refusal. A host that meets the refusal usually
    /// retries, and the retry is the dangerous one: it arrives at a stop that has already given up
    /// waiting once, and must still be told the writer is unaccounted for.
    func testRepeatedNonQuiescentStopsKeepRefusingTheRewind() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let welding = ZcashRustBackendWeldingMock()
        welding.truncateToChainStateChainStateClosure = { _ in }
        let sync = try makeSlipstreamSynchronizer(engine: engine, welding: welding)
        await sync.setInternalSyncStatusForTesting(.disconnected)

        try await sync.start(retry: false)
        engine.stopQuiescent = false

        for attempt in 1...2 {
            let failed = XCTestExpectation(description: "rewind attempt \(attempt) reported the refusal")
            var rewindError: Error?
            sync.rewind(.birthday)
                .sink(
                    receiveCompletion: { completion in
                        if case let .failure(error) = completion {
                            rewindError = error
                        }
                        failed.fulfill()
                    },
                    receiveValue: { _ in }
                )
                .store(in: &cancellables)
            await fulfillment(of: [failed], timeout: 5)

            guard case .slipstreamEngineNotQuiescent = try XCTUnwrap(rewindError as? ZcashError) else {
                return XCTFail("attempt \(attempt): a stop that stayed non-quiescent must refuse the truncate again")
            }
            XCTAssertFalse(
                welding.truncateToChainStateChainStateCalled,
                "attempt \(attempt): the chain state must not be truncated on top of a writer that never finished"
            )
            let isRunning = await sync.isRunningForTesting()
            XCTAssertTrue(isRunning, "attempt \(attempt): a refused rewind leaves the synchronizer running")
        }

        let calls = await engine.calls
        XCTAssertEqual(calls.filter { $0 == "stop" }.count, 2, "each refused rewind stopped the pass once: \(calls)")
    }

    /// A wipe deletes the files every other operation reads, so it is the one that must refuse most
    /// firmly: the handle is not freed and nothing is removed.
    func testWipeRefusesWhenTheStopWasNotQuiescent() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)

        try await sync.start(retry: false)
        engine.stopQuiescent = false

        let finished = XCTestExpectation(description: "wipe reported the refusal")
        var wipeError: Error?
        sync.wipe()
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        wipeError = error
                    }
                    finished.fulfill()
                },
                receiveValue: { _ in }
            )
            .store(in: &cancellables)
        await fulfillment(of: [finished], timeout: 5)

        guard case .slipstreamEngineNotQuiescent = try XCTUnwrap(wipeError as? ZcashError) else {
            return XCTFail("a non-quiescent stop must refuse the wipe")
        }
        let calls = await engine.calls
        XCTAssertFalse(calls.contains("close"), "the handle must not be freed under a live writer: \(calls)")
        XCTAssertNotEqual(sync.latestState.internalSyncStatus, .unprepared, "the wallet was left intact")
        let isRunning = await sync.isRunningForTesting()
        XCTAssertTrue(isRunning, "a refused wipe leaves the synchronizer running, as it found it")
    }

    /// The reopen half of the same rule: a switch that cannot prove the old pass is gone must not
    /// hand the wallet to a second engine handle.
    func testSwitchToRefusesToReopenWhenTheStopWasNotQuiescent() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)

        try await sync.start(retry: false)
        engine.stopQuiescent = false

        do {
            try await sync.switchTo(endpoint: LightWalletEndpoint(address: "other.example.com", port: 443, secure: true))
            XCTFail("a non-quiescent stop must refuse the reopen")
        } catch let error as ZcashError {
            guard case .slipstreamEngineNotQuiescent = error else {
                return XCTFail("unexpected error \(error.code)")
            }
        }

        let calls = await engine.calls
        XCTAssertFalse(
            calls.contains { $0.hasPrefix("reopen(") },
            "a second handle must not be opened onto a wallet the first one may still be writing: \(calls)"
        )
    }

    /// The control: a quiescent stop is the ordinary case, and it must still mutate. Without this
    /// the three refusals above would pass just as well against an operation that refused always.
    func testAQuiescentStopStillMutates() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let welding = ZcashRustBackendWeldingMock()
        welding.deleteAccountClosure = { _ in }
        let sync = try makeSlipstreamSynchronizer(engine: engine, welding: welding)
        await sync.setInternalSyncStatusForTesting(.disconnected)

        try await sync.start(retry: false)

        try await sync.deleteAccount(TestsData.mockedAccountUUID)

        XCTAssertTrue(welding.deleteAccountCalled, "the default stop is quiescent and the mutation goes through")
    }

    /// [MOB-1850] The refusal is about the wallet, not about the caller: once the engine can prove
    /// its pass and its writer are gone, a mutation that was refused must go through. A
    /// refusal that outlived the condition causing it would be its own outage — the mirror image of
    /// the bug, and the reason the record is CLEARED by the pass finishing rather than by time.
    func testQuiescenceAdmitsTheMutationAfterEarlierRefusals() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let welding = ZcashRustBackendWeldingMock()
        welding.deleteAccountClosure = { _ in }
        let sync = try makeSlipstreamSynchronizer(engine: engine, welding: welding)
        await sync.setInternalSyncStatusForTesting(.disconnected)

        try await sync.start(retry: false)
        engine.stopQuiescent = false

        do {
            try await sync.deleteAccount(TestsData.mockedAccountUUID)
            XCTFail("the unproved stop must refuse the mutation first")
        } catch let error as ZcashError {
            guard case .slipstreamEngineNotQuiescent = error else {
                return XCTFail("unexpected error \(error.code)")
            }
        }
        XCTAssertFalse(welding.deleteAccountCalled, "nothing was written while the writer was unaccounted for")

        // The writer finished: the engine can now prove what it could not prove before.
        engine.stopQuiescent = true

        try await sync.deleteAccount(TestsData.mockedAccountUUID)

        XCTAssertTrue(welding.deleteAccountCalled, "a proved-quiescent stop admits the mutation the refusals held back")
    }

    // MARK: - Helpers

    /// Shuts the snapshot gate from INSIDE the next `snapshot()` call, so exactly one tick is held
    /// and the test knows it. Closing the gate and registering the observer separately would leave a
    /// window in which a call slips past the observer and hangs on the gate for the whole timeout.
    private func holdNextSnapshot(of engine: GatedFakeSlipstreamEngine, description: String) async throws {
        let held = XCTestExpectation(description: description)
        await engine.onCall("snapshot") { [gate = engine.snapshotGate] in
            gate.close()
            held.fulfill()
        }
        await fulfillment(of: [held], timeout: 5)
    }

    /// The engine calls that own a pass, with the poll loop's per-tick chatter (`snapshot`,
    /// `drainEvents`, `walletSummary`) filtered out — that chatter grows on its own schedule and
    /// would make any exact comparison a race the test invented.
    private static func lifecycleCalls(_ calls: [String]) -> [String] {
        calls.filter { call in
            call.hasPrefix("start") || call.hasPrefix("stop") || call.hasPrefix("reopen") || call.hasPrefix("close")
                || call == "open" || call == "notifyTxChange"
        }
    }

    /// The index of the first teardown that began while an engine `start` had been entered but had
    /// not yet returned, or nil when the trace never does that.
    ///
    /// This is the ordering invariant recovery must respect, in one line: a lifecycle operation
    /// that stops the engine may only run when no other operation is in the middle of bringing it
    /// up.
    private static func firstTeardownWhileAStartIsInFlight(_ calls: [String]) -> Int? {
        var startsInFlight = 0
        for (index, call) in calls.enumerated() {
            switch call {
            case "start": startsInFlight += 1
            case "start:done": startsInFlight -= 1
            case "stop", "close": if startsInFlight > 0 { return index }
            default: break
            }
        }
        return nil
    }
}
