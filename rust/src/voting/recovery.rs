use std::panic::AssertUnwindSafe;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use zcash_voting as voting;

use crate::{unwrap_exc_or, unwrap_exc_or_null};

use super::constants::{KEYSTONE_SIGNATURE_LEN, PCZT_SIGHASH_LEN, RANDOMIZED_KEY_LEN};
use super::db::VotingDatabaseHandle;
use super::helpers::{bytes_from_ptr, json_to_boxed_slice, str_from_ptr};

#[derive(serde::Serialize)]
struct JsonKeystoneSignatureRecord {
    bundle_index: u32,
    sig: Vec<u8>,
    sighash: Vec<u8>,
    rk: Vec<u8>,
}

impl From<zcash_voting::storage::KeystoneSignatureRecord> for JsonKeystoneSignatureRecord {
    fn from(record: zcash_voting::storage::KeystoneSignatureRecord) -> Self {
        Self {
            bundle_index: record.bundle_index,
            sig: record.sig,
            sighash: record.sighash,
            rk: record.rk,
        }
    }
}

/// Persist the on-chain transaction hash of a submitted delegation bundle.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `round_id` and `tx_hash` must be valid UTF-8 pointers with their stated lengths.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_store_delegation_tx_hash(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    tx_hash: *const u8,
    tx_hash_len: usize,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let tx_hash_str = unsafe { str_from_ptr(tx_hash, tx_hash_len) }?;
        handle
            .db
            .store_delegation_tx_hash(&round_id_str, bundle_index, &tx_hash_str)
            .map_err(|e| anyhow!("store_delegation_tx_hash failed: {}", e))?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// Load a previously stored delegation transaction hash.
///
/// Returns a JSON-encoded `Option<String>`.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `round_id` must be a valid UTF-8 pointer with its stated length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_get_delegation_tx_hash(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let hash = handle
            .db
            .get_delegation_tx_hash(&round_id_str, bundle_index)
            .map_err(|e| anyhow!("get_delegation_tx_hash failed: {}", e))?;
        json_to_boxed_slice(&hash)
    });
    unwrap_exc_or_null(res)
}

/// Persist the on-chain transaction hash of a submitted vote.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `round_id` and `tx_hash` must be valid UTF-8 pointers with their stated lengths.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_store_vote_tx_hash(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    proposal_id: u32,
    tx_hash: *const u8,
    tx_hash_len: usize,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let tx_hash_str = unsafe { str_from_ptr(tx_hash, tx_hash_len) }?;
        voting::vote::record_submission(
            &handle.db,
            &round_id_str,
            bundle_index,
            proposal_id,
            &tx_hash_str,
        )
        .map_err(|e| anyhow!("record_submission failed: {}", e))?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// Load a previously stored vote transaction hash.
///
/// Returns a JSON-encoded `Option<String>`.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `round_id` must be a valid UTF-8 pointer with its stated length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_get_vote_tx_hash(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    proposal_id: u32,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let hash = handle
            .db
            .get_vote_tx_hash(&round_id_str, bundle_index, proposal_id)
            .map_err(|e| anyhow!("get_vote_tx_hash failed: {}", e))?;
        json_to_boxed_slice(&hash)
    });
    unwrap_exc_or_null(res)
}

/// Record the on-chain vote-commitment-tree position of a confirmed vote.
///
/// This replaces the former `zcashlc_voting_store_commitment_bundle`, which also
/// took the commitment bundle JSON. `zcash_voting` now owns that JSON: it is
/// written when the vote is committed, so the caller has nothing left to supply
/// beyond the confirmed tree position, and the `bundle_json` parameter pair is
/// gone.
///
/// Returns 0 on success, -1 on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `round_id` must be a valid UTF-8 pointer with its stated length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_record_vc_position(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    proposal_id: u32,
    vc_tree_position: u64,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        voting::vote::record_vc_position(
            &handle.db,
            &round_id_str,
            bundle_index,
            proposal_id,
            vc_tree_position,
        )
        .map_err(|e| anyhow!("record_vc_position failed: {}", e))?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// Load a stored commitment bundle and vote-commitment-tree position.
