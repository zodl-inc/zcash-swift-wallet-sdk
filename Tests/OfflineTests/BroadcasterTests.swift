//
//  BroadcasterTests.swift
//  ZcashLightClientKitTests
//

import Combine
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

final class BroadcasterTests: ZcashTestCase {
    private var cancellables: [AnyCancellable] = []

    override func setUp() async throws {
        try await super.setUp()
        cancellables = []
    }

    override func tearDown() async throws {
        cancellables = []
        try await super.tearDown()
    }

    // MARK: - Create

    func testCreateProposedTransactionsReturnsCreatedTransactionsAndEmitsEvent() async throws {
        let rawTransaction = Data([0x01, 0x02, 0x03, 0x04])
        let rawID = Data(repeating: 0xAB, count: 32)
        let overviews = [makeTransaction(raw: rawTransaction, rawID: rawID)]
        let transactionEncoder = StubTransactionEncoder(createdTransactions: overviews)
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)

        let foundTransactionsExpectation = XCTestExpectation(description: "found transactions event")
        synchronizer.eventStream
            .sink { event in
                guard case let .foundTransactions(transactions, range) = event else { return }
                XCTAssertNil(range)
                XCTAssertEqual(transactions.map(\.rawID), [rawID])
                foundTransactionsExpectation.fulfill()
            }
            .store(in: &cancellables)

        await synchronizer.updateStatus(.stopped)

        let proposal = Proposal.testOnlyFakeProposal(totalFee: 10)
        let spendingKey = TestsData(networkType: .testnet).spendingKey

