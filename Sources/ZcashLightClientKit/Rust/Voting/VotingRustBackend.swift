//
//  VotingRustBackend.swift
//  ZcashLightClientKit
//

import Foundation
import libzcashlc

// MARK: - Error

/// What the voting wrapper refuses on its own, before any FFI call is made.
///
/// Everything the crate refuses crosses the boundary as ``VotingError``, which
/// carries the kind a host branches on. These cases have no crate answer to
/// carry, because there was no call to make: the database is not open or is
/// already open, or the session is closed or already driving its round.
public enum VotingRustBackendError: LocalizedError, Equatable {
    /// The voting database is already open.
    case databaseAlreadyOpen
    /// The voting database is not open.
    case databaseNotOpen
    /// The session is closed. A closed session is finished rather than paused:
    /// further work on that round needs a new session.
    case sessionClosed
    /// A run or a share-tracking run is already in flight on this session.
    case sessionBusy

    public var errorDescription: String? {
        switch self {
        case .databaseAlreadyOpen:
            return "Voting database is already open."
        case .databaseNotOpen:
            return "Voting database is not open."
        case .sessionClosed:
            return "Voting round session is closed."
        case .sessionBusy:
            return "Voting round session is already driving this round."
        }
    }
}

// MARK: - VotingRustBackend

