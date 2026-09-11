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
//! Traffic splits by kind: chain and helper requests go through the route
//! chosen at open — Tor or direct, never falling back — because they are what
//! links this device to a vote. PIR and vote-tree requests use the
//! process-wide direct transport: they identify no voter and move enough
//! bytes that routing them over Tor would cost far more than it bought.
//!
//! A run — [`VotingSession::run`] or [`VotingSession::track_shares`] — is
//! driven on the shared runtime instead of on the calling thread, and streams
//! what it observes to the host through an [`EventSink`] as it goes. Neither
//! driver fails: both return a report whose quiescence says why the round
//! stopped, so the errors these methods return are the ones around the run —
//! a signer this host cannot build, a report the wire projection refuses, or a
//! driver task that did not finish.
//!
//! Proving one bundle ahead of a run is the exception to that shape: it runs
//! on a thread this module creates and sizes rather than on the runtime,
//! because Orchard proving needs a stack neither a runtime worker nor the
//! host's calling thread is guaranteed to have.

use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use zeroize::Zeroizing;

use super::errors::{VotingResultExt, envelope_or_invalid_input, internal, invalid_input};
use super::route::SdkRoute;
use super::signer::SeedSpendAuthSigner;
use super::store::VotingDatabaseHandle;
use super::wallet_access::SdkWalletDbOpener;
use super::wire::{
    BallotIntentDto, BundleLayoutDto, DelegationProgressDto, DrivePolicyDto, EligibilityDto,
    HostOverridesDto, KeystoneSignatureBatchResultDto, KeystoneSignedBundleDto,
    KeystoneSigningRequestDto, PirPrecomputeDto, ProofStatusDto, SessionBindingDto,
    SessionEventDto, SessionInputsDto, ShareTrackingPolicyDto, Signer, plan_view,
};

/// Stack the delegation proving thread is created with.
///
/// Orchard proof generation needs far more stack than a thread is given by
/// default, and the thread a host calls in on is the host's own, whose size
/// this SDK does not set — so the proof runs on a thread this module sizes.
const PROOF_THREAD_STACK_BYTES: usize = 64 << 20;

/// The C function a host installs to receive one run's events, or `None` to
/// run without an event stream.
///
/// Each call carries one `SessionEventDto` as UTF-8 JSON. The bytes are
/// borrowed for the duration of the call only, so a host that keeps them must
/// copy them.
pub(super) type EventCallback =
    Option<unsafe extern "C" fn(context: *mut std::ffi::c_void, json: *const u8, json_len: usize)>;

/// Where a run's events go: the host's callback and the context it named.
///
/// `Copy`, because the drivers want one of these in the spawned task and
/// another inside the reporter they report through, and there is nothing here
/// to share.
#[derive(Clone, Copy)]
pub(super) struct EventSink {
    callback: EventCallback,
    context: *mut std::ffi::c_void,
}

// SAFETY: a sink is a function pointer and an opaque host pointer, and Rust
// cannot know what the latter points at, so both obligations are the host's
// and [`EventSink::new`] states them: the context must stay valid for the
// whole run, and the callback must be safe to call from any thread at any
// time. The round driver reports from several bundle tasks at once, so
// concurrent calls are the normal case rather than an edge; the SDK's Swift
// wrapper serializes them.
unsafe impl Send for EventSink {}
unsafe impl Sync for EventSink {}

impl EventSink {
    /// A sink that discards every event.
    ///
    /// Test-only: the C surface builds every sink from the host's callback,
    /// which is itself optional, so nothing in production asks for an empty
    /// one by name.
    #[cfg(test)]
    pub(super) fn none() -> Self {
        EventSink {
            callback: None,
            context: std::ptr::null_mut(),
        }
    }

    /// A sink over the host's `callback`, called with `context`.
    ///
    /// The callback runs on whichever thread reached the event: one of the
    /// shared runtime's workers, or the proof thread this module creates. It
    /// must not block — the round driver reports from concurrent bundle tasks,
    /// and a callback that waits holds one of them up and can stall the run.
    /// Hand the JSON off and return.
    ///
    /// # Safety
    ///
    /// `callback`, when present, must be safe to call with `context` from any
    /// thread and from several threads at once, and `context` must stay valid
    /// until the run this sink is passed to has returned.
    pub(super) unsafe fn new(callback: EventCallback, context: *mut std::ffi::c_void) -> Self {
        EventSink { callback, context }
    }

    /// Serializes `event` and hands it to the host.
    ///
    /// A sink without a callback drops it, and so does an event that fails to
    /// serialize: the stream is an observation of a run, and the run's report
    /// — which carries the same plan, failures and outcomes — is what the host
    /// acts on.
    ///
    /// Does nothing but serialize and call, because the round driver reports
    /// from concurrent bundle tasks and a reporter that blocked would hold one
    /// of them up.
    pub(super) fn emit(&self, event: &SessionEventDto) {
        let Some(callback) = self.callback else {
            return;
        };
        let Ok(json) = serde_json::to_string(event) else {
            return;
        };
        // SAFETY: the callback and the context are the host's own, given to
        // `new` under its contract; the JSON is borrowed for this call only.
        unsafe { callback(self.context, json.as_ptr(), json.len()) };
    }

