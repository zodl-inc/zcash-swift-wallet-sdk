//
//  VotingRoundTypes.swift
//  ZcashLightClientKit
//

import Foundation

// The round plan and run report a session answers with, mirroring the
// `zcash_voting::wire` views field for field. Every enum decodes an
// unrecognised value as `unknown` rather than failing: the crate's own views
// are open, and a host that cannot name a new kind must still read the rest of
// the payload.

// MARK: - Steps

/// Cross-stage workflow phase of a delegation, vote, or share record.
public enum VotingWorkflowPhase: String, Equatable, Sendable, Decodable {
    case prepared
    case signed
    case submittedDelegation = "submitted_delegation"
    case submittedVote = "submitted_vote"
    case submittedShare = "submitted_share"
    case submissionManaged = "submission_managed"
    case submissionRejected = "submission_rejected"
    case confirmed
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingWorkflowPhase(rawValue: raw) ?? .unknown
    }
}

/// High-level work area a wallet should show or resume for a round.
public enum VotingRoundPlanAction: String, Equatable, Sendable, Decodable {
    case idle
    case delegate
    case vote
    case submitShares = "submit_shares"
    case done
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingRoundPlanAction(rawValue: raw) ?? .unknown
    }
}

/// What one planned step does.
public enum VotingNextStepKind: String, Equatable, Sendable, Decodable {
    case delegate
    case advanceDelegation = "advance_delegation"
    case advanceImportedDelegation = "advance_imported_delegation"
    case castVote = "cast_vote"
    case advanceVote = "advance_vote"
    case advanceVoteBatch = "advance_vote_batch"
    case submitShares = "submit_shares"
    case confirmShare = "confirm_share"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingNextStepKind(rawValue: raw) ?? .unknown
    }
}

/// One step the driver selected, with the identity it applies to.
///
/// Only the fields a `kind` names are meaningful; the rest are zero.
public struct VotingNextStep: Equatable, Sendable, Decodable {
    public let kind: VotingNextStepKind
    public let bundleIndex: UInt32
    public let proposalId: UInt32
    public let choice: UInt32
    public let shareIndex: UInt32

    private enum CodingKeys: String, CodingKey {
        case kind
        case bundleIndex = "bundle_index"
        case proposalId = "proposal_id"
        case choice
        case shareIndex = "share_index"
    }
}

/// Durable identity of one helper share.
public struct VotingShareKey: Equatable, Sendable, Decodable {
    public let bundleIndex: UInt32
    public let proposalId: UInt32
    public let shareIndex: UInt32

    public init(bundleIndex: UInt32, proposalId: UInt32, shareIndex: UInt32) {
        self.bundleIndex = bundleIndex
        self.proposalId = proposalId
        self.shareIndex = shareIndex
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIndex = "bundle_index"
        case proposalId = "proposal_id"
        case shareIndex = "share_index"
    }
}

// MARK: - Chain submission

/// How one chain submission ended.
public enum VotingChainOutcomeKind: String, Equatable, Sendable, Decodable {
    case confirmed
    case tracking
    case recovering
    case submittedWithoutHash = "submitted_without_hash"
    case rejected
    case cancelled
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingChainOutcomeKind(rawValue: raw) ?? .unknown
    }
}

/// Flat view of one chain submission result.
///
/// `diagnosticMessage` is the bounded, redacted text of the crate's nested
/// diagnostic: it is what a host shows for the terminal outcomes
/// (``VotingChainOutcomeKind/submittedWithoutHash`` and
/// ``VotingChainOutcomeKind/rejected``), which schedule no further work.
public struct VotingChainSubmissionOutcome: Equatable, Sendable, Decodable {
    public let kind: VotingChainOutcomeKind
    /// How a confirmation was established: `hash` or `tree`.
    public let confirmationSource: String?
    public let transactionHash: String?
    public let candidateTransactionHash: String?
    public let finalVanPosition: UInt64?
    public let voteCommitmentPositions: [UInt64]
    public let diagnosticMessage: String?

