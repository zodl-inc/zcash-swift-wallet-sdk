//
//  SynchronizerMigrationDefaultsTests.swift
//  OfflineTests
//
//  Pins the `Synchronizer` protocol-extension defaults for the migration group (R4-B): every
//  throwing member's default throws an "unimplemented" `LocalizedError`, and the three non-throwing
//  members get their documented inert defaults. Driven through `NonMigratingSynchronizer`, a minimal
//  conformer that implements only the protocol's previously-existing (pre-migration) members and
//  relies on every migration default -- so these tests would fail to compile if a default were ever
//  removed, and fail at runtime if a default's behavior ever changed.
//
//  No network, no FFI beyond what `Synchronizer`'s existing types require to name.
//

import Combine
import Foundation
@testable import TestUtils
import XCTest
@_spi(Testing) @testable import ZcashLightClientKit

final class SynchronizerMigrationDefaultsTests: XCTestCase {
    private let accountUUID = AccountUUID(id: [UInt8](repeating: 0x01, count: 16))
    private var synchronizer: NonMigratingSynchronizer!

    override func setUp() {
        super.setUp()
        synchronizer = NonMigratingSynchronizer()
    }

    override func tearDown() {
        synchronizer = nil
        super.tearDown()
    }

    // MARK: - Throwing defaults

    func testMigrationAdvanceStepDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented { _ = try await self.synchronizer.migrationAdvanceStep(accountUUID: self.accountUUID) }
    }

    func testMigrationProgressDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented { _ = try await self.synchronizer.migrationProgress(accountUUID: self.accountUUID) }
    }

    func testProveMigrationTransactionsDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented {
            _ = try await self.synchronizer.proveMigrationTransactions(
                accountUUID: self.accountUUID,
                [MigrationProveTarget(id: 1, kind: .transfer(crossing: 0), isScheduleDue: false)],
                maxProofs: 1
            )
        }
    }

    func testMigrationSyncWakeupsDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented { _ = try await self.synchronizer.migrationSyncWakeups(accountUUID: self.accountUUID) }
    }

    // `nextMigrationWake(accountUUID:)` is one of the non-throwing members: its default is the
    // inert `nil` (`testNextMigrationWakeDefaultReturnsNil` below, alongside the other inert
    // defaults), not a `MigrationUnimplemented` throw.

    func testEstimatedMigrationChainTipDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented { _ = try await self.synchronizer.estimatedMigrationChainTip() }
    }

    func testEstimatedMigrationSecondsPerBlockDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented { _ = try await self.synchronizer.estimatedMigrationSecondsPerBlock() }
    }

    func testMigrationTransactionStatusesDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented { _ = try await self.synchronizer.migrationTransactionStatuses(accountUUID: self.accountUUID) }
    }

    func testIsNoteSplitNeededDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented { _ = try await self.synchronizer.isNoteSplitNeeded(accountUUID: self.accountUUID) }
    }

    func testPrepareNoteSplitDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented { _ = try await self.synchronizer.prepareNoteSplit(accountUUID: self.accountUUID) }
    }

    func testSubmitNoteSplitDefaultThrowsUnimplemented() async {
        let proposal = NoteSplitProposal(outputNotes: [Zatoshi(10_000)], fee: Zatoshi(1_000), proposalHandle: 0)
        let usk = TestsData(networkType: .testnet).spendingKey
        let options = MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: LightWalletEndpoint(address: "submit.example", port: 9067))
        await assertThrowsMigrationUnimplemented {
            _ = try await self.synchronizer.submitNoteSplit(accountUUID: self.accountUUID, proposal: proposal, usk: usk, options: options)
        }
    }

    func testProposeMigrationTransfersDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented {
            _ = try await self.synchronizer.proposeMigrationTransfers(accountUUID: self.accountUUID)
        }
    }

    func testProposeImmediateMigrationDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented { _ = try await self.synchronizer.proposeImmediateMigration(accountUUID: self.accountUUID) }
    }

    func testRecordImmediateMigrationDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented {
            try await self.synchronizer.recordImmediateMigration(accountUUID: self.accountUUID, txid: Data(repeating: 0x01, count: 32))
        }
    }

    func testResidualAfterMigrationDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented { _ = try await self.synchronizer.residualAfterMigration(accountUUID: self.accountUUID) }
    }

    func testLockMigrationResidualDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented { _ = try await self.synchronizer.lockMigrationResidual(accountUUID: self.accountUUID) }
    }

    func testUnlockMigrationResidualDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented { _ = try await self.synchronizer.unlockMigrationResidual(accountUUID: self.accountUUID) }
    }

    func testEstimateMigrationRunsDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented { _ = try await self.synchronizer.estimateMigrationRuns(accountUUID: self.accountUUID) }
    }

    func testSignAndStoreMigrationScheduleDefaultThrowsUnimplemented() async {
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 1, proposalHandle: 0, preparations: [])
        let usk = TestsData(networkType: .testnet).spendingKey
        await assertThrowsMigrationUnimplemented {
            try await self.synchronizer.signAndStoreMigrationSchedule(accountUUID: self.accountUUID, schedule, usk: usk)
        }
    }

    func testPerformMigrationBroadcastDefaultThrowsUnimplemented() async {
        let options = MigrationNetworkPrivacyOptions(useTor: false, submissionEndpoint: LightWalletEndpoint(address: "submit.example", port: 9067))
        await assertThrowsMigrationUnimplemented {
            _ = try await self.synchronizer.performMigrationBroadcast(
                accountUUID: self.accountUUID,
                MigrationBroadcastInstruction(id: 1),
                options: options
            )
        }
    }

    /// The one-argument convenience overload (`useEstimatedTip` defaulted to `false`) must reach the
    /// same protocol-extension default as the two-argument requirement it forwards to.
    func testHasOverdueMigrationTransfersOneArgOverloadDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented { _ = try await self.synchronizer.hasOverdueMigrationTransfers(accountUUID: self.accountUUID) }
    }

    func testHasOverdueMigrationTransfersDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented {
            _ = try await self.synchronizer.hasOverdueMigrationTransfers(accountUUID: self.accountUUID, useEstimatedTip: true)
        }
    }

    func testHasInvalidMigrationTransfersDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented { _ = try await self.synchronizer.hasInvalidMigrationTransfers(accountUUID: self.accountUUID) }
    }

    func testRestartCurrentMigrationStepDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented {
            _ = try await self.synchronizer.restartCurrentMigrationStep(accountUUID: self.accountUUID)
        }
    }

    func testRefreshStaleMigrationTransfersDefaultThrowsUnimplemented() async {
        let usk = TestsData(networkType: .testnet).spendingKey
        await assertThrowsMigrationUnimplemented {
            _ = try await self.synchronizer.refreshStaleMigrationTransfers(accountUUID: self.accountUUID, usk: usk)
        }
    }

    /// The nil-usk (external-signer/Keystone) lane must fall through to the same default as the
    /// real-usk call above -- `usk` being optional must not bypass the "unimplemented" default.
    func testRefreshStaleMigrationTransfersDefaultThrowsUnimplementedWithNilUsk() async {
        await assertThrowsMigrationUnimplemented {
            _ = try await self.synchronizer.refreshStaleMigrationTransfers(accountUUID: self.accountUUID, usk: nil)
        }
    }

    func testCreateUnsignedNoteSplitPCZTsDefaultThrowsUnimplemented() async {
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 1, proposalHandle: 0, preparations: [])
        await assertThrowsMigrationUnimplemented {
            _ = try await self.synchronizer.createUnsignedNoteSplitPCZTs(accountUUID: self.accountUUID, for: schedule)
        }
    }

    func testStoreSignedNoteSplitPCZTsDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented {
            _ = try await self.synchronizer.storeSignedNoteSplitPCZTs(
                accountUUID: self.accountUUID,
                [MigrationSignedTransferPczt(id: 0, pczt: Data([0x01, 0x02]))]
            )
        }
    }

    func testCreateUnsignedMigrationTransferPCZTsDefaultThrowsUnimplemented() async {
        let schedule = MigrationSchedule(transfers: [], estimatedDurationHours: 1, proposalHandle: 0, preparations: [])
        await assertThrowsMigrationUnimplemented {
            _ = try await self.synchronizer.createUnsignedMigrationTransferPCZTs(accountUUID: self.accountUUID, for: schedule)
        }
    }

    func testStoreSignedMigrationSchedulePCZTsDefaultThrowsUnimplemented() async {
        let signed = [MigrationSignedTransferPczt(id: 0, pczt: Data([0x03, 0x04]))]
        await assertThrowsMigrationUnimplemented {
            try await self.synchronizer.storeSignedMigrationSchedulePCZTs(accountUUID: self.accountUUID, signed)
        }
    }

    func testBatchMigrationPcztsForSigningDefaultThrowsUnimplemented() async {
        let pczts = [MigrationUnsignedTransferPczt(id: 0, pczt: Data([0x01, 0x02]), actions: 3)]
        await assertThrowsMigrationUnimplemented {
            _ = try await self.synchronizer.batchMigrationPcztsForSigning(pczts, maxActionsPerSession: MigrationSigningBudget.keystone)
        }
    }

    func testBuildKeystoneSignBatchQRPartsDefaultThrowsUnimplemented() async {
        let pczts = [MigrationUnsignedTransferPczt(id: 0, pczt: Data([0x01, 0x02]), actions: 3)]
        await assertThrowsMigrationUnimplemented {
            _ = try await self.synchronizer.buildKeystoneSignBatchQRParts(requestId: Data([0xAB]), pczts: pczts, maxFragmentLen: 200)
        }
    }

    func testDecodeKeystoneSignBatchPartDefaultThrowsUnimplemented() async {
        await assertThrowsMigrationUnimplemented {
            _ = try await self.synchronizer.decodeKeystoneSignBatchPart("ur:test", expectedRequestId: Data([0xAB]))
        }
    }

    func testApplyKeystoneBatchSignaturesDefaultThrowsUnimplemented() async {
        let pczts = [MigrationUnsignedTransferPczt(id: 0, pczt: Data([0x01, 0x02]), actions: 3)]
        await assertThrowsMigrationUnimplemented {
            _ = try await self.synchronizer.applyKeystoneBatchSignatures(pczts: pczts, batchSignResponse: Data([0x03, 0x04]))
        }
    }

    // MARK: - Inert defaults

    func testLocalAccountBalancesDefaultReturnsNil() async throws {
        let balances = try await synchronizer.getLocalAccountBalances()
        XCTAssertNil(balances)
    }

    /// `nil` is the correct session-start answer for the inert default too: no host-level
    /// conformer means no crank has ever run.
    func testNextMigrationWakeDefaultReturnsNil() async {
        let outlook = await synchronizer.nextMigrationWake(accountUUID: accountUUID)
        XCTAssertNil(outlook, "the inert default must report no retained outlook")
    }

    func testIsMigrationSyncBlockedDefaultReturnsFalse() async {
        let blocked = await synchronizer.isMigrationSyncBlocked()
        XCTAssertFalse(blocked, "the inert default must report unblocked (sync allowed)")
    }

    func testMigrationSyncBlockedStreamDefaultEmitsFalse() {
        var received: [Bool] = []
        let cancellable = synchronizer.migrationSyncBlockedStream.sink { received.append($0) }
        defer { cancellable.cancel() }

        XCTAssertEqual(received, [false], "the inert default stream must seed (and only ever emit) false")
    }

    /// Infallible by protocol contract (see `Synchronizer.resetKeystoneSignBatchDecoder()`'s doc):
    /// the inert default simply returns, unlike its three throwing Keystone-batch-signing siblings
    /// above.
    func testResetKeystoneSignBatchDecoderDefaultIsANoOp() async {
        await synchronizer.resetKeystoneSignBatchDecoder()
    }

    // MARK: - Wrapper-protocol `restartSync(at:)` defaults (source compatibility)

    /// [MOB-1850 review] `restartSync(at:)` was added to `ClosureSynchronizer` and
    /// `CombineSynchronizer` alongside `Synchronizer`, but only `Synchronizer` originally shipped a
    /// default implementation. Without one on the other two, any external conformer of either
    /// protocol that is not simply a thin forwarder to a `Synchronizer` -- `ClosureSDKSynchronizer`
    /// and `CombineSDKSynchronizer` both are, so neither exercises this -- would stop compiling the
    /// moment the member was added. `ClosureSynchronizerWithoutRestartSync` below is a compile-only
    /// double built to pin the fix: it conforms to `ClosureSynchronizer` without overriding
    /// `restartSync`, so this test only compiles at all if the default exists, and only passes if the
    /// default behaves correctly.
    func testClosureSynchronizerRestartSyncDefaultThrowsUnimplemented() {
        let sync: ClosureSynchronizer = ClosureSynchronizerWithoutRestartSync()
        var receivedError: Error?
        sync.restartSync(at: LightWalletEndpoint(address: "example.com", port: 443, secure: true)) { error in
            receivedError = error
        }
        assertUnimplemented(receivedError)
    }

    /// Same pin as above, for `CombineSynchronizer` -- see `CombineSynchronizerWithoutRestartSync`.
    func testCombineSynchronizerRestartSyncDefaultFailsWithUnimplemented() {
        let sync: CombineSynchronizer = CombineSynchronizerWithoutRestartSync()
        var receivedCompletion: Subscribers.Completion<Error>?
        let cancellable = sync.restartSync(at: LightWalletEndpoint(address: "example.com", port: 443, secure: true))
            .sink(receiveCompletion: { receivedCompletion = $0 }, receiveValue: { _ in })
        defer { cancellable.cancel() }

        guard case .failure(let error) = receivedCompletion else {
            XCTFail("Expected the default to fail the publisher, got \(String(describing: receivedCompletion))")
            return
        }
        assertUnimplemented(error)
    }

    // MARK: - Helpers

    /// Asserts `operation` throws a `LocalizedError` describing a missing default implementation --
    /// without depending on the file-private `MigrationUnimplemented` type itself, which this test
    /// file (unlike `Synchronizer.swift`) cannot name.
    private func assertThrowsMigrationUnimplemented(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected the migration default to throw", file: file, line: line)
        } catch let error as LocalizedError {
            XCTAssertEqual(
                error.errorDescription?.contains("has no default implementation"),
                true,
                "expected an 'unimplemented' style message, got: \(String(describing: error.errorDescription))",
                file: file,
                line: line
            )
        } catch {
            XCTFail("Expected a LocalizedError describing a missing default implementation, got \(error)", file: file, line: line)
        }
    }

    /// Non-async restatement of `assertThrowsMigrationUnimplemented`'s check, for the closure/Combine
    /// wrapper defaults above, which resolve synchronously rather than via `async throws`.
    private func assertUnimplemented(_ error: Error?, file: StaticString = #filePath, line: UInt = #line) {
        guard let localizedError = error as? LocalizedError else {
            XCTFail("Expected a LocalizedError describing a missing default implementation, got \(String(describing: error))", file: file, line: line)
            return
        }
        XCTAssertEqual(
            localizedError.errorDescription?.contains("has no default implementation"),
            true,
            "expected an 'unimplemented' style message, got: \(String(describing: localizedError.errorDescription))",
            file: file,
            line: line
        )
    }
}

