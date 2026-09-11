//! C entry points over the per-round voting session.
//!
//! One shape throughout, the same one [`super::store_ffi`] uses: JSON
//! arguments arrive as `(ptr, len)` byte pairs, JSON results come back as a
//! `*mut crate::ffi::BoxedSlice` the caller frees with
//! [`zcashlc_free_boxed_slice`](crate::ffi::zcashlc_free_boxed_slice), and
//! failure is null with `VotingErrorView` JSON in the last-error slot. Swift
//! branches on the typed `kind` in that JSON, never on message text.
//!
//! [`zcashlc_voting_session_open`] opens one session per round and
//! [`zcashlc_voting_session_free`] releases it; every other entry point takes
//! that handle and is a thin translation of [`super::session`] — pointer and
//! JSON decoding, one call, one encode. Nothing here decides anything.
//!
//! Every entry point blocks its calling thread for the whole operation, which
//! for a run or a proof is minutes rather than milliseconds, so a host calls
//! them off the thread it draws on. Each one takes its own reference to the
//! round as it reads the handle, so the three long calls behave alike under
//! [`zcashlc_voting_session_free`]: freeing the handle mid-call releases the
//! host's reference and the round outlives the call that is using it.
//!
//! # Events
//!
//! The three long operations — [`zcashlc_voting_session_run`],
//! [`zcashlc_voting_session_track_shares`] and
//! [`zcashlc_voting_session_precompute_delegation_proof`] — stream what they
//! observe to an optional host callback, one `SessionEventDto` as UTF-8 JSON
//! per call. Three things hold for all of them:
//!
//! - The callback runs on the shared runtime's worker threads (on the proving
//!   thread for a proof), from several threads at once during a run, and never
//!   on the thread that made the call. It must not block: a callback that
//!   waits holds up the bundle task that reported.
//! - The `context` pointer is handed back untouched and must stay valid until
//!   the call returns. The JSON bytes are borrowed for the duration of one
//!   callback only, so a host that keeps them copies them.
//! - The stream is lossy by design. An event that fails to serialize or that
//!   the wire projection refuses is dropped rather than failing the operation;
//!   the report the call returns carries the same plan, failures and outcomes
//!   and is the authoritative account of what happened.
//!
//! A session admits one run or tracking run at a time — the SDK's Swift
//! wrapper serializes them — and the events of concurrent runs over one
//! callback would be indistinguishable.

use std::panic::AssertUnwindSafe;
use std::sync::Arc;

use ffi_helpers::panic::catch_panic;
use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::{unwrap_exc_or, unwrap_exc_or_null};

use super::errors::invalid_input;
use super::helpers::{bytes_from_ptr, json_to_boxed_slice};
use super::route::SdkRoute;
use super::session::{EventCallback, EventSink, VotingSession};
use super::store::VotingDatabaseHandle;
use super::store_ffi::handle_from_ptr;
use super::wire::{
    BallotIntentDto, DrivePolicyDto, HostOverridesDto, KeystoneSignedBundleDto, ProofStatusDto,
    SessionBindingDto, SessionInputsDto, ShareTrackingPolicyDto, SignerDto,
};

/// One open voting round, as the host holds it.
///
/// An opaque box around an `Arc` on the round. Every entry point takes its own
/// clone of that `Arc` as it reads the pointer ([`session_from_ptr`]), so this
/// handle is only ever the host's reference: freeing it while a call is in
/// flight releases that reference and leaves the call holding the round.
pub struct VotingSessionHandle {
    session: Arc<VotingSession>,
}

/// Take an owned reference to the session behind a raw pointer, or fail with
/// typed JSON.
///
/// Returns a clone rather than a borrow, so the handle's box is touched only
/// while this function runs: an entry point that then works for minutes holds
/// the round itself, not the allocation the host may free meanwhile. Every
/// entry point here goes through it for that reason, whether it is a read that
/// returns at once or a run that does not.
///
/// # Safety
///
/// If non-null, `ptr` must point to a live `VotingSessionHandle` returned by
/// [`zcashlc_voting_session_open`] and not yet freed — that is, the host must
/// not free the handle while a call is reading this pointer. Freeing it once a
/// call has taken its reference is safe, and is what
/// [`zcashlc_voting_session_free`] documents.
unsafe fn session_from_ptr(ptr: *mut VotingSessionHandle) -> anyhow::Result<Arc<VotingSession>> {
    unsafe { ptr.as_ref() }
        .map(|handle| Arc::clone(&handle.session))
        .ok_or_else(|| invalid_input("VotingSessionHandle is null"))
}

/// Decode one JSON argument, naming it in the failure.
///
/// A payload this boundary cannot parse is the host's own mistake, so it
/// crosses as `invalid_input` rather than as a decode error of its own kind.
///
/// # Safety
///
/// Same contract as [`bytes_from_ptr`].
unsafe fn json_from_ptr<T: DeserializeOwned>(
    ptr: *const u8,
    len: usize,
    what: &str,
) -> anyhow::Result<T> {
    let bytes = unsafe { bytes_from_ptr(ptr, len) }?;
    serde_json::from_slice(bytes).map_err(|e| invalid_input(format!("{what} JSON: {e}")))
}

/// Decode a JSON argument the host may leave empty, which means the default.
///
/// Only the arguments whose defaults this SDK owns are read this way — the
/// host overrides and the two drive policies, where "nothing to say" is a
/// complete answer. A signer is never one of them: which key signs a round is
/// always the host's explicit choice.
///
/// # Safety
///
/// Same contract as [`bytes_from_ptr`].
unsafe fn json_from_ptr_or_default<T: DeserializeOwned + Default>(
    ptr: *const u8,
    len: usize,
    what: &str,
) -> anyhow::Result<T> {
    if len == 0 {
        return Ok(T::default());
    }
    unsafe { json_from_ptr(ptr, len, what) }
}

