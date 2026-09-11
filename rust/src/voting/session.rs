//! Per-round voting session: executor, delegation pipeline, clients and
//! cancellation control, opened once per round and held for its lifetime.
//!
//! Everything a round needs that outlives one call lives here, because
//! `zcash_voting` binds it that way: the executor freezes the wallet scope and
//! the proposal roster at construction, the delegation pipeline freezes the
//! account and the lightwalletd anchor, and the chain client freezes the
//! endpoint fleet. Rebuilding them per call would re-validate all of that on
//! every screen tap and could not carry a cancellation signal across calls.
//!
//! [`VotingSession::open`] performs no network I/O. The PIR fleet only records
//! its endpoints, the chain client only validates its configuration, and the
//! helper client only holds a transport; nothing dials until a step runs. That
//! is what lets Swift open a session on the main thread and discover a bad
//! round configuration immediately rather than through a timeout.
//!
//! Traffic splits by kind (spec D12): chain and helper requests go through the
//! route chosen at open — Tor or direct, never falling back — while PIR and
//! vote-tree requests use the process-wide direct transport.

use std::sync::Arc;

use zeroize::Zeroizing;

use super::errors::{VotingResultExt, internal, invalid_input};
use super::route::SdkRoute;
use super::store::VotingDatabaseHandle;
use super::wallet_access::SdkWalletDbOpener;
use super::wire::{
    BallotIntentDto, BundleLayoutDto, EligibilityDto, SessionBindingDto, SessionInputsDto,
};

/// One open voting round: the crate objects that drive it, plus the inputs
/// they were built from.
///
/// Deliberately not `Debug`: it holds the round's voting hotkey secret, and a
/// derived formatter would print it. `SeedSpendAuthSigner` is not `Debug` for
/// the same reason.
// Constructed by the session FFI, which lands in a later change. The per-field
// allows below say which later change reads each field, so this one can go when
// the FFI lands without the rest turning into warnings.
#[allow(dead_code)]
pub struct VotingSession {
    /// A wallet-scoped handle on the sidecar, taken once at open.
    ///
    /// The executor and the pipeline each freeze their own handle over the
    /// same connection, so this one is never the thing they persist through;
    /// it is the session's own read handle.
    // Consumed by the round driver, which lands in a later change.
    #[allow(dead_code)]
    database: Arc<zcash_voting::storage::VotingDb>,
    /// Runs the round's steps. Owns the round binding — id, network, roster
    /// and hotkey secret — which is why planning goes through it rather than
    /// through a roster this struct would otherwise have to keep in step.
    executor: zcash_voting::RoundExecutor<Arc<zcash_voting::HyperTransport<SdkRoute>>>,
    /// Round setup, note selection, bundle layout and delegation proving.
    ///
    /// `Arc` because the round driver hands it to the crate as a
    /// `DelegationDriver` while this session keeps using it.
    pipeline: Arc<zcash_voting::DelegationPipeline<SdkWalletDbOpener>>,
    /// The PIR fleet delegation precompute queries, over the shared direct
    /// transport (spec D12).
    // Consumed by the round driver, which lands in a later change.
    #[allow(dead_code)]
    pir: Arc<zcash_voting::PirFleet>,
    /// The helper client, kept beside the executor's clone: the two share one
    /// health tracker, so share tracking observes what the round's deliveries
    /// learned about each helper.
    // Consumed by share tracking, which lands in a later change.
    #[allow(dead_code)]
    helper_client: zcash_voting::HelperClient,
    /// Cancellation and the host operation epoch, shared with every bounded
    /// pass this session starts.
    control: zcash_voting::ChainSubmissionControl,
    /// The inputs this session was opened with, kept because a step needs the
    /// ones the crate does not capture at construction: the helper fleet, the
    /// vote-tree nodes and the round's timing.
    // Consumed by the round driver, which lands in a later change.
    #[allow(dead_code)]
    inputs: SessionInputsDto,
    /// The voting identity of the store this session was opened from.
    // Consumed by the round driver, which lands in a later change.
    #[allow(dead_code)]
    network: zcash_voting::Network,
    /// The SDK's numeric network id, kept so wallet-database and key
    /// derivation calls resolve the same (possibly custom) chain.
    // Consumed by the software signer, which lands in a later change.
    #[allow(dead_code)]
    network_id: u32,
    /// The round this session is bound to, as canonical lowercase hex.
    round_id: String,
    /// The round's voting hotkey secret, when one was bound.
    ///
    /// Held separately from the executor's copy because the delegation stages
    /// reconstruct the hotkey on the proving thread; `Zeroizing` so neither
    /// copy outlives the session in memory.
    // Consumed by the round driver, which lands in a later change.
    #[allow(dead_code)]
    hotkey_secret: Option<Zeroizing<Vec<u8>>>,
}

