//
//  SubmitPlanStoreWipeRaceTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

/// [R11] A server acceptance for a submission that started before `wipe()` must not recreate the
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
}
