//
//  SlipstreamStallRecoveryPolicyTests.swift
//  ZcashLightClientKitTests
//

import Combine
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

/// Coverage for the stall watchdog's recovery restart (MOB-1850): the pure policy
/// `SlipstreamSynchronizer.stallRecoveryDecision(...)`, and the reporting the restart owes its host
/// when it cannot bring the pass back up. The watchdog used to only log a stalled pass; it now
/// restarts one, so the policy owns the two properties that keep the restart safe -- a per-handle
/// cap on how many times a pass may be resurrected, and an exponential wait between attempts so a
/// server that is down is not hammered once per poll tick -- and the restart owns the promise that
/// every `.syncStalled` the host is handed eventually resolves.
final class SlipstreamStallRecoveryPolicyTests: ZcashTestCase {
    private let backoffBase: TimeInterval = 60
    private let maxAttempts = 3

    /// A healthy pass never restarts, whatever the counters say.
    func testNotStalledDecidesNone() {
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: false,
                attemptsSoFar: 0,
                maxAttempts: maxAttempts,
                secondsSinceLastRestart: nil,
                backoffBase: backoffBase
            ),
            .none
        )
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: false,
                attemptsSoFar: 2,
                maxAttempts: maxAttempts,
                secondsSinceLastRestart: 10_000,
                backoffBase: backoffBase
            ),
            .none,
            "a recovered pass must not restart just because its budget and backoff would allow it"
        )
    }

    /// The first stall of a handle restarts immediately — there is no earlier restart to wait after,
    /// and the whole point is to reconnect without the user asking.
    func testFirstStallRestartsImmediately() {
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: true,
                attemptsSoFar: 0,
                maxAttempts: maxAttempts,
                secondsSinceLastRestart: nil,
                backoffBase: backoffBase
            ),
            .restart(attempt: 1)
        )
    }

    /// Still inside the first backoff window (60 s after restart 1) → hold. Without this the poll
    /// loop would re-decide every 2 s and burn the whole budget in six seconds.
    func testSecondStallInsideBackoffWindowHolds() {
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: true,
                attemptsSoFar: 1,
                maxAttempts: maxAttempts,
                secondsSinceLastRestart: 30,
                backoffBase: backoffBase
            ),
            .none
        )
    }

    /// Past the first backoff window → the second restart is allowed.
    func testSecondStallPastBackoffWindowRestarts() {
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: true,
                attemptsSoFar: 1,
                maxAttempts: maxAttempts,
                secondsSinceLastRestart: 61,
                backoffBase: backoffBase
            ),
            .restart(attempt: 2)
        )
    }

    /// The window doubles with each attempt: after two restarts the wait is 120 s, so 119 s holds.
    func testThirdStallInsideDoubledBackoffWindowHolds() {
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: true,
                attemptsSoFar: 2,
                maxAttempts: maxAttempts,
                secondsSinceLastRestart: 119,
                backoffBase: backoffBase
            ),
            .none
        )
    }

    /// …and 121 s clears it, allowing the third and last restart.
    func testThirdStallPastDoubledBackoffWindowRestarts() {
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: true,
                attemptsSoFar: 2,
                maxAttempts: maxAttempts,
                secondsSinceLastRestart: 121,
                backoffBase: backoffBase
            ),
            .restart(attempt: 3)
        )
    }

    /// The budget is spent: the SDK stops trying and says so, so the host can offer the user a
    /// server switch instead of watching a pass restart forever.
    func testBudgetExhaustedGivesUp() {
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: true,
                attemptsSoFar: 3,
                maxAttempts: maxAttempts,
                secondsSinceLastRestart: 10_000,
                backoffBase: backoffBase
            ),
            .giveUp,
            "the cap wins over an elapsed backoff window"
        )
    }

    /// The shipped policy, end to end: 3 restarts per handle with exactly TWO waits between them,
    /// 60 s and then 120 s, and a give-up in place of a fourth restart.
    ///
    /// The cap is checked before any backoff window is computed, so the doubling stops where the
    /// budget does: with `maxStallRestartsPerHandle == 3` the largest window a shipped decision
    /// can ever evaluate is the one for `attemptsSoFar == 2`. A third window would need a fourth
    /// restart to sit in front of, and there is none.
    func testShippedPolicyRestartsThreeTimesWithTwoWaits() {
        XCTAssertEqual(SlipstreamSynchronizer.maxStallRestartsPerHandle, 3)
        XCTAssertEqual(SlipstreamSynchronizer.stallRestartBackoffBase, 60)

        // Walk the shipped constants through the policy the way `tickPoll` does, so the waits
        // between consecutive restarts are pinned as 60 s and then 120 s.
        for (attemptsSoFar, window) in [(1, 60.0), (2, 120.0)] {
            let justInside = shippedDecision(attemptsSoFar: attemptsSoFar, secondsSinceLastRestart: window - 1)
            let atWindow = shippedDecision(attemptsSoFar: attemptsSoFar, secondsSinceLastRestart: window)
            XCTAssertEqual(justInside, .none, "attempt \(attemptsSoFar + 1) must wait the full \(Int(window)) s")
            XCTAssertEqual(atWindow, .restart(attempt: attemptsSoFar + 1), "attempt \(attemptsSoFar + 1) is due at \(Int(window)) s")
        }

        // And there is no third wait: after the third restart the budget is spent, so however long
        // the host waits it is told to stop rather than handed a 240 s window.
        for elapsed in [239.0, 240.0, 10_000.0] {
            XCTAssertEqual(
                shippedDecision(attemptsSoFar: 3, secondsSinceLastRestart: elapsed),
                .giveUp,
                "the shipped cap gives up instead of opening a further backoff window at \(Int(elapsed)) s"
            )
        }
    }

    /// The doubling itself, tested as a property of the FUNCTION rather than of the shipped
    /// policy: raise the cap and the window after attempt 3 is 240 s. The shipped configuration
    /// never reaches this window (see the test above); it is asserted here so a change to the
    /// backoff formula cannot pass unnoticed behind the cap.
    func testBackoffWindowKeepsDoublingWhenTheCapAllowsIt() {
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: true,
                attemptsSoFar: 3,
                maxAttempts: 4,
                secondsSinceLastRestart: 239,
                backoffBase: backoffBase
            ),
            .none
        )
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: true,
                attemptsSoFar: 3,
                maxAttempts: 4,
                secondsSinceLastRestart: 240,
                backoffBase: backoffBase
            ),
            .restart(attempt: 4)
        )
    }

    // MARK: - The watchdog -> policy seam

    /// The stall fact the policy consumes comes from `checkStallWatchdog`, which clamps the
    /// engine-reported span to the CURRENT handle's lifetime. That clamp used to only spare the
    /// user a wrong log line; it now decides whether the SDK tears the engine down. A freshly
    /// opened handle must therefore report "not stalled" no matter how large a span the engine
    /// carries over -- `stalledSeconds` survives a stop->start, so believing an inherited span
    /// would restart a pass that is seconds old, and the restart would hand the next tick exactly
    /// the same inherited span again.
    func testFreshHandleReportsNoStallDespiteInheritedStallSpan() async throws {
        let synchronizer = try makeSynchronizer()
        let snapshot = SlipstreamSnapshot(
            chainTip: 2_000_000,
            fetchedBlocks: 10,
            scannedBlocks: 10,
            enhancedTxs: 0,
            currentRangeEnd: 2_000_000,
            state: 1,
            stalledSeconds: 497
        )

        let stalled = await synchronizer.checkStallWatchdog(snapshot)

        XCTAssertFalse(stalled, "a handle opened moments ago cannot have accrued a 497 s stall")
        XCTAssertEqual(
            SlipstreamSynchronizer.stallRecoveryDecision(
                isStalled: stalled,
                attemptsSoFar: 0,
                maxAttempts: SlipstreamSynchronizer.maxStallRestartsPerHandle,
                secondsSinceLastRestart: nil,
                backoffBase: SlipstreamSynchronizer.stallRestartBackoffBase
            ),
            .none,
            "and so must not spend a restart from the handle's budget"
        )
    }

    // MARK: - A restart that cannot bring the pass back up

    /// A failed restart must report the give-up on attempt 1, not only at the cap.
    ///
    /// `runStallRecovery` calls `stopPolling()` before anything else and `startImpl` throws before
    /// it reaches `startPolling()`, so a restart whose start fails leaves no poll loop at all:
    /// nothing ticks, nothing re-decides, and the `.giveUp` branch — which lives in `tickPoll` —
    /// can never fire. While the give-up report was gated on
    /// `stallRestartAttempts >= maxStallRestartsPerHandle`, a failure on attempt 1 or 2 therefore
    /// left the synchronizer permanently stopped AND permanently silent: a host that had just been
    /// handed `.syncStalled(attempt: 1, gaveUp: false)` waited forever for a resolution nothing
    /// could produce.
    ///
    /// [MOB-1850] The failure is now injected through the engine (`startError`) rather than by
    /// leaving the synchronizer unprepared. `runStallRecovery` validates that the wallet IS prepared
    /// before it touches anything — an unprepared synchronizer no longer reaches its restart at all,
    /// which is the point of the test below — so the reachable ways to fail a restart's start are
    /// the migration gate and `engine.start()` itself, which is exactly what a dead transport fails.
    func testRestartWhoseStartFailsReportsGiveUpOnTheFirstAttempt() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setStartError(ZcashError.rustSlipstreamNotOpen)
        let synchronizer = try makeSlipstreamSynchronizer(engine: engine)
        await synchronizer.setInternalSyncStatusForTesting(.disconnected)
        let giveUp = XCTestExpectation(description: "give-up stall event")
        let events = RecordedEvents()
        let subscription = synchronizer.eventStream.sink { event in
            events.append(event)
            if case .syncStalled(_, let gaveUp) = event, gaveUp {
                giveUp.fulfill()
            }
        }
        defer { subscription.cancel() }

        // The generations a poll tick would capture on a synchronizer nothing has stopped, so the
        // recovery's validation passes and it reaches its restart.
        await synchronizer.runStallRecovery(
            expectedPassGeneration: await synchronizer.passGenerationForTesting(),
            expectedStopRequestGeneration: await synchronizer.stopRequestGenerationForTesting(),
            attempt: 1
        )

        await fulfillment(of: [giveUp], timeout: 5)
        XCTAssertEqual(
            events.syncStalledEvents,
            [SyncStalledReport(attempt: 1, gaveUp: false), SyncStalledReport(attempt: 1, gaveUp: true)],
            "the restart it announced, then exactly one give-up naming the attempt that failed"
        )
    }

    /// A restart whose generation is already stale abandons at its first guard, emitting nothing
    /// and starting nothing.
    ///
    /// The guard is what keeps the recovery from resurrecting an engine another path has claimed:
    /// a `stop()` the user asked for, or a `switchTo` / `wipe` / import / delete / rewind that is
    /// bringing up a pass of its own. Its SILENCE is part of the contract. An abandoned restart
    /// has not given up — the path that took the engine over is now responsible for the pass — so
    /// a `.syncStalled(gaveUp: true)` here would tell a host the SDK had stopped trying when it
    /// has not, and a `.syncStalled(gaveUp: false)` would promise a restart nobody is performing.
    ///
    /// `-1` stands in for "somebody bumped the counter while this restart was waiting for its turn":
    /// the generation only ever climbs from 0, so no synchronizer can hold it and the test needs to
    /// win no race to be sure the guard is the thing it exercises.
    func testRestartWithAStaleGenerationAbandonsSilently() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let synchronizer = try makeSlipstreamSynchronizer(engine: engine)
        let events = RecordedEvents()
        let subscription = synchronizer.eventStream.sink { events.append($0) }
        defer { subscription.cancel() }

        await synchronizer.runStallRecovery(
            expectedPassGeneration: -1,
            expectedStopRequestGeneration: await synchronizer.stopRequestGenerationForTesting(),
            attempt: 1
        )

        XCTAssertTrue(
            events.syncStalledEvents.isEmpty,
            "an abandoned restart owes the host no stall report, and must not forge one"
        )
        XCTAssertTrue(events.all.isEmpty, "nor anything else: it touched no transaction and found nothing")
        // [MOB-1850] The engine is untouched, not merely un-restarted. The old restart tore the pass
        // down BEFORE it compared generations, so `engine.stop()` had already landed by the time it
        // abandoned; validation now happens first, so a stale recovery makes no engine call at all.
        let calls = await engine.calls
        XCTAssertTrue(calls.isEmpty, "and made no engine call whatsoever: \(calls)")
        XCTAssertEqual(
            synchronizer.latestState.internalSyncStatus,
            .unprepared,
            "and it started nothing: the synchronizer is exactly as the guard found it"
        )
    }

    /// A recovery restart must not reset the budget that bounds it.
    ///
    /// The restart brings the pass back up through `startImpl(retry:resetRecoveryBudget:)`, and
    /// `startImpl` re-arms the stall watchdog — including, for an app-driven start, the per-handle
    /// restart budget. If the recovery's own restart cleared that budget, `stallRestartAttempts`
    /// would return to zero after every attempt, the cap would be unreachable and a permanently
    /// stalled server would be restarted forever. The flag argument is what keeps the two apart;
    /// before it, the same distinction was inferred from `stallRecoveryInFlight`, which could not
    /// tell a recovery's restart from an app start that merely overlapped one.
    func testRecoveryRestartPreservesTheBudgetItIsSpending() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let synchronizer = try makeSlipstreamSynchronizer(engine: engine)
        await synchronizer.setInternalSyncStatusForTesting(.disconnected)

        await synchronizer.runStallRecovery(
            expectedPassGeneration: await synchronizer.passGenerationForTesting(),
            expectedStopRequestGeneration: await synchronizer.stopRequestGenerationForTesting(),
            attempt: 1
        )

        let attemptsAfterRecovery = await synchronizer.stallRestartAttemptsForTesting()
        XCTAssertEqual(attemptsAfterRecovery, 1, "the successful restart spent one attempt and did not hand itself a fresh budget")

        // An app-driven start is the opposite case: a new run of the host's own deserves a clean
        // slate, so it clears what the recovery preserved.
        try await synchronizer.start(retry: false)
        let attemptsAfterAppStart = await synchronizer.stallRestartAttemptsForTesting()
        XCTAssertEqual(attemptsAfterAppStart, 0, "an app-driven start opens a new run and resets the budget")

        synchronizer.stop()
    }

    // MARK: - Helpers

    /// The policy as the poll loop asks it, with the shipped constants substituted for the
    /// caller-supplied ones.
    private func shippedDecision(attemptsSoFar: Int, secondsSinceLastRestart: TimeInterval?) -> SlipstreamSynchronizer.StallRecoveryDecision {
        SlipstreamSynchronizer.stallRecoveryDecision(
            isStalled: true,
            attemptsSoFar: attemptsSoFar,
            maxAttempts: SlipstreamSynchronizer.maxStallRestartsPerHandle,
            secondsSinceLastRestart: secondsSinceLastRestart,
            backoffBase: SlipstreamSynchronizer.stallRestartBackoffBase
        )
    }

    /// A prepared-nothing synchronizer over the REAL engine: no handle opened, `.unprepared`
    /// status, no poll loop.
    ///
    /// Enough to drive `checkStallWatchdog`, which reads only the snapshot it is handed and the
    /// watchdog's own Swift-side state. The recovery tests above use the gated fake instead
    /// ([MOB-1850]), because what they assert is which engine calls a validated restart does and
    /// does not make.
    private func makeSynchronizer() throws -> SlipstreamSynchronizer {
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in ZcashRustBackendWeldingMock() }
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in LightWalletServiceMock() }
        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in TransactionRepositoryMock() }

        let initializer = Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: try __dataDbURL(),
            torDirURL: try __torDirURL(),
            endpoint: LightWalletEndpointBuilder.default,
            network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )

        return SlipstreamSynchronizer(initializer: initializer)
    }
}
