//! JSON wire types crossing the voting FFI boundary.
//!
//! Every DTO here is the JSON shape Swift exchanges with the session and
//! store FFI: `serde`-derived, snake_case fields, byte fields base64 (RFC
//! 4648 standard alphabet, padded) via the `b64` / `b64_opt` serde `with`
//! modules. Conversions to and from the native `zcash_voting` types live
//! alongside each DTO so the boundary logic stays in one place.

use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use super::errors::VotingResultExt;

/// Serialize `[u8]` as a standard-alphabet, padded base64 string; deserialize back.
///
/// Used via `#[serde(with = "b64")]` on every non-optional byte field crossing
/// the wire boundary.
pub(super) mod b64 {
    use base64::Engine;
    use base64::engine::general_purpose::STANDARD;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(&STANDARD.encode(bytes))
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let encoded = String::deserialize(deserializer)?;
        STANDARD.decode(encoded).map_err(serde::de::Error::custom)
    }
}

/// Like [`b64`], but for `Option<Vec<u8>>`: an absent or JSON-`null` field
/// decodes to `None`; any other value decodes as base64.
///
/// Pair with `#[serde(default, with = "b64_opt")]` so a missing field also
/// decodes to `None` rather than failing with "missing field".
pub(super) mod b64_opt {
    use base64::Engine;
    use base64::engine::general_purpose::STANDARD;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S>(bytes: &Option<Vec<u8>>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match bytes {
            Some(bytes) => serializer.serialize_some(&STANDARD.encode(bytes)),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Option<Vec<u8>>, D::Error>
    where
        D: Deserializer<'de>,
    {
        let encoded: Option<String> = Option::deserialize(deserializer)?;
        encoded
            .map(|encoded| STANDARD.decode(encoded).map_err(serde::de::Error::custom))
            .transpose()
    }
}

/// Project a crate round plan onto the wire view Swift decodes.
///
/// `RoundPlanView::try_from` is fallible — the view restates a plan's step
/// payloads in a shape that need not hold for every plan the crate can build —
/// so every caller has to map that failure onto the JSON envelope. There are
/// three of them (the session's `plan` and `set_ballot_intents`, and the
/// store's `round_plan`), and they must answer alike, so the projection lives
/// here once.
pub(super) fn plan_view(
    plan: zcash_voting::session::RoundPlan,
) -> anyhow::Result<zcash_voting::wire::RoundPlanView> {
    zcash_voting::wire::RoundPlanView::try_from(plan).ffi()
}

/// Parameters for a voting round, sourced from the vote chain.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub(super) struct RoundParamsDto {
    pub vote_round_id: String,
    pub snapshot_height: u64,
    #[serde(with = "b64")]
    pub ea_pk: Vec<u8>,
    #[serde(with = "b64")]
    pub nc_root: Vec<u8>,
    #[serde(with = "b64")]
    pub nullifier_imt_root: Vec<u8>,
}

impl RoundParamsDto {
    pub(super) fn into_params(self) -> zcash_voting::VotingRoundParams {
        zcash_voting::VotingRoundParams {
            vote_round_id: self.vote_round_id,
            snapshot_height: self.snapshot_height,
            ea_pk: self.ea_pk,
            nc_root: self.nc_root,
            nullifier_imt_root: self.nullifier_imt_root,
        }
    }
}

/// PIR fleet shape negotiated for a round.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub(super) struct PirLayoutDto {
    pub pir_depth: u32,
    pub tier0_layers: u32,
    pub tier1_layers: u32,
    pub poly_len: u32,
}

impl PirLayoutDto {
    pub(super) fn into_layout(self) -> zcash_voting::config::PirLayout {
        zcash_voting::config::PirLayout {
            pir_depth: self.pir_depth,
            tier0_layers: self.tier0_layers,
            tier1_layers: self.tier1_layers,
            poly_len: self.poly_len,
        }
    }
}

/// Everything needed to open a round session.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub(super) struct SessionInputsDto {
    pub account_uuid: String,
    pub wallet_db_path: String,
    pub round_params: RoundParamsDto,
    pub round_name: String,
    #[serde(with = "b64")]
    pub anchor_tree_state: Vec<u8>,
    pub chain_endpoints: Vec<String>,
    pub vote_tree_node_urls: Vec<String>,
    pub helper_urls: Vec<String>,
    pub pir_endpoints: Vec<String>,
    pub pir_layout: PirLayoutDto,
    pub ceremony_start_seconds: Option<u64>,
    pub vote_end_time_seconds: Option<u64>,
}