/// A minimal `Synchronizer` conformer implementing only the protocol's previously-existing
/// (pre-migration) members. None of its stubs are ever exercised by these tests -- only the 31
/// migration-group members are called, and this type deliberately does not override any of them, so
/// every call falls through to the protocol-extension default under test.
private final class NonMigratingSynchronizer: Synchronizer {
    private static func unused(_ member: StaticString = #function) -> Never {
        fatalError("NonMigratingSynchronizer.\(member) is not exercised by the migration-defaults tests")
    }

    var alias: ZcashSynchronizerAlias { Self.unused() }
    var latestState: SynchronizerState { Self.unused() }
    var connectionState: ConnectionState { Self.unused() }
    var stateStream: AnyPublisher<SynchronizerState, Never> { Self.unused() }
    var eventStream: AnyPublisher<SynchronizerEvent, Never> { Self.unused() }
    var exchangeRateUSDStream: AnyPublisher<FiatCurrencyResult?, Never> { Self.unused() }

    func prepare(
        with seed: [UInt8]?,
        walletBirthday: BlockHeight?,
        name: String,
        keySource: String?
    ) async throws -> Initializer.InitializationResult { Self.unused() }

    func start(retry: Bool) async throws { Self.unused() }
    func stop() { Self.unused() }

    func getSaplingAddress(accountUUID: AccountUUID) async throws -> SaplingAddress { Self.unused() }
    func getUnifiedAddress(accountUUID: AccountUUID) async throws -> UnifiedAddress { Self.unused() }
    func getTransparentAddress(accountUUID: AccountUUID) async throws -> TransparentAddress { Self.unused() }
    func getCustomUnifiedAddress(accountUUID: AccountUUID, receivers: Set<ReceiverType>) async throws -> UnifiedAddress { Self.unused() }

