import CryptoKit
import Foundation

/// The priority requested for a shared delegation proof.
public enum VotingProvingIntent: Sendable {
    case speculative
    case interactive
}

/// A retained proof producer shared by callers with the same persisted setup and inputs.
///
/// Cancelling a result waiter only removes that waiter. Once native proving starts it cannot
/// be interrupted; use `cancelAndWait()` to invalidate delivery and join its actual return.
public final class VotingDelegationOperation: @unchecked Sendable {
    private typealias Completion = Result<VotingDelegationProofResult, Error>
    private struct Subscriber {
        let continuation: CheckedContinuation<VotingDelegationProofResult, Error>
        let progress: (@Sendable (Double) -> Void)?
    }

    private let lock = NSLock()
    private let callbacks = DispatchQueue(label: "cash.z.zcashlc.delegation-progress")
    private var subscribers: [UUID: Subscriber] = [:]
    private var latestProgress: Double?
    private var completion: Completion?
    private var cancelled = false
    private var interactive = false
    private var entered = false
    private var boosted = false
    private var task: Task<Void, Never>?
    private var producer: (@Sendable (VotingDelegationOperation) async throws -> VotingDelegationProofResult)?

    init(producer: @escaping @Sendable (VotingDelegationOperation) async throws -> VotingDelegationProofResult) {
        self.producer = producer
    }

    /// Wait for this operation, independently of any other waiter's cancellation.
    /// Interactive subscriptions permanently promote this operation until native return.
    public func result(
        intent: VotingProvingIntent,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> VotingDelegationProofResult {
        let id = UUID()
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                subscribe(id: id, intent: intent, progress: progress, cancellation: cancellation, continuation: continuation)
            }
        } onCancel: {
            cancellation.markCancelled()
            self.removeSubscriber(id)
        }
    }

    /// Promote an existing speculative operation, including a proof already in native code.
    public func promote() async { promoteSynchronously() }

    /// Invalidate results and progress, then wait for native work and callbacks to finish.
    public func cancelAndWait() async {
        cancel()
        await waitForReturn()
    }

    func waitForReturn() async {
        await producerTask()?.value
        await withCheckedContinuation { continuation in
            callbacks.async { continuation.resume() }
        }
    }

    private func producerTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }

    var canRetry: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let completion else { return cancelled && task == nil }
        if case .failure = completion { return true }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let removed = subscribers.values
        subscribers.removeAll()
        let running = task
        if running == nil { producer = nil }
        lock.unlock()
        running?.cancel()
        removed.forEach { $0.continuation.resume(throwing: CancellationError()) }
    }

    func beginProof() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        entered = true
        if interactive && !boosted {
            VotingRustBackend.beginInteractiveProvingBoost()
            boosted = true
        }
    }

    func endProof() {
        lock.lock()
        defer { lock.unlock() }
        entered = false
        if boosted {
            VotingRustBackend.endInteractiveProvingBoost()
            boosted = false
        }
    }

    func report(_ progress: Double) {
        lock.lock()
        guard !cancelled, completion == nil else {
            lock.unlock()
            return
        }
        latestProgress = progress
        let ids = Array(subscribers.keys)
        lock.unlock()
        for id in ids { deliver(progress, to: id) }
    }

    private func deliver(_ progress: Double, to id: UUID) {
        callbacks.async { [self] in
            lock.lock()
            let callback = cancelled ? nil : subscribers[id]?.progress
            lock.unlock()
            callback?(progress)
        }
    }

    private func promoteSynchronously() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled, completion == nil else { return }
        promoteLocked()
    }

    private func promoteLocked() {
        interactive = true
        if entered && !boosted {
            VotingRustBackend.beginInteractiveProvingBoost()
            boosted = true
        }
    }

    private func subscribe(
        id: UUID,
        intent: VotingProvingIntent,
        progress: (@Sendable (Double) -> Void)?,
        cancellation: CancellationFlag,
        continuation: CheckedContinuation<VotingDelegationProofResult, Error>
    ) {
        lock.lock()
        if cancelled || cancellation.isCancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        if let completion {
            lock.unlock()
            continuation.resume(with: completion)
            return
        }
        if intent == .interactive { promoteLocked() }
        subscribers[id] = Subscriber(continuation: continuation, progress: progress)
        let replay = latestProgress
        if task == nil, let producer {
            let priority: TaskPriority = interactive ? .userInitiated : .utility
            task = Task.detached(priority: priority) { [self] in
                let result: Completion
                do {
                    try Task.checkCancellation()
                    result = .success(try await producer(self))
                } catch {
                    result = .failure(error)
                }
                finish(result)
            }
            self.producer = nil
        }
        lock.unlock()
        if let replay { deliver(replay, to: id) }
    }

    private func removeSubscriber(_ id: UUID) {
        lock.lock()
        let subscriber = subscribers.removeValue(forKey: id)
        lock.unlock()
        subscriber?.continuation.resume(throwing: CancellationError())
    }

    private func finish(_ result: Completion) {
        lock.lock()
        let delivered: Completion = cancelled ? .failure(CancellationError()) : result
        completion = delivered
        let waiting = subscribers.values
        subscribers.removeAll()
        lock.unlock()
        waiting.forEach { $0.continuation.resume(with: delivered) }
    }
}