/// Wraps the voting `libzcashlc` C FFI surface.
///
/// Two halves. The store half is this type: an opaque `VotingDatabaseHandle`
/// over the sidecar database, the reads a host renders a round list from, and
/// the maintenance calls it makes outside a round. The round half is
/// ``VotingRoundSession``, opened through ``makeSession(inputs:binding:torRuntime:epoch:)``,
/// which owns everything that reads the wallet, proves, or reaches the network.
///
/// Stateless FFI — hotkeys, key extraction, the proving policy — is exposed as
/// type methods, so a caller that has no database can still use it.
///
/// Errors: every failing FFI call throws the crate's own ``VotingError``, built
/// from the typed JSON the FFI leaves in its last-error slot. The wrapper's own
/// refusals — no handle, a handle already open — throw
/// ``VotingRustBackendError``.
///
/// Thread safety: handle access is serialized by an `NSLock`. The sidecar reads
/// and writes hold it for their whole duration — they are queries, and holding
/// it is what keeps ``close()`` from freeing the handle underneath one. The one
/// store call that reaches the network, ``syncVoteTree(roundId:nodeUrl:)``,
/// does not: it runs its FFI call on a detached task with the lock released, so
/// a round listing or a close is never stuck behind a tree sync. Everything
/// else that blocks for longer than a query belongs to a session.
public final class VotingRustBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?
    /// The handle a ``close()`` could not free because a sync was still using
    /// it. The last sync to finish frees it.
    private var handleAwaitingFree: OpaquePointer?
    /// The detached vote-tree syncs running right now, keyed so a finished one
    /// removes its own entry and no other.
    private var inFlight: [UUID: Task<Void, Never>] = [:]

    public init() {}

    deinit {
        if let handle {
            zcashlc_voting_db_free(handle)
        }
    }

    // MARK: - Database lifecycle

    /// Open the voting database at `path` for `networkId`.
    ///
    /// An existing schema-13 sidecar is migrated in place as it opens.
    ///
    /// The network is fixed for the lifetime of the handle: every
    /// database-bound call takes its voting identity from `networkId` rather
    /// than accepting one of its own, so no later call can disagree with the
    /// network the database was opened for. A custom (regtest) network takes
    /// its voting identity from the registered base network, and opening fails
    /// if that network has not been configured yet.
    ///
    /// Throws ``VotingRustBackendError/databaseAlreadyOpen`` if the backend
    /// already holds an open handle.
    public func open(path: String, networkId: UInt32) throws {
        lock.lock()
        defer { lock.unlock() }

        guard handle == nil else {
            throw VotingRustBackendError.databaseAlreadyOpen
        }

        let pathBytes = [UInt8](path.utf8)
        guard let ptr = pathBytes.withUnsafeBufferPointer({ buf in
            zcashlc_voting_db_open(buf.baseAddress, UInt(buf.count), networkId)
        }) else {
            throw Self.votingError(fallback: "`voting_db_open` failed")
        }
        handle = ptr
    }

    /// Close the voting database, freeing the underlying handle.
    ///
    /// Idempotent: closing an already-closed backend is a no-op. A session
    /// opened from this handle keeps its own reference to the sidecar and
    /// stays usable, but closing the sessions first is the order that leaves
    /// nothing driving a round the host has stopped listening to.
    ///
    /// The backend is closed to new calls the moment this returns: every
    /// database-bound call throws ``VotingRustBackendError/databaseNotOpen``
    /// from here on. It does not wait for a
    /// ``syncVoteTree(roundId:nodeUrl:)`` still in flight — this call does not
    /// block, and a sync cannot be interrupted — so the handle, and with it the
    /// sidecar connection, is freed when that sync returns instead of here. A
    /// host that means to delete the sidecar file, rather than just stop using
    /// it, should let the sync it started finish first.
    public func close() {
        lock.lock()
        defer { lock.unlock() }

        guard let dbh = handle else { return }

        // Cleared before the free decision, so a call racing this one is
        // refused as closed whichever side of the free it lands on.
        handle = nil
        if inFlight.isEmpty {
            zcashlc_voting_db_free(dbh)
        } else {
            handleAwaitingFree = dbh
        }
    }

    /// Bind the handle to a wallet identifier, scoping every later operation.
    ///
    /// Must be called after ``open(path:networkId:)`` and before any round
    /// operation, including opening a session: the sidecar holds several
    /// wallets' rounds, and an unscoped read is refused rather than answered
    /// for the wrong wallet. Call it again to follow a wallet switch.
    public func setWalletId(_ walletId: String) throws {
        try withHandle { dbh in
            let bytes = [UInt8](walletId.utf8)
            let status = bytes.withUnsafeBufferPointer { buffer in
                zcashlc_voting_set_wallet_id(dbh, buffer.baseAddress, UInt(buffer.count))
            }
            guard status == 0 else {
                throw Self.votingError(fallback: "`voting_set_wallet_id` failed")
            }
        }
    }

    // MARK: - Round store

    /// Every round of the bound wallet.
    public func listRounds() throws -> [VotingRoundSummary] {
        try withHandle { dbh in
            try Self.decodingJSON(fallback: "`voting_list_rounds` failed") {
                zcashlc_voting_list_rounds(dbh)
            }
        }
    }

    /// The plan for one round against an authenticated proposal roster.
    ///
    /// `proposalIds` is the roster the host authenticated; the plan is made
    /// against it, so a proposal the host cannot vouch for cannot be planned
    /// for. A round the sidecar has never seen is not an error: it plans as an
    /// idle round that owes a draft.
    public func roundPlan(roundId: String, proposalIds: [UInt32]) throws -> VotingRoundPlan {
        let roster = try Self.encodeJSON(proposalIds, describing: "proposal ids")
        return try withRoundId(roundId, bytes: roster) { dbh, id, idLen, roster, rosterLen in
            try Self.decodingJSON(fallback: "`voting_round_plan` failed") {
                zcashlc_voting_round_plan(dbh, id, idLen, roster, rosterLen)
            }
        }
    }

    /// Rounds of the bound wallet with helper-share work still outstanding.
    ///
    /// This is what says whether the host still owes share tracking, so it is
    /// the query to make on entering the voting flow and on foreground while
    /// anything is pending.
    public func pendingShareRounds() throws -> [VotingPendingShareRound] {
        try withHandle { dbh in
            try Self.decodingJSON(fallback: "`voting_pending_share_rounds` failed") {
                zcashlc_voting_pending_share_rounds(dbh)
            }
        }
    }

    /// Sync a round's vote-commitment tree from `nodeUrl`, returning the height
    /// it synced to.
    ///
    /// The one store call that reaches the network, and it blocks for the whole
    /// sync, so it runs its FFI call on a detached task rather than on the
    /// caller's executor — and without the backend lock, which would otherwise
    /// hold up every other call on this handle, ``close()`` included, for the
    /// duration of a network round trip. The handle stays valid while it runs:
    /// a close during a sync frees the handle when the sync returns.
    public func syncVoteTree(roundId: String, nodeUrl: String) async throws -> UInt32 {
        let id = [UInt8](roundId.utf8)
        let url = [UInt8](nodeUrl.utf8)

        let height = try await detached { dbh -> Int64 in
            let synced = id.withUnsafeBufferPointer { idBytes in
                url.withUnsafeBufferPointer { urlBytes in
                    zcashlc_voting_sync_vote_tree(
                        dbh,
                        idBytes.baseAddress,
                        UInt(idBytes.count),
                        urlBytes.baseAddress,
                        UInt(urlBytes.count)
                    )
                }
            }

            // Read here rather than after the await: the FFI's last-error slot
            // is per-thread, and this is the thread that made the call.
            guard synced >= 0 else {
                throw Self.votingError(fallback: "`voting_sync_vote_tree` failed")
            }
            return synced
        }

        guard let synced = UInt32(exactly: height) else {
            throw VotingError(
                kind: .internal,
                message: "vote tree synced to height \(height), which is not a block height"
            )
        }
        return synced
    }

    /// Drop the cached vote-tree state for one round.
    ///
    /// An empty `roundId` is the crate's wallet-wide reset, which forgets every
    /// round's cached tree state, so it is refused here as invalid input: a
    /// host asking about one round never means every round, and the FFI cannot
    /// tell the two apart once the empty id has crossed.
    public func resetVoteTree(roundId: String) throws {
        try requireNamedRound(roundId, calling: "resetVoteTree")
        try withRoundId(roundId) { dbh, id, idLen in
            let status = zcashlc_voting_reset_vote_tree(dbh, id, idLen)
            guard status == 0 else {
                throw Self.votingError(fallback: "`voting_reset_vote_tree` failed")
            }
        }
    }

    /// Return a round to a re-runnable state after an interrupted setup.
    ///
    /// Drops cached tree state and clears locally prepared *unsigned*
    /// delegation setup; proved or submitted bundles, imported capabilities and
    /// stored signatures survive. An empty `roundId` is refused for the same
    /// reason as in ``resetVoteTree(roundId:)``: the crate would read it as a
    /// wallet-wide tree reset rather than as work on one round.
    public func resetSessionState(roundId: String) throws {
        try requireNamedRound(roundId, calling: "resetSessionState")
        try withRoundId(roundId) { dbh, id, idLen in
            let status = zcashlc_voting_reset_session_state(dbh, id, idLen)
            guard status == 0 else {
                throw Self.votingError(fallback: "`voting_reset_session_state` failed")
            }
        }
    }

    /// Delete one round.
    ///
    /// With `discardingRecovery == false` the call refuses once part of the
    /// round has reached the network. Passing `true` abandons such a round on
    /// purpose, giving up the state that could recover its voting weight, so it
    /// belongs behind a decision the voter made.
    public func deleteRound(roundId: String, discardingRecovery: Bool) throws {
        try withRoundId(roundId) { dbh, id, idLen in
            let status = zcashlc_voting_delete_round(dbh, id, idLen, discardingRecovery)
            guard status == 0 else {
                throw Self.votingError(fallback: "`voting_delete_round` failed")
            }
        }
    }

    /// Drop bundle rows at index `>= keepCount`, returning how many were
    /// deleted.
    public func deleteSkippedBundles(roundId: String, keepCount: UInt32) throws -> UInt64 {
        let deleted = try withRoundId(roundId) { dbh, id, idLen in
            zcashlc_voting_delete_skipped_bundles(dbh, id, idLen, keepCount)
        }

        guard deleted >= 0 else {
            throw Self.votingError(fallback: "`voting_delete_skipped_bundles` failed")
        }
        return UInt64(deleted)
    }

    /// Forget a bundle's combined-cast rejection streak, answering whether
    /// there was one to forget.
    public func retryBlockedCombinedCast(roundId: String, bundleIndex: UInt32) throws -> Bool {
        let cleared = try withRoundId(roundId) { dbh, id, idLen in
            zcashlc_voting_retry_blocked_combined_cast(dbh, id, idLen, bundleIndex)
        }

        guard cleared >= 0 else {
            throw Self.votingError(fallback: "`voting_retry_blocked_combined_cast` failed")
        }
        return cleared == 1
    }

    /// Clear the stored ballot intents of the named proposals.
    ///
    /// The crate has no batch form, so the ids are cleared one at a time: a
    /// proposal whose vote the chain lifecycle already owns fails the call with
    /// the proposals before it already cleared. Re-running is safe — clearing
    /// an intent that is not there is not an error — so the remedy is to drop
    /// the offending id and call again.
    public func clearBallotIntents(roundId: String, proposalIds: [UInt32]) throws {
        let ids = try Self.encodeJSON(proposalIds, describing: "proposal ids")
        try withRoundId(roundId, bytes: ids) { dbh, id, idLen, proposals, proposalsLen in
            let status = zcashlc_voting_clear_ballot_intents(dbh, id, idLen, proposals, proposalsLen)
            guard status == 0 else {
                throw Self.votingError(fallback: "`voting_clear_ballot_intents` failed")
            }
        }
    }

    /// The Keystone signatures stored for a round.
    public func keystoneSignatures(roundId: String) throws -> [VotingKeystoneSignatureRecord] {
        try withRoundId(roundId) { dbh, id, idLen in
            try Self.decodingJSON(fallback: "`voting_get_keystone_signatures` failed") {
                zcashlc_voting_get_keystone_signatures(dbh, id, idLen)
            }
        }
    }

    // MARK: - Sessions

    /// Open a session for one round over this backend's sidecar.
    ///
    /// `torRuntime` selects the route the session's chain and helper traffic
    /// takes for its whole life: `nil` is the direct HTTP route, and a runtime
    /// is used through an isolated client taken during this call, so the
    /// round's circuits are not linkable to the rest of the wallet's Tor use. A
    /// session opened on Tor never falls back to a direct connection. PIR and
    /// vote-tree traffic take the shared direct transport either way, because a
    /// PIR query names no voter and its volume does not belong on Tor.
    ///
    /// The runtime is borrowed for this call only; the caller keeps ownership
    /// of it. Nothing here reaches the network: every failure is a decision
    /// about the arguments, and the wallet id must already be set.
    func makeSession(
        inputs: VotingSessionInputs,
        binding: VotingSessionBinding,
        torRuntime: OpaquePointer?,
        epoch: UInt64
    ) throws -> VotingRoundSession {
        let inputsJSON = try Self.encodeJSON(inputs, describing: "session inputs")
        let bindingJSON = try Self.encodeJSON(binding, describing: "session binding")

        let session = try withHandle { dbh -> OpaquePointer in
            let ptr = inputsJSON.withUnsafeBufferPointer { inputsBuffer in
                bindingJSON.withUnsafeBufferPointer { bindingBuffer in
                    zcashlc_voting_session_open(
                        dbh,
                        inputsBuffer.baseAddress,
                        UInt(inputsBuffer.count),
                        bindingBuffer.baseAddress,
                        UInt(bindingBuffer.count),
                        torRuntime,
                        epoch
                    )
                }
            }

            guard let ptr else {
                throw Self.votingError(fallback: "`voting_session_open` failed")
            }
            return ptr
        }

        return VotingRoundSession(handle: session, roundId: inputs.roundParams.voteRoundId)
    }
}

