//! Read-only reuse of a proof already committed with its delegation setup.

use super::helpers::{bytes_from_ptr, json_to_boxed_slice};
use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use serde::Deserialize;
use std::panic::AssertUnwindSafe;
use zcash_voting as voting;
use zcash_voting::backend::{
    orchard,
    pasta_curves::{group::ff::PrimeField, pallas},
};
use zcash_voting::storage::queries;

use super::db::VotingDatabaseHandle;
use super::json::{JsonDelegationProofResult, JsonNoteInfo};

#[derive(Deserialize)]
struct ProofReadbackRequest {
    round_id: String,
    bundle_index: u32,
    notes: Vec<JsonNoteInfo>,
    fvk: Vec<u8>,
    seed_fingerprint: [u8; 32],
    account_index: u32,
    round_name: String,
    snapshot_height: u64,
    pczt_sighash: Vec<u8>,
}

fn read_completed_proof(
    handle: &VotingDatabaseHandle,
    request: ProofReadbackRequest,
    hotkey_secret: &[u8],
) -> anyhow::Result<Option<JsonDelegationProofResult>> {
    let wallet = handle.db.wallet_id();
    let (round, network) =
        queries::load_round_params_with_network(&handle.db.conn(), &request.round_id, &wallet)?;
    anyhow::ensure!(
        network == handle.network,
        "stored round network does not match open database"
    );
    anyhow::ensure!(
        round.snapshot_height == request.snapshot_height,
        "stored snapshot does not match requested snapshot"
    );
    let sighash = queries::load_pczt_sighash(
        &handle.db.conn(),
        &request.round_id,
        &wallet,
        request.bundle_index,
    )?;
    anyhow::ensure!(
        sighash.len() == 32 && sighash == request.pczt_sighash,
        "persisted delegation setup changed"
    );
    match handle
        .db
        .delegation_phase(&request.round_id, request.bundle_index)?
    {
        voting::phases::DelegationPhase::Prepared | voting::phases::DelegationPhase::PcztBuilt => {
            return Ok(None);
        }
        _ => {}
    }

    // Use the same native key construction and round/network checks as fresh proving.
    let hotkey = voting::VotingHotkey::from_stored_secret(hotkey_secret, handle.network)?;
    let keys = voting::delegate::DelegationKeys::with_voting_hotkey(
        request.fvk.clone(),
        &hotkey,
        request.seed_fingerprint,
        request.account_index,
        request.round_name,
    )?;
    let signing =
        handle
            .db
            .get_delegation_signing_request(&request.round_id, request.bundle_index, &keys)?;
    anyhow::ensure!(
        signing.sighash.as_slice() == sighash,
        "persisted delegation setup changed"
    );
    let notes: Vec<voting::NoteInfo> = request.notes.into_iter().map(Into::into).collect();
    anyhow::ensure!(
        (1..=5).contains(&notes.len()),
        "delegation requires one to five notes"
    );
    let conn = handle.db.conn();
    queries::require_bundle_notes(
        &conn,
        &request.round_id,
        &wallet,
        request.bundle_index,
        &notes,
    )?;
    let fields = queries::load_delegation_submission_data(
        &conn,
        &request.round_id,
        &wallet,
        request.bundle_index,
    )?;
    anyhow::ensure!(!fields.proof.is_empty(), "stored successful proof is empty");
    let authority =
        queries::load_zkp2_inputs(&conn, &request.round_id, &wallet, request.bundle_index)?;
    let van = super::capability::van_commitment(
        &hotkey,
        &request.round_id,
        authority.total_note_value,
        &authority.gov_comm_rand,
    )?;
    anyhow::ensure!(
        van == fields.gov_comm,
        "hotkey does not match persisted delegation commitment"
    );

    // Bind the FVK to the setup's randomized verification key through the supported Orchard API.
    let fvk_bytes = request
        .fvk
        .as_slice()
        .try_into()
        .map_err(|_| anyhow!("invalid full viewing key length"))?;
    let fvk = orchard::keys::FullViewingKey::from_bytes(fvk_bytes)
        .ok_or_else(|| anyhow!("invalid full viewing key"))?;
    let alpha = Option::<pallas::Scalar>::from(pallas::Scalar::from_repr(signing.alpha))
        .ok_or_else(|| anyhow!("invalid persisted delegation randomizer"))?;
    let ak = orchard::keys::SpendValidatingKey::from(fvk);
    let rk = ak.randomize(&alpha);
    let rk_bytes: [u8; 32] = (&rk).into();
    anyhow::ensure!(
        rk_bytes.as_slice() == fields.rk,
        "full viewing key does not match persisted delegation key"
    );

    let vote_round_id = base(&hex::decode(&round.vote_round_id)?)?;
    let nullifiers = fields
        .gov_nullifiers
        .iter()
        .map(|bytes| base(bytes))
        .collect::<anyhow::Result<Vec<_>>>()?;
    let gov_nullifiers = nullifiers
        .try_into()
        .map_err(|_| anyhow!("stored delegation must have five nullifiers"))?;
    let nf_signed = orchard::note::Nullifier::from_inner(base(&fields.nf_signed)?);
    let instance = voting_circuits::delegation::Instance::from_parts(
        nf_signed,
        rk,
        base(&fields.cmx_new)?,
        base(&fields.gov_comm)?,
        vote_round_id,
        base(&round.nc_root)?,
        base(&round.nullifier_imt_root)?,
        gov_nullifiers,
        voting_circuits::delegation::derive_nullifier_domain(vote_round_id),
    )?;
    Ok(Some(JsonDelegationProofResult {
        proof: fields.proof,
        public_inputs: instance
            .to_halo2_instance()
            .iter()
            .map(|value| value.to_repr().to_vec())
            .collect(),
        nf_signed: fields.nf_signed,
        cmx_new: fields.cmx_new,
        gov_nullifiers: fields.gov_nullifiers,
        van_comm: fields.gov_comm,
        rk: fields.rk,
    }))
}

