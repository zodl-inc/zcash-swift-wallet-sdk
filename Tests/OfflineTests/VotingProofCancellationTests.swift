//
//  VotingProofCancellationTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

// [MOB-1860] Regression coverage for a cancelled delegation proof starting anyway.
//
// The failure this closes: a caller cancels `buildAndProveDelegation` while the PIR servers are
// still being probed (or in the brief window right after resolution finishes), and the proof starts
// regardless — because nothing between `PirSnapshotResolver.resolve` returning and the detached
// proving call actually checked for cancellation. `buildAndProveDelegation`'s `proveEntry` parameter
// is a test seam standing in for the FFI entry point (`syncBuildAndProveDelegation` in production),
// so these tests can observe whether it was reached — and control what it returns or throws —
// without paying for a real, potentially minutes-long proof.

private func cancellationHexRoundId(_ tag: UInt8) -> String {
    String(format: "%02x", tag) + String(repeating: "00", count: 31)
}

private let cancellationNetworkId: UInt32 = 1
private let cancellationWalletId = "cancellation-test-wallet"
private let cancellationRoundId = cancellationHexRoundId(0x09)
private let cancellationSnapshotHeight: UInt64 = 100
private let cancellationMatchingURL = "https://a.example"
private let cancellationSecondURL = "https://b.example"

/// A `Bool` set from one task and read from another, guarded by `NSLock` for the package's iOS 13 /
/// macOS 12 floor — `LockIsolated` (swift-dependencies) is not available in this package. Exposes
/// the same `setValue` / `.value` shape a `LockIsolated` would, for a spy's "was I entered" flag.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged: Bool

    init(_ initial: Bool) {
        flagged = initial
    }

    func setValue(_ newValue: Bool) {
        lock.lock()
        flagged = newValue
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flagged
    }
}

final class VotingProofCancellationTests: XCTestCase {
    private var dbPath: String?

    override func tearDown() {
        if let dbPath {
            try? FileManager.default.removeItem(atPath: dbPath)
        }
        dbPath = nil
        super.tearDown()
    }

    // MARK: - Test doubles

    /// Answers `matchingURL` immediately with a match. Every other URL blocks on `gate` until the
    /// test opens it, then reports unreachable — modelling a probe that was still in flight when
    /// the caller gave up.
    private struct GatedProbe: PirSnapshotProbing {
        let matchingURL: String
        let gate: Gate

        func probe(url: String, expectedSnapshotHeight: BlockHeight) async -> PirSnapshotProbeOutcome {
            if url == matchingURL {
                return PirSnapshotProbeOutcome(url: url, status: .matching(height: expectedSnapshotHeight))
            }
            await gate.wait()
            return PirSnapshotProbeOutcome(url: url, status: .unreachable(reason: "cancelled"))
        }
    }

    /// Every endpoint reports a match immediately — resolution never suspends on a gate.
    private struct ImmediatelyMatchingProbe: PirSnapshotProbing {
        func probe(url: String, expectedSnapshotHeight: BlockHeight) async -> PirSnapshotProbeOutcome {
            PirSnapshotProbeOutcome(url: url, status: .matching(height: expectedSnapshotHeight))
        }
    }

    /// Every endpoint is unreachable, so resolution always fails with `.noMatchingEndpoint`.
    private struct AlwaysUnreachableProbe: PirSnapshotProbing {
        func probe(url: String, expectedSnapshotHeight: BlockHeight) async -> PirSnapshotProbeOutcome {
            PirSnapshotProbeOutcome(url: url, status: .unreachable(reason: "offline"))
        }
    }

    // MARK: - Tests