    private enum CodingKeys: String, CodingKey {
        case kind
        case confirmationSource = "confirmation_source"
        case transactionHash = "transaction_hash"
        case candidateTransactionHash = "candidate_transaction_hash"
        case finalVanPosition = "final_van_position"
        case voteCommitmentPositions = "vote_commitment_positions"
        case diagnostic
    }

    /// The nested diagnostic, of which only the message crosses into Swift.
    private struct Diagnostic: Decodable {
        let message: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(VotingChainOutcomeKind.self, forKey: .kind)
        confirmationSource = try container.decodeIfPresent(String.self, forKey: .confirmationSource)
        transactionHash = try container.decodeIfPresent(String.self, forKey: .transactionHash)
        candidateTransactionHash = try container.decodeIfPresent(String.self, forKey: .candidateTransactionHash)
        finalVanPosition = try container.decodeIfPresent(UInt64.self, forKey: .finalVanPosition)
        voteCommitmentPositions = try container.decodeIfPresent([UInt64].self, forKey: .voteCommitmentPositions) ?? []
        diagnosticMessage = try container.decodeIfPresent(Diagnostic.self, forKey: .diagnostic)?.message
    }
}

// MARK: - Plan

/// One proposal's recorded choice, absent when the voter skipped it.
public struct VotingCompletedVoteChoice: Equatable, Sendable, Decodable {
    public let proposalId: UInt32
    public let choice: UInt32?

    public init(proposalId: UInt32, choice: UInt32?) {
        self.proposalId = proposalId
        self.choice = choice
    }

    private enum CodingKeys: String, CodingKey {
        case proposalId = "proposal_id"
        case choice
    }
}

/// What a finished round shows the voter.
public struct VotingCompletedVoteDisplay: Equatable, Sendable, Decodable {
    public let choices: [VotingCompletedVoteChoice]
    public let votedAt: UInt64?

    private enum CodingKeys: String, CodingKey {
        case choices
        case votedAt = "voted_at"
    }
}

/// Durable state of one bundle's delegation.
public struct VotingDelegationStatus: Equatable, Sendable, Decodable {
    public let bundleIndex: UInt32
    public let phase: VotingWorkflowPhase
    public let txHash: String?
    /// True when this bundle's delegation ended without a confirmation and no
    /// further delegation step will be planned for it. Read this rather than
    /// inferring from `phase`: a dispatch that reached the chain without a
    /// usable transaction hash reports the same phase as a healthy submission,
    /// and retrying it would resubmit.
    public let terminal: Bool

    private enum CodingKeys: String, CodingKey {
        case bundleIndex = "bundle_index"
        case phase
        case txHash = "tx_hash"
        case terminal
    }
}

/// What a round owes and what a host should show for it.
///
/// The derived flags are the crate's own: read them instead of matching step
/// kinds, because the planner computes them from an exhaustive match and a new
/// step kind cannot silently read as "no work".
public struct VotingRoundPlan: Equatable, Sendable, Decodable {
    public let roundId: String
    public let pendingRecovery: Bool
    public let blockingRecovery: Bool
    public let blockingShareWork: Bool
    /// True while any helper-share row is unconfirmed. Schedule background
    /// share tracking from this rather than from held share rows.
    public let hasUnconfirmedShares: Bool
    public let hotkeyBound: Bool
    public let completedForDisplay: Bool
    public let completedVoteDisplay: VotingCompletedVoteDisplay?
    public let needsDraftSetup: Bool
    /// True when the round holds a ballot choice but no bundle rows yet, so
    /// the bundle plan must be persisted before any vote work is planned.
    public let needsBundleSetup: Bool
    /// True when delegation work needs fresh or restored signing material.
    public let needsDelegationSigning: Bool
    /// True when a delegation is in flight. `needsDelegationSigning` says
    /// whether the next pass also needs signing material.
    public let hasInFlightDelegation: Bool
    /// Bundles this plan owes any delegation step for, ascending.
    public let delegationBundlesNeedingWork: [UInt32]
    /// Bundles whose delegation still needs the voter's signing material,
    /// ascending: a subset of `delegationBundlesNeedingWork`.
    public let delegationBundlesNeedingSigning: [UInt32]
    public let needsVotePolling: Bool
    /// True when vote or share work remains, counting share confirmation only
    /// when it is blocking.
    public let hasRemainingVoteOrShareWork: Bool
    /// True when vote or share work remains, counting share confirmation
    /// unconditionally.
    public let hasRecoverableVoteOrShareWork: Bool
    public let primaryAction: VotingRoundPlanAction
    public let delegationStatuses: [VotingDelegationStatus]
    /// Proposals with no terminal decision yet.
    public let openProposals: [UInt32]
    /// Durable intents for proposals outside the authenticated roster; casting
    /// is withheld until the host clears them.
    public let unrosteredIntents: [UInt32]
    public let immediateShareConfirmed: Bool
    public let allDecided: Bool