extension VotingRustBackend {
    /// Reuse an operation only when the wallet, persisted setup and all proof inputs match.
    /// The operation starts when its first `result` subscriber arrives.
    public func delegationOperation(
        params: VotingDelegationProofParams,
        pirEndpoints: [URL],
        expectedSnapshotHeight: BlockHeight,
        layout: VotingPirLayout
    ) async throws -> VotingDelegationOperation {
        try await delegationOperation(
            params: params,
            pirEndpoints: pirEndpoints,
            expectedSnapshotHeight: expectedSnapshotHeight,
            layout: layout,
            pirResolver: PirSnapshotResolver(),
            proveEntry: nil
        )
    }

    func delegationOperation(
        params: VotingDelegationProofParams,
        pirEndpoints: [URL],
        expectedSnapshotHeight: BlockHeight,
        layout: VotingPirLayout,
        pirResolver: PirSnapshotResolver,
        proveEntry: VotingDelegationProveEntry?
    ) async throws -> VotingDelegationOperation {
        try Task.checkCancellation()
        guard expectedSnapshotHeight >= 0 else {
            throw VotingRustBackendError.invalidData("Delegation snapshot must be nonnegative")
        }
        let scope = try delegationRegistry.scope()
        let queue = delegationRegistry.provingQueue
        var setupSighash: [UInt8] = []
        var completed: VotingDelegationProofResult?
        return try delegationRegistry.operation(scope: scope) { reader in
            let state = try reader.getRoundState(roundId: params.roundId)
            guard state.snapshotHeight == UInt64(expectedSnapshotHeight) else {
                throw VotingRustBackendError.invalidData("Delegation snapshot does not match persisted round")
            }
            let sighash = try reader.getStoredPcztSighash(roundId: params.roundId, bundleIndex: params.bundleIndex)
            setupSighash = sighash
            completed = try reader.completedDelegationProof(params, snapshotHeight: expectedSnapshotHeight, sighash: sighash)
            return try VotingDelegationIdentity(
                params: params,
                endpoints: pirEndpoints,
                height: expectedSnapshotHeight,
                layout: layout,
                sighash: sighash
            )
        } make: { [weak self] in
            let persisted = completed
            let sighash = setupSighash
            return VotingDelegationOperation { [weak self] operation in
                if let persisted { return persisted }
                guard let self else { throw VotingRustBackendError.databaseNotOpen }
                let ticket = UUID()
                operation.report(0)
                try await queue.acquire(ticket)
                do {
                    try self.delegationRegistry.check(scope)
                    if let persisted = try self.completedDelegationProof(
                        params,
                        snapshotHeight: expectedSnapshotHeight,
                        sighash: sighash,
                        expectedScope: scope
                    ) {
                        await queue.release(ticket)
                        return persisted
                    }
                    let result = try await self.resolveAndProveDelegation(
                        params,
                        pirEndpoints: pirEndpoints.map(\.absoluteString),
                        expectedSnapshotHeight: UInt64(expectedSnapshotHeight),
                        pirLayout: layout,
                        pirResolver: pirResolver,
                        progress: { operation.report($0) },
                        operation: operation,
                        proveEntry: proveEntry ?? { [self] params, url, layout, progress in
                            try self.syncBuildAndProveDelegation(
                                params,
                                pirServerUrl: url,
                                pirLayout: layout,
                                progress: progress,
                                expectedScope: scope
                            )
                        }
                    )
                    await queue.release(ticket)
                    return result
                } catch {
                    await queue.release(ticket)
                    throw error
                }
            }
        }
    }

    /// Fence admissions and results, then join every proof and pending progress callback.
    /// Call before clearing or reopening the voting database.
    public func cancelDelegationOperationsAndWait() async {
        let operations = delegationRegistry.beginMutation()
        for operation in operations { await operation.waitForReturn() }
        delegationRegistry.endDrain(operations)
    }
}

struct VotingDelegationScope: Equatable, Sendable {
    let path: String
    let network: UInt32
    let wallet: String
    let generation: UUID
}

struct VotingDelegationIdentity: Hashable, Sendable, Undescribable {
    private let digest: Data