fn base(bytes: &[u8]) -> anyhow::Result<pallas::Base> {
    let encoded = bytes
        .try_into()
        .map_err(|_| anyhow!("stored field must be 32 bytes"))?;
    Option::<pallas::Base>::from(pallas::Base::from_repr(encoded))
        .ok_or_else(|| anyhow!("stored field is not canonical"))
}

/// Read a completed proof for an exact persisted setup and validated proof input aggregate.
/// Returns JSON `null` only for an unproved bundle; corruption or mismatched inputs fail closed.
/// The hotkey secret is borrowed separately and is never included in JSON or logged.
///
/// # Safety
/// `db` must be a live voting handle. Every byte pointer must be valid for its length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_get_completed_delegation_proof(
    db: *mut VotingDatabaseHandle,
    request_json: *const u8,
    request_json_len: usize,
    hotkey_secret: *const u8,
    hotkey_secret_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let db = AssertUnwindSafe(db);
    let result = catch_panic(|| {
        let handle =
            unsafe { db.as_ref() }.ok_or_else(|| anyhow!("VotingDatabaseHandle is null"))?;
        let request =
            serde_json::from_slice(unsafe { bytes_from_ptr(request_json, request_json_len) }?)?;
        let secret = unsafe { bytes_from_ptr(hotkey_secret, hotkey_secret_len) }?;
        let proof = read_completed_proof(handle, request, secret)?;
        json_to_boxed_slice(&proof)
    });
    crate::unwrap_exc_or_null(result)
}

#[cfg(test)]
mod tests {
    use super::super::{capability::van_commitment, db::zcashlc_voting_db_free, test_helpers};
    use super::*;
    use zcash_voting::backend::orchard;
    use zcash_voting::backend::pasta_curves::{group::ff::PrimeField, pallas};
    use zcash_voting::storage::queries;

    const ROUND: &str = "0100000000000000000000000000000000000000000000000000000000000000";

