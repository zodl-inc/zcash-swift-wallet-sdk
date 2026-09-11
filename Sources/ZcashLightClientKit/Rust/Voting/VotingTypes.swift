//
//  VotingTypes.swift
//  ZcashLightClientKit
//

import Foundation

// MARK: - Hotkey

/// A voting hotkey: the secret the wallet delegates voting power to, together
/// with the Orchard address derived from it.
///
/// A voting hotkey is an app-owned random value, not a wallet-seed derivation.
/// The application **must persist `storedSecret`**: it cannot be recovered from
/// the wallet seed, so restoring a wallet from its seed phrase does not restore
/// the ability to vote with a hotkey whose secret was lost. Everything else here
/// is derived from `storedSecret` and does not need to be stored.
///
/// Conforms to `Undescribable` so the secret cannot escape through
/// `print`, string interpolation, or reflection.
public struct VotingHotkey: Sendable, Undescribable {
    /// The material to persist. Treat it as key material, not as an identifier.
    public let storedSecret: [UInt8]
    /// Raw Orchard address bytes for the hotkey, derived from `storedSecret`.
    public let rawOrchardAddress: [UInt8]
    /// Address index the hotkey's Orchard address was derived at.
    public let addressIndex: UInt32
}

// MARK: - PIR layout

/// The PIR fleet shape a round is served with.
public struct VotingPirLayout: Equatable, Sendable {
    public let pirDepth: UInt32
    public let tier0Layers: UInt32
    public let tier1Layers: UInt32

    /// YPIR RLWE polynomial degree; the crate accepts only 2048 or 4096.
    ///
    /// Any other value — including the `0` of ``unknown`` — fails closed in
    /// `zcash_voting` before any network I/O.
    public let polyLen: UInt32

    /// The crate's `PirLayout::UNKNOWN` sentinel, and its `Default`.
    ///
    /// `zcash_voting` rejects it — "pir_layout is unknown; resolve a current
    /// dynamic voting config first" — so this is a fail-closed placeholder for
    /// callers that have not resolved a config yet, never a usable layout.
    public static let unknown = VotingPirLayout(
        pirDepth: 0,
        tier0Layers: 0,
        tier1Layers: 0,
        polyLen: 0
    )

    public init(pirDepth: UInt32, tier0Layers: UInt32, tier1Layers: UInt32, polyLen: UInt32) {
        self.pirDepth = pirDepth
        self.tier0Layers = tier0Layers
        self.tier1Layers = tier1Layers
        self.polyLen = polyLen
    }
}

/// The layout crosses the FFI inside ``VotingSessionInputs``, under the crate's
/// own field names.
extension VotingPirLayout: Encodable {
    private enum CodingKeys: String, CodingKey {
        case pirDepth = "pir_depth"
        case tier0Layers = "tier0_layers"
        case tier1Layers = "tier1_layers"
        case polyLen = "poly_len"
    }
}

// MARK: - Round session inputs

/// Parameters for a voting round, sourced from the vote chain.
///
/// The byte fields encode as standard, padded base64, which is what the Rust
/// side's `b64` serde module reads.
public struct VotingRoundParameters: Equatable, Sendable, Encodable {
    public let voteRoundId: String
    public let snapshotHeight: UInt64
    public let eaPk: Data
    public let ncRoot: Data
    public let nullifierImtRoot: Data

    public init(
        voteRoundId: String,
        snapshotHeight: UInt64,
        eaPk: Data,
        ncRoot: Data,
        nullifierImtRoot: Data
    ) {
        self.voteRoundId = voteRoundId
        self.snapshotHeight = snapshotHeight
        self.eaPk = eaPk
        self.ncRoot = ncRoot
        self.nullifierImtRoot = nullifierImtRoot
    }

    private enum CodingKeys: String, CodingKey {
        case voteRoundId = "vote_round_id"
        case snapshotHeight = "snapshot_height"
        case eaPk = "ea_pk"
        case ncRoot = "nc_root"
        case nullifierImtRoot = "nullifier_imt_root"
    }
}

