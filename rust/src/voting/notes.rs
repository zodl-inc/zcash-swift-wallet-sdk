use std::panic::AssertUnwindSafe;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use zcash_client_backend::data_api::{Account, WalletRead};

use crate::unwrap_exc_or_null;

use super::constants::ACCOUNT_UUID_BYTE_LEN;
use super::db::VotingDatabaseHandle;
use super::helpers::{bytes_from_ptr, json_to_boxed_slice, open_wallet_db, str_from_ptr};
use super::json::JsonNoteInfo;

// Only primitive encodings cross the ordinary-wallet and voting backend families.
fn neutral_note_info<P: zcash_protocol::consensus::Parameters>(
    note: &orchard::Note,
    position: u64,
    scope: zip32::Scope,
    ufvk: &zcash_keys::keys::UnifiedFullViewingKey,
    network: &P,
) -> anyhow::Result<JsonNoteInfo> {
    use orchard::note::{ExtractedNoteCommitment, NoteVersion};
    if note.version() != NoteVersion::V3 {
        return Err(anyhow!("voting requires Ironwood/V3 notes"));
    }
    let fvk = ufvk
        .orchard()
        .ok_or_else(|| anyhow!("voting requires an Orchard viewing key"))?;
    Ok(JsonNoteInfo {
        commitment: ExtractedNoteCommitment::from(note.commitment())
            .to_bytes()
            .to_vec(),
        nullifier: note.nullifier(fvk).to_bytes().to_vec(),
        value: note.value().inner(),
        position,
        diversifier: note.recipient().diversifier().as_array().to_vec(),
        rho: note.rho().to_bytes().to_vec(),
        rseed: note.rseed().as_bytes().to_vec(),
        scope: match scope {
            zip32::Scope::External => 0,
            zip32::Scope::Internal => 1,
        },
        ufvk_str: ufvk.encode(network),
    })
}

// =============================================================================
// VotingDatabase methods — Wallet notes
// =============================================================================

/// Get wallet notes eligible for voting at the given snapshot height.
///
/// Returns JSON-encoded `Vec<NoteInfo>` as `*mut FfiBoxedSlice`, or null on error.
///
/// `account_uuid` must be a non-null pointer to exactly `ACCOUNT_UUID_BYTE_LEN` bytes
/// (binary account UUID).
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - `wallet_db_path` must be a valid path for reads of `wallet_db_path_len` bytes.
/// - When `account_uuid_len == ACCOUNT_UUID_BYTE_LEN`, `account_uuid` must be valid for
///   reads of `ACCOUNT_UUID_BYTE_LEN` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_get_wallet_notes(
    db: *mut VotingDatabaseHandle,
    wallet_db_path: *const u8,
    wallet_db_path_len: usize,
    snapshot_height: u64,
    network_id: u32,
    account_uuid: *const u8,
    account_uuid_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let res = catch_panic(|| {
        // Enforce that the database handle is not null.
        let _handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let wallet_path_str = unsafe { str_from_ptr(wallet_db_path, wallet_db_path_len) }?;

        if account_uuid.is_null() || account_uuid_len != ACCOUNT_UUID_BYTE_LEN {
            return Err(anyhow!(
                "account_uuid must be a non-null pointer to exactly {} bytes (got len {})",
                ACCOUNT_UUID_BYTE_LEN,
                account_uuid_len
            ));
        }

        let wallet_db = open_wallet_db(&wallet_path_str, network_id)?;

        let uuid_bytes = unsafe { bytes_from_ptr(account_uuid, account_uuid_len) }?;
        let arr: [u8; ACCOUNT_UUID_BYTE_LEN] = uuid_bytes
            .try_into()
            .map_err(|_| anyhow!("account_uuid must be {} bytes", ACCOUNT_UUID_BYTE_LEN))?;
        let target_id = zcash_client_sqlite::AccountUuid::from_uuid(uuid::Uuid::from_bytes(arr));

        // Get the account from the wallet database.
        let account = wallet_db
            .get_account(target_id)?
            .ok_or_else(|| anyhow!("account not found"))?;

        // Get the UFVK from the account.
        let ufvk = account
            .ufvk()
            .ok_or_else(|| anyhow!("account has no UFVK"))?;
        let resolved_uuid = account.id();

        // Convert the snapshot height to a block height.
        let snapshot_height_u32 = u32::try_from(snapshot_height).map_err(|_| {
            anyhow!(
                "snapshot_height {} does not fit in u32 (max {})",
                snapshot_height,
                u32::MAX
            )
        })?;

        // Get the unspent Ironwood notes at the historical height. zcash_voting
        // 1.0 votes with Ironwood-pool notes, so voting weight is read from the
        // Ironwood pool, not Orchard.
        let height = zcash_protocol::consensus::BlockHeight::from_u32(snapshot_height_u32);
        let received_notes = wallet_db
            .get_unspent_ironwood_notes_at_historical_height(resolved_uuid, height)
            .map_err(|e| {
                anyhow!(
                    "get_unspent_ironwood_notes_at_historical_height failed: {}",
                    e
                )
            })?;

        // Convert the notes to JSON.
        let network = wallet_db.params();
        let mut json_notes = Vec::with_capacity(received_notes.len());
        for rn in &received_notes {
            let note_info = neutral_note_info(
                rn.note(),
                u64::from(rn.note_commitment_tree_position()),
                rn.spending_key_scope(),
                ufvk,
                network,
            )?;
            json_notes.push(JsonNoteInfo::from(note_info));
        }
        json_to_boxed_slice(&json_notes)
    });
    unwrap_exc_or_null(res)
}

