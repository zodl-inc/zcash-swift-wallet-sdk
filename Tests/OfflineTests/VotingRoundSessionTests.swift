//
//  VotingRoundSessionTests.swift
//  ZcashLightClientKitTests
//

import XCTest
import SwiftProtobuf
@testable import TestUtils
@testable import ZcashLightClientKit

/// Snapshot height every fixture here votes at.
///
/// Not arbitrary: note selection resolves the voting note version from the
/// snapshot height and the crate accepts only Ironwood (NU6.3) notes, so a
/// height below that activation is refused before the wallet is read at all.
/// This one is above NU6.3 on testnet (4_134_000) and mainnet (3_428_143).
private let votingSnapshotHeight: UInt64 = 4_200_000

/// Port 9 is the discard port: nothing listens, and a connection to loopback
/// there is refused at once rather than hanging. Opening a session dials
/// nothing, so this is never contacted; it exists so a test that accidentally
/// performs I/O fails fast instead of reaching a real host.
private let unroutableEndpoint = "http://127.0.0.1:9/"

private let sessionWalletId = "voting-session-tests"

/// A fixture that cannot be built is a failure rather than an unsupported
/// environment: `XCTFail` records where, and throwing this stops the test
/// instead of letting it run against half a wallet.
private enum VotingFixtureFailure: Error {
    case walletDatabaseNotInitialized
}

/// The wallet a round reads notes from, the sidecar it persists to, and the
/// session over both.
private struct VotingSessionFixture {
    let backend: VotingRustBackend
    let session: VotingRoundSession
    let roundId: String
}

/// `VotingRoundSession` over the real FFI, with a wallet that holds no notes.
///
/// Everything a round would reach — chain, helpers, vote tree, PIR — points at
/// the discard port, so the calls that reach quiescence do so on the sidecar
/// alone. What an empty wallet proves is the shape of the boundary: typed
/// refusals rather than crashes, events that arrive in order, and a session
/// that closes while nothing is in flight.
final class VotingRoundSessionTests: XCTestCase {
    // MARK: - Fixture

    private func makeFixture(tag: UInt8) async throws -> VotingSessionFixture {
        let root = Environment.uniqueTestTempDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let walletDb = root.appendingPathComponent("data.db")
        let rustBackend = ZcashRustBackend.makeForTests(
            dbData: walletDb,
            fsBlockDbRoot: root.appendingPathComponent("fsblocks"),
            networkType: .testnet
        )

        let initialized = try await rustBackend.initDataDb(seed: nil)
        guard case .success = initialized else {
            XCTFail("the fixture wallet database did not initialize: \(initialized)")
            throw VotingFixtureFailure.walletDatabaseNotInitialized
        }

        // A birthday one block above the snapshot puts the wallet's fully
        // scanned height — the block below the birthday, with no scanned
        // blocks — at or above the round's snapshot, which the crate requires
        // before it will select notes at all.
        _ = try await rustBackend.createAccount(
            seed: Environment.seedBytes,
            treeState: treeState(height: votingSnapshotHeight + 1),
            recoverUntil: nil,
            name: "voting",
            keySource: nil
        )

        let accounts = try await rustBackend.listAccounts()
        let account = try XCTUnwrap(accounts.first, "the fixture wallet holds no account")

        let backend = VotingRustBackend()
        let sidecar = root.appendingPathComponent("voting.sqlite3")
        try backend.open(path: sidecar.path, networkId: NetworkType.testnet.networkId)
        addTeardownBlock { backend.close() }
        try backend.setWalletId(sessionWalletId)

        let roundId = hexRoundId(tag)
        let inputs = VotingSessionInputs(
            accountUUID: try account.id.votingUUIDString(),
            walletDbPath: walletDb.path,
            roundParams: VotingRoundParameters(
                voteRoundId: roundId,
                snapshotHeight: votingSnapshotHeight,
                eaPk: Data(repeating: 7, count: 32),
                ncRoot: Data(repeating: 8, count: 32),
                nullifierImtRoot: Data(repeating: 9, count: 32)
            ),
            roundName: "synthetic round \(tag)",
            anchorTreeState: try treeState(height: votingSnapshotHeight).serializedData(),
            chainEndpoints: [unroutableEndpoint],
            voteTreeNodeUrls: [unroutableEndpoint],
            helperUrls: [unroutableEndpoint],
            pirEndpoints: [unroutableEndpoint],
            // The production layout the crate compiles against. Not decorative:
            // the fleet validates it against YPIR's minima, so a made-up shape
            // fails at session open.
            pirLayout: VotingPirLayout(pirDepth: 19, tier0Layers: 12, tier1Layers: 7, polyLen: 4096),
            ceremonyStartSeconds: 1_000,
            voteEndTimeSeconds: 2_000_000_000
        )
        let binding = VotingSessionBinding(roster: [VotingProposalRosterEntry(proposalId: 1, numOptions: 3)])

        let session = try backend.makeSession(inputs: inputs, binding: binding, torRuntime: nil, epoch: 1)
        return VotingSessionFixture(backend: backend, session: session, roundId: roundId)
    }