    func proposeTransfer(accountUUID: AccountUUID, recipient: Recipient, amount: Zatoshi, memo: Memo?) async throws -> Proposal { Self.unused() }

    func proposeSendMax(accountUUID: AccountUUID, recipient: Recipient, memo: Memo?, mode: MaxSpendMode) async throws -> Proposal { Self.unused() }

    func proposeOrchardToIronwoodMigration(accountUUID: AccountUUID) async throws -> Proposal { Self.unused() }

    func proposeShielding(
        accountUUID: AccountUUID,
        shieldingThreshold: Zatoshi,
        memo: Memo,
        transparentReceiver: TransparentAddress?
    ) async throws -> Proposal? { Self.unused() }

    func createProposedTransactions(
        proposal: Proposal,
        spendingKey: UnifiedSpendingKey
    ) async throws -> AsyncThrowingStream<TransactionSubmitResult, Error> { Self.unused() }

    func proposefulfillingPaymentURI(_ uri: String, accountUUID: AccountUUID) async throws -> Proposal { Self.unused() }

    func createPCZTFromProposal(accountUUID: AccountUUID, proposal: Proposal) async throws -> Pczt { Self.unused() }
    func redactPCZTForSigner(pczt: Pczt) async throws -> Pczt { Self.unused() }
    func PCZTRequiresSaplingProofs(pczt: Pczt) async -> Bool { Self.unused() }
    func addProofsToPCZT(pczt: Pczt) async throws -> Pczt { Self.unused() }