    /// A sink that appends every event's JSON to `collected`.
    ///
    /// Test-only. The context is `collected`'s target rather than a clone of
    /// the `Arc`, so a caller must keep its own clone alive for as long as the
    /// sink can be called — which is what lets the test read the events back
    /// after the run.
    #[cfg(test)]
    fn collecting(collected: &Arc<std::sync::Mutex<Vec<String>>>) -> Self {
        unsafe extern "C" fn collect(
            context: *mut std::ffi::c_void,
            json: *const u8,
            json_len: usize,
        ) {
            // SAFETY: `collecting` set the context to a live `Arc`'s target,
            // which its caller holds for the whole run, and `json` is the
            // emitted string's bytes.
            let collected = unsafe { &*context.cast::<std::sync::Mutex<Vec<String>>>() };
            let json = unsafe { std::slice::from_raw_parts(json, json_len) };
            // A panic must not unwind out of an `extern "C"` frame, so a
            // poisoned lock is taken anyway: the assertion belongs to the test
            // that reads the vector back, not to the driver's worker thread.
            collected
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .push(String::from_utf8_lossy(json).into_owned());
        }

        EventSink {
            callback: Some(collect),
            context: Arc::as_ptr(collected).cast::<std::ffi::c_void>().cast_mut(),
        }
    }
}

