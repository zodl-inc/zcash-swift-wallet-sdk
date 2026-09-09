//
//  SDKBroadcaster.swift
//  ZcashLightClientKit
//

import Combine
import Foundation

final class SDKBroadcaster: Broadcaster {
    private let transactionEncoder: TransactionEncoder
    private let initializer: Initializer
    private let logger: Logger
    private let eventSubject: PassthroughSubject<SynchronizerEvent, Never>
    private let submitPlanStore: SubmitPlanStoring
    private let multiEndpointSubmitter: MultiEndpointSubmitter
    private let statusCheck: () throws -> Void

    init(
        transactionEncoder: TransactionEncoder,
        initializer: Initializer,
        logger: Logger,
        eventSubject: PassthroughSubject<SynchronizerEvent, Never>,
        submitPlanStore: SubmitPlanStoring,
        multiEndpointSubmitter: MultiEndpointSubmitter,
        statusCheck: @escaping () throws -> Void
    ) {
        self.transactionEncoder = transactionEncoder
        self.initializer = initializer
        self.logger = logger
        self.eventSubject = eventSubject
        self.submitPlanStore = submitPlanStore
        self.multiEndpointSubmitter = multiEndpointSubmitter
        self.statusCheck = statusCheck
    }

    // MARK: - Broadcaster conformance

    func createProposedTransactions(
        proposal: Proposal,
        spendingKey: UnifiedSpendingKey
    ) async throws -> [CreatedTransaction] {
        try await createProposedTransactions(proposal: proposal, spendingKey: spendingKey, recordingPlans: true)
    }

    func createTransactionFromPCZT(
        pcztWithProofs: Pczt,
        pcztWithSigs: Pczt
    ) async throws -> [CreatedTransaction] {
        try await createTransactionFromPCZT(pcztWithProofs: pcztWithProofs, pcztWithSigs: pcztWithSigs, recordingPlans: true)
    }

    func submit(
        transaction: CreatedTransaction,
        to endpoints: [LightWalletEndpoint],
        timing: SubmissionTiming
    ) async -> TransactionSubmissionOutcome {
        let txId = transaction.txId.toHexStringTxId()

        guard !endpoints.isEmpty else {
            logger.debug("Transaction \(txId) submit requested with no endpoints; nothing sent, transaction stays awaiting.")
            return .unreachable
        }

        let endpointList = endpoints.map { "\($0.host):\($0.port)" }.joined(separator: ", ")
        logger.debug("Transaction \(txId) submitting to \(endpoints.count) endpoint(s): \(endpointList).")

        // Record before any network attempt so a cancelled or timed-out race
        // still leaves the intended retry plan behind. The returned token is
        // carried through the network race so a `wipe()` that lands while it
        // is in flight leaves the eventual `markAccepted` call provably stale.
        let lifecycle = await submitPlanStore.recordPlan(txId: transaction.txId, endpoints: endpoints)

        let outcome = await multiEndpointSubmitter.submit(transaction: transaction, to: endpoints, timing: timing)
        logger.debug("Transaction \(txId) submission \(outcome.logDescription).")

        // Remember which server took it, so the app can tell "handed to a
        // server" apart from "still trying" while the transaction waits to be
        // mined. Retrying continues either way — a mempool is not a commitment.
        if case .accepted(by: let endpoint) = outcome {
            await submitPlanStore.markAccepted(txId: transaction.txId, host: "\(endpoint.host):\(endpoint.port)", lifecycle: lifecycle)
        }

        return outcome
    }

    func releaseForResubmission(
        transactions: [CreatedTransaction],
        to endpoints: [LightWalletEndpoint]
    ) async {
        guard !endpoints.isEmpty else {
            logger.debug("Release for resubmission requested with no endpoints; transactions stay awaiting.")
            return
        }
        // `recordPlanForAwaitingTransaction`, not `recordPlan`: a release only succeeds for a
        // transaction that already has an awaiting row from this wallet lifecycle, so a release
        // landing after `wipe()` can never recreate the plan store's database file.
        var releasedCount = 0
        for transaction in transactions {
            guard await submitPlanStore.recordPlanForAwaitingTransaction(txId: transaction.txId, endpoints: endpoints) != nil else {
                logger.debug(
                    """
                    Release for resubmission dropped for \(transaction.txId.toHexStringTxId()); the transaction has \
                    no awaiting row in the current wallet lifecycle.
                    """
                )
                continue
            }
            releasedCount += 1
        }
        logger.debug("Released \(releasedCount) created transaction(s) to background resubmission.")
    }

