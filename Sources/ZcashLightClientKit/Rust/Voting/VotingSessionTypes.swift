//
//  VotingSessionTypes.swift
//  ZcashLightClientKit
//

import Foundation

// The live event stream a session narrates a run with, and the one-shot
// results its other calls answer with. As in `VotingRoundTypes`, every enum
// decodes an unrecognised value as `unknown`.

// MARK: - Step progress

/// Delegation proving and signing stages.
public enum VotingDelegationProgressKind: String, Equatable, Sendable, Decodable {
    case selectingNotes = "selecting_notes"
    case pcztBuilding = "pczt_building"
    case pcztBuilt = "pczt_built"
    case proofStarting = "proof_starting"
    case waitingForExistingProof = "waiting_for_existing_proof"
    case proofProgress = "proof_progress"
    case proofComplete = "proof_complete"
    case signingPayload = "signing_payload"
    case payloadReady = "payload_ready"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingDelegationProgressKind(rawValue: raw) ?? .unknown
    }
}

/// What one progress observation from inside a running step describes.
public enum VotingRoundStepProgressKind: String, Equatable, Sendable, Decodable {
    case selected
    case delegation
    case treeSynced = "tree_synced"
    case voteCommit = "vote_commit"
    /// The signed combined delegation-and-cast envelope is durable.
    case delegateAndVoteBatchPersisted = "delegate_and_vote_batch_persisted"
    case helperPlansPrepared = "helper_plans_prepared"
    case chainOutcome = "chain_outcome"
    case shareOutcome = "share_outcome"
    case shareConfirmed = "share_confirmed"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingRoundStepProgressKind(rawValue: raw) ?? .unknown
    }
}

/// One progress observation from inside a running step.
///
/// `kind` says which fields are populated: `bundleIndex`,
/// `delegationProgress` and `proofProgress` for
/// ``VotingRoundStepProgressKind/delegation``; `treeHeight` for
/// ``VotingRoundStepProgressKind/treeSynced``; `bundleIndex`, `proposalId` and
/// `proofProgress` for ``VotingRoundStepProgressKind/voteCommit``;
/// `shareConfirmed` for ``VotingRoundStepProgressKind/shareConfirmed``.
public struct VotingRoundStepProgress: Equatable, Sendable, Decodable {
    public let kind: VotingRoundStepProgressKind
    public let bundleIndex: UInt32?
    public let proposalId: UInt32?
    public let delegationProgress: VotingDelegationProgressKind?
    /// Proving progress in `0...1`.
    public let proofProgress: Double?
    public let treeHeight: UInt32?
    public let shareConfirmed: Bool?

    private enum CodingKeys: String, CodingKey {
        case kind
        case bundleIndex = "bundle_index"
        case proposalId = "proposal_id"
        case delegationProgress = "delegation_progress"
        case proofProgress = "proof_progress"
        case treeHeight = "tree_height"
        case shareConfirmed = "share_confirmed"
    }
}

// MARK: - Round drive events

/// What one observation from a round run describes.
public enum VotingRoundDriveEventKind: String, Equatable, Sendable, Decodable {
    case planRefreshed = "plan_refreshed"
    case stepSelected = "step_selected"
    case stepProgress = "step_progress"
    case stepFinished = "step_finished"
    case stepFailed = "step_failed"
    case awaitingRepoll = "awaiting_repoll"
    case bundleSkipped = "bundle_skipped"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingRoundDriveEventKind(rawValue: raw) ?? .unknown
    }
}

/// One observation from a round run.
///
/// Every variant that describes work names its `step`: a run overlaps bundles,
/// so a bare progress record would otherwise be misattributed. The stream is
/// lossy by design — ``VotingRoundRunReport`` is the authoritative answer.
public struct VotingRoundDriveEvent: Equatable, Sendable, Decodable {
    public let kind: VotingRoundDriveEventKind
    /// The step every work-describing kind belongs to.
    public let step: VotingNextStep?
    /// `planRefreshed`: the plan the driver selects from, and its tally.
    public let plan: VotingRoundPlan?
    public let tally: VotingRoundWorkTally?
    /// `stepProgress`: progress from inside the running step.
    public let progress: VotingRoundStepProgress?
    /// `stepFailed`: why it failed.
    public let failureKind: VotingRoundStepFailureKind?
    public let message: String?
    /// `awaitingRepoll`: how long the driver waits before trying the step
    /// again. Fractional, and it paces helper work as well as chain tracking,
    /// so read `step` rather than labelling the wait as chain work.
    public let delaySeconds: Double?
    /// `bundleSkipped`: the bundle isolated for the rest of the run.
    public let bundleIndex: UInt32?

    private enum CodingKeys: String, CodingKey {
        case kind
        case step
        case plan
        case tally
        case progress
        case failureKind = "failure_kind"
        case message
        case delaySeconds = "delay_seconds"
        case bundleIndex = "bundle_index"
    }
}

// MARK: - Share tracking