    func createTransactionFromPCZT(
        pcztWithProofs: Pczt,
        pcztWithSigs: Pczt
    ) async throws -> AsyncThrowingStream<TransactionSubmitResult, Error> { Self.unused() }

    var transactions: [ZcashTransaction.Overview] { get async { Self.unused() } }
    var sentTransactions: [ZcashTransaction.Overview] { get async { Self.unused() } }
    var receivedTransactions: [ZcashTransaction.Overview] { get async { Self.unused() } }

    func paginatedTransactions(of kind: TransactionKind) -> PaginatedTransactionRepository { Self.unused() }

    func getMemos(for rawID: Data) async throws -> [Memo] { Self.unused() }
    func getMemos(for transaction: ZcashTransaction.Overview) async throws -> [Memo] { Self.unused() }
    func getRecipients(for transaction: ZcashTransaction.Overview) async -> [TransactionRecipient] { Self.unused() }
    func getTransactionOutputs(for transaction: ZcashTransaction.Overview) async -> [ZcashTransaction.Output] { Self.unused() }
    func allTransactions() async throws -> [ZcashTransaction.Overview] { Self.unused() }
    func allTransactions(from transaction: ZcashTransaction.Overview, limit: Int) async throws -> [ZcashTransaction.Overview] { Self.unused() }
    func latestHeight() async throws -> BlockHeight { Self.unused() }
    func refreshUTXOs(address: TransparentAddress, from height: BlockHeight) async throws -> RefreshedUTXOs { Self.unused() }
    func getAccountsBalances() async throws -> [AccountUUID: AccountBalance] { Self.unused() }
    func refreshExchangeRateUSD() { Self.unused() }
    func listAccounts() async throws -> [Account] { Self.unused() }

    // swiftlint:disable:next function_parameter_count
    func importAccount(
        ufvk: String,
        seedFingerprint: [UInt8]?,
        zip32AccountIndex: Zip32AccountIndex?,
        purpose: AccountPurpose,
        name: String,
        keySource: String?,
        birthday: BlockHeight?
    ) async throws -> AccountUUID { Self.unused() }

    func fetchTxidsWithMemoContaining(searchTerm: String) async throws -> [Data] { Self.unused() }
    func rescanFrom(height: BlockHeight) async throws { Self.unused() }
    func rewind(_ policy: RewindPolicy) -> AnyPublisher<Void, Error> { Self.unused() }
    func wipe() -> AnyPublisher<Void, Error> { Self.unused() }
    func switchTo(endpoint: LightWalletEndpoint) async throws { Self.unused() }
    func isSeedRelevantToAnyDerivedAccount(seed: [UInt8]) async throws -> Bool { Self.unused() }

    func evaluateBestOf(
        endpoints: [LightWalletEndpoint],
        fetchThresholdSeconds: Double,
        nBlocksToFetch: UInt64,
        kServers: Int,
        network: NetworkType
    ) async -> [LightWalletEndpoint] { Self.unused() }

    func evaluateServerSwitch(
        current: LightWalletEndpoint,
        candidates: [LightWalletEndpoint],
        fetchThresholdSeconds: Double,
        nBlocksToFetch: UInt64,
        network: NetworkType
    ) async -> LightWalletEndpoint? { Self.unused() }

    func estimateBirthdayHeight(for date: Date) -> BlockHeight { Self.unused() }
    func estimateTimestamp(for height: BlockHeight) -> TimeInterval? { Self.unused() }
    func tor(enabled: Bool) async throws { Self.unused() }
    func exchangeRateOverTor(enabled: Bool) async throws { Self.unused() }
    func isTorSuccessfullyInitialized() async -> Bool? { Self.unused() }
    func httpRequestOverTor(for request: URLRequest, retryLimit: UInt8) async throws -> (data: Data, response: HTTPURLResponse) { Self.unused() }
    func debugDatabase(sql: String) -> String { Self.unused() }

    func getSingleUseTransparentAddress(accountUUID: AccountUUID) async throws -> SingleUseTransparentAddress { Self.unused() }
    func checkSingleUseTransparentAddresses(accountUUID: AccountUUID) async throws -> TransparentAddressCheckResult { Self.unused() }
    func updateTransparentAddressTransactions(address: String) async throws -> TransparentAddressCheckResult { Self.unused() }
    func fetchUTXOsBy(address: String, accountUUID: AccountUUID) async throws -> TransparentAddressCheckResult { Self.unused() }
    func enhanceTransactionBy(txId: TxId) async throws -> Void { Self.unused() }
    func deleteAccount(_ accountUUID: AccountUUID) async throws -> Void { Self.unused() }

