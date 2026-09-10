//
//  SubmitPlanStoreWipeRaceTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

/// A server acceptance for a submission that started before `wipe()` must not recreate the
/// deleted submit-plan store. `wipe()` retires the store's current lifecycle token before it
/// touches the connection or the file, so a `markAccepted` call still carrying the retired token —
/// a foreground submission's network race that was in flight when the wipe landed — is recognized
/// as stale and dropped instead of reopening (and thereby recreating) the database.
final class SubmitPlanStoreWipeRaceTests: ZcashTestCase {
    private var databaseURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        databaseURL = testGeneralStorageDirectory.appendingPathComponent("submit_plans_wipe_race_test.db")
    }

    private func makeStore() -> SubmitPlanStore {
        SubmitPlanStore(databaseURL: databaseURL, logger: NullLogger())
    }

    private var endpointA: LightWalletEndpoint {
        LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
    }

    private var txId: Data { Data(repeating: 0x31, count: 32) }
    private var otherTxId: Data { Data(repeating: 0x32, count: 32) }

    func testAcceptanceFromBeforeAWipeDoesNotRecreateTheStore() async throws {
        let store = makeStore()
        let lifecycle = await store.recordPlan(txId: txId, endpoints: [endpointA])
        await store.wipe()
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))

        await store.markAccepted(txId: txId, host: "a.example.com:443", lifecycle: lifecycle)

        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path), "a pre-wipe acceptance must not recreate the deleted store")
        let plan = await store.plan(for: txId)
        XCTAssertNil(plan)
    }

    func testNewLifecycleAfterWipeRecordsAcceptanceNormally() async throws {
        let store = makeStore()
        _ = await store.recordPlan(txId: txId, endpoints: [endpointA])
        await store.wipe()
        let fresh = await store.recordPlan(txId: otherTxId, endpoints: [endpointA])
        await store.markAccepted(txId: otherTxId, host: "a.example.com:443", lifecycle: fresh)
        let freshPlan = await store.plan(for: otherTxId)
        XCTAssertEqual(freshPlan, StoredSubmitPlan.ready([endpointA], acceptedBy: "a.example.com:443"))
        let stalePlan = await store.plan(for: txId)
        XCTAssertNil(stalePlan, "old metadata must not enter the new lifecycle")
    }

    // MARK: - A release for resubmission landing after wipe() must not recreate the store

    /// A host's release-for-resubmission call for a transaction created before a `wipe()` must not
    /// recreate `submit_plans.db`: unlike `recordPlan`, `recordPlanForAwaitingTransaction` checks
    /// for an existing file (via `existingConnection()`) before ever reaching `connection()`, so a
    /// release racing a wipe finds the file already gone and drops the write instead of
    /// resurrecting the deleted store.
    func testReleaseForResubmissionAfterWipeDoesNotRecreateTheStore() async throws {
        let store = makeStore()
        _ = await store.recordPlan(txId: txId, endpoints: [endpointA])
        await store.wipe()
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))

        let lifecycle = await store.recordPlanForAwaitingTransaction(txId: txId, endpoints: [endpointA])

        XCTAssertNil(lifecycle, "a release landing after wipe must report nothing recorded")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: databaseURL.path),
            "a release landing after wipe must not recreate the deleted store"
        )
        let plan = await store.plan(for: txId)
        XCTAssertNil(plan)
    }

    /// The ordinary case: a transaction the host already created (so the store has its `.awaiting`
    /// row, and therefore its backing file) is released for resubmission normally.
    func testReleaseForResubmissionRecordsPlanWhenStoreExists() async throws {
        let store = makeStore()
        let initialLifecycle = await store.currentLifecycle()
        await store.markAwaitingSubmission(txIds: [txId], lifecycle: initialLifecycle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path), "the awaiting mark already created the file")

        let lifecycle = await store.recordPlanForAwaitingTransaction(txId: txId, endpoints: [endpointA])

        XCTAssertNotNil(lifecycle, "an existing store records the release normally")
        let plan = await store.plan(for: txId)
        XCTAssertEqual(plan, StoredSubmitPlan.ready([endpointA], acceptedBy: nil))
    }

    // MARK: - Reads must never recreate a wiped store

    /// `transactionSubmissionStatus` (via `plan(for:)`) must answer "no row" for a wiped store
    /// without reopening it: unlike a write, a read has nothing to persist, so recreating the file
    /// only to find it empty would resurrect a database the host already asked to delete.
    func testAStatusReadAfterWipeDoesNotRecreateTheStoreFile() async throws {
        let store = makeStore()
        let lifecycle = await store.currentLifecycle()
        await store.markAwaitingSubmission(txIds: [txId], lifecycle: lifecycle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))

        await store.wipe()
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))

        let plan = await store.plan(for: txId)
        XCTAssertNil(plan, "a read on a wiped store answers 'no row', it must not report the store unavailable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path), "a read must never recreate a wiped store")
    }

    /// A release that lands after a wipe *and* after the store has legitimately reopened for a
    /// new-lifecycle transaction must still refuse the old transaction: the file existing again is
    /// not enough, because that other transaction's awaiting row is the only thing that proves a
    /// release belongs to the current lifecycle.
    func testADelayedReleaseAfterWipeAndReopenRecordsNothing() async throws {
        let store = makeStore()
        let g0 = await store.currentLifecycle()
        await store.markAwaitingSubmission(txIds: [txId], lifecycle: g0)
        await store.wipe()

        // A new-lifecycle transaction reopens the store legitimately.
        let g1 = await store.currentLifecycle()
        await store.markAwaitingSubmission(txIds: [otherTxId], lifecycle: g1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))

        let released = await store.recordPlanForAwaitingTransaction(txId: txId, endpoints: [endpointA])
        XCTAssertNil(released, "a transaction created before the wipe has no awaiting row and must not be released")
        let staleReadback = await store.plan(for: txId)
        XCTAssertNil(staleReadback)
        let ids = await store.allPlannedTransactionIds()
        XCTAssertFalse(ids.contains(txId))

        // The current lifecycle's own transaction still releases.
        let releasedOther = await store.recordPlanForAwaitingTransaction(txId: otherTxId, endpoints: [endpointA])
        XCTAssertNotNil(releasedOther)
        let otherReadback = await store.plan(for: otherTxId)
        XCTAssertEqual(otherReadback, StoredSubmitPlan.ready([endpointA], acceptedBy: nil))
    }
}