        let transactions = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: proposal,
            spendingKey: spendingKey
        )

        XCTAssertEqual(transactions.map(\.txId), [rawID])
        XCTAssertEqual(transactions.map(\.raw), [rawTransaction])
        await fulfillment(of: [foundTransactionsExpectation], timeout: 1.0)
    }

    func testCreateProposedTransactionsContinuesWhenHistoryViewDoesNotContainCreatedTransaction() async throws {
        let rawTransaction = Data([0x01, 0x02, 0x03, 0x04])
        let rawID = Data(repeating: 0xAB, count: 32)
        let overviews = [makeTransaction(raw: rawTransaction, rawID: rawID)]
        let transactionEncoder = StubTransactionEncoder(
            createdTransactions: overviews,
            fetchError: ZcashError.transactionRepositoryEntityNotFound
        )
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        let transactions = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )

        XCTAssertEqual(transactions.map(\.txId), [rawID])
        XCTAssertEqual(transactions.map(\.raw), [rawTransaction])

        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plan = await store.plan(for: rawID)
        XCTAssertEqual(plan, StoredSubmitPlan.awaiting)
    }

    func testCreateProposedTransactionsContinuesWhenHistoryEnrichmentThrowsAnotherError() async throws {
        struct TransientHistoryError: Error {}
        let rawTransaction = Data([0x01, 0x02, 0x03, 0x04])
        let rawID = Data(repeating: 0xAC, count: 32)
        let transactionEncoder = StubTransactionEncoder(
            createdTransactions: [makeTransaction(raw: rawTransaction, rawID: rawID)],
            fetchError: TransientHistoryError()
        )
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        let transactions = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )

        XCTAssertEqual(transactions, [CreatedTransaction(txId: rawID, raw: rawTransaction, expiryHeight: 123_456)])
        let plan = await mockContainer.resolve(SubmitPlanStoring.self).plan(for: rawID)
        XCTAssertEqual(plan, StoredSubmitPlan.awaiting)
    }

    func testCreateProposedTransactionsEmitsAvailableHistoryWhenOnlyOneOverviewIsMissing() async throws {
        let foundRawID = Data(repeating: 0xAB, count: 32)
        let missingRawID = Data(repeating: 0xCD, count: 32)
        let overviews = [
            makeTransaction(raw: Data([0x01]), rawID: foundRawID),
            makeTransaction(raw: Data([0x02]), rawID: missingRawID)
        ]
        let transactionEncoder = StubTransactionEncoder(
            createdTransactions: overviews,
            missingHistoryTxIds: [missingRawID]
        )
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        let foundTransactionsExpectation = XCTestExpectation(description: "available history event")
        synchronizer.eventStream
            .sink { event in
                guard case let .foundTransactions(transactions, range) = event else { return }
                XCTAssertNil(range)
                XCTAssertEqual(transactions.map(\.rawID), [foundRawID])
                foundTransactionsExpectation.fulfill()
            }
            .store(in: &cancellables)
        await synchronizer.updateStatus(.stopped)

        let transactions = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )

        XCTAssertEqual(transactions.map(\.txId), [foundRawID, missingRawID])
        await fulfillment(of: [foundTransactionsExpectation], timeout: 1.0)
    }

    func testCreateMarksTransactionsAwaitingSubmission() async throws {
        let rawID = Data(repeating: 0xAB, count: 32)
        let overviews = [makeTransaction(raw: Data([0x01]), rawID: rawID)]
        let transactionEncoder = StubTransactionEncoder(createdTransactions: overviews)
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        _ = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )

        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plan = await store.plan(for: rawID)
        XCTAssertEqual(plan, StoredSubmitPlan.awaiting)
    }

    func testWalletTransactionEncoderReadsCreatedTransactionThroughGeneralFFI() async throws {
        let rawID = Data(repeating: 0xBC, count: 32)
        let transactionData = TransactionData(
            txId: rawID,
            raw: Data([0x01, 0x02, 0x03]),
            expiryHeight: 123_456
        )
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.createProposedTransactionsProposalUskReturnValue = [rawID]
        rustBackend.getTransactionTxIdReturnValue = transactionData
        let encoder = WalletTransactionEncoder(
            rustBackend: rustBackend,
            dataDb: try __dataDbURL(),
            fsBlockDbRoot: testTempDirectory,
            service: LightWalletServiceMock(),
            repository: TransactionRepositoryMock(),
            outputParams: try __outputParamsURL(),
            spendParams: try __spendParamsURL(),
            networkType: .testnet,
            logger: submissionLifecycleLogger(),
            sdkFlags: SDKFlags(torEnabled: false, exchangeRateEnabled: false)
        )

        let transactions = try await encoder.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )

        XCTAssertEqual(transactions, [CreatedTransaction(transactionData: transactionData)])
        XCTAssertEqual(rustBackend.getTransactionTxIdReceivedTxId, rawID)
    }

    func testWalletTransactionEncoderReportsFailedAndAlreadyReadTransactionIds() async throws {
        let firstTxId = Data(repeating: 0xBC, count: 32)
        let missingTxId = Data(repeating: 0xBD, count: 32)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.createProposedTransactionsProposalUskReturnValue = [firstTxId, missingTxId]
        rustBackend.getTransactionTxIdClosure = { txId in
            guard txId == firstTxId else { return nil }
            return TransactionData(txId: firstTxId, raw: Data([0x01]), expiryHeight: 123_456)
        }
        let encoder = WalletTransactionEncoder(
            rustBackend: rustBackend,
            dataDb: try __dataDbURL(),
            fsBlockDbRoot: testTempDirectory,
            service: LightWalletServiceMock(),
            repository: TransactionRepositoryMock(),
            outputParams: try __outputParamsURL(),
            spendParams: try __spendParamsURL(),
            networkType: .testnet,
            logger: submissionLifecycleLogger(),
            sdkFlags: SDKFlags(torEnabled: false, exchangeRateEnabled: false)
        )

        do {
            _ = try await encoder.createProposedTransactions(
                proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
                spendingKey: TestsData(networkType: .testnet).spendingKey
            )
            XCTFail("Expected wallet-store readback to fail")
        } catch ZcashError.rustGetTransaction(let message) {
            XCTAssertTrue(message.contains(missingTxId.toHexStringTxId()))
            XCTAssertTrue(message.contains(firstTxId.toHexStringTxId()))
        } catch {
            XCTFail("Expected rustGetTransaction but got \(error.localizedDescription)")
        }
    }

    func testCreateTransactionFromPCZTMarksAwaitingAndEmitsEvent() async throws {
        let rawID = Data(repeating: 0xCD, count: 32)
        let overviews = [makeTransaction(raw: Data([0x05, 0x06]), rawID: rawID)]
        let transactionEncoder = StubTransactionEncoder(createdTransactions: overviews)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.extractAndStoreTxFromPCZTPcztWithProofsPcztWithSigsReturnValue = rawID
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder, rustBackend: rustBackend)
        await synchronizer.updateStatus(.stopped)

        let transactions = try await synchronizer.broadcaster.createTransactionFromPCZT(
            pcztWithProofs: Pczt([0x10, 0x11]),
            pcztWithSigs: Pczt([0x12, 0x13])
        )

        XCTAssertEqual(transactions.map(\.txId), [rawID])
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plan = await store.plan(for: rawID)
        XCTAssertEqual(plan, StoredSubmitPlan.awaiting)
    }

    func testCreateTransactionFromPCZTContinuesWhenHistoryViewDoesNotContainCreatedTransaction() async throws {
        let rawID = Data(repeating: 0xCD, count: 32)
        let rawTransaction = Data([0x05, 0x06])
        let overviews = [makeTransaction(raw: rawTransaction, rawID: rawID)]
        let transactionEncoder = StubTransactionEncoder(
            createdTransactions: overviews,
            fetchError: ZcashError.transactionRepositoryEntityNotFound
        )
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.extractAndStoreTxFromPCZTPcztWithProofsPcztWithSigsReturnValue = rawID
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder, rustBackend: rustBackend)
        await synchronizer.updateStatus(.stopped)

        let transactions = try await synchronizer.broadcaster.createTransactionFromPCZT(
            pcztWithProofs: Pczt([0x10, 0x11]),
            pcztWithSigs: Pczt([0x12, 0x13])
        )

        XCTAssertEqual(transactions, [CreatedTransaction(txId: rawID, raw: rawTransaction, expiryHeight: 123_456)])
    }

    func testBroadcasterThrowsWhenNotPrepared() async throws {
        let transactionEncoder = StubTransactionEncoder(createdTransactions: [])
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)

        do {
            _ = try await synchronizer.broadcaster.createProposedTransactions(
                proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
                spendingKey: TestsData(networkType: .testnet).spendingKey
            )
            XCTFail("Should throw when synchronizer is not prepared")
        } catch {
            XCTAssertTrue(error is ZcashError, "Expected ZcashError but got \(error)")
        }
    }

    func testBroadcasterThrowsWhenSynchronizerIsReleased() async throws {
        let transactionEncoder = StubTransactionEncoder(createdTransactions: [])
        var synchronizer: SDKSynchronizer? = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer?.updateStatus(.stopped)

        let broadcaster = try XCTUnwrap(synchronizer?.broadcaster)
        synchronizer = nil
        await Task.yield()

        do {
            _ = try await broadcaster.createProposedTransactions(
                proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
                spendingKey: TestsData(networkType: .testnet).spendingKey
            )
            XCTFail("Should throw when the owning synchronizer has been released")
        } catch ZcashError.synchronizerNotPrepared {
            // expected
        } catch {
            XCTFail("Expected synchronizerNotPrepared but got \(error)")
        }
    }

    // MARK: - Submit (single, via real local gRPC servers)

    func testSubmitRecordsPlanAndDeliversToEndpoint() async throws {
        let acceptingService = try RecordingCompactTxStreamerService(sendResponse: makeSendResponse(errorCode: 0, errorMessage: ""))
        defer { try? acceptingService.stop() }
        let synchronizer = try makeSynchronizer(transactionEncoder: StubTransactionEncoder(createdTransactions: []))
        let transaction = makeCreatedTransaction()

        let outcome = await synchronizer.broadcaster.submit(
            transaction: transaction,
            to: [acceptingService.endpoint]
        )

        XCTAssertEqual(outcome, TransactionSubmissionOutcome.accepted(by: acceptingService.endpoint))
        XCTAssertEqual(acceptingService.recordedTransactions(), [transaction.raw])

        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plan = await store.plan(for: transaction.txId)
        XCTAssertEqual(plan, StoredSubmitPlan.ready([acceptingService.endpoint], acceptedBy: "\(acceptingService.endpoint.host):\(acceptingService.endpoint.port)"))
    }

    // MARK: - Wipe race: a late acceptance for a submission started before wipe()

    /// A `wipe()` that lands while a foreground `submit` is still racing its network call must win:
    /// the acceptance that eventually arrives belongs to a submission the caller already asked to
    /// forget, and applying it would recreate the submit-plan store file `wipe()` just deleted.
    func testWipeDuringSubmissionDropsALateAcceptance() async throws {
        let endpoint = LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
        let endpointSubmitterMock = EndpointSubmitterMock()
        let gate = Gate()
        endpointSubmitterMock.set(behavior: .gated(gate, then: .succeed), for: endpoint)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitterMock
        )
        let transaction = makeCreatedTransaction()
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plansDatabaseURL = submitPlanDatabaseURL(for: synchronizer)

        let submitTask = Task {
            await synchronizer.broadcaster.submit(transaction: transaction, to: [endpoint])
        }
        await endpointSubmitterMock.awaitSubmissionStarted(to: endpoint)

        await store.wipe()
        gate.open()

        let outcome = await submitTask.value
        XCTAssertEqual(outcome, TransactionSubmissionOutcome.accepted(by: endpoint))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: plansDatabaseURL.path),
            "a late acceptance for a submission that started before wipe() must not recreate the store file"
        )
        let plan = await store.plan(for: transaction.txId)
        XCTAssertNil(plan)
    }

    /// Control: a wipe racing a submission that ends up rejected (rather than accepted) must not
    /// change the outcome reported to the caller, and must still leave no plan behind — the drop is
    /// specific to a stale acceptance, not a side effect of wiping mid-flight.
    func testWipeDuringSubmissionDoesNotAffectALateRejection() async throws {
        let endpoint = LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
        let endpointSubmitterMock = EndpointSubmitterMock()
        let gate = Gate()
        endpointSubmitterMock.set(behavior: .gated(gate, then: .reject(code: -25, message: "rejected")), for: endpoint)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitterMock
        )
        let transaction = makeCreatedTransaction()
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plansDatabaseURL = submitPlanDatabaseURL(for: synchronizer)

        let submitTask = Task {
            await synchronizer.broadcaster.submit(transaction: transaction, to: [endpoint])
        }
        await endpointSubmitterMock.awaitSubmissionStarted(to: endpoint)

        await store.wipe()
        gate.open()

        let outcome = await submitTask.value
        XCTAssertEqual(
            outcome,
            TransactionSubmissionOutcome.rejected(code: -25, message: "rejected"),
            "a concurrent wipe must not change the outcome reported to the caller"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: plansDatabaseURL.path))
        let plan = await store.plan(for: transaction.txId)
        XCTAssertNil(plan)
    }

    /// Two simultaneous foreground submissions straddling a `wipe()`: the one that started before it
    /// has its late acceptance dropped, while one recorded after the wipe — a new lifecycle — accepts
    /// normally. Proves the drop is scoped to the specific submission the wipe raced, not to every
    /// acceptance the store sees afterward.
    func testWipeDropsOnlyThePreWipeSubmissionsAcceptance() async throws {
        let staleEndpoint = LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
        let freshEndpoint = LightWalletEndpoint(address: "b.example.com", port: 9067, secure: false)
        let endpointSubmitterMock = EndpointSubmitterMock()
        let staleGate = Gate()
        endpointSubmitterMock.set(behavior: .gated(staleGate, then: .succeed), for: staleEndpoint)
        endpointSubmitterMock.set(behavior: .succeed, for: freshEndpoint)
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitterMock
        )
        let staleTransaction = makeCreatedTransaction(seed: 0x41)
        let freshTransaction = makeCreatedTransaction(seed: 0x42)
        let store = mockContainer.resolve(SubmitPlanStoring.self)

        let staleTask = Task {
            await synchronizer.broadcaster.submit(transaction: staleTransaction, to: [staleEndpoint])
        }
        await endpointSubmitterMock.awaitSubmissionStarted(to: staleEndpoint)
        await store.wipe()

        let freshOutcome = await synchronizer.broadcaster.submit(transaction: freshTransaction, to: [freshEndpoint])
        XCTAssertEqual(freshOutcome, TransactionSubmissionOutcome.accepted(by: freshEndpoint))

        staleGate.open()
        let staleOutcome = await staleTask.value
        XCTAssertEqual(staleOutcome, TransactionSubmissionOutcome.accepted(by: staleEndpoint))

        let stalePlan = await store.plan(for: staleTransaction.txId)
        XCTAssertNil(stalePlan, "the pre-wipe submission's late acceptance must not resurrect a plan")
        let freshPlan = await store.plan(for: freshTransaction.txId)
        XCTAssertEqual(
            freshPlan,
            StoredSubmitPlan.ready([freshEndpoint], acceptedBy: "\(freshEndpoint.host):\(freshEndpoint.port)")
        )
    }

    // MARK: - Release for resubmission

    /// A host that created transactions but could not hand them to a server itself releases them
    /// to the SDK's background resubmission: each transaction's plan moves straight to `.ready`
    /// with the given endpoints, and no network attempt is made.
    func testReleaseForResubmissionRecordsPlansWithoutSubmitting() async throws {
        let endpointA = LightWalletEndpoint(address: "a.example.com", port: 443, secure: true)
        let endpointB = LightWalletEndpoint(address: "b.example.com", port: 9067, secure: false)
        let endpointSubmitterMock = EndpointSubmitterMock()
        let synchronizer = try makeSynchronizer(
            transactionEncoder: StubTransactionEncoder(createdTransactions: []),
            endpointSubmitter: endpointSubmitterMock
        )
        let created = [makeCreatedTransaction(seed: 0xAB), makeCreatedTransaction(seed: 0xCD)]

        await synchronizer.broadcaster.releaseForResubmission(transactions: created, to: [endpointA, endpointB])

        XCTAssertTrue(endpointSubmitterMock.recordedSubmissions().isEmpty, "Releasing must not itself submit")
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        for transaction in created {
            let plan = await store.plan(for: transaction.txId)
            XCTAssertEqual(plan, StoredSubmitPlan.ready([endpointA, endpointB], acceptedBy: nil))
        }
    }

    /// An empty endpoint list records nothing: a transaction already marked `.awaiting` by
    /// creation stays that way, so it remains excluded from background resubmission until the
    /// host releases it with real endpoints.
    func testReleaseForResubmissionWithEmptyEndpointsLeavesTransactionAwaiting() async throws {
        let rawID = Data(repeating: 0xEF, count: 32)
        let rawTransaction = Data([0x01, 0x02])
        let overviews = [makeTransaction(raw: rawTransaction, rawID: rawID)]
        let transactionEncoder = StubTransactionEncoder(createdTransactions: overviews)
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        let created = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let planBefore = await store.plan(for: rawID)
        XCTAssertEqual(planBefore, StoredSubmitPlan.awaiting)

        await synchronizer.broadcaster.releaseForResubmission(transactions: created, to: [])

        let planAfter = await store.plan(for: rawID)
        XCTAssertEqual(planAfter, StoredSubmitPlan.awaiting, "An empty endpoint list must record nothing; the transaction stays awaiting")
    }

    // MARK: - Wipe race: a stale awaiting-mark for a transaction created before wipe()

    /// A `wipe()` that lands while a transaction is still being created (proving, PCZT
    /// extraction) must not have the eventual `markAwaitingSubmission` call recreate the deleted
    /// submit-plan store: the lifecycle token is captured before creation starts, so by the time
    /// `finishCreation` writes the awaiting mark, a wipe that landed meanwhile makes the token
    /// provably stale — mirroring the existing guard on a late `submit` acceptance.
    func testCreationDropsAwaitingMarkWhenWipedDuringCreation() async throws {
        let rawID = Data(repeating: 0xFA, count: 32)
        let rawTransaction = Data([0x01, 0x02, 0x03])
        let overviews = [makeTransaction(raw: rawTransaction, rawID: rawID)]
        let transactionEncoder = StubTransactionEncoder(createdTransactions: overviews)
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plansDatabaseURL = submitPlanDatabaseURL(for: synchronizer)
        transactionEncoder.onCreateProposedTransactions = {
            await store.wipe()
        }

        let created = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )
        XCTAssertEqual(created.map(\.txId), [rawID])

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: plansDatabaseURL.path),
            "a mark-awaiting call for a transaction created before wipe() must not recreate the store file"
        )
        let plan = await store.plan(for: rawID)
        XCTAssertNil(plan, "A wipe landing during creation must not be undone by a stale awaiting-mark")
    }

    // MARK: - Submission status reported to the host

    func testSubmissionStatusIsAwaitingBeforeTheAppSubmits() async throws {
        let rawID = Data(repeating: 0xAB, count: 32)
        let transactionEncoder = StubTransactionEncoder(createdTransactions: [makeTransaction(raw: Data([0x01]), rawID: rawID)])
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        _ = try await synchronizer.broadcaster.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )

        let status = await synchronizer.transactionSubmissionStatus(for: rawID)
        XCTAssertEqual(status, TransactionSubmissionStatus.awaiting)
    }

    func testSubmissionStatusIsAcceptedWithTheServerThatTookTheTransaction() async throws {
        let acceptingService = try RecordingCompactTxStreamerService(sendResponse: makeSendResponse(errorCode: 0, errorMessage: ""))
        defer { try? acceptingService.stop() }
        let synchronizer = try makeSynchronizer(transactionEncoder: StubTransactionEncoder(createdTransactions: []))
        let transaction = makeCreatedTransaction()

        _ = await synchronizer.broadcaster.submit(transaction: transaction, to: [acceptingService.endpoint])

        let endpoint = try XCTUnwrap(acceptingService.endpoint)
        let status = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        XCTAssertEqual(status, TransactionSubmissionStatus.accepted(host: "\(endpoint.host):\(endpoint.port)"))
    }

    func testSubmissionStatusIsSubmittedWhenNoServerAccepted() async throws {
        let rejectingService = try RecordingCompactTxStreamerService(sendResponse: makeSendResponse(errorCode: -25, errorMessage: "rejected"))
        defer { try? rejectingService.stop() }
        let synchronizer = try makeSynchronizer(transactionEncoder: StubTransactionEncoder(createdTransactions: []))
        let transaction = makeCreatedTransaction()

        _ = await synchronizer.broadcaster.submit(transaction: transaction, to: [rejectingService.endpoint])

        let status = await synchronizer.transactionSubmissionStatus(for: transaction.txId)
        XCTAssertEqual(status, TransactionSubmissionStatus.submitted)
    }

    func testSubmissionStatusIsNilForATransactionTheStoreNeverSaw() async throws {
        let synchronizer = try makeSynchronizer(transactionEncoder: StubTransactionEncoder(createdTransactions: []))

        let status = await synchronizer.transactionSubmissionStatus(for: Data(repeating: 0xFE, count: 32))
        XCTAssertNil(status)
    }

    func testSubmitToRejectingEndpointIsRejected() async throws {
        let rejectingService = try RecordingCompactTxStreamerService(sendResponse: makeSendResponse(errorCode: -25, errorMessage: "rejected"))
        defer { try? rejectingService.stop() }
        let synchronizer = try makeSynchronizer(transactionEncoder: StubTransactionEncoder(createdTransactions: []))

        let outcome = await synchronizer.broadcaster.submit(
            transaction: makeCreatedTransaction(),
            to: [rejectingService.endpoint]
        )

        XCTAssertEqual(outcome, TransactionSubmissionOutcome.rejected(code: -25, message: "rejected"))
    }

    func testSubmitFirstAcceptanceWinsAcrossEndpoints() async throws {
        let acceptingService = try RecordingCompactTxStreamerService(sendResponse: makeSendResponse(errorCode: 0, errorMessage: ""))
        defer { try? acceptingService.stop() }
        let rejectingService = try RecordingCompactTxStreamerService(sendResponse: makeSendResponse(errorCode: -25, errorMessage: "rejected"))
        defer { try? rejectingService.stop() }
        let synchronizer = try makeSynchronizer(transactionEncoder: StubTransactionEncoder(createdTransactions: []))
        let transaction = makeCreatedTransaction()

        let outcome = await synchronizer.broadcaster.submit(
            transaction: transaction,
            to: [rejectingService.endpoint, acceptingService.endpoint],
            timing: SubmissionTiming(responseTimeout: 5, postAcceptanceGraceDelay: 0.2)
        )

        XCTAssertEqual(outcome, TransactionSubmissionOutcome.accepted(by: acceptingService.endpoint))

        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plan = await store.plan(for: transaction.txId)
        XCTAssertEqual(plan, StoredSubmitPlan.ready(
            [rejectingService.endpoint, acceptingService.endpoint],
            acceptedBy: "\(acceptingService.endpoint.host):\(acceptingService.endpoint.port)"
        ))
    }

    func testSubmitWithEmptyEndpointsIsUnreachableAndRecordsNoPlan() async throws {
        let synchronizer = try makeSynchronizer(transactionEncoder: StubTransactionEncoder(createdTransactions: []))
        let transaction = makeCreatedTransaction()

        let outcome = await synchronizer.broadcaster.submit(transaction: transaction, to: [])

        XCTAssertEqual(outcome, TransactionSubmissionOutcome.unreachable)
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plan = await store.plan(for: transaction.txId)
        XCTAssertNil(plan)
    }

    // MARK: - Submit (batch)

    func testBatchSubmitStopsAfterFirstFailureAndMarksRestNotAttempted() async throws {
        let rejectingService = try RecordingCompactTxStreamerService(sendResponse: makeSendResponse(errorCode: -25, errorMessage: "rejected"))
        defer { try? rejectingService.stop() }
        let synchronizer = try makeSynchronizer(transactionEncoder: StubTransactionEncoder(createdTransactions: []))
        let first = makeCreatedTransaction(seed: 0x01)
        let second = makeCreatedTransaction(seed: 0x02)

        let reports = await synchronizer.broadcaster.submit(
            transactions: [first, second],
            to: [rejectingService.endpoint]
        )

        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports[0].txId, first.txId)
        XCTAssertEqual(reports[0].outcome, TransactionSubmissionOutcome.rejected(code: -25, message: "rejected"))
        XCTAssertEqual(reports[1].txId, second.txId)
        XCTAssertEqual(reports[1].outcome, TransactionSubmissionOutcome.notAttempted)

        // The second transaction was never released — its plan must not exist.
        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let secondPlan = await store.plan(for: second.txId)
        XCTAssertNil(secondPlan)
    }

    func testBatchSubmitAllAccepted() async throws {
        let acceptingService = try RecordingCompactTxStreamerService(sendResponse: makeSendResponse(errorCode: 0, errorMessage: ""))
        defer { try? acceptingService.stop() }
        let synchronizer = try makeSynchronizer(transactionEncoder: StubTransactionEncoder(createdTransactions: []))
        let first = makeCreatedTransaction(seed: 0x03)
        let second = makeCreatedTransaction(seed: 0x04)

        let reports = await synchronizer.broadcaster.submit(
            transactions: [first, second],
            to: [acceptingService.endpoint]
        )

        XCTAssertEqual(reports.map(\.outcome), [
            TransactionSubmissionOutcome.accepted(by: acceptingService.endpoint),
            TransactionSubmissionOutcome.accepted(by: acceptingService.endpoint)
        ])
        XCTAssertEqual(acceptingService.recordedTransactions(), [first.raw, second.raw])
    }

    // MARK: - Legacy Synchronizer APIs (behavior unchanged, no plan rows)

    func testLegacyCreateProposedTransactionsSubmitsOnceAndRecordsNoPlan() async throws {
        let rawID = Data(repeating: 0xAB, count: 32)
        let rawTransaction = Data([0x01, 0x02, 0x03, 0x04])
        let overviews = [makeTransaction(raw: rawTransaction, rawID: rawID)]
        let transactionEncoder = StubTransactionEncoder(createdTransactions: overviews)
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder)
        await synchronizer.updateStatus(.stopped)

        let stream = try await synchronizer.createProposedTransactions(
            proposal: Proposal.testOnlyFakeProposal(totalFee: 10),
            spendingKey: TestsData(networkType: .testnet).spendingKey
        )
        var iterator = stream.makeAsyncIterator()

        let maybeSubmitResult = try await iterator.next()
        let submitResult = try XCTUnwrap(maybeSubmitResult)
        XCTAssertEqual(submitResult, TransactionSubmitResult.success(txId: rawID))
        let nextSubmitResult = try await iterator.next()
        XCTAssertNil(nextSubmitResult)
        XCTAssertEqual(
            transactionEncoder.submittedTransactions,
            [EncodedTransaction(transactionId: rawID, raw: rawTransaction)]
        )

        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plan = await store.plan(for: rawID)
        XCTAssertNil(plan, "Legacy path must not register submit plans")
    }

    func testLegacyCreateTransactionFromPCZTSubmitsOnceAndRecordsNoPlan() async throws {
        let rawID = Data(repeating: 0xCD, count: 32)
        let rawTransaction = Data([0x05, 0x06, 0x07, 0x08])
        let overviews = [makeTransaction(raw: rawTransaction, rawID: rawID)]
        let transactionEncoder = StubTransactionEncoder(createdTransactions: overviews)
        let rustBackend = ZcashRustBackendWeldingMock()
        rustBackend.extractAndStoreTxFromPCZTPcztWithProofsPcztWithSigsReturnValue = rawID
        let synchronizer = try makeSynchronizer(transactionEncoder: transactionEncoder, rustBackend: rustBackend)
        await synchronizer.updateStatus(.stopped)

        let stream = try await synchronizer.createTransactionFromPCZT(
            pcztWithProofs: Pczt([0x10, 0x11]),
            pcztWithSigs: Pczt([0x12, 0x13])
        )
        var iterator = stream.makeAsyncIterator()

        let maybeSubmitResult = try await iterator.next()
        let submitResult = try XCTUnwrap(maybeSubmitResult)
        XCTAssertEqual(submitResult, TransactionSubmitResult.success(txId: rawID))

        let store = mockContainer.resolve(SubmitPlanStoring.self)
        let plan = await store.plan(for: rawID)
        XCTAssertNil(plan, "Legacy path must not register submit plans")
    }

    // MARK: - Helpers

    private func makeSynchronizer(
        transactionEncoder: TransactionEncoder,
        rustBackend: ZcashRustBackendWelding? = nil,
        endpointSubmitter: EndpointSubmitter? = nil
    ) throws -> SDKSynchronizer {
        let serviceMock = LightWalletServiceMock()
        let transactionRepository = TransactionRepositoryMock()

        if let rustBackend {
            mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in rustBackend }
        }
        if let endpointSubmitter {
            mockContainer.mock(type: EndpointSubmitter.self, isSingleton: true) { _ in endpointSubmitter }
        }
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in serviceMock }
        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in transactionRepository }
        mockContainer.mock(type: Logger.self, isSingleton: true) { _ in submissionLifecycleLogger() }

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

        let blockProcessor = CompactBlockProcessor(
            initializer: initializer,
            walletBirthdayProvider: { initializer.walletBirthday }
        )

        return SDKSynchronizer(
            status: .unprepared,
            initializer: initializer,
            transactionEncoder: transactionEncoder,
            transactionRepository: transactionRepository,
            blockProcessor: blockProcessor,
            syncSessionTicker: .live
        )
    }

    private func makeTransaction(raw: Data?, rawID: Data) -> ZcashTransaction.Overview {
        CreatedTransactionTests.makeTransaction(raw: raw, rawID: rawID)
    }

    private func makeCreatedTransaction(seed: UInt8 = 0xAB) -> CreatedTransaction {
        CreatedTransaction(
            txId: Data(repeating: seed, count: 32),
            raw: Data([seed, 0x02, 0x03, 0x04]),
            expiryHeight: 123_456
        )
    }

    private func makeSendResponse(errorCode: Int32, errorMessage: String) -> SendResponse {
        var response = SendResponse()
        response.errorCode = errorCode
        response.errorMessage = errorMessage
        return response
    }

    /// Same construction as `Dependencies.swift:58-64` — the real `SubmitPlanStore`'s backing file
    /// that `mockContainer.resolve(SubmitPlanStoring.self)` resolves to in these tests.
    private func submitPlanDatabaseURL(for synchronizer: SDKSynchronizer) -> URL {
        synchronizer.initializer.generalStorageURL
            .appendingPathComponent("submit_plans_\(synchronizer.initializer.network.networkType.networkId).db")
    }
}