// Consumed by the session FFI, which lands in a later change.
#[allow(dead_code)]
impl VotingSession {
    /// Opens a session for one round over `store`'s sidecar.
    ///
    /// Validation runs front to back and fails on the first problem, so a host
    /// learns about a malformed round id before a malformed anchor and about a
    /// malformed anchor before an unusable PIR layout. Nothing here reaches the
    /// network: every failure is a decision about the arguments.
    ///
    /// `epoch` is the host's operation epoch at open. Swift bumps it whenever
    /// the user switches wallets or leaves the flow, and every bounded pass
    /// started under an older epoch stops at its next boundary.
    pub(super) fn open(
        store: &VotingDatabaseHandle,
        inputs: SessionInputsDto,
        binding: SessionBindingDto,
        route: SdkRoute,
        epoch: u64,
    ) -> anyhow::Result<Self> {
        let database = store.scoped()?;

        let round_params = inputs.round_params.clone().into_params();
        // Checked here as well as inside the pipeline constructor, so a bad
        // round id is reported as itself rather than as whatever the anchor
        // decode or the branch-id lookup makes of it.
        zcash_voting::validate_round_params(&round_params).ffi()?;

        // The bytes are lightwalletd output the host fetched and passed
        // through, so a decode failure is the host's input, not this SDK's
        // invariant.
        let tree_state =
            <zcash_client_backend::proto::service::TreeState as prost::Message>::decode(
                inputs.anchor_tree_state.as_slice(),
            )
            .map_err(|e| {
                invalid_input(format!(
                    "anchor tree state is not a TreeState protobuf: {e}"
                ))
            })?;

        // Resolves the consensus branch id active at the snapshot height, so
        // delegation PCZTs are built for the same upgrade the notes were
        // selected under.
        let lwd = zcash_voting::delegate::DelegationLwdInputs::from_anchor_tree_state(
            store.network,
            round_params.clone(),
            &inputs.round_name,
            &tree_state,
        )
        .ffi()?;

        let hotkey = binding
            .hotkey_secret
            .as_deref()
            .map(|secret| zcash_voting::VotingHotkey::from_stored_secret(secret, store.network))
            .transpose()
            .ffi()?;

        // Spec D6: the existing five-note policy with privacy trimming off.
        // A round that already persisted a plan keeps its stored policy — the
        // crate treats that one as authoritative — so this seeds new rounds only.
        let bundle_policy = zcash_voting::BundlePolicy::default().with_max_privacy_bundles(None);

        let pipeline = Arc::new(
            zcash_voting::DelegationPipeline::new(
                Arc::clone(&database),
                SdkWalletDbOpener::new(&inputs.wallet_db_path, store.network_id),
                lwd,
                &inputs.account_uuid,
                hotkey,
                bundle_policy,
                None,
            )
            .ffi()?,
        );

        // Constructing the fleet validates the layout and normalizes the
        // endpoint list; it connects to nothing.
        let pir = Arc::new(
            zcash_voting::PirFleet::new(
                &inputs.pir_endpoints,
                inputs.pir_layout.clone().into_layout(),
                super::runtime::direct_transport(),
            )
            .ffi()?,
        );

        let transport = super::route::routed_transport(route);
        let helper_transport: Arc<dyn zcash_voting::HelperTransport> = transport.clone();
        let helper_client = zcash_voting::HelperClient::new(
            helper_transport,
            zcash_voting::HelperHealth::default(),
        );

        let executor = zcash_voting::RoundExecutor::with_transport(
            Arc::clone(&database),
            Arc::clone(&transport),
            zcash_voting::ChainSubmissionClientConfig::for_network(
                store.network,
                inputs.chain_endpoints.clone(),
            ),
            // The executor's clone shares this client's health tracker, so a
            // helper the round found unreachable stays cooled down for share
            // tracking too.
            helper_client.clone(),
        )
        // A `ChainSubmissionFailure` is not a `VotingError`, so it cannot go
        // through `ffi()`; its kinds describe submission outcomes, and nothing
        // construction can fail on is one the host can act on differently.
        .map_err(|e| internal(format!("{e}")))?
        .with_binding(zcash_voting::RoundBinding {
            round_id: round_params.vote_round_id.clone(),
            network: store.network,
            proposals: binding
                .roster
                .iter()
                .map(|entry| zcash_voting::ProposalRosterEntry {
                    proposal_id: entry.proposal_id,
                    num_options: entry.num_options,
                })
                .collect(),
            hotkey_secret: binding.hotkey_secret.clone().map(Zeroizing::new),
        })
        .ffi()?
        // Vote-tree sync is not chain or helper traffic, so it keeps the
        // shared direct transport whatever route this session chose (spec D12).
        .with_tree_transport(super::runtime::direct_transport());

        let control = zcash_voting::ChainSubmissionControl::new(epoch);

        Ok(VotingSession {
            database,
            executor,
            pipeline,
            pir,
            helper_client,
            control,
            round_id: round_params.vote_round_id,
            network: store.network,
            network_id: store.network_id,
            hotkey_secret: binding.hotkey_secret.map(Zeroizing::new),
            inputs,
        })
    }

