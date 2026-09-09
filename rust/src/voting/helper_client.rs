//! Wallet-scoped helper operations, independent of the primary proving handle.
use super::helpers::{bytes_from_ptr, json_to_boxed_slice};
use anyhow::{Result, anyhow, ensure};
use ffi_helpers::panic::catch_panic;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::panic::AssertUnwindSafe;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use zcash_voting::{
    self as voting, HelperClient, HelperHealth, HelperTransport, storage::VotingDb,
};

#[derive(Default)]
struct Cancellation {
    cancelled: AtomicBool,
    changed: tokio::sync::Notify,
}
impl Cancellation {
    fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
        self.changed.notify_waiters();
    }
    fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }
    async fn wait(&self) {
        let notified = self.changed.notified();
        tokio::pin!(notified);
        notified.as_mut().enable();
        if !self.is_cancelled() {
            notified.await;
        }
    }
}
#[derive(Deserialize)]
struct Identity {
    round_id: String,
    bundle_index: u32,
    proposal_id: u32,
}
#[derive(Deserialize)]
struct ShareIdentity {
    delivery: Identity,
    share_index: u32,
}
#[derive(Deserialize)]
struct Configuration {
    round_id: String,
    helper_urls: Vec<String>,
    proposal_ids: Vec<u32>,
    vote_end_time: Option<u64>,
    last_moment_buffer: Option<u64>,
}
#[derive(Deserialize)]
struct Fleet {
    configured_urls: Vec<String>,
    ready_urls: Vec<String>,
}
#[derive(Deserialize)]
#[serde(untagged)]
enum BallotDecision {
    Choice { choice: u32 },
    Skipped { skipped: bool },
}
impl BallotDecision {
    fn native(self) -> Result<voting::session::Decision> {
        match self {
            Self::Choice { choice } => Ok(voting::session::Decision::Choice(choice)),
            Self::Skipped { skipped: true } => Ok(voting::session::Decision::Skipped),
            _ => Err(anyhow!("invalid ballot decision")),
        }
    }
}
#[derive(Deserialize)]
struct BallotIntent {
    proposal_id: u32,
    num_options: u32,
    decision: BallotDecision,
}
#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case")]
enum Request {
    Preflight {
        urls: Vec<String>,
    },
    Prepare {
        identity: Identity,
        fleet: Fleet,
        configuration: Configuration,
        now: u64,
    },
    Submit {
        identity: Identity,
        configuration: Configuration,
        now: u64,
    },
    Confirm {
        share: ShareIdentity,
        configuration: Configuration,
        now: u64,
    },
    Track {
        configuration: Configuration,
        now: u64,
    },
    SetIntents {
        round_id: String,
        intents: Vec<BallotIntent>,
    },
    Intents {
        round_id: String,
    },
}
struct HelperContext {
    db: Arc<VotingDb>,
    client: HelperClient,
    network: voting::Network,
    cancellation: Cancellation,
}
impl HelperContext {
    fn open(
        path: &str,
        network: voting::Network,
        wallet: &str,
        transport: Arc<dyn HelperTransport>,
    ) -> Result<Self> {
        ensure!(
            !wallet.is_empty(),
            "helper client requires a wallet identity"
        );
        ensure!(
            !path.is_empty() && path != ":memory:",
            "helper client requires a persistent voting database"
        );
        let db = VotingDb::open(path)?;
        db.set_wallet_id(wallet);
        Ok(Self {
            db: Arc::new(db),
            client: HelperClient::new(transport, HelperHealth::default()),
            network,
            cancellation: Cancellation::default(),
        })
    }
    fn validate_round(&self, round_id: &str) -> Result<()> {
        voting::types::validate_vote_round_id_hex(round_id)?;
        let (_, network) = voting::storage::queries::load_round_params_with_network(
            &self.db.conn(),
            round_id,
            &self.db.wallet_id(),
        )?;
        ensure!(
            network == self.network,
            "helper round network differs from client scope"
        );
        Ok(())
    }
    fn validate_identity(&self, identity: &Identity, config: &Configuration) -> Result<()> {
        ensure!(
            identity.round_id == config.round_id,
            "helper identity and configuration differ"
        );
        self.validate_round(&identity.round_id)
    }
    async fn execute(&self, request: Value, cancellation: &Cancellation) -> Result<Value> {
        let cancel = || self.cancellation.is_cancelled() || cancellation.is_cancelled();
        ensure!(!cancel(), "helper operation cancelled");
        match serde_json::from_value::<Request>(request)? {
            Request::Preflight { urls } => {
                let fleet = tokio::select! {
                    fleet=self.client.preflight_fleet(&urls) => fleet?,
                    _=self.cancellation.wait() => return Err(anyhow!("helper operation cancelled")),
                    _=cancellation.wait() => return Err(anyhow!("helper operation cancelled")),
                };
                Ok(
                    json!({"configured_urls":fleet.configured_server_urls(),"ready_urls":&fleet.ranked_server_urls()[..fleet.ready_server_count()]}),
                )
            }
            Request::SetIntents { round_id, intents } => {
                self.validate_round(&round_id)?;
                ensure!(!intents.is_empty(), "ballot intents must not be empty");
                let mut seen = BTreeSet::new();
                let intents = intents
                    .into_iter()
                    .map(|intent| {
                        ensure!(seen.insert(intent.proposal_id), "duplicate ballot proposal");
                        voting::types::validate_proposal_id(intent.proposal_id)?;
                        voting::types::validate_vote_options(intent.num_options)?;
                        let decision = intent.decision.native()?;
                        if let voting::session::Decision::Choice(choice) = decision {
                            voting::types::validate_vote_decision(choice, intent.num_options)?;
                        }
                        Ok((intent.proposal_id, intent.num_options, decision))
                    })
                    .collect::<Result<Vec<_>>>()?;
                // Native writes are individually atomic. A later conflict may leave
                // an earlier intent persisted; callers must retry/read back the batch.
                for (proposal, num_options, decision) in intents {
                    ensure!(!cancel(), "helper operation cancelled");
                    self.db
                        .set_ballot_intent(&round_id, proposal, decision, num_options)?;
                }
                Ok(Value::Null)
            }
            Request::Intents { round_id } => {
                self.validate_round(&round_id)?;
                let intents = self
                    .db
                    .ballot_intents(&round_id)?
                    .into_iter()
                    .map(|(proposal, decision)| {
                        let decision = match decision {
                            voting::session::Decision::Choice(choice) => json!({"choice":choice}),
                            voting::session::Decision::Skipped => json!({"skipped":true}),
                        };
                        (proposal.to_string(), decision)
                    })
                    .collect::<serde_json::Map<_, _>>();
                Ok(Value::Object(intents))
            }
            Request::Prepare {
                identity,
                fleet,
                configuration,
                now,
            } => {
                self.validate_identity(&identity, &configuration)?;
                let fleet = voting::HelperFleetPreflight::from_readiness(
                    &fleet.configured_urls,
                    &fleet.ready_urls,
                )?;
                let configured =
                    voting::HelperFleetPreflight::from_readiness(&configuration.helper_urls, &[])?;
                ensure!(
                    fleet.configured_server_urls() == configured.configured_server_urls(),
                    "planning fleet differs from round configuration"
                );
                let committed = voting::vote::CommittedVote::recover(
                    &self.db,
                    &identity.round_id,
                    identity.bundle_index,
                    identity.proposal_id,
                )?;
                let plan = committed.prepare_share_delivery(
                    &self.db,
                    voting::share_tracking::ShareDeliveryPlanningParams {
                        fleet: &fleet,
                        now_seconds: now,
                        vote_end_time_seconds: configuration
                            .vote_end_time
                            .ok_or_else(|| anyhow!("preparation requires vote end time"))?,
                        last_moment_buffer_seconds: configuration.last_moment_buffer,
                        proposal_ids: &configuration.proposal_ids,
                    },
                )?;
                let recovery = voting::vote::parse_recovery(&committed.recovery_json(&self.db)?)?;
                let shares=voting::share::recover_payloads(&recovery)?.into_iter().zip(plan.share_plans).map(|(payload,plan)|json!({
                    "share_index":payload.enc_share.share_index,"immediate":plan.immediate,"submit_at":plan.submit_at,"target_count":plan.target_count,
                })).collect::<Vec<_>>();
                Ok(
                    json!({"identity":identity_json(&identity),"shares":shares,"placement_guarantee":plan.placement_guarantee}),
                )
            }
            Request::Submit {
                identity,
                configuration,
                now,
            } => {
                self.validate_identity(&identity, &configuration)?;
                // Confirmation updates the durable VC position and generation; the
                // pre-confirmation CommittedVote must never be reused here.
                let committed = voting::vote::CommittedVote::recover(
                    &self.db,
                    &identity.round_id,
                    identity.bundle_index,
                    identity.proposal_id,
                )?;
                let report = committed
                    .submit_prepared_shares(
                        &self.db,
                        &self.client,
                        voting::share_tracking::ShareDeliverySubmissionParams {
                            configured_server_urls: &configuration.helper_urls,
                            now_seconds: now,
                        },
                        &cancel,
                    )
                    .await?;
                let deliveries=report.deliveries.into_iter().map(|delivery|json!({"share_index":delivery.share_index,"accepted_urls":delivery.submission.accepted_urls,"ambiguous_urls":delivery.submission.ambiguous_urls,"target_count":delivery.submission.target_count})).collect::<Vec<_>>();
                Ok(
                    json!({"deliveries":deliveries,"pending_share_indices":report.pending_share_indices,"cancelled":report.cancelled,"placement_guarantee":report.placement_guarantee}),
                )
            }
            Request::Confirm {
                share,
                configuration,
                now,
            } => {
                self.validate_identity(&share.delivery, &configuration)?;
                let report = voting::share_tracking::confirm_pending_share(
                    &self.db,
                    &voting::share_tracking::ShareConfirmationParams {
                        round_id: &configuration.round_id,
                        share: voting::share_tracking::ShareKey {
                            bundle_index: share.delivery.bundle_index,
                            proposal_id: share.delivery.proposal_id,
                            share_index: share.share_index,
                        },
                        configured_server_urls: &configuration.helper_urls,
                        now_seconds: now,
                    },
                    &self.client,
                    &cancel,
                )
                .await?;
                Ok(json!({"confirmed":report.confirmed,"cancelled":report.cancelled}))
            }
            Request::Track { configuration, now } => {
                self.validate_round(&configuration.round_id)?;
                let report = voting::share_tracking::track_pending_shares(
                    &self.db,
                    &voting::share_tracking::ShareTrackingParams {
                        round_id: &configuration.round_id,
                        configured_server_urls: &configuration.helper_urls,
                        now_seconds: now,
                        vote_end_time_seconds: configuration.vote_end_time,
                        policy: voting::share::ShareTimingPolicy::default(),
                    },
                    &self.client,
                    &cancel,
                )
                .await?;
                let confirmed = report
                    .confirmed
                    .into_iter()
                    .map(|share| share_json(&configuration.round_id, share))
                    .collect::<Vec<_>>();
                let unrecoverable = report
                    .unrecoverable
                    .into_iter()
                    .map(|share| share_json(&configuration.round_id, share))
                    .collect::<Vec<_>>();
                let targets = |values: Vec<voting::share_tracking::ResubmittedShare>| {
                    values.into_iter().map(|target|json!({"identity":share_json(&configuration.round_id,target.share),"server_url":target.server_url})).collect::<Vec<_>>()
                };
                Ok(
                    json!({"confirmed":confirmed,"resubmitted":targets(report.resubmitted),"ambiguous":targets(report.ambiguous),"unrecoverable":unrecoverable,"cancelled":report.cancelled,"next_delay_seconds":report.next_delay_seconds}),
                )
            }
        }
    }
}
fn identity_json(identity: &Identity) -> Value {
    json!({"round_id":identity.round_id,"bundle_index":identity.bundle_index,"proposal_id":identity.proposal_id})
}
fn share_json(round: &str, share: voting::share_tracking::ShareKey) -> Value {
    json!({"delivery":{"round_id":round,"bundle_index":share.bundle_index,"proposal_id":share.proposal_id},"share_index":share.share_index})
}

