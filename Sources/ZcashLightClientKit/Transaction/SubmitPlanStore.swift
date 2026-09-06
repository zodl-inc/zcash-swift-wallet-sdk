//
//  SubmitPlanStore.swift
//  ZcashLightClientKit
//

import Foundation
import SQLite

/// The stored retry plan for one transaction created through `Broadcaster`.
enum StoredSubmitPlan: Equatable {
    /// Created via `Broadcaster` but never submitted by the caller.
    /// Resubmission must skip it.
    case awaiting
    /// Submitted to these endpoints; resubmission retries through them.
    /// `acceptedBy` is `host:port` of the server that took the transaction into
    /// its mempool, or `nil` while no server has acknowledged it. Acceptance
    /// does not end retrying: an accepted transaction is still resubmitted
    /// until it is mined, because a mempool is not a commitment.
    case ready([LightWalletEndpoint], acceptedBy: String?)
    /// The store cannot be read, so whether a plan exists is unknown.
    /// Resubmission must skip the transaction: auto-submitting something the
    /// app may never have released is worse than delaying a retry.
    case storeUnavailable
}

extension StoredSubmitPlan {
    /// The public status this stored plan reports to a host. `nil` where the SDK
    /// cannot answer: a store it cannot read says nothing about the transaction,
    /// and neither does a missing row.
    var submissionStatus: TransactionSubmissionStatus? {
        switch self {
        case .awaiting:
            return .awaiting
        case .ready(_, let acceptedBy):
            guard let acceptedBy else { return .submitted }
            return .accepted(host: acceptedBy)
        case .storeUnavailable:
            return nil
        }
    }
}

/// A token identifying one epoch of the submit-plan store's lifetime. `wipe()` retires the
/// current token and starts a new one, so a write still carrying a retired token (an acceptance
/// for a submission that began before the wipe) can be recognized as stale instead of being
/// applied to — and thereby recreating — the store the caller already asked to delete.
struct SubmitPlanLifecycle: Equatable, Sendable {
    let generation: Int
}

protocol SubmitPlanStoring {
    /// Marks `txIds` awaiting submission by the app. Dropped — logged, not thrown — when
    /// `lifecycle` belongs to an epoch the store has since wiped: see `currentLifecycle()`.
    func markAwaitingSubmission(txIds: [Data], lifecycle: SubmitPlanLifecycle) async
    /// Records the plan and returns the store's current lifecycle token, for a later
    /// `markAccepted(txId:host:lifecycle:)` call to prove it still belongs to this epoch.
    @discardableResult
    func recordPlan(txId: Data, endpoints: [LightWalletEndpoint]) async -> SubmitPlanLifecycle
    /// `recordPlan`, but a no-op — returning `nil` without touching the file system — when the
    /// store's backing database file does not exist. For a release-for-resubmission call, which
    /// unlike `recordPlan` must never recreate a store `wipe()` has already deleted: any
    /// transaction that was legitimately created already has a row from `markAwaitingSubmission`,
    /// which guarantees the file exists by the time a release for it could arrive, so this can only
    /// ever refuse a release that landed after a wipe.
    @discardableResult
    func recordPlanIfStoreExists(txId: Data, endpoints: [LightWalletEndpoint]) async -> SubmitPlanLifecycle?
    /// Records that `host` (`host:port`) took the transaction into its mempool.
    /// Creates the row when the transaction has no plan yet, so a transaction
    /// accepted through a path that never recorded one is still reportable.
    /// Dropped — logged, not thrown — when `lifecycle` belongs to an epoch the store has since
    /// wiped: see `currentLifecycle()`.
    func markAccepted(txId: Data, host: String, lifecycle: SubmitPlanLifecycle) async
    /// `nil` means the store was read successfully and has no row — a legacy
    /// transaction unknown to this store. Read failures return
    /// `.storeUnavailable`, never `nil`.
    func plan(for txId: Data) async -> StoredSubmitPlan?
    func allPlannedTransactionIds() async -> [Data]
    func deletePlans(txIds: [Data]) async
    func clear() async
    /// Deletes the backing database file and resets the store so it can start
    /// fresh. Part of `Synchronizer.wipe()`.
    func wipe() async
    /// The store's current lifecycle token. A caller that cannot keep the token `recordPlan`
    /// returned (because it re-reads the plan after some other async work, rather than holding
    /// onto the token from when it recorded the plan) fetches a fresh one here immediately before
    /// the work whose result will flow into `markAccepted`.
    func currentLifecycle() async -> SubmitPlanLifecycle
}