    private enum CodingKeys: String, CodingKey {
        case roundId = "round_id"
        case pendingRecovery = "pending_recovery"
        case blockingRecovery = "blocking_recovery"
        case blockingShareWork = "blocking_share_work"
        case hasUnconfirmedShares = "has_unconfirmed_shares"
        case hotkeyBound = "hotkey_bound"
        case completedForDisplay = "completed_for_display"
        case completedVoteDisplay = "completed_vote_display"
        case needsDraftSetup = "needs_draft_setup"
        case needsBundleSetup = "needs_bundle_setup"
        case needsDelegationSigning = "needs_delegation_signing"
        case hasInFlightDelegation = "has_in_flight_delegation"
        case delegationBundlesNeedingWork = "delegation_bundles_needing_work"
        case delegationBundlesNeedingSigning = "delegation_bundles_needing_signing"
        case needsVotePolling = "needs_vote_polling"
        case hasRemainingVoteOrShareWork = "has_remaining_vote_or_share_work"
        case hasRecoverableVoteOrShareWork = "has_recoverable_vote_or_share_work"
        case primaryAction = "primary_action"
        case delegationStatuses = "delegation_statuses"
        case openProposals = "open_proposals"
        case unrosteredIntents = "unrostered_intents"
        case immediateShareConfirmed = "immediate_share_confirmed"
        case allDecided = "all_decided"
    }
}

// MARK: - Run report

/// Why one round run stopped.
public enum VotingRoundQuiescenceKind: String, Equatable, Sendable, Decodable {
    case noWorkLeft = "no_work_left"
    case needsBundleSetup = "needs_bundle_setup"
    case persistedChainTerminal = "persisted_chain_terminal"
    case needsBallot = "needs_ballot"
    case needsDelegationSignatures = "needs_delegation_signatures"
    case backgroundShareWorkOnly = "background_share_work_only"
    case cancelled
    case chainTerminal = "chain_terminal"
    case chainRecoveryStalled = "chain_recovery_stalled"
    case failures
    case passBudgetExhausted = "pass_budget_exhausted"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingRoundQuiescenceKind(rawValue: raw) ?? .unknown
    }
}

/// Why one round run stopped, with the work each reason names.
///
/// Each field is populated only for the kinds that carry it: switch on `kind`
/// and read what that kind names.
public struct VotingRoundQuiescence: Equatable, Sendable, Decodable {
    public let kind: VotingRoundQuiescenceKind
    /// `needsBallot`: proposals with no terminal decision yet.
    public let openProposals: [UInt32]
    /// `needsBallot`: durable intents outside the roster the host must clear.
    public let unrosteredIntents: [UInt32]
    /// `needsDelegationSignatures`: every bundle still awaiting a signature.
    public let bundles: [UInt32]
    /// `backgroundShareWorkOnly`: shares requiring the host's tracking timer.
    public let shares: [VotingShareKey]
    /// `chainTerminal` and `chainRecoveryStalled`: the step and its outcome.
    public let step: VotingNextStep?
    public let chainOutcome: VotingChainSubmissionOutcome?
    /// `passBudgetExhausted`: the work the run left behind.
    public let remaining: [VotingNextStep]

