//
//  SlipstreamTestSynchronizer.swift
//  TestUtils
//

import Foundation
import XCTest
@testable import ZcashLightClientKit

extension ZcashTestCase {
    /// Builds a `SlipstreamSynchronizer` around an injected engine, wired exactly as the shipped one
    /// is: the same container, the same `Initializer` arguments, the same production `init` body —
    /// only the engine is the caller's.
    ///
    /// Promoted here from `SlipstreamStallRecoveryPolicyTests` so every Slipstream lifecycle test
    /// shares one definition of "a synchronizer over test doubles"; a divergence between two such
    /// setups is the kind of thing that makes one test's failure unreproducible in another.
    ///
    /// The three container mocks are what `SlipstreamSynchronizer.init` and `start()` reach for:
    /// `ZcashRustBackendWelding` backs both `initializer.rustBackend` and the migration host's
    /// sync-blocked predicate, `LightWalletService` and `TransactionRepository` are resolved while
    /// the object graph is built. The welding mock's `listAccounts` is defaulted to "no accounts"
    /// because `start()`'s migration privacy gate calls it unconditionally, and the generated mock's
    /// un-stubbed return value is implicitly unwrapped — an un-defaulted call is a crash, not a
    /// failure. A caller that supplies its own `welding` owns that decision, and this leaves an
    /// answer it already stubbed untouched.
    ///
    /// - Parameters:
    ///   - engine: the engine the synchronizer drives. A `GatedFakeSlipstreamEngine` for a
    ///     lifecycle test; a real `SlipstreamEngine` would work too.
    ///   - container: the DI container to build over. Defaults to the test case's `mockContainer`.
    ///   - welding: the rust-backend double to register. Defaults to a fresh, minimally stubbed one.
    ///   - endpoint: the initial server. Never dialled by a fake engine.
    ///   - network: the Zcash network. Testnet by default, as every offline Slipstream test uses.
    ///   - alternateEndpoints: recorded on the synchronizer; the engine's own alternates are the
    ///     caller's business, since the caller built the engine.
    func makeSlipstreamSynchronizer(
        engine: any SlipstreamEngineControlling,
        container: DIContainer? = nil,
        welding: ZcashRustBackendWeldingMock? = nil,
        endpoint: LightWalletEndpoint = LightWalletEndpointBuilder.default,
        network: ZcashNetwork = ZcashNetworkBuilder.network(for: .testnet),
        alternateEndpoints: [LightWalletEndpoint] = []
    ) throws -> SlipstreamSynchronizer {
        let container = container ?? mockContainer!
        let welding = welding ?? ZcashRustBackendWeldingMock()
        if welding.listAccountsReturnValue == nil {
            welding.listAccountsReturnValue = []
        }
        if welding.migrationBlockRateSamplesWindowReturnValue == nil {
            welding.migrationBlockRateSamplesWindowReturnValue = []
        }

        container.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in welding }
        container.mock(type: LightWalletService.self, isSingleton: true) { _ in LightWalletServiceMock() }
        // `wipe()` closes the repository's database connection before deleting the files, and the
        // generated mock force-unwraps that closure — an un-stubbed call is a crash rather than a
        // failure, exactly like the welding defaults above.
        let repository = TransactionRepositoryMock()
        repository.closeDBConnectionClosure = {}
        container.mock(type: TransactionRepository.self, isSingleton: true) { _ in repository }

        let initializer = Initializer(
            container: container,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: try __dataDbURL(),
            torDirURL: try __torDirURL(),
            endpoint: endpoint,
            network: network,
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )

        return SlipstreamSynchronizer(
            initializer: initializer,
            alternateEndpoints: alternateEndpoints,
            engine: engine
        )
    }
}