// MARK: - Test Doubles

private final class StubTransactionEncoder: TransactionEncoder {
    private let createdTransactions: [CreatedTransaction]
    private let overviews: [ZcashTransaction.Overview]
    private let fetchError: Error?
    private let missingHistoryTxIds: Set<Data>
    private(set) var receivedCreateArguments: (proposal: Proposal, spendingKey: UnifiedSpendingKey)?
    private(set) var receivedFetchTxIds: [Data]?
    private(set) var submittedTransactions: [EncodedTransaction] = []
    /// Runs at the start of `createProposedTransactions`, standing in for the (potentially slow)
    /// proving work it represents — e.g. to land a `wipe()` while a transaction is mid-creation.
    var onCreateProposedTransactions: (() async -> Void)?

    init(
        createdTransactions overviews: [ZcashTransaction.Overview],
        fetchError: Error? = nil,
        missingHistoryTxIds: Set<Data> = []
    ) {
        self.overviews = overviews
        self.createdTransactions = overviews.map { overview in
            guard let raw = overview.raw else {
                XCTFail("StubTransactionEncoder requires raw transaction bytes")
                return CreatedTransaction(txId: overview.rawID, raw: Data(), expiryHeight: overview.expiryHeight)
            }
            return CreatedTransaction(txId: overview.rawID, raw: raw, expiryHeight: overview.expiryHeight)
        }
        self.fetchError = fetchError
        self.missingHistoryTxIds = missingHistoryTxIds
    }

