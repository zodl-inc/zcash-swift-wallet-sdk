//
//  SlipstreamFakeEngineSmokeTests.swift
//  ZcashLightClientKitTests
//

import Combine
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

/// Proves the engine seam introduced by MOB-1850: `SlipstreamSynchronizer` drives its sync engine
/// through `SlipstreamEngineControlling`, so a test can hand it a fake and observe the lifecycle
/// without an FFI handle, a wallet database or a server.
///
/// The seam is what later work needs, not the assertions here: this file is the smoke test that the
/// injected engine really is the one the synchronizer starts, polls and stops.
final class SlipstreamFakeEngineSmokeTests: ZcashTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() async throws {
        cancellables.removeAll()
        try await super.tearDown()
    }

    func testStartWithFakeEngineSpawnsOnePassAndTicks() async throws {
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let synchronizer = try makeSlipstreamSynchronizer(engine: engine)
        await synchronizer.setInternalSyncStatusForTesting(.disconnected)

        // Subscribed before the run so the `.stopped` emission cannot be missed: `stopImpl()` sends
        // it and only then awaits `engine.stop()`, so observing the engine's stop below proves this
        // recorder has already seen it.
        let statuses = RecordedSyncStatuses()
        synchronizer.stateStream
            .sink { statuses.append($0.internalSyncStatus) }
            .store(in: &cancellables)

        try await synchronizer.start(retry: false)

        let startCalls = await engine.calls.filter { $0 == "start" }.count
        XCTAssertEqual(startCalls, 1, "start() drove the INJECTED engine, exactly once")
        XCTAssertTrue(
            synchronizer.latestState.internalSyncStatus.isSyncing,
            "and published the fake's snapshot as a syncing state"
        )

        // A NEGATIVE claim -- that nothing further happens -- so a fixed sleep is the honest way to
        // make it: the poll cadence is 2 s, and a second tick must poll the engine again without
        // starting a second pass.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        let startCallsAfterATick = await engine.calls.filter { $0 == "start" }.count
        XCTAssertEqual(startCallsAfterATick, 1, "a poll tick polls; it does not start a second pass")
        let snapshotCalls = await engine.calls.filter { $0 == "snapshot" }.count
        XCTAssertGreaterThan(snapshotCalls, 1, "and the poll loop really is ticking against the fake")

        synchronizer.stop()

        // A POSITIVE claim, so it waits on the observable rather than on a clock.
        let stopped = await waitUntil { await engine.calls.contains("stop") }
        XCTAssertTrue(stopped, "stop() reached the injected engine")
        let stopCalls = await engine.calls.filter { $0 == "stop" }.count
        XCTAssertEqual(stopCalls, 1, "exactly once")
        XCTAssertTrue(statuses.contains(.stopped), "and the host was told, before the engine was stopped")
    }

    /// The gates are the reason the seam exists, so this pins that one of them really suspends the
    /// synchronizer at a chosen point and that a test can release it from outside the engine actor.
    ///
    /// The interleaving it holds open is the one the SDK-1 ordering contract is about: a `stop()`
    /// that has reached the engine but not returned must keep the next `start()` waiting, so the
    /// engine can never be told to start a pass and then to abort it.
    func testAClosedStopGateHoldsTheNextStartUntilTheTestOpensIt() async throws {
        let engine = GatedFakeSlipstreamEngine(openGates: false)
        engine.startGate.open()
        engine.snapshotGate.open()
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let synchronizer = try makeSlipstreamSynchronizer(engine: engine)
        await synchronizer.setInternalSyncStatusForTesting(.disconnected)
        try await synchronizer.start(retry: false)

        synchronizer.stop()
        let reachedStop = await waitUntil { await engine.calls.contains("stop") }
        XCTAssertTrue(reachedStop, "the stop reached the engine")

        let secondStart = Task { try await synchronizer.start(retry: false) }

        // A NEGATIVE claim -- that the second start has NOT run -- so it is made by letting real
        // time pass. Nothing but the shut gate is holding it.
        try await Task.sleep(nanoseconds: 300_000_000)
        let startsWhileHeld = await engine.calls.filter { $0 == "start" }.count
        XCTAssertEqual(startsWhileHeld, 1, "a start cannot overtake a stop that has not returned")

        engine.stopGate.open()
        try await secondStart.value
        let startsAfterRelease = await engine.calls.filter { $0 == "start" }.count
        XCTAssertEqual(startsAfterRelease, 2, "and runs as soon as the stop completes")

        // Leave nothing polling behind: the gate is open, so this teardown lands.
        synchronizer.stop()
        let stoppedAgain = await waitUntil { await engine.calls.filter { $0 == "stop" }.count == 2 }
        XCTAssertTrue(stoppedAgain, "the synchronizer tore down cleanly")
    }
}
