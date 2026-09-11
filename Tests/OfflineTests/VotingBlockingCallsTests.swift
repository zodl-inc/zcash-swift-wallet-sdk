//
//  VotingBlockingCallsTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import ZcashLightClientKit

/// The threads every blocking voting FFI call runs on.
///
/// What these prove is the property the voting FFI needs and Swift's
/// cooperative pool cannot give it: a call blocks a thread this SDK owns, and
/// more of them can block at once than the host has processors — which is the
/// shape of a round, where a run, a precompute and one tracking pass per
/// pending round are all in flight together for minutes.
final class VotingBlockingCallsTests: XCTestCase {
    /// The call body runs on the voting queue, not on whatever executor awaited
    /// it. The label is the one a crash report or an Instruments trace shows,
    /// so it is asserted literally rather than through the constant.
    func testABlockingCallRunsOnTheVotingQueueRatherThanTheCallersExecutor() async throws {
        let calls = VotingBlockingCalls()
        let ticket = calls.register()

        let label = try await calls.run(ticket: ticket) {
            String(cString: __dispatch_queue_get_label(nil))
        }

        XCTAssertEqual(label, "cash.z.wallet.voting.blocking")
    }

    /// More calls than the host has processors are in flight at once.
    ///
    /// Every body waits for all of them to arrive before any returns, so this
    /// finishes only if the executor holds them all at the same time. On the
    /// cooperative pool — whose width is the processor count and which does not
    /// grow when its threads block — it could not.
    func testMoreConcurrentCallsThanProcessorsAreAllInFlightAtOnce() async throws {
        let width = ProcessInfo.processInfo.activeProcessorCount + 4
        let calls = VotingBlockingCalls()
        let everyone = ArrivalBarrier(count: width)

        let arrived = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<width {
                let ticket = calls.register()
                group.addTask {
                    try await calls.run(ticket: ticket) {
                        everyone.arriveAndWait(timeout: .now() + 30)
                    }
                }
            }

            var arrived = 0
            for try await allArrived in group where allArrived {
                arrived += 1
            }
            return arrived
        }

        XCTAssertEqual(arrived, width, "a call was left waiting for one the executor could not start")
    }

    /// A join waits for the calls registered before it and returns at once when
    /// there are none: this is what `close()` rides on when it may not free a
    /// handle Rust is still using.
    func testJoinWaitsForTheCallsRegisteredBeforeItAndReturnsAtOnceWhenThereAreNone() async throws {
        let calls = VotingBlockingCalls()
        await calls.join()

        let ticket = calls.register()
        let release = DispatchSemaphore(value: 0)
        let running = expectation(description: "the call reached the blocking queue")
        let finished = Finished()

        async let call: Void = calls.run(ticket: ticket) {
            running.fulfill()
            release.wait()
            finished.mark()
        }

        await fulfillment(of: [running], timeout: 30)
        XCTAssertFalse(finished.isMarked)

        release.signal()
        await calls.join()
        XCTAssertTrue(finished.isMarked, "join returned while the call it registered was still running")

        try await call
    }
}

// MARK: - Test support

/// Releases every waiter only once `count` of them have arrived.
private final class ArrivalBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let everyoneArrived = DispatchSemaphore(value: 0)
    private let count: Int
    private var arrived = 0

    init(count: Int) {
        self.count = count
    }

    /// Blocks until every arrival is in, answering whether they all made it.
    /// The timeout is what turns an executor that cannot hold them all into a
    /// failing assertion rather than a hung suite.
    func arriveAndWait(timeout: DispatchTime) -> Bool {
        lock.lock()
        arrived += 1
        let last = arrived == count
        lock.unlock()

        if last {
            for _ in 0..<count {
                everyoneArrived.signal()
            }
        }

        return everyoneArrived.wait(timeout: timeout) == .success
    }
}

/// A flag one thread sets and another reads.
private final class Finished: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false

    var isMarked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return marked
    }

    func mark() {
        lock.lock()
        defer { lock.unlock() }
        marked = true
    }
}