// MARK: - Interactive proving QoS boost

extension VotingRustBackend {
    /// Raises every proving-pool worker from its resting utility QoS to
    /// user-initiated for the duration of an interactive proving session.
    /// Refcounted in the FFI; every begin must be paired with an end.
    static func beginInteractiveProvingBoost() {
        zcashlc_proving_interactive_begin()
    }

    static func endInteractiveProvingBoost() {
        zcashlc_proving_interactive_end()
    }

    /// Outstanding interactive proving sessions (diagnostics and tests).
    static func interactiveProvingBoostCount() -> Int32 {
        zcashlc_proving_interactive_active()
    }

    /// Runs `body` under the pool-wide interactive proving boost, releasing it
    /// on every exit path. The FFI end is refcounted and saturating, but a
    /// missing end pins the pool at user-initiated for the process lifetime —
    /// route every boost through this helper instead of pairing the raw
    /// begin/end statics by hand.
    static func withInteractiveProvingBoost<T>(
        _ body: () async throws -> T
    ) async rethrows -> T {
        beginInteractiveProvingBoost()
        defer { endInteractiveProvingBoost() }
        return try await body()
    }
}

// MARK: - Proving pool (static)

extension VotingRustBackend {
    /// Fix the process-wide proving policy, answering whether this call is the
    /// one that configured it.
    ///
    /// The pool is configured once per process. A repeat that asks for the
    /// policy already in force is accepted as a fresh configure and answers
    /// `true`; only a policy that disagrees with the one in force answers
    /// `false`, leaving the running pool as it is. A host that cares which
    /// policy is live must therefore treat `false` as "mine was not applied"
    /// rather than as a harmless repeat.
    ///
    /// First *use* fixes the pool too: ``warmProvingCaches()`` and the first
    /// proof both start it on the crate's default policy, which sizes the heavy
    /// job limit to the device's parallelism rather than to one. Call this
    /// before either, or the policy that ends up live is the default rather
    /// than the one asked for here.
    public static func configureProving(_ policy: VotingProvingPolicy) throws -> Bool {
        let json = try encodeJSON(policy, describing: "proving policy")
        let result = json.withUnsafeBufferPointer { buffer in
            zcashlc_voting_configure(buffer.baseAddress, UInt(buffer.count))
        }

        switch result {
        case 0:
            return true
        case 1:
            return false
        default:
            throw votingError(fallback: "`voting_configure` failed")
        }
    }

