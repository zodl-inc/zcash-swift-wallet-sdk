//! C entry points over the sidecar voting store.
//!
//! One shape throughout: string arguments arrive as `(ptr, len)` UTF-8 pairs,
//! JSON results come back as a `*mut crate::ffi::BoxedSlice` the caller frees
//! with [`zcashlc_free_boxed_slice`](crate::ffi::zcashlc_free_boxed_slice),
//! and failure is null (pointer returns) or `-1` (integer returns) with
//! `VotingErrorView` JSON in the last-error slot. Swift branches on the typed
//! `kind` in that JSON, never on message text.
//!
//! Every entry point is a thin translation of [`super::store`]: pointer and
//! JSON decoding, one call, one encode. Nothing here decides anything.

use std::panic::AssertUnwindSafe;

use ffi_helpers::panic::catch_panic;

use crate::{unwrap_exc_or, unwrap_exc_or_null};

use super::errors::{VotingResultExt, internal, invalid_input};
use super::helpers::{bytes_from_ptr, json_to_boxed_slice, str_from_ptr};
use super::store::{self, VotingDatabaseHandle};

/// Borrow the handle behind a raw pointer, or fail with typed JSON.
///
/// Shared with [`super::session_ffi`], which opens sessions over the same
/// handle and must refuse a null one the same way.
///
/// # Safety
///
/// If non-null, `db` must point to a live `VotingDatabaseHandle` returned by
/// [`zcashlc_voting_db_open`] and not yet freed. The returned reference must
/// not outlive it.
pub(super) unsafe fn handle_from_ptr<'a>(
    db: *mut VotingDatabaseHandle,
) -> anyhow::Result<&'a VotingDatabaseHandle> {
    unsafe { db.as_ref() }.ok_or_else(|| invalid_input("VotingDatabaseHandle is null"))
}

/// Decode a JSON array of proposal ids.
///
/// # Safety
///
/// Same contract as [`bytes_from_ptr`].
unsafe fn proposal_ids_from_json(ptr: *const u8, len: usize) -> anyhow::Result<Vec<u32>> {
    let bytes = unsafe { bytes_from_ptr(ptr, len) }?;
    serde_json::from_slice(bytes).map_err(|e| invalid_input(format!("proposal ids JSON: {e}")))
}

/// Open the voting sidecar database at `path` for `network_id`.
///
/// An existing schema-13 database is migrated in place. Returns an opaque
/// handle, or null on error.
///
/// # Safety
///
/// - For the `(path, path_len)` byte argument: if `path_len > 0` then `path`
///   must be non-null and valid for reads for `path_len` bytes; if
///   `path_len == 0`, `path` is ignored.
/// - Call [`zcashlc_voting_db_free`] to free the returned handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_db_open(
    path: *const u8,
    path_len: usize,
    network_id: u32,
) -> *mut VotingDatabaseHandle {
    let res = catch_panic(|| {
        let path = unsafe { str_from_ptr(path, path_len) }?;
        Ok(Box::into_raw(Box::new(VotingDatabaseHandle::open(
            &path, network_id,
        )?)))
    });
    unwrap_exc_or_null(res)
}

/// Free a `VotingDatabaseHandle`.
///
/// # Safety
///
/// - If `ptr` is non-null, it must be a pointer previously returned by
///   [`zcashlc_voting_db_open`] that has not already been freed.
/// - Calling this twice on the same non-null pointer, or on any pointer not
///   obtained from [`zcashlc_voting_db_open`], is undefined behavior.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_db_free(ptr: *mut VotingDatabaseHandle) {
    if !ptr.is_null() {
        let handle: Box<VotingDatabaseHandle> = unsafe { Box::from_raw(ptr) };
        drop(handle);
    }
}

/// Bind the handle to a wallet identifier, scoping every later operation.
///
/// Must be called after [`zcashlc_voting_db_open`] and before any round
/// operation. Returns 0 on success, -1 on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - For the `(wallet_id, wallet_id_len)` byte argument: if
///   `wallet_id_len > 0` then `wallet_id` must be non-null and valid for reads
///   for `wallet_id_len` bytes; if `wallet_id_len == 0`, `wallet_id` is
///   ignored (and the empty id is refused).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_set_wallet_id(
    db: *mut VotingDatabaseHandle,
    wallet_id: *const u8,
    wallet_id_len: usize,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle = unsafe { handle_from_ptr(*db) }?;
        let wallet_id = unsafe { str_from_ptr(wallet_id, wallet_id_len) }?;
        handle.set_wallet_id(&wallet_id)?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// Every round of the bound wallet, as a JSON array of round summaries.