/// Why one share-tracking run stopped.
public enum VotingShareTrackingQuiescenceKind: String, Equatable, Sendable, Decodable {
    case nothingToTrack = "nothing_to_track"
    case allConfirmed = "all_confirmed"
    case voteEndReached = "vote_end_reached"
    case cancelled
    case alreadyDriving = "already_driving"
    case failing
    case passBudgetExhausted = "pass_budget_exhausted"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingShareTrackingQuiescenceKind(rawValue: raw) ?? .unknown
    }
}

/// Why one share-tracking run stopped, with the failures that ended it.
public struct VotingShareTrackingQuiescence: Equatable, Sendable, Decodable {
    public let kind: VotingShareTrackingQuiescenceKind
    /// `failing`: the consecutive failures that ended the run.
    public let messages: [String]

    private enum CodingKeys: String, CodingKey {
        case kind
        case messages
    }

    // `messages` is `#[serde(default)]` upstream: every kind but `failing`
    // leaves it out, and none of them should fail to decode for that.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(VotingShareTrackingQuiescenceKind.self, forKey: .kind)
        messages = try container.decodeIfPresent([String].self, forKey: .messages) ?? []
    }
}

/// What one observation from a share-tracking run describes.
public enum VotingShareTrackingEventKind: String, Equatable, Sendable, Decodable {
    case passStarted = "pass_started"
    case passFinished = "pass_finished"
    case passFailed = "pass_failed"
    case awaitingNextPass = "awaiting_next_pass"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingShareTrackingEventKind(rawValue: raw) ?? .unknown
    }
}

/// One observation from a share-tracking run.
public struct VotingShareTrackingEvent: Equatable, Sendable, Decodable {
    public let kind: VotingShareTrackingEventKind
    /// The pass this belongs to, counting from 1. Absent on
    /// ``VotingShareTrackingEventKind/awaitingNextPass``, which sits between
    /// two passes.
    public let pass: UInt32?
    /// `passFailed`: why.
    public let message: String?
    /// `awaitingNextPass`: how long the driver waits before the next one.
    public let delaySeconds: Double?

    private enum CodingKeys: String, CodingKey {
        case kind
        case pass
        case message
        case delaySeconds = "delay_seconds"
    }
}

/// Everything one share-tracking run did.
public struct VotingShareTrackingRunReport: Equatable, Sendable, Decodable {
    public let quiescence: VotingShareTrackingQuiescence
    public let passes: UInt32
    public let confirmed: [VotingShareKey]
    /// From the most recent pass, not accumulated: a share stops being
    /// unrecoverable once its material is restored.
    public let unrecoverable: [VotingShareKey]
    public let failures: [String]

    private enum CodingKeys: String, CodingKey {
        case quiescence
        case passes
        case confirmed
        case unrecoverable
        case failures
    }

    // The three lists are `#[serde(default)]` upstream: a run that confirmed
    // nothing and failed at nothing omits them, and the report must still say
    // why it stopped and how many passes it took.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quiescence = try container.decode(VotingShareTrackingQuiescence.self, forKey: .quiescence)
        passes = try container.decode(UInt32.self, forKey: .passes)
        confirmed = try container.decodeIfPresent([VotingShareKey].self, forKey: .confirmed) ?? []
        unrecoverable = try container.decodeIfPresent([VotingShareKey].self, forKey: .unrecoverable) ?? []
        failures = try container.decodeIfPresent([String].self, forKey: .failures) ?? []
    }
}

// MARK: - Session event stream

/// One delegation-pipeline progress observation for one bundle.
public struct VotingDelegationProgress: Equatable, Sendable, Decodable {
    public let bundleIndex: UInt32
    public let stage: VotingDelegationProgressKind
    /// Proving progress in `0...1`, present only while proving.
    public let fraction: Double?

    private enum CodingKeys: String, CodingKey {
        case bundleIndex = "bundle_index"
        case stage
        case fraction
    }
}

/// One event from a session's live stream.
///
/// The stream is lossy by design: an event can be dropped under load, and the
/// run's report is the authoritative record of what happened. An event whose
/// kind this SDK does not name decodes as ``unknown`` rather than failing the
/// whole stream.
public enum VotingSessionEvent: Equatable, Sendable, Decodable {
    case roundDrive(VotingRoundDriveEvent)
    case shareTracking(VotingShareTrackingEvent)
    case delegationProgress(VotingDelegationProgress)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case kind
        case event
        case progress
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "round_drive":
            let event = try container.decode(VotingRoundDriveEvent.self, forKey: .event)
            self = .roundDrive(event)
        case "share_tracking":
            let event = try container.decode(VotingShareTrackingEvent.self, forKey: .event)
            self = .shareTracking(event)
        case "delegation_progress":
            let progress = try container.decode(VotingDelegationProgress.self, forKey: .progress)
            self = .delegationProgress(progress)
        default:
            self = .unknown
        }
    }
}

// MARK: - Session results

/// Compact round info for the store's round listing.
///
/// `phase` and `network` are the crate's own lowercased names.
public struct VotingRoundSummary: Equatable, Sendable, Decodable {
    public let roundId: String
    public let walletId: String
    public let phase: String
    public let network: String
    public let snapshotHeight: UInt64
    public let createdAt: UInt64