#[cfg(test)]
mod tests {
    use super::*;
    use orchard::note::{ExtractedNoteCommitment, NoteVersion, Rho};
    use orchard::value::NoteValue;
    use rand::rngs::OsRng;
    use zcash_keys::keys::UnifiedSpendingKey;
    use zcash_protocol::consensus::TEST_NETWORK;
    use zip32::{AccountId, Scope};
    #[test]
    fn from_orchard_note_populates_note_info() {
        let seed = [0x42u8; 32];
        let account = AccountId::try_from(0u32).unwrap();
        let usk = UnifiedSpendingKey::from_seed(&TEST_NETWORK, &seed, account).unwrap();
        let ufvk = usk.to_unified_full_viewing_key();
        let fvk = ufvk.orchard().unwrap().clone();
        let address = fvk.address_at(0u32, Scope::External);

        let mut rng = OsRng;
        let note = test_note(&fvk, address, NoteVersion::V3, &mut rng);

        let note_info =
            neutral_note_info(&note, 42, Scope::External, &ufvk, &TEST_NETWORK).unwrap();
        let commitment: ExtractedNoteCommitment = note.commitment().into();

        assert_eq!(note_info.commitment, commitment.to_bytes().to_vec());
        assert_eq!(
            note_info.nullifier,
            note.nullifier(&fvk).to_bytes().to_vec()
        );
        assert_eq!(note_info.value, 12_500_000);
        assert_eq!(note_info.position, 42);
        assert_eq!(
            note_info.diversifier,
            note.recipient().diversifier().as_array().to_vec()
        );
        assert_eq!(note_info.rho, note.rho().to_bytes().to_vec());
        assert_eq!(note_info.rseed, note.rseed().as_bytes().to_vec());
        assert_eq!(note_info.scope, 0);
        assert_eq!(note_info.ufvk_str, ufvk.encode(&TEST_NETWORK));
    }

    #[test]
    fn from_orchard_note_rejects_non_ironwood_notes() {
        let seed = [0x42u8; 32];
        let account = AccountId::try_from(0u32).unwrap();
        let usk = UnifiedSpendingKey::from_seed(&TEST_NETWORK, &seed, account).unwrap();
        let ufvk = usk.to_unified_full_viewing_key();
        let fvk = ufvk.orchard().unwrap().clone();
        let address = fvk.address_at(0u32, Scope::External);

        let mut rng = OsRng;
        let note = test_note(&fvk, address, NoteVersion::V2, &mut rng);

        let err = neutral_note_info(&note, 42, Scope::External, &ufvk, &TEST_NETWORK)
            .expect_err("Orchard/V2 notes are not eligible for voting");

        assert!(
            err.to_string().contains("requires Ironwood/V3 notes"),
            "{err}"
        );
    }

    fn test_note(
        _fvk: &orchard::keys::FullViewingKey,
        address: orchard::Address,
        version: NoteVersion,
        _rng: &mut OsRng,
    ) -> orchard::Note {
        let mut rho_bytes = [0u8; 32];
        rho_bytes[0] = 1;
        let rho = Rho::from_bytes(&rho_bytes).unwrap();
        let rseed = orchard::note::RandomSeed::from_bytes([0x42; 32], &rho).unwrap();
        orchard::Note::from_parts(
            address,
            NoteValue::from_raw(12_500_000),
            rho,
            rseed,
            version,
        )
        .unwrap()
    }

    use crate::NETWORK_ID_MAINNET;
    use crate::voting::db::{zcashlc_voting_db_free, zcashlc_voting_db_open};

    /// Arbitrary account UUID for FFI tests that only exercise path/network/db errors.
    const TEST_ACCOUNT_UUID: [u8; super::ACCOUNT_UUID_BYTE_LEN] =
        [0x7Eu8; super::ACCOUNT_UUID_BYTE_LEN];

