//! Sidecar voting-database handle owned by the SDK, and the store-level
//! operations Swift drives outside a round session.
//!
//! One [`VotingDatabaseHandle`] is opened per sidecar file and held for the
//! app's lifetime. It keeps the *unscoped* root connection plus the wallet id
//! Swift sets after opening, and hands out a scoped `VotingDb` per call: the
//! crate scopes rows per wallet, so nothing below this module may run against
//! a handle whose wallet id is unset. Scoping is cheap — a scoped handle
//! clones the root's connection handle rather than opening one — so there is
//! nothing to cache and no lifetime to manage beyond this one.
//!
//! Everything here is synchronous and short: these are the reads and the
//! destructive edits a screen performs directly. Driving a round (proving,
//! submission, helper delivery) belongs to the session, not to this module;
//! the one exception is [`sync_vote_tree`], which the crate implements as a
//! blocking call over its own direct transport (spec D12).

use std::sync::{Arc, Mutex, MutexGuard};

use zcash_voting::storage::VotingDb;

use super::errors::{VotingResultExt, internal, invalid_input};
use super::helpers::voting_network;
use super::wire::{KeystoneSignatureRecordDto, RoundSummaryDto};

/// Opaque handle over one open voting sidecar database.
///
/// `root` is deliberately never used for a wallet-scoped read or write: it
/// carries no wallet id, and `zcash_voting` panics rather than guesses when a
/// scoped operation runs without one. Callers go through [`Self::scoped`],
/// which fails with typed JSON while the wallet id is still unset.
pub struct VotingDatabaseHandle {
    /// The unscoped connection to the sidecar. Every scoped handle derived
    /// from it shares this one connection, so writers reached through this
    /// handle serialize on it instead of contending for the file. A second
    /// `zcashlc_voting_db_open` on the same path gets its own connection;
    /// the SDK opens one handle per sidecar and keeps it.
    root: Arc<VotingDb>,
    /// The wallet whose rows this handle reads and writes. `None` until Swift
    /// calls `zcashlc_voting_set_wallet_id`; a `Mutex` because the handle is
    /// shared across threads and the id can be set again on wallet switch.
    wallet_id: Mutex<Option<String>>,
    /// The voting identity of `network_id`, fixed once at open time because
    /// `zcash_voting` persists each round's network.
    // Read by the session, which lands in a later change.
    #[allow(dead_code)]
    pub(super) network: zcash_voting::Network,
    /// The SDK's numeric network id, kept so wallet-database and key
    /// derivation calls resolve the same (possibly custom) chain the handle
    /// was opened for.
    // Read by the session, which lands in a later change.
    #[allow(dead_code)]
    pub(super) network_id: u32,
}

impl VotingDatabaseHandle {
    /// Open (or create) the sidecar at `path` for `network_id`.
    ///
    /// The network is resolved once, here, so no later call has to re-check
    /// it: a handle cannot exist for a network that does not. `VotingDb::open`
    /// migrates an existing schema-13 sidecar in place.
    pub(super) fn open(path: &str, network_id: u32) -> anyhow::Result<Self> {
        let network = voting_network(network_id)?;
        let root = VotingDb::open(path).ffi()?;
        Ok(VotingDatabaseHandle {
            root: Arc::new(root),
            wallet_id: Mutex::new(None),
            network,
            network_id,
        })
    }

    /// Bind every subsequent operation to `wallet_id`.
    ///
    /// An empty id is refused here rather than at the first scoped call, so a
    /// host that forgot to supply one learns at the point of the mistake.
    pub(super) fn set_wallet_id(&self, wallet_id: &str) -> anyhow::Result<()> {
        if wallet_id.is_empty() {
            return Err(invalid_input("wallet id must not be empty"));
        }
        *self.wallet_id_slot()? = Some(wallet_id.to_string());
        Ok(())
    }

    /// The wallet id bound to this handle.
    pub(super) fn wallet_id(&self) -> anyhow::Result<String> {
        self.wallet_id_slot()?.clone().ok_or_else(|| {
            invalid_input("wallet id is not set; call zcashlc_voting_set_wallet_id first")
        })
    }