/// The route a round session's chain and helper traffic takes.
///
/// Chosen once, when the session is opened, and kept for the session's whole
/// life. ``tor`` fails closed: a session that cannot have the Tor route is
/// refused rather than opened on a direct connection, so a voter who asked for
/// Tor never ends up announcing themselves over plain HTTP. PIR and vote-tree
/// traffic take the crate's direct transport either way, because a PIR query
/// names no voter and its volume does not belong on Tor.
///
/// The runtime the ``tor`` route needs belongs to the synchronizer rather than
/// to the caller, which is why a route is named here instead of a client being
/// handed over — see `Synchronizer.makeVotingRoundSession(backend:inputs:binding:route:epoch:)`.
public enum VotingTransportRoute: Sendable, Equatable {
    case direct
    case tor
}

/// Everything needed to open a round session.
///
/// The endpoints are the ones the session uses for its whole life: chain and
/// helper traffic follow the route chosen when the session is opened, while PIR
/// and vote-tree traffic always use the crate's direct transport.
public struct VotingSessionInputs: Equatable, Sendable, Encodable {
    public let accountUUID: String
    public let walletDbPath: String
    public let roundParams: VotingRoundParameters
    public let roundName: String
    public let anchorTreeState: Data
    public let chainEndpoints: [String]
    public let voteTreeNodeUrls: [String]
    public let helperUrls: [String]
    public let pirEndpoints: [String]
    public let pirLayout: VotingPirLayout
    /// Absent when the round announces no ceremony start.
    public let ceremonyStartSeconds: UInt64?
    /// Absent when the round announces no end; once it passes, a run stops
    /// scheduling new work.
    public let voteEndTimeSeconds: UInt64?

    public init(
        accountUUID: String,
        walletDbPath: String,
        roundParams: VotingRoundParameters,
        roundName: String,
        anchorTreeState: Data,
        chainEndpoints: [String],
        voteTreeNodeUrls: [String],
        helperUrls: [String],
        pirEndpoints: [String],
        pirLayout: VotingPirLayout,
        ceremonyStartSeconds: UInt64? = nil,
        voteEndTimeSeconds: UInt64? = nil
    ) {
        self.accountUUID = accountUUID
        self.walletDbPath = walletDbPath
        self.roundParams = roundParams
        self.roundName = roundName
        self.anchorTreeState = anchorTreeState
        self.chainEndpoints = chainEndpoints
        self.voteTreeNodeUrls = voteTreeNodeUrls
        self.helperUrls = helperUrls
        self.pirEndpoints = pirEndpoints
        self.pirLayout = pirLayout
        self.ceremonyStartSeconds = ceremonyStartSeconds
        self.voteEndTimeSeconds = voteEndTimeSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case accountUUID = "account_uuid"
        case walletDbPath = "wallet_db_path"
        case roundParams = "round_params"
        case roundName = "round_name"
        case anchorTreeState = "anchor_tree_state"
        case chainEndpoints = "chain_endpoints"
        case voteTreeNodeUrls = "vote_tree_node_urls"
        case helperUrls = "helper_urls"
        case pirEndpoints = "pir_endpoints"
        case pirLayout = "pir_layout"
        case ceremonyStartSeconds = "ceremony_start_seconds"
        case voteEndTimeSeconds = "vote_end_time_seconds"
    }
}

/// One roster proposal: its id and the number of selectable options.
public struct VotingProposalRosterEntry: Equatable, Sendable, Encodable {
    public let proposalId: UInt32
    public let numOptions: UInt32

    public init(proposalId: UInt32, numOptions: UInt32) {
        self.proposalId = proposalId
        self.numOptions = numOptions
    }

    private enum CodingKeys: String, CodingKey {
        case proposalId = "proposal_id"
        case numOptions = "num_options"
    }
}

/// The authenticated roster a session votes against, plus the stored hotkey
/// secret when the session must bind to a hotkey generated earlier.
///
/// Conforms to `Undescribable` because `hotkeySecret` is the voting hotkey's
/// key material.
public struct VotingSessionBinding: Equatable, Sendable, Encodable, Undescribable {
    public let roster: [VotingProposalRosterEntry]
    /// Absent for a round that has not bound a hotkey yet.
    public let hotkeySecret: Data?

    public init(roster: [VotingProposalRosterEntry], hotkeySecret: Data? = nil) {
        self.roster = roster
        self.hotkeySecret = hotkeySecret
    }