    /// A lightwalletd `TreeState` for `height` with empty commitment trees.
    ///
    /// Empty tree strings decode to empty trees rather than failing, so this
    /// serves as a usable anchor and a usable account birthday without real
    /// frontier bytes. The hash is 32 zero bytes because the wallet parses it.
    private func treeState(height: UInt64) -> TreeState {
        var state = TreeState()
        state.network = "test"
        state.height = height
        state.hash = String(repeating: "00", count: 32)
        return state
    }

    /// The refusal a wallet with nothing to vote with produces. Which of the
    /// two kinds note selection lands on is the crate's business; every caller
    /// here only needs the round to have refused rather than failed some other
    /// way.
    private func assertEmptyWalletRefusal(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let votingError = error as? VotingError else {
            return XCTFail("expected VotingError, got \(error)", file: file, line: line)
        }

        XCTAssertTrue(
            [VotingErrorKind.noSpendableNotes, .insufficientEligibility].contains(votingError.kind),
            "unexpected kind for an empty wallet: \(votingError.kind)",
            file: file,
            line: line
        )
    }

    // MARK: - Steps that read the wallet

    func testSetupBundlesOnAnEmptyWalletIsATypedRefusal() async throws {
        let fixture = try await makeFixture(tag: 0x41)

        do {
            _ = try await fixture.session.setupBundles()
            XCTFail("a wallet with no notes cannot lay out bundles")
        } catch {
            assertEmptyWalletRefusal(error)
        }

        do {
            _ = try await fixture.session.eligibility()
            XCTFail("a wallet with no notes is not eligible")
        } catch {
            assertEmptyWalletRefusal(error)
        }

        await fixture.session.close()
    }

    /// `setupBundles` creates the round row before it reads the wallet, so the
    /// refusal leaves a round the store half can see and plan over.
    func testARefusedSetupLeavesTheRoundForTheStoreAPI() async throws {
        let fixture = try await makeFixture(tag: 0x42)
        _ = try? await fixture.session.setupBundles()

        let rounds = try fixture.backend.listRounds()
        XCTAssertEqual(rounds.map(\.roundId), [fixture.roundId])
        XCTAssertEqual(rounds.first?.walletId, sessionWalletId)
        XCTAssertEqual(rounds.first?.snapshotHeight, votingSnapshotHeight)
        XCTAssertEqual(try fixture.backend.keystoneSignatures(roundId: fixture.roundId), [])

        let storePlan = try fixture.backend.roundPlan(roundId: fixture.roundId, proposalIds: [1])
        XCTAssertEqual(storePlan.roundId, fixture.roundId)
        XCTAssertFalse(storePlan.hotkeyBound)

        // The session plans over the same row and agrees with the store.
        XCTAssertEqual(try fixture.session.plan().roundId, fixture.roundId)

        let plan = try fixture.session.setBallotIntents([VotingBallotIntent(proposalId: 1, decision: .choice(0))])
        XCTAssertEqual(plan.roundId, fixture.roundId)
        XCTAssertTrue(plan.needsBundleSetup)

        try fixture.backend.clearBallotIntents(roundId: fixture.roundId, proposalIds: [1])
        try fixture.backend.deleteRound(roundId: fixture.roundId, discardingRecovery: false)
        XCTAssertEqual(try fixture.backend.listRounds(), [])

        await fixture.session.close()
    }

    // MARK: - Runs

    /// A cancelled session drives nothing: it reads no plan, dials no endpoint,
    /// and says why it stopped rather than failing.
    func testRunOnACancelledSessionQuiescesCancelled() async throws {
        let fixture = try await makeFixture(tag: 0x43)
        fixture.session.cancel()

        let report = try await fixture.session.run(signer: VotingDelegationSigner.none) { _ in }

        XCTAssertEqual(report.quiescence.kind, .cancelled)
        await fixture.session.close()
    }