/// One open voting round: the crate objects that drive it, plus the inputs
/// they were built from.
///
/// Deliberately not `Debug`: the executor's round binding and the delegation
/// pipeline each hold the round's voting hotkey secret, and a derived
/// formatter would reach it through them. `SeedSpendAuthSigner` is not `Debug`
/// for the same reason.
pub struct VotingSession {
    /// A wallet-scoped handle on the sidecar, taken once at open.
    ///
    /// The executor and the pipeline each freeze their own handle over the
    /// same connection, so this one is never the thing they persist through;
    /// it is the session's own read handle, and the one share tracking drives
    /// the round's shares over.
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
    /// transport rather than this session's route: a PIR query names no
    /// voter, and the volume it moves does not belong on Tor.
    pir: Arc<zcash_voting::PirFleet>,
    /// The helper client, kept beside the executor's clone: the two share one
    /// health tracker, so share tracking observes what the round's deliveries
    /// learned about each helper.
    helper_client: zcash_voting::HelperClient,
    /// Cancellation and the host operation epoch, shared with every bounded
    /// pass this session starts.
    control: zcash_voting::ChainSubmissionControl,
    /// The inputs this session was opened with, kept because a step needs the
    /// ones the crate does not capture at construction: the helper fleet, the
    /// vote-tree nodes and the round's timing. A run reads them through
    /// [`HostInputs`], which applies that call's overrides on top.
    inputs: SessionInputsDto,
    /// The voting identity of the store this session was opened from.
    network: zcash_voting::Network,
    /// The SDK's numeric network id, kept so wallet-database and key
    /// derivation calls resolve the same (possibly custom) chain.
    network_id: u32,
    /// The round this session is bound to, as canonical lowercase hex.
    round_id: String,
}

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

        // The five-note bundle layout this SDK has always used, with privacy
        // trimming off: trimming drops eligible notes to blur the voter's
        // weight, which costs voting power the voter did not agree to give up.
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
            hotkey_secret: binding.hotkey_secret.map(Zeroizing::new),
        })
        .ffi()?
        // Vote-tree sync is not chain or helper traffic — it names no voter —
        // so it keeps the shared direct transport whatever route this session
        // chose.
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
        plan_view(plan)
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
        plan_view(plan)
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

    /// Persists one bundle's witnesses and padded secrets and warms its PIR
    /// rows.
    ///
    /// The one delegation step worth running ahead of a drive: a bundle whose
    /// rows are already warm proves without waiting on the PIR fleet, and the
    /// report says how much of the warmth was already there. PIR traffic takes
    /// the shared direct transport whatever route this session opened on: a
    /// PIR query names no voter, and its volume does not belong on Tor.
    pub(super) fn precompute_pir(&self, bundle_index: u32) -> anyhow::Result<PirPrecomputeDto> {
        let report = self
            .pipeline
            .precompute_pir(bundle_index, &self.pir)
            .ffi()?;
        Ok(PirPrecomputeDto {
            bundle_index: report.bundle_index,
            cached: report.report.cached,
            fetched: report.report.fetched,
            // The round's layout as the precompute saw it, so one report is
            // enough for a host to say "bundle 2 of 5".
            bundle_count: report.layout.bundle_count,
        })
    }

    /// Generates this bundle's proof, or reports the persisted one it reused,
    /// streaming the pipeline's stages to `sink` as it goes.
    ///
    /// Runs on a thread of its own with a
    /// [64 MiB stack](PROOF_THREAD_STACK_BYTES) and blocks the calling thread
    /// until that one joins — minutes for a proof this call has to generate.
    /// Not spawned on the shared runtime: proving is CPU work that would hold
    /// a worker for its whole duration, and a worker's stack is the runtime's
    /// to size rather than this call's.
    ///
    /// A spawned thread must own what it touches, so the pipeline and the
    /// fleet go in as `Arc` clones and the sink — which is `Copy` — goes in by
    /// value; nothing is borrowed from the session across the join.
    pub(super) fn precompute_delegation_proof(
        self: &Arc<Self>,
        bundle_index: u32,
        sink: EventSink,
    ) -> anyhow::Result<ProofStatusDto> {
        let pipeline = Arc::clone(&self.pipeline);
        let pir = Arc::clone(&self.pir);
        let status = std::thread::Builder::new()
            .name("zcash-voting-proof".to_string())
            .stack_size(PROOF_THREAD_STACK_BYTES)
            .spawn(move || {
                let reporter = DelegationProgressCallbackReporter { sink, bundle_index };
                pipeline.ensure_proof(bundle_index, &pir, &reporter)
            })
            // A thread the OS refused and a proof that panicked are both this
            // SDK's problem rather than a decision the host can make
            // differently, so both cross as `internal`; a panic payload is not
            // worth rendering into the message.
            .map_err(|e| internal(format!("voting proof thread did not start: {e}")))?
            .join()
            .map_err(|_| internal("voting proof thread panicked"))?
            .ffi()?;
        Ok(match status {
            zcash_voting::delegate::DelegationProofStatus::Generated => ProofStatusDto::Generated,
            zcash_voting::delegate::DelegationProofStatus::Reused => ProofStatusDto::Reused,
        })
    }

    /// The redacted PCZTs a Keystone device signs, one per named bundle and in
    /// the order named — one request per bundle, because the device signs one
    /// QR at a time and the host shows them in the order it asked for.
    ///
    /// A bundle the pipeline cannot build a request for fails the whole call
    /// rather than dropping out of the batch: the host asked for the set of
    /// QRs that covers a round, and a quietly shorter one would read as a
    /// complete set with a bundle that never needed signing.
    pub(super) fn keystone_signing_requests(
        &self,
        bundle_indices: &[u32],
    ) -> anyhow::Result<Vec<KeystoneSigningRequestDto>> {
        require_distinct_bundles(bundle_indices)?;
        bundle_indices
            .iter()
            .map(|bundle_index| {
                Ok(KeystoneSigningRequestDto::from(
                    self.pipeline.keystone_request(*bundle_index).ffi()?,
                ))
            })
            .collect()
    }

    /// Lifts the signatures off the PCZTs a Keystone device returned and
    /// stores them for this round.
    ///
    /// The signature bytes are the only thing taken from the host's PCZT. The
    /// sighash and `rk` stored beside each one come from the request this
    /// wallet rebuilds here, which is why the requests are rebuilt rather than
    /// handed back by the host: what a stored signature is later verified
    /// against is then the wallet's own, whatever the device returned.
    ///
    /// Nothing here checks that the signature signs that sighash. It is lifted
    /// out of the PCZT at the action index the request named and stored as
    /// given, so a syntactically valid PCZT for another bundle is stored
    /// rather than refused; it is caught when the stored signature is verified
    /// for proving. The store's own check — that the bundle row still carries
    /// this sighash and `rk` — is about this wallet's state, a bundle rebuilt
    /// since the request was made, not about the host's bytes.
    ///
    /// The write is one atomic idempotent batch: every named bundle is stored
    /// or none is, and a retry after a QR session that was interrupted halfway
    /// reports what was already there rather than failing on it.
    pub(super) fn store_keystone_signatures(
        &self,
        signed: Vec<KeystoneSignedBundleDto>,
    ) -> anyhow::Result<KeystoneSignatureBatchResultDto> {
        let bundle_indices = signed
            .iter()
            .map(|entry| entry.bundle_index)
            .collect::<Vec<_>>();
        require_distinct_bundles(&bundle_indices)?;
        let inputs = signed
            .iter()
            .map(|entry| {
                let request = self.pipeline.keystone_request(entry.bundle_index).ffi()?;
                super::signer::keystone_signature_input(&request, &entry.signed_pczt).ffi()
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        let stored = self
            .database
            .store_keystone_signatures_batch(&self.round_id, &inputs)
            .ffi()?;
        Ok(KeystoneSignatureBatchResultDto {
            inserted: stored.inserted,
            already_present: stored.already_present,
        })
    }

    /// Drives this round to quiescence, reporting every driver event to
    /// `sink` as it goes.
    ///
    /// Blocks the calling thread for the whole run — minutes on a round with
    /// proofs to generate — but runs the driver on the shared runtime rather
    /// than here: calls arrive from Swift threads, never from a runtime
    /// worker, and the driver hands its planning reads off the worker with
    /// `block_in_place`, which only a multi-thread runtime allows.
    ///
    /// `signer` decides what the run may do with delegation. Without one, the
    /// driver reports the bundles that owe a signature instead of dispatching
    /// them; with a software seed, the seed goes into [`SeedSpendAuthSigner`]
    /// and nowhere else — never into Swift, and never into a sighash, alpha or
    /// PCZT the host could see. It is in a `Zeroizing` buffer from the moment
    /// the FFI decoded it, and that buffer is wiped when this run's delegation
    /// inputs drop with the spawned task.
    ///
    /// The driver itself never fails: a run that could do nothing says why
    /// through the report's quiescence. What can fail is either side of it —
    /// a signer this host cannot build, a driver task that did not finish, and
    /// a report the wire projection refuses.
    pub(super) fn run(
        self: &Arc<Self>,
        overrides: HostOverridesDto,
        signer: Signer,
        policy: DrivePolicyDto,
        sink: EventSink,
    ) -> anyhow::Result<zcash_voting::wire::RoundRunReportView> {
        let session = Arc::clone(self);
        let (drive_policy, max_proof_concurrency) = policy.into_policy();
        // `.clone()` rather than `Arc::clone`: the unsizing coercion to the
        // trait object happens at this binding, and `Arc::clone`'s argument
        // would have to already be one.
        let driver: Arc<dyn zcash_voting::DelegationDriver> = self.pipeline.clone();
        let delegation = match signer {
            Signer::None => None,
            Signer::Software(seed) => Some(zcash_voting::DelegationSigner::Software(Arc::new(
                // `SeedSpendAuthSigner::new` rejects a seed it cannot derive
                // from with a bare message, which has to reach Swift as the
                // typed envelope the rest of the session uses — but the
                // network check it delegates already returns one, so wrapping
                // unconditionally would nest that envelope's JSON inside a
                // second one's message.
                SeedSpendAuthSigner::new(seed, self.network_id, self.network)
                    .map_err(envelope_or_invalid_input)?,
            ))),
            Signer::KeystoneStored => Some(zcash_voting::DelegationSigner::Keystone(
                zcash_voting::KeystoneSignatureSource::Stored,
            )),
        }
        .map(|signer| zcash_voting::DelegationStepInputs {
            driver,
            signer,
            pir: Arc::clone(&self.pir),
        });

        let report = super::runtime::runtime()
            .block_on(super::runtime::runtime().spawn(async move {
                let host = SessionHost {
                    inputs: HostInputs {
                        session: Arc::clone(&session),
                        overrides,
                    },
                    delegation,
                    max_proof_concurrency,
                };
                let reporter = CallbackReporter { sink };
                zcash_voting::RoundDriver::new(&session.executor)
                    .with_policy(drive_policy)
                    .run(&host, &session.control, &reporter)
                    .await
            }))
            .map_err(|e| internal(format!("voting run task failed: {e}")))?;
        zcash_voting::wire::RoundRunReportView::try_from(report).ffi()
    }

    /// Drives this round's unconfirmed helper shares to confirmation,
    /// reporting every pass to `sink`.
    ///
    /// Spawned like [`Self::run`] and for the same reasons, and like it the
    /// driver never fails: a run that owed nothing, ran out of passes or found
    /// the vote already closed says so through the report's quiescence.
    ///
    /// A round admits one tracking run at a time. A second started while a
    /// live one holds the round returns at once with `already_driving`; one
    /// started while a cancelled run is on its way out waits for it to release
    /// the round and takes it over.
    pub(super) fn track_shares(
        self: &Arc<Self>,
        overrides: HostOverridesDto,
        policy: ShareTrackingPolicyDto,
        sink: EventSink,
    ) -> anyhow::Result<zcash_voting::wire::ShareTrackingRunReportView> {
        let session = Arc::clone(self);
        let policy = policy.into_policy();

        let report = super::runtime::runtime()
            .block_on(super::runtime::runtime().spawn(async move {
                let host = ShareTrackingHost {
                    inputs: HostInputs {
                        session: Arc::clone(&session),
                        overrides,
                    },
                };
                let reporter = ShareTrackingCallbackReporter { sink };
                zcash_voting::ShareTrackingDriver::new(
                    &session.database,
                    &session.helper_client,
                    &session.round_id,
                )
                .with_policy(policy)
                .run(&host, &session.control, &reporter)
                .await
            }))
            .map_err(|e| internal(format!("share tracking task failed: {e}")))?;
        Ok(zcash_voting::wire::ShareTrackingRunReportView::from(report))
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
    ///
    /// Test-only, like [`EventSink::none`]: every step here reaches the round
    /// through the field, and the C surface hands Swift the round id inside the
    /// plan and the reports rather than on its own.
    #[cfg(test)]
    pub(super) fn round_id(&self) -> &str {
        &self.round_id
    }
}

/// Unix seconds now, or 0 on a host whose clock predates the epoch.
///
/// Read on every host context rather than captured once per run: a round can
/// take minutes, a proof can cross the last-moment or vote-end boundary, and
/// the step that follows must plan against the clock it actually runs under.
/// The fallback is deliberate — no round's timing window contains 0, so a
/// broken clock plans as if outside the window instead of stopping the run.
fn now_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|since_epoch| since_epoch.as_secs())
        .unwrap_or(0)
}