    private enum CodingKeys: String, CodingKey {
        case roster
        case hotkeySecret = "hotkey_secret"
    }
}

// MARK: - Ballot

/// A voter's decision for one proposal.
public enum VotingBallotDecision: Equatable, Sendable {
    /// Vote for `option`, a zero-based index into the proposal's options.
    case choice(UInt32)
    /// Record that the proposal is deliberately left undecided.
    case skipped
}

/// One ballot decision to record before casting.
///
/// Encodes flat, the way the crate's internally tagged decision reads it:
/// `{"proposal_id":3,"decision":"choice","option":1}` or
/// `{"proposal_id":4,"decision":"skipped"}`.
public struct VotingBallotIntent: Equatable, Sendable, Encodable {
    public let proposalId: UInt32
    public let decision: VotingBallotDecision

    public init(proposalId: UInt32, decision: VotingBallotDecision) {
        self.proposalId = proposalId
        self.decision = decision
    }

    private enum CodingKeys: String, CodingKey {
        case proposalId = "proposal_id"
        case decision
        case option
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(proposalId, forKey: .proposalId)
        switch decision {
        case .choice(let option):
            try container.encode("choice", forKey: .decision)
            try container.encode(option, forKey: .option)
        case .skipped:
            try container.encode("skipped", forKey: .decision)
        }
    }
}

// MARK: - Signer

/// Which signer backs a run.
///
/// Conforms to `Undescribable` because ``software(seed:)`` carries wallet seed
/// bytes. The seed reaches Rust only for the duration of the call it is passed
/// to, and is zeroized there.
public enum VotingDelegationSigner: Equatable, Sendable, Encodable, Undescribable {
    /// No signing material: a run plans and reports, and stops where a
    /// signature would be needed.
    case none
    /// An in-process software signer for `seed`.
    case software(seed: [UInt8])
    /// A Keystone device whose signatures for this round are already stored.
    case keystoneStored

    private enum CodingKeys: String, CodingKey {
        case kind
        case seed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode("none", forKey: .kind)
        case .software(let seed):
            try container.encode("software", forKey: .kind)
            try container.encode(Data(seed), forKey: .seed)
        case .keystoneStored:
            try container.encode("keystone_stored", forKey: .kind)
        }
    }
}

// MARK: - Policies

/// What a failing step does to the rest of a run.
public enum VotingFailureIsolation: String, Equatable, Sendable, Encodable {
    /// Skip the failed bundle and keep driving the others.
    case skipBundle = "skip_bundle"
    /// Stop the whole run at the first failure.
    case stopRound = "stop_round"
}

/// What a run's progress tally is measured against.
public enum VotingProgressBaseline: String, Equatable, Sendable, Encodable {
    /// Everything the run itself started owing.
    case run
    /// Only the proposals the voter chose.
    case selectedChoices = "selected_choices"
}

/// How the round driver paces itself between steps and isolates failures.
///
/// ``default`` is this SDK's tuning rather than the crate's: two bundles in
/// flight, one proof at a time. A phone that admits two Orchard proofs at once
/// is the memory-pressure kill the SDK cannot recover from, so raising
/// `maxProofConcurrency` is the host's call, never a default.
public struct VotingRoundDrivePolicy: Equatable, Sendable, Encodable {
    public let pendingRepollSeconds: Double
    public let maxBundleConcurrency: Int
    public let failureIsolation: VotingFailureIsolation
    public let maxDispatches: Int
    public let progressBaseline: VotingProgressBaseline
    public let maxProofConcurrency: Int

    /// The documented defaults: 2s repoll, two bundles, skip the failed bundle,
    /// 512 dispatches, run baseline, one proof at a time.
    public static let `default` = VotingRoundDrivePolicy()

    public init(
        pendingRepollSeconds: Double = 2,
        maxBundleConcurrency: Int = 2,
        failureIsolation: VotingFailureIsolation = .skipBundle,
        maxDispatches: Int = 512,
        progressBaseline: VotingProgressBaseline = .run,
        maxProofConcurrency: Int = 1
    ) {
        self.pendingRepollSeconds = pendingRepollSeconds
        self.maxBundleConcurrency = maxBundleConcurrency
        self.failureIsolation = failureIsolation
        self.maxDispatches = maxDispatches
        self.progressBaseline = progressBaseline
        self.maxProofConcurrency = maxProofConcurrency
    }