///
/// Returns null on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - Call [`zcashlc_free_boxed_slice`](crate::ffi::zcashlc_free_boxed_slice)
///   to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_list_rounds(
    db: *mut VotingDatabaseHandle,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle = unsafe { handle_from_ptr(*db) }?;
        json_to_boxed_slice(&store::list_rounds(handle)?)
    });
    unwrap_exc_or_null(res)
}

/// The plan for one round against an authenticated proposal roster, as
/// `RoundPlanView` JSON.
///
/// `proposal_ids_json` is a JSON array of proposal ids — the roster the host
/// authenticated. Returns null on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - Each `(ptr, len)` byte argument follows the [`bytes_from_ptr`] contract.
/// - Call [`zcashlc_free_boxed_slice`](crate::ffi::zcashlc_free_boxed_slice)
///   to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_round_plan(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    proposal_ids_json: *const u8,
    proposal_ids_json_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle = unsafe { handle_from_ptr(*db) }?;
        let round_id = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let proposal_ids =
            unsafe { proposal_ids_from_json(proposal_ids_json, proposal_ids_json_len) }?;
        json_to_boxed_slice(&store::round_plan(handle, &round_id, &proposal_ids)?)
    });
    unwrap_exc_or_null(res)
}

/// Rounds of the bound wallet with helper-share work still outstanding, as a
/// JSON array of `PendingShareRoundView`.
///
/// Returns null on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - Call [`zcashlc_free_boxed_slice`](crate::ffi::zcashlc_free_boxed_slice)
///   to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_pending_share_rounds(
    db: *mut VotingDatabaseHandle,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle = unsafe { handle_from_ptr(*db) }?;
        json_to_boxed_slice(&store::pending_share_rounds(handle)?)
    });
    unwrap_exc_or_null(res)
}

/// Sync a round's vote-commitment tree from `node_url`.
///
/// Blocks for the duration of the sync. Returns the height synced to, or -1 on
/// error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - Each `(ptr, len)` byte argument follows the [`bytes_from_ptr`] contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_sync_vote_tree(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    node_url: *const u8,
    node_url_len: usize,
) -> i64 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle = unsafe { handle_from_ptr(*db) }?;
        let round_id = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let node_url = unsafe { str_from_ptr(node_url, node_url_len) }?;
        Ok(i64::from(store::sync_vote_tree(
            handle, &round_id, &node_url,
        )?))
    });
    unwrap_exc_or(res, -1)
}

/// Drop the cached vote-tree state for one round.
///
/// A zero-length `round_id` means the crate's wallet-wide reset, which forgets
/// every round's cached tree state for the bound wallet. Returns 0 on success,
/// -1 on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - The `(round_id, round_id_len)` byte argument follows the
///   [`bytes_from_ptr`] contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_reset_vote_tree(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle = unsafe { handle_from_ptr(*db) }?;
        let round_id = unsafe { str_from_ptr(round_id, round_id_len) }?;
        store::reset_vote_tree(handle, &round_id)?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// Return a round to a re-runnable state after an interrupted setup.
///
/// Drops cached tree state and clears locally prepared *unsigned* delegation
/// setup fields; proved or submitted bundles, imported capabilities and stored
/// signatures survive. A zero-length `round_id` resets only the cached tree
/// state, wallet-wide, and clears no persisted column. Returns 0 on success,
/// -1 on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - The `(round_id, round_id_len)` byte argument follows the
///   [`bytes_from_ptr`] contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_reset_session_state(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle = unsafe { handle_from_ptr(*db) }?;
        let round_id = unsafe { str_from_ptr(round_id, round_id_len) }?;
        store::reset_session_state(handle, &round_id)?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// Delete one round.
///
/// With `discard_recovery == false` the call refuses once part of the round
/// has reached the network. `true` abandons such a round on purpose, giving up
/// the state that could recover its voting weight. Returns 0 on success, -1 on
/// error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - The `(round_id, round_id_len)` byte argument follows the
///   [`bytes_from_ptr`] contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_delete_round(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    discard_recovery: bool,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle = unsafe { handle_from_ptr(*db) }?;
        let round_id = unsafe { str_from_ptr(round_id, round_id_len) }?;
        store::delete_round(handle, &round_id, discard_recovery)?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// Drop bundle rows at index `>= keep_count`.