    /// A handle on the same connection, scoped to this handle's wallet.
    pub(super) fn scoped(&self) -> anyhow::Result<Arc<VotingDb>> {
        let wallet_id = self.wallet_id()?;
        Ok(Arc::new(self.root.scoped(&wallet_id).ffi()?))
    }

    fn wallet_id_slot(&self) -> anyhow::Result<MutexGuard<'_, Option<String>>> {
        self.wallet_id
            .lock()
            .map_err(|_| internal("voting wallet id lock is poisoned"))
    }
}

/// Every round this wallet has in the sidecar, newest first.
pub(super) fn list_rounds(h: &VotingDatabaseHandle) -> anyhow::Result<Vec<RoundSummaryDto>> {
    Ok(h.scoped()?
        .list_rounds()
        .ffi()?
        .into_iter()
        .map(RoundSummaryDto::from)
        .collect())
}

/// The plan for `round_id` against the authenticated `proposal_ids`.
///
/// The roster is the caller's: `zcash_voting` classifies stored ballot intents
/// against exactly the proposals passed here, so an intent outside the
/// authenticated roster is reported as withheld rather than acted on.
pub(super) fn round_plan(
    h: &VotingDatabaseHandle,
    round_id: &str,
    proposal_ids: &[u32],
) -> anyhow::Result<zcash_voting::wire::RoundPlanView> {
    let db = h.scoped()?;
    let plan = zcash_voting::session::resume_plan(&db, round_id, proposal_ids).ffi()?;
    zcash_voting::wire::RoundPlanView::try_from(plan).ffi()
}

/// Rounds of this wallet with helper-share work still outstanding (spec D13).
pub(super) fn pending_share_rounds(
    h: &VotingDatabaseHandle,
) -> anyhow::Result<Vec<zcash_voting::wire::PendingShareRoundView>> {
    // The crate's multi-account entry point re-scopes per wallet id and
    // ignores the handle's own, so the id is passed explicitly. The SDK holds
    // one handle per wallet, so that list is always this wallet alone.
    let wallet_id = h.wallet_id()?;
    let db = h.scoped()?;
    Ok(
        zcash_voting::share::pending_rounds_for_accounts(&db, &[wallet_id.as_str()])
            .ffi()?
            .into_iter()
            .map(zcash_voting::wire::PendingShareRoundView::from)
            .collect(),
    )
}

/// Sync the round's vote-commitment tree from `node_url`, returning the height
/// synced to.
///
/// The crate resolves the transport itself (spec D12): it reuses the wallet's
/// tree client that already holds this round, whatever transport that client
/// was built on, and otherwise opens one over its own direct transport. There
/// is no route argument here by design — vote-tree traffic is not the chain
/// and helper traffic the session's route governs.
pub(super) fn sync_vote_tree(
    h: &VotingDatabaseHandle,
    round_id: &str,
    node_url: &str,
) -> anyhow::Result<u32> {
    let db = h.scoped()?;
    zcash_voting::precompute::sync_vote_tree(&db, round_id, node_url).ffi()
}

/// Drop the cached vote-tree state for one round.
///
/// An empty `round_id` is the crate's wallet-wide reset, not a no-op: it
/// forgets every round's cached tree state for this wallet. Callers that mean
/// one round must pass its id.
pub(super) fn reset_vote_tree(h: &VotingDatabaseHandle, round_id: &str) -> anyhow::Result<()> {
    let db = h.scoped()?;
    zcash_voting::precompute::reset_vote_tree(&db, round_id).ffi()
}

/// Return a round to a re-runnable state after an interrupted setup.
///
/// Drops the cached tree state and clears the locally prepared *unsigned*
/// delegation setup fields, so an abandoned Keystone request can be rebuilt.
/// Proved or submitted bundles, imported capabilities and stored signatures
/// survive: this is a retry, not a deletion.
///
/// An empty `round_id` resets only the cached tree state, wallet-wide, and
/// clears no persisted column — the crate's guard, which is why this calls the
/// crate's combined entry point rather than its two halves.
pub(super) fn reset_session_state(h: &VotingDatabaseHandle, round_id: &str) -> anyhow::Result<()> {
    let db = h.scoped()?;
    zcash_voting::precompute::reset_voting_session_state(&db, round_id).ffi()
}