    init(params: VotingDelegationProofParams, endpoints: [URL], height: BlockHeight, layout: VotingPirLayout, sighash: [UInt8]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let fields = [
            Data(params.roundId.utf8), try encoder.encode(params.bundleIndex), try encoder.encode(params.notes),
            Data(params.keys.fvk), Data(params.keys.hotkeyStoredSecret), Data(params.keys.seedFingerprint),
            try encoder.encode(params.keys.accountIndex), Data(params.keys.roundName.utf8),
            try encoder.encode(endpoints.map(\.absoluteString)), try encoder.encode(height),
            try encoder.encode([layout.pirDepth, layout.tier0Layers, layout.tier1Layers, layout.polyLen]), Data(sighash)
        ]
        digest = Data(SHA256.hash(data: try encoder.encode(fields)))
    }
}

final class VotingDelegationRegistry: @unchecked Sendable {
    // Native reader I/O is serialized by admission, never performed under the state lock.
    private let admission = DispatchQueue(label: "cash.z.zcashlc.delegation-admission")
    private let lock = NSLock()
    private var current: VotingDelegationScope?
    private var mutationDepth = 0
    private var reader: VotingRustBackend?
    private var entries: [VotingDelegationIdentity: VotingDelegationOperation] = [:]
    private var retired: [VotingDelegationOperation] = []
    let provingQueue = VotingDelegationQueue()

    func open(path: String, network: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        current = VotingDelegationScope(
            path: URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path,
            network: network,
            wallet: "",
            generation: UUID()
        )
    }

    func close() {
        lock.lock()
        current = nil
        lock.unlock()
    }

    func setWallet(_ wallet: String) {
        lock.lock()
        defer { lock.unlock() }
        if let scope = current {
            current = VotingDelegationScope(path: scope.path, network: scope.network, wallet: wallet, generation: UUID())
        }
    }

    func scope() throws -> VotingDelegationScope {
        lock.lock()
        defer { lock.unlock() }
        guard let current, !current.wallet.isEmpty else { throw VotingRustBackendError.databaseNotOpen }
        guard mutationDepth == 0 else { throw CancellationError() }
        return current
    }

    func check(_ scope: VotingDelegationScope) throws {
        lock.lock()
        defer { lock.unlock() }
        guard current == scope, mutationDepth == 0 else { throw CancellationError() }
    }

    func operation(
        scope: VotingDelegationScope,
        identity: (VotingRustBackend) throws -> VotingDelegationIdentity,
        make: () -> VotingDelegationOperation
    ) throws -> VotingDelegationOperation {
        try admission.sync {
            try check(scope)
            if reader == nil {
                let opened = VotingRustBackend()
                try opened.open(path: scope.path, networkId: scope.network)
                try opened.setWalletId(scope.wallet)
                reader = opened
            }
            guard let reader else { throw VotingRustBackendError.databaseNotOpen }
            let key = try identity(reader)
            lock.lock()
            let existing = entries[key]
            lock.unlock()
            if let existing, !existing.canRetry { return existing }
            let operation = make()
            lock.lock()
            entries[key] = operation
            lock.unlock()
            return operation
        }
    }

    /// Legacy synchronous mutations join any identity read before changing the database.
    /// Native proof calls still use the original primary-handle lock as their lifetime guard.
    @discardableResult
    func beginMutation() -> [VotingDelegationOperation] {
        let operations = admission.sync {
            lock.lock()
            mutationDepth += 1
            if let scope = current {
                current = VotingDelegationScope(path: scope.path, network: scope.network, wallet: scope.wallet, generation: UUID())
            }
            retired.append(contentsOf: entries.values)
            entries.removeAll()
            let operations = retired
            lock.unlock()
            reader?.close()
            reader = nil
            return operations
        }
        operations.forEach { $0.cancel() }
        return operations
    }

    func endMutation() {
        lock.lock()
        mutationDepth -= 1
        lock.unlock()
    }

    func endDrain(_ operations: [VotingDelegationOperation]) {
        let joined = Set(operations.map(ObjectIdentifier.init))
        lock.lock()
        retired.removeAll { joined.contains(ObjectIdentifier($0)) }
        mutationDepth -= 1
        lock.unlock()
    }
}

/// One native delegation entry at a time, with independently cancellable queued requests.
actor VotingDelegationQueue {
    private var owner: UUID?
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire(_ id: UUID) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if owner == nil {
                    owner = id
                    continuation.resume()
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release(_ id: UUID) {
        guard owner == id else { return }
        if waiters.isEmpty {
            owner = nil
        } else {
            let next = waiters.removeFirst()
            owner = next.0
            next.1.resume()
        }
    }

    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            waiters.remove(at: index).1.resume(throwing: CancellationError())
        }
    }
}

typealias VotingDelegationProveEntry =
    @Sendable (
        VotingDelegationProofParams, String, VotingPirLayout, (@Sendable (Double) -> Void)?
    ) throws -> VotingDelegationProofResult
