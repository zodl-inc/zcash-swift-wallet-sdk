//
//  VotingRoundSessionTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import ZcashLightClientKit

private let sessionWalletId = "voting-session-tests"

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
        let environment = try await makeVotingSessionEnvironment(tag: tag, walletId: sessionWalletId)
        let session = try environment.backend.makeSession(
            inputs: environment.inputs,
            binding: environment.binding,
            torRuntime: nil,
            epoch: 1
        )

        return VotingSessionFixture(backend: environment.backend, session: session, roundId: environment.roundId)
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
        XCTAssertEqual(rounds.first?.snapshotHeight, votingFixtureSnapshotHeight)
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

    /// A round that announces no ceremony window opens over the real FFI.
    ///
    /// Both halves of the window default to `nil`, and Swift omits an absent
    /// key rather than writing `null`, so the bytes that cross carry neither
    /// `ceremony_start_seconds` nor `vote_end_time_seconds`. Nothing else
    /// proves the crate's bare `Option<u64>` fields resolve to `None` from an
    /// absent key — and every host that leaves those defaults alone depends on
    /// it.
    func testASessionOpensForARoundThatAnnouncesNoCeremonyWindow() async throws {
        let environment = try await makeVotingSessionEnvironment(
            tag: 0x48,
            walletId: sessionWalletId,
            ceremonyStartSeconds: nil,
            voteEndTimeSeconds: nil
        )
        XCTAssertNil(environment.inputs.ceremonyStartSeconds)
        XCTAssertNil(environment.inputs.voteEndTimeSeconds)

        let session = try environment.backend.makeSession(
            inputs: environment.inputs,
            binding: environment.binding,
            torRuntime: nil,
            epoch: 1
        )

        XCTAssertEqual(try session.plan().roundId, environment.roundId)
        await session.close()
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