    // `getTreeState(height:)`, `broadcaster` and `restartSync(at:)` are intentionally left
    // unimplemented too, relying on their own pre-existing defaults -- this conformer implements the
    // bare minimum.
}

/// [MOB-1850 review] Compile-only double proving `ClosureSynchronizer` remains source-compatible
/// without an override for the `restartSync(at:completion:)` requirement. Every other member is a
/// `fatalError` stub: giving this protocol the full `NonMigratingSynchronizer` treatment (a real,
/// exercised conformer) would be disproportionate for pinning a single default, and unnecessary --
/// nothing here is ever called except `restartSync`, which deliberately falls through to the
/// protocol-extension default under test.
private final class ClosureSynchronizerWithoutRestartSync: ClosureSynchronizer {
    private static func unused(_ member: StaticString = #function) -> Never {
        fatalError("ClosureSynchronizerWithoutRestartSync.\(member) is not exercised by this test")
    }

    var alias: ZcashSynchronizerAlias { Self.unused() }
    var latestState: SynchronizerState { Self.unused() }
    var connectionState: ConnectionState { Self.unused() }
    var stateStream: AnyPublisher<SynchronizerState, Never> { Self.unused() }
    var eventStream: AnyPublisher<SynchronizerEvent, Never> { Self.unused() }

    func prepare(
        with seed: [UInt8]?,
        walletBirthday: BlockHeight?,
        name: String,
        keySource: String?,
        completion: @escaping (Result<Initializer.InitializationResult, Error>) -> Void
    ) { Self.unused() }

    func start(retry: Bool, completion: @escaping (Error?) -> Void) { Self.unused() }
    func stop() { Self.unused() }

    func getSaplingAddress(accountUUID: AccountUUID, completion: @escaping (Result<SaplingAddress, Error>) -> Void) { Self.unused() }
    func getUnifiedAddress(accountUUID: AccountUUID, completion: @escaping (Result<UnifiedAddress, Error>) -> Void) { Self.unused() }
    func getTransparentAddress(accountUUID: AccountUUID, completion: @escaping (Result<TransparentAddress, Error>) -> Void) { Self.unused() }

    func getCustomUnifiedAddress(
        accountUUID: AccountUUID,
        receivers: Set<ReceiverType>,
        completion: @escaping (Result<UnifiedAddress, Error>) -> Void
    ) { Self.unused() }

    func proposeTransfer(
        accountUUID: AccountUUID,
        recipient: Recipient,
        amount: Zatoshi,
        memo: Memo?,
        completion: @escaping (Result<Proposal, Error>) -> Void
    ) { Self.unused() }

    func proposeSendMax(
        accountUUID: AccountUUID,
        recipient: Recipient,
        memo: Memo?,
        mode: MaxSpendMode,
        completion: @escaping (Result<Proposal, Error>) -> Void
    ) { Self.unused() }

    func proposeOrchardToIronwoodMigration(accountUUID: AccountUUID, completion: @escaping (Result<Proposal, Error>) -> Void) { Self.unused() }

    func proposeShielding(
        accountUUID: AccountUUID,
        shieldingThreshold: Zatoshi,
        memo: Memo,
        transparentReceiver: TransparentAddress?,
        completion: @escaping (Result<Proposal?, Error>) -> Void
    ) { Self.unused() }

    func createProposedTransactions(
        proposal: Proposal,
        spendingKey: UnifiedSpendingKey,
        completion: @escaping (Result<AsyncThrowingStream<TransactionSubmitResult, Error>, Error>) -> Void
    ) { Self.unused() }

    func createPCZTFromProposal(accountUUID: AccountUUID, proposal: Proposal, completion: @escaping (Result<Pczt, Error>) -> Void) { Self.unused() }
    func redactPCZTForSigner(pczt: Pczt, completion: @escaping (Result<Pczt, Error>) -> Void) { Self.unused() }
    func PCZTRequiresSaplingProofs(pczt: Pczt, completion: @escaping (Bool) -> Void) { Self.unused() }
    func addProofsToPCZT(pczt: Pczt, completion: @escaping (Result<Pczt, Error>) -> Void) { Self.unused() }

    func createTransactionFromPCZT(
        pcztWithProofs: Pczt,
        pcztWithSigs: Pczt,
        completion: @escaping (Result<AsyncThrowingStream<TransactionSubmitResult, Error>, Error>) -> Void
    ) { Self.unused() }

    func listAccounts(completion: @escaping (Result<[Account], Error>) -> Void) { Self.unused() }

