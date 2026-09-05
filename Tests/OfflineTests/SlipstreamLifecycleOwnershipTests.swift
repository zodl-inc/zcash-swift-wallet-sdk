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
/// Two audit findings meet here. **R1**: a poll tick decides things — that the pass has stalled,
/// what state to publish, whether to re-fetch transactions — and then suspends inside an engine
/// call. By the time it resumes, the pass it decided for may be gone: the app stopped the
/// synchronizer, a server switch replaced the handle, a wipe deleted the wallet. Acting on a
/// decision taken for a pass that no longer exists is how a deliberately stopped synchronizer came
/// back to life. **R2**: the stall recovery tears the engine down and brings it back up, and while
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

    // MARK: - R1: a tick belongs to the pass that scheduled it

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

    // MARK: - R2: a recovery may only act on the pass it was decided for

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
    /// This is the R2 invariant in one line: a lifecycle operation that stops the engine may only
    /// run when no other operation is in the middle of bringing it up.
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