/// SQLite-backed store for per-transaction submit plans.
///
/// Writes are best-effort: I/O failures are logged and swallowed so a
/// persistence problem can never fail a send. Reads fail safe: when the store
/// cannot be opened or read, lookups report `.storeUnavailable` so background
/// resubmission skips the affected transactions instead of falling back to an
/// endpoint the user didn't choose.
actor SubmitPlanStore: SubmitPlanStoring {
    private let databaseURL: URL
    private let logger: Logger

    private var cachedConnection: Connection?
    private var connectionFailed = false
    private var lifecycleGeneration = 0

    private static let tableName = "tx_submit_plans"
    private static let acceptedHostColumnName = "accepted_host"

    private let table = Table(SubmitPlanStore.tableName)
    private let txIdColumn = SQLite.Expression<Blob>("tx_id")
    private let endpointsColumn = SQLite.Expression<String>("endpoints")
    private let acceptedHostColumn = SQLite.Expression<String?>(SubmitPlanStore.acceptedHostColumnName)

    init(databaseURL: URL, logger: Logger) {
        self.databaseURL = databaseURL
        self.logger = logger
    }

    func markAwaitingSubmission(txIds: [Data], lifecycle: SubmitPlanLifecycle) {
        // A wipe that landed while the transaction was still being created (proving, PCZT
        // extraction) retired this token. Applying the write now would reopen `connection()` and
        // recreate the database file the wipe just deleted, for a transaction the caller already
        // asked to forget. Log and drop instead of throwing, mirroring `markAccepted`'s guard.
        guard lifecycle.generation == lifecycleGeneration else {
            logger.info("SubmitPlanStore ignored a mark-awaiting-submission call from a previous wallet lifecycle.")
            return
        }
        guard let connection = connection() else { return }
        do {
            for txId in txIds {
                let insert = table.insert(
                    or: .ignore,
                    txIdColumn <- Blob(bytes: txId.bytes),
                    endpointsColumn <- "[]"
                )
                try connection.run(insert)
            }
        } catch {
            // The awaiting mark is what keeps background resubmission away
            // from transactions the app never submitted. If it cannot be
            // written, fail the store closed for this session so lookups
            // report `.storeUnavailable` instead of `nil` (legacy) for the
            // unmarked transactions.
            cachedConnection = nil
            connectionFailed = true
            logger.warn("SubmitPlanStore failed to mark transactions awaiting submission; disabling the store: \(error)")
        }
    }

    @discardableResult
    func recordPlan(txId: Data, endpoints: [LightWalletEndpoint]) -> SubmitPlanLifecycle {
        guard !endpoints.isEmpty else { return currentLifecycle() }
        guard let connection = connection() else { return currentLifecycle() }
        do {
            let storedEndpoints = endpoints.map { StoredEndpoint(endpoint: $0) }
            let encoded = try JSONEncoder().encode(storedEndpoints)
            let json = String(data: encoded, encoding: .utf8) ?? "[]"
            // Insert-then-update rather than a replacing upsert, so a plan
            // recorded again for an already-accepted transaction keeps its
            // `accepted_host` instead of reverting to NULL: acceptance
            // survives a re-recorded plan.
            let insert = table.insert(
                or: .ignore,
                txIdColumn <- Blob(bytes: txId.bytes),
                endpointsColumn <- json
            )
            try connection.run(insert)
            try connection.run(table.filter(txIdColumn == Blob(bytes: txId.bytes)).update(endpointsColumn <- json))
        } catch {
            logger.warn("SubmitPlanStore failed to record submit plan: \(error.localizedDescription)")
        }
        return currentLifecycle()
    }

    /// `recordPlan`, but refuses to touch the file system when the database file is gone.
    ///
    /// `connection()` creates the directory and the SQLite file as a side effect of opening it, so
    /// an ordinary `recordPlan` call reaching a wiped wallet would recreate `submit_plans.db` for a
    /// wallet that no longer has one. Checking `FileManager` directly, before `connection()` ever
    /// runs, is what makes the refusal possible: by the time this is called for a release racing a
    /// `wipe()`, the file that release's earlier `markAwaitingSubmission` created is already gone.
    @discardableResult
    func recordPlanIfStoreExists(txId: Data, endpoints: [LightWalletEndpoint]) -> SubmitPlanLifecycle? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        return recordPlan(txId: txId, endpoints: endpoints)
    }

    func markAccepted(txId: Data, host: String, lifecycle: SubmitPlanLifecycle) {
        // A wipe that landed while this acceptance's submission was still in flight retired
        // this token. Applying the write now would reopen `connection()` and recreate the database
        // file the wipe just deleted — for a submission the caller already asked to forget. Log and
        // drop instead of throwing: this is an ordinary, expected race, not a failure.
        guard lifecycle.generation == lifecycleGeneration else {
            logger.info("SubmitPlanStore ignored an acceptance from a previous wallet lifecycle.")
            return
        }
        guard let connection = connection() else { return }
        do {
            // Insert-then-update rather than an upsert: a replacing insert would
            // wipe the endpoint list `recordPlan` stored moments earlier, and
            // that list is the only thing background resubmission can retry
            // through.
            let insert = table.insert(
                or: .ignore,
                txIdColumn <- Blob(bytes: txId.bytes),
                endpointsColumn <- "[]"
            )
            try connection.run(insert)
            try connection.run(table.filter(txIdColumn == Blob(bytes: txId.bytes)).update(acceptedHostColumn <- host))
        } catch {
            logger.warn("SubmitPlanStore failed to record the accepting server for a submit plan: \(error.localizedDescription)")
        }
    }

    func plan(for txId: Data) -> StoredSubmitPlan? {
        guard let connection = connection() else { return .storeUnavailable }
        do {
            let query = table.filter(txIdColumn == Blob(bytes: txId.bytes))
            guard let row = try connection.pluck(query) else { return nil }

            // The accepting host decides first: once a server has taken the
            // transaction it is no longer awaiting submission, whatever the
            // endpoint list says. A row written before this column existed, or
            // by a path that only marked the transaction awaiting, has none and
            // keeps the endpoint-driven mapping.
            let acceptedHost = row[acceptedHostColumn]

            let json = row[endpointsColumn]
            guard
                let data = json.data(using: .utf8),
                let storedEndpoints = try? JSONDecoder().decode([StoredEndpoint].self, from: data)
            else {
                // Never silently fall back to an endpoint the user didn't choose:
                // an undecodable plan behaves as if it listed no endpoints until
                // pruning removes it. Retrying an empty list is a no-op, so
                // reporting the acceptance costs nothing.
                logger.warn("SubmitPlanStore found undecodable endpoints for a plan; ignoring them.")
                guard let acceptedHost else { return .awaiting }
                return .ready([], acceptedBy: acceptedHost)
            }

            let endpoints = storedEndpoints.map(\.endpoint)
            if let acceptedHost {
                return .ready(endpoints, acceptedBy: acceptedHost)
            }
            return endpoints.isEmpty ? .awaiting : .ready(endpoints, acceptedBy: nil)
        } catch {
            logger.warn("SubmitPlanStore failed to load submit plan: \(error)")
            return .storeUnavailable
        }
    }

    func allPlannedTransactionIds() -> [Data] {
        guard let connection = connection() else { return [] }
        do {
            return try connection.prepare(table.select(txIdColumn)).map { row in
                Data(row[txIdColumn].bytes)
            }
        } catch {
            logger.warn("SubmitPlanStore failed to list submit plans: \(error)")
            return []
        }
    }

    func deletePlans(txIds: [Data]) {
        guard !txIds.isEmpty else { return }
        guard let connection = connection() else { return }
        do {
            for txId in txIds {
                try connection.run(table.filter(txIdColumn == Blob(bytes: txId.bytes)).delete())
            }
        } catch {
            logger.warn("SubmitPlanStore failed to delete submit plans: \(error)")
        }
    }

    func clear() {
        guard let connection = connection() else { return }
        do {
            try connection.run(table.delete())
        } catch {
            logger.warn("SubmitPlanStore failed to clear submit plans: \(error)")
        }
    }

    func wipe() {
        // Retire the current lifecycle first, before anything else: any `markAccepted` call
        // already holding a token from this epoch — a foreground submission whose network race is
        // still in flight — must see the mismatch, however soon after this line it arrives.
        lifecycleGeneration += 1
        // Drop the connection first so the file handle is closed, then remove
        // the file itself: row deletion alone would leave transaction ids and
        // endpoints recoverable from SQLite free pages after a wallet wipe.
        cachedConnection = nil
        connectionFailed = false
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: databaseURL)
        } catch {
            logger.warn("SubmitPlanStore failed to delete its database file: \(error)")
        }
    }

    func currentLifecycle() -> SubmitPlanLifecycle {
        SubmitPlanLifecycle(generation: lifecycleGeneration)
    }

    private static let schemaVersion: Int64 = 1

    private func connection() -> Connection? {
        if let cachedConnection { return cachedConnection }
        guard !connectionFailed else { return nil }

        do {
            let directoryURL = databaseURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableDirectoryURL = directoryURL
            try mutableDirectoryURL.setResourceValues(resourceValues)

            let connection = try Connection(databaseURL.path)

            let schemaVersion = try connection.scalar("PRAGMA user_version") as? Int64 ?? 0
            guard schemaVersion <= Self.schemaVersion else {
                // Written by a newer SDK; don't touch it (a downgraded SDK
                // misreading rows could resurrect the legacy fallback).
                connectionFailed = true
                logger.warn(
                    "SubmitPlanStore database schema \(schemaVersion) is newer than the supported \(Self.schemaVersion); submit plans are disabled."
                )
                return nil
            }

            try connection.run(table.create(ifNotExists: true) { builder in
                builder.column(txIdColumn, primaryKey: true)
                builder.column(endpointsColumn, defaultValue: "[]")
                builder.column(acceptedHostColumn)
            })
            // `accepted_host` is added by presence check instead of by a schema
            // version bump on purpose. A nullable added column is backward
            // compatible: an older SDK build keeps reading and writing this
            // store, simply ignoring the column. Bumping `user_version` would
            // instead trip the newer-schema guard above in every older build on
            // the same device — a TestFlight downgrade or a QA device that
            // alternates builds would lose submit plans entirely.
            if try !columnNames(of: connection).contains(Self.acceptedHostColumnName) {
                try connection.run(table.addColumn(acceptedHostColumn))
            }
            if schemaVersion < Self.schemaVersion {
                try connection.run("PRAGMA user_version = \(Self.schemaVersion)")
            }

            cachedConnection = connection
            return connection
        } catch {
            connectionFailed = true
            logger.warn("SubmitPlanStore could not open its database; submit plans are disabled: \(error)")
            return nil
        }
    }

    /// The columns the plans table currently has, so an additive column can be
    /// added once and never a second time — `ADD COLUMN` on a column that is
    /// already there throws, and that would disable the store for the session.
    private func columnNames(of connection: Connection) throws -> [String] {
        try connection.prepare("PRAGMA table_info(\(Self.tableName))").compactMap { row in
            row[1] as? String
        }
    }
}

/// Codable persistence shape for one endpoint.
private struct StoredEndpoint: Codable, Equatable {
    let host: String
    let port: Int
    let secure: Bool
    let singleCallTimeoutInMillis: Int64
    let streamingCallTimeoutInMillis: Int64

    init(endpoint: LightWalletEndpoint) {
        host = endpoint.host
        port = endpoint.port
        secure = endpoint.secure
        singleCallTimeoutInMillis = endpoint.singleCallTimeoutInMillis
        streamingCallTimeoutInMillis = endpoint.streamingCallTimeoutInMillis
    }

    var endpoint: LightWalletEndpoint {
        LightWalletEndpoint(
            address: host,
            port: port,
            secure: secure,
            singleCallTimeoutInMillis: singleCallTimeoutInMillis,
            streamingCallTimeoutInMillis: streamingCallTimeoutInMillis
        )
    }
}
