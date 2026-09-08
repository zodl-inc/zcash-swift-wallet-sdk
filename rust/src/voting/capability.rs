//! Restores a delegation carved out of a wiped voting database, through the
//! crate's capability import, behind guards that refuse to clear a round the
//! wallet could still use.

use std::panic::AssertUnwindSafe;

use anyhow::anyhow;
use base64::prelude::{BASE64_STANDARD, Engine as _};
use ffi_helpers::panic::catch_panic;
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use zcash_voting as voting;
use zcash_voting::storage::queries;

use crate::unwrap_exc_or_null;

use super::db::VotingDatabaseHandle;
use super::helpers::{bytes_from_ptr, json_to_boxed_slice, str_from_ptr, voting_network};

/// One bundle of a recovered delegation, as the caller supplies it.
#[derive(Deserialize)]
struct RecoveredBundle {
    bundle_index: u32,
    /// Bundle weight in zatoshi, as `bundles.total_note_value` stores it.
    total_note_value: u64,
    /// The 32-byte VAN blinding factor.
    van_comm_rand: Vec<u8>,
    /// The 32-byte VAN commitment the row carried. The restore refuses a
    /// bundle whose blinding and weight do not open it for the handle's hotkey.
    van: Vec<u8>,
    /// Lowercase hex SHA-256 of the signed delegation transaction.
    delegation_tx_hash: String,
}

/// Everything except the hotkey secret, as one JSON document. The secret
/// crosses as its own buffer, the way `zcashlc_voting_build_pczt` takes it,
/// so it is never copied through a JSON encoder on either side.
#[derive(Deserialize)]
struct RestoreRequest {
    round_id: String,
    snapshot_height: u64,
    ea_pk: Vec<u8>,
    nc_root: Vec<u8>,
    nullifier_imt_root: Vec<u8>,
    vote_chain_id: String,
    bundles: Vec<RecoveredBundle>,
    session_json: Option<String>,
}

#[derive(Serialize)]
struct RestoreReply {
    outcome: &'static str,
}

/// What the round holds now, read on the same connection just before the
/// decision to clear it.
struct RoundRows {
    /// `(bundle_index, van_comm_rand, delegation_tx_hash)` in index order.
    bundles: Vec<(u32, Option<Vec<u8>>, Option<String>)>,
    votes: i64,
    shares: i64,
    keystone_signatures: i64,
}

/// The lowercase network name the capability codec expects.
fn network_name(network: voting::types::Network) -> &'static str {
    match network {
        voting::types::Network::Mainnet => "mainnet",
        voting::types::Network::Testnet => "testnet",
        voting::types::Network::Regtest => "regtest",
    }
}

fn count(
    conn: &rusqlite::Connection,
    sql: &str,
    round_id: &str,
    wallet_id: &str,
) -> anyhow::Result<i64> {
    Ok(conn.query_row(sql, params![round_id, wallet_id], |row| row.get(0))?)
}

