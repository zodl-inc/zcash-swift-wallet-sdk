//
//  SlipstreamPrePassScannedHeightTests.swift
//
//  MOB-1912: the state `start()` publishes before its first pass and the `.stopped` state `stop()`
//  publishes used to omit `fullyScannedHeight`, so `SynchronizerState.init` defaulted it to 0 next to
//  a real chain tip. A client sizing "blocks remaining" as `latestBlockHeight − fullyScannedHeight`
//  read the whole chain as unsynced for the moment before the first in-pass state arrived — Zodl's
//  syncing banner flashed in and out on every foreground and on a new wallet's first start.
//
//  Pinned: the height the last in-pass state established survives `stop()` and rides in the pre-pass
//  state of the next `start()`, the way every in-pass state already carries it.
//

import Combine
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class SlipstreamPrePassScannedHeightTests: ZcashTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() async throws {
        cancellables.removeAll()
        try await super.tearDown()
    }

    func testStopAndTheNextStartCarryTheLastKnownScannedHeight() async throws {
        // The snapshot's chain tip stays 0, as in the mask tests: a known tip would also wake the
        // resubmission poller, which needs repository stubs this test is not about.
        let scannedHeight: BlockHeight = 2_000_000
        let engine = GatedFakeSlipstreamEngine()
        await engine.setNextWalletSummary(Self.walletSummary(fullyScannedHeight: scannedHeight))
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100))
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)

        try await sync.start(retry: false)
        let established = await waitUntil { sync.latestState.fullyScannedHeight == scannedHeight }
        XCTAssertTrue(established, "the first tick must publish the wallet summary's fully-scanned height")

        sync.stop()
        let stopped = await waitUntil { sync.latestState.internalSyncStatus == .stopped }
        XCTAssertTrue(stopped, "stop() must park the pass")
        XCTAssertEqual(
            sync.latestState.fullyScannedHeight,
            scannedHeight,
            "the .stopped state dropped the scanned height"
        )

        let states = RecordedStates()
        sync.stateStream.sink { states.append($0) }.store(in: &cancellables)
        try await sync.start(retry: false)
        let restarted = await waitUntil { states.firstSyncing != nil }
        XCTAssertTrue(restarted, "the restart must publish a .syncing state")
        XCTAssertEqual(
            states.firstSyncing?.fullyScannedHeight,
            scannedHeight,
            "start()'s pre-pass state dropped the scanned height"
        )
        sync.stop()
        _ = await waitUntil { sync.latestState.internalSyncStatus == .stopped }
    }

    private static func walletSummary(fullyScannedHeight: BlockHeight) -> WalletSummary {
        WalletSummary(
            accountBalances: [:],
            chainTipHeight: fullyScannedHeight,
            fullyScannedHeight: fullyScannedHeight,
            recoveryProgress: nil,
            scanProgress: nil,
            nextSaplingSubtreeIndex: 0,
            nextOrchardSubtreeIndex: 0,
            nextIronwoodSubtreeIndex: 0
        )
    }

    /// Every state the stream delivers, in order; `firstSyncing` is the pre-pass state of a restart.
    private final class RecordedStates: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [SynchronizerState] = []

        var firstSyncing: SynchronizerState? {
            lock.lock()
            defer { lock.unlock() }
            return states.first { state in
                if case .syncing = state.internalSyncStatus { return true }
                return false
            }
        }

        func append(_ state: SynchronizerState) {
            lock.lock()
            states.append(state)
            lock.unlock()
        }
    }
}
