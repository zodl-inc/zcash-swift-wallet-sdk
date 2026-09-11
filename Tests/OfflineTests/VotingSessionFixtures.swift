//
//  VotingSessionFixtures.swift
//  ZcashLightClientKitTests
//

import XCTest
import SwiftProtobuf
@testable import TestUtils
@testable import ZcashLightClientKit

/// Snapshot height every voting fixture votes at.
///
/// Not arbitrary: note selection resolves the voting note version from the
/// snapshot height and the crate accepts only Ironwood (NU6.3) notes, so a
/// height below that activation is refused before the wallet is read at all.
/// This one is above NU6.3 on testnet (4_134_000) and mainnet (3_428_143).
let votingFixtureSnapshotHeight: UInt64 = 4_200_000

/// Port 9 is the discard port: nothing listens, and a connection to loopback
/// there is refused at once rather than hanging. Opening a session dials
/// nothing, so this is never contacted; it exists so a test that accidentally
/// performs I/O fails fast instead of reaching a real host.
let votingFixtureUnroutableEndpoint = "http://127.0.0.1:9/"

/// A well-formed round id carrying `tag` in its first byte.
///
/// The remaining 31 bytes are zero, so the little-endian value is `tag` itself:
/// a canonical Pallas base-field encoding, which is what the crate requires of
/// every round id. One tag per test keeps rounds distinct within a store.
func hexRoundId(_ tag: UInt8) -> String {
    String(format: "%02x", tag) + String(repeating: "00", count: 31)
}

/// A fixture that cannot be built is a failure rather than an unsupported
/// environment: `XCTFail` records where, and throwing this stops the test
/// instead of letting it run against half a wallet.
enum VotingFixtureFailure: Error {
    case walletDatabaseNotInitialized
}

/// The wallet a round reads notes from, the sidecar it persists to, and the
/// arguments a session over both is opened from.
///
/// Shared rather than per-suite: the session suite opens the session through
/// the backend directly and the factory suite opens it through a
/// `Synchronizer`, and the two must vote over the same synthetic round for
/// either result to mean anything.
struct VotingSessionFixtureEnvironment {
    let backend: VotingRustBackend
    let inputs: VotingSessionInputs
    let binding: VotingSessionBinding
    let roundId: String
}

/// A lightwalletd `TreeState` for `height` with empty commitment trees.
///
/// Empty tree strings decode to empty trees rather than failing, so this serves
/// as a usable anchor and a usable account birthday without real frontier
/// bytes. The hash is 32 zero bytes because the wallet parses it.
func votingFixtureTreeState(height: UInt64) -> TreeState {
    var state = TreeState()
    state.network = "test"
    state.height = height
    state.hash = String(repeating: "00", count: 32)
    return state
}

extension XCTestCase {
    /// A synthetic round over a wallet that holds no notes, in a temporary
    /// directory this test case removes at teardown.
    ///
    /// Everything a round would reach — chain, helpers, vote tree, PIR —
    /// points at the discard port, so nothing built here can touch the
    /// network. `tag` names the round (one per test keeps rounds distinct
    /// within a store).
    ///
    /// The ceremony window is a parameter because both halves of it are
    /// optional on the wire: passing `nil` omits the key entirely, which is
    /// what a round that announces no window produces and what the crate's
    /// `Option<u64>` has to accept.
    func makeVotingSessionEnvironment(
        tag: UInt8,
        walletId: String,
        ceremonyStartSeconds: UInt64? = 1_000,
        voteEndTimeSeconds: UInt64? = 2_000_000_000
    ) async throws -> VotingSessionFixtureEnvironment {
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
            treeState: votingFixtureTreeState(height: votingFixtureSnapshotHeight + 1),
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
        try backend.setWalletId(walletId)

        let roundId = hexRoundId(tag)
        let inputs = VotingSessionInputs(
            accountUUID: try account.id.votingUUIDString(),
            walletDbPath: walletDb.path,
            roundParams: VotingRoundParameters(
                voteRoundId: roundId,
                snapshotHeight: votingFixtureSnapshotHeight,
                eaPk: Data(repeating: 7, count: 32),
                ncRoot: Data(repeating: 8, count: 32),
                nullifierImtRoot: Data(repeating: 9, count: 32)
            ),
            roundName: "synthetic round \(tag)",
            anchorTreeState: try votingFixtureTreeState(height: votingFixtureSnapshotHeight).serializedData(),
            chainEndpoints: [votingFixtureUnroutableEndpoint],
            voteTreeNodeUrls: [votingFixtureUnroutableEndpoint],
            helperUrls: [votingFixtureUnroutableEndpoint],
            pirEndpoints: [votingFixtureUnroutableEndpoint],
            // The production layout the crate compiles against. Not decorative:
            // the fleet validates it against YPIR's minima, so a made-up shape
            // fails at session open.
            pirLayout: VotingPirLayout(pirDepth: 19, tier0Layers: 12, tier1Layers: 7, polyLen: 4096),
            ceremonyStartSeconds: ceremonyStartSeconds,
            voteEndTimeSeconds: voteEndTimeSeconds
        )
        let binding = VotingSessionBinding(roster: [VotingProposalRosterEntry(proposalId: 1, numOptions: 3)])

        return VotingSessionFixtureEnvironment(backend: backend, inputs: inputs, binding: binding, roundId: roundId)
    }
}