    private enum CodingKeys: String, CodingKey {
        case pendingRepollSeconds = "pending_repoll_seconds"
        case maxBundleConcurrency = "max_bundle_concurrency"
        case failureIsolation = "failure_isolation"
        case maxDispatches = "max_dispatches"
        case progressBaseline = "progress_baseline"
        case maxProofConcurrency = "max_proof_concurrency"
    }
}

/// How the share-tracking driver paces its passes.
public struct VotingShareTrackingPolicy: Equatable, Sendable, Encodable {
    public let failureRetrySeconds: Double
    public let maxConsecutiveFailures: UInt32
    /// A pass budget for a bounded foreground run; absent means no budget.
    public let maxPasses: UInt32?

    /// The documented defaults: 15s retry, 240 consecutive failures, no budget.
    public static let `default` = VotingShareTrackingPolicy()

    public init(
        failureRetrySeconds: Double = 15,
        maxConsecutiveFailures: UInt32 = 240,
        maxPasses: UInt32? = nil
    ) {
        self.failureRetrySeconds = failureRetrySeconds
        self.maxConsecutiveFailures = maxConsecutiveFailures
        self.maxPasses = maxPasses
    }

    private enum CodingKeys: String, CodingKey {
        case failureRetrySeconds = "failure_retry_seconds"
        case maxConsecutiveFailures = "max_consecutive_failures"
        case maxPasses = "max_passes"
    }
}

/// How wide the proving pool runs.
///
/// An absent `cpuWorkerCount` lets Rust size the pool to the device's available
/// parallelism; `maxActiveHeavyJobs` stays at 1 unless the host raises it.
public struct VotingProvingPolicy: Equatable, Sendable, Encodable {
    public let cpuWorkerCount: Int?
    public let maxActiveHeavyJobs: Int

    /// The documented defaults: device parallelism, one heavy job.
    public static let `default` = VotingProvingPolicy()

    public init(cpuWorkerCount: Int? = nil, maxActiveHeavyJobs: Int = 1) {
        self.cpuWorkerCount = cpuWorkerCount
        self.maxActiveHeavyJobs = maxActiveHeavyJobs
    }

    private enum CodingKeys: String, CodingKey {
        case cpuWorkerCount = "cpu_worker_count"
        case maxActiveHeavyJobs = "max_active_heavy_jobs"
    }
}

/// Per-run overrides applied on top of the round's stored configuration.
///
/// An outer `nil` leaves the stored value alone: the key is left out of the
/// JSON entirely. The inner `nil` of the two optional-of-optional fields cannot
/// be expressed to Rust — the FFI reads a JSON `null` as "no override" rather
/// than as "clear this value" — so `.some(nil)` is encoded as absent too, and
/// clearing a stored ceremony start or vote end is not something a host can ask
/// for through this type.
public struct VotingHostOverrides: Equatable, Sendable, Encodable {
    public let helperUrls: [String]?
    public let voteTreeNodeUrls: [String]?
    public let ceremonyStartSeconds: UInt64??
    public let voteEndTimeSeconds: UInt64??

    /// Override nothing.
    public static let none = VotingHostOverrides()

    public init(
        helperUrls: [String]? = nil,
        voteTreeNodeUrls: [String]? = nil,
        ceremonyStartSeconds: UInt64?? = nil,
        voteEndTimeSeconds: UInt64?? = nil
    ) {
        self.helperUrls = helperUrls
        self.voteTreeNodeUrls = voteTreeNodeUrls
        self.ceremonyStartSeconds = ceremonyStartSeconds
        self.voteEndTimeSeconds = voteEndTimeSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case helperUrls = "helper_urls"
        case voteTreeNodeUrls = "vote_tree_node_urls"
        case ceremonyStartSeconds = "ceremony_start_seconds"
        case voteEndTimeSeconds = "vote_end_time_seconds"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(helperUrls, forKey: .helperUrls)
        try container.encodeIfPresent(voteTreeNodeUrls, forKey: .voteTreeNodeUrls)
        if case .some(.some(let seconds)) = ceremonyStartSeconds {
            try container.encode(seconds, forKey: .ceremonyStartSeconds)
        }
        if case .some(.some(let seconds)) = voteEndTimeSeconds {
            try container.encode(seconds, forKey: .voteEndTimeSeconds)
        }
    }
}