    fn open_temp_voting_db(tag: &str) -> (*mut VotingDatabaseHandle, std::path::PathBuf) {
        let mut path = std::env::temp_dir();
        path.push(format!(
            "zcashlc_voting_get_wallet_notes_{}_{}.sqlite",
            tag,
            std::process::id()
        ));
        let path_bytes = path.to_string_lossy().as_bytes().to_vec();
        let db = unsafe { zcashlc_voting_db_open(path_bytes.as_ptr(), path_bytes.len(), 1) };
        assert!(!db.is_null(), "open voting db at {:?}", path);
        (db, path)
    }

    fn nonexistent_wallet_path() -> Vec<u8> {
        // A path inside a directory that almost certainly does not exist; sqlite will
        // fail to create the file because the parent directory is missing.
        format!(
            "/nonexistent-zcashlc-test-{}/wallet.sqlite",
            std::process::id()
        )
        .into_bytes()
    }

    #[test]
    fn get_wallet_notes_rejects_null_db() {
        let wallet_path = b"/tmp/should_not_be_read.sqlite";
        let result = unsafe {
            zcashlc_voting_get_wallet_notes(
                std::ptr::null_mut(),
                wallet_path.as_ptr(),
                wallet_path.len(),
                100,
                NETWORK_ID_MAINNET,
                TEST_ACCOUNT_UUID.as_ptr(),
                TEST_ACCOUNT_UUID.len(),
            )
        };
        assert!(result.is_null());
    }

    #[test]
    fn get_wallet_notes_rejects_invalid_utf8_wallet_path() {
        let (db, voting_path) = open_temp_voting_db("invalid_utf8");
        let invalid_path = [0xffu8];
        let result = unsafe {
            zcashlc_voting_get_wallet_notes(
                db,
                invalid_path.as_ptr(),
                invalid_path.len(),
                100,
                NETWORK_ID_MAINNET,
                TEST_ACCOUNT_UUID.as_ptr(),
                TEST_ACCOUNT_UUID.len(),
            )
        };
        assert!(result.is_null());
        unsafe { zcashlc_voting_db_free(db) };
        let _ = std::fs::remove_file(&voting_path);
    }

    #[test]
    fn get_wallet_notes_rejects_invalid_network_id() {
        let (db, voting_path) = open_temp_voting_db("invalid_network");
        let wallet_path = b"/tmp/zcashlc_unused_wallet.sqlite";
        let result = unsafe {
            zcashlc_voting_get_wallet_notes(
                db,
                wallet_path.as_ptr(),
                wallet_path.len(),
                100,
                99, // invalid: parse_network rejects anything outside {0, 1}
                TEST_ACCOUNT_UUID.as_ptr(),
                TEST_ACCOUNT_UUID.len(),
            )
        };
        assert!(result.is_null());
        unsafe { zcashlc_voting_db_free(db) };
        let _ = std::fs::remove_file(&voting_path);
    }

    #[test]
    fn get_wallet_notes_rejects_unopenable_wallet_path() {
        let (db, voting_path) = open_temp_voting_db("unopenable");
        let wallet_path = nonexistent_wallet_path();
        let result = unsafe {
            zcashlc_voting_get_wallet_notes(
                db,
                wallet_path.as_ptr(),
                wallet_path.len(),
                100,
                NETWORK_ID_MAINNET,
                TEST_ACCOUNT_UUID.as_ptr(),
                TEST_ACCOUNT_UUID.len(),
            )
        };
        assert!(result.is_null());
        unsafe { zcashlc_voting_db_free(db) };
        let _ = std::fs::remove_file(&voting_path);
    }

    #[test]
    fn get_wallet_notes_rejects_null_account_uuid() {
        let (db, voting_path) = open_temp_voting_db("null_uuid");
        let wallet_path = b"/tmp/zcashlc_unused_wallet.sqlite";
        let result = unsafe {
            zcashlc_voting_get_wallet_notes(
                db,
                wallet_path.as_ptr(),
                wallet_path.len(),
                100,
                NETWORK_ID_MAINNET,
                std::ptr::null(),
                super::ACCOUNT_UUID_BYTE_LEN,
            )
        };
        assert!(result.is_null());
        unsafe { zcashlc_voting_db_free(db) };
        let _ = std::fs::remove_file(&voting_path);
    }

    #[test]
    fn get_wallet_notes_rejects_wrong_account_uuid_length() {
        let (db, voting_path) = open_temp_voting_db("bad_uuid_len");
        let wallet_path = b"/tmp/zcashlc_unused_wallet.sqlite";
        let short = [0u8; 8];
        let result = unsafe {
            zcashlc_voting_get_wallet_notes(
                db,
                wallet_path.as_ptr(),
                wallet_path.len(),
                100,
                NETWORK_ID_MAINNET,
                short.as_ptr(),
                short.len(),
            )
        };
        assert!(result.is_null());
        unsafe { zcashlc_voting_db_free(db) };
        let _ = std::fs::remove_file(&voting_path);
    }
}