/// One roster proposal: its id and the number of selectable options.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub(super) struct RosterEntryDto {
    pub proposal_id: u32,
    pub num_options: u32,
}

/// The authenticated roster plus an optional stored hotkey secret to bind a
/// session to a previously generated hotkey.
///
/// No derived `Debug`: `hotkey_secret` is key material, and a derived
/// rendering would print it. The hand-written one below redacts it.
#[derive(Serialize, Deserialize, Clone, PartialEq, Eq)]
pub(super) struct SessionBindingDto {
    pub roster: Vec<RosterEntryDto>,
    #[serde(default, with = "b64_opt")]
    pub hotkey_secret: Option<Vec<u8>>,
}

impl std::fmt::Debug for SessionBindingDto {
    /// Names each field rather than deriving: a field added without a thought
    /// for this impl goes missing from the rendering instead of into it.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SessionBindingDto")
            .field("roster", &self.roster)
            .field(
                "hotkey_secret",
                &self.hotkey_secret.as_ref().map(|_| "[redacted]"),
            )
            .finish()
    }
}

/// A voter's decision for one proposal, internally tagged by `"decision"`.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(tag = "decision", rename_all = "snake_case")]
pub(super) enum DecisionDto {
    Choice { option: u32 },
    Skipped,
}

/// One ballot decision to record before casting.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
pub(super) struct BallotIntentDto {
    pub proposal_id: u32,
    #[serde(flatten)]
    pub decision: DecisionDto,
}

impl BallotIntentDto {
    pub(super) fn into_intent(self) -> zcash_voting::BallotIntent {
        zcash_voting::BallotIntent {
            proposal_id: self.proposal_id,
            decision: match self.decision {
                DecisionDto::Choice { option } => zcash_voting::session::Decision::Choice(option),
                DecisionDto::Skipped => zcash_voting::session::Decision::Skipped,
            },
        }
    }
}

/// Which signer backs a session, as it arrives on the wire: none yet, an
/// in-process software seed, or a Keystone hardware signer whose signatures are
/// already stored.
///
/// The wire shape only. [`SignerDto::into_signer`] is called on it the moment
/// it is decoded, and [`Signer`] is what the session runs with.
///
/// No derived `Debug`: the software variant carries the wallet seed, and a
/// derived rendering would print it. The hand-written one below redacts it.
#[derive(Serialize, Deserialize, Clone, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub(super) enum SignerDto {
    None,
    Software {
        #[serde(with = "b64")]
        seed: Vec<u8>,
    },
    KeystoneStored,
}

impl std::fmt::Debug for SignerDto {
    /// Matches the software variant without binding its field, so no field of
    /// it can reach the formatter, now or after someone adds one.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SignerDto::None => f.write_str("SignerDto::None"),
            SignerDto::Software { .. } => f.write_str("SignerDto::Software { seed: [redacted] }"),
            SignerDto::KeystoneStored => f.write_str("SignerDto::KeystoneStored"),
        }
    }
}

/// Which signer backs a session, as the session holds it: the software seed
/// has been moved into a buffer that wipes itself when dropped.
///
/// The move happens as soon as the JSON is decoded, so everything that can
/// still fail after that — another argument that will not decode, a session
/// that refuses the call, a signer that will not build — drops a wiped buffer
/// rather than leaving the seed in freed memory.
///
/// What this cannot cover is serde's own intermediate. The seed arrives as
/// base64 text, and the `String` `serde_json` allocates while decoding it is
/// dropped without being wiped; serde offers no hook to change that. Closing
/// that last gap would mean the seed crossing as its own `(ptr, len)`
/// argument, which is a change to the C surface.
///
/// Deliberately no `Debug`: `Zeroizing<Vec<u8>>` renders as its bytes.
pub(super) enum Signer {
    None,
    Software(Zeroizing<Vec<u8>>),
    KeystoneStored,
}

impl SignerDto {
    /// Moves a software seed out of the decoded DTO and into a buffer that
    /// wipes itself.
    pub(super) fn into_signer(self) -> Signer {
        match self {
            SignerDto::None => Signer::None,
            // `Zeroizing::new` takes the `Vec` by value, so this is the same
            // allocation — now wiped on drop — rather than a second copy of
            // the seed.
            SignerDto::Software { seed } => Signer::Software(Zeroizing::new(seed)),
            SignerDto::KeystoneStored => Signer::KeystoneStored,
        }
    }
}