///
/// Returns a JSON-encoded `Option<(String, u64)>`.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `round_id` must be a valid UTF-8 pointer with its stated length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_get_commitment_bundle(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    proposal_id: u32,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let result = handle
            .db
            .get_commitment_bundle(&round_id_str, bundle_index, proposal_id)
            .map_err(|e| anyhow!("get_commitment_bundle failed: {}", e))?;
        json_to_boxed_slice(&result)
    });
    unwrap_exc_or_null(res)
}

/// Persist a Keystone-produced PCZT signature.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `round_id` must be a valid UTF-8 pointer with its stated length.
/// - `sig` must point to exactly 64 bytes.
/// - `sighash` and `rk` must each point to exactly 32 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_store_keystone_signature(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
    sig: *const u8,
    sig_len: usize,
    sighash: *const u8,
    sighash_len: usize,
    rk: *const u8,
    rk_len: usize,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        if sig_len != KEYSTONE_SIGNATURE_LEN {
            return Err(anyhow!(
                "sig must be {} bytes, got {}",
                KEYSTONE_SIGNATURE_LEN,
                sig_len
            ));
        }
        if sighash_len != PCZT_SIGHASH_LEN {
            return Err(anyhow!(
                "sighash must be {} bytes, got {}",
                PCZT_SIGHASH_LEN,
                sighash_len
            ));
        }
        if rk_len != RANDOMIZED_KEY_LEN {
            return Err(anyhow!(
                "rk must be {} bytes, got {}",
                RANDOMIZED_KEY_LEN,
                rk_len
            ));
        }
        let sig_bytes = unsafe { bytes_from_ptr(sig, sig_len) }?;
        let sighash_bytes = unsafe { bytes_from_ptr(sighash, sighash_len) }?;
        let rk_bytes = unsafe { bytes_from_ptr(rk, rk_len) }?;
        handle
            .db
            .store_keystone_signature(
                &round_id_str,
                bundle_index,
                sig_bytes,
                sighash_bytes,
                rk_bytes,
            )
            .map_err(|e| anyhow!("store_keystone_signature failed: {}", e))?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// Load all Keystone signatures stored for a round.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `round_id` must be a valid UTF-8 pointer with its stated length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_get_keystone_signatures(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let sigs = handle
            .db
            .get_keystone_signatures(&round_id_str)
            .map_err(|e| anyhow!("get_keystone_signatures failed: {}", e))?;

        let out: Vec<JsonKeystoneSignatureRecord> = sigs.into_iter().map(Into::into).collect();

        json_to_boxed_slice(&out)
    });
    unwrap_exc_or_null(res)
}

/// Deletes one bundle's persisted Keystone signature.
///
/// Deleting the signature makes the bundle eligible again for
/// `zcashlc_voting_reset_session_state`'s guarded cleanup, which otherwise
/// leaves bundles with a stored Keystone signature untouched. For wallets
/// discarding a signature that no longer matches the bundle's stored
/// delegation setup.
///
/// Returns 0 on success (including when no row exists to delete), -1 on
/// error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `round_id` must be a valid UTF-8 pointer with its stated length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_clear_keystone_signature(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
    bundle_index: u32,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        handle
            .db
            .conn()
            .execute(
                "DELETE FROM keystone_signatures WHERE round_id = :round_id AND wallet_id = :wallet_id AND bundle_index = :bundle_index",
                rusqlite::named_params! {
                    ":round_id": round_id_str,
                    ":wallet_id": handle.db.wallet_id(),
                    ":bundle_index": bundle_index as i64,
                },
            )
            .map_err(|e| anyhow!("clear_keystone_signature failed: {}", e))?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

