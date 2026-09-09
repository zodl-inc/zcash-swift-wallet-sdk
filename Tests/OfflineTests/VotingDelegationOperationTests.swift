import SQLite3
import XCTest

@testable import TestUtils
@testable import ZcashLightClientKit

final class VotingDelegationOperationTests: XCTestCase {
    private var paths: [String] = []
    private let round = String(repeating: "00", count: 32)
    private let endpoint = URL(string: "https://pir.example")!
    private let layout = VotingPirLayout(pirDepth: 16, tier0Layers: 4, tier1Layers: 4, polyLen: 2048)

    override func tearDown() {
        for path in paths { try? FileManager.default.removeItem(atPath: path) }
        super.tearDown()
    }

    func testMatchingPersistedSetupReturnsSameRetainedOperation() async throws {
        let backend = try makeBackend()
        let params = try makeParams()
        let first = try await backend.delegationOperation(
            params: params,
            pirEndpoints: [endpoint],
            expectedSnapshotHeight: 100,
            layout: layout
        )
        let second = try await backend.delegationOperation(
            params: params,
            pirEndpoints: [endpoint],
            expectedSnapshotHeight: 100,
            layout: layout
        )
        XCTAssertTrue(first === second, "Matching persisted setup must share its retained producer")
        await backend.cancelDelegationOperationsAndWait()
    }

    func testMissingPersistedSetupIsRejectedBeforeAdmission() async throws {
        let backend = try makeBackend(persistSetup: false)
        do {
            _ = try await backend.delegationOperation(
                params: makeParams(),
                pirEndpoints: [endpoint],
                expectedSnapshotHeight: 100,
                layout: layout
            )
            XCTFail("Missing persisted PCZT setup must not create an operation")
        } catch {
            XCTAssertTrue(error is VotingRustBackendError)
        }
    }