/// Delete one round.
///
/// The default refuses once part of the round has reached the network, because
/// its stored setup is then the only thing that can reproduce its voting
/// weight. `discard_recovery` is the deliberate abandonment path past that
/// refusal, and the weight does not come back.
pub(super) fn delete_round(
    h: &VotingDatabaseHandle,
    round_id: &str,
    discard_recovery: bool,
) -> anyhow::Result<()> {
    let db = h.scoped()?;
    if discard_recovery {
        db.delete_round_discarding_recovery(round_id).ffi()
    } else {
        db.delete_round(round_id).ffi()
    }
}

/// Drop bundle rows at index `>= keep_count`, returning how many were deleted.
pub(super) fn delete_skipped_bundles(
    h: &VotingDatabaseHandle,
    round_id: &str,
    keep_count: u32,
) -> anyhow::Result<u64> {
    h.scoped()?
        .delete_skipped_bundles(round_id, keep_count)
        .ffi()
}

/// Forget a bundle's combined-cast rejection streak, returning whether one was
/// recorded.
///
/// The block is advisory — the wallet stops re-proving a delegation the chain
/// keeps refusing — so this is the voter's explicit "the cause is fixed".
pub(super) fn retry_blocked_combined_cast(
    h: &VotingDatabaseHandle,
    round_id: &str,
    bundle_index: u32,
) -> anyhow::Result<bool> {
    h.scoped()?
        .retry_blocked_combined_cast(round_id, bundle_index)
        .ffi()
}

/// Clear the stored ballot intent for each of `proposal_ids`.
///
/// Applied one proposal at a time, as the crate exposes it: a proposal whose
/// vote the chain lifecycle already owns fails, and the call stops there
/// rather than clearing the rest behind a partial success.
pub(super) fn clear_ballot_intents(
    h: &VotingDatabaseHandle,
    round_id: &str,
    proposal_ids: &[u32],
) -> anyhow::Result<()> {
    let db = h.scoped()?;
    for &proposal_id in proposal_ids {
        db.clear_ballot_intent(round_id, proposal_id).ffi()?;
    }
    Ok(())
}