    /// Warm process-lifetime proving-key caches used by voting proofs.
    ///
    /// Returns at once and warms in the background; a no-op after the first
    /// call in this process. Call it when entering a flow that will prove
    /// interactively so the first proving call does not pay the multi-second
    /// keygen — after ``configureProving(_:)``, because warming starts the pool
    /// and so fixes the policy if nothing has yet. It runs at the pool's resting priority: warm-up is background
    /// work, and if the voter submits before it finishes, that call's own boost
    /// covers the keygen remainder.
    public static func warmProvingCaches() throws {
        guard zcashlc_voting_warm_proving_caches() == 0 else {
            throw votingError(fallback: "`warm_proving_caches` failed")
        }
    }
}

// MARK: - Foundation helpers (static)

extension VotingRustBackend {
    /// Whether `roundId` is a well-formed voting round id: 64 lowercase hex
    /// characters encoding a canonical Pallas base-field element.
    ///
    /// Takes no database, so a host can check an id before it has a handle.
    public static func validateRoundId(_ roundId: String) -> Bool {
        let bytes = [UInt8](roundId.utf8)
        let valid = bytes.withUnsafeBufferPointer { buffer in
            zcashlc_voting_validate_round_id(buffer.baseAddress, UInt(buffer.count))
        }

        if !valid {
            // A rejection also leaves its reason in the FFI's last-error slot.
            // Nothing here reports it, so it is cleared rather than left to
            // surface as the explanation of some later failure.
            _ = lastErrorMessage(fallback: "")
        }
        return valid
    }

