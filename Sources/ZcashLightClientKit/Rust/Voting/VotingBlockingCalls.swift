//
//  VotingBlockingCalls.swift
//  ZcashLightClientKit
//

import Foundation

/// The threads the voting FFI's blocking calls run on, and the register a close
/// waits on.
///
/// Every voting call that reads the wallet, proves, or reaches the network
/// blocks the thread that made it for as long as the crate takes: a run drives
/// a whole round, a proof joins a proving thread, share tracking drives passes.
/// Those windows are minutes, and they are not exclusive — a run, a precompute
/// and one tracking pass per pending round can all be in flight at once.
///
/// They therefore run here rather than on Swift's cooperative pool. That pool
/// is a fixed number of threads and does not grow when one of them blocks, so a
/// minutes-long FFI call on it is a thread the whole process loses, and enough
/// of them together starve the host's own `async` work — its sync, its UI, work
/// that has nothing to do with voting. This queue is concurrent, so it grows a
/// thread for a call the blocked ones cannot start, and the caller suspends
/// rather than blocks while it waits.
///
/// The calls in flight are registered because their handle may not be freed
/// while Rust is still using it: one register per handle owner — the backend
/// and each session — over threads they all share.
final class VotingBlockingCalls: @unchecked Sendable {
    /// One pool of threads for the whole voting surface rather than one per
    /// owner. `userInitiated` because everything routed here is work a voter is
    /// waiting on, and the thread it blocks is this SDK's own.
    private static let queue = DispatchQueue(
        label: "cash.z.wallet.voting.blocking",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private let lock = NSLock()
    private var inFlight: Set<UUID> = []
    private var joiners: [CheckedContinuation<Void, Never>] = []

    /// Registers a call that is about to start, answering its ticket.
    ///
    /// Call it while holding the lock that guards the handle the call will use:
    /// registering under the hold that read the handle is what leaves no window
    /// where a call starts against a handle a close is about to free. Every
    /// ticket must reach ``run(ticket:_:)``, which is what retires it.
    func register() -> UUID {
        lock.lock()
        defer { lock.unlock() }

        let ticket = UUID()
        inFlight.insert(ticket)
        return ticket
    }

    /// Runs `body` on the blocking queue and answers with what it returned,
    /// retiring `ticket` on every path.
    ///
    /// The caller suspends until `body` returns. It is deliberately not
    /// cancellable: an FFI call in progress cannot be abandoned, because the
    /// handle it was given has to stay alive until Rust is done with it.
    ///
    /// `body` runs on one thread from beginning to end, which is what lets it
    /// read the FFI's last-error slot — that slot is per thread, and the thread
    /// that made the failing call is the only one holding its message.
    func run<T: Sendable>(ticket: UUID, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        defer { retire(ticket) }

        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result(catching: body))
            }
        }
    }

    /// Whether no call is registered right now.
    ///
    /// The answer is a fact about the moment it was read: only a caller holding
    /// the lock that guards ``register()`` can rely on it staying true, which
    /// is how the backend decides whether a close may free its handle.
    var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight.isEmpty
    }

    /// Waits for the calls registered right now to return.
    ///
    /// Suspends rather than blocks: a cooperative thread held here is one the
    /// rest of the wallet cannot use. A caller that also has to keep new calls
    /// from starting must do that itself, before it joins.
    func join() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if inFlight.isEmpty {
                lock.unlock()
                return continuation.resume()
            }

            joiners.append(continuation)
            lock.unlock()
        }
    }

    /// Retires one finished call, releasing the joins that were waiting for the
    /// last of them. The waiters are resumed with the lock released: a
    /// continuation resumes work that may come straight back here.
    private func retire(_ ticket: UUID) {
        lock.lock()
        inFlight.remove(ticket)
        let waiting = inFlight.isEmpty ? joiners : []
        if inFlight.isEmpty {
            joiners.removeAll()
        }
        lock.unlock()

        for joiner in waiting {
            joiner.resume()
        }
    }
}
