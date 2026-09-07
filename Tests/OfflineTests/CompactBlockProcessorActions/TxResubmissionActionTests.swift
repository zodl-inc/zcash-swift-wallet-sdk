//
//  TxResubmissionActionTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class TxResubmissionActionTests: ZcashTestCase {
    private var transactionRepository: TransactionRepositoryMock!
    private var transactionEncoder: StubTransactionEncoder!
    private var submitPlanStore: SubmitPlanStoringMock!
    private var endpointSubmitter: EndpointSubmitterMock!

    private let latestBlockHeight = BlockHeight(2_000_000)

    private var endpointA: LightWalletEndpoint {
        LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
    }

    private func makeOverview(
        rawID: Data,
        minedHeight: BlockHeight? = nil,
        expiryHeight: BlockHeight? = 3_000_000
    ) -> ZcashTransaction.Overview {
        ZcashTransaction.Overview(
            accountUUID: TestsData.mockedAccountUUID,
            blockTime: nil,
            expiryHeight: expiryHeight,
            fee: Zatoshi(10_000),
            index: 0,
            isShielding: false,
            hasChange: false,
            memoCount: 0,
            minedHeight: minedHeight,
            raw: Data([0x01, 0x02, 0x03]),
            rawID: rawID,
            receivedNoteCount: 0,
            sentNoteCount: 1,
            value: Zatoshi(-1_000),
            isExpiredUmined: false,
            totalSpent: nil,
            totalReceived: nil,
            spentNoteCount: 0,
            poolCrossingValue: nil,
            isTrusted: false,
            zip318Kind: .notClassified
        )
    }

    private func setupAction(
        candidates: [ZcashTransaction.Overview],
        encoderTransactions: [ZcashTransaction.Overview] = [],
        submitPlanStoreOverride: SubmitPlanStoring? = nil
    ) -> TxResubmissionAction {
        transactionRepository = TransactionRepositoryMock()
        transactionRepository.findForResubmissionUpToClosure = { _ in candidates }
        transactionEncoder = StubTransactionEncoder(createdTransactions: encoderTransactions)
        submitPlanStore = SubmitPlanStoringMock()
        endpointSubmitter = EndpointSubmitterMock()

        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in self.transactionRepository }
        mockContainer.mock(type: TransactionEncoder.self, isSingleton: true) { _ in self.transactionEncoder }
        // A real `SubmitPlanStore` can be substituted for the double, for tests that need the
        // real read/latch behavior `SubmitPlanStoringMock` does not reproduce.
        mockContainer.mock(type: SubmitPlanStoring.self, isSingleton: true) { _ in submitPlanStoreOverride ?? self.submitPlanStore }
        mockContainer.mock(type: Logger.self, isSingleton: true) { _ in submissionLifecycleLogger() }
        mockContainer.mock(type: SubmitPlanExecutor.self, isSingleton: true) { _ in
            SubmitPlanExecutor(endpointSubmitter: self.endpointSubmitter, logger: submissionLifecycleLogger())
        }

        let action = TxResubmissionAction(container: mockContainer)
        // Push the throttle back so tests exercise the resubmit branch.
        // The first-invocation throttle is covered by its own test.
        action.latestResolvedTime = 0
        return action
    }

    private func makeContext() -> ActionContextMock {
        let context = ActionContextMock.default()
        context.prevState = .enhance
        context.underlyingSyncControlData = SyncControlData(
            latestBlockHeight: latestBlockHeight,
            latestScannedHeight: nil,
            firstUnenhancedHeight: nil
        )
        return context
    }

    func testAwaitingTransactionIsSkipped() async throws {
        let rawID = Data(repeating: 0x01, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])
        await submitPlanStore.markAwaitingSubmission(txIds: [rawID], lifecycle: await submitPlanStore.currentLifecycle())
        // Make the repository confirm the candidate is alive so pruning keeps it.
        transactionRepository.findRawIDClosure = { _ in candidate }

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertTrue(transactionEncoder.submittedTransactions.isEmpty, "Awaiting transactions must not be submitted")
        XCTAssertTrue(endpointSubmitter.recordedSubmissions().isEmpty)
        let plan = await submitPlanStore.plan(for: rawID)
        XCTAssertEqual(plan, StoredSubmitPlan.awaiting, "Awaiting plan must survive")
    }

    func testReadyTransactionIsResubmittedThroughPlanEndpoints() async throws {
        let rawID = Data(repeating: 0x02, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])
        await submitPlanStore.recordPlan(txId: rawID, endpoints: [endpointA])
        transactionRepository.findRawIDClosure = { _ in candidate }

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertEqual(endpointSubmitter.recordedSubmissions().map(\.host), ["a.example.com"])
        XCTAssertTrue(transactionEncoder.submittedTransactions.isEmpty, "Plan transactions must not use the default endpoint")
    }

    func testAcceptedTransactionIsStillResubmittedThroughItsPlan() async throws {
        let rawID = Data(repeating: 0x12, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])
        await submitPlanStore.recordPlan(txId: rawID, endpoints: [endpointA])
        await submitPlanStore.markAccepted(txId: rawID, host: "x.example.com:1", lifecycle: await submitPlanStore.currentLifecycle())
        transactionRepository.findRawIDClosure = { _ in candidate }

        _ = try await action.run(with: makeContext()) { _ in }

        // A server holding the transaction in its mempool is not a guarantee it
        // will be mined, so retrying continues exactly as for any ready plan.
        XCTAssertEqual(endpointSubmitter.recordedSubmissions().map(\.host), ["a.example.com"])
        XCTAssertTrue(transactionEncoder.submittedTransactions.isEmpty, "Plan transactions must not use the default endpoint")
    }

    func testResubmissionRecordsTheServerThatAcceptedTheTransaction() async throws {
        let rawID = Data(repeating: 0x13, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])
        await submitPlanStore.recordPlan(txId: rawID, endpoints: [endpointA])
        transactionRepository.findRawIDClosure = { _ in candidate }

        _ = try await action.run(with: makeContext()) { _ in }

        let plan = await submitPlanStore.plan(for: rawID)
        XCTAssertEqual(plan, StoredSubmitPlan.ready([endpointA], acceptedBy: "a.example.com:443"))
    }

    // MARK: - Release for resubmission

    /// A transaction created through `Broadcaster` but never submitted by the app (`.awaiting`)
    /// and then released to background resubmission (mirroring
    /// `Broadcaster.releaseForResubmission(transactions:to:)`, which records the plan the same way
    /// `recordPlan` does here) is picked up and broadcast through the released endpoint on the
    /// very next resubmission pass.
    func testResubmitterBroadcastsAReleasedTransaction() async throws {
        let rawID = Data(repeating: 0x14, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])
        transactionRepository.findRawIDClosure = { _ in candidate }

        // Mirrors what `finishCreation` does for a transaction created through `Broadcaster`.
        await submitPlanStore.markAwaitingSubmission(txIds: [rawID], lifecycle: await submitPlanStore.currentLifecycle())
        let awaitingPlan = await submitPlanStore.plan(for: rawID)
        XCTAssertEqual(awaitingPlan, StoredSubmitPlan.awaiting)

        // Mirrors `Broadcaster.releaseForResubmission(transactions:to:)`: records the plan without
        // attempting network submission, moving the transaction from `.awaiting` to `.ready`.
        await submitPlanStore.recordPlan(txId: rawID, endpoints: [endpointA])
        let releasedPlan = await submitPlanStore.plan(for: rawID)
        XCTAssertEqual(releasedPlan, StoredSubmitPlan.ready([endpointA], acceptedBy: nil))
        XCTAssertTrue(endpointSubmitter.recordedSubmissions().isEmpty, "Release must not itself submit")

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertEqual(endpointSubmitter.recordedSubmissions().map(\.host), ["a.example.com"])
        XCTAssertTrue(transactionEncoder.submittedTransactions.isEmpty, "Released transactions must not use the default endpoint")
    }

    // MARK: - Wipe race: a late acceptance for a resubmission started before wipe()

    /// A `wipe()` that lands while a background resubmission's network call is parked must drop
    /// the eventual acceptance, exactly like the equivalent guard on a foreground `submit`
    /// (`BroadcasterTests.testWipeDuringSubmissionDropsALateAcceptance`).
    func testWipeParkedDuringResubmissionDropsTheAcceptance() async throws {
        let rawID = Data(repeating: 0x15, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])
        transactionRepository.findRawIDClosure = { _ in candidate }
        await submitPlanStore.recordPlan(txId: rawID, endpoints: [endpointA])

        let gate = Gate()
        endpointSubmitter.set(behavior: .gated(gate, then: .succeed), for: endpointA)

        let resubmission = Task {
            _ = try await action.run(with: makeContext()) { _ in }
        }
        await endpointSubmitter.awaitSubmissionStarted(to: endpointA)

        // The plan has already been read as `.ready` and the submission is parked in the
        // executor; a wipe landing now must not let the eventual acceptance recreate state for a
        // transaction the caller already asked to forget.
        await submitPlanStore.wipe()
        gate.open()

        try await resubmission.value

        XCTAssertEqual(submitPlanStore.wipeCallsCount, 1)
        let plan = await submitPlanStore.plan(for: rawID)
        XCTAssertNil(plan, "A wipe landing mid-resubmission must not be undone by a late acceptance")
    }

    /// Narrower than the above: the wipe lands not during the network round trip but in the
    /// single actor-hop gap between `plan(for:)` returning its (pre-wipe) `.ready` value and
    /// `resubmit` acting on it. A lifecycle token captured only after `plan(for:)` returns could
    /// already reflect the post-wipe generation here, wrongly matching the store's generation at
    /// `markAccepted` time — which is exactly why `resubmit` captures its token before the read,
    /// not merely before the network call.
    func testWipeParkedDuringPlanReadCatchesAWipeInsideTheRead() async throws {
        let rawID = Data(repeating: 0x16, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])
        transactionRepository.findRawIDClosure = { _ in candidate }
        await submitPlanStore.recordPlan(txId: rawID, endpoints: [endpointA])

        let gate = Gate()
        submitPlanStore.planReadGate = gate

        let resubmission = Task {
            _ = try await action.run(with: makeContext()) { _ in }
        }

        // `plan(for:)` has already computed its (pre-wipe) `.ready` result and is parked before
        // returning it; wipe while that read is still in flight.
        await submitPlanStore.awaitPlanReadStarted()
        await submitPlanStore.wipe()
        gate.open()

        try await resubmission.value

        XCTAssertEqual(submitPlanStore.wipeCallsCount, 1)
        XCTAssertEqual(endpointSubmitter.recordedSubmissions().map(\.host), ["a.example.com"], "the stale read is still resubmitted")
        let plan = await submitPlanStore.plan(for: rawID)
        XCTAssertNil(plan, "A wipe landing while the plan was being read must not be undone by the acceptance that read produced")
    }

    func testLegacyTransactionUsesDefaultEncoderSubmit() async throws {
        let rawID = Data(repeating: 0x03, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertEqual(transactionEncoder.submittedTransactions.count, 1)
        XCTAssertEqual(transactionEncoder.submittedTransactions.first?.transactionId, rawID)
        XCTAssertTrue(endpointSubmitter.recordedSubmissions().isEmpty)
    }

    func testPruningRemovesExpiredMissingAndNilExpiryPlansButKeepsMinedUntilExpiry() async throws {
        let minedUnexpiredTxId = Data(repeating: 0x04, count: 32)
        let expiredTxId = Data(repeating: 0x05, count: 32)
        let minedExpiredTxId = Data(repeating: 0x0B, count: 32)
        let missingTxId = Data(repeating: 0x06, count: 32)
        let nilExpiryTxId = Data(repeating: 0x08, count: 32)
        let aliveTxId = Data(repeating: 0x07, count: 32)

        let action = setupAction(candidates: [])
        await submitPlanStore.recordPlan(txId: minedUnexpiredTxId, endpoints: [endpointA])
        await submitPlanStore.recordPlan(txId: expiredTxId, endpoints: [endpointA])
        await submitPlanStore.recordPlan(txId: minedExpiredTxId, endpoints: [endpointA])
        await submitPlanStore.recordPlan(txId: missingTxId, endpoints: [endpointA])
        await submitPlanStore.recordPlan(txId: nilExpiryTxId, endpoints: [endpointA])
        await submitPlanStore.recordPlan(txId: aliveTxId, endpoints: [endpointA])

        transactionRepository.findRawIDClosure = { rawID in
            if rawID == minedUnexpiredTxId {
                return self.makeOverview(rawID: rawID, minedHeight: 1_999_000)
            }
            if rawID == expiredTxId {
                return self.makeOverview(rawID: rawID, expiryHeight: 1_999_999)
            }
            if rawID == minedExpiredTxId {
                return self.makeOverview(rawID: rawID, minedHeight: 1_999_000, expiryHeight: 1_999_999)
            }
            if rawID == missingTxId {
                throw ZcashError.transactionRepositoryEntityNotFound
            }
            if rawID == nilExpiryTxId {
                return self.makeOverview(rawID: rawID, expiryHeight: nil)
            }
            return self.makeOverview(rawID: rawID)
        }

        _ = try await action.run(with: makeContext()) { _ in }

        let remaining = await submitPlanStore.allPlannedTransactionIds()
        // The mined-but-unexpired plan survives: a reorg could un-mine the
        // transaction, and its retries must still use the recorded endpoints.
        XCTAssertEqual(Set(remaining), Set([aliveTxId, minedUnexpiredTxId]))
    }

    func testStoreUnavailableSkipsResubmission() async throws {
        let rawID = Data(repeating: 0x0C, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])
        submitPlanStore.storeUnavailable = true
        transactionRepository.findRawIDClosure = { _ in candidate }

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertTrue(
            transactionEncoder.submittedTransactions.isEmpty,
            "An unreadable plan store must not fall back to the default-endpoint submit"
        )
        XCTAssertTrue(endpointSubmitter.recordedSubmissions().isEmpty)
    }

    /// A submit-plan store whose creation failed must report `.storeUnavailable` to the
    /// resubmitter, not `nil`: `nil` reads as "legacy transaction unknown to this store" and falls
    /// through to the default-endpoint submit below, broadcasting through an endpoint the user
    /// never chose. Uses a real `SubmitPlanStore` (not the double `testStoreUnavailableSkipsResubmission`
    /// uses above) so the store's actual latch behavior — not just the resubmitter's handling of an
    /// already-`.storeUnavailable` plan — is under test.
    func testStoreCreationFailureSkipsResubmissionInsteadOfLegacyBroadcast() async throws {
        let rawID = Data(repeating: 0x17, count: 32)
        let candidate = makeOverview(rawID: rawID)

        // A regular FILE where the store's parent directory should be, exactly like
        // `SubmitPlanStoreTests.testFailedCreationBeforeFileExistsReportsStoreUnavailable`:
        // creation fails and latches `connectionFailed` before the database file is ever written.
        let blockedParent = testGeneralStorageDirectory
            .appendingPathComponent("blocked-parent-\(UUID().uuidString)")
        try Data([1]).write(to: blockedParent)
        defer {
            try? FileManager.default.removeItem(at: blockedParent)
        }
        let realStore = SubmitPlanStore(
            databaseURL: blockedParent.appendingPathComponent("submit_plans.db"),
            logger: NullLogger()
        )
        let action = setupAction(candidates: [candidate], submitPlanStoreOverride: realStore)
        transactionRepository.findRawIDClosure = { _ in candidate }

        // Mirrors what `finishCreation` does for a transaction created through `Broadcaster`: the
        // insert fails because the parent directory is blocked, latching `connectionFailed`.
        await realStore.markAwaitingSubmission(txIds: [rawID], lifecycle: await realStore.currentLifecycle())

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertTrue(
            transactionEncoder.submittedTransactions.isEmpty,
            "A submit-plan store whose creation failed must not fall back to the default-endpoint submit"
        )
        XCTAssertTrue(endpointSubmitter.recordedSubmissions().isEmpty)
    }

    func testOneFailingPlanDoesNotStarveOtherCandidates() async throws {
        let planTxId = Data(repeating: 0x0D, count: 32)
        let legacyTxId = Data(repeating: 0x0E, count: 32)
        let planCandidate = makeOverview(rawID: planTxId)
        let legacyCandidate = makeOverview(rawID: legacyTxId)
        let action = setupAction(candidates: [planCandidate, legacyCandidate])
        await submitPlanStore.recordPlan(txId: planTxId, endpoints: [endpointA])
        endpointSubmitter.set(behavior: .failTransport, for: endpointA)
        transactionRepository.findRawIDClosure = { rawID in
            rawID == planTxId ? planCandidate : legacyCandidate
        }

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertEqual(
            transactionEncoder.submittedTransactions.map(\.transactionId),
            [legacyTxId],
            "A failing plan retry must not abort resubmission of the remaining candidates"
        )
    }

    func testNoCandidatesStillPrunes() async throws {
        let staleTxId = Data(repeating: 0x09, count: 32)
        let action = setupAction(candidates: [])
        await submitPlanStore.recordPlan(txId: staleTxId, endpoints: [endpointA])
        transactionRepository.findRawIDClosure = { _ in
            throw ZcashError.transactionRepositoryEntityNotFound
        }

        _ = try await action.run(with: makeContext()) { _ in }

        let remaining = await submitPlanStore.allPlannedTransactionIds()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testPruningKeepsViewInvisibleUnexpiredWalletStoreTransaction() async throws {
        let txId = Data(repeating: 0x10, count: 32)
        let walletStoreTransaction = makeOverview(rawID: txId, expiryHeight: latestBlockHeight + 1)
        let action = setupAction(candidates: [], encoderTransactions: [walletStoreTransaction])
        await submitPlanStore.recordPlan(txId: txId, endpoints: [endpointA])
        transactionRepository.findRawIDClosure = { _ in
            throw ZcashError.transactionRepositoryEntityNotFound
        }

        _ = try await action.run(with: makeContext()) { _ in }

        let remaining = await submitPlanStore.allPlannedTransactionIds()
        XCTAssertEqual(remaining, [txId])
    }

    func testPruningRemovesViewInvisibleExpiredWalletStoreTransaction() async throws {
        let txId = Data(repeating: 0x11, count: 32)
        let walletStoreTransaction = makeOverview(rawID: txId, expiryHeight: latestBlockHeight)
        let action = setupAction(candidates: [], encoderTransactions: [walletStoreTransaction])
        await submitPlanStore.recordPlan(txId: txId, endpoints: [endpointA])
        transactionRepository.findRawIDClosure = { _ in
            throw ZcashError.transactionRepositoryEntityNotFound
        }

        _ = try await action.run(with: makeContext()) { _ in }

        let remaining = await submitPlanStore.allPlannedTransactionIds()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testFreshActionThrottlesFirstInvocation() async throws {
        let rawID = Data(repeating: 0x0F, count: 32)
        let candidate = makeOverview(rawID: rawID)
        let action = setupAction(candidates: [candidate])
        // Undo the test-only push: a freshly constructed action should not
        // resubmit on its first invocation, even when candidates are present.
        action.latestResolvedTime = Date().timeIntervalSince1970
        transactionRepository.findRawIDClosure = { _ in candidate }

        _ = try await action.run(with: makeContext()) { _ in }

        XCTAssertTrue(
            transactionEncoder.submittedTransactions.isEmpty,
            "Fresh action must not resubmit before the throttle window elapses"
        )
        XCTAssertTrue(endpointSubmitter.recordedSubmissions().isEmpty)
    }

    func testUnknownRepositoryErrorKeepsPlanDuringPruning() async throws {
        struct TransientDatabaseError: Error {}
        let txId = Data(repeating: 0x0A, count: 32)
        let action = setupAction(candidates: [])
        await submitPlanStore.recordPlan(txId: txId, endpoints: [endpointA])
        transactionRepository.findRawIDClosure = { _ in
            throw TransientDatabaseError()
        }

        _ = try await action.run(with: makeContext()) { _ in }

        let remaining = await submitPlanStore.allPlannedTransactionIds()
        XCTAssertEqual(remaining, [txId], "A transient repository error must not prune a live retry plan")
    }
}