/// How the round driver paces itself between steps and isolates failures.
///
/// Mirrors `zcash_voting::FailureIsolation`'s variants.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(super) enum FailureIsolationDto {
    SkipBundle,
    StopRound,
}

/// What a run's progress total is measured against.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(super) enum ProgressBaselineDto {
    Run,
    SelectedChoices,
}

/// Swift-tunable overrides for [`zcash_voting::RoundDrivePolicy`], plus the
/// SDK-only `max_proof_concurrency` cap. Every field defaults independently
/// when absent from JSON.
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub(super) struct DrivePolicyDto {
    #[serde(default)]
    pub pending_repoll_seconds: Option<f64>,
    #[serde(default)]
    pub max_bundle_concurrency: Option<usize>,
    #[serde(default)]
    pub failure_isolation: Option<FailureIsolationDto>,
    #[serde(default)]
    pub max_dispatches: Option<usize>,
    #[serde(default)]
    pub progress_baseline: Option<ProgressBaselineDto>,
    #[serde(default)]
    pub max_proof_concurrency: Option<usize>,
}

impl DrivePolicyDto {
    // Defaults: repoll 2s, bundle concurrency 2, skip_bundle, 512 dispatches,
    // run baseline, proof concurrency 1.
    //
    // The struct-literal form clippy suggests inlines two `match` expressions
    // into one expression, which reads worse than default-then-override.
    #[allow(clippy::field_reassign_with_default)]
    pub(super) fn into_policy(self) -> (zcash_voting::RoundDrivePolicy, usize) {
        use std::num::NonZeroUsize;
        let mut policy = zcash_voting::RoundDrivePolicy::default();
        policy.pending_repoll =
            std::time::Duration::from_secs_f64(self.pending_repoll_seconds.unwrap_or(2.0));
        policy.max_bundle_concurrency = NonZeroUsize::new(self.max_bundle_concurrency.unwrap_or(2))
            .unwrap_or(NonZeroUsize::MIN);
        policy.failure_isolation = match self
            .failure_isolation
            .unwrap_or(FailureIsolationDto::SkipBundle)
        {
            FailureIsolationDto::SkipBundle => zcash_voting::FailureIsolation::SkipBundle,
            FailureIsolationDto::StopRound => zcash_voting::FailureIsolation::StopRound,
        };
        policy.max_dispatches = self.max_dispatches.unwrap_or(512);
        policy.progress_baseline = match self.progress_baseline.unwrap_or(ProgressBaselineDto::Run)
        {
            ProgressBaselineDto::Run => zcash_voting::ProgressBaseline::Run,
            ProgressBaselineDto::SelectedChoices => zcash_voting::ProgressBaseline::SelectedChoices,
        };
        (policy, self.max_proof_concurrency.unwrap_or(1).max(1))
    }
}

/// Swift-tunable per-round overrides applied on top of the stored round
/// config. Each field is independently absent (no override), explicitly
/// cleared, or set: see [`Self::ceremony_start_seconds`].
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub(super) struct HostOverridesDto {
    #[serde(default)]
    pub helper_urls: Option<Vec<String>>,
    #[serde(default)]
    pub vote_tree_node_urls: Option<Vec<String>>,
    #[serde(default)]
    pub ceremony_start_seconds: Option<Option<u64>>,
    #[serde(default)]
    pub vote_end_time_seconds: Option<Option<u64>>,
}

/// Swift-tunable overrides for [`zcash_voting::ShareTrackingDrivePolicy`].
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq)]
pub(super) struct ShareTrackingPolicyDto {
    #[serde(default)]
    pub failure_retry_seconds: Option<f64>,
    #[serde(default)]
    pub max_consecutive_failures: Option<u32>,
    #[serde(default)]
    pub max_passes: Option<u32>,
}

impl ShareTrackingPolicyDto {
    // Defaults: failure retry 15s, 240 consecutive failures, no pass budget —
    // matching `zcash_voting::ShareTrackingDrivePolicy::default()` exactly
    // (its `timing` field is left at the crate's own default throughout).
    pub(super) fn into_policy(self) -> zcash_voting::ShareTrackingDrivePolicy {
        zcash_voting::ShareTrackingDrivePolicy {
            failure_retry: std::time::Duration::from_secs_f64(
                self.failure_retry_seconds.unwrap_or(15.0),
            ),
            max_consecutive_failures: self.max_consecutive_failures.unwrap_or(240),
            max_passes: self.max_passes,
            ..zcash_voting::ShareTrackingDrivePolicy::default()
        }
    }
}

