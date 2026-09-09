//! Witness extraction from the ordinary wallet, across the voting backend boundary.
//!
//! Mirrors zcash_voting 3.1.0 `witness::generate_note_witnesses`'s snapshot
//! validation. Its WalletDb is a different concrete backend; only validated
//! primitive WitnessData enters the native voting verifier and storage.

use anyhow::{Result, ensure};
use incrementalmerkletree::{Position, frontier::CommitmentTree};
use orchard::tree::MerkleHashOrchard;
use prost::Message;
use std::borrow::Borrow;
use zcash_client_backend::proto::service::TreeState;
use zcash_client_sqlite::WalletDb;
use zcash_protocol::consensus::{BlockHeight, BranchId, Parameters};
use zcash_voting::{
    NoteInfo, WitnessData,
    storage::{VotingDb, queries},
};

pub(super) fn generate<C, P, CL, R>(
    db: &VotingDb,
    round_id: &str,
    notes: &[NoteInfo],
    wallet_db: &WalletDb<C, P, CL, R>,
) -> Result<Vec<WitnessData>>
where
    C: Borrow<rusqlite::Connection>,
    P: Parameters,
{
    let (bytes, params, network) = {
        let wallet_id = db.wallet_id();
        let conn = db.conn();
        let bytes = queries::load_tree_state(&conn, round_id, &wallet_id)?;
        let (params, network) =
            queries::load_round_params_with_network(&conn, round_id, &wallet_id)?;
        (bytes, params, network)
    };
    ensure!(
        wallet_db.params().network_type() == network.network_type(),
        "wallet DB network does not match stored round network"
    );
    let height = BlockHeight::from_u32(params.snapshot_height.try_into()?);
    // The native 3.1 protocol selector accepts exactly NU6.3 / Ironwood.
    ensure!(
        BranchId::for_height(&network, height) == BranchId::Nu6_3,
        "zcash voting only supports Ironwood / NU6.3 shielded voting notes"
    );
    let tree_state = TreeState::decode(bytes.as_slice())?;
    ensure!(
        tree_state.height == params.snapshot_height,
        "cached TreeState height does not match round snapshot_height"
    );
    let tree: CommitmentTree<MerkleHashOrchard, { orchard::NOTE_COMMITMENT_TREE_DEPTH as u8 }> =
        tree_state.ironwood_tree()?;
    let root = tree.root().to_bytes().to_vec();
    ensure!(
        root == params.nc_root,
        "cached TreeState ironwood root does not match round nc_root"
    );
    let frontier = tree
        .to_frontier()
        .take()
        .ok_or_else(|| anyhow::anyhow!("empty ironwood frontier at snapshot height"))?;
    let positions = notes
        .iter()
        .map(|note| Position::from(note.position))
        .collect::<Vec<_>>();
    let paths =
        wallet_db.generate_ironwood_witnesses_at_historical_height(&positions, frontier, height)?;
    ensure!(
        paths.len() == notes.len(),
        "generated path count does not match voting notes"
    );
    let witnesses = paths
        .into_iter()
        .zip(notes)
        .map(|(path, note)| WitnessData {
            note_commitment: note.commitment.clone(),
            position: note.position,
            root: root.clone(),
            auth_path: path
                .path_elems()
                .iter()
                .map(|hash| hash.to_bytes().to_vec())
                .collect(),
        })
        .collect::<Vec<_>>();
    for witness in &witnesses {
        ensure!(
            zcash_voting::witness::verify_witness(witness)?,
            "native voting witness verification failed"
        );
    }
    Ok(witnesses)
}