/// Drops the round's cached vote tree and clears locally prepared unsigned
/// delegation setup fields so an interrupted Keystone signing request can be
/// rebuilt. Bundles that already have a Keystone signature, a stored
/// delegation tx hash, or a recorded VAN position are preserved.
///
/// Returns 0 on success, -1 on error.
///
/// A zero-length `round_id` is rejected with `-1`: the underlying cache reset
/// would otherwise silently act on every round on this handle. Per-round
/// semantics require a non-empty id; to drop every round's cached tree client
/// deliberately, use `zcashlc_voting_reset_tree_client`.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `round_id` must be a valid UTF-8 pointer with its stated length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_reset_session_state(
    db: *mut VotingDatabaseHandle,
    round_id: *const u8,
    round_id_len: usize,
) -> i32 {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let round_id_str = unsafe { str_from_ptr(round_id, round_id_len) }?;
        if round_id_str.is_empty() {
            return Err(anyhow!(
                "reset_session_state requires a non-empty round_id; use zcashlc_voting_reset_tree_client to drop every round's cached tree client"
            ));
        }
        handle
            .tree_sync
            .reset(&round_id_str)
            .map_err(|e| anyhow!("reset_session_state failed: {}", e))?;
        handle
            .db
            .clear_unsigned_delegation_setup_fields(&round_id_str)
            .map_err(|e| anyhow!("reset_session_state failed: {}", e))?;
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::zcashlc_free_boxed_slice;
    use crate::voting::db::zcashlc_voting_db_free;
    use crate::voting::delegation::{
        zcashlc_voting_get_bundle_count, zcashlc_voting_store_van_position,
    };
    use crate::voting::test_helpers::{
        TEST_ROUND_ID, call_get_sighash, insert_round_and_bundle, open_memory_db,
        plant_signing_request,
    };
    use serde::de::DeserializeOwned;

    fn decode_boxed_json<T: DeserializeOwned>(ptr: *mut crate::ffi::BoxedSlice) -> T {
        assert!(!ptr.is_null());
        let json = unsafe { (*ptr).as_slice() }.to_vec();
        let value = serde_json::from_slice(&json).expect("decode boxed JSON");
        unsafe { zcashlc_free_boxed_slice(ptr) };
        value
    }

    /// Creates the vote row that the recovery-state rows hang off.
    ///
    /// `zcash_voting` only writes vote rows as a side effect of `vote::commit`,
    /// which requires a full ZKP #2 proof, so tests seed the row through the
    /// public storage query layer instead.
    fn insert_vote(db: *mut VotingDatabaseHandle, round_id: &str) {
        let handle = unsafe { db.as_ref() }.expect("voting db handle");
        voting::storage::queries::store_vote(
            &handle.db.conn(),
            round_id,
            &handle.db.wallet_id(),
            0,
            0,
            0,
            &[0xaa; 32],
        )
        .expect("insert vote");
    }

    #[test]
    fn delegation_tx_hash_round_trips() {
        let db = open_memory_db();
        let round_id = b"round";
        insert_round_and_bundle(db, "round");
        let tx_hash = b"delegation-tx";

        let code = unsafe {
            zcashlc_voting_store_delegation_tx_hash(
                db,
                round_id.as_ptr(),
                round_id.len(),
                0,
                tx_hash.as_ptr(),
                tx_hash.len(),
            )
        };
        assert_eq!(code, 0);

        let result = unsafe {
            zcashlc_voting_get_delegation_tx_hash(db, round_id.as_ptr(), round_id.len(), 0)
        };
        let actual: Option<String> = decode_boxed_json(result);
        assert_eq!(actual.as_deref(), Some("delegation-tx"));

        unsafe { zcashlc_voting_db_free(db) };
    }

    #[test]
    fn store_delegation_tx_hash_rejects_missing_bundle() {
        let db = open_memory_db();
        let round_id = b"missing";
        let tx_hash = b"delegation-tx";

        let code = unsafe {
            zcashlc_voting_store_delegation_tx_hash(
                db,
                round_id.as_ptr(),
                round_id.len(),
                0,
                tx_hash.as_ptr(),
                tx_hash.len(),
            )
        };
        assert_eq!(code, -1);

        unsafe { zcashlc_voting_db_free(db) };
    }

    #[test]
    fn vote_tx_hash_round_trips() {
        let db = open_memory_db();
        let round_id = b"round";
        insert_round_and_bundle(db, "round");
        insert_vote(db, "round");
        let tx_hash = b"vote-tx";

        let code = unsafe {
            zcashlc_voting_store_vote_tx_hash(
                db,
                round_id.as_ptr(),
                round_id.len(),
                0,
                0,
                tx_hash.as_ptr(),
                tx_hash.len(),
            )
        };
        assert_eq!(code, 0);

        let result =
            unsafe { zcashlc_voting_get_vote_tx_hash(db, round_id.as_ptr(), round_id.len(), 0, 0) };
        let actual: Option<String> = decode_boxed_json(result);
        assert_eq!(actual.as_deref(), Some("vote-tx"));

        unsafe { zcashlc_voting_db_free(db) };
    }

    // The former `commitment_bundle_round_trips` test is gone: the caller can no
    // longer supply the commitment bundle JSON, so an FFI-level round trip is no
    // longer expressible. `zcash_voting` writes that JSON only from
    // `vote::commit`, which needs a real ZKP #2 proof, and
    // `zcashlc_voting_get_commitment_bundle` reports `None` until it is present.

    #[test]
    fn record_vc_position_accepts_existing_vote() {
        let db = open_memory_db();
        let round_id = b"round";
        insert_round_and_bundle(db, "round");
        insert_vote(db, "round");

        let code = unsafe {
            zcashlc_voting_record_vc_position(db, round_id.as_ptr(), round_id.len(), 0, 0, 42)
        };
        assert_eq!(code, 0);

        unsafe { zcashlc_voting_db_free(db) };
    }

    #[test]
    fn record_vc_position_rejects_missing_vote() {
        let db = open_memory_db();
        let round_id = b"round";
        insert_round_and_bundle(db, "round");

        let code = unsafe {
            zcashlc_voting_record_vc_position(db, round_id.as_ptr(), round_id.len(), 0, 0, 42)
        };
        assert_eq!(code, -1);

        unsafe { zcashlc_voting_db_free(db) };
    }

    #[test]
    fn store_keystone_signature_round_trips_valid_signature() {
        let db = open_memory_db();
        let round_id = b"round";
        insert_round_and_bundle(db, "round");
        let sig = [1u8; KEYSTONE_SIGNATURE_LEN];
        let sighash = [2u8; PCZT_SIGHASH_LEN];
        let rk = [3u8; RANDOMIZED_KEY_LEN];

        let code = unsafe {
            zcashlc_voting_store_keystone_signature(
                db,
                round_id.as_ptr(),
                round_id.len(),
                0,
                sig.as_ptr(),
                sig.len(),
                sighash.as_ptr(),
                sighash.len(),
                rk.as_ptr(),
                rk.len(),
            )
        };
        assert_eq!(code, 0);

        let result = unsafe {
            zcashlc_voting_get_keystone_signatures(db, round_id.as_ptr(), round_id.len())
        };
        assert!(!result.is_null());
        let json = unsafe { (*result).as_slice() }.to_vec();
        let actual: serde_json::Value =
            serde_json::from_slice(&json).expect("keystone signatures json");
        assert_eq!(
            actual,
            serde_json::json!([
                {
                    "bundle_index": 0,
                    "sig": sig.to_vec(),
                    "sighash": sighash.to_vec(),
                    "rk": rk.to_vec(),
                }
            ])
        );

        unsafe { zcashlc_free_boxed_slice(result) };
        unsafe { zcashlc_voting_db_free(db) };
    }

    #[test]
    fn store_keystone_signature_rejects_invalid_lengths() {
        let db = open_memory_db();
        let round_id = b"round";
        insert_round_and_bundle(db, "round");
        let sig = [1u8; KEYSTONE_SIGNATURE_LEN];
        let sighash = [2u8; PCZT_SIGHASH_LEN];
        let rk = [3u8; RANDOMIZED_KEY_LEN];

        let cases = [
            (
                KEYSTONE_SIGNATURE_LEN - 1,
                PCZT_SIGHASH_LEN,
                RANDOMIZED_KEY_LEN,
            ),
            (
                KEYSTONE_SIGNATURE_LEN,
                PCZT_SIGHASH_LEN - 1,
                RANDOMIZED_KEY_LEN,
            ),
            (
                KEYSTONE_SIGNATURE_LEN,
                PCZT_SIGHASH_LEN,
                RANDOMIZED_KEY_LEN - 1,
            ),
        ];

        for (sig_len, sighash_len, rk_len) in cases {
            let code = unsafe {
                zcashlc_voting_store_keystone_signature(
                    db,
                    round_id.as_ptr(),
                    round_id.len(),
                    0,
                    sig.as_ptr(),
                    sig_len,
                    sighash.as_ptr(),
                    sighash_len,
                    rk.as_ptr(),
                    rk_len,
                )
            };
            assert_eq!(code, -1);
        }

        unsafe { zcashlc_voting_db_free(db) };
    }

    #[test]
    fn clear_keystone_signature_deletes_one_bundles_row() {
        let db = open_memory_db();
        let round_id = b"round";
        insert_round_and_bundle(db, "round");
        let sig = [1u8; KEYSTONE_SIGNATURE_LEN];
        let sighash = [2u8; PCZT_SIGHASH_LEN];
        let rk = [3u8; RANDOMIZED_KEY_LEN];
        assert_eq!(
            unsafe {
                zcashlc_voting_store_keystone_signature(
                    db,
                    round_id.as_ptr(),
                    round_id.len(),
                    0,
                    sig.as_ptr(),
                    sig.len(),
                    sighash.as_ptr(),
                    sighash.len(),
                    rk.as_ptr(),
                    rk.len(),
                )
            },
            0
        );

        let before: Vec<serde_json::Value> = decode_boxed_json(unsafe {
            zcashlc_voting_get_keystone_signatures(db, round_id.as_ptr(), round_id.len())
        });
        assert_eq!(before.len(), 1, "signature must be listed before the clear");

        let rc = unsafe {
            zcashlc_voting_clear_keystone_signature(db, round_id.as_ptr(), round_id.len(), 0)
        };
        assert_eq!(rc, 0);

        let after: Vec<serde_json::Value> = decode_boxed_json(unsafe {
            zcashlc_voting_get_keystone_signatures(db, round_id.as_ptr(), round_id.len())
        });
        assert!(
            after.is_empty(),
            "bundle 0's signature must be gone after the clear"
        );

        unsafe { zcashlc_voting_db_free(db) };
    }

    #[test]
    fn clear_keystone_signature_on_missing_row_succeeds() {
        let db = open_memory_db();
        let round_id = b"round";
        insert_round_and_bundle(db, "round");

        let rc = unsafe {
            zcashlc_voting_clear_keystone_signature(db, round_id.as_ptr(), round_id.len(), 0)
        };
        assert_eq!(
            rc, 0,
            "clearing a bundle with no stored signature must still succeed"
        );

        unsafe { zcashlc_voting_db_free(db) };
    }

    #[test]
    fn clear_keystone_signature_rejects_null_db() {
        let round_id = b"round";
        let rc = unsafe {
            zcashlc_voting_clear_keystone_signature(
                std::ptr::null_mut(),
                round_id.as_ptr(),
                round_id.len(),
                0,
            )
        };
        assert_eq!(rc, -1);
    }

    /// Stores the delegation tx hash, vote tx hash, and a Keystone signature
    /// that the clear-recovery tests start from.

    /// Pins the conservative `zcash_voting` 3.0 clear semantics: a vote whose
    /// on-chain `vc_tree_position` is recorded is confirmed state, and the
    /// recovery clear must preserve it (rc.5 nulled it unconditionally).

    /// Round-trip proof that the reset actually clears the unsigned delegation
    /// setup: a planted signing request answers the sighash readback before the
    /// reset and no longer does after, while the bundle row itself survives.
    #[test]
    fn reset_session_state_clears_unsigned_setup_and_keeps_bundles() {
        let db = open_memory_db();
        plant_signing_request(db, &[0u8; 32]);

        let round_id = TEST_ROUND_ID.as_bytes();
        let before = call_get_sighash(db, round_id);
        assert!(!before.is_null(), "setup must be present before the reset");
        unsafe { crate::ffi::zcashlc_free_boxed_slice(before) };

        assert_eq!(
            unsafe { zcashlc_voting_reset_session_state(db, round_id.as_ptr(), round_id.len()) },
            0,
            "reset must succeed"
        );

        let after = call_get_sighash(db, round_id);
        assert!(
            after.is_null(),
            "unsigned setup must be gone after the reset"
        );
        assert_eq!(
            unsafe { zcashlc_voting_get_bundle_count(db, round_id.as_ptr(), round_id.len()) },
            1,
            "bundle rows must survive the reset"
        );
        unsafe { zcashlc_voting_db_free(db) };
    }

    /// A recorded VAN leaf position is registration evidence on its own:
    /// `store_van_position` can record one before any delegation tx hash is
    /// stored. The reset must leave such a bundle's delegation setup intact —
    /// alpha cannot be regenerated, so clearing it would orphan the on-chain
    /// registration permanently.
    #[test]
    fn reset_session_state_keeps_setup_for_bundle_with_van_position_only() {
        let db = open_memory_db();
        plant_signing_request(db, &[0u8; 32]);
        let round_id = TEST_ROUND_ID.as_bytes();

        // Only the VAN position marks the registration: no delegation tx
        // hash, no Keystone signature.
        assert_eq!(
            unsafe {
                zcashlc_voting_store_van_position(db, round_id.as_ptr(), round_id.len(), 0, 7)
            },
            0,
            "recording the VAN position must succeed"
        );

        assert_eq!(
            unsafe { zcashlc_voting_reset_session_state(db, round_id.as_ptr(), round_id.len()) },
            0,
            "reset must succeed"
        );

        let after = call_get_sighash(db, round_id);
        assert!(
            !after.is_null(),
            "a bundle whose only registration evidence is its VAN position must keep its delegation setup"
        );
        let kept = unsafe { (*after).as_slice() }.to_vec();
        unsafe { zcashlc_free_boxed_slice(after) };
        let sighash: Vec<u8> =
            serde_json::from_slice(&kept).expect("sighash readback decodes as JSON bytes");
        assert_eq!(
            sighash,
            crate::voting::test_helpers::PLANTED_SIGHASH.to_vec(),
            "the preserved setup must echo the planted sighash"
        );

        unsafe { zcashlc_voting_db_free(db) };
    }

    #[test]
    fn reset_session_state_rejects_null_db() {
        let round_id = b"round";
        assert_eq!(
            unsafe {
                zcashlc_voting_reset_session_state(
                    std::ptr::null_mut(),
                    round_id.as_ptr(),
                    round_id.len(),
                )
            },
            -1
        );
    }

    #[test]
    fn reset_session_state_rejects_empty_round_id() {
        let db = open_memory_db();
        insert_round_and_bundle(db, "round");
        let rc = unsafe { zcashlc_voting_reset_session_state(db, std::ptr::null(), 0) };
        assert_eq!(rc, -1, "empty round_id must be rejected");
        let round_id = b"round";
        assert_eq!(
            unsafe { zcashlc_voting_get_bundle_count(db, round_id.as_ptr(), round_id.len()) },
            1,
            "rejection must leave the round untouched"
        );
        unsafe { zcashlc_voting_db_free(db) };
    }
}