    func testSpeculativeResultRunsOneUtilityProofWithoutBoost() async throws {
        let backend = try makeBackend()
        let fixture = makeResult()
        let operation = try await backend.delegationOperation(
            params: makeParams(),
            pirEndpoints: [endpoint],
            expectedSnapshotHeight: 100,
            layout: layout,
            pirResolver: PirSnapshotResolver(probe: MatchingProbe()),
            proveEntry: { _, _, _, _ in
                XCTAssertEqual(Task.currentPriority, .utility)
                XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 0)
                return fixture
            }
        )
        let result = try await operation.result(intent: .speculative)
        XCTAssertEqual(result.proof, [7, 7, 7, 7])
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 0)
    }

    func testMatchingWaitersShareOneProofAndInteractivePromotionBalancesBoost() async throws {
        let backend = try makeBackend()
        let proof = ProofGate(result: makeResult())
        let operation = try await makeOperation(backend, proof: proof)
        let first = Task { try await operation.result(intent: .speculative) }
        await fulfillment(of: [proof.entered], timeout: 5)
        let replayed = expectation(description: "interactive subscriber receives progress")
        let second = Task {
            try await operation.result(intent: .interactive) { _ in replayed.fulfill() }
        }
        await fulfillment(of: [replayed], timeout: 5)
        let matching = try await makeOperation(backend, proof: proof)
        XCTAssertTrue(operation === matching)
        await matching.promote()
        XCTAssertEqual(proof.count, 1)
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 1)
        proof.release.signal()
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult.proof, secondResult.proof)
        XCTAssertEqual(proof.count, 1)
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 0)
    }

    func testCancellingOneWaiterLeavesOtherWaiterAndProducerAlive() async throws {
        let backend = try makeBackend()
        let proof = ProofGate(result: makeResult())
        let operation = try await makeOperation(backend, proof: proof)
        let first = Task { try await operation.result(intent: .speculative) }
        await fulfillment(of: [proof.entered], timeout: 5)
        let subscribed = expectation(description: "second waiter subscribed")
        let second = Task { try await operation.result(intent: .speculative) { _ in subscribed.fulfill() } }
        await fulfillment(of: [subscribed], timeout: 5)
        first.cancel()
        assertCancelled(await first.result)
        XCTAssertEqual(proof.count, 1)
        proof.release.signal()
        let result = try await second.value
        XCTAssertEqual(result.proof, [7, 7, 7, 7])
    }

    func testCompletedOperationIsReusedWithoutProofReentry() async throws {
        let backend = try makeBackend()
        let proof = ProofGate(result: makeResult())
        proof.release.signal()
        let first = try await makeOperation(backend, proof: proof)
        _ = try await first.result(intent: .speculative)
        let second = try await makeOperation(backend, proof: proof)
        XCTAssertTrue(first === second)
        _ = try await second.result(intent: .interactive)
        XCTAssertEqual(proof.count, 1)
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 0)
    }

    func testDifferentBundlesWaitForSerialProofEntry() async throws {
        let backend = try makeBackend()
        let firstProof = ProofGate(result: makeResult())
        let secondProof = ProofGate(result: makeResult())
        let first = try await makeOperation(backend, proof: firstProof)
        let second = try await makeOperation(backend, proof: secondProof, bundle: 1)
        XCTAssertFalse(first === second)
        let firstTask = Task { try await first.result(intent: .speculative) }
        await fulfillment(of: [firstProof.entered], timeout: 5)
        let secondTask = Task { try await second.result(intent: .speculative) }
        // Promotion returns only after the operation's synchronized state transition.
        await second.promote()
        XCTAssertEqual(secondProof.count, 0)
        firstProof.release.signal()
        _ = try await firstTask.value
        await fulfillment(of: [secondProof.entered], timeout: 5)
        secondProof.release.signal()
        _ = try await secondTask.value
        XCTAssertEqual(firstProof.count, 1)
        XCTAssertEqual(secondProof.count, 1)
    }

    func testQueuedCancellationFinishesWithoutWaitingForAnotherProof() async throws {
        let backend = try makeBackend()
        let activeProof = ProofGate(result: makeResult())
        let queuedProof = ProofGate(result: makeResult())
        let active = try await makeOperation(backend, proof: activeProof)
        let queued = try await makeOperation(backend, proof: queuedProof, bundle: 1)
        let activeTask = Task { try await active.result(intent: .speculative) }
        await fulfillment(of: [activeProof.entered], timeout: 5)
        let subscribed = expectation(description: "queued operation started")
        let queuedTask = Task {
            try await queued.result(intent: .speculative) { value in
                if value == 0 { subscribed.fulfill() }
            }
        }
        await fulfillment(of: [subscribed], timeout: 5)
        await queued.cancelAndWait()
        assertCancelled(await queuedTask.result)
        XCTAssertEqual(queuedProof.count, 0)
        activeProof.release.signal()
        _ = try await activeTask.value
    }

    func testCancelBeforeResultNeverEntersProof() async throws {
        let backend = try makeBackend()
        let proof = ProofGate(result: makeResult())
        let operation = try await makeOperation(backend, proof: proof)
        await operation.cancelAndWait()
        let task = Task { try await operation.result(intent: .interactive) }
        assertCancelled(await task.result)
        XCTAssertEqual(proof.count, 0)
    }

    func testCancellationDuringPirResolutionPreventsProofEntry() async throws {
        let backend = try makeBackend()
        let probeEntered = expectation(description: "probe entered")
        let release = Gate()
        let proof = ProofGate(result: makeResult())
        let operation = try await backend.delegationOperation(
            params: makeParams(),
            pirEndpoints: [endpoint],
            expectedSnapshotHeight: 100,
            layout: layout,
            pirResolver: PirSnapshotResolver(probe: GatedProbe(entered: probeEntered, release: release)),
            proveEntry: proof.prove
        )
        let task = Task { try await operation.result(intent: .speculative) }
        await fulfillment(of: [probeEntered], timeout: 5)
        let drain = Task { await operation.cancelAndWait() }
        assertCancelled(await task.result)
        release.open()
        await drain.value
        XCTAssertEqual(proof.count, 0)
    }

    func testCancellationAfterEntryRetainsMatchingOperationUntilReturn() async throws {
        let backend = try makeBackend()
        let proof = ProofGate(result: makeResult())
        let operation = try await makeOperation(backend, proof: proof)
        let task = Task { try await operation.result(intent: .interactive) }
        await fulfillment(of: [proof.entered], timeout: 5)
        let finished = LockedCounter()
        let drain = Task {
            await operation.cancelAndWait()
            finished.increment()
        }
        assertCancelled(await task.result)
        let matching = try await makeOperation(backend, proof: proof)
        XCTAssertTrue(operation === matching)
        XCTAssertEqual(finished.value, 0)
        XCTAssertEqual(proof.count, 1)
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 1)
        proof.release.signal()
        await drain.value
        XCTAssertEqual(finished.value, 1)
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 0)
    }

    func testBackendDrainFencesDeliveryAndWaitsBeforeCloseAndReopen() async throws {
        let backend = try makeBackend()
        let path = try XCTUnwrap(paths.last)
        let proof = ProofGate(result: makeResult())
        let operation = try await makeOperation(backend, proof: proof)
        let task = Task { try await operation.result(intent: .speculative) }
        await fulfillment(of: [proof.entered], timeout: 5)
        let closed = LockedCounter()
        let drain = Task {
            await backend.cancelDelegationOperationsAndWait()
            backend.close()
            closed.increment()
        }
        assertCancelled(await task.result)
        XCTAssertEqual(closed.value, 0)
        proof.release.signal()
        await drain.value
        XCTAssertEqual(closed.value, 1)
        try backend.open(path: path, networkId: 1)
        try backend.setWalletId("operation-wallet")
        let replacement = try await makeOperation(backend, proof: proof)
        XCTAssertFalse(operation === replacement)
        let stale = Task { try await operation.result(intent: .speculative) }
        assertCancelled(await stale.result)
        await backend.cancelDelegationOperationsAndWait()
    }

    func testFailureReleasesBoostAndAllowsNewAttempt() async throws {
        let backend = try makeBackend()
        let fixture = makeResult()
        let failed = try await backend.delegationOperation(
            params: makeParams(),
            pirEndpoints: [endpoint],
            expectedSnapshotHeight: 100,
            layout: layout,
            pirResolver: PirSnapshotResolver(probe: MatchingProbe()),
            proveEntry: { _, _, _, _ in throw VotingRustBackendError.invalidData("fixture failure") }
        )
        do {
            _ = try await failed.result(intent: .interactive)
            XCTFail("Proof failure must reach its subscriber")
        } catch {
            XCTAssertEqual(error as? VotingRustBackendError, .invalidData("fixture failure"))
        }
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 0)
        let retry = try await backend.delegationOperation(
            params: makeParams(),
            pirEndpoints: [endpoint],
            expectedSnapshotHeight: 100,
            layout: layout,
            pirResolver: PirSnapshotResolver(probe: MatchingProbe()),
            proveEntry: { _, _, _, _ in fixture }
        )
        XCTAssertFalse(failed === retry)
        let result = try await retry.result(intent: .speculative)
        XCTAssertEqual(result.proof, fixture.proof)
    }

    func testEveryProofAndPirInputParticipatesInIdentity() async throws {
        let backend = try makeBackend()
        let original = try makeParams()
        let first = try await backend.delegationOperation(
            params: original,
            pirEndpoints: [endpoint],
            expectedSnapshotHeight: 100,
            layout: layout
        )
        let variants = [
            VotingDelegationKeyInputs(
                fvk: [UInt8](repeating: 6, count: 96),
                hotkeyStoredSecret: original.keys.hotkeyStoredSecret,
                seedFingerprint: original.keys.seedFingerprint,
                accountIndex: 0,
                roundName: "operation-round"
            ),
            VotingDelegationKeyInputs(
                fvk: original.keys.fvk,
                hotkeyStoredSecret: [UInt8](repeating: 7, count: 32),
                seedFingerprint: original.keys.seedFingerprint,
                accountIndex: 0,
                roundName: "operation-round"
            ),
            VotingDelegationKeyInputs(
                fvk: original.keys.fvk,
                hotkeyStoredSecret: original.keys.hotkeyStoredSecret,
                seedFingerprint: [UInt8](repeating: 8, count: 32),
                accountIndex: 0,
                roundName: "operation-round"
            ),
            VotingDelegationKeyInputs(
                fvk: original.keys.fvk,
                hotkeyStoredSecret: original.keys.hotkeyStoredSecret,
                seedFingerprint: original.keys.seedFingerprint,
                accountIndex: 1,
                roundName: "operation-round"
            ),
            VotingDelegationKeyInputs(
                fvk: original.keys.fvk,
                hotkeyStoredSecret: original.keys.hotkeyStoredSecret,
                seedFingerprint: original.keys.seedFingerprint,
                accountIndex: 0,
                roundName: "other-round-name"
            )
        ]
        for keys in variants {
            let params = VotingDelegationProofParams(roundId: round, bundleIndex: 0, notes: [], keys: keys)
            let other = try await backend.delegationOperation(
                params: params,
                pirEndpoints: [endpoint],
                expectedSnapshotHeight: 100,
                layout: layout
            )
            XCTAssertFalse(first === other)
        }
        let differentEndpoint = try await backend.delegationOperation(
            params: original,
            pirEndpoints: [URL(string: "https://other.example")!],
            expectedSnapshotHeight: 100,
            layout: layout
        )
        XCTAssertFalse(first === differentEndpoint)
        let differentLayout = try await backend.delegationOperation(
            params: original,
            pirEndpoints: [endpoint],
            expectedSnapshotHeight: 100,
            layout: VotingPirLayout(pirDepth: 17, tier0Layers: 4, tier1Layers: 4, polyLen: 2048)
        )
        XCTAssertFalse(first === differentLayout)
        await backend.cancelDelegationOperationsAndWait()
    }

    func testChangedPersistedSighashGetsNewOperationAndSnapshotMismatchIsRejected() async throws {
        let backend = try makeBackend()
        let proof = ProofGate(result: makeResult())
        let original = try await makeOperation(backend, proof: proof)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(try XCTUnwrap(paths.last), &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "UPDATE bundles SET pczt_sighash = randomblob(32)", nil, nil, nil), SQLITE_OK)
        let changed = try await makeOperation(backend, proof: proof)
        XCTAssertFalse(original === changed)
        do {
            _ = try await backend.delegationOperation(
                params: makeParams(),
                pirEndpoints: [endpoint],
                expectedSnapshotHeight: 101,
                layout: layout
            )
            XCTFail("Mismatched snapshot must be rejected")
        } catch {
            XCTAssertTrue(error is VotingRustBackendError)
        }
        await backend.cancelDelegationOperationsAndWait()
    }

    func testWalletMutationInvalidatesPreviouslyAdmittedOperation() async throws {
        let backend = try makeBackend()
        let proof = ProofGate(result: makeResult())
        let operation = try await makeOperation(backend, proof: proof)
        try backend.setWalletId("another-wallet")
        let task = Task { try await operation.result(intent: .speculative) }
        assertCancelled(await task.result)
        XCTAssertEqual(proof.count, 0)
        do {
            _ = try await makeOperation(backend, proof: proof)
            XCTFail("New wallet must not inherit the previous wallet's persisted setup")
        } catch {
            XCTAssertTrue(error is VotingRustBackendError)
        }
    }

    func testDrainJoinsAlreadyRunningProgressCallback() async throws {
        let backend = try makeBackend()
        let proof = ProofGate(result: makeResult())
        let operation = try await makeOperation(backend, proof: proof)
        let callbackEntered = expectation(description: "progress callback entered")
        let callbackRelease = DispatchSemaphore(value: 0)
        let callbacks = LockedCounter()
        let task = Task {
            try await operation.result(intent: .speculative) { _ in
                callbacks.increment()
                callbackEntered.fulfill()
                callbackRelease.wait()
            }
        }
        await fulfillment(of: [callbackEntered, proof.entered], timeout: 5)
        let drained = LockedCounter()
        let drain = Task {
            await backend.cancelDelegationOperationsAndWait()
            drained.increment()
        }
        assertCancelled(await task.result)
        proof.release.signal()
        XCTAssertEqual(drained.value, 0)
        callbackRelease.signal()
        await drain.value
        XCTAssertEqual(callbacks.value, 1)
        XCTAssertEqual(drained.value, 1)
    }

    func testPersistedCompletedProofSurvivesReopenAndSkipsPirAndProving() async throws {
        let backend = try makeBackend()
        let path = try XCTUnwrap(paths.last)
        let params = try plantCompletedProof(backend: backend, path: path)
        backend.close()
        try backend.open(path: path, networkId: 1)
        try backend.setWalletId("operation-wallet")
        let operation = try await backend.delegationOperation(
            params: params,
            pirEndpoints: [endpoint],
            expectedSnapshotHeight: 100,
            layout: layout,
            pirResolver: PirSnapshotResolver(probe: RejectingProbe()),
            proveEntry: { _, _, _, _ in
                XCTFail("Persisted proof must not enter the prover again")
                throw VotingRustBackendError.invalidData("unexpected proof entry")
            }
        )
        let result = try await operation.result(intent: .speculative)
        XCTAssertEqual(result.proof, [1, 2, 3])
        XCTAssertEqual(result.publicInputs.count, 14)
        XCTAssertEqual(result.nfSigned, [UInt8](repeating: 0, count: 32))
        await backend.cancelDelegationOperationsAndWait()
    }

    private struct RejectingProbe: PirSnapshotProbing {
        func probe(url: String, expectedSnapshotHeight: BlockHeight) async -> PirSnapshotProbeOutcome {
            XCTFail("Durable proof reuse must not probe PIR")
            return PirSnapshotProbeOutcome(url: url, status: .unreachable(reason: "offline"))
        }
    }

    private func plantCompletedProof(backend: VotingRustBackend, path: String) throws -> VotingDelegationProofParams {
        let derivation = TestsData(networkType: .mainnet).derivationTools
        let spending = try derivation.deriveUnifiedSpendingKey(seed: [UInt8](repeating: 1, count: 32), accountIndex: Zip32AccountIndex(0))
        let viewing = try derivation.deriveUnifiedFullViewingKey(from: spending)
        let fvk = try VotingRustBackend.extractOrchardFvk(ufvk: viewing.stringEncoded, networkId: 1)
        let hotkey = try VotingRustBackend.generateHotkey(networkId: 1)
        let van = try VotingRustBackend.vanCommitment(
            hotkey: hotkey,
            networkId: 1,
            roundId: round,
            totalNoteValue: 13_000_000,
            vanCommRand: [UInt8](repeating: 0, count: 32)
        )
        let note = VotingNoteInfo(
            commitment: [UInt8](repeating: 1, count: 32),
            nullifier: [UInt8](repeating: 2, count: 32),
            value: 13_000_000,
            position: 0,
            diversifier: [UInt8](repeating: 0, count: 11),
            rho: [UInt8](repeating: 3, count: 32),
            rseed: [UInt8](repeating: 4, count: 32),
            scope: 0,
            ufvkStr: viewing.stringEncoded
        )
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        // With the fixture's zero alpha, rk is the FVK's encoded spend-validating key.
        let rk = fvk.prefix(32).map { String(format: "%02x", $0) }.joined()
        let commitment = van.map { String(format: "%02x", $0) }.joined()
        let effects = "01\(String(repeating: "00", count: 820))"
        let sql = """
            UPDATE bundles SET note_positions_blob = zeroblob(8), alpha = zeroblob(32), rk = X'\(rk)',
                nf_signed = zeroblob(32), cmx_new = zeroblob(32), gov_comm = X'\(commitment)',
                gov_nullifiers_blob = zeroblob(160), tx1_effects = X'\(effects)',
                van_comm_rand = zeroblob(32), total_note_value = 13000000, address_index = 0
            WHERE bundle_index = 0;
            INSERT INTO proofs (round_id, wallet_id, bundle_index, proof, success, created_at)
            VALUES ('\(round)', 'operation-wallet', 0, X'010203', 1, 0);
            """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        return VotingDelegationProofParams(
            roundId: round,
            bundleIndex: 0,
            notes: [note],
            keys: VotingDelegationKeyInputs(
                fvk: fvk,
                hotkeyStoredSecret: hotkey.storedSecret,
                seedFingerprint: [UInt8](repeating: 4, count: 32),
                accountIndex: 0,
                roundName: "fixture"
            )
        )
    }

    private func makeOperation(
        _ backend: VotingRustBackend,
        proof: ProofGate,
        bundle: UInt32 = 0
    ) async throws -> VotingDelegationOperation {
        try await backend.delegationOperation(
            params: makeParams(bundle: bundle),
            pirEndpoints: [endpoint],
            expectedSnapshotHeight: 100,
            layout: layout,
            pirResolver: PirSnapshotResolver(probe: MatchingProbe()),
            proveEntry: proof.prove
        )
    }

    private func assertCancelled(_ result: Result<VotingDelegationProofResult, Error>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try result.get(), file: file, line: line) { error in
            XCTAssertTrue(error is CancellationError, file: file, line: line)
        }
    }

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    private final class ProofGate: @unchecked Sendable {
        let entered = XCTestExpectation(description: "proof entered")
        let release = DispatchSemaphore(value: 0)
        private let entries = LockedCounter()
        private let fixture: VotingDelegationProofResult
        var count: Int { entries.value }
        init(result: VotingDelegationProofResult) { fixture = result }
        lazy var prove: VotingDelegationProveEntry = { [self] _, _, _, progress in
            entries.increment()
            progress?(0.25)
            entered.fulfill()
            release.wait()
            return fixture
        }
    }

    private struct GatedProbe: PirSnapshotProbing {
        let entered: XCTestExpectation
        let release: Gate
        func probe(url: String, expectedSnapshotHeight: BlockHeight) async -> PirSnapshotProbeOutcome {
            entered.fulfill()
            await release.wait()
            return PirSnapshotProbeOutcome(url: url, status: .matching(height: expectedSnapshotHeight))
        }
    }

    private struct MatchingProbe: PirSnapshotProbing {
        func probe(url: String, expectedSnapshotHeight: BlockHeight) async -> PirSnapshotProbeOutcome {
            PirSnapshotProbeOutcome(url: url, status: .matching(height: expectedSnapshotHeight))
        }
    }

    private func makeResult() -> VotingDelegationProofResult {
        VotingDelegationProofResult(
            proof: [7, 7, 7, 7],
            publicInputs: [[8, 8]],
            nfSigned: [9],
            cmxNew: [10],
            govNullifiers: [[11]],
            vanComm: [12],
            randomizedKey: [13]
        )
    }

    private func makeBackend(persistSetup: Bool = true) throws -> VotingRustBackend {
        let path = "\(NSTemporaryDirectory())VotingDelegationOperationTests-\(UUID().uuidString).sqlite"
        paths.append(path)
        let backend = VotingRustBackend()
        try backend.open(path: path, networkId: 1)
        try backend.setWalletId("operation-wallet")
        if persistSetup {
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(path, &database), SQLITE_OK)
            defer { sqlite3_close(database) }
            let sql = """
                INSERT INTO rounds (round_id, wallet_id, network, snapshot_height, ea_pk, nc_root, nullifier_imt_root, created_at)
                VALUES ('\(round)', 'operation-wallet', 'mainnet', 100, zeroblob(32), zeroblob(32), zeroblob(32), 0);
                INSERT INTO bundles (round_id, wallet_id, bundle_index, pczt_sighash)
                VALUES ('\(round)', 'operation-wallet', 0, zeroblob(32));
                INSERT INTO bundles (round_id, wallet_id, bundle_index, pczt_sighash)
                VALUES ('\(round)', 'operation-wallet', 1, zeroblob(32));
                """
            XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        }
        return backend
    }

    private func makeParams(bundle: UInt32 = 0) throws -> VotingDelegationProofParams {
        VotingDelegationProofParams(
            roundId: round,
            bundleIndex: bundle,
            notes: [],
            keys: VotingDelegationKeyInputs(
                fvk: [UInt8](repeating: 3, count: votingOrchardFvkByteCount),
                hotkeyStoredSecret: [UInt8](repeating: 5, count: 32),
                seedFingerprint: [UInt8](repeating: 4, count: votingSeedFingerprintByteCount),
                accountIndex: 0,
                roundName: "operation-round"
            )
        )
    }
}