/// The JSON body [`zcashlc_voting_session_precompute_delegation_proof`]
/// returns.
///
/// `ProofStatusDto` serializes as a bare JSON string, and a bare string is a
/// result no later field can be added to; wrapping it in one named field keeps
/// every result on this surface an object Swift decodes the same way.
#[derive(Serialize)]
struct ProofStatusResponse {
    status: ProofStatusDto,
}

/// Open a voting session for one round over `db`'s sidecar.
///
/// `inputs_json` is a `SessionInputsDto` and `binding_json` a
/// `SessionBindingDto` — the authenticated proposal roster, and the stored
/// hotkey secret when the round already has one. `db` must already carry a
/// wallet id ([`zcashlc_voting_set_wallet_id`](super::store_ffi::zcashlc_voting_set_wallet_id)):
/// the session scopes every row it reads to that wallet, so a handle without
/// one is refused as `invalid_input` here rather than at the first step that
/// would have read a row.
///
/// `tor` selects the route this session's chain and helper traffic takes, for
/// the session's whole life: null is the direct HTTP route, and a Tor runtime
/// is used through an isolated client taken during this call, so the round's
/// circuits are not linkable to the rest of the wallet's Tor use. A session
/// opened on Tor never falls back to a direct connection: a Tor route that
/// cannot connect fails the request, because putting the voter's traffic on
/// the clear network after they asked for Tor is worse than failing. PIR and
/// vote-tree traffic take the shared direct transport either way.
///
/// `epoch` is the host's operation epoch at open; move it with
/// [`zcashlc_voting_session_set_epoch`]. Nothing here reaches the network:
/// every failure is a decision about the arguments. Returns null on error.
///
/// # Safety
///
/// - `db` must be a valid, non-null `VotingDatabaseHandle` pointer.
/// - Each `(ptr, len)` byte argument follows the [`bytes_from_ptr`] contract.
/// - `tor`, when non-null, must point to a live `TorRuntime` returned by a
///   `zcashlc_*` method and not yet freed. It is borrowed for this call only;
///   the caller keeps ownership and still frees it with
///   [`zcashlc_free_tor_runtime`](crate::zcashlc_free_tor_runtime).
/// - Call [`zcashlc_voting_session_free`] to free the returned handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_session_open(
    db: *mut VotingDatabaseHandle,
    inputs_json: *const u8,
    inputs_json_len: usize,
    binding_json: *const u8,
    binding_json_len: usize,
    tor: *const crate::tor::TorRuntime,
    epoch: u64,
) -> *mut VotingSessionHandle {
    let db = AssertUnwindSafe(db);
    let tor = AssertUnwindSafe(tor);
    let res = catch_panic(|| {
        let handle = unsafe { handle_from_ptr(*db) }?;
        let inputs: SessionInputsDto =
            unsafe { json_from_ptr(inputs_json, inputs_json_len, "session inputs") }?;
        let binding: SessionBindingDto =
            unsafe { json_from_ptr(binding_json, binding_json_len, "session binding") }?;
        // SAFETY: the caller's live runtime, per this function's contract. The
        // isolated client is taken here rather than by the host, so a session
        // cannot be handed a runtime whose circuits another part of the wallet
        // is already using.
        let route = match unsafe { (*tor).as_ref() } {
            Some(tor) => SdkRoute::tor(tor.isolated_client()),
            None => SdkRoute::direct(),
        };
        let session = VotingSession::open(handle, inputs, binding, route, epoch)?;
        Ok(Box::into_raw(Box::new(VotingSessionHandle {
            session: Arc::new(session),
        })))
    });
    unwrap_exc_or_null(res)
}

/// Free a `VotingSessionHandle`.
///
/// Releases the host's reference to the round. Every entry point took its own
/// reference when it read its handle, so freeing during any call in flight —
/// a run, a tracking run or a proof alike — is memory-safe: this drops the
/// host's reference and the round itself is dropped when the last call using
/// it returns. What is not safe is freeing the handle while another entry
/// point is reading the same pointer, which no host can arrange usefully
/// anyway.
///
/// The SDK's Swift wrapper still cancels and joins before freeing, because a
/// run left to itself keeps driving a round nothing is listening to.
///
/// # Safety
///
/// - If `ptr` is non-null, it must be a pointer previously returned by
///   [`zcashlc_voting_session_open`] that has not already been freed.
/// - Calling this twice on the same non-null pointer, or on any pointer not
///   obtained from [`zcashlc_voting_session_open`], is undefined behavior.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_session_free(ptr: *mut VotingSessionHandle) {
    if !ptr.is_null() {
        let handle: Box<VotingSessionHandle> = unsafe { Box::from_raw(ptr) };
        drop(handle);
    }
}

/// This round's resume plan, as `RoundPlanView` JSON.
///
/// Planned against the roster the session is bound to. Returns null on error.
///
/// # Safety
///
/// - `session` must be a valid, non-null `VotingSessionHandle` pointer.
/// - Call [`zcashlc_free_boxed_slice`](crate::ffi::zcashlc_free_boxed_slice)
///   to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_session_plan(
    session: *mut VotingSessionHandle,
) -> *mut crate::ffi::BoxedSlice {
    let session = AssertUnwindSafe(session);
    let res = catch_panic(|| {
        let session = unsafe { session_from_ptr(*session) }?;
        json_to_boxed_slice(&session.plan()?)
    });
    unwrap_exc_or_null(res)
}