    /// Reconstructs the audit's five-step sequence: one endpoint matches immediately, the other is
    /// still being probed when the caller cancels. `resolve` must not hand back the first match once
    /// cancelled, so the proof never starts.
    func testCancellationWhileASecondProbeIsPendingNeverEntersTheProof() async throws {
        let backend = try makeOpenVotingBackend()
        let gate = Gate()
        let entered = LockedFlag(false)

        let task = Task {
            try await backend.buildAndProveDelegation(
                try makeParams(),
                pirEndpoints: [cancellationMatchingURL, cancellationSecondURL],
                expectedSnapshotHeight: cancellationSnapshotHeight,
                pirResolver: PirSnapshotResolver(
                    probe: GatedProbe(matchingURL: cancellationMatchingURL, gate: gate)
                ),
                proveEntry: { _, _, _, _ in
                    entered.setValue(true)
                    throw CancellationError()
                }
            )
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        gate.open()

        let result = await task.result
        XCTAssertFalse(entered.value, "the proof must not start after cancellation")
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
    }

    /// Cancels before either probe has answered at all. `resolve`'s own cancellation check must fire
    /// before it ever gets to "no endpoint matched" territory.
    func testCancellationBeforeResolutionThrowsCancellation() async throws {
        let backend = try makeOpenVotingBackend()
        let gate = Gate()
        let entered = LockedFlag(false)

        let task = Task {
            try await backend.buildAndProveDelegation(
                try makeParams(),
                pirEndpoints: [cancellationMatchingURL, cancellationSecondURL],
                expectedSnapshotHeight: cancellationSnapshotHeight,
                // Neither endpoint matches `gate`'s owner, so both probes gate — resolution cannot
                // complete until the test opens it, regardless of which one is "first".
                pirResolver: PirSnapshotResolver(
                    probe: GatedProbe(matchingURL: "https://never-matches.example", gate: gate)
                ),
                proveEntry: { _, _, _, _ in
                    entered.setValue(true)
                    throw CancellationError()
                }
            )
        }

        task.cancel()
        gate.open()

        let result = await task.result
        XCTAssertFalse(entered.value, "the proof must not start after cancellation")
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
    }

    /// Both probes answer immediately — resolution succeeds — and the caller cancels as early as a
    /// test can arrange, before the detached proving call could plausibly have been scheduled. There
    /// is no production hook to pause execution precisely between the flag check and the FFI call
    /// (that gap is exactly the documented limitation the next test exercises), so this proves the
    /// negative the way the hygiene rule for this suite allows: cancelling immediately, with no
    /// artificial delay that would let the detached closure win the race, and asserting the spy was
    /// never invoked.
    func testResolvedThenCancelledBeforeDetachedEntryDoesNotEnter() async throws {
        let backend = try makeOpenVotingBackend()
        let entered = LockedFlag(false)

        let task = Task {
            try await backend.buildAndProveDelegation(
                try makeParams(),
                pirEndpoints: [cancellationMatchingURL, cancellationSecondURL],
                expectedSnapshotHeight: cancellationSnapshotHeight,
                pirResolver: PirSnapshotResolver(probe: ImmediatelyMatchingProbe()),
                proveEntry: { _, _, _, _ in
                    entered.setValue(true)
                    throw CancellationError()
                }
            )
        }
        task.cancel()

        let result = await task.result
        XCTAssertFalse(entered.value, "the proof must not start after cancellation")
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        }
    }

    /// Documents the limitation the doc comment on `buildAndProveDelegation` calls out: once
    /// `proveEntry` has actually been entered, a later cancellation cannot interrupt it. The spy
    /// parks on a semaphore so the test can observe entry, cancel, and only then let it finish.
    func testAlreadyEnteredProofRunsToCompletionDespiteCancellation() async throws {
        let backend = try makeOpenVotingBackend()
        let entered = LockedFlag(false)
        let enteredSemaphore = DispatchSemaphore(value: 0)
        let releaseSemaphore = DispatchSemaphore(value: 0)
        let fixture = makeFixtureResult(tag: 0x11)

        let task = Task {
            try await backend.buildAndProveDelegation(
                try makeParams(),
                pirEndpoints: [cancellationMatchingURL],
                expectedSnapshotHeight: cancellationSnapshotHeight,
                pirResolver: PirSnapshotResolver(probe: ImmediatelyMatchingProbe()),
                proveEntry: { _, _, _, _ in
                    entered.setValue(true)
                    enteredSemaphore.signal()
                    releaseSemaphore.wait()
                    return fixture
                }
            )
        }

        XCTAssertEqual(
            enteredSemaphore.wait(timeout: .now() + .seconds(5)),
            .success,
            "proveEntry was never entered"
        )
        task.cancel()
        releaseSemaphore.signal()

        let result = await task.result
        XCTAssertTrue(entered.value)
        let proof = try result.get()
        XCTAssertEqual(proof.proof, fixture.proof)
        XCTAssertEqual(proof.randomizedKey, fixture.randomizedKey)
    }