    func proposeTransfer(
        accountUUID: AccountUUID,
        recipient: String,
        amount: Zatoshi,
        memoBytes: MemoBytes?
    ) async throws -> Proposal {
        fatalError("Unused in test")
    }

    func proposeSendMax(
        accountUUID: AccountUUID,
        recipient: String,
        memoBytes: MemoBytes?,
        mode: MaxSpendMode
    ) async throws -> Proposal {
        fatalError("Unused in test")
    }

    func proposeOrchardToIronwoodMigration(accountUUID: AccountUUID) async throws -> Proposal {
        fatalError("Unused in test")
    }

    func proposeShielding(
        accountUUID: AccountUUID,
        shieldingThreshold: Zatoshi,
        memoBytes: MemoBytes?,
        transparentReceiver: String?
    ) async throws -> Proposal? {
        fatalError("Unused in test")
    }

    func createProposedTransactions(
        proposal: Proposal,
        spendingKey: UnifiedSpendingKey
    ) async throws -> [CreatedTransaction] {
        receivedCreateArguments = (proposal, spendingKey)
        if let onCreateProposedTransactions {
            await onCreateProposedTransactions()
        }
        return createdTransactions
    }

    func createdTransactions(forTxIds txIds: [Data]) async throws -> [CreatedTransaction] {
        txIds.compactMap { txId in
            createdTransactions.first { $0.txId == txId }
        }
    }

    func proposeFulfillingPaymentFromURI(
        _ uri: String,
        accountUUID: AccountUUID
    ) async throws -> Proposal {
        fatalError("Unused in test")
    }

    func submit(transaction: EncodedTransaction) async throws {
        submittedTransactions.append(transaction)
    }

    func isTransactionKnownToServer(txId: Data) async -> Bool {
        false
    }

    func fetchTransactionsForTxIds(_ txIds: [Data]) async throws -> [ZcashTransaction.Overview] {
        receivedFetchTxIds = txIds
        if let fetchError {
            throw fetchError
        }
        if txIds.contains(where: missingHistoryTxIds.contains) {
            throw ZcashError.transactionRepositoryEntityNotFound
        }
        return txIds.compactMap { txId in
            overviews.first { $0.rawID == txId }
        }
    }

    func closeDBConnection() { }
}