/// The host inputs one run reads: the session's own, with that call's
/// overrides applied.
///
/// Overrides replace, never merge, and only where present: a field the host
/// set stands in for the session's value for this run, and one it left absent
/// keeps the session's. JSON cannot say "clear this" — an explicit `null`
/// deserializes as absent — so a round whose timing must be gone is opened
/// without it rather than overridden here.
///
/// Every accessor clones and returns; none of them touches the sidecar or any
/// lock the drivers hold, because the drivers call this between dispatches and
/// a context that waited on a step's own lock would deadlock the run.
struct HostInputs {
    session: Arc<VotingSession>,
    overrides: HostOverridesDto,
}

impl HostInputs {
    fn configured_helper_urls(&self) -> Vec<String> {
        self.overrides
            .helper_urls
            .clone()
            .unwrap_or_else(|| self.session.inputs.helper_urls.clone())
    }

    fn vote_tree_node_urls(&self) -> Vec<String> {
        self.overrides
            .vote_tree_node_urls
            .clone()
            .unwrap_or_else(|| self.session.inputs.vote_tree_node_urls.clone())
    }

    fn ceremony_start_seconds(&self) -> Option<u64> {
        self.overrides
            .ceremony_start_seconds
            .unwrap_or(self.session.inputs.ceremony_start_seconds)
    }