    /// The round's resume plan, against the roster this session is bound to.
    ///
    /// Planned through the executor rather than by calling
    /// `zcash_voting::session::resume_plan` with a roster held here as well:
    /// the executor already owns the validated roster, and
    /// [`Self::set_ballot_intents`] returns the plan the executor computes, so
    /// routing both through it is what keeps the two answers the same one. The
    /// executor also refuses a round the sidecar stores under another network,
    /// which the bare `resume_plan` does not check.
    pub(super) fn plan(&self) -> anyhow::Result<zcash_voting::wire::RoundPlanView> {
        let plan = self.executor.plan().ffi()?;
        zcash_voting::wire::RoundPlanView::try_from(plan).ffi()
    }

    /// Records ballot decisions and returns the refreshed plan.
    ///
    /// The whole batch is resolved against the bound roster before anything is
    /// written, so a decision for a proposal outside the authenticated roster
    /// leaves durable intent untouched.
    pub(super) fn set_ballot_intents(
        &self,
        intents: Vec<BallotIntentDto>,
    ) -> anyhow::Result<zcash_voting::wire::RoundPlanView> {
        let intents = intents
            .into_iter()
            .map(BallotIntentDto::into_intent)
            .collect::<Vec<_>>();
        let plan = self.executor.set_ballot_intents(&intents).ffi()?;
        zcash_voting::wire::RoundPlanView::try_from(plan).ffi()
    }

    /// Creates the round row, then its delegation bundle rows.
    ///
    /// The round row is created before note selection runs, so a wallet with
    /// nothing eligible still leaves a round the host can plan and show. The
    /// explicit `ensure_round` is idempotent and duplicates what
    /// `setup_bundles` does first internally; it states that ordering at this
    /// boundary rather than depending on it silently.
    pub(super) fn setup_bundles(&self) -> anyhow::Result<BundleLayoutDto> {
        self.pipeline.ensure_round().ffi()?;
        let layout = self.pipeline.setup_bundles().ffi()?;
        Ok(BundleLayoutDto {
            bundle_count: layout.bundle_count,
            eligible_weight: layout.eligible_weight,
            dropped_count: layout.dropped_count,
            privacy_trim_dropped_bundles: layout.privacy_trim_dropped_bundles,
            privacy_trim_dropped_notes: layout.privacy_trim_dropped_notes,
        })
    }