fn round_rows(
    conn: &rusqlite::Connection,
    round_id: &str,
    wallet_id: &str,
) -> anyhow::Result<RoundRows> {
    let mut statement = conn.prepare(
        "SELECT bundle_index, van_comm_rand, delegation_tx_hash FROM bundles
          WHERE round_id = ?1 AND wallet_id = ?2 ORDER BY bundle_index",
    )?;
    let bundles = statement
        .query_map(params![round_id, wallet_id], |row| {
            Ok((row.get::<_, i64>(0)? as u32, row.get(1)?, row.get(2)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(RoundRows {
        bundles,
        votes: count(
            conn,
            "SELECT COUNT(*) FROM votes WHERE round_id = ?1 AND wallet_id = ?2",
            round_id,
            wallet_id,
        )?,
        shares: count(
            conn,
            "SELECT COUNT(*) FROM share_delegations WHERE round_id = ?1 AND wallet_id = ?2",
            round_id,
            wallet_id,
        )?,
        keystone_signatures: count(
            conn,
            "SELECT COUNT(*) FROM keystone_signatures WHERE round_id = ?1 AND wallet_id = ?2",
            round_id,
            wallet_id,
        )?,
    })
}

/// What the guards allow for a package, when they do not refuse it.
#[derive(Debug, PartialEq, Eq)]
enum Decision {
    /// The round already holds exactly this delegation; nothing is written.
    AlreadyRestored,
    /// Every row the package does not restore is useless to the wallet, so
    /// the round is cleared and the package imported.
    ClearAndImport,
}

/// The guards that decide what may be done to the round for this package.
/// An error names the guard that refused.
///
/// Rows the wallet could still use stay: cast votes, delivered shares,
/// Keystone signatures, and every bundle row the package does not restore
/// under the same index and accepted hash. A row without a stored hash is not
/// proof that nothing was broadcast, since the hash is stored only after the
/// broadcast returns, so the package must cover every stored row. It may
/// extend a prefix restored earlier.
fn decide(rows: &RoundRows, package: &[(u32, [u8; 32], String)]) -> anyhow::Result<Decision> {
    if rows.votes > 0 {
        return Err(anyhow!(
            "round holds {} cast vote(s); nothing may be cleared",
            rows.votes
        ));
    }
    if rows.shares > 0 {
        return Err(anyhow!(
            "round holds {} delivered share(s); nothing may be cleared",
            rows.shares
        ));
    }
    if rows.keystone_signatures > 0 {
        return Err(anyhow!(
            "round holds {} Keystone signature(s); nothing may be cleared",
            rows.keystone_signatures
        ));
    }
    if rows.bundles.is_empty() {
        return Ok(Decision::ClearAndImport);
    }
    let mut identical = rows.bundles.len() == package.len();
    for (index, stored_rand, stored_hash) in &rows.bundles {
        let Some((_, offered_rand, offered_hash)) = package
            .iter()
            .find(|(offered_index, _, _)| offered_index == index)
        else {
            return Err(anyhow!(
                "bundle {index} is not in the package; nothing may be cleared"
            ));
        };
        match stored_hash {
            Some(hash) if hash != offered_hash => {
                return Err(anyhow!(
                    "bundle {index} carries a different accepted delegation; nothing may be cleared"
                ));
            }
            Some(_) => {
                if stored_rand.as_deref() != Some(offered_rand.as_slice()) {
                    identical = false;
                }
            }
            None => identical = false,
        }
    }
    Ok(if identical {
        Decision::AlreadyRestored
    } else {
        Decision::ClearAndImport
    })
}

/// The VAN commitment `hotkey`, `round_id`, `total_note_value` and
/// `van_comm_rand` open: what the crate stores for a bundle built from them.
fn van_commitment(
    hotkey: &voting::VotingHotkey,
    round_id: &str,
    total_note_value: u64,
    van_comm_rand: &[u8],
) -> anyhow::Result<Vec<u8>> {
    let round_bytes = hex::decode(round_id).map_err(|_| anyhow!("round id is not hex"))?;
    let (g_d_x, pk_d_x) =
        voting::action::derive_hotkey_x_coords_from_raw_address(hotkey.raw_orchard_address())
            .map_err(|e| anyhow!("hotkey address is not usable: {e}"))?;
    voting::governance::construct_van(
        &g_d_x,
        &pk_d_x,
        total_note_value,
        &round_bytes,
        van_comm_rand,
    )
    .map_err(|e| anyhow!("commitment could not be recomputed: {e}"))
}

/// Restore a delegation whose secrets were carved out of a wiped database.
///
/// Validates the package and the round context, checks that each bundle's
/// blinding and weight open the commitment it carries for the handle's
/// hotkey, reads what the round holds, refuses unless the round holds no
/// votes, shares, or Keystone signatures and every bundle row it holds is
/// restored by the package under its accepted hash, and only then runs
/// `clear_round` followed by `import_delegation_capability`. The package
/// must be contiguous from bundle zero and cover every stored row; it may
/// extend a prefix restored earlier.
///
/// `request_json` is one JSON object: `round_id`, `snapshot_height`, `ea_pk`,
/// `nc_root`, `nullifier_imt_root` (byte arrays), `vote_chain_id`, `bundles`
/// (objects with `bundle_index`, `total_note_value`, `van_comm_rand` and `van`
/// as 32-byte arrays, `delegation_tx_hash` lowercase hex) and optional
/// `session_json`. `hotkey_stored_secret` is the material returned as
/// `FfiVotingHotkey::stored_secret`, passed as raw bytes.
///
/// The stored weight becomes the canonical whole-ballot total, as it does for
/// every capability import: the package carries `num_ballots`, and the import
/// stores `num_ballots * BALLOT_DIVISOR`. The VAN is unaffected, because
/// `construct_van` commits to `num_ballots`, not to the exact zatoshi total, so
/// a delegation whose weight was not a ballot multiple still reproduces the
/// commitment the chain holds. The test below pins that.
///
/// Returns JSON `{"outcome":"restored"}` or `{"outcome":"already_restored"}`
/// as `*mut BoxedSlice`, or null with the error set.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `request_json` and `hotkey_stored_secret` must be valid for their
///   stated lengths.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_restore_recovered_delegation(
    db: *mut VotingDatabaseHandle,
    request_json: *const u8,
    request_json_len: usize,
    hotkey_stored_secret: *const u8,
    hotkey_stored_secret_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let request: RestoreRequest =
            serde_json::from_slice(unsafe { bytes_from_ptr(request_json, request_json_len) }?)?;
        let secret = unsafe { bytes_from_ptr(hotkey_stored_secret, hotkey_stored_secret_len) }?;

        // Everything that can fail on input fails here, before any read or
        // write.
        let params = voting::VotingRoundParams {
            vote_round_id: request.round_id.clone(),
            snapshot_height: request.snapshot_height,
            ea_pk: request.ea_pk,
            nc_root: request.nc_root,
            nullifier_imt_root: request.nullifier_imt_root,
        };
        voting::validate_round_params(&params).map_err(|e| anyhow!("invalid round params: {e}"))?;
        let hotkey = voting::VotingHotkey::from_stored_secret(secret, handle.network)
            .map_err(|e| anyhow!("invalid hotkey secret: {e}"))?;

        let mut package_bundles = Vec::with_capacity(request.bundles.len());
        let mut comparable = Vec::with_capacity(request.bundles.len());
        for bundle in request.bundles {
            let num_ballots = bundle.total_note_value / voting::BALLOT_DIVISOR;
            if num_ballots == 0 {
                return Err(anyhow!(
                    "bundle {} weight {} is below one ballot",
                    bundle.bundle_index,
                    bundle.total_note_value
                ));
            }
            let rand: [u8; 32] =
                bundle.van_comm_rand.as_slice().try_into().map_err(|_| {
                    anyhow!("bundle {} blinding is not 32 bytes", bundle.bundle_index)
                })?;
            let van: [u8; 32] = bundle.van.as_slice().try_into().map_err(|_| {
                anyhow!("bundle {} commitment is not 32 bytes", bundle.bundle_index)
            })?;
            let opened = van_commitment(&hotkey, &request.round_id, bundle.total_note_value, &rand)
                .map_err(|e| anyhow!("bundle {}: {e}", bundle.bundle_index))?;
            if opened != van {
                return Err(anyhow!(
                    "bundle {} does not open its commitment; nothing may be cleared",
                    bundle.bundle_index
                ));
            }
            comparable.push((bundle.bundle_index, rand, bundle.delegation_tx_hash.clone()));
            package_bundles.push(voting::DelegationCapabilityBundleV1 {
                bundle_index: bundle.bundle_index,
                num_ballots,
                van_comm_rand: BASE64_STANDARD.encode(rand),
                delegation_tx_hash: bundle.delegation_tx_hash,
            });
        }
        let capability = voting::DelegationCapabilityV1 {
            format_version: 1,
            vote_chain_id: request.vote_chain_id.clone(),
            network: network_name(handle.network).to_string(),
            vote_round_id: request.round_id.clone(),
            address_index: hotkey.address_index(),
            raw_orchard_address: BASE64_STANDARD.encode(hotkey.raw_orchard_address()),
            bundles: package_bundles,
        };
        let json = capability
            .to_json()
            .map_err(|e| anyhow!("capability encoding failed: {e}"))?;
        // The strict codec: canonical field elements, lowercase distinct
        // hashes, contiguous indices, weight bounds.
        voting::DelegationCapabilityV1::from_json(&json)
            .map_err(|e| anyhow!("capability package is invalid: {e}"))?;

        // The guards, on the live connection, immediately before the
        // decision.
        let wallet_id = handle.db.wallet_id();
        let decision = {
            let conn = handle.db.conn();
            let stored = conn
                .query_row(
                    "SELECT 1 FROM rounds WHERE round_id = ?1 AND wallet_id = ?2",
                    params![request.round_id, wallet_id],
                    |_| Ok(()),
                )
                .optional()?;
            if stored.is_some() {
                let (stored_params, stored_network) =
                    queries::load_round_params_with_network(&conn, &request.round_id, &wallet_id)
                        .map_err(|e| anyhow!("could not read the stored round: {e}"))?;
                if stored_params != params || stored_network != handle.network {
                    return Err(anyhow!(
                        "stored round parameters differ from the caller's; nothing may be cleared"
                    ));
                }
            }
            let rows = round_rows(&conn, &request.round_id, &wallet_id)?;
            decide(&rows, &comparable)?
        };
        if decision == Decision::AlreadyRestored {
            return json_to_boxed_slice(&RestoreReply {
                outcome: "already_restored",
            });
        }

        // The two writes. The crate's import opens its own transaction on
        // this connection, so the clear cannot share it; after the checks
        // above, an import failure here can only be a storage failure, and
        // the escrow still holds everything for the next attempt.
        {
            let conn = handle.db.conn();
            queries::clear_round(&conn, &request.round_id, &wallet_id)
                .map_err(|e| anyhow!("clear_round failed: {e}"))?;
        }
        voting::import_delegation_capability(
            &handle.db,
            &json,
            voting::ImportDelegationCapabilityParams {
                voting_hotkey: &hotkey,
                expected_chain_id: &request.vote_chain_id,
                expected_network: handle.network,
                expected_round_params: &params,
                session_json: request.session_json.as_deref(),
            },
        )
        .map_err(|e| anyhow!("import_delegation_capability failed after clear: {e}"))?;
        json_to_boxed_slice(&RestoreReply {
            outcome: "restored",
        })
    });
    unwrap_exc_or_null(res)
}

/// The VAN commitment a hotkey, round, weight and blinding open.
///
/// `hotkey_stored_secret` is the material `FfiVotingHotkey::stored_secret`
/// returns; `round_id` is the round's 64-character lowercase hex id;
/// `van_comm_rand` is the 32-byte blinding. Returns the 32-byte commitment as
/// a boxed slice, or null with the error set. It is the value
/// `zcashlc_voting_restore_recovered_delegation` recomputes for each bundle
/// before it clears anything, so a caller can check a recovered row the same
/// way.
///
/// # Safety
///
/// - Every pointer must be valid for its stated length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_van_commitment(
    hotkey_stored_secret: *const u8,
    hotkey_stored_secret_len: usize,
    network_id: u32,
    round_id: *const u8,
    round_id_len: usize,
    total_note_value: u64,
    van_comm_rand: *const u8,
    van_comm_rand_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let secret = unsafe { bytes_from_ptr(hotkey_stored_secret, hotkey_stored_secret_len) }?;
        let round_id = unsafe { str_from_ptr(round_id, round_id_len) }?;
        let rand = unsafe { bytes_from_ptr(van_comm_rand, van_comm_rand_len) }?;
        let network = voting_network(network_id)?;
        let hotkey = voting::VotingHotkey::from_stored_secret(secret, network)
            .map_err(|e| anyhow!("invalid hotkey secret: {e}"))?;
        if rand.len() != 32 {
            return Err(anyhow!("blinding is not 32 bytes"));
        }
        let van = van_commitment(&hotkey, &round_id, total_note_value, rand)?;
        Ok(crate::ffi::BoxedSlice::some(van))
    });
    unwrap_exc_or_null(res)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::zcashlc_free_boxed_slice;
    use crate::voting::db::zcashlc_voting_db_free;
    use crate::voting::test_helpers::open_memory_db;

    /// 64 lowercase hex characters encoding a canonical Pallas element: only
    /// the low byte is set.
    fn hex_round_id(tag: u8) -> String {
        format!("{tag:02x}{}", "00".repeat(31))
    }

    fn restore_request(
        round_id: &str,
        total_note_value: u64,
        rand: &[u8; 32],
        van: &[u8],
    ) -> String {
        serde_json::json!({
            "round_id": round_id,
            "snapshot_height": 123,
            "ea_pk": vec![7u8; 32],
            "nc_root": vec![7u8; 32],
            "nullifier_imt_root": vec![7u8; 32],
            "vote_chain_id": "zcash-coinholder-polling",
            "bundles": [{
                "bundle_index": 0,
                "total_note_value": total_note_value,
                "van_comm_rand": rand.to_vec(),
                "van": van.to_vec(),
                "delegation_tx_hash": "ab".repeat(32),
            }],
        })
        .to_string()
    }

    /// The reviewer's question on the PR: does routing the weight through the
    /// capability's whole-ballot representation change the VAN? It does not.
    /// `construct_van` hashes `num_ballots`, so the VAN of the exact original
    /// weight (one ballot plus a remainder) equals the VAN the restore stores.
    #[test]
    fn restored_van_equals_the_van_of_the_exact_original_weight() {
        let db = open_memory_db();
        let handle = unsafe { &*db };
        let hotkey = voting::hotkey::generate_random_voting_hotkey(handle.network).unwrap();
        let round_id = hex_round_id(0x05);
        let mut rand = [0u8; 32];
        rand[0] = 0x2A;
        let exact_total: u64 = 13_000_000;

        let van = van_commitment(&hotkey, &round_id, exact_total, &rand).unwrap();
        let request = restore_request(&round_id, exact_total, &rand, &van);
        let secret = hotkey.stored_secret().to_vec();
        let reply = unsafe {
            zcashlc_voting_restore_recovered_delegation(
                db,
                request.as_ptr(),
                request.len(),
                secret.as_ptr(),
                secret.len(),
            )
        };
        assert!(!reply.is_null(), "restore failed");
        let outcome = unsafe { (*reply).as_slice() }.to_vec();
        unsafe { zcashlc_free_boxed_slice(reply) };
        assert_eq!(outcome, br#"{"outcome":"restored"}"#);

        let (stored_van, stored_total): (Vec<u8>, i64) = handle
            .db
            .conn()
            .query_row(
                "SELECT gov_comm, total_note_value FROM bundles
                  WHERE round_id = ?1 AND bundle_index = 0",
                params![round_id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();

        let (g_d_x, pk_d_x) =
            voting::action::derive_hotkey_x_coords_from_raw_address(hotkey.raw_orchard_address())
                .unwrap();
        let round_bytes = hex::decode(&round_id).unwrap();
        let van_of_exact_weight =
            voting::governance::construct_van(&g_d_x, &pk_d_x, exact_total, &round_bytes, &rand)
                .unwrap();
        assert_eq!(stored_van, van_of_exact_weight);
        // What does change is the stored weight: the canonical whole-ballot total.
        assert_eq!(
            stored_total as u64,
            (exact_total / voting::BALLOT_DIVISOR) * voting::BALLOT_DIVISOR
        );

        unsafe { zcashlc_voting_db_free(db) };
    }

    fn last_error() -> String {
        ffi_helpers::error_handling::error_message().unwrap_or_default()
    }

    /// A bundle whose blinding does not open the commitment it carries is
    /// refused before the round is read or written.
    #[test]
    fn a_bundle_that_does_not_open_its_commitment_is_refused() {
        let db = open_memory_db();
        let handle = unsafe { &*db };
        let hotkey = voting::hotkey::generate_random_voting_hotkey(handle.network).unwrap();
        let round_id = hex_round_id(0x0D);
        let mut rand = [0u8; 32];
        rand[0] = 0x2A;

        let request = restore_request(&round_id, 13_000_000, &rand, &[9u8; 32]);
        let secret = hotkey.stored_secret().to_vec();
        let reply = unsafe {
            zcashlc_voting_restore_recovered_delegation(
                db,
                request.as_ptr(),
                request.len(),
                secret.as_ptr(),
                secret.len(),
            )
        };
        assert!(reply.is_null());
        let message = last_error();
        assert!(
            message.contains("bundle 0 does not open its commitment; nothing may be cleared"),
            "{message}"
        );

        let rounds: i64 = handle
            .db
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM rounds WHERE round_id = ?1",
                params![round_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(rounds, 0);

        unsafe { zcashlc_voting_db_free(db) };
    }

    fn van_commitment_ffi(
        hotkey: &voting::VotingHotkey,
        round_id: &str,
        total_note_value: u64,
        rand: &[u8],
    ) -> Option<Vec<u8>> {
        let secret = hotkey.stored_secret().to_vec();
        let reply = unsafe {
            zcashlc_voting_van_commitment(
                secret.as_ptr(),
                secret.len(),
                crate::NETWORK_ID_TESTNET,
                round_id.as_ptr(),
                round_id.len(),
                total_note_value,
                rand.as_ptr(),
                rand.len(),
            )
        };
        if reply.is_null() {
            return None;
        }
        let van = unsafe { (*reply).as_slice() }.to_vec();
        unsafe { zcashlc_free_boxed_slice(reply) };
        Some(van)
    }

    /// The exported commitment is the one `construct_van` yields for the
    /// hotkey's address.
    #[test]
    fn van_commitment_ffi_matches_construct_van() {
        let hotkey =
            voting::hotkey::generate_random_voting_hotkey(voting::Network::Testnet).unwrap();
        let round_id = hex_round_id(0x0E);
        let mut rand = [0u8; 32];
        rand[0] = 0x2B;

        let van = van_commitment_ffi(&hotkey, &round_id, 25_000_000, &rand).expect("commitment");

        let (g_d_x, pk_d_x) =
            voting::action::derive_hotkey_x_coords_from_raw_address(hotkey.raw_orchard_address())
                .unwrap();
        let expected = voting::governance::construct_van(
            &g_d_x,
            &pk_d_x,
            25_000_000,
            &hex::decode(&round_id).unwrap(),
            &rand,
        )
        .unwrap();
        assert_eq!(van, expected);
    }

    #[test]
    fn van_commitment_ffi_rejects_a_weight_below_one_ballot() {
        let hotkey =
            voting::hotkey::generate_random_voting_hotkey(voting::Network::Testnet).unwrap();
        let round_id = hex_round_id(0x0F);

        assert!(van_commitment_ffi(&hotkey, &round_id, 1, &[0x2C; 32]).is_none());
        assert!(
            last_error().contains("at least 1 ballot"),
            "{}",
            last_error()
        );
    }

    /// `(index, blinding tag, accepted hash tag)`; `None` is a NULL column.
    fn stored(bundles: &[(u32, Option<u8>, Option<u8>)]) -> RoundRows {
        RoundRows {
            bundles: bundles
                .iter()
                .map(|(index, rand, hash)| {
                    (
                        *index,
                        rand.map(|tag| vec![tag; 32]),
                        hash.map(|tag| format!("{tag:02x}").repeat(32)),
                    )
                })
                .collect(),
            votes: 0,
            shares: 0,
            keystone_signatures: 0,
        }
    }

    fn offered(bundles: &[(u32, u8, u8)]) -> Vec<(u32, [u8; 32], String)> {
        bundles
            .iter()
            .map(|(index, rand, hash)| (*index, [*rand; 32], format!("{hash:02x}").repeat(32)))
            .collect()
    }

    #[test]
    fn the_same_package_is_already_restored() {
        let rows = stored(&[(0, Some(0x2A), Some(0xAB)), (1, Some(0x2B), Some(0xAC))]);
        let package = offered(&[(0, 0x2A, 0xAB), (1, 0x2B, 0xAC)]);
        assert_eq!(decide(&rows, &package).unwrap(), Decision::AlreadyRestored);
    }

    /// A row without a hash may still back a delegation the chain accepted:
    /// the hash is stored only after the broadcast returns.
    #[test]
    fn a_package_shorter_than_the_round_is_refused() {
        let rows = stored(&[
            (0, Some(0x3A), None),
            (1, Some(0x3B), None),
            (2, Some(0x3C), None),
        ]);
        let package = offered(&[(0, 0x2A, 0xAB), (1, 0x2B, 0xAC)]);
        let message = decide(&rows, &package).unwrap_err().to_string();
        assert!(
            message.contains("bundle 2 is not in the package"),
            "{message}"
        );
    }

    #[test]
    fn a_fuller_package_may_extend_a_restored_prefix() {
        let rows = stored(&[(0, Some(0x2A), Some(0xAB))]);
        let package = offered(&[(0, 0x2A, 0xAB), (1, 0x2B, 0xAC)]);
        assert_eq!(decide(&rows, &package).unwrap(), Decision::ClearAndImport);
    }

    #[test]
    fn a_package_that_drops_an_accepted_bundle_is_refused() {
        let rows = stored(&[(0, Some(0x2A), Some(0xAB)), (1, Some(0x2B), Some(0xAC))]);
        let package = offered(&[(0, 0x2A, 0xAB)]);
        let message = decide(&rows, &package).unwrap_err().to_string();
        assert!(
            message.contains("bundle 1 is not in the package"),
            "{message}"
        );
    }

    #[test]
    fn a_different_accepted_hash_is_refused() {
        let rows = stored(&[(0, Some(0x2A), Some(0xAB))]);
        let package = offered(&[(0, 0x2A, 0xAD)]);
        let message = decide(&rows, &package).unwrap_err().to_string();
        assert!(
            message.contains("bundle 0 carries a different accepted delegation"),
            "{message}"
        );
    }

    #[test]
    fn a_missing_blinding_under_the_accepted_hash_may_be_restored() {
        let rows = stored(&[(0, None, Some(0xAB))]);
        let package = offered(&[(0, 0x2A, 0xAB)]);
        assert_eq!(decide(&rows, &package).unwrap(), Decision::ClearAndImport);
    }

    #[test]
    fn a_cast_vote_is_refused_whatever_the_package() {
        let mut rows = stored(&[(0, Some(0x3A), None)]);
        rows.votes = 1;
        let message = decide(&rows, &offered(&[(0, 0x2A, 0xAB)]))
            .unwrap_err()
            .to_string();
        assert!(message.contains("cast vote"), "{message}");
    }
}