/// Record ballot decisions and return the refreshed plan, as `RoundPlanView`
/// JSON.
///
/// `intents_json` is a JSON array of `BallotIntentDto`. The whole batch is
/// resolved against the bound roster before anything is written, so a decision
/// for a proposal outside it leaves durable intent untouched. Returns null on
/// error.
///
/// # Safety
///
/// - `session` must be a valid, non-null `VotingSessionHandle` pointer.
/// - The `(ptr, len)` byte argument follows the [`bytes_from_ptr`] contract.
/// - Call [`zcashlc_free_boxed_slice`](crate::ffi::zcashlc_free_boxed_slice)
///   to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_session_set_ballot_intents(
    session: *mut VotingSessionHandle,
    intents_json: *const u8,
    intents_json_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let session = AssertUnwindSafe(session);
    let res = catch_panic(|| {
        let session = unsafe { session_from_ptr(*session) }?;
        let intents: Vec<BallotIntentDto> =
            unsafe { json_from_ptr(intents_json, intents_json_len, "ballot intents") }?;
        json_to_boxed_slice(&session.set_ballot_intents(intents)?)
    });
    unwrap_exc_or_null(res)
}

/// Create this round's row and its delegation bundle rows, returning the
/// bundle layout as JSON.
///
/// Reads the wallet to select notes, so it takes as long as that read does.
/// Returns null on error — including when the account holds nothing eligible,
/// which is a typed kind the host shows rather than a fault.
///
/// # Safety
///
/// - `session` must be a valid, non-null `VotingSessionHandle` pointer.
/// - Call [`zcashlc_free_boxed_slice`](crate::ffi::zcashlc_free_boxed_slice)
///   to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_session_setup_bundles(
    session: *mut VotingSessionHandle,
) -> *mut crate::ffi::BoxedSlice {
    let session = AssertUnwindSafe(session);
    let res = catch_panic(|| {
        let session = unsafe { session_from_ptr(*session) }?;
        json_to_boxed_slice(&session.setup_bundles()?)
    });
    unwrap_exc_or_null(res)
}

/// Whether this account can vote in this round, as JSON, without persisting
/// anything.
///
/// Returns null on error.
///
/// # Safety
///
/// - `session` must be a valid, non-null `VotingSessionHandle` pointer.
/// - Call [`zcashlc_free_boxed_slice`](crate::ffi::zcashlc_free_boxed_slice)
///   to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_session_eligibility(
    session: *mut VotingSessionHandle,
) -> *mut crate::ffi::BoxedSlice {
    let session = AssertUnwindSafe(session);
    let res = catch_panic(|| {
        let session = unsafe { session_from_ptr(*session) }?;
        json_to_boxed_slice(&session.eligibility()?)
    });
    unwrap_exc_or_null(res)
}

/// Persist one bundle's witnesses and padded secrets and warm its PIR rows,
/// returning what the precompute did as JSON.
///
/// Reaches the PIR fleet over the shared direct transport whatever route the
/// session opened on — a PIR query names no voter — so it blocks for as long
/// as those queries take. Returns null on error.
///
/// # Safety
///
/// - `session` must be a valid, non-null `VotingSessionHandle` pointer.
/// - Call [`zcashlc_free_boxed_slice`](crate::ffi::zcashlc_free_boxed_slice)
///   to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_session_precompute_pir(
    session: *mut VotingSessionHandle,
    bundle_index: u32,
) -> *mut crate::ffi::BoxedSlice {
    let session = AssertUnwindSafe(session);
    let res = catch_panic(|| {
        let session = unsafe { session_from_ptr(*session) }?;
        json_to_boxed_slice(&session.precompute_pir(bundle_index)?)
    });
    unwrap_exc_or_null(res)
}

/// Generate one bundle's delegation proof ahead of a run, or report the
/// persisted one it reused.
///
/// Returns `{"status":"generated"}` or `{"status":"reused"}`, and null on
/// error. Blocks for the whole proof — minutes when there is one to generate —
/// on a thread this call creates and sizes for Orchard proving.
///
/// `callback` receives this bundle's pipeline stages as `SessionEventDto` JSON
/// while the proof runs, on that proving thread; see the module documentation
/// for the callback, context and lossiness contract.
///
/// [`zcashlc_voting_session_cancel`] does not interrupt a proof already in
/// flight here: the pipeline call this wraps takes no cancellation signal at
/// the `zcash_voting` revision this SDK builds against, so a cancelled session
/// stops at the next run boundary instead. A proof that finishes is persisted
/// and reused, so nothing is wasted.
///
/// # Safety
///
/// - `session` must be a valid, non-null `VotingSessionHandle` pointer.
/// - `callback`, when present, must be safe to call with `context` from a
///   thread that is not the caller's, and `context` must stay valid until this
///   call returns.
/// - Call [`zcashlc_free_boxed_slice`](crate::ffi::zcashlc_free_boxed_slice)
///   to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_session_precompute_delegation_proof(
    session: *mut VotingSessionHandle,
    bundle_index: u32,
    callback: EventCallback,
    context: *mut std::ffi::c_void,
) -> *mut crate::ffi::BoxedSlice {
    let session = AssertUnwindSafe(session);
    let res = catch_panic(|| {
        let session = unsafe { session_from_ptr(*session) }?;
        // SAFETY: the host's callback and context, under this function's
        // contract; the sink is used only until this call returns.
        let sink = unsafe { EventSink::new(callback, context) };
        let status = session.precompute_delegation_proof(bundle_index, sink)?;
        json_to_boxed_slice(&ProofStatusResponse { status })
    });
    unwrap_exc_or_null(res)
}