    /// Whether the account can vote in this round, without persisting anything.
    pub(super) fn eligibility(&self) -> anyhow::Result<EligibilityDto> {
        let report = self.pipeline.eligibility().ffi()?;
        Ok(EligibilityDto {
            // `usize` on every target this SDK builds for is at most 64 bits,
            // so widening is lossless.
            distinct_note_count: report.eligibility.distinct_note_count as u64,
            eligible_weight: report.eligibility.eligible_weight,
            is_eligible: report.eligibility.is_eligible(),
            privacy_trim_dropped_value_zatoshi: report.privacy_trim_dropped_value_zatoshi,
        })
    }

    /// Cancels every bounded pass this session's control governs.
    ///
    /// Permanent: a cancelled session is finished, not paused. Work already
    /// made durable stays durable.
    pub(super) fn cancel(&self) {
        self.control.cancel();
    }

    /// Moves the host operation epoch, invalidating passes that captured an
    /// older one.
    pub(super) fn set_epoch(&self, epoch: u64) {
        self.control.set_operation_epoch(epoch);
    }

    /// The round this session is bound to.
    pub(super) fn round_id(&self) -> &str {
        &self.round_id
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voting::test_support::*;

    /// A session over a fresh in-memory store and a fresh wallet holding one
    /// note-less account.
    ///
    /// The temporary directory is returned alongside, not dropped here: it owns
    /// the wallet file the session's opener re-opens on every pipeline stage.
    fn open_session(
        tag: u8,
    ) -> (
        crate::voting::store::VotingDatabaseHandle,
        tempfile::TempDir,
        VotingSession,
    ) {
        let store = open_memory_store(crate::NETWORK_ID_TESTNET, "w");
        let (dir, wallet_path, account_uuid) =
            temp_wallet_db_with_account(crate::NETWORK_ID_TESTNET);
        let inputs = synthetic_session_inputs(tag, &wallet_path, &account_uuid);
        let hotkey =
            zcash_voting::hotkey::generate_random_voting_hotkey(zcash_voting::Network::Testnet)
                .expect("hotkey")
                .stored_secret()
                .to_vec();
        let session = VotingSession::open(
            &store,
            inputs,
            synthetic_binding(2, Some(hotkey)),
            SdkRoute::direct(),
            1,
        )
        .expect("open");
        (store, dir, session)
    }

    /// The error kind of a voting failure that crossed as `VotingErrorView` JSON.
    ///
    /// Every assertion below goes through this rather than matching message
    /// text: the point of the envelope is that Swift branches on the kind.
    fn error_kind(err: &anyhow::Error) -> String {
        let view: zcash_voting::VotingErrorView =
            serde_json::from_str(&err.to_string()).expect("typed JSON error");
        serde_json::to_value(view.kind)
            .expect("kind")
            .as_str()
            .expect("kind is a string")
            .to_string()
    }

    #[test]
    fn open_rejects_invalid_tree_state_bytes() {
        let store = open_memory_store(crate::NETWORK_ID_TESTNET, "w");
        let (_dir, wallet_path, account_uuid) =
            temp_wallet_db_with_account(crate::NETWORK_ID_TESTNET);
        let mut inputs = synthetic_session_inputs(0x21, &wallet_path, &account_uuid);
        inputs.anchor_tree_state = vec![0xff, 0xff, 0xff];
        // `VotingSession` is deliberately not `Debug` (it holds a hotkey
        // secret), so the success arm cannot go through `unwrap_err`.
        let err = match VotingSession::open(
            &store,
            inputs,
            synthetic_binding(1, None),
            SdkRoute::direct(),
            1,
        ) {
            Ok(_) => panic!("a malformed anchor tree state must not open a session"),
            Err(err) => err,
        };
        assert_eq!(error_kind(&err), "invalid_input");
    }

    #[test]
    fn open_binds_the_round_id_from_the_round_params() {
        let (_store, _dir, session) = open_session(0x20);
        assert_eq!(session.round_id(), hex_round_id(0x20));
    }

    /// A round whose bundle setup failed still plans, and says what it owes.
    ///
    /// This is the sequence a voter with no eligible notes produces, so the
    /// round must survive it: `setup_bundles` persisted the round row before
    /// note selection refused, and the plan that follows reports a round that
    /// owes a draft — no proposal has been decided — rather than failing.
    #[test]
    fn open_then_plan_on_fresh_round_needs_bundle_setup() {
        let (_store, _dir, session) = open_session(0x22);
        session.setup_bundles().unwrap_err(); // empty wallet: no spendable notes
        let plan = session.plan().expect("a round with no bundles still plans");
        assert_eq!(plan.round_id, hex_round_id(0x22));
        assert!(plan.needs_draft_setup);
        assert!(!plan.needs_bundle_setup);
    }

    /// Planning a round the sidecar has never seen is not an error.
    ///
    /// The crate plans over a round's rows, and a round with none plans as an
    /// idle round that owes a draft. Asserting it here keeps the host from
    /// having to order "open" and "plan" against a round row it cannot see.
    #[test]
    fn plan_before_any_round_row_is_an_idle_plan() {
        let (_store, _dir, session) = open_session(0x29);
        let plan = session.plan().expect("plan");
        assert_eq!(plan.round_id, hex_round_id(0x29));
        assert!(plan.next_steps.is_empty());
        assert!(plan.needs_draft_setup);
    }

    #[test]
    fn setup_bundles_on_empty_wallet_is_no_spendable_notes() {
        let (_store, _dir, session) = open_session(0x23);
        let err = session.setup_bundles().unwrap_err();
        assert!(matches!(
            error_kind(&err).as_str(),
            "no_spendable_notes" | "insufficient_eligibility"
        ));
    }

    #[test]
    fn eligibility_on_empty_wallet_is_no_spendable_notes() {
        let (_store, _dir, session) = open_session(0x26);
        let err = session.eligibility().unwrap_err();
        assert!(matches!(
            error_kind(&err).as_str(),
            "no_spendable_notes" | "insufficient_eligibility"
        ));
    }

    #[test]
    fn set_ballot_intents_requires_rostered_proposals() {
        let (_store, _dir, session) = open_session(0x24);
        let err = session
            .set_ballot_intents(vec![crate::voting::wire::BallotIntentDto {
                proposal_id: 99,
                decision: crate::voting::wire::DecisionDto::Skipped,
            }])
            .unwrap_err();
        assert_eq!(error_kind(&err), "invalid_input");
    }

    /// Recording an intent needs the round row, and `setup_bundles` is how a
    /// session creates it: its `ensure_round` runs before note selection, so
    /// the row survives the empty wallet's `NoSpendableNotes`. Without that
    /// first call the write fails on the sidecar's foreign key instead.
    #[test]
    fn set_ballot_intents_on_a_rostered_proposal_returns_a_plan() {
        let (_store, _dir, session) = open_session(0x27);
        session.setup_bundles().unwrap_err();
        let plan = session
            .set_ballot_intents(vec![crate::voting::wire::BallotIntentDto {
                proposal_id: 1,
                decision: crate::voting::wire::DecisionDto::Choice { option: 0 },
            }])
            .expect("plan");
        assert_eq!(plan.round_id, hex_round_id(0x27));
        // Proposal 2 is rostered and undecided, so the round still owes a draft;
        // proposal 1 now holds a choice with no bundle rows behind it.
        assert!(plan.needs_draft_setup);
        assert!(plan.needs_bundle_setup);
    }

    /// The same call before the round row exists: the sidecar refuses the
    /// write, and what must hold is that it reaches Swift as decodable typed
    /// JSON rather than as a panic or a bare message.
    #[test]
    fn set_ballot_intents_before_round_setup_is_a_typed_error() {
        let (_store, _dir, session) = open_session(0x28);
        let err = session
            .set_ballot_intents(vec![crate::voting::wire::BallotIntentDto {
                proposal_id: 1,
                decision: crate::voting::wire::DecisionDto::Choice { option: 0 },
            }])
            .unwrap_err();
        assert_eq!(error_kind(&err), "storage");
    }

    #[test]
    fn cancel_and_epoch_reach_the_control() {
        let (_store, _dir, session) = open_session(0x25);
        session.set_epoch(7);
        assert_eq!(session.control.operation_epoch(), 7);
        session.cancel();
        assert!(session.control.is_cancelled());
    }
}