    /// No cancellation anywhere in this one: the positive path must still return the spy's result.
    func testSuccessfulProofStillRuns() async throws {
        let backend = try makeOpenVotingBackend()
        let fixture = makeFixtureResult(tag: 0x22)

        let result = try await backend.buildAndProveDelegation(
            try makeParams(),
            pirEndpoints: [cancellationMatchingURL],
            expectedSnapshotHeight: cancellationSnapshotHeight,
            pirResolver: PirSnapshotResolver(probe: ImmediatelyMatchingProbe()),
            proveEntry: { _, _, _, _ in fixture }
        )

        XCTAssertEqual(result.proof, fixture.proof)
        XCTAssertEqual(result.randomizedKey, fixture.randomizedKey)
    }

    /// Unrelated to cancellation: confirms the new overload still surfaces the existing
    /// `noMatchingEndpoint` failure when no server serves the round's snapshot, and never calls
    /// `proveEntry` when resolution itself failed.
    func testNoMatchingServerStillFails() async throws {
        let backend = try makeOpenVotingBackend()

        do {
            _ = try await backend.buildAndProveDelegation(
                try makeParams(),
                pirEndpoints: [cancellationMatchingURL, cancellationSecondURL],
                expectedSnapshotHeight: cancellationSnapshotHeight,
                pirResolver: PirSnapshotResolver(probe: AlwaysUnreachableProbe()),
                proveEntry: { _, _, _, _ in
                    XCTFail("proveEntry must not run when no PIR endpoint matches")
                    throw CancellationError()
                }
            )
            XCTFail("expected .noMatchingEndpoint")
        } catch let error as PirSnapshotResolverError {
            guard case .noMatchingEndpoint = error else {
                XCTFail("expected .noMatchingEndpoint, got \(error.localizedDescription)")
                return
            }
        }
    }

    // MARK: - Helpers

    private func makeTempDbPath() -> String {
        let unique = ProcessInfo.processInfo.globallyUniqueString
        let path = "\(NSTemporaryDirectory())VotingProofCancellationTests-\(unique).sqlite"
        dbPath = path
        return path
    }

    private func makeOpenVotingBackend() throws -> VotingRustBackend {
        let backend = VotingRustBackend()
        try backend.open(path: makeTempDbPath(), networkId: cancellationNetworkId)
        try backend.setWalletId(cancellationWalletId)
        return backend
    }

    private func makeParams() throws -> VotingDelegationProofParams {
        let hotkey = try VotingRustBackend.generateHotkey(networkId: cancellationNetworkId)
        return VotingDelegationProofParams(
            roundId: cancellationRoundId,
            bundleIndex: 0,
            notes: [],
            keys: VotingDelegationKeyInputs(
                fvk: [UInt8](repeating: 0x03, count: votingOrchardFvkByteCount),
                hotkeyStoredSecret: hotkey.storedSecret,
                seedFingerprint: [UInt8](repeating: 0x04, count: votingSeedFingerprintByteCount),
                accountIndex: 0,
                roundName: "cancellation-round"
            )
        )
    }

    private func makeFixtureResult(tag: UInt8) -> VotingDelegationProofResult {
        VotingDelegationProofResult(
            proof: [UInt8](repeating: tag, count: 4),
            publicInputs: [[UInt8](repeating: tag, count: 4)],
            nfSigned: [UInt8](repeating: tag, count: votingFieldElementByteCount),
            cmxNew: [UInt8](repeating: tag, count: votingFieldElementByteCount),
            govNullifiers: [[UInt8](repeating: tag, count: votingFieldElementByteCount)],
            vanComm: [UInt8](repeating: tag, count: votingFieldElementByteCount),
            randomizedKey: [UInt8](repeating: tag, count: votingRandomizedKeyByteCount)
        )
    }
}