// MARK: - Keystone input

/// One bundle's PCZT as a Keystone device signed it.
public struct VotingKeystoneSignedBundle: Equatable, Sendable, Encodable {
    public let bundleIndex: UInt32
    public let signedPczt: Data

    public init(bundleIndex: UInt32, signedPczt: Data) {
        self.bundleIndex = bundleIndex
        self.signedPczt = signedPczt
    }

    private enum CodingKeys: String, CodingKey {
        case bundleIndex = "bundle_index"
        case signedPczt = "signed_pczt"
    }
}

// MARK: - Error

/// Stable category of a ``VotingError``.
///
/// ``other`` covers every category a newer `zcash_voting` may add: an
/// unrecognised category string decodes to it rather than failing the decode.
public enum VotingErrorKind: String, Equatable, Sendable, Decodable {
    case invalidInput = "invalid_input"
    case keystoneSignatureConflict = "keystone_signature_conflict"
    case proofFailed = "proof_failed"
    case busy
    case storage
    case `internal`
    case insufficientEligibility = "insufficient_eligibility"
    case noSpendableNotes = "no_spendable_notes"
    case setupAlreadyPersisted = "setup_already_persisted"
    case delegationPcztUnavailable = "delegation_pczt_unavailable"
    case dbBusy = "db_busy"
    case pirUnavailable = "pir_unavailable"
    case delegationTargetMismatch = "delegation_target_mismatch"
    case delegationAlreadyBroadcast = "delegation_already_broadcast"
    case other

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = VotingErrorKind(rawValue: raw) ?? .other
    }
}

/// A failure from the voting FFI, in the crate's own wire shape.
///
/// The structured fields carry the payload of the kinds that have one:
/// `bundleIndex` for the bundle-scoped kinds, `httpStatus` and `endpoint` for
/// ``VotingErrorKind/pirUnavailable``. `retryable` says whether the same call
/// can be repeated as it stands; it is the crate's answer, not an inference
/// from `kind`.
public struct VotingError: Error, Equatable, Sendable, Decodable, LocalizedError {
    public let kind: VotingErrorKind
    public let retryable: Bool
    public let message: String
    public let bundleIndex: UInt32?
    public let httpStatus: UInt16?
    public let endpoint: String?

    /// The crate's own message, which is written to be read by a person, so a
    /// host with nothing more specific to show can show it.
    public var errorDescription: String? {
        message
    }

    /// A voting failure this SDK raised itself, in the shape the crate uses.
    ///
    /// The wrapper refuses a few calls before they reach the FFI — an argument
    /// whose meaning would silently widen on the way through, say — and a host
    /// branching on ``kind`` should not have to tell those apart from the
    /// crate's own refusals.
    public init(
        kind: VotingErrorKind,
        retryable: Bool = false,
        message: String,
        bundleIndex: UInt32? = nil,
        httpStatus: UInt16? = nil,
        endpoint: String? = nil
    ) {
        self.kind = kind
        self.retryable = retryable
        self.message = message
        self.bundleIndex = bundleIndex
        self.httpStatus = httpStatus
        self.endpoint = endpoint
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case retryable
        case message
        case bundleIndex = "bundle_index"
        case httpStatus = "http_status"
        case endpoint
    }

    /// Reads the FFI's last error text as a ``VotingError``.
    ///
    /// The voting FFI records failures as the crate's JSON envelope, but not
    /// every failure crossing the boundary comes from the crate — a panic
    /// message or a plain string can reach here too. Anything that does not
    /// decode is kept verbatim as a non-retryable ``VotingErrorKind/other``,
    /// so no error text is lost to a decode failure.
    public static func fromLastErrorMessage(_ message: String) -> VotingError {
        guard
            let data = message.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(VotingError.self, from: data)
        else {
            return VotingError(
                kind: .other,
                retryable: false,
                message: message,
                bundleIndex: nil,
                httpStatus: nil,
                endpoint: nil
            )
        }

        return decoded
    }
}