extension XCTestCase {
    /// Polls `condition` until it holds or `timeout` elapses, and reports which happened.
    ///
    /// The point is that a positive assertion never rests on a fixed sleep: a slow machine makes a
    /// sleep-based test flaky, and a fast one makes it slower than it needs to be. Waiting on the
    /// thing being asserted fixes both. (A NEGATIVE claim — that something does not happen — still
    /// needs a real elapsed interval, and should say so where it sleeps.)
    func waitUntil(
        timeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.02,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return await condition()
    }
}

/// A thread-safe record of the statuses a synchronizer published, for tests that must assert an
/// emission HAPPENED rather than that it is the current one — a later tick can overwrite
/// `latestState` before the assertion runs, and that would be a race the test invented rather than
/// one it found.
///
/// `NSLock` for the package's iOS 13 / macOS 12 floor.
final class RecordedSyncStatuses: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [InternalSyncStatus] = []

    var all: [InternalSyncStatus] {
        lock.lock()
        defer { lock.unlock() }
        return statuses
    }

    func append(_ status: InternalSyncStatus) {
        lock.lock()
        statuses.append(status)
        lock.unlock()
    }

    func contains(_ status: InternalSyncStatus) -> Bool {
        all.contains(status)
    }
}

/// One `.syncStalled` event, in a form a test can compare. `SynchronizerEvent` is not `Equatable`
/// (its other cases carry model types that are not), so an assertion about the stall reports a host
/// received would otherwise have to be written as a `compactMap` with a pattern match at every call
/// site — and the interesting property is almost always the exact SEQUENCE of reports.
struct SyncStalledReport: Equatable {
    let attempt: Int
    let gaveUp: Bool
}

/// A thread-safe record of the events a synchronizer published — the `eventStream` counterpart of
/// `RecordedSyncStatuses`, and for the same reason: a Combine sink fires on whatever thread sent the
/// value, so appending to a captured local `var` from one is a data race the test invented.
///
/// `NSLock` for the package's iOS 13 / macOS 12 floor.
final class RecordedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SynchronizerEvent] = []

    var all: [SynchronizerEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// The `.syncStalled` reports, in order — the projection nearly every lifecycle assertion wants.
    var syncStalledEvents: [SyncStalledReport] {
        all.compactMap { event in
            guard case let .syncStalled(attempt, gaveUp) = event else { return nil }
            return SyncStalledReport(attempt: attempt, gaveUp: gaveUp)
        }
    }

    func append(_ event: SynchronizerEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}

extension SlipstreamSnapshot {
    /// A snapshot of a healthy, mid-flight sync pass: state Syncing, a fresh chain tip, not
    /// recovering, nothing stalled.
    ///
    /// `chainTip` is 0 by default, which is deliberate rather than lazy: the poll loop's background
    /// resubmission check is gated on `chainTip > 0`, so a zero tip keeps a lifecycle test's tick
    /// confined to the engine calls it is actually about. A test that wants the resubmission driver
    /// to fire passes a real height.
    static func testSyncing(
        progressPermille: UInt16,
        chainTip: UInt64 = 0,
        fetchedBlocks: UInt64 = 0,
        scannedBlocks: UInt64 = 0,
        enhancedTxs: UInt64 = 0,
        currentRangeEnd: UInt64 = 0,
        passTotalBlocks: UInt64 = 0,
        spendableHint: UInt8 = 0,
        rangesCompleted: UInt64 = 0,
        stalledSeconds: UInt32 = 0,
        txSetVersion: UInt64 = 0
    ) -> SlipstreamSnapshot {
        SlipstreamSnapshot(
            chainTip: chainTip,
            fetchedBlocks: fetchedBlocks,
            scannedBlocks: scannedBlocks,
            enhancedTxs: enhancedTxs,
            currentRangeEnd: currentRangeEnd,
            state: 1,
            passTotalBlocks: passTotalBlocks,
            spendableHint: spendableHint,
            rangesCompleted: rangesCompleted,
            isRecovering: 0,
            progressPermille: progressPermille,
            stalledSeconds: stalledSeconds,
            tipFresh: 1,
            txSetVersion: txSetVersion
        )
    }
}