/// The redacted PCZTs a Keystone device signs, as a JSON array of
/// `KeystoneSigningRequestDto` — one per named bundle, in the order named.
///
/// `bundle_indices_json` is a JSON array of bundle indices. A batch that names
/// no bundle, or names one twice, is refused as `invalid_input`: the host
/// asked for the set of QRs that covers a round, and neither a set that covers
/// nothing nor one that shows a bundle twice is that. Returns null on error.
///
/// # Safety
///
/// - `session` must be a valid, non-null `VotingSessionHandle` pointer.
/// - The `(ptr, len)` byte argument follows the [`bytes_from_ptr`] contract.
/// - Call [`zcashlc_free_boxed_slice`](crate::ffi::zcashlc_free_boxed_slice)
///   to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_session_keystone_signing_requests(
    session: *mut VotingSessionHandle,
    bundle_indices_json: *const u8,
    bundle_indices_json_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let session = AssertUnwindSafe(session);
    let res = catch_panic(|| {
        let session = unsafe { session_from_ptr(*session) }?;
        let bundle_indices: Vec<u32> = unsafe {
            json_from_ptr(
                bundle_indices_json,
                bundle_indices_json_len,
                "bundle indices",
            )
        }?;
        json_to_boxed_slice(&session.keystone_signing_requests(&bundle_indices)?)
    });
    unwrap_exc_or_null(res)
}

/// Lift the signatures off the PCZTs a Keystone device returned and store them
/// for this round, returning what the batch stored as JSON.
///
/// `entries_json` is a JSON array of `KeystoneSignedBundleDto`. As with
/// [`zcashlc_voting_session_keystone_signing_requests`], an empty batch and a
/// repeated bundle index are refused as `invalid_input`. The write is one
/// atomic idempotent batch, so a retry after an interrupted QR session reports
/// what was already there rather than failing on it. Returns null on error.
///
/// # Safety
///
/// - `session` must be a valid, non-null `VotingSessionHandle` pointer.
/// - The `(ptr, len)` byte argument follows the [`bytes_from_ptr`] contract.
/// - Call [`zcashlc_free_boxed_slice`](crate::ffi::zcashlc_free_boxed_slice)
///   to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_session_store_keystone_signatures(
    session: *mut VotingSessionHandle,
    entries_json: *const u8,
    entries_json_len: usize,
) -> *mut crate::ffi::BoxedSlice {
    let session = AssertUnwindSafe(session);
    let res = catch_panic(|| {
        let session = unsafe { session_from_ptr(*session) }?;
        let signed: Vec<KeystoneSignedBundleDto> =
            unsafe { json_from_ptr(entries_json, entries_json_len, "Keystone signed bundles") }?;
        json_to_boxed_slice(&session.store_keystone_signatures(signed)?)
    });
    unwrap_exc_or_null(res)
}

/// Drive this round to quiescence, returning the run report as
/// `RoundRunReportView` JSON.
///
/// `host_json` is a `HostOverridesDto` and `policy_json` a `DrivePolicyDto`;
/// an empty argument (`len == 0`) means the session's own inputs and the
/// default policy respectively. `signer_json` is a `SignerDto` and is never
/// empty: a run without delegation is `{"kind":"none"}`, stated by the host
/// rather than inferred from a missing argument. A software seed lives in the
/// SDK's signer for this call only, and never reaches Swift; it is moved into
/// a buffer that wipes itself as soon as it is decoded.
///
/// The driver itself does not fail — a run that could do nothing says why
/// through the report's quiescence — so null here means the call around it
/// failed: a signer this host cannot build, a task that did not finish, or a
/// report the wire projection refused.
///
/// `callback` receives the driver's events as `SessionEventDto` JSON while the
/// run proceeds; see the module documentation for the callback, context and
/// lossiness contract, and for the one-run-at-a-time rule.
///
/// # Safety
///
/// - `session` must be a valid, non-null `VotingSessionHandle` pointer.
/// - Each `(ptr, len)` byte argument follows the [`bytes_from_ptr`] contract.
/// - `callback`, when present, must be safe to call with `context` from
///   several threads at once, and `context` must stay valid until this call
///   returns.
/// - Call [`zcashlc_free_boxed_slice`](crate::ffi::zcashlc_free_boxed_slice)
///   to free the returned pointer.
#[allow(clippy::too_many_arguments)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_session_run(
    session: *mut VotingSessionHandle,
    host_json: *const u8,
    host_json_len: usize,
    signer_json: *const u8,
    signer_json_len: usize,
    policy_json: *const u8,
    policy_json_len: usize,
    callback: EventCallback,
    context: *mut std::ffi::c_void,
) -> *mut crate::ffi::BoxedSlice {
    let session = AssertUnwindSafe(session);
    let res = catch_panic(|| {
        let session = unsafe { session_from_ptr(*session) }?;
        let overrides: HostOverridesDto =
            unsafe { json_from_ptr_or_default(host_json, host_json_len, "host overrides") }?;
        if signer_json_len == 0 {
            return Err(invalid_input(
                r#"a run names its signer; pass {"kind":"none"} to run without one"#,
            ));
        }
        // Moved into its wiping buffer as it is decoded: `into_signer` is what
        // takes a software seed out of the plain `Vec` serde built, so nothing
        // that can still fail below — the policy decode, the session's own
        // refusals — drops an un-wiped one. serde's intermediate base64
        // `String` is the one allocation this cannot reach; see `wire::Signer`.
        let signer = unsafe { json_from_ptr::<SignerDto>(signer_json, signer_json_len, "signer") }?
            .into_signer();
        let policy: DrivePolicyDto =
            unsafe { json_from_ptr_or_default(policy_json, policy_json_len, "drive policy") }?;
        // SAFETY: the host's callback and context, under this function's
        // contract; the sink is used only until this call returns.
        let sink = unsafe { EventSink::new(callback, context) };
        json_to_boxed_slice(&session.run(overrides, signer, policy, sink)?)
    });
    unwrap_exc_or_null(res)
}

