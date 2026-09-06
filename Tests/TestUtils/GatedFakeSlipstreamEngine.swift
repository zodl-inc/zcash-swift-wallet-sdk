//
//  GatedFakeSlipstreamEngine.swift
//  TestUtils
//

import Foundation
@testable import ZcashLightClientKit

/// A latch a test opens to release calls suspended on it.
///
/// A closed gate suspends every caller of `wait()`; `open()` resumes all of them and every later
/// caller passes straight through. That is exactly enough to pin an interleaving: hold the engine
/// inside `stop()` while the synchronizer's next `start()` runs, then let the stop finish and assert
/// on the order the two landed in.
///
/// `close()` re-arms the latch. It was deliberately absent at first, because a gate that shuts at an
/// unknown moment makes a test's outcome depend on WHEN it shut — the property these tests exist to
/// delete. The [MOB-1850] lifecycle tests need it anyway: a synchronizer must be brought up through
/// a real `start()` (which snapshots twice) before the interleaving under test can be arranged, so
/// the gate that will hold the next call has to be open first. The rule that keeps it deterministic
/// is the caller's: close a gate only while no call is inside it, and then wait on an OBSERVABLE
/// (`onCall`, or the recorded call log) rather than on elapsed time before assuming a call arrived.
///
/// `NSLock`, not `OSAllocatedUnfairLock`, for the package's iOS 13 / macOS 12 floor — the same
/// reason `LifecycleQueue` uses one.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Re-arms the latch: calls arriving after this suspend until the next `open()`.
    /// Callers already suspended are unaffected — `close()` never un-resumes anything.
    func close() {
        lock.lock()
        isOpen = false
        lock.unlock()
    }

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
    ///
    /// The three pass-owning calls also append a `":done"` entry when they RETURN (`"start:done"`,
    /// `"stop:done"`, `"reopen:done"`). Entry order alone cannot express "a start was still in
    /// flight when a teardown began", which is exactly the [MOB-1850] R2 invariant; with both edges
    /// recorded, the trace answers it directly. The un-gated calls keep a single entry — a
    /// `snapshot:done` on every poll tick would bury the lifecycle in noise for no gain.
    private(set) var calls: [String] = []

    /// One-shot hooks keyed by call name, fired by `record(_:)` the next time that call arrives and
    /// then removed. The point is to observe that a call REACHED the engine while it is still held
    /// by its gate — the moment a test needs in order to arrange the next step of an interleaving —
    /// without polling. One-shot because the natural payload is an `XCTestExpectation.fulfill()`,
    /// which fails the test when it runs twice, and `snapshot` arrives on every poll tick.
    private var callHooks: [String: @Sendable () -> Void] = [:]

    /// Whether a handle is notionally open. `open`/`reopen` set it, `close` and a failed `reopen`
    /// clear it, and `snapshot()` answers `nil` while it is false — the real engine's behaviour on a
    /// nil handle, which several teardown paths depend on.
    private(set) var isOpen = true

    /// What `snapshot()` returns while the handle is open.
    var nextSnapshot: SlipstreamSnapshot?
    /// [MOB-1852] What `walletSummary(confirmationsPolicy:)` returns while the handle is open. `nil`
    /// by default — "no balance data yet" — which every consumer already falls back from; a test
    /// that needs real balances (e.g. to exercise the [#1591] mask) scripts one via
    /// `setNextWalletSummary(_:)`.
    var nextWalletSummary: WalletSummary?
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

    /// Names one of the four gates, so a test can shut and reopen it without reaching for the
    /// property (`engine.snapshotGate.close()` works too; this reads better in a call sequence and
    /// keeps the enum available for hooks that want to talk about gates generically).
    enum GateKind {
        case stop
        case reopen
        case start
        case snapshot
    }

    private nonisolated func gate(_ kind: GateKind) -> Gate {
        switch kind {
        case .stop: return stopGate
        case .reopen: return reopenGate
        case .start: return startGate
        case .snapshot: return snapshotGate
        }
    }

    /// Shuts a gate so the NEXT call of that kind suspends inside the engine. Safe only while no
    /// call is currently inside it — see `Gate`'s note.
    func closeGate(_ kind: GateKind) {
        gate(kind).close()
    }

    /// Opens a gate, releasing whatever is held by it. The actor-isolated twin of
    /// `engine.startGate.open()`, for symmetry with `closeGate(_:)`.
    func openGate(_ kind: GateKind) {
        gate(kind).open()
    }

    /// Runs `hook` the next time a call named `name` is recorded, then forgets it.
    ///
    /// `name` matches either the logged entry or its bare member name, so `onCall("reopen")` fires
    /// for the `"reopen(host:port)"` the log actually carries.
    func onCall(_ name: String, _ hook: @escaping @Sendable () -> Void) {
        callHooks[name] = hook
    }

    /// The single logging choke point: appends the call and fires a matching one-shot hook. Called
    /// on ENTRY, before the call's gate, so a test can see that a call arrived while it is still
    /// being held.
    private func record(_ name: String) {
        calls.append(name)
        var fired = callHooks.removeValue(forKey: name)
        if fired == nil, let paren = name.firstIndex(of: "(") {
            fired = callHooks.removeValue(forKey: String(name[name.startIndex..<paren]))
        }
        fired?()
    }

    // MARK: - Scripting

    func setNextSnapshot(_ snapshot: SlipstreamSnapshot?) {
        nextSnapshot = snapshot
    }

    func setNextWalletSummary(_ summary: WalletSummary?) {
        nextWalletSummary = summary
    }

    func setReopenError(_ error: Error?) {
        reopenError = error
    }

    func setStartError(_ error: Error?) {
        startError = error
    }

    // MARK: - SlipstreamEngineControlling

    func open(network: ZcashNetwork) throws {
        record("open")
        isOpen = true
    }

    func setAlternates(_ endpoints: [LightWalletEndpoint]) {
        record("setAlternates")
    }

    func start(ufvk: String?, birthday: BlockHeight, torDir: String?) async throws {
        record("start")
        await startGate.wait()
        // [MOB-1850 hardening] In a `defer`, not a trailing statement, so a scripted `startError`
        // still leaves a complete "start"/"start:done" pair. Entry order alone cannot tell a caller
        // whether a start that appears in the log ever RETURNED — which is exactly what
        // `firstTeardownWhileAStartIsInFlight` needs to answer — and a start that failed still
        // returned (by throwing), so its trace must close the same way a successful one's does.
        defer { record("start:done") }
        if let startError {
            throw startError
        }
    }

    func stop() async {
        record("stop")
        await stopGate.wait()
        record("stop:done")
    }

    func notifyTxChange() {
        record("notifyTxChange")
    }

    func close() {
        record("close")
        isOpen = false
    }

    func reopen(server newServer: LightWalletEndpoint, network: ZcashNetwork) async throws {
        record("reopen(\(newServer.host):\(newServer.port))")
        await reopenGate.wait()
        if let reopenError {
            isOpen = false
            throw reopenError
        }
        isOpen = true
        record("reopen:done")
    }

    /// Serves the scripted `nextWalletSummary` while the handle is open, `nil` otherwise —
    /// mirroring `snapshot()`'s own `isOpen` gate. Defaults to `nil` ("no balance data yet"), which
    /// every consumer already falls back from; a test that needs real balances scripts them via
    /// `setNextWalletSummary(_:)`.
    func walletSummary(confirmationsPolicy: ConfirmationsPolicy) -> WalletSummary? {
        record("walletSummary")
        return isOpen ? nextWalletSummary : nil
    }

    func snapshot() async -> SlipstreamSnapshot? {
        record("snapshot")
        await snapshotGate.wait()
        return isOpen ? nextSnapshot : nil
    }

    func drainEvents(capacity: Int) -> [SlipstreamEngineEvent] {
        record("drainEvents")
        return []
    }
}