///
/// Returns the number of deleted rows, or -1 on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - The `(round_id, round_id_len)` byte argument follows the
///   [`bytes_from_ptr`] contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_delete_skipped_bundles(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    keep_count: u32,
) -> i64 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle = unsafe { handle_from_ptr(*db) }?;
        let round_id = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let deleted = store::delete_skipped_bundles(handle, &round_id, keep_count)?;
        i64::try_from(deleted).map_err(|_| {
            internal(format!(
                "deleted bundle count {deleted} does not fit in i64"
            ))
        })
    });
    unwrap_exc_or(res, -1)
}

/// Forget a bundle's combined-cast rejection streak.
///
/// Returns 1 when a streak was cleared, 0 when there was nothing to retry, -1
/// on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - The `(round_id, round_id_len)` byte argument follows the
///   [`bytes_from_ptr`] contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_retry_blocked_combined_cast(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle = unsafe { handle_from_ptr(*db) }?;
        let round_id = unsafe { str_from_ptr(round_id, round_id_len) }?;
        Ok(i32::from(store::retry_blocked_combined_cast(
            handle,
            &round_id,
            bundle_index,
        )?))
    });
    unwrap_exc_or(res, -1)
}

/// Clear the stored ballot intents named by `proposal_ids_json`.
///
/// `proposal_ids_json` is a JSON array of proposal ids, cleared one at a time:
/// the crate has no batch form, so a proposal whose vote the chain lifecycle
/// already owns fails the call with the proposals before it already cleared.
/// Re-running is safe — clearing an intent that is not there is not an error —
/// so the remedy is to drop the offending id and call again. Returns 0 on
/// success, -1 on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - Each `(ptr, len)` byte argument follows the [`bytes_from_ptr`] contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_clear_ballot_intents(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    proposal_ids_json: *const u8,
    proposal_ids_json_len: usize,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle = unsafe { handle_from_ptr(*db) }?;
        let round_id = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let proposal_ids =
            unsafe { proposal_ids_from_json(proposal_ids_json, proposal_ids_json_len) }?;
        store::clear_ballot_intents(handle, &round_id, &proposal_ids)?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// The Keystone signatures stored for a round, as a JSON array.
///
/// Returns null on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - The `(round_id, round_id_len)` byte argument follows the
///   [`bytes_from_ptr`] contract.
/// - Call [`zcashlc_free_boxed_slice`](crate::ffi::zcashlc_free_boxed_slice)
///   to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_get_keystone_signatures(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle = unsafe { handle_from_ptr(*db) }?;
        let round_id = unsafe { str_from_ptr(round_id, round_id_len) }?;
        json_to_boxed_slice(&store::keystone_signatures(handle, &round_id)?)
    });
    unwrap_exc_or_null(res)
}