    fn vote_end_time_seconds(&self) -> Option<u64> {
        self.overrides
            .vote_end_time_seconds
            .unwrap_or(self.session.inputs.vote_end_time_seconds)
    }
}

/// The round driver's host: the session's inputs, plus what only a drive
/// needs.
struct SessionHost {
    inputs: HostInputs,
    /// The delegation inputs this run signs with, or `None` when the host
    /// named no signer.
    delegation: Option<zcash_voting::DelegationStepInputs>,
    max_proof_concurrency: usize,
}

impl zcash_voting::RoundHostSource for SessionHost {
    fn host_context(&self) -> zcash_voting::RoundHostContext {
        zcash_voting::RoundHostContext {
            configured_helper_urls: self.inputs.configured_helper_urls(),
            now_seconds: now_seconds(),
            ceremony_start_seconds: self.inputs.ceremony_start_seconds(),
            vote_end_time_seconds: self.inputs.vote_end_time_seconds(),
            vote_tree_node_urls: self.inputs.vote_tree_node_urls(),
            delegation: self.delegation.clone(),
            // Fresh submissions only: the driver upgrades work the sidecar
            // already holds to exact-tree recovery itself, so naming a policy
            // for that case here would state a decision the crate makes.
            chain_policy: zcash_voting::ChainAdvancePolicy::default(),
            max_proof_concurrency: self.max_proof_concurrency,
        }
    }
}

/// The share-tracking driver's host: the helper fleet and the round's end,
/// which is all a pass reads.
struct ShareTrackingHost {
    inputs: HostInputs,
}

impl zcash_voting::ShareTrackingHostSource for ShareTrackingHost {
    fn host_context(&self) -> zcash_voting::ShareTrackingHostContext {
        zcash_voting::ShareTrackingHostContext {
            configured_helper_urls: self.inputs.configured_helper_urls(),
            now_seconds: now_seconds(),
            vote_end_time_seconds: self.inputs.vote_end_time_seconds(),
        }
    }
}

/// Projects the round driver's events onto the host's sink.
struct CallbackReporter {
    sink: EventSink,
}

impl zcash_voting::RoundDriveReporter for CallbackReporter {
    fn report(&self, event: zcash_voting::RoundDriveEvent) {
        // An event the wire projection refuses is dropped rather than failing
        // the run: the stream is an observation, and the run report — which
        // carries the same plan, failures and chain outcomes — remains the
        // authoritative account of what happened.
        if let Ok(event) = zcash_voting::wire::RoundDriveEventView::try_from(event) {
            self.sink.emit(&SessionEventDto::RoundDrive {
                event: Box::new(event),
            });
        }
    }
}

/// Projects the share-tracking driver's events onto the host's sink.
struct ShareTrackingCallbackReporter {
    sink: EventSink,
}

impl zcash_voting::ShareTrackingReporter for ShareTrackingCallbackReporter {
    fn report(&self, event: zcash_voting::ShareTrackingEvent) {
        self.sink.emit(&SessionEventDto::ShareTracking {
            event: zcash_voting::wire::ShareTrackingEventView::from(event),
        });
    }
}

/// Projects one bundle's delegation-pipeline progress onto the host's sink.
///
/// The bundle index comes from the call rather than from the event: the
/// pipeline reports a stage, and which bundle it belongs to is what this
/// session asked it to prove.
struct DelegationProgressCallbackReporter {
    sink: EventSink,
    bundle_index: u32,
}

impl zcash_voting::DelegationProgressReporter for DelegationProgressCallbackReporter {
    fn on_progress(&self, progress: zcash_voting::delegate::DelegationProgress) {
        // An event that fails to serialize is dropped inside the sink, as in
        // the drivers' reporters above: the stream is an observation of the
        // proof, and the status this call returns is what the host acts on.
        self.sink.emit(&SessionEventDto::DelegationProgress {
            progress: DelegationProgressDto {
                bundle_index: self.bundle_index,
                stage: progress_stage(&progress).to_string(),
                fraction: progress_fraction(&progress),
            },
        });
    }
}

/// The wire name of a delegation progress stage: the crate's variant in
/// snake_case.
///
/// Spelled out rather than derived, because `DelegationProgress` is the
/// crate's own enum and carries no `Serialize`; writing the names here is also
/// what pins them as the strings Swift matches on. The enum is
/// `#[non_exhaustive]`, so a stage a newer crate reports and this SDK does not
/// name crosses as `unknown` rather than being dropped — a host shows an
/// unnamed step rather than a stalled one.
pub(super) fn progress_stage(
    progress: &zcash_voting::delegate::DelegationProgress,
) -> &'static str {
    use zcash_voting::delegate::DelegationProgress;

    match progress {
        DelegationProgress::SelectingNotes => "selecting_notes",
        DelegationProgress::PcztBuilding => "pczt_building",
        DelegationProgress::PcztBuilt => "pczt_built",
        DelegationProgress::ProofStarting => "proof_starting",
        DelegationProgress::WaitingForExistingProof => "waiting_for_existing_proof",
        DelegationProgress::ProofProgress(_) => "proof_progress",
        DelegationProgress::ProofComplete => "proof_complete",
        DelegationProgress::SigningPayload => "signing_payload",
        DelegationProgress::PayloadReady => "payload_ready",
        _ => "unknown",
    }
}

