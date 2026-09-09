import Foundation
import XCTest
@testable import ZcashLightClientKit
@testable import TestUtils

final class VotingHelperClientTests: XCTestCase {
    func testRoundIDValidatesOnConstructionAndDecoding() throws {
        let value = String(repeating: "01", count: 32)
        let round = try VotingRoundID(validating: value)
        XCTAssertEqual(round.stringEncoded, value)
        XCTAssertEqual(try JSONDecoder().decode(VotingRoundID.self, from: JSONEncoder().encode(round)), round)
        XCTAssertThrowsError(try VotingRoundID(validating: "round"))
        XCTAssertThrowsError(try VotingRoundID(validating: String(repeating: "ff", count: 32)))
        XCTAssertThrowsError(try JSONDecoder().decode(VotingRoundID.self, from: Data("\"bad\"".utf8)))
    }

    func testReportsPreserveUnknownAndUnrecoverableStates() throws {
        let round = String(repeating: "01", count: 32)
        let identity = "{\"delivery\":{\"round_id\":\"\(round)\",\"bundle_index\":2,\"proposal_id\":3},\"share_index\":4}"
        let json = "{\"confirmed\":[\(identity)],\"resubmitted\":[{\"identity\":\(identity),\"server_url\":\"https://accepted.example\"}],\"ambiguous\":[{\"identity\":\(identity),\"server_url\":\"https://unknown.example\"}],\"unrecoverable\":[\(identity)],\"cancelled\":true,\"next_delay_seconds\":17}"
        let report = try JSONDecoder().decode(VotingShareTrackingReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.confirmed.first?.delivery.bundleIndex, 2)
        XCTAssertEqual(report.confirmed.first?.shareIndex, 4)
        XCTAssertEqual(report.resubmitted.first?.serverURL.host, "accepted.example")
        XCTAssertEqual(report.ambiguous.first?.serverURL.host, "unknown.example")
        XCTAssertEqual(report.unrecoverable, report.confirmed)
        XCTAssertTrue(report.cancelled)
        XCTAssertEqual(report.nextDelaySeconds, 17)
        let delivered = try JSONDecoder().decode(VotingShareDeliveryReport.self, from: Data(#"{"deliveries":[{"share_index":4,"accepted_urls":["https://accepted.example"],"ambiguous_urls":["https://unknown.example"],"target_count":2}],"pending_share_indices":[4],"cancelled":false,"placement_guarantee":"legacy_best_effort"}"#.utf8))
        XCTAssertEqual(delivered.deliveries.first?.targetCount, 2)
        XCTAssertEqual(delivered.deliveries.first?.acceptedURLs.count, 1)
        XCTAssertEqual(delivered.deliveries.first?.ambiguousURLs.count, 1)
        XCTAssertEqual(delivered.pendingShareIndices, [4])
        XCTAssertEqual(delivered.placementGuarantee, .legacyBestEffort)
        let confirmation = try JSONDecoder().decode(VotingShareConfirmationReport.self, from: Data(#"{"confirmed":false,"cancelled":true}"#.utf8))
        XCTAssertFalse(confirmation.confirmed)
        XCTAssertTrue(confirmation.cancelled)
    }

    func testPreparedPlacementAndFleetReportsKeepSchedulingMetadata() throws {
        let round = String(repeating: "01", count: 32)
        let json = "{\"identity\":{\"round_id\":\"\(round)\",\"bundle_index\":2,\"proposal_id\":3},\"shares\":[{\"share_index\":0,\"immediate\":true,\"submit_at\":0,\"target_count\":2},{\"share_index\":4,\"immediate\":false,\"submit_at\":1000,\"target_count\":3}],\"placement_guarantee\":\"strict\"}"
        let report = try JSONDecoder().decode(VotingPreparedShareDelivery.self, from: Data(json.utf8))
        XCTAssertEqual(report.identity.bundleIndex, 2)
        XCTAssertEqual(report.shares.map(\.shareIndex), [0, 4])
        XCTAssertEqual(report.shares.map(\.immediate), [true, false])
        XCTAssertEqual(report.shares.map(\.submitAt), [0, 1000])
        XCTAssertEqual(report.shares.map(\.targetCount), [2, 3])
        XCTAssertEqual(report.placementGuarantee, .strict)
        let fleet = try JSONDecoder().decode(VotingHelperFleet.self, from: Data(#"{"configured_urls":["https://one.example","https://two.example"],"ready_urls":["https://two.example"]}"#.utf8))
        XCTAssertEqual(fleet.configuredURLs.count, 2)
        XCTAssertEqual(fleet.readyURLs.first?.host, "two.example")
    }

    func testShareJournalReadPreservesNativeAttemptStatesAndLegacyDefaults() throws {
        let json = #"{"round_id":"round","bundle_index":0,"proposal_id":1,"share_index":2,"sent_to_urls":["https://accepted.example"],"attempting_urls":["https://attempting.example"],"ambiguous_urls":["https://unknown.example"],"target_count":3,"nullifier":"01","confirmed":false,"submit_at":0,"created_at":100}"#
        let value = try JSONDecoder().decode(VotingShareDelegation.self, from: Data(json.utf8))
        let roundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        XCTAssertEqual(roundTrip?["attempting_urls"] as? [String], ["https://attempting.example"])
        XCTAssertEqual(roundTrip?["ambiguous_urls"] as? [String], ["https://unknown.example"])
        XCTAssertEqual(roundTrip?["target_count"] as? Int, 3)
        var legacy = try XCTUnwrap(roundTrip)
        legacy.removeValue(forKey: "attempting_urls")
        legacy.removeValue(forKey: "ambiguous_urls")
        legacy.removeValue(forKey: "target_count")
        let decoded = try JSONDecoder().decode(VotingShareDelegation.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(decoded.attemptingURLs.isEmpty)
        XCTAssertTrue(decoded.ambiguousURLs.isEmpty)
        XCTAssertEqual(decoded.targetCount, 0)
    }

    func testConfigurationPreservesNativeDefaultTimingPolicy() throws {
        let round = try VotingRoundID(validating: String(repeating: "01", count: 32))
        let configuration = VotingHelperRoundConfiguration(
            roundID: round,
            helperURLs: [URL(string: "https://helper.example")!],
            proposalIDs: [1, 2],
            voteEndTime: nil,
            lastMomentBuffer: nil
        )
        let decoded = try JSONDecoder().decode(
            VotingHelperRoundConfiguration.self,
            from: JSONEncoder().encode(configuration)
        )
        XCTAssertEqual(decoded, configuration)
        XCTAssertNil(decoded.lastMomentBuffer)
        XCTAssertNil(decoded.voteEndTime)
        for decision in [VotingBallotDecision.choice(2), VotingBallotDecision.skipped] {
            XCTAssertEqual(try JSONDecoder().decode(VotingBallotDecision.self, from: JSONEncoder().encode(decision)), decision)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(VotingBallotDecision.self, from: Data(#"{"skipped":false}"#.utf8)))
    }

    func testNativeClientsRetainTheirWalletScopeAfterPrimaryChangesAndCloses() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = VotingRustBackend()
        try backend.open(path: directory.appendingPathComponent("voting.sqlite").path, networkId: 1)
        let round = try VotingRoundID(validating: String(repeating: "01", count: 32))
        func prepareWallet(_ wallet: String) throws {
            try backend.setWalletId(wallet)
            try backend.initRound(roundId: round.stringEncoded, snapshotHeight: 1000,
                                  eaPublicKey: Array(repeating: 7, count: 32), ncRoot: Array(repeating: 8, count: 32),
                                  nullifierImtRoot: Array(repeating: 9, count: 32))
        }
        try prepareWallet("first")
        let first = try await backend.makeHelperClient(transport: .direct)
        try prepareWallet("second")
        let second = try await backend.makeHelperClient(transport: .direct)
        backend.close()
        try await first.setBallotIntents(roundID: round, intents: [VotingBallotIntent(proposalID: 1, numOptions: 3, decision: .choice(2))])
        try await second.setBallotIntents(roundID: round, intents: [VotingBallotIntent(proposalID: 1, numOptions: 3, decision: .skipped)])
        let firstIntents = try await first.ballotIntents(roundID: round)
        let secondIntents = try await second.ballotIntents(roundID: round)
        XCTAssertEqual(firstIntents[1], .choice(2))
        XCTAssertEqual(secondIntents[1], .skipped)
        await first.cancelAndWait()
        await second.cancelAndWait()
    }

    func testClosedClientRejectsCalls() async throws {
        let driver = GatedHelperDriver()
        let client = VotingHelperClient(driver: driver)
        await client.cancelAndWait()
        driver.release.signal()
        do {
            _ = try await client.preflightFleet(urls: [URL(string: "https://helper.example")!])
            XCTFail("closed clients must reject new leases")
        } catch {}
        XCTAssertEqual(driver.leaseCount, 0)
    }

    func testTwoHelperOperationsCanRemainPendingIndependently() async throws {
        let driver = GatedHelperDriver()
        let client = VotingHelperClient(driver: driver)
        let first = Task { try await client.preflightFleet(urls: []) }
        let second = Task { try await client.preflightFleet(urls: []) }
        await driver.bothEntered.wait()
        XCTAssertEqual(driver.leaseCount, 2)
        let close = Task {
            await client.cancelAndWait()
            XCTAssertEqual(driver.returnCount, 2, "join must wait for both native returns")
        }
        await driver.cancelled.wait()
        driver.release.signal()
        driver.release.signal()
        _ = await first.result
        _ = await second.result
        await close.value
    }

    func testCancelWaitsForRetainedOperationAndPrimaryWorkProceeds() async throws {
        let backend = VotingRustBackend()
        try backend.open(path: ":memory:", networkId: 1)
        try backend.setWalletId("primary-wallet")
        defer { backend.close() }
        let driver = GatedHelperDriver()
        let client = VotingHelperClient(driver: driver)
        let work = Task { try await client.preflightFleet(urls: [URL(string: "https://helper.example")!]) }
        await driver.entered.wait()
        XCTAssertNoThrow(try backend.setWalletId("primary-still-available"))
        let close = Task {
            await client.cancelAndWait()
            XCTAssertTrue(driver.returned, "join must wait for the native return")
        }
        await driver.cancelled.wait()
        XCTAssertFalse(driver.returned)
        do {
            _ = try await client.preflightFleet(urls: [URL(string: "https://helper.example")!])
            XCTFail("cancel must fence new calls before join")
        } catch {}
        driver.release.signal()
        _ = await work.result
        await close.value
        XCTAssertTrue(driver.returned)
    }
}

private actor HelperSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

private final class GatedHelperDriver: VotingHelperDriving, VotingHelperOperationDriving, @unchecked Sendable {
    let entered = HelperSignal()
    let bothEntered = HelperSignal()
    let cancelled = HelperSignal()
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var leases = 0
    private var executions = 0
    private var finished = 0
    var leaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return leases
    }
    var returned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished > 0
    }
    var returnCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
    func acquire() throws -> any VotingHelperOperationDriving {
        lock.lock()
        leases += 1
        lock.unlock()
        return self
    }
    func cancel() { Task { await cancelled.signal() } }
    func execute(_ request: Data) throws -> Data {
        lock.lock()
        executions += 1
        let bothStarted = executions == 2
        lock.unlock()
        Task {
            await entered.signal()
            if bothStarted { await bothEntered.signal() }
        }
        release.wait()
        lock.lock()
        finished += 1
        lock.unlock()
        return Data(#"{"configured_urls":["https://helper.example"],"ready_urls":[]}"#.utf8)
    }
}

final class VotingHelperSynchronizerTests: XCTestCase {
    func testPublicSynchronizersCreateDirectHelperAndRefuseDisabledTor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = VotingRustBackend()
        try backend.open(path: directory.appendingPathComponent("voting.sqlite").path, networkId: 1)
        try backend.setWalletId("wallet")
        defer { backend.close() }
        for useSlipstream in [false, true] {
            let initializer = Initializer(
                cacheDbURL: nil,
                fsBlockDbRoot: directory.appendingPathComponent("blocks"),
                generalStorageURL: directory.appendingPathComponent("general"),
                dataDbURL: directory.appendingPathComponent("wallet.sqlite"),
                torDirURL: directory.appendingPathComponent("tor"),
                endpoint: LightWalletEndpointBuilder.default,
                network: ZcashNetworkBuilder.network(for: .mainnet),
                spendParamsURL: directory.appendingPathComponent("spend"),
                outputParamsURL: directory.appendingPathComponent("output"),
                saplingParamsSourceURL: .default,
                isTorEnabled: false,
                isExchangeRateEnabled: false
            )
            let synchronizer: any Synchronizer = useSlipstream
                ? SlipstreamSynchronizer(initializer: initializer)
                : SDKSynchronizer(initializer: initializer)
            let helper = try await synchronizer.makeVotingHelperClient(for: backend, route: .direct)
            await helper.cancelAndWait()
            do {
                _ = try await synchronizer.makeVotingHelperClient(for: backend, route: .tor)
                XCTFail("disabled Tor must fail without creating a direct helper")
            } catch {
                XCTAssertEqual((error as? ZcashError)?.code, ZcashError.torNotEnabled.code)
            }
        }
    }
}
