import Foundation
import libzcashlc

/// Retains an independent wallet-scoped native database and helper transport.
/// Helper HTTP work never borrows the primary voting backend's handle.
public final class VotingHelperClient: @unchecked Sendable {
    private let driver: any VotingHelperDriving
    private let lock = NSLock()
    private let active = DispatchGroup()
    private var closed = false

    init(driver: any VotingHelperDriving) {
        self.driver = driver
    }

    convenience init(nativeHandle: OpaquePointer) {
        self.init(driver: NativeVotingHelperDriver(handle: nativeHandle))
    }

    deinit { driver.cancel() }

    public func preflightFleet(urls: [URL]) async throws -> VotingHelperFleet {
        try await perform(HelperRequest(operation: "preflight", urls: urls))
    }

    public func prepareShareDelivery(
        identity: VotingHelperDeliveryIdentity,
        fleet: VotingHelperFleet,
        configuration: VotingHelperRoundConfiguration,
        now: UInt64
    ) async throws -> VotingPreparedShareDelivery {
        try await perform(HelperRequest(operation: "prepare", identity: identity, fleet: fleet, configuration: configuration, now: now))
    }

    public func submitPreparedShares(
        delivery: VotingPreparedShareDelivery,
        configuration: VotingHelperRoundConfiguration,
        now: UInt64
    ) async throws -> VotingShareDeliveryReport {
        try await perform(HelperRequest(operation: "submit", identity: delivery.identity, configuration: configuration, now: now))
    }

    public func confirmPendingShare(
        identity: VotingHelperShareIdentity,
        configuration: VotingHelperRoundConfiguration,
        now: UInt64
    ) async throws -> VotingShareConfirmationReport {
        try await perform(HelperRequest(operation: "confirm", share: identity, configuration: configuration, now: now))
    }

    public func trackPendingShares(
        configuration: VotingHelperRoundConfiguration,
        now: UInt64
    ) async throws -> VotingShareTrackingReport {
        try await perform(HelperRequest(operation: "track", configuration: configuration, now: now))
    }

    /// Persist the complete user-approved ballot before committing or preparing shares.
    /// Native validation protects submitted and unknown vote evidence. Each intent is
    /// individually atomic: a later conflict can leave earlier writes persisted.
    /// Read back/retry after failure and dispatch no commitment until the full call succeeds.
    public func setBallotIntents(roundID: VotingRoundID, intents: [VotingBallotIntent]) async throws {
        let _: Bool? = try await perform(HelperRequest(operation: "set_intents", roundID: roundID, intents: intents))
    }

    /// Returns only durable decisions. Absence never implies that a proposal was skipped.
    public func ballotIntents(roundID: VotingRoundID) async throws -> [UInt32: VotingBallotDecision] {
        let values: [String: VotingBallotDecision] = try await perform(HelperRequest(operation: "intents", roundID: roundID))
        var result: [UInt32: VotingBallotDecision] = [:]
        for (key, decision) in values {
            guard let proposal = UInt32(key) else { throw VotingHelperError.invalidReport }
            result[proposal] = decision
        }
        return result
    }

    /// Permanently fence new work, cancel active operations and await their actual return.
    public func cancelAndWait() async {
        fenceNewWork()
        driver.cancel()
        await withCheckedContinuation { continuation in
            active.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
                continuation.resume()
            }
        }
    }

    private func fenceNewWork() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    private func acquire() throws -> any VotingHelperOperationDriving {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw VotingHelperError.cancelled }
        let operation = try driver.acquire()
        active.enter()
        return operation
    }

    private func perform<Result: Decodable>(_ request: HelperRequest) async throws -> Result {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(request)
        let operation = try acquire()
        defer { active.leave() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let response: Data = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Swift.Result { try operation.execute(data) })
                }
            }
            return try JSONDecoder().decode(Result.self, from: response)
        } onCancel: {
            operation.cancel()
        }
    }
}

protocol VotingHelperDriving: Sendable {
    func acquire() throws -> any VotingHelperOperationDriving
    func cancel()
}

protocol VotingHelperOperationDriving: Sendable {
    func execute(_ request: Data) throws -> Data
    func cancel()
}

private final class NativeVotingHelperDriver: VotingHelperDriving, @unchecked Sendable {
    private let handle: OpaquePointer
    init(handle: OpaquePointer) { self.handle = handle }
    deinit { zcashlc_voting_helper_free(handle) }
    func cancel() { zcashlc_voting_helper_cancel(handle) }
    func acquire() throws -> any VotingHelperOperationDriving {
        guard let operation = zcashlc_voting_helper_acquire(handle) else {
            throw VotingHelperError.cancelled
        }
        return NativeVotingHelperOperation(handle: operation)
    }
}

private final class NativeVotingHelperOperation: VotingHelperOperationDriving, @unchecked Sendable {
    private let handle: OpaquePointer
    init(handle: OpaquePointer) { self.handle = handle }
    deinit { zcashlc_voting_helper_operation_free(handle) }
    func cancel() { zcashlc_voting_helper_operation_cancel(handle) }
    func execute(_ request: Data) throws -> Data {
        let bytes = Array(request)
        guard let response = bytes.withUnsafeBufferPointer({
            zcashlc_voting_helper_execute(handle, $0.baseAddress, UInt($0.count))
        }) else {
            throw VotingHelperError.nativeOperationFailed
        }
        defer { zcashlc_free_boxed_slice(response) }
        return Data(bytes: response.pointee.ptr, count: Int(response.pointee.len))
    }
}

private struct HelperRequest: Encodable {
    let operation: String
    var urls: [URL]?
    var roundID: VotingRoundID?
    var intents: [VotingBallotIntent]?
    var identity: VotingHelperDeliveryIdentity?
    var share: VotingHelperShareIdentity?
    var fleet: VotingHelperFleet?
    var configuration: VotingHelperRoundConfiguration?
    var now: UInt64?

    private enum CodingKeys: String, CodingKey {
        case operation, urls, intents, identity, share, fleet, configuration, now
        case roundID = "round_id"
    }
}