    /// Extract the 96-byte Orchard FVK from a UFVK string.
    public static func extractOrchardFvk(ufvk: String, networkId: UInt32) throws -> [UInt8] {
        let bytes = [UInt8](ufvk.utf8)
        return try readingBytes(fallback: "`extract_orchard_fvk_from_ufvk` failed") {
            bytes.withUnsafeBufferPointer { buf in
                zcashlc_voting_extract_orchard_fvk_from_ufvk(buf.baseAddress, UInt(buf.count), networkId)
            }
        }
    }

    /// Extract the 32-byte Ironwood note-commitment-tree root from a
    /// protobuf-encoded `TreeState`.
    ///
    /// Voting rounds anchor to the Ironwood pool, so a round's `nc_root` is the
    /// Ironwood tree's root at the snapshot height — not the Orchard tree's.
    public static func extractNcRoot(treeState: [UInt8]) throws -> [UInt8] {
        try readingBytes(fallback: "`extract_nc_root` failed") {
            treeState.withUnsafeBufferPointer { buf in
                zcashlc_voting_extract_nc_root(buf.baseAddress, UInt(buf.count))
            }
        }
    }
}

// MARK: - Hotkeys

extension VotingRustBackend {
    /// Generate a new voting hotkey for `networkId`.
    ///
    /// - Important: The application **must persist** the returned
    /// ``VotingHotkey/storedSecret``. A voting hotkey is an app-owned random
    /// value rather than a wallet-seed derivation, so it cannot be re-derived:
    /// restoring the wallet from its seed phrase does **not** restore the
    /// ability to vote with a hotkey whose secret was lost, and any voting power
    /// already delegated to that hotkey becomes unusable. The SDK does not store
    /// it on the application's behalf.
    ///
    /// Generate a hotkey once and reuse the stored secret; calling this again
    /// produces an unrelated hotkey rather than recovering the previous one.
    ///
    /// The secret is owned by Swift after this call. The Rust allocation is
    /// zeroized and freed before this method returns; treat the returned bytes
    /// with the same care as any other key material.
    public static func generateHotkey(networkId: UInt32) throws -> VotingHotkey {
        guard let ptr = zcashlc_voting_generate_hotkey(networkId) else {
            throw votingError(fallback: "`generate_hotkey` failed")
        }
        defer { zcashlc_voting_free_hotkey(ptr) }
        return votingHotkey(from: ptr)
    }

