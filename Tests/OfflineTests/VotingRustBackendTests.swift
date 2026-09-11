//
//  VotingRustBackendTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import ZcashLightClientKit

/// The store half of the voting FFI: the database-bound reads and maintenance
/// calls a host makes without a round session, plus the process-wide proving
/// configuration.
final class VotingRustBackendTests: XCTestCase {
    /// An open sidecar in a temporary file, bound to a wallet and closed at
    /// teardown. Mainnet by default — nothing here reads a wallet database, so
    /// the network only has to be one the crate knows.
    private func openBackend(networkId: UInt32 = 1, walletId: String = "wallet") throws -> VotingRustBackend {
        let backend = VotingRustBackend()
        let path = "\(NSTemporaryDirectory())voting-\(UUID().uuidString).sqlite3"
        try backend.open(path: path, networkId: networkId)
        addTeardownBlock {
            backend.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        try backend.setWalletId(walletId)
        return backend
    }

    func testOpenListRoundsAndTypedErrors() throws {
        let backend = try openBackend()

        XCTAssertEqual(try backend.listRounds(), [])
        XCTAssertEqual(try backend.pendingShareRounds(), [])

        // Planning a round the sidecar has never seen is not an error: the
        // crate plans over a round's rows, and a round with none plans as an
        // idle round that owes a draft.
        let idle = try backend.roundPlan(roundId: hexRoundId(0xfe), proposalIds: [1])
        XCTAssertEqual(idle.roundId, hexRoundId(0xfe))
        XCTAssertTrue(idle.needsDraftSetup)
        XCTAssertFalse(idle.needsBundleSetup)

        // A roster the crate refuses is, and it arrives as the typed envelope a
        // host branches on rather than as bare text.
        XCTAssertThrowsError(try backend.roundPlan(roundId: hexRoundId(0xfe), proposalIds: [0])) { error in
            guard let votingError = error as? VotingError else { return XCTFail("expected VotingError, got \(error)") }
            XCTAssertEqual(votingError.kind, .invalidInput)
            XCTAssertFalse(votingError.message.isEmpty)
        }

        XCTAssertTrue(VotingRustBackend.validateRoundId(hexRoundId(0x01)))
        XCTAssertFalse(VotingRustBackend.validateRoundId("nope"))
    }

    /// The database-bound calls refuse to run without a handle, and a second
    /// open over the same backend is refused rather than leaking the first.
    func testDatabaseLifecycleIsGuarded() throws {
        let backend = VotingRustBackend()

        XCTAssertThrowsError(try backend.listRounds()) { error in
            XCTAssertEqual(error as? VotingRustBackendError, .databaseNotOpen)
        }

        let path = "\(NSTemporaryDirectory())voting-\(UUID().uuidString).sqlite3"
        try backend.open(path: path, networkId: 1)
        addTeardownBlock {
            backend.close()
            try? FileManager.default.removeItem(atPath: path)
        }

        XCTAssertThrowsError(try backend.open(path: path, networkId: 1)) { error in
            XCTAssertEqual(error as? VotingRustBackendError, .databaseAlreadyOpen)
        }

        // Idempotent, and the handle is gone afterwards.
        backend.close()
        backend.close()
        XCTAssertThrowsError(try backend.setWalletId("wallet")) { error in
            XCTAssertEqual(error as? VotingRustBackendError, .databaseNotOpen)
        }
    }

    /// An empty round id is the crate's wallet-wide tree reset, which is never
    /// what a host asking about one round means, so the wrapper refuses it
    /// before the FFI can widen the call.
    func testResetsRefuseAnEmptyRoundId() throws {
        let backend = try openBackend()

        XCTAssertThrowsError(try backend.resetVoteTree(roundId: "")) { error in
            guard let votingError = error as? VotingError else { return XCTFail("expected VotingError, got \(error)") }
            XCTAssertEqual(votingError.kind, .invalidInput)
            XCTAssertFalse(votingError.retryable)
        }
        XCTAssertThrowsError(try backend.resetSessionState(roundId: "")) { error in
            guard let votingError = error as? VotingError else { return XCTFail("expected VotingError, got \(error)") }
            XCTAssertEqual(votingError.kind, .invalidInput)
        }

        // A named round the sidecar has never seen is not an error for either.
        try backend.resetVoteTree(roundId: hexRoundId(0x02))
        try backend.resetSessionState(roundId: hexRoundId(0x02))
    }

    /// The proving pool is fixed once per process: an identical repeat is
    /// accepted as a fresh configure, and only a policy that disagrees with the
    /// one in force reports that the pool was already configured.
    ///
    /// What the first call answers depends on what ran before it in this
    /// process — warming the caches or proving fixes the crate's own default
    /// policy — so the assertion is the rule rather than that first answer.
    func testConfigureProvingIsIdempotent() throws {
        let policy = VotingProvingPolicy(cpuWorkerCount: nil, maxActiveHeavyJobs: 1)

        if try VotingRustBackend.configureProving(policy) {
            // This call fixed the pool, so the policy in force is this one, and
            // asking for it again is accepted as a fresh configure rather than
            // reported as a conflict.
            XCTAssertTrue(try VotingRustBackend.configureProving(policy))
        }

        // Some policy is in force by now, whichever call fixed it. This one
        // asks for a heavy-job count that no machine's core count is, so it
        // disagrees with whatever is in force and is refused rather than
        // applied.
        let conflicting = VotingProvingPolicy(cpuWorkerCount: nil, maxActiveHeavyJobs: 1024)
        XCTAssertFalse(try VotingRustBackend.configureProving(conflicting))
    }

    /// The vote-tree sync is the one store call that reaches the network. It
    /// runs off the backend lock, so a node that refuses the connection comes
    /// back as the crate's typed failure and leaves the backend answering.
    func testSyncVoteTreeReportsATypedFailureAndLeavesTheBackendUsable() async throws {
        let backend = try openBackend()

        do {
            // Port 9 is the discard port: nothing listens, and loopback refuses
            // at once rather than hanging.
            _ = try await backend.syncVoteTree(roundId: hexRoundId(0x03), nodeUrl: "http://127.0.0.1:9/")
            XCTFail("nothing is listening on the discard port")
        } catch {
            XCTAssertTrue(error is VotingError, "expected VotingError, got \(error)")
        }

        XCTAssertEqual(try backend.listRounds(), [])
    }

    /// The hotkey statics need no database, and a stored secret re-derives the
    /// same hotkey rather than a new one.
    func testHotkeyFromStoredSecretReDerivesTheSameHotkey() throws {
        let hotkey = try VotingRustBackend.generateHotkey(networkId: 1)
        XCTAssertFalse(hotkey.storedSecret.isEmpty)

        let rederived = try VotingRustBackend.hotkey(fromStoredSecret: hotkey.storedSecret, networkId: 1)
        XCTAssertEqual(rederived.storedSecret, hotkey.storedSecret)
        XCTAssertEqual(rederived.rawOrchardAddress, hotkey.rawOrchardAddress)
        XCTAssertEqual(rederived.addressIndex, hotkey.addressIndex)
    }
}