/// The Keystone signatures stored for a round, for `KeystoneSignatureSource::Stored` reuse.
pub(super) fn keystone_signatures(
    h: &VotingDatabaseHandle,
    round_id: &str,
) -> anyhow::Result<Vec<KeystoneSignatureRecordDto>> {
    Ok(h.scoped()?
        .get_keystone_signatures(round_id)
        .ffi()?
        .into_iter()
        .map(KeystoneSignatureRecordDto::from)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voting::test_support::{hex_round_id, open_memory_store, synthetic_round_params};

    #[test]
    fn open_rejects_unknown_network_and_requires_wallet_id() {
        assert!(VotingDatabaseHandle::open(":memory:", 99).is_err());
        let handle = VotingDatabaseHandle::open(":memory:", crate::NETWORK_ID_MAINNET).unwrap();
        assert!(
            handle.scoped().is_err(),
            "scoped without wallet id must fail"
        );
        handle.set_wallet_id("w").unwrap();
        assert!(handle.scoped().is_ok());
    }

    #[test]
    fn list_rounds_reflects_created_rounds() {
        let handle = open_memory_store(crate::NETWORK_ID_MAINNET, "w");
        assert!(list_rounds(&handle).unwrap().is_empty());
        let params = synthetic_round_params(0x11, 123);
        handle
            .scoped()
            .unwrap()
            .ensure_round(zcash_voting::Network::Mainnet, &params, None)
            .unwrap();
        let rounds = list_rounds(&handle).unwrap();
        assert_eq!(rounds.len(), 1);
        assert_eq!(rounds[0].round_id, hex_round_id(0x11));
        assert_eq!(rounds[0].snapshot_height, 123);
    }

    /// `needs_bundle_setup` is narrower than "this round has no bundles": the
    /// crate raises it only for a round that *holds a ballot choice* and has
    /// no bundle rows to cast it into, which is the one ordering a host can
    /// resolve. A round nobody has decided on yet owes a draft instead, so
    /// both sides of that distinction are asserted here.
    #[test]
    fn round_plan_reports_bundle_setup_once_a_ballot_choice_exists() {
        let handle = open_memory_store(crate::NETWORK_ID_MAINNET, "w");
        let params = synthetic_round_params(0x12, 123);
        let db = handle.scoped().unwrap();
        db.ensure_round(zcash_voting::Network::Mainnet, &params, None)
            .unwrap();

        let plan = round_plan(&handle, &hex_round_id(0x12), &[1, 2]).unwrap();
        assert_eq!(plan.round_id, hex_round_id(0x12));
        assert!(!plan.needs_bundle_setup);
        assert!(plan.needs_draft_setup);

        db.set_ballot_intent(
            &hex_round_id(0x12),
            1,
            zcash_voting::session::Decision::Choice(0),
            2,
        )
        .unwrap();

        let plan = round_plan(&handle, &hex_round_id(0x12), &[1, 2]).unwrap();
        assert_eq!(plan.round_id, hex_round_id(0x12));
        assert!(plan.needs_bundle_setup);
    }

    /// An id the sidecar has never seen is not an error: planning reads a
    /// round's rows, and a round with none plans as an empty round that owes a
    /// draft. What must hold is that the *error* path is decodable JSON rather
    /// than a panic or a bare message, so a roster the crate refuses is
    /// checked alongside it.
    #[test]
    fn round_plan_for_unknown_round_is_an_idle_plan_and_a_bad_roster_is_a_json_error() {
        let handle = open_memory_store(crate::NETWORK_ID_MAINNET, "w");

        let plan = round_plan(&handle, &hex_round_id(0xfe), &[1]).unwrap();
        assert_eq!(plan.round_id, hex_round_id(0xfe));
        assert!(plan.next_steps.is_empty());
        assert!(plan.needs_draft_setup);

        let err = round_plan(&handle, &hex_round_id(0xfe), &[0]).unwrap_err();
        let view: zcash_voting::VotingErrorView =
            serde_json::from_str(&err.to_string()).expect("json error");
        assert_eq!(serde_json::to_value(view.kind).unwrap(), "invalid_input");
        assert!(!view.message.is_empty());
    }

    /// `share::pending_rounds_for_accounts` silently drops empty wallet ids,
    /// so a handle that failed to plumb one through would answer `[]` and look
    /// healthy. Asserting that an unbound handle *fails* is what distinguishes
    /// "no pending rounds" from "asked about no wallet".
    #[test]
    fn pending_share_rounds_requires_a_bound_wallet() {
        let handle = VotingDatabaseHandle::open(":memory:", crate::NETWORK_ID_MAINNET).unwrap();
        let err = pending_share_rounds(&handle).unwrap_err();
        let view: zcash_voting::VotingErrorView =
            serde_json::from_str(&err.to_string()).expect("json error");
        assert_eq!(serde_json::to_value(view.kind).unwrap(), "invalid_input");
    }

    #[test]
    fn delete_round_removes_it_and_pending_share_rounds_is_empty() {
        let handle = open_memory_store(crate::NETWORK_ID_MAINNET, "w");
        let params = synthetic_round_params(0x13, 123);
        handle
            .scoped()
            .unwrap()
            .ensure_round(zcash_voting::Network::Mainnet, &params, None)
            .unwrap();
        assert!(pending_share_rounds(&handle).unwrap().is_empty());
        delete_round(&handle, &hex_round_id(0x13), false).unwrap();
        assert!(list_rounds(&handle).unwrap().is_empty());
    }

    #[test]
    fn keystone_signatures_and_clear_intents_on_fresh_round() {
        let handle = open_memory_store(crate::NETWORK_ID_MAINNET, "w");
        let params = synthetic_round_params(0x14, 123);
        handle
            .scoped()
            .unwrap()
            .ensure_round(zcash_voting::Network::Mainnet, &params, None)
            .unwrap();
        assert!(
            keystone_signatures(&handle, &hex_round_id(0x14))
                .unwrap()
                .is_empty()
        );
        clear_ballot_intents(&handle, &hex_round_id(0x14), &[1]).unwrap();
        reset_session_state(&handle, &hex_round_id(0x14)).unwrap();
    }
}