    struct Fixture {
        db: *mut VotingDatabaseHandle,
        secret: Vec<u8>,
        fvk: Vec<u8>,
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            unsafe { zcashlc_voting_db_free(self.db) };
        }
    }

    impl Fixture {
        fn new(completed: bool) -> Self {
            let db = test_helpers::open_memory_db();
            test_helpers::insert_round_and_bundle(db, ROUND);
            let secret = test_helpers::valid_stored_secret();
            let spending_key = orchard::keys::SpendingKey::from_bytes([1; 32]).unwrap();
            let fvk = orchard::keys::FullViewingKey::from(&spending_key)
                .to_bytes()
                .to_vec();
            let hotkey =
                voting::VotingHotkey::from_stored_secret(&secret, voting::Network::Mainnet)
                    .unwrap();
            let van = van_commitment(&hotkey, ROUND, 13_000_000, &[0; 32]).unwrap();
            let handle = unsafe { &*db };
            let conn = handle.db.conn();
            let mut effects = vec![0; voting::tx1::TX1_EFFECTS_LEN];
            effects[0] = voting::tx1::TX1_EFFECTS_VERSION;
            queries::store_delegation_data(
                &conn,
                ROUND,
                "wallet",
                0,
                &[0; 32],
                &[],
                &[0; 32],
                &[],
                &[0; 32],
                &[0; 32],
                &[0; 32],
                &[0; 32],
                &[0; 32],
                &van,
                13_000_000,
                0,
                &[],
                &[9; 32],
                &effects,
            )
            .unwrap();
            if completed {
                let ak = orchard::keys::SpendValidatingKey::from(
                    orchard::keys::FullViewingKey::from(&spending_key),
                );
                let rk: [u8; 32] = (&ak.randomize(&pallas::Scalar::from(0))).into();
                queries::store_proof(&conn, ROUND, "wallet", 0, &[1, 2, 3]).unwrap();
                queries::store_proof_result_fields(
                    &conn,
                    ROUND,
                    "wallet",
                    0,
                    &rk,
                    &vec![vec![0; 32]; 5],
                    &[0; 32],
                    &[0; 32],
                )
                .unwrap();
            }
            drop(conn);
            Self { db, secret, fvk }
        }

        fn request(&self) -> ProofReadbackRequest {
            ProofReadbackRequest {
                round_id: ROUND.to_string(),
                bundle_index: 0,
                notes: (0..1)
                    .map(|position| JsonNoteInfo {
                        commitment: vec![1; 32],
                        nullifier: vec![2; 32],
                        value: 13_000_000,
                        position,
                        diversifier: vec![0; 11],
                        rho: vec![3; 32],
                        rseed: vec![4; 32],
                        scope: 0,
                        ufvk_str: String::new(),
                    })
                    .collect(),
                fvk: self.fvk.clone(),
                seed_fingerprint: [4; 32],
                account_index: 0,
                round_name: "fixture".to_string(),
                snapshot_height: 123,
                pczt_sighash: vec![9; 32],
            }
        }

        fn read(
            &self,
            request: ProofReadbackRequest,
        ) -> anyhow::Result<Option<JsonDelegationProofResult>> {
            read_completed_proof(unsafe { &*self.db }, request, &self.secret)
        }
    }

    #[test]
    fn completed_proof_reuses_persisted_bytes_and_reconstructs_all_public_inputs() {
        let fixture = Fixture::new(true);
        let result = fixture
            .read(fixture.request())
            .unwrap()
            .expect("stored completed proof");
        assert_eq!(result.proof, [1, 2, 3]);
        assert_eq!(result.public_inputs.len(), 14);
        assert_eq!(result.public_inputs[0], vec![0; 32]);
        assert_eq!(result.public_inputs[5], pallas::Base::from(1).to_repr());
        assert_eq!(result.public_inputs[6], vec![8; 32]);
        assert_eq!(result.public_inputs[7], vec![9; 32]);
    }

    #[test]
    fn unproved_bundle_is_an_explicit_cache_miss() {
        let fixture = Fixture::new(false);
        assert!(fixture.read(fixture.request()).unwrap().is_none());
    }

    #[test]
    fn durable_reuse_rejects_changed_notes_keys_snapshot_and_setup() {
        let fixture = Fixture::new(true);
        let mut changed = fixture.request();
        changed.notes[0].value += 1;
        assert!(fixture.read(changed).is_err(), "changed notes");
        let mut changed = fixture.request();
        let other = orchard::keys::SpendingKey::from_bytes([2; 32]).unwrap();
        changed.fvk = orchard::keys::FullViewingKey::from(&other)
            .to_bytes()
            .to_vec();
        assert!(
            fixture
                .read(changed)
                .unwrap_err()
                .to_string()
                .contains("full viewing key")
        );
        let secret = test_helpers::valid_stored_secret();
        assert!(
            read_completed_proof(unsafe { &*fixture.db }, fixture.request(), &secret)
                .unwrap_err()
                .to_string()
                .contains("hotkey")
        );
        let mut changed = fixture.request();
        changed.snapshot_height += 1;
        assert!(fixture.read(changed).is_err(), "changed snapshot");
        let mut changed = fixture.request();
        changed.pczt_sighash[0] ^= 1;
        assert!(fixture.read(changed).is_err(), "changed PCZT");
    }

    #[test]
    fn corrupt_successful_proof_is_an_error_not_a_cache_miss() {
        let fixture = Fixture::new(true);
        let handle = unsafe { &*fixture.db };
        handle
            .db
            .conn()
            .execute("UPDATE bundles SET gov_nullifiers_blob = X'00'", [])
            .unwrap();
        assert!(fixture.read(fixture.request()).is_err());
    }

    #[test]
    fn submitted_bundle_without_proof_is_not_reproved() {
        let fixture = Fixture::new(false);
        let handle = unsafe { &*fixture.db };
        handle
            .db
            .conn()
            .execute("UPDATE bundles SET delegation_tx_hash = 'accepted'", [])
            .unwrap();
        assert!(fixture.read(fixture.request()).is_err());
    }
}