/// Drive this round's unconfirmed helper shares to confirmation, returning the
/// tracking report as `ShareTrackingRunReportView` JSON.
///
/// `host_json` is a `HostOverridesDto` and `policy_json` a
/// `ShareTrackingPolicyDto`; an empty argument (`len == 0`) means the
/// session's own inputs and the default policy. No signer: tracking delivers
/// and confirms shares that already exist.
///
/// Like a run, the driver does not fail — a round that owed nothing, ran out
/// of passes or found the vote closed says so through the report's quiescence,
/// and a second tracking run over a round one already holds returns
/// `already_driving` at once.
///
/// `callback` receives each pass's events as `SessionEventDto` JSON; see the
/// module documentation for the callback, context and lossiness contract.
///
/// # Safety
///
/// - `session` must be a valid, non-null `VotingSessionHandle` pointer.
/// - Each `(ptr, len)` byte argument follows the [`bytes_from_ptr`] contract.
/// - `callback`, when present, must be safe to call with `context` from a
///   thread that is not the caller's, and `context` must stay valid until this
///   call returns.
/// - Call [`zcashlc_free_boxed_slice`](crate::ffi::zcashlc_free_boxed_slice)
///   to free the returned pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_session_track_shares(
    session: *mut VotingSessionHandle,
    host_json: *const u8,
    host_json_len: usize,
    policy_json: *const u8,
    policy_json_len: usize,
    callback: EventCallback,
    context: *mut std::ffi::c_void,
) -> *mut crate::ffi::BoxedSlice {
    let session = AssertUnwindSafe(session);
    let res = catch_panic(|| {
        let session = unsafe { session_from_ptr(*session) }?;
        let overrides: HostOverridesDto =
            unsafe { json_from_ptr_or_default(host_json, host_json_len, "host overrides") }?;
        let policy: ShareTrackingPolicyDto = unsafe {
            json_from_ptr_or_default(policy_json, policy_json_len, "share tracking policy")
        }?;
        // SAFETY: the host's callback and context, under this function's
        // contract; the sink is used only until this call returns.
        let sink = unsafe { EventSink::new(callback, context) };
        json_to_boxed_slice(&session.track_shares(overrides, policy, sink)?)
    });
    unwrap_exc_or_null(res)
}

/// Cancel every bounded pass this session governs.
///
/// A run and a tracking run stop at their next boundary and report
/// `cancelled`; a proof already running under
/// [`zcashlc_voting_session_precompute_delegation_proof`] runs to completion,
/// as documented there. Permanent: a cancelled session is finished, not
/// paused, and work already made durable stays durable.
///
/// Nothing is reported back. A null handle is ignored — there is no session to
/// cancel — and leaves `VotingErrorView` JSON in the last-error slot.
///
/// # Safety
///
/// If non-null, `session` must be a valid `VotingSessionHandle` pointer that
/// has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_session_cancel(session: *mut VotingSessionHandle) {
    let session = AssertUnwindSafe(session);
    let res = catch_panic(|| {
        unsafe { session_from_ptr(*session) }?.cancel();
        Ok(())
    });
    unwrap_exc_or(res, ())
}