/// Swift-tunable overrides for [`zcash_voting::ProvingPolicy`].
///
/// Unlike the upstream crate's own `Default` (which sizes both fields to
/// `available_parallelism`), this SDK's default keeps `max_active_heavy_jobs`
/// at 1: CPU workers may run wide, but only one heavy proof/keygen job is
/// admitted at a time unless Swift raises it explicitly. A phone that admits
/// two Orchard proofs at once is the memory-pressure kill this SDK cannot
/// recover from, so the ceiling is the host's to raise, never the default.
#[derive(Serialize, Deserialize, Default, Clone, Debug, PartialEq, Eq)]
pub(super) struct ProvingPolicyDto {
    #[serde(default)]
    pub cpu_worker_count: Option<usize>,
    #[serde(default)]
    pub max_active_heavy_jobs: Option<usize>,
}

impl ProvingPolicyDto {
    pub(super) fn into_policy(self) -> zcash_voting::ProvingPolicy {
        use std::num::NonZeroUsize;
        let available = std::thread::available_parallelism().unwrap_or(NonZeroUsize::MIN);
        zcash_voting::ProvingPolicy {
            cpu_worker_count: self
                .cpu_worker_count
                .and_then(NonZeroUsize::new)
                .unwrap_or(available),
            max_active_heavy_jobs: self
                .max_active_heavy_jobs
                .and_then(NonZeroUsize::new)
                .unwrap_or(NonZeroUsize::MIN),
        }
    }
}

/// Compact round info for the store FFI's round listing.
#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
pub(super) struct RoundSummaryDto {
    pub round_id: String,
    pub wallet_id: String,
    pub phase: String,
    pub network: String,
    pub snapshot_height: u64,
    pub created_at: u64,
}

impl From<zcash_voting::storage::RoundSummary> for RoundSummaryDto {
    fn from(summary: zcash_voting::storage::RoundSummary) -> Self {
        RoundSummaryDto {
            round_id: summary.round_id,
            wallet_id: summary.wallet_id,
            phase: format!("{:?}", summary.phase).to_lowercase(),
            network: format!("{:?}", summary.network).to_lowercase(),
            snapshot_height: summary.snapshot_height,
            created_at: summary.created_at,
        }
    }
}

/// Delegation bundle layout after quantizing eligible notes.
#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
pub(super) struct BundleLayoutDto {
    pub bundle_count: u32,
    pub eligible_weight: u64,
    pub dropped_count: u32,
    pub privacy_trim_dropped_bundles: u32,
    pub privacy_trim_dropped_notes: u32,
}

/// Voting eligibility computed for the wallet's snapshot notes.
#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
pub(super) struct EligibilityDto {
    pub distinct_note_count: u64,
    pub eligible_weight: u64,
    pub is_eligible: bool,
    pub privacy_trim_dropped_value_zatoshi: u64,
}

/// Progress of PIR precompute for one delegation bundle.
#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
pub(super) struct PirPrecomputeDto {
    pub bundle_index: u32,
    pub cached: u32,
    pub fetched: u32,
    pub bundle_count: u32,
}

/// Whether a proof was freshly generated or reused from the shared cache.
#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub(super) enum ProofStatusDto {
    Generated,
    Reused,
}

/// One delegation-pipeline progress observation for one bundle.
///
/// `stage` is one of: `selecting_notes`, `pczt_building`, `pczt_built`,
/// `proof_starting`, `waiting_for_existing_proof`, `proof_progress`,
/// `proof_complete`, `signing_payload`, `payload_ready` — or `unknown` for a
/// stage a newer `zcash_voting` reports that this SDK does not name yet, since
/// the crate's progress enum is `#[non_exhaustive]`.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub(super) struct DelegationProgressDto {
    pub bundle_index: u32,
    pub stage: String,
    pub fraction: Option<f64>,
}

