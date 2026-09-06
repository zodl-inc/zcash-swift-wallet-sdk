//
//  SlipstreamMaskMetadataTests.swift
//  ZcashLightClientKitTests
//

import Combine
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

/// [MOB-1852 / audit R10] `SynchronizerState.isSpendableMasked` must always describe the balances
/// carried in the SAME emission — never a flag some other, unrelated call last happened to compute.
///
/// Before this fix, `walletBalanceSnapshots()` wrote `currentlySpendableMasked` as a side effect of
/// every call that obtained a fresh summary, including a standalone `getAccountsBalances()` that
/// published no state at all. A poll tick whose OWN summary came back nil (the engine mid-close, a
/// transient hiccup) fell back to `latestState.accountsBalances` for its balances but read the
/// SHARED flag verbatim for `isSpendableMasked` — so an unrelated caller's read, sitting anywhere
/// between two ticks, could silently flip the flag the next tick reported while the balances that
/// tick actually published were unchanged.
final class SlipstreamMaskMetadataTests: ZcashTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() async throws {
        cancellables.removeAll()
        try await super.tearDown()
    }

    // MARK: - Fixture

    /// One account with a non-zero spendable balance, so masking (which zeroes `spendableValue`)
    /// is actually observable — a fixture whose balance is already zero could not tell a masked
    /// emission from an unmasked one.
    private func maskMetadataWalletSummary() -> WalletSummary {
        let account = AccountUUID(id: [UInt8](repeating: 9, count: 16))
        let balance = AccountBalance(
            saplingBalance: PoolBalance(
                spendableValue: Zatoshi(500_000),
                changePendingConfirmation: .zero,
                valuePendingSpendability: .zero
            ),
            orchardBalance: .zero,
            unshielded: .zero
        )
        return WalletSummary(
            accountBalances: [account: balance],
            chainTipHeight: 3_000_000,
            fullyScannedHeight: 2_999_990,
            recoveryProgress: nil,
            scanProgress: nil,
            nextSaplingSubtreeIndex: 0,
            nextOrchardSubtreeIndex: 0,
            nextIronwoodSubtreeIndex: 0
        )
    }

    // MARK: - The fallback branch carries the RETAINED balances' own flag

    /// Exercises both directions in one test, as the two are mirror images of the same bug:
    /// starting masked and having a standalone unmasked read try to poison the next fallback tick,
    /// and starting unmasked with a standalone masked read doing the same in reverse.
    func testFallbackEmissionCarriesTheRetainedBalancesMaskFlag() async throws {
        try await assertFallbackEmissionRetainsItsOwnMaskFlag(initiallyMasked: true)
        try await assertFallbackEmissionRetainsItsOwnMaskFlag(initiallyMasked: false)
    }

    private func assertFallbackEmissionRetainsItsOwnMaskFlag(initiallyMasked: Bool) async throws {
        let engine = GatedFakeSlipstreamEngine()
        let fixture = maskMetadataWalletSummary()
        await engine.setNextWalletSummary(fixture)
        await engine.setNextSnapshot(
            SlipstreamSnapshot.testSyncing(progressPermille: 100, tipFresh: initiallyMasked ? 0 : 1)
        )
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)

        // 1. Publish the reference emission: a fresh tick with its own summary, masked or not.
        try await sync.start(retry: false)
        let established = await waitUntil {
            sync.latestState.isSpendableMasked == initiallyMasked && !sync.latestState.accountsBalances.isEmpty
        }
        XCTAssertTrue(
            established,
            "the first tick must publish the fixture's balances under isSpendableMasked == \(initiallyMasked)"
        )
        let retainedBalances = sync.latestState.accountsBalances

        // Freeze the pass so the standalone read below cannot race a natural tick: `stop()`
        // preserves both the balances and the flag it just established verbatim (`stopImpl` carries
        // `latestState.accountsBalances` / `latestState.isSpendableMasked` forward unchanged), and
        // stopping the poll loop is what makes the next two steps deterministic instead of racing
        // the 2-second tick cadence.
        sync.stop()
        let stopped = await waitUntil { sync.latestState.internalSyncStatus == .stopped }
        XCTAssertTrue(stopped, "the pass must be parked before the standalone read")
        XCTAssertEqual(sync.latestState.accountsBalances, retainedBalances, "stop() must not disturb the retained balances")
        XCTAssertEqual(sync.latestState.isSpendableMasked, initiallyMasked, "stop() must not disturb the retained flag")

        // 2. A standalone read, under the OPPOSITE mask condition, must not emit state — and,
        //    before the fix, corrupted the shared `currentlySpendableMasked` flag as a side effect
        //    of merely being called, with no tick and no emission involved at all.
        // `stateStream` is backed by a `CurrentValueSubject`, so subscribing replays the CURRENT
        // (`.stopped`) state immediately — the baseline below is taken after that replay, so the
        // assertion is "no NEW emission", not "no emission ever".
        let statuses = RecordedSyncStatuses()
        sync.stateStream.sink { statuses.append($0.internalSyncStatus) }.store(in: &cancellables)
        let emissionsBeforeStandaloneRead = statuses.all.count
        await engine.setNextSnapshot(
            SlipstreamSnapshot.testSyncing(progressPermille: 100, tipFresh: initiallyMasked ? 1 : 0)
        )
        let balancesFromStandaloneRead = try await sync.getAccountsBalances()
        XCTAssertEqual(
            statuses.all.count,
            emissionsBeforeStandaloneRead,
            "a standalone read must not emit state: \(statuses.all)"
        )
        XCTAssertNotEqual(
            balancesFromStandaloneRead,
            retainedBalances,
            "the standalone read must actually have observed the opposite mask condition"
        )

        // 3. The engine goes "mid-close": walletSummary() returns nil, so the next tick has no
        //    fresh summary of its own and must fall back to `latestState` for BOTH the balances
        //    and the flag that describes them — never the flag step 2 left behind.
        await engine.setNextWalletSummary(nil)
        try await sync.start(retry: false)

        // `start()`'s own warm-start emission (unaffected by this bug either way) lands first;
        // waiting for a SECOND new emission is what guarantees the poll loop's first tick — the
        // actual fallback branch under test — has landed too.
        let fellBack = await waitUntil { statuses.all.count >= emissionsBeforeStandaloneRead + 2 }
        XCTAssertTrue(fellBack, "the restarted pass must publish its own warm-start emission and then a tick")
        XCTAssertEqual(sync.latestState.accountsBalances, retainedBalances, "balances fall back to latestState's")
        XCTAssertEqual(
            sync.latestState.isSpendableMasked,
            initiallyMasked,
            "the fallback emission must carry the flag describing the RETAINED balances, not the standalone read's"
        )

        sync.stop()
    }

    // MARK: - A fresh emission applies and lifts the mask together with its own amounts

    /// A tick with its OWN fresh summary (no fallback involved) must publish balances and a flag
    /// that agree with each other and with `WalletSummary.withSpendableMasked()` — the transform
    /// the [#1591] mask predicate is actually defined by.
    func testFreshEmissionAppliesAndLiftsTheMaskWithItsAmounts() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let fixture = maskMetadataWalletSummary()
        await engine.setNextWalletSummary(fixture)
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100, tipFresh: 0))
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)

        try await sync.start(retry: false)
        let masked = await waitUntil {
            sync.latestState.isSpendableMasked && !sync.latestState.accountsBalances.isEmpty
        }
        XCTAssertTrue(masked, "a stale tip must mask the balances and raise the flag together")
        XCTAssertEqual(
            sync.latestState.accountsBalances,
            fixture.withSpendableMasked().accountBalances,
            "the masked amounts must match the shared mask transform exactly"
        )

        let statuses = RecordedSyncStatuses()
        sync.stateStream.sink { statuses.append($0.internalSyncStatus) }.store(in: &cancellables)
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100, tipFresh: 1))

        let lifted = await waitUntil(timeout: 6) {
            !sync.latestState.isSpendableMasked && !statuses.all.isEmpty
        }
        XCTAssertTrue(lifted, "a fresh tip must lift the mask")
        XCTAssertEqual(
            sync.latestState.accountsBalances,
            fixture.accountBalances,
            "the unmasked amounts must be the summary's own, untransformed"
        )

        sync.stop()
    }

    // MARK: - Status-only and stop emissions never re-derive the mask

    /// The `.stopped` emission and a status-only transition never re-derive the mask: neither one
    /// is publishing a fresh balance read of its own, so both simply carry forward whatever
    /// `latestState.isSpendableMasked` already was.
    func testStatusOnlyAndStopEmissionsKeepMatchingMetadata() async throws {
        let engine = GatedFakeSlipstreamEngine()
        let fixture = maskMetadataWalletSummary()
        await engine.setNextWalletSummary(fixture)
        await engine.setNextSnapshot(SlipstreamSnapshot.testSyncing(progressPermille: 100, tipFresh: 0))
        let sync = try makeSlipstreamSynchronizer(engine: engine)
        await sync.setInternalSyncStatusForTesting(.disconnected)

        try await sync.start(retry: false)
        let masked = await waitUntil {
            sync.latestState.isSpendableMasked && !sync.latestState.accountsBalances.isEmpty
        }
        XCTAssertTrue(masked)
        let maskedBalances = sync.latestState.accountsBalances

        sync.stop()
        let stopped = await waitUntil { sync.latestState.internalSyncStatus == .stopped }
        XCTAssertTrue(stopped)
        XCTAssertTrue(sync.latestState.isSpendableMasked, "the stop emission must carry the mask forward")
        XCTAssertEqual(sync.latestState.accountsBalances, maskedBalances, "and the balances it describes")

        // A status-only transition (no engine call, no balance read at all) must carry the same
        // metadata — it must not silently unmask by defaulting the flag.
        await sync.setInternalSyncStatusForTesting(.disconnected)
        XCTAssertTrue(sync.latestState.isSpendableMasked, "a status-only transition must not silently unmask")
        XCTAssertEqual(sync.latestState.accountsBalances, maskedBalances)
    }
}
