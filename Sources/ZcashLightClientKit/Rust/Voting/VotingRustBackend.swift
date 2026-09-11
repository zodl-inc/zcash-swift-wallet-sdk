//
//  VotingRustBackend.swift
//  ZcashLightClientKit
//

import Foundation
import libzcashlc

// MARK: - Error

/// Error type for voting Rust backend operations.
public enum VotingRustBackendError: LocalizedError, Equatable {
    /// The voting database is already open.
    case databaseAlreadyOpen
    /// The voting database is not open.
    case databaseNotOpen
    /// A Rust error occurred.
    case rustError(String)
    /// Invalid data was received.
    case invalidData(String)

    public var errorDescription: String? {
        switch self {
        case .databaseAlreadyOpen:
            return "Voting database is already open."
        case .databaseNotOpen:
            return "Voting database is not open."
        case .rustError(let message):
            return "Voting backend error: \(message)"
        case .invalidData(let message):
            return "Invalid data: \(message)"
        }
    }
}

// MARK: - VotingRustBackend

/// Wraps the voting `libzcashlc` C FFI surface.
///
/// Manages an opaque `VotingDatabaseHandle` pointer for the database-bound
/// methods. Stateless / static FFI (e.g. `generateHotkey(networkId:)`) is
/// exposed as type methods so callers do not need to open a database.
///
/// Thread safety: handle access is serialized by an `NSLock`. Database-bound
/// FFI calls hold the lock for their full duration so `close()` cannot free the
/// handle while Rust is using it.
public final class VotingRustBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?

    public init() {}

    deinit {
        if let handle {
            zcashlc_voting_db_free(handle)
        }
    }

    // MARK: - Database lifecycle

    /// Open the voting database at `path` for `networkId`.
    ///
    /// The network is fixed for the lifetime of the handle: every
    /// database-bound call takes its voting identity from `networkId` rather
    /// than accepting one of its own, so no later call can disagree with the
    /// network the database was opened for. A custom (regtest) network takes
    /// its voting identity from the registered base network, and opening fails
    /// if that network has not been configured yet.
    ///
    /// Throws `VotingRustBackendError.databaseAlreadyOpen` if the backend
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
            throw VotingRustBackendError.rustError(
                Self.staticLastErrorMessage(fallback: "`voting_db_open` failed")
            )
        }
        handle = ptr
    }

    /// Close the voting database, freeing the underlying handle.
    ///
    /// Idempotent: calling `close()` on an already-closed backend is a no-op.
    public func close() {
        lock.lock()
        defer { lock.unlock() }

        if let dbh = handle {
            zcashlc_voting_db_free(dbh)
            handle = nil
        }
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

// MARK: - Foundation helpers (static)

extension VotingRustBackend {
    /// Warm process-lifetime proving-key caches used by voting proofs.
    ///
    /// Safe to call multiple times; subsequent calls are cheap. Call when
    /// entering a flow that will prove interactively (off the main actor) so
    /// the first proving call does not pay the multi-second keygen. Runs at
    /// the pool's resting priority: warm-up is background work, and if a user
    /// submits before it finishes, the proving call's own boost covers the
    /// keygen remainder.
    public static func warmProvingCaches() throws {
        let result = zcashlc_voting_warm_proving_caches()
        guard result == 0 else {
            throw VotingRustBackendError.rustError(
                staticLastErrorMessage(fallback: "`warm_proving_caches` failed")
            )
        }
    }

    /// Extract the 96-byte Orchard FVK from a UFVK string.
    public static func extractOrchardFvk(ufvk: String, networkId: UInt32) throws -> [UInt8] {
        let bytes = [UInt8](ufvk.utf8)
        return try staticBoxedSliceFFI(fallback: "`extract_orchard_fvk_from_ufvk` failed") {
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
        try staticBoxedSliceFFI(fallback: "`extract_nc_root` failed") {
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
            throw VotingRustBackendError.rustError(
                staticLastErrorMessage(fallback: "`generate_hotkey` failed")
            )
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
            throw VotingRustBackendError.rustError(
                staticLastErrorMessage(fallback: "`hotkey_from_stored_secret` failed")
            )
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

    func lastErrorMessage(fallback: String) -> String {
        Self.staticLastErrorMessage(fallback: fallback)
    }

    func decodeJSON<T: Decodable>(from ptr: UnsafeMutablePointer<FfiBoxedSlice>) throws -> T {
        let data = Data(bytes: ptr.pointee.ptr, count: Int(ptr.pointee.len))
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Reads the last error recorded by `libzcashlc` and clears it as a side
    /// effect, so subsequent failures do not surface a stale message.
    static func staticLastErrorMessage(fallback: String) -> String {
        let errorLen = zcashlc_last_error_length()
        defer { zcashlc_clear_last_error() }

        if errorLen > 0 {
            let error = UnsafeMutablePointer<Int8>.allocate(capacity: Int(errorLen))
            defer { error.deallocate() }
            zcashlc_error_message_utf8(error, errorLen)
            if let message = String(validatingUTF8: error) {
                return message
            }
        }

        return fallback
    }

    /// Decode JSON returned by static FFI calls.
    static func staticDecodeJSON<T: Decodable>(from ptr: UnsafeMutablePointer<FfiBoxedSlice>) throws -> T {
        let data = Data(bytes: ptr.pointee.ptr, count: Int(ptr.pointee.len))
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Calls a static FFI returning `*FfiBoxedSlice` and copies the resulting
    /// bytes into a Swift `[UInt8]`, freeing the slice in `defer`.
    static func staticBoxedSliceFFI(
        fallback: String,
        _ call: () -> UnsafeMutablePointer<FfiBoxedSlice>?
    ) throws -> [UInt8] {
        guard let ptr = call() else {
            throw VotingRustBackendError.rustError(staticLastErrorMessage(fallback: fallback))
        }
        defer { zcashlc_free_boxed_slice(ptr) }
        return [UInt8](Data(bytes: ptr.pointee.ptr, count: Int(ptr.pointee.len)))
    }
}

/// Copy `count` bytes starting at `pointer` into a Swift `[UInt8]`.
/// Returns an empty array if either argument is degenerate.
private func bytesFromRawPointer(_ pointer: UnsafeMutablePointer<UInt8>?, count: Int) -> [UInt8] {
    guard let pointer, count > 0 else { return [] }
    return [UInt8](UnsafeBufferPointer(start: pointer, count: count))
}