/// Whether `round_id` is a well-formed voting round id.
///
/// A valid id is 64 lowercase hex characters encoding a canonical Pallas
/// base-field element. Takes no database, so a host can check an id before it
/// has a handle. `false` also leaves the reason in the last-error slot.
///
/// # Safety
///
/// The `(round_id, round_id_len)` byte argument follows the [`bytes_from_ptr`]
/// contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_validate_round_id(
    round_id: *const u8,
    round_id_len: usize,
) -> bool {
    let res = catch_panic(|| {
        let round_id = unsafe { str_from_ptr(round_id, round_id_len) }?;
        zcash_voting::types::validate_vote_round_id_hex(&round_id).ffi()?;
        Ok(true)
    });
    unwrap_exc_or(res, false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voting::test_support::{
        boxed_slice_to_string, hex_round_id, last_error_string, open_memory_store_ptr,
    };

    /// Read a JSON result and free it, so no test leaks the boxed slice.
    ///
    /// # Safety
    ///
    /// `ptr` must be a non-null `BoxedSlice` returned by an entry point here.
    unsafe fn take_json(ptr: *mut crate::ffi::BoxedSlice) -> String {
        let json = unsafe { boxed_slice_to_string(ptr) };
        unsafe { crate::ffi::zcashlc_free_boxed_slice(ptr) };
        json
    }

    /// The kind of the `VotingErrorView` in the last-error slot.
    fn last_error_kind() -> serde_json::Value {
        let view: zcash_voting::VotingErrorView =
            serde_json::from_str(&last_error_string()).expect("json error");
        serde_json::to_value(view.kind).expect("kind")
    }

    #[test]
    fn db_open_rejects_invalid_utf8_path() {
        let invalid_path = [0xff];
        let handle =
            unsafe { zcashlc_voting_db_open(invalid_path.as_ptr(), invalid_path.len(), 1) };
        assert!(handle.is_null());
        // Decoding failures are typed JSON too, not a bare message: Swift
        // reads one envelope for every failure this boundary can produce.
        assert_eq!(last_error_kind(), "invalid_input");
    }

    #[test]
    fn db_open_rejects_invalid_network_id() {
        // The network is validated once, here, so no database-bound call has to
        // re-check it: the handle cannot exist for a network that does not.
        let path = b":memory:";
        let db = unsafe { zcashlc_voting_db_open(path.as_ptr(), path.len(), 99) };
        assert!(db.is_null(), "unknown network id must not open a handle");
    }

    #[test]
    fn db_free_accepts_null() {
        unsafe { zcashlc_voting_db_free(std::ptr::null_mut()) };
    }

    #[test]
    fn set_wallet_id_rejects_null_db() {
        let code = unsafe { zcashlc_voting_set_wallet_id(std::ptr::null_mut(), b"x".as_ptr(), 1) };
        assert_eq!(code, -1);
    }

    #[test]
    fn list_rounds_ffi_returns_json_array_and_null_db_sets_json_error() {
        let db = open_memory_store_ptr(crate::NETWORK_ID_MAINNET, "w");
        let ptr = unsafe { zcashlc_voting_list_rounds(db) };
        assert!(!ptr.is_null());
        let json = unsafe { take_json(ptr) };
        assert_eq!(json, "[]");
        unsafe { zcashlc_voting_db_free(db) };
        assert!(unsafe { zcashlc_voting_list_rounds(std::ptr::null_mut()) }.is_null());
        assert_eq!(last_error_kind(), "invalid_input");
    }

    #[test]
    fn set_wallet_id_refuses_the_empty_id() {
        let path = b":memory:";
        let db = unsafe { zcashlc_voting_db_open(path.as_ptr(), path.len(), 1) };
        assert!(!db.is_null());
        // An unset wallet id is what makes every scoped read fail, so the empty
        // id is refused where it is offered rather than at the first use.
        assert_eq!(
            unsafe { zcashlc_voting_set_wallet_id(db, std::ptr::null(), 0) },
            -1
        );
        assert_eq!(last_error_kind(), "invalid_input");
        assert!(unsafe { zcashlc_voting_list_rounds(db) }.is_null());
        assert_eq!(last_error_kind(), "invalid_input");
        assert_eq!(
            unsafe { zcashlc_voting_set_wallet_id(db, b"w".as_ptr(), 1) },
            0
        );
        let json = unsafe { take_json(zcashlc_voting_list_rounds(db)) };
        assert_eq!(json, "[]");
        unsafe { zcashlc_voting_db_free(db) };
    }

    #[test]
    fn round_plan_ffi_decodes_the_roster_json_and_refuses_malformed_json() {
        let db = open_memory_store_ptr(crate::NETWORK_ID_MAINNET, "w");
        let round_id = hex_round_id(0x21);
        let roster = b"[1,2]";
        let ptr = unsafe {
            zcashlc_voting_round_plan(
                db,
                round_id.as_ptr(),
                round_id.len(),
                roster.as_ptr(),
                roster.len(),
            )
        };
        assert!(!ptr.is_null());
        let plan: zcash_voting::wire::RoundPlanView =
            serde_json::from_str(&unsafe { take_json(ptr) }).expect("plan json");
        assert_eq!(plan.round_id, round_id);
        assert_eq!(plan.open_proposals, vec![1, 2]);

        let malformed = b"[1,";
        assert!(
            unsafe {
                zcashlc_voting_round_plan(
                    db,
                    round_id.as_ptr(),
                    round_id.len(),
                    malformed.as_ptr(),
                    malformed.len(),
                )
            }
            .is_null()
        );
        assert_eq!(last_error_kind(), "invalid_input");
        unsafe { zcashlc_voting_db_free(db) };
    }

    #[test]
    fn store_edits_round_trip_over_the_boundary() {
        let db = open_memory_store_ptr(crate::NETWORK_ID_MAINNET, "w");
        let round_id = hex_round_id(0x22);
        let params = crate::voting::test_support::synthetic_round_params(0x22, 4321);
        unsafe { &*db }
            .scoped()
            .unwrap()
            .ensure_round(zcash_voting::Network::Mainnet, &params, None)
            .unwrap();

        let (id, len) = (round_id.as_ptr(), round_id.len());
        let json = unsafe { take_json(zcashlc_voting_list_rounds(db)) };
        assert!(json.contains(&round_id), "{json}");
        let signatures = unsafe { take_json(zcashlc_voting_get_keystone_signatures(db, id, len)) };
        assert_eq!(signatures, "[]");
        assert_eq!(
            unsafe { zcashlc_voting_reset_session_state(db, id, len) },
            0
        );
        // Nothing of this round has reached the network, so the checked
        // deletion is the one that applies.
        assert_eq!(
            unsafe { zcashlc_voting_delete_round(db, id, len, false) },
            0
        );
        let json = unsafe { take_json(zcashlc_voting_list_rounds(db)) };
        assert_eq!(json, "[]");
        let pending = unsafe { take_json(zcashlc_voting_pending_share_rounds(db)) };
        assert_eq!(pending, "[]");
        unsafe { zcashlc_voting_db_free(db) };
    }

    #[test]
    fn integer_entry_points_report_a_null_db_as_minus_one() {
        let round_id = hex_round_id(0x23);
        let (id, len) = (round_id.as_ptr(), round_id.len());
        let null = std::ptr::null_mut();
        assert_eq!(unsafe { zcashlc_voting_reset_vote_tree(null, id, len) }, -1);
        assert_eq!(
            unsafe { zcashlc_voting_reset_session_state(null, id, len) },
            -1
        );
        assert_eq!(
            unsafe { zcashlc_voting_delete_round(null, id, len, true) },
            -1
        );
        assert_eq!(
            unsafe { zcashlc_voting_delete_skipped_bundles(null, id, len, 1) },
            -1
        );
        assert_eq!(
            unsafe { zcashlc_voting_retry_blocked_combined_cast(null, id, len, 0) },
            -1
        );
        assert_eq!(
            unsafe { zcashlc_voting_sync_vote_tree(null, id, len, b"u".as_ptr(), 1) },
            -1
        );
        assert_eq!(
            unsafe { zcashlc_voting_clear_ballot_intents(null, id, len, b"[1]".as_ptr(), 3) },
            -1
        );
        assert!(unsafe { zcashlc_voting_get_keystone_signatures(null, id, len) }.is_null());
        assert!(unsafe { zcashlc_voting_pending_share_rounds(null) }.is_null());
        assert_eq!(last_error_kind(), "invalid_input");
    }

    #[test]
    fn validate_round_id_accepts_a_canonical_id_and_rejects_the_rest() {
        // A tag with a hex letter in it, so the uppercase spelling below is a
        // genuinely different string.
        let valid = hex_round_id(0xab);
        assert!(unsafe { zcashlc_voting_validate_round_id(valid.as_ptr(), valid.len()) });
        let short = b"abcd";
        assert!(!unsafe { zcashlc_voting_validate_round_id(short.as_ptr(), short.len()) });
        assert_eq!(last_error_kind(), "invalid_input");
        // Uppercase is rejected: the crate's ids are lowercase hex, and a
        // case-insensitive check here would let a host store two spellings of
        // one round.
        let upper = valid.to_uppercase();
        assert!(!unsafe { zcashlc_voting_validate_round_id(upper.as_ptr(), upper.len()) });
    }

    /// The custom slot's voting identity must follow the registered base
    /// network: a modified-mainnet chain keeps mainnet hotkeys and HRPs. This
    /// is the only test that touches the process-global custom-network slot —
    /// keep it that way (parallel tests share the global).
    #[test]
    fn db_open_custom_network_derives_voting_network_from_base() {
        let mut path = std::env::temp_dir();
        path.push(format!(
            "zcashlc_voting_db_custom_network_{}.sqlite",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        let path_bytes = path.to_string_lossy().as_bytes().to_vec();

        // Before zcashlc_set_custom_network runs, the custom slot has no base
        // to derive the voting network from — opening must fail, not silently
        // fall back to Regtest.
        let unconfigured = unsafe {
            zcashlc_voting_db_open(
                path_bytes.as_ptr(),
                path_bytes.len(),
                crate::NETWORK_ID_REGTEST,
            )
        };
        assert!(
            unconfigured.is_null(),
            "custom slot must not open before the custom network is configured"
        );

        // Modified-mainnet: base identity mainnet, custom activation heights.
        assert!(crate::zcashlc_set_custom_network(
            1, 347_500, 419_200, 653_600, 903_000, 1_046_400, 1_687_104, 2_726_400, 3_146_400,
            3_364_600, 3_428_143,
        ));

        let db = unsafe {
            zcashlc_voting_db_open(
                path_bytes.as_ptr(),
                path_bytes.len(),
                crate::NETWORK_ID_REGTEST,
            )
        };
        assert!(!db.is_null(), "open voting db at {:?}", path);
        let network = unsafe { (*db).network };
        assert_eq!(
            network,
            zcash_voting::Network::Mainnet,
            "base-mainnet custom network must map to the mainnet voting identity"
        );
        unsafe { zcashlc_voting_db_free(db) };
        let _ = std::fs::remove_file(&path);
    }
}