/// One bundle's voting PCZT, redacted for signing by a Keystone device.
#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
pub(super) struct KeystoneSigningRequestDto {
    pub bundle_index: u32,
    pub bundle_count: u32,
    #[serde(with = "b64")]
    pub redacted_pczt: Vec<u8>,
    #[serde(with = "b64")]
    pub pczt_sighash: Vec<u8>,
    #[serde(with = "b64")]
    pub rk: Vec<u8>,
    pub action_index: u32,
    pub display_memo: String,
    pub eligible_weight_zatoshi: u64,
    pub delegated_weight_zatoshi: u64,
}

impl From<zcash_voting::delegate::KeystoneSigningRequest> for KeystoneSigningRequestDto {
    fn from(request: zcash_voting::delegate::KeystoneSigningRequest) -> Self {
        KeystoneSigningRequestDto {
            bundle_index: request.bundle_index,
            bundle_count: request.bundle_count,
            redacted_pczt: request.redacted_pczt_bytes,
            pczt_sighash: request.pczt_sighash,
            rk: request.rk,
            action_index: request.action_index,
            display_memo: request.display_memo,
            eligible_weight_zatoshi: request.eligible_weight_zatoshi,
            delegated_weight_zatoshi: request.delegated_weight_zatoshi,
        }
    }
}

/// A Keystone-signed bundle PCZT returned from the QR scanning flow.
#[derive(Deserialize, Clone, Debug, PartialEq, Eq)]
pub(super) struct KeystoneSignedBundleDto {
    pub bundle_index: u32,
    #[serde(with = "b64")]
    pub signed_pczt: Vec<u8>,
}

/// Outcome of storing a batch of Keystone signatures.
#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
pub(super) struct KeystoneSignatureBatchResultDto {
    pub inserted: u32,
    pub already_present: u32,
}

/// One stored Keystone signature, for `KeystoneSignatureSource::Stored` reuse.
#[derive(Serialize, Clone, Debug, PartialEq, Eq)]
pub(super) struct KeystoneSignatureRecordDto {
    pub bundle_index: u32,
    #[serde(with = "b64")]
    pub sig: Vec<u8>,
    #[serde(with = "b64")]
    pub sighash: Vec<u8>,
    #[serde(with = "b64")]
    pub rk: Vec<u8>,
}

impl From<zcash_voting::wire::KeystoneSignatureRecord> for KeystoneSignatureRecordDto {
    fn from(record: zcash_voting::wire::KeystoneSignatureRecord) -> Self {
        KeystoneSignatureRecordDto {
            bundle_index: record.bundle_index,
            sig: record.sig,
            sighash: record.sighash,
            rk: record.rk,
        }
    }
}

/// One event from a session's live event stream, internally tagged by `"kind"`.
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub(super) enum SessionEventDto {
    // Boxed: `RoundDriveEventView` is hundreds of bytes wider than the other
    // variants' payloads, so an unboxed field would size every `SessionEventDto`
    // (including the frequent `DelegationProgress` ticks) to its footprint.
    // `Box<T>` serializes identically to `T` (serde's impl just delegates), so
    // this does not change the JSON shape.
    RoundDrive {
        event: Box<zcash_voting::wire::RoundDriveEventView>,
    },
    ShareTracking {
        event: zcash_voting::wire::ShareTrackingEventView,
    },
    DelegationProgress {
        progress: DelegationProgressDto,
    },
}

#[cfg(test)]
mod tests {
    use base64::Engine;
    use base64::engine::general_purpose::STANDARD;

    use super::*;

    #[test]
    fn round_params_dto_round_trips_through_json_and_into_params() {
        let ea_pk = vec![0xffu8, 0xff, 0xff]; // standard alphabet, no padding: "////"
        let nc_root = vec![0xffu8]; // standard alphabet, padded: "/w=="
        let nullifier_imt_root = vec![1u8, 2, 3, 4, 5];

        let dto = RoundParamsDto {
            vote_round_id: "round-7".to_string(),
            snapshot_height: 123_456,
            ea_pk: ea_pk.clone(),
            nc_root: nc_root.clone(),
            nullifier_imt_root: nullifier_imt_root.clone(),
        };

        let json = serde_json::to_value(&dto).expect("serialize");
        assert_eq!(
            json,
            serde_json::json!({
                "vote_round_id": "round-7",
                "snapshot_height": 123_456,
                "ea_pk": "////",
                "nc_root": "/w==",
                "nullifier_imt_root": STANDARD.encode(&nullifier_imt_root),
            })
        );

        let round_tripped: RoundParamsDto = serde_json::from_value(json).expect("deserialize");
        assert_eq!(round_tripped, dto);

        assert_eq!(
            dto.into_params(),
            zcash_voting::VotingRoundParams {
                vote_round_id: "round-7".to_string(),
                snapshot_height: 123_456,
                ea_pk,
                nc_root,
                nullifier_imt_root,
            }
        );
    }