enum HelperRuntime {
    Direct(tokio::runtime::Runtime),
    Tor(tor_rtcompat::PreferredRuntime),
}
impl HelperRuntime {
    fn block_on<F: std::future::Future>(&self, future: F) -> F::Output {
        use tor_rtcompat::ToplevelBlockOn;
        match self {
            Self::Direct(runtime) => runtime.block_on(future),
            Self::Tor(runtime) => runtime.block_on(future),
        }
    }
}
struct HelperExecutor {
    context: HelperContext,
    runtime: HelperRuntime,
}
/// Retained wallet-scoped helper context. Never aliases the primary database handle.
pub struct VotingHelperHandle {
    executor: Arc<HelperExecutor>,
}
/// A single native operation lease, retaining its runtime and transport until return.
pub struct VotingHelperOperation {
    executor: Arc<HelperExecutor>,
    cancellation: Cancellation,
}

/// Create an independent helper context; null `tor` explicitly selects direct transport.
/// # Safety
/// `db` must be valid for this call. A non-null `tor` must be valid until return.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_helper_create(
    db: *const super::db::VotingDatabaseHandle,
    tor: *const crate::tor::TorRuntime,
) -> *mut VotingHelperHandle {
    let res = catch_panic(AssertUnwindSafe(|| {
        let primary = unsafe { db.as_ref() }.ok_or_else(|| anyhow!("voting database is closed"))?;
        let (transport, runtime): (Arc<dyn HelperTransport>, HelperRuntime) =
            match unsafe { tor.as_ref() } {
                Some(tor) => {
                    let isolated = tor.isolated_client();
                    let runtime = HelperRuntime::Tor(isolated.runtime().clone());
                    (
                        Arc::new(super::helper_transport::TorHelperTransport::new(isolated)),
                        runtime,
                    )
                }
                None => (
                    Arc::new(voting::HyperTransport::new()),
                    HelperRuntime::Direct(
                        tokio::runtime::Builder::new_multi_thread()
                            .enable_all()
                            .build()?,
                    ),
                ),
            };
        let context = HelperContext::open(
            &primary.path,
            primary.network,
            &primary.db.wallet_id(),
            transport,
        )?;
        Ok(Box::into_raw(Box::new(VotingHelperHandle {
            executor: Arc::new(HelperExecutor { context, runtime }),
        })))
    }));
    crate::unwrap_exc_or_null(res)
}
/// Acquire a retained lease while the root handle is alive.
/// # Safety
/// `client` must be valid until return. Free the result exactly once after execution.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_helper_acquire(
    client: *const VotingHelperHandle,
) -> *mut VotingHelperOperation {
    let res = catch_panic(AssertUnwindSafe(|| {
        let client =
            unsafe { client.as_ref() }.ok_or_else(|| anyhow!("helper client is closed"))?;
        ensure!(
            !client.executor.context.cancellation.is_cancelled(),
            "helper client is cancelled"
        );
        Ok(Box::into_raw(Box::new(VotingHelperOperation {
            executor: client.executor.clone(),
            cancellation: Cancellation::default(),
        })))
    }));
    crate::unwrap_exc_or_null(res)
}
/// Execute one lease. Reports contain only helper lifecycle state, never helper payloads.
/// # Safety
/// `operation` must remain alive, and request must be valid for `request_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_helper_execute(
    operation: *const VotingHelperOperation,
    request: *const u8,
    request_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(AssertUnwindSafe(|| {
        let operation =
            unsafe { operation.as_ref() }.ok_or_else(|| anyhow!("helper operation is closed"))?;
        let request = serde_json::from_slice(unsafe { bytes_from_ptr(request, request_len) }?)
            .map_err(|_| anyhow!("invalid helper request"))?;
        let result = operation
            .executor
            .runtime
            .block_on(
                operation
                    .executor
                    .context
                    .execute(request, &operation.cancellation),
            )
            .map_err(|_| anyhow!("voting helper operation failed"))?;
        json_to_boxed_slice(&result)
    }));
    crate::unwrap_exc_or_null(res)
}
/// Cancel the client and fence future leases. Existing leases must still be joined.
/// # Safety
/// `client` must remain valid throughout this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_helper_cancel(client: *const VotingHelperHandle) {
    if let Some(client) = unsafe { client.as_ref() } {
        client.executor.context.cancellation.cancel();
    }
}
/// Signal one operation without cancelling other wallet operations.
/// # Safety
/// `operation` must remain valid throughout this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_helper_operation_cancel(
    operation: *const VotingHelperOperation,
) {
    if let Some(operation) = unsafe { operation.as_ref() } {
        operation.cancellation.cancel();
    }
}
/// Release a completed operation lease.
/// # Safety
/// The non-null pointer must have been returned by acquire and must not be in use or freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_helper_operation_free(
    operation: *mut VotingHelperOperation,
) {
    if !operation.is_null() {
        drop(unsafe { Box::from_raw(operation) });
    }
}
/// Release the root context. Active operation leases retain native ownership.
/// # Safety
/// The non-null pointer must have been returned by create and not already freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_helper_free(client: *mut VotingHelperHandle) {
    if !client.is_null() {
        let client = unsafe { Box::from_raw(client) };
        client.executor.context.cancellation.cancel();
    }
}
/// Validate canonical round IDs with the native voting decoder.
/// # Safety
/// `round_id` must be valid for `round_id_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_validate_round_id(
    round_id: *const u8,
    round_id_len: usize,
) -> bool {
    let res = catch_panic(|| {
        let bytes = unsafe { bytes_from_ptr(round_id, round_id_len) }?;
        let round =
            std::str::from_utf8(bytes).map_err(|_| anyhow!("invalid voting round identifier"))?;
        voting::types::validate_vote_round_id_hex(round)
            .map_err(|_| anyhow!("invalid voting round identifier"))?;
        Ok(true)
    });
    crate::unwrap_exc_or(res, false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;
    use std::time::Duration;
    use zcash_voting::backend::pasta_curves::{
        group::{Group, GroupEncoding},
        pallas,
    };
    use zcash_voting::vote::{VoteRecoveryBundle, insert_recovery_fixture};
    use zcash_voting::{HelperFuture, HelperResponse, HelperTransportError};

    const ROUND: &str = "0101010101010101010101010101010101010101010101010101010101010101";
    const WALLET: &str = "helper-test-wallet";

    #[test]
    fn retained_tor_runtime_outlives_original_owner() {
        let original = tor_rtcompat::PreferredRuntime::create().unwrap();
        let runtime = HelperRuntime::Tor(original.clone());
        drop(original);
        assert!(matches!(runtime, HelperRuntime::Tor(_)));
        assert_eq!(runtime.block_on(async { 42 }), 42);
    }

    #[test]
    fn absent_last_moment_buffer_preserves_native_policy() {
        let mut value = configuration();
        value.as_object_mut().unwrap().remove("last_moment_buffer");
        let configuration: Configuration = serde_json::from_value(value).unwrap();
        assert_eq!(configuration.last_moment_buffer, None);
    }

    #[test]
    fn operation_lease_retains_selected_tor_route_and_database_after_root_release() {
        let directory = tempfile::tempdir().unwrap();
        let transport = Arc::new(Transport::default());
        let weak_transport = Arc::downgrade(&transport);
        let original_runtime = tor_rtcompat::PreferredRuntime::create().unwrap();
        let context = HelperContext::open(
            directory.path().join("voting.sqlite").to_str().unwrap(),
            voting::Network::Mainnet,
            WALLET,
            transport,
        )
        .unwrap();
        let root = Box::into_raw(Box::new(VotingHelperHandle {
            executor: Arc::new(HelperExecutor {
                context,
                runtime: HelperRuntime::Tor(original_runtime.clone()),
            }),
        }));
        let operation = unsafe { zcashlc_voting_helper_acquire(root) };
        assert!(!operation.is_null());
        drop(original_runtime);
        unsafe { zcashlc_voting_helper_free(root) };
        assert!(weak_transport.upgrade().is_some());
        let lease = unsafe { &*operation };
        assert!(matches!(lease.executor.runtime, HelperRuntime::Tor(_)));
        assert!(lease.executor.context.cancellation.is_cancelled());
        assert_eq!(lease.executor.context.db.wallet_id(), WALLET);
        assert_eq!(lease.executor.runtime.block_on(async { 7 }), 7);
        unsafe { zcashlc_voting_helper_operation_free(operation) };
        assert!(weak_transport.upgrade().is_none());
    }

    #[derive(Default)]
    struct Transport {
        posts: Mutex<Vec<String>>,
        ambiguous: AtomicBool,
        confirmed: AtomicBool,
    }
    impl HelperTransport for Transport {
        fn get<'a>(&'a self, url: &'a str, _: Duration) -> HelperFuture<'a> {
            Box::pin(async move {
                let status = if url.ends_with("/status") {
                    "ready"
                } else if self.confirmed.load(Ordering::SeqCst) {
                    "confirmed"
                } else {
                    "pending"
                };
                Ok(HelperResponse::json(
                    200,
                    serde_json::to_vec(&serde_json::json!({"status": status})).unwrap(),
                ))
            })
        }
        fn post_json<'a>(&'a self, url: &'a str, _: Vec<u8>, _: Duration) -> HelperFuture<'a> {
            Box::pin(async move {
                self.posts.lock().unwrap().push(url.to_string());
                if self.ambiguous.load(Ordering::SeqCst) {
                    Err(HelperTransportError::Ambiguous("fixture".to_string()))
                } else {
                    Ok(HelperResponse::json(
                        200,
                        br#"{"status":"queued"}"#.to_vec(),
                    ))
                }
            })
        }
    }
    fn urls() -> Vec<String> {
        (0..3)
            .map(|i| format!("https://helper{i}.example"))
            .collect()
    }
    fn field(n: u8) -> [u8; 32] {
        let mut bytes = [0; 32];
        bytes[0] = n;
        bytes
    }
    fn fixture() -> VoteRecoveryBundle {
        VoteRecoveryBundle {
            vote_round_id: ROUND.to_string(),
            bundle_index: 0,
            proposal_id: 1,
            vote_decision: 2,
            anchor_height: 123,
            vc_tree_position: 0,
            single_share: true,
            num_options: 3,
            van_nullifier: field(10),
            vote_authority_note_new: field(11),
            vote_commitment: field(12),
            proof: vec![13; 96],
            shares_hash: field(14),
            r_vpk: field(15),
            alpha_v: field(16),
            vote_auth_sig: [17; 64],
            encrypted_shares: vec![voting::types::EncryptedShare {
                c1: pallas::Point::generator().to_bytes().to_vec(),
                c2: (pallas::Point::generator() * pallas::Scalar::from(2))
                    .to_bytes()
                    .to_vec(),
                share_index: 0,
                plaintext_value: 5,
                randomness: field(23).to_vec(),
            }],
            share_blinds: vec![field(1)],
            share_comms: (0..16).map(|i| field(i + 30)).collect(),
            batch: None,
        }
    }
    fn seed(db: &VotingDb) {
        db.create_round(
            voting::Network::Mainnet,
            &voting::VotingRoundParams {
                vote_round_id: ROUND.to_string(),
                snapshot_height: 1000,
                ea_pk: vec![7; 32],
                nc_root: vec![8; 32],
                nullifier_imt_root: vec![9; 32],
            },
            None,
        )
        .unwrap();
        db.ensure_bundles(
            ROUND,
            &[voting::NoteInfo {
                commitment: vec![1; 32],
                nullifier: vec![2; 32],
                value: voting::BALLOT_DIVISOR,
                position: 0,
                diversifier: vec![3; 11],
                rho: vec![4; 32],
                rseed: vec![5; 32],
                scope: 0,
                ufvk_str: String::new(),
            }],
        )
        .unwrap();
        insert_recovery_fixture(db, &fixture()).unwrap();
    }
    fn identity() -> Value {
        serde_json::json!({"round_id":ROUND,"bundle_index":0,"proposal_id":1})
    }
    fn configuration() -> Value {
        serde_json::json!({"round_id":ROUND,"helper_urls":urls(),"proposal_ids":[1,2],"vote_end_time":10000,"last_moment_buffer":30})
    }
    fn request(operation: &str) -> Value {
        serde_json::json!({"operation":operation,"identity":identity(),"configuration":configuration(),"now":1000,"fleet":{"configured_urls":urls(),"ready_urls":urls()}})
    }
    fn plan(db: &VotingDb) -> Option<String> {
        use rusqlite::OptionalExtension;
        db.conn().query_row("SELECT share_plans_json FROM helper_share_plans WHERE round_id=?1 AND wallet_id=?2", (ROUND,WALLET), |r|r.get(0)).optional().unwrap()
    }
    async fn intents(context: &HelperContext) {
        context.execute(serde_json::json!({"operation":"set_intents","round_id":ROUND,"intents":[{"proposal_id":1,"num_options":3,"decision":{"choice":2}},{"proposal_id":2,"num_options":3,"decision":{"skipped":true}}]}), &Cancellation::default()).await.unwrap();
    }

    struct GatedPostTransport {
        entered: tokio::sync::Semaphore,
        release: tokio::sync::Semaphore,
    }
    impl HelperTransport for GatedPostTransport {
        fn get<'a>(&'a self, _: &'a str, _: Duration) -> HelperFuture<'a> {
            Box::pin(async {
                Ok(HelperResponse::new(
                    200,
                    br#"{"status":"ready"}"#.to_vec(),
                    None,
                ))
            })
        }
        fn post_json<'a>(&'a self, _: &'a str, _: Vec<u8>, _: Duration) -> HelperFuture<'a> {
            Box::pin(async move {
                self.entered.add_permits(1);
                self.release.acquire().await.unwrap().forget();
                Err(HelperTransportError::Ambiguous(
                    "injected uncertain POST".to_string(),
                ))
            })
        }
    }
    #[tokio::test]
    async fn cancellation_joins_inflight_post_and_retains_unknown_evidence() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("voting.sqlite");
        let transport = Arc::new(GatedPostTransport {
            entered: tokio::sync::Semaphore::new(0),
            release: tokio::sync::Semaphore::new(0),
        });
        let context = Arc::new(
            HelperContext::open(
                path.to_str().unwrap(),
                voting::Network::Mainnet,
                WALLET,
                transport.clone(),
            )
            .unwrap(),
        );
        seed(&context.db);
        intents(&context).await;
        context
            .execute(request("prepare"), &Cancellation::default())
            .await
            .unwrap();
        voting::vote::record_vc_position(&context.db, ROUND, 0, 1, 789).unwrap();
        let worker_context = context.clone();
        let work = tokio::spawn(async move {
            worker_context
                .execute(request("submit"), &Cancellation::default())
                .await
        });
        transport.entered.acquire().await.unwrap().forget();
        context.cancellation.cancel();
        assert!(
            !work.is_finished(),
            "in-flight POST must actually return before join completes"
        );
        // A separate primary DB remains writable while helper HTTP is suspended.
        let primary = VotingDb::open(path.to_str().unwrap()).unwrap();
        primary.set_wallet_id("another-wallet");
        assert!(primary.ballot_intents(ROUND).unwrap().is_empty());
        transport.release.add_permits(16);
        let report = work.await.unwrap().unwrap();
        assert_eq!(report["cancelled"], true);
        assert!(
            !report["deliveries"][0]["ambiguous_urls"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        assert!(!context.db.get_share_delegations(ROUND).unwrap().is_empty());
    }

    #[tokio::test]
    async fn prepare_persists_before_dispatch_and_delivery_survives_reopen() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("voting.sqlite");
        let transport = Arc::new(Transport::default());
        let context = HelperContext::open(
            path.to_str().unwrap(),
            voting::Network::Mainnet,
            WALLET,
            transport.clone(),
        )
        .unwrap();
        seed(&context.db);
        intents(&context).await;
        let prepared = context
            .execute(request("prepare"), &Cancellation::default())
            .await;
        let persisted_plan = plan(&context.db);
        assert!(
            persisted_plan.is_some(),
            "preparation must persist the complete plan"
        );
        assert!(prepared.is_ok());
        let post_count_before_confirmation = transport.posts.lock().unwrap().len();
        assert_eq!(post_count_before_confirmation, 0);
        assert!(
            context
                .execute(request("submit"), &Cancellation::default())
                .await
                .is_err()
        );
        assert_eq!(transport.posts.lock().unwrap().len(), 0);
        voting::vote::record_vc_position(&context.db, ROUND, 0, 1, 789).unwrap();
        let submitted = context
            .execute(request("submit"), &Cancellation::default())
            .await
            .unwrap();
        let expected_share_count =
            submitted["deliveries"][0]["target_count"].as_u64().unwrap() as usize;
        let posted_after_confirmation = transport.posts.lock().unwrap().len();
        assert_eq!(posted_after_confirmation, expected_share_count);
        let accepted_urls_before_restart = context.db.get_share_delegations(ROUND).unwrap()[0]
            .sent_to_urls
            .clone();
        drop(context);
        let reopened = HelperContext::open(
            path.to_str().unwrap(),
            voting::Network::Mainnet,
            WALLET,
            transport.clone(),
        )
        .unwrap();
        let reopened_accepted_urls = reopened.db.get_share_delegations(ROUND).unwrap()[0]
            .sent_to_urls
            .clone();
        assert_eq!(reopened_accepted_urls, accepted_urls_before_restart);
        transport.confirmed.store(true, Ordering::SeqCst);
        let mut tracking = request("track");
        tracking["now"] =
            json!(reopened.db.get_share_delegations(ROUND).unwrap()[0].created_at + 100);
        tracking["configuration"]["vote_end_time"] = Value::Null;
        let tracked = reopened
            .execute(tracking, &Cancellation::default())
            .await
            .unwrap();
        assert_eq!(tracked["confirmed"].as_array().unwrap().len(), 1);
        assert!(reopened.db.get_share_delegations(ROUND).unwrap()[0].confirmed);
    }

    #[tokio::test]
    async fn incomplete_ballot_is_rejected_and_submitted_choice_cannot_be_changed() {
        let directory = tempfile::tempdir().unwrap();
        let context = HelperContext::open(
            directory.path().join("voting.sqlite").to_str().unwrap(),
            voting::Network::Mainnet,
            WALLET,
            Arc::new(Transport::default()),
        )
        .unwrap();
        seed(&context.db);
        assert!(
            context
                .execute(request("prepare"), &Cancellation::default())
                .await
                .is_err()
        );
        assert!(plan(&context.db).is_none());
        intents(&context).await;
        voting::vote::record_submission(&context.db, ROUND, 0, 1, "vote-tx").unwrap();
        let changed=context.execute(serde_json::json!({"operation":"set_intents","round_id":ROUND,"intents":[{"proposal_id":1,"num_options":3,"decision":{"skipped":true}}]}), &Cancellation::default()).await;
        assert!(changed.is_err());
        let stored = context
            .execute(
                serde_json::json!({"operation":"intents","round_id":ROUND}),
                &Cancellation::default(),
            )
            .await
            .unwrap();
        assert_eq!(stored["1"]["choice"], 2);
        assert_eq!(stored["2"]["skipped"], true);
    }

    #[tokio::test]
    async fn ambiguous_posts_are_not_retried_on_the_same_helper() {
        let directory = tempfile::tempdir().unwrap();
        let transport = Arc::new(Transport::default());
        transport.ambiguous.store(true, Ordering::SeqCst);
        let context = HelperContext::open(
            directory.path().join("voting.sqlite").to_str().unwrap(),
            voting::Network::Mainnet,
            WALLET,
            transport.clone(),
        )
        .unwrap();
        seed(&context.db);
        intents(&context).await;
        context
            .execute(request("prepare"), &Cancellation::default())
            .await
            .unwrap();
        voting::vote::record_vc_position(&context.db, ROUND, 0, 1, 789).unwrap();
        let report = context
            .execute(request("submit"), &Cancellation::default())
            .await
            .unwrap();
        let unknown_urls = report["deliveries"][0]["ambiguous_urls"]
            .as_array()
            .unwrap()
            .clone();
        assert!(!unknown_urls.is_empty());
        transport.posts.lock().unwrap().clear();
        context
            .execute(request("submit"), &Cancellation::default())
            .await
            .unwrap();
        let retried_on_same_helper = transport.posts.lock().unwrap().clone();
        assert!(unknown_urls.iter().all(|url| {
            !retried_on_same_helper
                .iter()
                .any(|post| post.starts_with(url.as_str().unwrap()))
        }));
    }

    #[tokio::test]
    async fn cancellation_before_dispatch_and_wallet_scope_are_preserved() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("voting.sqlite");
        let transport = Arc::new(Transport::default());
        let context = HelperContext::open(
            path.to_str().unwrap(),
            voting::Network::Mainnet,
            WALLET,
            transport.clone(),
        )
        .unwrap();
        seed(&context.db);
        intents(&context).await;
        let other = HelperContext::open(
            path.to_str().unwrap(),
            voting::Network::Mainnet,
            "another-wallet",
            transport.clone(),
        )
        .unwrap();
        assert!(
            other
                .execute(request("prepare"), &Cancellation::default())
                .await
                .is_err()
        );
        context
            .execute(request("prepare"), &Cancellation::default())
            .await
            .unwrap();
        voting::vote::record_vc_position(&context.db, ROUND, 0, 1, 789).unwrap();
        let cancel = Cancellation::default();
        cancel.cancel();
        assert!(context.execute(request("submit"), &cancel).await.is_err());
        assert!(transport.posts.lock().unwrap().is_empty());
    }
    #[tokio::test]
    async fn schema13_upgrade_preserves_recovery_bytes_and_legacy_tracking_without_intents() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("legacy.sqlite");
        let legacy = rusqlite::Connection::open(&path).unwrap();
        legacy
            .execute_batch(include_str!("fixtures/schema13.sql"))
            .unwrap();
        legacy.pragma_update(None, "user_version", 13).unwrap();
        legacy.execute("INSERT INTO rounds(round_id,wallet_id,network,snapshot_height,ea_pk,nc_root,nullifier_imt_root,created_at) VALUES (?1,?2,'mainnet',1000,?3,?3,?3,1)",(ROUND,WALLET,field(7).to_vec())).unwrap();
        legacy.execute("INSERT INTO bundles(round_id,wallet_id,bundle_index,van_comm_rand,pczt_sighash,van_leaf_position,total_note_value,delegation_tx_hash) VALUES (?1,?2,0,?3,?4,42,12500000,'accepted-delegation')",(ROUND,WALLET,field(11).to_vec(),field(12).to_vec())).unwrap();
        // A second row without a hash must survive too; recovery cannot silently drop it.
        legacy
            .execute(
                "INSERT INTO bundles(round_id,wallet_id,bundle_index) VALUES (?1,?2,1)",
                (ROUND, WALLET),
            )
            .unwrap();
        legacy.execute("INSERT INTO proofs(round_id,wallet_id,bundle_index,witness,proof,success,created_at) VALUES (?1,?2,0,?3,?4,1,1)",(ROUND,WALLET,vec![21;65],vec![22;96])).unwrap();
        legacy.execute("INSERT INTO imt_proofs(round_id,wallet_id,bundle_index,nullifier,root,nf_bounds,leaf_pos,path,created_at) VALUES (?1,?2,0,?3,?4,?5,7,?6,1)",(ROUND,WALLET,field(1).to_vec(),field(2).to_vec(),vec![3;96],vec![4;928])).unwrap();
        let mut recovery = fixture();
        recovery.vc_tree_position = 789;
        let recovery_json = voting::vote::serialize_recovery(&recovery).unwrap();
        legacy.execute("INSERT INTO votes(round_id,wallet_id,bundle_index,proposal_id,choice,created_at,tx_hash,vc_tree_position,commitment_bundle_json) VALUES (?1,?2,0,1,2,1,'accepted-vote',789,?3)",(ROUND,WALLET,&recovery_json)).unwrap();
        let accepted = serde_json::to_string(&urls()).unwrap();
        legacy.execute("INSERT INTO share_delegations(round_id,wallet_id,bundle_index,proposal_id,share_index,sent_to_urls,nullifier,created_at) VALUES (?1,?2,0,1,0,?3,?4,1)",(ROUND,WALLET,&accepted,field(5).to_vec())).unwrap();
        drop(legacy);
        let transport = Arc::new(Transport::default());
        transport.confirmed.store(true, Ordering::SeqCst);
        let context = HelperContext::open(
            path.to_str().unwrap(),
            voting::Network::Mainnet,
            WALLET,
            transport.clone(),
        )
        .unwrap();
        {
            let conn = context.db.conn();
            assert_eq!(
                conn.pragma_query_value(None, "user_version", |r| r.get::<_, u32>(0))
                    .unwrap(),
                17
            );
            let retained=conn.query_row("SELECT van_comm_rand,pczt_sighash,van_leaf_position,delegation_tx_hash FROM bundles WHERE bundle_index=0",[],|r|Ok((r.get::<_,Vec<u8>>(0)?,r.get::<_,Vec<u8>>(1)?,r.get::<_,u64>(2)?,r.get::<_,String>(3)?))).unwrap();
            assert_eq!(
                retained,
                (
                    field(11).to_vec(),
                    field(12).to_vec(),
                    42,
                    "accepted-delegation".to_string()
                )
            );
            assert_eq!(
                conn.query_row("SELECT count(*) FROM bundles", [], |r| r.get::<_, u32>(0))
                    .unwrap(),
                2
            );
            let proof = conn
                .query_row("SELECT witness,proof FROM proofs", [], |r| {
                    Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, Vec<u8>>(1)?))
                })
                .unwrap();
            assert_eq!(proof, (vec![21; 65], vec![22; 96]));
            let pir = conn
                .query_row(
                    "SELECT nullifier,root,nf_bounds,leaf_pos,path,network FROM pir_proof_cache",
                    [],
                    |r| {
                        Ok((
                            r.get::<_, Vec<u8>>(0)?,
                            r.get::<_, Vec<u8>>(1)?,
                            r.get::<_, Vec<u8>>(2)?,
                            r.get::<_, u32>(3)?,
                            r.get::<_, Vec<u8>>(4)?,
                            r.get::<_, String>(5)?,
                        ))
                    },
                )
                .unwrap();
            assert_eq!(
                pir,
                (
                    field(1).to_vec(),
                    field(2).to_vec(),
                    vec![3; 96],
                    7,
                    vec![4; 928],
                    "mainnet".to_string()
                )
            );
            assert_eq!(
                conn.query_row("SELECT commitment_bundle_json FROM votes", [], |r| r
                    .get::<_, String>(0))
                    .unwrap(),
                recovery_json
            );
            assert_eq!(
                conn.query_row("SELECT sent_to_urls FROM share_delegations", [], |r| r
                    .get::<_, String>(
                    0
                ))
                .unwrap(),
                accepted
            );
        }
        assert!(context.db.ballot_intents(ROUND).unwrap().is_empty());
        let mut track = request("track");
        track["configuration"]["vote_end_time"] = Value::Null;
        let report = context
            .execute(track, &Cancellation::default())
            .await
            .unwrap();
        assert_eq!(report["confirmed"].as_array().unwrap().len(), 1);
        assert!(
            context.db.ballot_intents(ROUND).unwrap().is_empty(),
            "legacy recovery must not manufacture skips"
        );
        assert!(transport.posts.lock().unwrap().is_empty());
        assert!(
            context
                .execute(request("prepare"), &Cancellation::default())
                .await
                .is_err(),
            "new plans require the real complete roster"
        );
    }

    #[tokio::test]
    async fn legacy_unknown_delivery_can_be_tracked_without_fabricating_intents() {
        let directory = tempfile::tempdir().unwrap();
        let transport = Arc::new(Transport::default());
        transport.confirmed.store(true, Ordering::SeqCst);
        let context = HelperContext::open(
            directory.path().join("voting.sqlite").to_str().unwrap(),
            voting::Network::Mainnet,
            WALLET,
            transport.clone(),
        )
        .unwrap();
        seed(&context.db);
        voting::vote::record_vc_position(&context.db, ROUND, 0, 1, 789).unwrap();
        voting::share::record_delivery_fixture(&context.db, ROUND, 0, 1, 0, &[], &urls(), 2, 0)
            .unwrap();
        let conflicting = context
            .execute(
                json!({
                    "operation":"set_intents", "round_id":ROUND,
                    "intents":[{"proposal_id":1,"num_options":3,"decision":{"skipped":true}}]
                }),
                &Cancellation::default(),
            )
            .await;
        assert!(
            conflicting.is_err(),
            "unknown delivery evidence must not be replaced by skipped intent"
        );
        assert!(context.db.ballot_intents(ROUND).unwrap().is_empty());
        let mut track = request("track");
        track["now"] = json!(context.db.get_share_delegations(ROUND).unwrap()[0].created_at + 100);
        track["configuration"]["vote_end_time"] = Value::Null;
        let report = context
            .execute(track, &Cancellation::default())
            .await
            .unwrap();
        assert_eq!(report["confirmed"].as_array().unwrap().len(), 1);
        assert!(context.db.ballot_intents(ROUND).unwrap().is_empty());
        assert!(transport.posts.lock().unwrap().is_empty());
    }
}