    /// A run and a tracking run are exclusive per session.
    ///
    /// The handshake is the run's own event stream: the first event is held on
    /// the session's delivery queue, and a run does not return until that queue
    /// has drained, so the first run is provably still in flight while the
    /// second call is made. No sleeps, and nothing depends on how long the FFI
    /// takes.
    func testASecondRunWhileOneIsInFlightIsRefusedAsBusy() async throws {
        let fixture = try await makeFixture(tag: 0x44)
        let session = fixture.session
        let gate = FirstEventGate()
        let reported = expectation(description: "the run reported its first event")

        async let first: VotingRoundRunReport = session.run(signer: VotingDelegationSigner.none) { _ in
            guard gate.claimFirst() else { return }
            reported.fulfill()
            gate.waitForRelease()
        }

        await fulfillment(of: [reported], timeout: 60)

        do {
            _ = try await session.run(signer: VotingDelegationSigner.none) { _ in }
            XCTFail("a second run while one is in flight must be refused")
        } catch {
            XCTAssertEqual(error as? VotingRustBackendError, .sessionBusy)
        }

        do {
            _ = try await session.trackShares { _ in }
            XCTFail("share tracking while a run is in flight must be refused")
        } catch {
            XCTAssertEqual(error as? VotingRustBackendError, .sessionBusy)
        }

        gate.release()

        let report = try await first
        XCTAssertEqual(report.quiescence.kind, .needsBallot)
        XCTAssertEqual(report.quiescence.openProposals, [1])

        // The slot is free again once the run has returned.
        let tracking = try await session.trackShares { _ in }
        XCTAssertEqual(tracking.quiescence.kind, .nothingToTrack)

        await session.close()
    }

    // MARK: - Lifecycle

    func testCloseIsIdempotentAndEveryLaterCallIsRefused() async throws {
        let fixture = try await makeFixture(tag: 0x45)

        await fixture.session.close()
        await fixture.session.close()

        XCTAssertThrowsError(try fixture.session.plan()) { error in
            XCTAssertEqual(error as? VotingRustBackendError, .sessionClosed)
        }

        do {
            _ = try await fixture.session.setupBundles()
            XCTFail("a closed session runs nothing")
        } catch {
            XCTAssertEqual(error as? VotingRustBackendError, .sessionClosed)
        }

        do {
            _ = try await fixture.session.run(signer: VotingDelegationSigner.none) { _ in }
            XCTFail("a closed session runs nothing")
        } catch {
            XCTAssertEqual(error as? VotingRustBackendError, .sessionClosed)
        }

        // Cancelling and moving the epoch on a closed session are no-ops rather
        // than uses of a freed handle.
        fixture.session.cancel()
        fixture.session.setOperationEpoch(2)
    }

    /// Every path through the proving boost releases it, including the throwing
    /// one: a missing release pins the whole pool at user-initiated for the
    /// life of the process.
    func testAThrowingProofCallReleasesTheProvingBoost() async throws {
        let fixture = try await makeFixture(tag: 0x46)
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 0)

        do {
            _ = try await fixture.session.precomputeDelegationProof(bundleIndex: 0) { _ in }
            XCTFail("a round with no bundles has no proof to precompute")
        } catch {
            XCTAssertTrue(error is VotingError, "expected VotingError, got \(error)")
        }

        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 0)
        await fixture.session.close()
    }

    /// The account id crosses as UUID text, and an id that is not 16 bytes is
    /// refused rather than read off the end of its array. `AccountUUID` is
    /// `Codable`, so a decoded one never passed the initializer that checks.
    func testAccountUUIDTextRefusesAnIdThatIsNotAUUID() throws {
        let account = try JSONDecoder().decode(AccountUUID.self, from: Data(#"{"id":[1,2,3]}"#.utf8))

        XCTAssertThrowsError(try account.votingUUIDString()) { error in
            guard let votingError = error as? VotingError else { return XCTFail("expected VotingError, got \(error)") }
            XCTAssertEqual(votingError.kind, .invalidInput)
        }
    }

    /// A batch that names no bundle is refused by the crate rather than
    /// silently storing nothing.
    func testKeystoneBatchesRejectEmptyAndDuplicateIndices() async throws {
        let fixture = try await makeFixture(tag: 0x47)

        do {
            _ = try await fixture.session.storeKeystoneSignatures([])
            XCTFail("an empty keystone batch must be refused")
        } catch {
            guard let votingError = error as? VotingError else { return XCTFail("expected VotingError, got \(error)") }
            XCTAssertEqual(votingError.kind, .invalidInput)
        }

        do {
            _ = try await fixture.session.keystoneSigningRequests(bundleIndices: [0, 0])
            XCTFail("a batch naming one bundle twice must be refused")
        } catch {
            guard let votingError = error as? VotingError else { return XCTFail("expected VotingError, got \(error)") }
            XCTAssertEqual(votingError.kind, .invalidInput)
        }

        await fixture.session.close()
    }
}

// MARK: - Handshake

/// Holds the first event a run reports until the test releases it.
///
/// Later events pass straight through: an event arriving after the test has
/// moved on must not wedge the session's delivery queue.
private final class FirstEventGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private let released = DispatchSemaphore(value: 0)

    func claimFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed {
            return false
        }
        claimed = true
        return true
    }

    func waitForRelease() {
        released.wait()
    }

    func release() {
        released.signal()
    }
}