    private enum CodingKeys: String, CodingKey {
        case roundId = "round_id"
        case walletId = "wallet_id"
        case phase
        case network
        case snapshotHeight = "snapshot_height"
        case createdAt = "created_at"
    }
}

/// Delegation bundle layout after quantizing the wallet's eligible notes.
public struct VotingBundleLayout: Equatable, Sendable, Decodable {
    public let bundleCount: UInt32
    public let eligibleWeight: UInt64
    public let droppedCount: UInt32
    public let privacyTrimDroppedBundles: UInt32
    public let privacyTrimDroppedNotes: UInt32

    private enum CodingKeys: String, CodingKey {
        case bundleCount = "bundle_count"
        case eligibleWeight = "eligible_weight"
        case droppedCount = "dropped_count"
        case privacyTrimDroppedBundles = "privacy_trim_dropped_bundles"
        case privacyTrimDroppedNotes = "privacy_trim_dropped_notes"
    }
}

/// Voting eligibility computed for the wallet's snapshot notes.
public struct VotingEligibilityReport: Equatable, Sendable, Decodable {
    public let distinctNoteCount: UInt64
    public let eligibleWeight: UInt64
    public let isEligible: Bool
    /// Raw value of the notes the privacy trim excludes from delegation, not
    /// their bundle-quantized voting weight. Surface that distinction.
    public let privacyTrimDroppedValueZatoshi: UInt64

    private enum CodingKeys: String, CodingKey {
        case distinctNoteCount = "distinct_note_count"
        case eligibleWeight = "eligible_weight"
        case isEligible = "is_eligible"
        case privacyTrimDroppedValueZatoshi = "privacy_trim_dropped_value_zatoshi"
    }
}

/// Progress of PIR precompute for one delegation bundle.
public struct VotingPirPrecomputeReport: Equatable, Sendable, Decodable {
    public let bundleIndex: UInt32
    public let cached: UInt32
    public let fetched: UInt32
    public let bundleCount: UInt32

    private enum CodingKeys: String, CodingKey {
        case bundleIndex = "bundle_index"
        case cached
        case fetched
        case bundleCount = "bundle_count"
    }
}

/// Whether a proof was freshly generated or reused from the shared cache.
///
/// Crosses the FFI wrapped as `{"status": "generated"}`, because a bare JSON
/// string is not an object the boundary can extend later.
public enum VotingDelegationProofStatus: String, Equatable, Sendable, Decodable {
    case generated
    case reused
    case unknown

    private enum CodingKeys: String, CodingKey {
        case status
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .status)
        self = VotingDelegationProofStatus(rawValue: raw) ?? .unknown
    }
}

/// One bundle's voting PCZT, redacted for signing by a Keystone device.
public struct VotingKeystoneSigningRequest: Equatable, Sendable, Decodable {
    public let bundleIndex: UInt32
    public let bundleCount: UInt32
    public let redactedPczt: Data
    public let pcztSighash: Data
    /// Randomized verification key (`rk` on the wire).
    public let randomizedKey: Data
    public let actionIndex: UInt32
    /// The text the device shows the voter.
    public let displayMemo: String
    public let eligibleWeightZatoshi: UInt64
    public let delegatedWeightZatoshi: UInt64

    private enum CodingKeys: String, CodingKey {
        case bundleIndex = "bundle_index"
        case bundleCount = "bundle_count"
        case redactedPczt = "redacted_pczt"
        case pcztSighash = "pczt_sighash"
        case randomizedKey = "rk"
        case actionIndex = "action_index"
        case displayMemo = "display_memo"
        case eligibleWeightZatoshi = "eligible_weight_zatoshi"
        case delegatedWeightZatoshi = "delegated_weight_zatoshi"
    }
}

/// Outcome of storing a batch of Keystone signatures.
public struct VotingKeystoneSignatureBatchResult: Equatable, Sendable, Decodable {
    public let inserted: UInt32
    public let alreadyPresent: UInt32

    private enum CodingKeys: String, CodingKey {
        case inserted
        case alreadyPresent = "already_present"
    }
}

/// One stored Keystone signature.
public struct VotingKeystoneSignatureRecord: Equatable, Sendable, Decodable {
    public let bundleIndex: UInt32
    public let sig: Data
    public let sighash: Data
    /// Randomized verification key (`rk` on the wire).
    public let randomizedKey: Data

    private enum CodingKeys: String, CodingKey {
        case bundleIndex = "bundle_index"
        case sig
        case sighash
        case randomizedKey = "rk"
    }
}

/// One round with unconfirmed helper shares, for one wallet.
///
/// `sessionJson` is the opaque host context stored when the round was created
/// — round timing the host owns, which the crate keeps without reading — and is
/// absent for a round that stored none.
public struct VotingPendingShareRound: Equatable, Sendable, Decodable {
    public let walletId: String
    public let roundId: String
    public let sessionJson: String?

    private enum CodingKeys: String, CodingKey {
        case walletId = "wallet_id"
        case roundId = "round_id"
        case sessionJson = "session_json"
    }
}