    /// The hotkey a stored secret describes, for `networkId`.
    ///
    /// The address and address index are derived from the secret, so an
    /// application that persisted only ``VotingHotkey/storedSecret`` can hand
    /// the SDK the full semantic hotkey again instead of bare key bytes.
    public static func hotkey(fromStoredSecret storedSecret: [UInt8], networkId: UInt32) throws -> VotingHotkey {
        let ptr = storedSecret.withUnsafeBufferPointer { buffer in
            zcashlc_voting_hotkey_from_stored_secret(buffer.baseAddress, UInt(buffer.count), networkId)
        }
        guard let ptr else {
            throw votingError(fallback: "`hotkey_from_stored_secret` failed")
        }
        defer { zcashlc_voting_free_hotkey(ptr) }
        return votingHotkey(from: ptr)
    }

    /// Copies an `FfiVotingHotkey` into Swift-owned memory. The caller frees
    /// the Rust allocation.
    private static func votingHotkey(from ptr: UnsafeMutablePointer<FfiVotingHotkey>) -> VotingHotkey {
        let raw = ptr.pointee
        return VotingHotkey(
            storedSecret: bytesFromRawPointer(raw.stored_secret, count: Int(raw.stored_secret_len)),
            rawOrchardAddress: bytesFromRawPointer(
                raw.raw_orchard_address,
                count: Int(raw.raw_orchard_address_len)
            ),
            addressIndex: raw.address_index
        )
    }
}

// MARK: - FFI call helpers

/// Shared by ``VotingRoundSession``, which makes the same three kinds of call
/// against a session handle.
///
/// Each helper reads the last-error slot in the same synchronous scope as the
/// failing call, because the FFI records errors per thread: a message read
/// after a thread hop is another thread's slot, which is empty.
extension VotingRustBackend {
    /// The typed error the FFI left behind, or `fallback` as a plain
    /// ``VotingErrorKind/other`` when it left nothing decodable.
    static func votingError(fallback: String) -> VotingError {
        VotingError.fromLastErrorMessage(lastErrorMessage(fallback: fallback))
    }

    /// Calls an FFI that answers with JSON in a boxed slice, decoding it and
    /// freeing the slice. A null answer is the error signal.
    ///
    /// A payload that does not decode is this SDK disagreeing with the crate
    /// about a shape, which is reported as ``VotingErrorKind/internal`` rather
    /// than as a bare `DecodingError`: the whole voting surface then throws
    /// either a ``VotingError`` or a ``VotingRustBackendError``, and a host has
    /// two things to catch instead of three.
    static func decodingJSON<T: Decodable>(
        fallback: String,
        _ call: () -> UnsafeMutablePointer<FfiBoxedSlice>?
    ) throws -> T {
        guard let ptr = call() else {
            throw votingError(fallback: fallback)
        }
        defer { zcashlc_free_boxed_slice(ptr) }

        let data = boxedSliceData(ptr)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw VotingError(
                kind: .internal,
                message: "the voting FFI answered with something that is not a \(T.self) (\(fallback)): \(error)"
            )
        }
    }

    /// Calls an FFI that answers with raw bytes in a boxed slice, copying them
    /// into Swift-owned memory and freeing the slice.
    static func readingBytes(
        fallback: String,
        _ call: () -> UnsafeMutablePointer<FfiBoxedSlice>?
    ) throws -> [UInt8] {
        guard let ptr = call() else {
            throw votingError(fallback: fallback)
        }
        defer { zcashlc_free_boxed_slice(ptr) }
        return [UInt8](boxedSliceData(ptr))
    }

    /// The bytes a boxed slice carries.
    ///
    /// The FFI is allowed to answer with a null pointer when the length is
    /// zero, and `Data(bytes:count:)` will not take one, so that case is read
    /// as what it means: no bytes. An empty answer where JSON was expected then
    /// surfaces as the typed decode failure rather than as a trap.
    static func boxedSliceData(_ ptr: UnsafeMutablePointer<FfiBoxedSlice>) -> Data {
        guard let bytes = ptr.pointee.ptr, ptr.pointee.len > 0 else { return Data() }
        return Data(bytes: bytes, count: Int(ptr.pointee.len))
    }

    /// Encodes one FFI argument as JSON.
    ///
    /// The wire types encode without failing, so a throw here is a programming
    /// error rather than something a voter can cause — it is reported as
    /// invalid input all the same, because that is what the crate would say
    /// about the bytes that did cross.
    static func encodeJSON<T: Encodable>(_ value: T, describing what: String) throws -> [UInt8] {
        do {
            return [UInt8](try JSONEncoder().encode(value))
        } catch {
            throw VotingError(kind: .invalidInput, message: "\(what) could not be encoded: \(error)")
        }
    }
}

