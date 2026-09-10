//
//  SubmitPlanStoreAcceptedTests.swift
//  ZcashLightClientKitTests
//

import SQLite
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class SubmitPlanStoreAcceptedTests: ZcashTestCase {
    private var databaseURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        databaseURL = testGeneralStorageDirectory.appendingPathComponent("submit_plans_accepted_test.db")
    }

    private func makeStore() -> SubmitPlanStore {
        SubmitPlanStore(databaseURL: databaseURL, logger: NullLogger())
    }

    private var endpointA: LightWalletEndpoint {
        LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
    }

    private var endpointB: LightWalletEndpoint {
        LightWalletEndpoint(address: "b.example.com", port: 9067, secure: false)
    }

    func testRecordedPlanIsNotAcceptedYet() async {
        let store = makeStore()
        let txId = Data(repeating: 0x21, count: 32)

        await store.recordPlan(txId: txId, endpoints: [endpointA, endpointB])

        let plan = await store.plan(for: txId)
        XCTAssertEqual(plan, StoredSubmitPlan.ready([endpointA, endpointB], acceptedBy: nil))
    }

    func testMarkAcceptedRecordsTheHostAndKeepsTheEndpoints() async {
        let store = makeStore()
        let txId = Data(repeating: 0x22, count: 32)
        await store.recordPlan(txId: txId, endpoints: [endpointA, endpointB])

        await store.markAccepted(txId: txId, host: "b.example.com:9067", lifecycle: await store.currentLifecycle())

        let plan = await store.plan(for: txId)
        XCTAssertEqual(plan, StoredSubmitPlan.ready([endpointA, endpointB], acceptedBy: "b.example.com:9067"))
    }

    func testMarkAcceptedWithoutAPlanCreatesAnAcceptedRow() async {
        let store = makeStore()
        let txId = Data(repeating: 0x23, count: 32)

        await store.markAccepted(txId: txId, host: "a.example.com:443", lifecycle: await store.currentLifecycle())

        let plan = await store.plan(for: txId)
        XCTAssertEqual(plan, StoredSubmitPlan.ready([], acceptedBy: "a.example.com:443"))
    }

    func testMarkAcceptedAgainRecordsTheLatestHost() async {
        let store = makeStore()
        let txId = Data(repeating: 0x24, count: 32)
        await store.recordPlan(txId: txId, endpoints: [endpointA])
        await store.markAccepted(txId: txId, host: "a.example.com:443", lifecycle: await store.currentLifecycle())

        await store.markAccepted(txId: txId, host: "b.example.com:9067", lifecycle: await store.currentLifecycle())

        // The last server to accept wins; the plan endpoints are untouched.
        let plan = await store.plan(for: txId)
        XCTAssertEqual(plan, StoredSubmitPlan.ready([endpointA], acceptedBy: "b.example.com:9067"))
    }

    func testAcceptanceSurvivesARecordedPlanUpdate() async {
        let store = makeStore()
        let txId = Data(repeating: 0x25, count: 32)
        await store.recordPlan(txId: txId, endpoints: [endpointA])
        await store.markAccepted(txId: txId, host: "a.example.com:443", lifecycle: await store.currentLifecycle())

        // A host that calls `broadcaster.submit` again for a transaction
        // already accepted re-records its plan; that must not clear the
        // acceptance already on file.
        await store.recordPlan(txId: txId, endpoints: [endpointB])

        let plan = await store.plan(for: txId)
        XCTAssertEqual(plan, StoredSubmitPlan.ready([endpointB], acceptedBy: "a.example.com:443"))
    }

    // MARK: - The test double must answer the same way

    /// `SubmitPlanStoringMock` stands in for the store in every suite that exercises submission
    /// and background resubmission, so a divergence here does not fail a test — it quietly makes
    /// the tests that use it assert the wrong contract. Acceptance surviving a re-recorded plan is
    /// the property the store had to be taught (an upsert would have cleared it), which is exactly
    /// the kind a double is written before and then never revisited.
    func testTheTestDoubleAlsoKeepsAcceptanceAcrossARecordedPlanUpdate() async {
        let double = SubmitPlanStoringMock()
        let txId = Data(repeating: 0x27, count: 32)
        await double.recordPlan(txId: txId, endpoints: [endpointA])
        await double.markAccepted(txId: txId, host: "a.example.com:443", lifecycle: await double.currentLifecycle())

        await double.recordPlan(txId: txId, endpoints: [endpointB])

        let plan = await double.plan(for: txId)
        XCTAssertEqual(
            plan,
            StoredSubmitPlan.ready([endpointB], acceptedBy: "a.example.com:443"),
            "the double must report what the store reports for the same two calls"
        )
    }

    // MARK: - Migration of a store written before `accepted_host` existed

    func testStoreWrittenWithoutTheAcceptedHostColumnGainsItOnOpen() async throws {
        let txId = Data(repeating: 0x26, count: 32)
        try makeLegacyDatabase(txId: txId, endpoints: [endpointA])

        let store = makeStore()
        let plan = await store.plan(for: txId)

        XCTAssertEqual(plan, StoredSubmitPlan.ready([endpointA], acceptedBy: nil))

        let connection = try Connection(databaseURL.path)
        XCTAssertTrue(try columnNames(connection).contains("accepted_host"))
        // The column is additive, so older SDK builds must keep reading the same
        // store: the schema version stays where it was.
        let version = try connection.scalar("PRAGMA user_version") as? Int64
        XCTAssertEqual(version, 1)
    }

    func testMigratedStoreCanRecordAcceptance() async throws {
        let txId = Data(repeating: 0x27, count: 32)
        try makeLegacyDatabase(txId: txId, endpoints: [endpointA])

        let store = makeStore()
        await store.markAccepted(txId: txId, host: "a.example.com:443", lifecycle: await store.currentLifecycle())

        let plan = await store.plan(for: txId)
        XCTAssertEqual(plan, StoredSubmitPlan.ready([endpointA], acceptedBy: "a.example.com:443"))
    }

    func testOpeningAnAlreadyMigratedStoreAgainIsANoOp() async throws {
        let txId = Data(repeating: 0x28, count: 32)
        try makeLegacyDatabase(txId: txId, endpoints: [endpointA])

        let firstStore = makeStore()
        _ = await firstStore.plan(for: txId)

        // A second open must not try to add the column again — that would throw
        // "duplicate column name" and disable the store for the whole session.
        let secondStore = makeStore()
        let plan = await secondStore.plan(for: txId)
        XCTAssertEqual(plan, StoredSubmitPlan.ready([endpointA], acceptedBy: nil))

        await secondStore.markAccepted(txId: txId, host: "a.example.com:443", lifecycle: await secondStore.currentLifecycle())
        let accepted = await secondStore.plan(for: txId)
        XCTAssertEqual(accepted, StoredSubmitPlan.ready([endpointA], acceptedBy: "a.example.com:443"))
    }

    // MARK: - Helpers

    /// Builds the table exactly as the store created it before `accepted_host`
    /// existed, with one row already in it.
    private func makeLegacyDatabase(txId: Data, endpoints: [LightWalletEndpoint]) throws {
        let connection = try Connection(databaseURL.path)
        try connection.run(
            """
            CREATE TABLE "tx_submit_plans" ("tx_id" BLOB PRIMARY KEY NOT NULL, "endpoints" TEXT DEFAULT ('[]'))
            """
        )
        try connection.run("PRAGMA user_version = 1")

        let json = endpoints
            .map { endpoint in
                """
                {"host":"\(endpoint.host)","port":\(endpoint.port),"secure":\(endpoint.secure),\
                "singleCallTimeoutInMillis":\(endpoint.singleCallTimeoutInMillis),\
                "streamingCallTimeoutInMillis":\(endpoint.streamingCallTimeoutInMillis)}
                """
            }
            .joined(separator: ",")
        try connection.run(
            "INSERT INTO tx_submit_plans (tx_id, endpoints) VALUES (?, ?)",
            [Blob(bytes: txId.bytes), "[\(json)]"]
        )
    }

    private func columnNames(_ connection: Connection) throws -> [String] {
        try connection.prepare("PRAGMA table_info(tx_submit_plans)").compactMap { row in
            row[1] as? String
        }
    }
}