    private enum CodingKeys: String, CodingKey {
        case kind
        case openProposals = "open_proposals"
        case unrosteredIntents = "unrostered_intents"
        case bundles
        case shares
        case step
        case chainOutcome = "chain_outcome"
        case remaining
    }
}

/// Ballot progress of one run, measured against what it started owing.
public struct VotingRoundWorkTally: Equatable, Sendable, Decodable {
    public let completedProposals: UInt32
    public let totalProposals: UInt32
    public let remainingObligations: UInt32

    private enum CodingKeys: String, CodingKey {
        case completedProposals = "completed_proposals"
        case totalProposals = "total_proposals"
        case remainingObligations = "remaining_obligations"
    }
}

/// Stable category of a round step failure.
public enum VotingRoundStepFailureKind: String, Equatable, Sendable, Decodable {
    case invalidInput = "invalid_input"
    case insufficientEligibility = "insufficient_eligibility"
    case noSpendableNotes = "no_spendable_notes"
    case busy
    case storage
    case invariantViolation = "invariant_violation"
    case transport
    case `protocol`
    case proofFailed = "proof_failed"
    case signing
    case helperDeliveryIncomplete = "helper_delivery_incomplete"
    case voteEnded = "vote_ended"
    case delegationTargetMismatch = "delegation_target_mismatch"
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingRoundStepFailureKind(rawValue: raw) ?? .unknown
    }
}

/// One step failure, with the step it belongs to when the run knows it.
public struct VotingRoundStepFailure: Equatable, Sendable, Decodable {
    public let kind: VotingRoundStepFailureKind
    public let step: VotingNextStep?
    public let message: String
}

/// One failure a run isolated, with the bundle it is attributed to.
///
/// Attribution, not isolation: ``VotingFailureIsolation/stopRound`` ends a run
/// without suppressing anything, so ``VotingRoundRunReport/skippedBundles`` is
/// the authoritative list of what was skipped.
public struct VotingRoundStepFailureRecord: Equatable, Sendable, Decodable {
    public let step: VotingNextStep?
    public let bundleIndex: UInt32?
    public let failure: VotingRoundStepFailure

    private enum CodingKeys: String, CodingKey {
        case step
        case bundleIndex = "bundle_index"
        case failure
    }
}

/// One chain outcome the run observed, bound to the step that produced it.
///
/// Not only terminal ones: a submission still tracking appears here too.
public struct VotingRoundChainOutcome: Equatable, Sendable, Decodable {
    public let step: VotingNextStep
    public let outcome: VotingChainSubmissionOutcome
}

/// Everything one round run did.
///
/// This is the authoritative answer for a run; the live event stream is a
/// best-effort narration of the same work and may drop events.
public struct VotingRoundRunReport: Equatable, Sendable, Decodable {
    public let quiescence: VotingRoundQuiescence
    /// The last plan the run read, absent only when it stopped before one.
    public let plan: VotingRoundPlan?
    public let tally: VotingRoundWorkTally
    /// Failures in dispatch order. A non-empty list does not imply a
    /// ``VotingRoundQuiescenceKind/failures`` quiescence: a run can isolate one
    /// bundle and finish the rest.
    public let failures: [VotingRoundStepFailureRecord]
    /// Bundles a failure isolated for the rest of the run.
    public let skippedBundles: [UInt32]
    /// Every chain outcome the run observed, terminal or not.
    public let chainOutcomes: [VotingRoundChainOutcome]

    private enum CodingKeys: String, CodingKey {
        case quiescence
        case plan
        case tally
        case failures
        case skippedBundles = "skipped_bundles"
        case chainOutcomes = "chain_outcomes"
    }
}