/// Move the host operation epoch, invalidating passes that captured an older
/// one.
///
/// Swift bumps it when the user switches wallets or leaves the flow: every
/// bounded pass started under an older epoch stops at its next boundary.
/// Nothing is reported back, and a null handle is ignored as in
/// [`zcashlc_voting_session_cancel`].
///
/// # Safety
///
/// If non-null, `session` must be a valid `VotingSessionHandle` pointer that
/// has not been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_session_set_epoch(
    session: *mut VotingSessionHandle,
    epoch: u64,
) {
    let session = AssertUnwindSafe(session);
    let res = catch_panic(|| {
        unsafe { session_from_ptr(*session) }?.set_epoch(epoch);
        Ok(())
    });
    unwrap_exc_or(res, ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::voting::store_ffi::{zcashlc_voting_db_free, zcashlc_voting_db_open};
    use crate::voting::test_support::{
        boxed_slice_to_string, hex_round_id, last_error_string, open_memory_store_ptr,
        synthetic_binding, synthetic_session_inputs, temp_wallet_db_with_account,
    };
    use crate::voting::wire::ProofStatusDto;

    /// A signer payload naming no signer: what a run that only plans passes.
    const SIGNER_NONE: &[u8] = br#"{"kind":"none"}"#;

    /// Read a JSON result and free it, so no test leaks the boxed slice.
    ///
    /// # Safety
    ///
    /// `ptr` must be a non-null `BoxedSlice` returned by an entry point here.
    unsafe fn take_json(ptr: *mut crate::ffi::BoxedSlice) -> serde_json::Value {
        let json = unsafe { boxed_slice_to_string(ptr) };
        unsafe { crate::ffi::zcashlc_free_boxed_slice(ptr) };
        serde_json::from_str(&json).expect("a result is JSON")
    }

    /// The kind of the `VotingErrorView` the last failing call recorded.
    ///
    /// Takes the error out of the slot, so consecutive assertions each read
    /// their own call's failure rather than the first one's.
    fn last_error_kind() -> String {
        let view: zcash_voting::VotingErrorView =
            serde_json::from_str(&last_error_string()).expect("typed JSON error");
        serde_json::to_value(view.kind)
            .expect("kind")
            .as_str()
            .expect("kind is a string")
            .to_string()
    }

    /// A session over a fresh in-memory store and a fresh wallet holding one
    /// note-less account, as the raw pointers the C surface takes.
    ///
    /// Bound to a hotkey, as a round that can delegate is: without one the
    /// delegation steps refuse before they read the wallet, and a test of how
    /// a wallet-level failure crosses this boundary would never reach one.
    ///
    /// The temporary directory is returned alongside: it owns the wallet file
    /// the session re-opens on every pipeline stage. Free the two pointers
    /// with [`free_session`].
    fn open_session(
        tag: u8,
    ) -> (
        *mut VotingDatabaseHandle,
        tempfile::TempDir,
        *mut VotingSessionHandle,
    ) {
        let db = open_memory_store_ptr(crate::NETWORK_ID_TESTNET, "w");
        let (dir, wallet_path, account_uuid) =
            temp_wallet_db_with_account(crate::NETWORK_ID_TESTNET);
        let inputs =
            serde_json::to_vec(&synthetic_session_inputs(tag, &wallet_path, &account_uuid))
                .expect("inputs JSON");
        let hotkey =
            zcash_voting::hotkey::generate_random_voting_hotkey(zcash_voting::Network::Testnet)
                .expect("hotkey")
                .stored_secret()
                .to_vec();
        let binding =
            serde_json::to_vec(&synthetic_binding(2, Some(hotkey))).expect("binding JSON");
        let session = unsafe {
            zcashlc_voting_session_open(
                db,
                inputs.as_ptr(),
                inputs.len(),
                binding.as_ptr(),
                binding.len(),
                std::ptr::null(),
                3,
            )
        };
        assert!(
            !session.is_null(),
            "session did not open: {}",
            last_error_string()
        );
        (db, dir, session)
    }

    /// Release what [`open_session`] handed out, session first.
    ///
    /// # Safety
    ///
    /// Both pointers must come from one [`open_session`] call and must not
    /// have been freed.
    unsafe fn free_session(db: *mut VotingDatabaseHandle, session: *mut VotingSessionHandle) {
        unsafe { zcashlc_voting_session_free(session) };
        unsafe { zcashlc_voting_db_free(db) };
    }

    /// Assert one entry point refused a call and said so as typed JSON.
    fn refused(name: &str, ptr: *mut crate::ffi::BoxedSlice) {
        assert!(ptr.is_null(), "{name} accepted a call it must refuse");
        assert_eq!(last_error_kind(), "invalid_input", "{name}");
    }

    /// Collects every event the session streamed, as the host's context.
    ///
    /// # Safety
    ///
    /// `context` must point at a live `Mutex<Vec<String>>` and `json` must be
    /// readable for `json_len` bytes — which is what the callback contract of
    /// the entry points below promises.
    unsafe extern "C" fn collect(context: *mut std::ffi::c_void, json: *const u8, json_len: usize) {
        let collected = unsafe { &*context.cast::<std::sync::Mutex<Vec<String>>>() };
        let json = unsafe { std::slice::from_raw_parts(json, json_len) };
        collected
            .lock()
            .expect("collected events")
            .push(String::from_utf8_lossy(json).into_owned());
    }

    /// A raw pointer this test hands to a thread of its own on purpose.
    ///
    /// Raw pointers are not `Send`, and rightly so; what makes these two safe
    /// to move is the handshake in
    /// [`freeing_the_handle_during_a_run_is_safe`], which keeps the session
    /// handle and the callback context alive for as long as the other thread
    /// can touch them.
    struct SharedPtr<T>(*mut T);

    // SAFETY: as stated on the type — the one test that constructs these owns
    // both targets and outlives the thread it hands them to.
    unsafe impl<T> Send for SharedPtr<T> {}

    /// The rendezvous [`freeing_the_handle_during_a_run_is_safe`] performs:
    /// the run says it has started, then waits to be told the handle is freed.
    struct FreeDuringRun {
        entered: std::sync::mpsc::SyncSender<()>,
        freed: std::sync::Mutex<std::sync::mpsc::Receiver<()>>,
        once: std::sync::Once,
    }

    /// The first event parks the run until the test thread has freed the
    /// handle; every later event passes straight through.
    ///
    /// A callback that blocks is exactly what the module documentation tells
    /// hosts not to write. It is the point here: it is what makes the free
    /// provably overlap the call rather than race it.
    ///
    /// # Safety
    ///
    /// `context` must point at a live `FreeDuringRun`, which the test holds
    /// for the whole run.
    unsafe extern "C" fn park_until_freed(
        context: *mut std::ffi::c_void,
        _json: *const u8,
        _json_len: usize,
    ) {
        let rendezvous = unsafe { &*context.cast::<FreeDuringRun>() };
        rendezvous.once.call_once(|| {
            rendezvous.entered.send(()).expect("the test thread waits");
            rendezvous
                .freed
                .lock()
                .expect("free signal")
                .recv_timeout(std::time::Duration::from_secs(60))
                .expect("the test thread frees the handle");
        });
    }

    #[test]
    fn session_open_rejects_null_db_and_bad_json() {
        let inputs = b"{}";
        assert!(
            unsafe {
                zcashlc_voting_session_open(
                    std::ptr::null_mut(),
                    inputs.as_ptr(),
                    inputs.len(),
                    inputs.as_ptr(),
                    inputs.len(),
                    std::ptr::null(),
                    1,
                )
            }
            .is_null()
        );
        assert_eq!(last_error_kind(), "invalid_input");

        let db = open_memory_store_ptr(crate::NETWORK_ID_TESTNET, "w");
        assert!(
            unsafe {
                zcashlc_voting_session_open(
                    db,
                    inputs.as_ptr(),
                    inputs.len(),
                    inputs.as_ptr(),
                    inputs.len(),
                    std::ptr::null(),
                    1,
                )
            }
            .is_null()
        );
        // A malformed argument is the host's own mistake, so it crosses as the
        // same typed envelope every other refusal here uses.
        assert_eq!(last_error_kind(), "invalid_input");
        unsafe { zcashlc_voting_db_free(db) };
    }

    /// The store handle scopes every row a session reads, so a session cannot
    /// open over one whose wallet is still unset — and it says so here rather
    /// than at the first step that would have read a row.
    #[test]
    fn session_open_requires_a_wallet_id_on_the_store() {
        let path = b":memory:";
        let db = unsafe { zcashlc_voting_db_open(path.as_ptr(), path.len(), 1) };
        assert!(!db.is_null());
        let (_dir, wallet_path, account_uuid) =
            temp_wallet_db_with_account(crate::NETWORK_ID_MAINNET);
        let inputs =
            serde_json::to_vec(&synthetic_session_inputs(0x51, &wallet_path, &account_uuid))
                .expect("inputs JSON");
        let binding = serde_json::to_vec(&synthetic_binding(1, None)).expect("binding JSON");
        assert!(
            unsafe {
                zcashlc_voting_session_open(
                    db,
                    inputs.as_ptr(),
                    inputs.len(),
                    binding.as_ptr(),
                    binding.len(),
                    std::ptr::null(),
                    1,
                )
            }
            .is_null()
        );
        assert_eq!(last_error_kind(), "invalid_input");
        unsafe { zcashlc_voting_db_free(db) };
    }

    /// Open, move the epoch, cancel, run, free: the lifecycle Swift performs
    /// around one round, over the C surface alone.
    ///
    /// A cancelled session drives nothing, so the run reaches no endpoint and
    /// reports why it stopped instead of failing — and freeing the session
    /// after it returns releases the last handle on the round.
    #[test]
    fn session_open_run_cancel_free_roundtrip() {
        let (db, _dir, session) = open_session(0x52);
        unsafe { zcashlc_voting_session_set_epoch(session, 4) };
        unsafe { zcashlc_voting_session_cancel(session) };
        let report = unsafe {
            zcashlc_voting_session_run(
                session,
                std::ptr::null(),
                0,
                SIGNER_NONE.as_ptr(),
                SIGNER_NONE.len(),
                std::ptr::null(),
                0,
                None,
                std::ptr::null_mut(),
            )
        };
        assert!(!report.is_null());
        // Empty host overrides and an empty policy mean the session's own
        // inputs and the default policy: a run needs neither to be named.
        assert_eq!(
            unsafe { take_json(report) }["quiescence"]["kind"],
            "cancelled"
        );
        unsafe { free_session(db, session) };
    }

    #[test]
    fn free_accepts_null() {
        unsafe { zcashlc_voting_session_free(std::ptr::null_mut()) };
    }

    /// A null session is a host mistake every entry point reports the same
    /// way: null with typed JSON for the ones that return a result, and
    /// nothing at all for the two that return none.
    #[test]
    fn entry_points_reject_a_null_session() {
        let null = std::ptr::null_mut();
        let empty_array = b"[]";
        refused("plan", unsafe { zcashlc_voting_session_plan(null) });
        refused("set_ballot_intents", unsafe {
            zcashlc_voting_session_set_ballot_intents(null, empty_array.as_ptr(), empty_array.len())
        });
        refused("setup_bundles", unsafe {
            zcashlc_voting_session_setup_bundles(null)
        });
        refused("eligibility", unsafe {
            zcashlc_voting_session_eligibility(null)
        });
        refused("precompute_pir", unsafe {
            zcashlc_voting_session_precompute_pir(null, 0)
        });
        refused("precompute_delegation_proof", unsafe {
            zcashlc_voting_session_precompute_delegation_proof(null, 0, None, std::ptr::null_mut())
        });
        refused("keystone_signing_requests", unsafe {
            zcashlc_voting_session_keystone_signing_requests(
                null,
                empty_array.as_ptr(),
                empty_array.len(),
            )
        });
        refused("store_keystone_signatures", unsafe {
            zcashlc_voting_session_store_keystone_signatures(
                null,
                empty_array.as_ptr(),
                empty_array.len(),
            )
        });
        refused("run", unsafe {
            zcashlc_voting_session_run(
                null,
                std::ptr::null(),
                0,
                SIGNER_NONE.as_ptr(),
                SIGNER_NONE.len(),
                std::ptr::null(),
                0,
                None,
                std::ptr::null_mut(),
            )
        });
        refused("track_shares", unsafe {
            zcashlc_voting_session_track_shares(
                null,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                None,
                std::ptr::null_mut(),
            )
        });
        // Neither of these can report anything, so what must hold is that a
        // null handle is ignored rather than dereferenced.
        unsafe { zcashlc_voting_session_cancel(null) };
        unsafe { zcashlc_voting_session_set_epoch(null, 9) };
    }

    /// The plan crosses as the `RoundPlanView` JSON Swift decodes, for the
    /// round the session was opened against.
    #[test]
    fn plan_returns_the_round_plan_as_json() {
        let (db, _dir, session) = open_session(0x53);
        let plan = unsafe { take_json(zcashlc_voting_session_plan(session)) };
        assert_eq!(plan["round_id"], hex_round_id(0x53));
        // The fixture roster is undecided, so the round owes a draft.
        assert_eq!(plan["needs_draft_setup"], true);
        unsafe { free_session(db, session) };
    }

    /// Malformed JSON is refused at the boundary, before the session is asked
    /// to do anything with it.
    #[test]
    fn json_arguments_are_refused_as_invalid_input() {
        let (db, _dir, session) = open_session(0x54);
        let malformed = b"not json";
        refused("set_ballot_intents", unsafe {
            zcashlc_voting_session_set_ballot_intents(session, malformed.as_ptr(), malformed.len())
        });
        refused("keystone_signing_requests", unsafe {
            zcashlc_voting_session_keystone_signing_requests(
                session,
                malformed.as_ptr(),
                malformed.len(),
            )
        });
        refused("store_keystone_signatures", unsafe {
            zcashlc_voting_session_store_keystone_signatures(
                session,
                malformed.as_ptr(),
                malformed.len(),
            )
        });
        refused("run", unsafe {
            zcashlc_voting_session_run(
                session,
                std::ptr::null(),
                0,
                malformed.as_ptr(),
                malformed.len(),
                std::ptr::null(),
                0,
                None,
                std::ptr::null_mut(),
            )
        });
        unsafe { free_session(db, session) };
    }

    /// A run always names its signer: an empty argument is the host having
    /// forgotten one, not a run without delegation — which is
    /// `{"kind":"none"}`.
    #[test]
    fn run_requires_an_explicit_signer() {
        let (db, _dir, session) = open_session(0x55);
        refused("run", unsafe {
            zcashlc_voting_session_run(
                session,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                None,
                std::ptr::null_mut(),
            )
        });
        unsafe { free_session(db, session) };
    }

    /// A Keystone batch names at least one bundle, in either direction of the
    /// QR flow.
    #[test]
    fn keystone_batches_reject_empty_arrays() {
        let (db, _dir, session) = open_session(0x56);
        let empty_array = b"[]";
        refused("keystone_signing_requests", unsafe {
            zcashlc_voting_session_keystone_signing_requests(
                session,
                empty_array.as_ptr(),
                empty_array.len(),
            )
        });
        refused("store_keystone_signatures", unsafe {
            zcashlc_voting_session_store_keystone_signatures(
                session,
                empty_array.as_ptr(),
                empty_array.len(),
            )
        });
        unsafe { free_session(db, session) };
    }

    /// A tracking run with no policy of its own runs under the defaults,
    /// streams its passes to the host's callback and returns the report that
    /// says why it stopped. Nothing here reaches a helper: the round holds no
    /// share to track.
    #[test]
    fn track_shares_streams_events_to_the_host_callback() {
        let (db, _dir, session) = open_session(0x57);
        let collected = std::sync::Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let context = std::sync::Arc::as_ptr(&collected)
            .cast::<std::ffi::c_void>()
            .cast_mut();
        let report = unsafe {
            zcashlc_voting_session_track_shares(
                session,
                std::ptr::null(),
                0,
                std::ptr::null(),
                0,
                Some(collect),
                context,
            )
        };
        assert!(!report.is_null());
        let report = unsafe { take_json(report) };
        assert_eq!(report["quiescence"]["kind"], "nothing_to_track");
        assert_eq!(report["passes"], 1);

        let events = collected.lock().expect("collected events").clone();
        assert!(!events.is_empty(), "the pass reported no event at all");
        for json in &events {
            let event: serde_json::Value = serde_json::from_str(json).expect("event JSON");
            assert_eq!(event["kind"], "share_tracking");
            assert!(
                event["event"].is_object(),
                "a share_tracking event carries the driver event: {json}"
            );
        }
        unsafe { free_session(db, session) };
    }

    /// The proof status is an object rather than the bare JSON string the
    /// status enum serializes as, so Swift decodes one shape from every entry
    /// point here and the payload can grow a field later.
    #[test]
    fn proof_status_crosses_as_an_object() {
        assert_eq!(
            serde_json::to_value(ProofStatusResponse {
                status: ProofStatusDto::Reused,
            })
            .expect("proof status JSON"),
            serde_json::json!({ "status": "reused" })
        );
    }

    /// The proving thread's failure path over the C surface: a bundle this
    /// round never set up. The pipeline refuses it while reading the wallet,
    /// so no endpoint is dialled, and the failure crosses the join as typed
    /// JSON rather than as a panic.
    #[test]
    fn precompute_delegation_proof_without_bundles_is_a_typed_error() {
        let (db, _dir, session) = open_session(0x58);
        let status = unsafe {
            zcashlc_voting_session_precompute_delegation_proof(
                session,
                0,
                None,
                std::ptr::null_mut(),
            )
        };
        assert!(status.is_null());
        assert!(matches!(
            last_error_kind().as_str(),
            "no_spendable_notes" | "insufficient_eligibility"
        ));
        unsafe { free_session(db, session) };
    }

    /// Freeing the handle while a run is in flight releases the host's
    /// reference and nothing else: the call took its own when it read the
    /// pointer, so the round outlives the free and still returns its report.
    ///
    /// Driven through the event callback rather than by timing: the tracking
    /// run parks in its first event, the test thread frees the handle while it
    /// is parked, and only then is the run let go. A free that dropped the
    /// round here would leave the driver running on freed memory.
    #[test]
    fn freeing_the_handle_during_a_run_is_safe() {
        let (db, _dir, session) = open_session(0x59);
        let (entered, entered_rx) = std::sync::mpsc::sync_channel(1);
        let (freed, freed_rx) = std::sync::mpsc::channel();
        let rendezvous = std::sync::Arc::new(FreeDuringRun {
            entered,
            freed: std::sync::Mutex::new(freed_rx),
            once: std::sync::Once::new(),
        });
        let context = SharedPtr(
            std::sync::Arc::as_ptr(&rendezvous)
                .cast::<std::ffi::c_void>()
                .cast_mut(),
        );
        let tracked = SharedPtr(session);

        let run = std::thread::spawn(move || {
            // Named whole rather than reached into: a closure that only ever
            // mentions `tracked.0` captures the raw pointer itself, which is
            // not `Send`, instead of the wrapper that says why moving it here
            // is sound.
            let (tracked, context) = (tracked, context);
            let report = unsafe {
                zcashlc_voting_session_track_shares(
                    tracked.0,
                    std::ptr::null(),
                    0,
                    std::ptr::null(),
                    0,
                    Some(park_until_freed),
                    context.0,
                )
            };
            assert!(!report.is_null());
            unsafe { take_json(report) }
        });

        entered_rx
            .recv_timeout(std::time::Duration::from_secs(60))
            .expect("the tracking run reported an event");
        unsafe { zcashlc_voting_session_free(session) };
        freed.send(()).expect("the tracking run waits");

        let report = run.join().expect("tracking thread");
        assert_eq!(report["quiescence"]["kind"], "nothing_to_track");
        unsafe { zcashlc_voting_db_free(db) };
    }
}