    func importAccount(
        ufvk: String,
        seedFingerprint: [UInt8]?,
        zip32AccountIndex: Zip32AccountIndex?,
        purpose: AccountPurpose,
        name: String,
        keySource: String?,
        birthday: BlockHeight?,
        completion: @escaping (Result<AccountUUID, Error>) -> Void
    ) async throws { Self.unused() }

    func clearedTransactions(completion: @escaping ([ZcashTransaction.Overview]) -> Void) { Self.unused() }
    func sentTranscations(completion: @escaping ([ZcashTransaction.Overview]) -> Void) { Self.unused() }
    func receivedTransactions(completion: @escaping ([ZcashTransaction.Overview]) -> Void) { Self.unused() }
    func paginatedTransactions(of kind: TransactionKind) -> PaginatedTransactionRepository { Self.unused() }
    func getMemos(for transaction: ZcashTransaction.Overview, completion: @escaping (Result<[Memo], Error>) -> Void) { Self.unused() }
    func getRecipients(for transaction: ZcashTransaction.Overview, completion: @escaping ([TransactionRecipient]) -> Void) { Self.unused() }

    func allConfirmedTransactions(
        from transaction: ZcashTransaction.Overview,
        limit: Int,
        completion: @escaping (Result<[ZcashTransaction.Overview], Error>) -> Void
    ) { Self.unused() }

    func latestHeight(completion: @escaping (Result<BlockHeight, Error>) -> Void) { Self.unused() }

    func refreshUTXOs(address: TransparentAddress, from height: BlockHeight, completion: @escaping (Result<RefreshedUTXOs, Error>) -> Void) {
        Self.unused()
    }

    func getAccountsBalances(_ completion: @escaping (Result<[AccountUUID: AccountBalance], Error>) -> Void) { Self.unused() }
    func getLocalAccountBalances(_ completion: @escaping (Result<[AccountUUID: AccountBalance]?, Error>) -> Void) { Self.unused() }

    func refreshExchangeRateUSD() { Self.unused() }
    func estimateBirthdayHeight(for date: Date, completion: @escaping (BlockHeight) -> Void) { Self.unused() }

    func httpRequestOverTor(
        for request: URLRequest,
        retryLimit: UInt8,
        completion: @escaping (Result<(data: Data, response: HTTPURLResponse), Error>) -> Void
    ) { Self.unused() }

    func rewind(_ policy: RewindPolicy) -> CompletablePublisher<Error> { Self.unused() }
    func wipe() -> CompletablePublisher<Error> { Self.unused() }
    func rescanFrom(height: BlockHeight, completion: @escaping (Error?) -> Void) { Self.unused() }

    // `broadcaster`, `transactionSubmissionStatus(for:completion:)` and `restartSync(at:completion:)`
    // are intentionally left unimplemented, relying on their protocol-extension defaults -- the last
    // one is the member this double exists to exercise.
}

/// [MOB-1850 review] Compile-only double proving `CombineSynchronizer` remains source-compatible
/// without an override for the `restartSync(at:)` requirement. See
/// `ClosureSynchronizerWithoutRestartSync`'s doc for why a `fatalError`-stubbed double, not a real
/// conformer, is the proportionate way to pin this.
private final class CombineSynchronizerWithoutRestartSync: CombineSynchronizer {
    private static func unused(_ member: StaticString = #function) -> Never {
        fatalError("CombineSynchronizerWithoutRestartSync.\(member) is not exercised by this test")
    }

    var alias: ZcashSynchronizerAlias { Self.unused() }
    var latestState: SynchronizerState { Self.unused() }
    var connectionState: ConnectionState { Self.unused() }
    var stateStream: AnyPublisher<SynchronizerState, Never> { Self.unused() }
    var eventStream: AnyPublisher<SynchronizerEvent, Never> { Self.unused() }

    func prepare(
        with seed: [UInt8]?,
        walletBirthday: BlockHeight?,
        name: String,
        keySource: String?
    ) -> SinglePublisher<Initializer.InitializationResult, Error> { Self.unused() }

    func start(retry: Bool) -> CompletablePublisher<Error> { Self.unused() }
    func stop() { Self.unused() }

    func getSaplingAddress(accountUUID: AccountUUID) -> SinglePublisher<SaplingAddress, Error> { Self.unused() }
    func getUnifiedAddress(accountUUID: AccountUUID) -> SinglePublisher<UnifiedAddress, Error> { Self.unused() }
    func getTransparentAddress(accountUUID: AccountUUID) -> SinglePublisher<TransparentAddress, Error> { Self.unused() }

    func getCustomUnifiedAddress(
        accountUUID: AccountUUID,
        receivers: Set<ReceiverType>
    ) -> SinglePublisher<UnifiedAddress, Error> { Self.unused() }