    func submit(
        transactions: [CreatedTransaction],
        to endpoints: [LightWalletEndpoint],
        timing: SubmissionTiming
    ) async -> [TransactionSubmissionReport] {
        logger.debug("Batch submitting \(transactions.count) transaction(s).")
        var reports: [TransactionSubmissionReport] = []
        var stopped = false

        for transaction in transactions {
            let txId = transaction.txId.toHexStringTxId()
            if stopped {
                logger.debug("Transaction \(txId) not attempted; an earlier transaction in the batch was not accepted.")
                reports.append(TransactionSubmissionReport(txId: transaction.txId, outcome: .notAttempted))
                continue
            }

            let outcome = await submit(transaction: transaction, to: endpoints, timing: timing)
            reports.append(TransactionSubmissionReport(txId: transaction.txId, outcome: outcome))

            if case .accepted = outcome {
                continue
            }
            logger.debug("Batch stopping after \(txId) was \(outcome.logDescription); remaining marked not attempted.")
            stopped = true
        }

        return reports
    }

    // MARK: - Internal create paths (legacy callers pass recordingPlans: false)

    func createProposedTransactions(
        proposal: Proposal,
        spendingKey: UnifiedSpendingKey,
        recordingPlans: Bool
    ) async throws -> [CreatedTransaction] {
        try statusCheck()

        // Captured before the (potentially slow) sapling-parameter download and proving work so a
        // `wipe()` that lands mid-flight leaves the eventual `markAwaitingSubmission` call provably
        // stale instead of reopening — and thereby recreating — the database `wipe()` just deleted.
        let lifecycle = await submitPlanStore.currentLifecycle()

        try await downloadSaplingParamsIfNeeded()

        let createdTransactions = try await transactionEncoder.createProposedTransactions(
            proposal: proposal,
            spendingKey: spendingKey
        )
        let overviews = await overviewsForEvent(txIds: createdTransactions.map(\.txId))

        return await finishCreation(
            createdTransactions: createdTransactions,
            overviews: overviews,
            recordingPlans: recordingPlans,
            lifecycle: lifecycle
        )
    }

    func createTransactionFromPCZT(
        pcztWithProofs: Pczt,
        pcztWithSigs: Pczt,
        recordingPlans: Bool
    ) async throws -> [CreatedTransaction] {
        try statusCheck()

        // Captured before the (potentially slow) sapling-parameter download and PCZT extraction so
        // a `wipe()` that lands mid-flight leaves the eventual `markAwaitingSubmission` call
        // provably stale instead of reopening — and thereby recreating — the database `wipe()` just
        // deleted.
        let lifecycle = await submitPlanStore.currentLifecycle()

        try await downloadSaplingParamsIfNeeded()

        let txId = try await initializer.rustBackend.extractAndStoreTxFromPCZT(
            pcztWithProofs: pcztWithProofs,
            pcztWithSigs: pcztWithSigs
        )
        guard let createdTransaction = try await transactionEncoder.createdTransactions(forTxIds: [txId]).first else {
            throw ZcashError.rustGetTransaction(
                "Transaction \(txId.toHexStringTxId()) is unavailable in the wallet store"
            )
        }

        let overviews = await overviewsForEvent(txIds: [createdTransaction.txId])

        return await finishCreation(
            createdTransactions: [createdTransaction],
            overviews: overviews,
            recordingPlans: recordingPlans,
            lifecycle: lifecycle
        )
    }

    // MARK: - Private

    private func downloadSaplingParamsIfNeeded() async throws {
        try await SaplingParameterDownloader.downloadParamsIfnotPresent(
            spendURL: initializer.spendParamsURL,
            spendSourceURL: initializer.saplingParamsSourceURL.spendParamFileURL,
            outputURL: initializer.outputParamsURL,
            outputSourceURL: initializer.saplingParamsSourceURL.outputParamFileURL,
            logger: logger
        )
    }

    private func overviewsForEvent(txIds: [Data]) async -> [ZcashTransaction.Overview] {
        var overviews: [ZcashTransaction.Overview] = []

        for txId in txIds {
            do {
                overviews.append(contentsOf: try await transactionEncoder.fetchTransactionsForTxIds([txId]))
            } catch {
                logger.warn(
                    """
                    Created transaction \(txId.toHexStringTxId()) could not be enriched from v_transactions; \
                    continuing with wallet-store bytes. \(error.localizedDescription)
                    """
                )
            }
        }

        return overviews
    }

    private func finishCreation(
        createdTransactions: [CreatedTransaction],
        overviews: [ZcashTransaction.Overview],
        recordingPlans: Bool,
        lifecycle: SubmitPlanLifecycle
    ) async -> [CreatedTransaction] {
        let txIdList = createdTransactions.map { $0.txId.toHexStringTxId() }.joined(separator: ", ")
        if recordingPlans {
            logger.debug("Created \(createdTransactions.count) transaction(s) awaiting submission by the app: \(txIdList).")
            await submitPlanStore.markAwaitingSubmission(txIds: createdTransactions.map(\.txId), lifecycle: lifecycle)
        } else {
            logger.debug("Created \(createdTransactions.count) transaction(s) for immediate submission: \(txIdList).")
        }

        if !overviews.isEmpty {
            eventSubject.send(.foundTransactions(overviews, nil))
        }

        return createdTransactions
    }
}