/// How far into itself a stage that measures its own progress is, and `None`
/// for one that does not: only proof generation reports a fraction.
pub(super) fn progress_fraction(
    progress: &zcash_voting::delegate::DelegationProgress,
) -> Option<f64> {
    match progress {
        zcash_voting::delegate::DelegationProgress::ProofProgress(fraction) => Some(*fraction),
        _ => None,
    }
}

/// Refuses a Keystone batch that names no bundle, or names one twice.
///
/// Both are the host's own mistake and neither has a sensible outcome: an
/// empty batch would build nothing and store nothing, and a repeated index
/// would either hand the host the same QR twice or offer the store two
/// signatures for one bundle. Checked before the pipeline prepares anything,
/// so the refusal costs no wallet read.
fn require_distinct_bundles(bundle_indices: &[u32]) -> anyhow::Result<()> {
    if bundle_indices.is_empty() {
        return Err(invalid_input("a Keystone batch names at least one bundle"));
    }
    let mut seen = std::collections::HashSet::with_capacity(bundle_indices.len());
    match bundle_indices
        .iter()
        .find(|bundle_index| !seen.insert(**bundle_index))
    {
        Some(duplicate) => Err(invalid_input(format!(
            "bundle {duplicate} is named twice in one Keystone batch"
        ))),
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voting::store;
    use crate::voting::test_support::*;
    use crate::voting::wire::DecisionDto;

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

    /// The refusal a wallet with nothing to vote with produces.
    ///
    /// Note selection reports it as `NoSpendableNotes` or, once weight is
    /// decomposed, as `InsufficientEligibility`; which of the two a fixture
    /// lands on is the crate's business, and every caller here only needs the
    /// round to have refused rather than failed some other way.
    fn assert_empty_wallet_refusal(err: &anyhow::Error) {
        let kind = error_kind(err);
        assert!(
            matches!(
                kind.as_str(),
                "no_spendable_notes" | "insufficient_eligibility"
            ),
            "unexpected kind for an empty wallet: {kind}"
        );
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

    /// A round whose bundle setup failed keeps its row and still plans.
    ///
    /// This is the sequence a voter with no eligible notes produces, so the
    /// round must survive it: `setup_bundles` persisted the round row before
    /// note selection refused, and the plan that follows reports a round that
    /// owes a draft — no proposal has been decided — rather than failing. The
    /// surviving row is asserted through the store, because a plan alone reads
    /// the same for a round the sidecar never recorded.
    #[test]
    fn plan_after_a_refused_bundle_setup_keeps_the_round_and_owes_a_draft() {
        let (store, _dir, session) = open_session(0x22);
        let err = session.setup_bundles().unwrap_err(); // empty wallet
        assert_empty_wallet_refusal(&err);

        let rounds = store::list_rounds(&store).expect("rounds");
        assert_eq!(
            rounds
                .iter()
                .map(|r| r.round_id.as_str())
                .collect::<Vec<_>>(),
            vec![hex_round_id(0x22).as_str()],
        );

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
        assert_empty_wallet_refusal(&err);
    }

    #[test]
    fn eligibility_on_empty_wallet_is_no_spendable_notes() {
        let (_store, _dir, session) = open_session(0x26);
        let err = session.eligibility().unwrap_err();
        assert_empty_wallet_refusal(&err);
    }

    #[test]
    fn set_ballot_intents_requires_rostered_proposals() {
        let (_store, _dir, session) = open_session(0x24);
        let err = session
            .set_ballot_intents(vec![BallotIntentDto {
                proposal_id: 99,
                decision: DecisionDto::Skipped,
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
            .set_ballot_intents(vec![BallotIntentDto {
                proposal_id: 1,
                decision: DecisionDto::Choice { option: 0 },
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
            .set_ballot_intents(vec![BallotIntentDto {
                proposal_id: 1,
                decision: DecisionDto::Choice { option: 0 },
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

    /// Every JSON string a run has handed the collecting sink so far.
    fn collected(seen: &Arc<std::sync::Mutex<Vec<String>>>) -> Vec<String> {
        seen.lock().expect("collected events").clone()
    }

    /// A sink with no callback drops events rather than calling through a
    /// null function pointer.
    ///
    /// Asserted against a collecting sink rather than on its own: that the
    /// call returns proves only that nothing crashed, so the same event is
    /// emitted through a sink that records it and then through the empty one,
    /// and what must hold is that the recorded vector does not grow.
    #[test]
    fn event_sink_without_a_callback_drops_events() {
        let event = SessionEventDto::DelegationProgress {
            progress: DelegationProgressDto {
                bundle_index: 0,
                stage: "proof_starting".to_string(),
                fraction: None,
            },
        };
        let seen = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        EventSink::collecting(&seen).emit(&event);
        assert_eq!(collected(&seen).len(), 1, "the collecting sink recorded it");

        EventSink::none().emit(&event);
        assert_eq!(
            collected(&seen).len(),
            1,
            "a sink with no callback must record nothing"
        );
    }

    /// A cancelled session drives nothing: no plan is read and no endpoint is
    /// dialled, and the run says why it stopped rather than failing.
    #[test]
    fn run_on_cancelled_control_quiesces_cancelled_without_network() {
        let (_store, _dir, session) = open_session(0x31);
        let session = Arc::new(session);
        session.cancel();
        let seen = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let report = session
            .run(
                HostOverridesDto::default(),
                Signer::None,
                DrivePolicyDto::default(),
                EventSink::collecting(&seen),
            )
            .expect("a cancelled run still reports");
        assert_eq!(
            serde_json::to_value(report.quiescence.kind).unwrap(),
            "cancelled"
        );
        assert!(
            collected(&seen).is_empty(),
            "a cancelled run reports no event"
        );
    }

    /// A seed the signer cannot derive from stops the call before anything is
    /// spawned, and reaches Swift as the typed envelope every other session
    /// failure uses rather than as a bare message.
    ///
    /// The message is asserted too, because the failure is wrapped on its way
    /// out: a wrap that did not check for an envelope first would put a
    /// serialized error where Swift shows text.
    #[test]
    fn run_with_a_software_seed_too_short_to_derive_is_a_typed_error() {
        let (_store, _dir, session) = open_session(0x35);
        let session = Arc::new(session);
        let err = session
            .run(
                HostOverridesDto::default(),
                Signer::Software(Zeroizing::new(vec![0u8; 8])),
                DrivePolicyDto::default(),
                EventSink::none(),
            )
            .unwrap_err();
        assert_eq!(error_kind(&err), "invalid_input");
        let view: zcash_voting::VotingErrorView =
            serde_json::from_str(&err.to_string()).expect("typed JSON error");
        assert!(
            view.message.contains("seed must be at least"),
            "not the seed refusal in readable form: {}",
            view.message
        );
    }

    /// A fresh round with an undecided ballot: nothing is dispatchable, and the
    /// ballot is what the voter can still act on, so it outranks the bundle
    /// setup the round also owes. Nothing here reaches an endpoint.
    ///
    /// The events the run emitted are asserted as JSON rather than as views:
    /// what Swift decodes is the envelope, so this is where the
    /// `SessionEventDto::RoundDrive` shape is pinned down.
    #[test]
    fn run_on_an_undecided_ballot_quiesces_needs_ballot_and_streams_events() {
        let (_store, _dir, session) = open_session(0x32);
        let session = Arc::new(session);
        let seen = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let report = session
            .run(
                HostOverridesDto::default(),
                Signer::None,
                DrivePolicyDto::default(),
                EventSink::collecting(&seen),
            )
            .expect("a round with no bundles still reports");
        assert_eq!(
            serde_json::to_value(report.quiescence.kind).unwrap(),
            "needs_ballot"
        );
        // The fixture roster, undecided: both proposals are the host's to
        // resolve before anything can be cast.
        assert_eq!(report.quiescence.open_proposals, vec![1, 2]);

        let events = collected(&seen);
        assert!(!events.is_empty(), "the run reported no event at all");
        for json in &events {
            let event: serde_json::Value = serde_json::from_str(json).expect("event JSON");
            assert_eq!(event["kind"], "round_drive");
            assert!(
                event["event"].is_object(),
                "a round_drive event carries the driver event: {json}"
            );
        }
        // The driver plans before it selects, so the first thing a host sees
        // is the plan the run will select from.
        let first: serde_json::Value = serde_json::from_str(&events[0]).expect("event JSON");
        assert_eq!(first["event"]["kind"], "plan_refreshed");
    }

    /// The same round once the ballot is terminal: the plan now owes bundle
    /// rows the run cannot create itself, which is the brief's expected
    /// handoff. Driven through a sink with no callback, which must be a no-op
    /// rather than a null call.
    #[test]
    fn run_with_a_decided_ballot_and_no_bundles_quiesces_needs_bundle_setup() {
        let (_store, _dir, session) = open_session(0x34);
        // Creates the round row (its `ensure_round` runs first) and then
        // refuses note selection on the empty wallet.
        session.setup_bundles().unwrap_err();
        session
            .set_ballot_intents(vec![
                BallotIntentDto {
                    proposal_id: 1,
                    decision: DecisionDto::Choice { option: 0 },
                },
                BallotIntentDto {
                    proposal_id: 2,
                    decision: DecisionDto::Skipped,
                },
            ])
            .expect("a terminal ballot over the bound roster");
        let session = Arc::new(session);
        let report = session
            .run(
                HostOverridesDto::default(),
                Signer::None,
                DrivePolicyDto::default(),
                EventSink::none(),
            )
            .expect("a round owing bundle setup still reports");
        assert_eq!(
            serde_json::to_value(report.quiescence.kind).unwrap(),
            "needs_bundle_setup"
        );
    }

    /// A round the sidecar holds no share for is quiescent on the first pass,
    /// and says so without reaching a helper.
    #[test]
    fn track_shares_with_nothing_pending_quiesces_immediately() {
        let (_store, _dir, session) = open_session(0x33);
        let session = Arc::new(session);
        let seen = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let report = session
            .track_shares(
                HostOverridesDto::default(),
                ShareTrackingPolicyDto::default(),
                EventSink::collecting(&seen),
            )
            .expect("tracking a round with no shares still reports");
        assert_eq!(
            serde_json::to_value(report.quiescence.kind).unwrap(),
            "nothing_to_track"
        );
        // One pass, which found the round owing nothing and stopped: a second
        // would mean the driver waited on a helper it had no share for.
        assert_eq!(report.passes, 1);
        let events = collected(&seen);
        assert!(!events.is_empty(), "the pass reported no event at all");
        for json in &events {
            let event: serde_json::Value = serde_json::from_str(json).expect("event JSON");
            assert_eq!(event["kind"], "share_tracking");
            assert!(
                event["event"].is_object(),
                "a share_tracking event carries the driver event: {json}"
            );
        }
    }

    /// One Keystone-signed bundle, with PCZT bytes no signature can come out
    /// of: every assertion below refuses the batch before it reads them.
    fn signed_bundle(bundle_index: u32) -> KeystoneSignedBundleDto {
        KeystoneSignedBundleDto {
            bundle_index,
            signed_pczt: vec![0u8; 4],
        }
    }

    /// A batch names at least one bundle and never names one twice — in
    /// either direction of the Keystone flow. Both are the host's mistake and
    /// both are refused before the pipeline prepares anything.
    #[test]
    fn keystone_batches_reject_empty_and_duplicate_indices() {
        let (_store, _dir, session) = open_session(0x41);
        let refusals = [
            session.keystone_signing_requests(&[]).unwrap_err(),
            session.keystone_signing_requests(&[0, 1, 0]).unwrap_err(),
            session.store_keystone_signatures(vec![]).unwrap_err(),
            session
                .store_keystone_signatures(vec![signed_bundle(0), signed_bundle(0)])
                .unwrap_err(),
        ];
        for err in &refusals {
            assert_eq!(error_kind(err), "invalid_input");
        }
    }

    /// A round with no bundle rows has no request to build: the pipeline
    /// prepares the bundle first, and the fixture's wallet holds no note to
    /// prepare it from. What must hold is that the refusal is a condition the
    /// host can act on rather than an SDK invariant it can do nothing with.
    #[test]
    fn keystone_request_without_setup_is_a_typed_error() {
        let (_store, _dir, session) = open_session(0x42);
        let err = session.keystone_signing_requests(&[0]).unwrap_err();
        assert_empty_wallet_refusal(&err);
    }

    /// PIR precompute prepares the bundle before it warms a single row, so an
    /// empty wallet stops it at note selection — which is also how this test
    /// knows no endpoint was dialled: a fleet that had been contacted would
    /// report its own transport failure instead.
    #[test]
    fn precompute_pir_without_bundles_is_a_typed_error() {
        let (_store, _dir, session) = open_session(0x43);
        let err = session.precompute_pir(0).unwrap_err();
        assert_empty_wallet_refusal(&err);
    }

    #[test]
    fn delegation_progress_maps_variants_to_snake_case() {
        use zcash_voting::delegate::DelegationProgress;

        assert_eq!(
            progress_stage(&DelegationProgress::WaitingForExistingProof),
            "waiting_for_existing_proof"
        );
        assert_eq!(
            progress_stage(&DelegationProgress::ProofProgress(0.25)),
            "proof_progress"
        );
        assert_eq!(
            progress_fraction(&DelegationProgress::ProofProgress(0.25)),
            Some(0.25)
        );
        assert_eq!(progress_fraction(&DelegationProgress::ProofComplete), None);
    }

    /// The proving thread's failure path, which nothing else here covers: a
    /// bundle this round never set up. The pipeline refuses it while reading
    /// the wallet, so no endpoint is dialled, and what must hold is that the
    /// failure crosses the join as the typed envelope rather than as a panic
    /// or a hang.
    ///
    /// The stage the pipeline reports before it reads the wallet is what
    /// exercises the reporter, so the events are asserted as the JSON Swift
    /// decodes.
    #[test]
    fn precompute_delegation_proof_without_bundles_is_a_typed_error() {
        let (_store, _dir, session) = open_session(0x44);
        let session = Arc::new(session);
        let seen = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let err = session
            .precompute_delegation_proof(0, EventSink::collecting(&seen))
            .unwrap_err();
        // The empty wallet's own refusal, which is also what says the fleet
        // was never reached: a dialled endpoint would have failed as its own
        // transport kind instead.
        assert_empty_wallet_refusal(&err);

        let events = collected(&seen);
        assert!(
            !events.is_empty(),
            "the proof step reported no progress at all"
        );
        for json in &events {
            let event: serde_json::Value = serde_json::from_str(json).expect("event JSON");
            assert_eq!(event["kind"], "delegation_progress");
            assert_eq!(event["progress"]["bundle_index"], 0);
            assert!(
                event["progress"]["stage"].is_string(),
                "a delegation_progress event names its stage: {json}"
            );
        }
    }
}