    func proposeTransfer(
        accountUUID: AccountUUID,
        recipient: Recipient,
        amount: Zatoshi,
        memo: Memo?
    ) -> SinglePublisher<Proposal, Error> { Self.unused() }

    func proposeSendMax(
        accountUUID: AccountUUID,
        recipient: Recipient,
        memo: Memo?,
        mode: MaxSpendMode
    ) -> SinglePublisher<Proposal, Error> { Self.unused() }

    func proposeOrchardToIronwoodMigration(accountUUID: AccountUUID) -> SinglePublisher<Proposal, Error> { Self.unused() }

    func proposeShielding(
        accountUUID: AccountUUID,
        shieldingThreshold: Zatoshi,
        memo: Memo,
        transparentReceiver: TransparentAddress?
    ) -> SinglePublisher<Proposal?, Error> { Self.unused() }

    func createProposedTransactions(
        proposal: Proposal,
        spendingKey: UnifiedSpendingKey
    ) -> SinglePublisher<AsyncThrowingStream<TransactionSubmitResult, Error>, Error> { Self.unused() }

    func createPCZTFromProposal(accountUUID: AccountUUID, proposal: Proposal) -> SinglePublisher<Pczt, Error> { Self.unused() }
    func redactPCZTForSigner(pczt: Pczt) -> SinglePublisher<Pczt, Error> { Self.unused() }
    func PCZTRequiresSaplingProofs(pczt: Pczt) -> SinglePublisher<Bool, Never> { Self.unused() }
    func addProofsToPCZT(pczt: Pczt) -> SinglePublisher<Pczt, Error> { Self.unused() }

    func createTransactionFromPCZT(
        pcztWithProofs: Pczt,
        pcztWithSigs: Pczt
    ) -> SinglePublisher<AsyncThrowingStream<TransactionSubmitResult, Error>, Error> { Self.unused() }

    func proposefulfillingPaymentURI(_ uri: String, accountUUID: AccountUUID) -> SinglePublisher<Proposal, Error> { Self.unused() }

    func listAccounts() -> SinglePublisher<[Account], Error> { Self.unused() }

    func importAccount(
        ufvk: String,
        seedFingerprint: [UInt8]?,
        zip32AccountIndex: Zip32AccountIndex?,
        purpose: AccountPurpose,
        name: String,
        keySource: String?,
        birthday: BlockHeight?
    ) async throws -> SinglePublisher<AccountUUID, Error> { Self.unused() }

    var allTransactions: SinglePublisher<[ZcashTransaction.Overview], Never> { Self.unused() }
    var sentTransactions: SinglePublisher<[ZcashTransaction.Overview], Never> { Self.unused() }
    var receivedTransactions: SinglePublisher<[ZcashTransaction.Overview], Never> { Self.unused() }

    func paginatedTransactions(of kind: TransactionKind) -> PaginatedTransactionRepository { Self.unused() }
    func getMemos(for transaction: ZcashTransaction.Overview) -> SinglePublisher<[Memo], Error> { Self.unused() }
    func getRecipients(for transaction: ZcashTransaction.Overview) -> SinglePublisher<[TransactionRecipient], Never> { Self.unused() }

    func allTransactions(from transaction: ZcashTransaction.Overview, limit: Int) -> SinglePublisher<[ZcashTransaction.Overview], Error> {
        Self.unused()
    }

    func latestHeight() -> SinglePublisher<BlockHeight, Error> { Self.unused() }
    func refreshUTXOs(address: TransparentAddress, from height: BlockHeight) -> SinglePublisher<RefreshedUTXOs, Error> { Self.unused() }
    func getLocalAccountBalances() -> SinglePublisher<[AccountUUID: AccountBalance]?, Error> { Self.unused() }

    func refreshExchangeRateUSD() { Self.unused() }
    func estimateBirthdayHeight(for date: Date) -> SinglePublisher<BlockHeight, Error> { Self.unused() }

    func httpRequestOverTor(
        for request: URLRequest,
        retryLimit: UInt8
    ) -> SinglePublisher<(data: Data, response: HTTPURLResponse), Error> { Self.unused() }

    func rewind(_ policy: RewindPolicy) -> CompletablePublisher<Error> { Self.unused() }
    func wipe() -> CompletablePublisher<Error> { Self.unused() }
    func rescanFrom(height: BlockHeight) -> CompletablePublisher<Error> { Self.unused() }

    // `broadcaster`, `transactionSubmissionStatus(for:)` and `restartSync(at:)` are intentionally
    // left unimplemented, relying on their protocol-extension defaults -- the last one is the member
    // this double exists to exercise.
}
