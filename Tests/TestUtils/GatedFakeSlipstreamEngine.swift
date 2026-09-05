//
//  GatedFakeSlipstreamEngine.swift
//  TestUtils
//

import Foundation
@testable import ZcashLightClientKit

/// A one-way latch a test opens to release calls suspended on it.
///
/// A closed gate suspends every caller of `wait()`; `open()` resumes all of them and every later
/// caller passes straight through. That is exactly enough to pin an interleaving: hold the engine
/// inside `stop()` while the synchronizer's next `start()` runs, then let the stop finish and assert
/// on the order the two landed in. Reopening is not offered because a gate that could close again
/// would make a test's timing depend on when the closing happened, which is the property these
/// tests exist to remove.
///
/// `NSLock`, not `OSAllocatedUnfairLock`, for the package's iOS 13 / macOS 12 floor — the same
/// reason `PendingStopSlot` uses one.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Releases everything waiting on the gate, and everything that arrives later.
    func open() {
        lock.lock()
        isOpen = true
        let resumed = waiters
        waiters.removeAll()
        lock.unlock()
        resumed.forEach { $0.resume() }
    }

    /// Suspends until the gate is opened. Returns immediately if it already is.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

/// A `SlipstreamEngineControlling` that records what the synchronizer asked of it, answers from a
/// script, and can be held inside any of four calls until the test says otherwise.
///
/// Its point is the lifecycle interleavings the real engine cannot be made to reproduce: a stop that
/// lands while a restart is reopening the handle, a start that arrives before the previous stop has
/// returned, a reopen that fails. With the real engine those depend on Rust's timing and on the
/// network; here they are decided by the test.
///
/// Gates start OPEN by default, so a test that only wants a fast, inert engine constructs one and
/// says nothing more. `GatedFakeSlipstreamEngine(openGates: false)` starts every gate closed, and
/// the test opens the ones it wants to release.
actor GatedFakeSlipstreamEngine: SlipstreamEngineControlling {
    /// Every call the synchronizer made, in order. Names are the bare member name, except `reopen`,
    /// which carries the endpoint it was pointed at (`"reopen(host:port)"`) because which server a
    /// restart chose is the interesting half of that call.
    ///
    /// An entry is appended on ENTRY, before the call's gate: a test holding the engine inside
    /// `stop()` can therefore see that the stop arrived while it is still suspended, which is the
    /// observation most interleaving assertions are built on.
    private(set) var calls: [String] = []

    /// Whether a handle is notionally open. `open`/`reopen` set it, `close` and a failed `reopen`
    /// clear it, and `snapshot()` answers `nil` while it is false — the real engine's behaviour on a
    /// nil handle, which several teardown paths depend on.
    private(set) var isOpen = true

    /// What `snapshot()` returns while the handle is open.
    var nextSnapshot: SlipstreamSnapshot?
    /// When set, `reopen` throws it and leaves the handle closed.
    var reopenError: Error?
    /// When set, `start` throws it once its gate has been passed.
    var startError: Error?

    // `nonisolated` is load-bearing, not decoration: an actor's `let` is implicitly nonisolated only
    // inside its own module, and every test that uses these lives in a test target rather than in
    // `TestUtils`. Without it `engine.stopGate.open()` does not compile from a test at all.
    nonisolated let stopGate = Gate()
    nonisolated let reopenGate = Gate()
    nonisolated let startGate = Gate()
    nonisolated let snapshotGate = Gate()

    init(openGates: Bool = true) {
        if openGates {
            stopGate.open()
            reopenGate.open()
            startGate.open()
            snapshotGate.open()
        }
    }

    // MARK: - Scripting

    func setNextSnapshot(_ snapshot: SlipstreamSnapshot?) {
        nextSnapshot = snapshot
    }

    func setReopenError(_ error: Error?) {
        reopenError = error
    }

    func setStartError(_ error: Error?) {
        startError = error
    }

    // MARK: - SlipstreamEngineControlling

    func open(network: ZcashNetwork) throws {
        calls.append("open")
        isOpen = true
    }

    func setAlternates(_ endpoints: [LightWalletEndpoint]) {
        calls.append("setAlternates")
    }

    func start(ufvk: String?, birthday: BlockHeight, torDir: String?) async throws {
        calls.append("start")
        await startGate.wait()
        if let startError {
            throw startError
        }
    }

    func stop() async {
        calls.append("stop")
        await stopGate.wait()
    }

    func notifyTxChange() {
        calls.append("notifyTxChange")
    }

    func close() {
        calls.append("close")
        isOpen = false
    }

    func reopen(server newServer: LightWalletEndpoint, network: ZcashNetwork) async throws {
        calls.append("reopen(\(newServer.host):\(newServer.port))")
        await reopenGate.wait()
        if let reopenError {
            isOpen = false
            throw reopenError
        }
        isOpen = true
    }

    /// Always `nil` — "no balance data yet", which every consumer already falls back from. A test
    /// that needs real balances scripts them here.
    func walletSummary(confirmationsPolicy: ConfirmationsPolicy) -> WalletSummary? {
        calls.append("walletSummary")
        return nil
    }

    func snapshot() async -> SlipstreamSnapshot? {
        calls.append("snapshot")
        await snapshotGate.wait()
        return isOpen ? nextSnapshot : nil
    }

    func drainEvents(capacity: Int) -> [SlipstreamEngineEvent] {
        calls.append("drainEvents")
        return []
    }
}