    #[test]
    fn ballot_intent_dto_decodes_choice_and_skipped() {
        let choice: BallotIntentDto =
            serde_json::from_str(r#"{"proposal_id":3,"decision":"choice","option":1}"#)
                .expect("choice");
        assert_eq!(choice.decision, DecisionDto::Choice { option: 1 });
        assert_eq!(
            choice.into_intent(),
            zcash_voting::BallotIntent {
                proposal_id: 3,
                decision: zcash_voting::session::Decision::Choice(1),
            }
        );

        let skipped: BallotIntentDto =
            serde_json::from_str(r#"{"proposal_id":4,"decision":"skipped"}"#).expect("skipped");
        assert_eq!(skipped.decision, DecisionDto::Skipped);
        assert_eq!(
            skipped.into_intent(),
            zcash_voting::BallotIntent {
                proposal_id: 4,
                decision: zcash_voting::session::Decision::Skipped,
            }
        );
    }

    #[test]
    fn signer_dto_decodes_software_variant() {
        let seed = vec![9u8, 8, 7, 6, 5];
        let json = serde_json::json!({
            "kind": "software",
            "seed": STANDARD.encode(&seed),
        });

        let signer: SignerDto = serde_json::from_value(json).expect("decode");
        assert_eq!(signer, SignerDto::Software { seed });
    }

    /// Neither secret-bearing DTO renders what it carries. Both are formatted
    /// nowhere today; what this pins is that adding a `{:?}` somewhere cannot
    /// turn into a printed seed or hotkey secret.
    #[test]
    fn secret_bearing_dtos_redact_their_debug_rendering() {
        let signer = SignerDto::Software {
            seed: vec![9u8; 32],
        };
        let rendered = format!("{signer:?}");
        assert!(rendered.contains("[redacted]"), "unexpected: {rendered}");
        assert!(!rendered.contains('9'), "unexpected: {rendered}");

        let binding = SessionBindingDto {
            roster: vec![RosterEntryDto {
                proposal_id: 1,
                num_options: 2,
            }],
            hotkey_secret: Some(vec![7u8; 32]),
        };
        let rendered = format!("{binding:?}");
        assert!(rendered.contains("[redacted]"), "unexpected: {rendered}");
        assert!(!rendered.contains('7'), "unexpected: {rendered}");
        // Whether a secret is bound at all is not the secret, and a host
        // debugging a binding needs it.
        assert!(rendered.contains("Some"), "unexpected: {rendered}");
    }

    #[test]
    fn signer_dto_round_trips_none_and_keystone_stored() {
        assert_eq!(
            serde_json::to_value(SignerDto::None).unwrap(),
            serde_json::json!({"kind": "none"})
        );
        assert_eq!(
            serde_json::from_value::<SignerDto>(serde_json::json!({"kind": "none"})).unwrap(),
            SignerDto::None
        );

        assert_eq!(
            serde_json::to_value(SignerDto::KeystoneStored).unwrap(),
            serde_json::json!({"kind": "keystone_stored"})
        );
        assert_eq!(
            serde_json::from_value::<SignerDto>(serde_json::json!({"kind": "keystone_stored"}))
                .unwrap(),
            SignerDto::KeystoneStored
        );
    }

    #[test]
    fn drive_policy_dto_empty_json_yields_documented_defaults() {
        let dto: DrivePolicyDto = serde_json::from_str("{}").expect("empty object");
        assert_eq!(dto, DrivePolicyDto::default());

        let (policy, max_proof_concurrency) = dto.into_policy();
        assert_eq!(policy.pending_repoll, std::time::Duration::from_secs(2));
        assert_eq!(
            policy.max_bundle_concurrency,
            std::num::NonZeroUsize::new(2).unwrap()
        );
        assert_eq!(
            policy.failure_isolation,
            zcash_voting::FailureIsolation::SkipBundle
        );
        assert_eq!(policy.max_dispatches, 512);
        assert_eq!(
            policy.progress_baseline,
            zcash_voting::ProgressBaseline::Run
        );
        assert_eq!(max_proof_concurrency, 1);
    }

    #[test]
    fn share_tracking_policy_dto_empty_json_yields_documented_defaults() {
        let dto: ShareTrackingPolicyDto = serde_json::from_str("{}").expect("empty object");
        assert_eq!(dto, ShareTrackingPolicyDto::default());

        let policy = dto.into_policy();
        assert_eq!(policy.failure_retry, std::time::Duration::from_secs(15));
        assert_eq!(policy.max_consecutive_failures, 240);
        assert_eq!(policy.max_passes, None);
    }

    #[test]
    fn proving_policy_dto_empty_json_yields_available_parallelism_and_one_heavy_job() {
        let dto: ProvingPolicyDto = serde_json::from_str("{}").expect("empty object");
        assert_eq!(dto, ProvingPolicyDto::default());

        let policy = dto.into_policy();
        let expected_workers =
            std::thread::available_parallelism().unwrap_or(std::num::NonZeroUsize::MIN);
        assert_eq!(policy.cpu_worker_count, expected_workers);
        assert_eq!(
            policy.max_active_heavy_jobs,
            std::num::NonZeroUsize::new(1).unwrap()
        );
    }

    #[test]
    fn session_event_dto_delegation_progress_serializes_with_snake_case_kind() {
        let event = SessionEventDto::DelegationProgress {
            progress: DelegationProgressDto {
                bundle_index: 2,
                stage: "proof_progress".to_string(),
                fraction: Some(0.5),
            },
        };

        let json = serde_json::to_value(&event).expect("serialize");
        assert_eq!(
            json,
            serde_json::json!({
                "kind": "delegation_progress",
                "progress": {
                    "bundle_index": 2,
                    "stage": "proof_progress",
                    "fraction": 0.5,
                }
            })
        );
    }

    /// Both halves of the ceremony window are bare `Option<u64>` with no
    /// `serde(default)`, and Swift omits an absent one rather than writing
    /// `null`. What makes that work is serde resolving a missing field to
    /// `None` for an `Option`, which is a property of serde rather than of this
    /// DTO — so it is pinned here, on the shape every host that leaves those
    /// inputs at their defaults actually sends.
    #[test]
    fn session_inputs_dto_decodes_without_the_optional_ceremony_window() {
        let json = serde_json::json!({
            "account_uuid": "11111111-1111-1111-1111-111111111111",
            "wallet_db_path": "/tmp/wallet.sqlite3",
            "round_params": {
                "vote_round_id": "round-1",
                "snapshot_height": 10,
                "ea_pk": STANDARD.encode([1u8, 2, 3]),
                "nc_root": STANDARD.encode([4u8, 5, 6]),
                "nullifier_imt_root": STANDARD.encode([7u8, 8, 9]),
            },
            "round_name": "Q3 governance",
            "anchor_tree_state": STANDARD.encode([1u8, 2, 3]),
            "chain_endpoints": ["https://chain.example"],
            "vote_tree_node_urls": ["https://tree.example"],
            "helper_urls": ["https://helper.example"],
            "pir_endpoints": ["https://pir.example"],
            "pir_layout": {
                "pir_depth": 19,
                "tier0_layers": 12,
                "tier1_layers": 7,
                "poly_len": 4096,
            },
        });

        let inputs: SessionInputsDto = serde_json::from_value(json).expect("absent window");

        assert_eq!(inputs.ceremony_start_seconds, None);
        assert_eq!(inputs.vote_end_time_seconds, None);
        // The rest still decoded, so this is an absent field rather than a
        // decode that gave up early.
        assert_eq!(inputs.round_name, "Q3 governance");
    }

    #[test]
    fn session_binding_dto_hotkey_secret_defaults_absent_and_null_to_none() {
        let absent: SessionBindingDto =
            serde_json::from_str(r#"{"roster":[]}"#).expect("absent field");
        assert_eq!(absent.hotkey_secret, None);

        let null: SessionBindingDto =
            serde_json::from_str(r#"{"roster":[],"hotkey_secret":null}"#).expect("null field");
        assert_eq!(null.hotkey_secret, None);

        let secret = vec![1u8, 2, 3];
        let present_json = serde_json::json!({
            "roster": [{"proposal_id": 1, "num_options": 2}],
            "hotkey_secret": STANDARD.encode(&secret),
        });
        let present: SessionBindingDto = serde_json::from_value(present_json).expect("present");
        assert_eq!(present.hotkey_secret, Some(secret));
        assert_eq!(
            present.roster,
            vec![RosterEntryDto {
                proposal_id: 1,
                num_options: 2
            }]
        );
    }

    #[test]
    fn pir_layout_dto_into_layout_maps_fields() {
        let dto = PirLayoutDto {
            pir_depth: 3,
            tier0_layers: 4,
            tier1_layers: 5,
            poly_len: 4096,
        };
        assert_eq!(
            dto.into_layout(),
            zcash_voting::config::PirLayout {
                pir_depth: 3,
                tier0_layers: 4,
                tier1_layers: 5,
                poly_len: 4096,
            }
        );
    }

    #[test]
    fn round_summary_dto_from_lowercases_phase_and_network_debug() {
        let summary = zcash_voting::storage::RoundSummary {
            round_id: "r1".to_string(),
            wallet_id: "w1".to_string(),
            phase: zcash_voting::storage::RoundPhase::DelegationConstructed,
            network: zcash_voting::Network::Testnet,
            snapshot_height: 42,
            created_at: 99,
        };

        assert_eq!(
            RoundSummaryDto::from(summary),
            RoundSummaryDto {
                round_id: "r1".to_string(),
                wallet_id: "w1".to_string(),
                phase: "delegationconstructed".to_string(),
                network: "testnet".to_string(),
                snapshot_height: 42,
                created_at: 99,
            }
        );
    }

    #[test]
    fn keystone_signing_request_dto_from_maps_fields_and_drops_full_pczt() {
        let request = zcash_voting::delegate::KeystoneSigningRequest {
            pczt_bytes: vec![0xAA],
            redacted_pczt_bytes: vec![1, 2, 3],
            pczt_sighash: vec![4, 5, 6],
            rk: vec![7, 8, 9],
            action_index: 1,
            display_memo: "memo".to_string(),
            eligible_weight_zatoshi: 1000,
            delegated_weight_zatoshi: 500,
            bundle_count: 3,
            bundle_index: 1,
        };

        assert_eq!(
            KeystoneSigningRequestDto::from(request),
            KeystoneSigningRequestDto {
                bundle_index: 1,
                bundle_count: 3,
                redacted_pczt: vec![1, 2, 3],
                pczt_sighash: vec![4, 5, 6],
                rk: vec![7, 8, 9],
                action_index: 1,
                display_memo: "memo".to_string(),
                eligible_weight_zatoshi: 1000,
                delegated_weight_zatoshi: 500,
            }
        );
    }

    #[test]
    fn host_overrides_dto_default_has_no_overrides_and_round_trips_empty_json() {
        let dto = HostOverridesDto::default();
        assert_eq!(dto.helper_urls, None);
        assert_eq!(dto.vote_tree_node_urls, None);
        assert_eq!(dto.ceremony_start_seconds, None);
        assert_eq!(dto.vote_end_time_seconds, None);

        let round_tripped: HostOverridesDto = serde_json::from_str("{}").expect("empty object");
        assert_eq!(round_tripped, dto);
    }

    #[test]
    fn session_inputs_dto_round_trips_through_json() {
        let dto = SessionInputsDto {
            account_uuid: "11111111-1111-1111-1111-111111111111".to_string(),
            wallet_db_path: "/tmp/wallet.sqlite3".to_string(),
            round_params: RoundParamsDto {
                vote_round_id: "round-1".to_string(),
                snapshot_height: 10,
                ea_pk: vec![1, 2],
                nc_root: vec![3, 4],
                nullifier_imt_root: vec![5, 6],
            },
            round_name: "Q3 governance".to_string(),
            anchor_tree_state: vec![7, 8, 9],
            chain_endpoints: vec!["https://chain.example".to_string()],
            vote_tree_node_urls: vec!["https://tree.example".to_string()],
            helper_urls: vec!["https://helper.example".to_string()],
            pir_endpoints: vec!["https://pir.example".to_string()],
            pir_layout: PirLayoutDto {
                pir_depth: 1,
                tier0_layers: 2,
                tier1_layers: 3,
                poly_len: 2048,
            },
            ceremony_start_seconds: Some(1_700_000_000),
            vote_end_time_seconds: None,
        };

        let json = serde_json::to_string(&dto).expect("serialize");
        let round_tripped: SessionInputsDto = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(round_tripped, dto);
    }
}