// MARK: - Private helpers

private extension VotingRustBackend {
    /// Runs a database-bound operation while holding the handle lock. Keeping
    /// the lock through the FFI call prevents `close()` from freeing the handle
    /// before Rust is done using it.
    func withHandle<T>(_ operation: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let dbh = handle else {
            throw VotingRustBackendError.databaseNotOpen
        }
        return try operation(dbh)
    }

    /// ``withHandle(_:)`` with `roundId`'s UTF-8 bytes in scope.
    func withRoundId<T>(
        _ roundId: String,
        _ operation: (OpaquePointer, UnsafePointer<UInt8>?, UInt) throws -> T
    ) throws -> T {
        let bytes = [UInt8](roundId.utf8)
        return try withHandle { dbh in
            try bytes.withUnsafeBufferPointer { buffer in
                try operation(dbh, buffer.baseAddress, UInt(buffer.count))
            }
        }
    }

    /// ``withRoundId(_:_:)`` for the calls that also take a byte argument.
    func withRoundId<T>(
        _ roundId: String,
        bytes: [UInt8],
        _ operation: (OpaquePointer, UnsafePointer<UInt8>?, UInt, UnsafePointer<UInt8>?, UInt) throws -> T
    ) throws -> T {
        try withRoundId(roundId) { dbh, id, idLen in
            try bytes.withUnsafeBufferPointer { buffer in
                try operation(dbh, id, idLen, buffer.baseAddress, UInt(buffer.count))
            }
        }
    }

    /// Runs `body` on a detached task registered as in flight, without holding
    /// the lock while it runs.
    ///
    /// The handle is read and the task registered under one lock hold, so a
    /// call either registers before ``close()`` looks at the list or is refused
    /// as closed: there is no window where a call starts against a handle that
    /// is about to be freed.
    func detached<T: Sendable>(_ body: @escaping @Sendable (OpaquePointer) throws -> T) async throws -> T {
        let box = VotingResultBox<T>()
        let ticket = UUID()
        let task = try startDetached(ticket: ticket) { dbh in
            box.complete(Result<T, Error> { try body(dbh) })
        }

        await task.value
        finishDetached(ticket: ticket)

        return try box.take()
    }

    /// Synchronous, because that is what taking a lock around a few field reads
    /// should be: an `async` function may not hold an `NSLock` across a suspension.
    func startDetached(
        ticket: UUID,
        _ body: @escaping @Sendable (OpaquePointer) -> Void
    ) throws -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }

        guard let dbh = handle else {
            throw VotingRustBackendError.databaseNotOpen
        }

        let task = Task.detached(priority: .userInitiated) {
            body(dbh)
        }
        inFlight[ticket] = task
        return task
    }

    /// Retires one finished call, freeing the handle a ``close()`` left behind
    /// once it was the last one using it.
    func finishDetached(ticket: UUID) {
        lock.lock()
        defer { lock.unlock() }

        inFlight[ticket] = nil
        if inFlight.isEmpty, let dbh = handleAwaitingFree {
            zcashlc_voting_db_free(dbh)
            handleAwaitingFree = nil
        }
    }

    /// Refuses the empty round id the FFI reads as "every round of this
    /// wallet".
    func requireNamedRound(_ roundId: String, calling method: String) throws {
        guard roundId.isEmpty else { return }

        throw VotingError(
            kind: .invalidInput,
            message: "\(method) needs a round id; the empty id is the crate's wallet-wide reset"
        )
    }
}

/// Copy `count` bytes starting at `pointer` into a Swift `[UInt8]`.
/// Returns an empty array if either argument is degenerate.
private func bytesFromRawPointer(_ pointer: UnsafeMutablePointer<UInt8>?, count: Int) -> [UInt8] {
    guard let pointer, count > 0 else { return [] }
    return [UInt8](UnsafeBufferPointer(start: pointer, count: count))
}
