import Foundation
import libzcashlc

/// Canonical native voting round identifier.
public struct VotingRoundID: Codable, Hashable, Sendable {
    public let stringEncoded: String
    public init(validating value: String) throws {
        let bytes = Array(value.utf8)
        guard bytes.withUnsafeBufferPointer({ zcashlc_voting_validate_round_id($0.baseAddress, UInt($0.count)) }) else {
            throw VotingHelperError.invalidRoundID
        }
        stringEncoded = value
    }
    public init(from decoder: Decoder) throws {
        try self.init(validating: decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringEncoded)
    }
}

public enum VotingHelperError: Error, Sendable {
    case invalidRoundID
    case invalidReport
    case cancelled
    case nativeOperationFailed
}

public enum VotingHelperRoute: Sendable {
    case direct
    case tor
}

public enum VotingHelperTransport: Sendable {
    case direct
    case tor(TorClient)
}

public enum VotingSharePlacementGuarantee: String, Codable, Sendable {
    case strict
    case legacyBestEffort = "legacy_best_effort"
}

public enum VotingBallotDecision: Codable, Hashable, Sendable {
    case choice(UInt32)
    case skipped
    private enum CodingKeys: String, CodingKey { case choice, skipped }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let choice = try container.decodeIfPresent(UInt32.self, forKey: .choice) {
            guard !container.contains(.skipped) else { throw VotingHelperError.invalidReport }
            self = .choice(choice)
        } else if try container.decodeIfPresent(Bool.self, forKey: .skipped) == true {
            self = .skipped
        } else {
            throw VotingHelperError.invalidReport
        }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .choice(let choice): try container.encode(choice, forKey: .choice)
        case .skipped: try container.encode(true, forKey: .skipped)
        }
    }
}

public struct VotingHelperDeliveryIdentity: Codable, Hashable, Sendable {
    public let roundID: VotingRoundID
    public let bundleIndex: UInt32
    public let proposalID: UInt32

    public init(
        roundID: VotingRoundID,
        bundleIndex: UInt32,
        proposalID: UInt32
    ) {
        self.roundID = roundID
        self.bundleIndex = bundleIndex
        self.proposalID = proposalID
    }

    private enum CodingKeys: String, CodingKey {
        case roundID = "round_id"
        case bundleIndex = "bundle_index"
        case proposalID = "proposal_id"
    }
}

public struct VotingHelperShareIdentity: Codable, Hashable, Sendable {
    public let delivery: VotingHelperDeliveryIdentity
    public let shareIndex: UInt32

    public init(
        delivery: VotingHelperDeliveryIdentity,
        shareIndex: UInt32
    ) {
        self.delivery = delivery
        self.shareIndex = shareIndex
    }

    private enum CodingKeys: String, CodingKey {
        case delivery
        case shareIndex = "share_index"
    }
}

public struct VotingHelperRoundConfiguration: Codable, Hashable, Sendable {
    public let roundID: VotingRoundID
    public let helperURLs: [URL]
    public let proposalIDs: [UInt32]
    public let voteEndTime: UInt64?
    public let lastMomentBuffer: UInt64?

    public init(
        roundID: VotingRoundID,
        helperURLs: [URL],
        proposalIDs: [UInt32],
        voteEndTime: UInt64?,
        lastMomentBuffer: UInt64?
    ) {
        self.roundID = roundID
        self.helperURLs = helperURLs
        self.proposalIDs = proposalIDs
        self.voteEndTime = voteEndTime
        self.lastMomentBuffer = lastMomentBuffer
    }

    private enum CodingKeys: String, CodingKey {
        case roundID = "round_id"
        case helperURLs = "helper_urls"
        case proposalIDs = "proposal_ids"
        case voteEndTime = "vote_end_time"
        case lastMomentBuffer = "last_moment_buffer"
    }
}

public struct VotingHelperFleet: Codable, Hashable, Sendable {
    public let configuredURLs: [URL]
    public let readyURLs: [URL]

    public init(
        configuredURLs: [URL],
        readyURLs: [URL]
    ) {
        self.configuredURLs = configuredURLs
        self.readyURLs = readyURLs
    }

    private enum CodingKeys: String, CodingKey {
        case configuredURLs = "configured_urls"
        case readyURLs = "ready_urls"
    }
}

public struct VotingPreparedShare: Codable, Hashable, Sendable {
    public let shareIndex: UInt32
    public let immediate: Bool
    public let submitAt: UInt64
    public let targetCount: UInt32

    public init(
        shareIndex: UInt32,
        immediate: Bool,
        submitAt: UInt64,
        targetCount: UInt32
    ) {
        self.shareIndex = shareIndex
        self.immediate = immediate
        self.submitAt = submitAt
        self.targetCount = targetCount
    }

    private enum CodingKeys: String, CodingKey {
        case shareIndex = "share_index"
        case immediate
        case submitAt = "submit_at"
        case targetCount = "target_count"
    }
}

public struct VotingPreparedShareDelivery: Codable, Hashable, Sendable {
    public let identity: VotingHelperDeliveryIdentity
    public let shares: [VotingPreparedShare]
    public let placementGuarantee: VotingSharePlacementGuarantee

    public init(
        identity: VotingHelperDeliveryIdentity,
        shares: [VotingPreparedShare],
        placementGuarantee: VotingSharePlacementGuarantee
    ) {
        self.identity = identity
        self.shares = shares
        self.placementGuarantee = placementGuarantee
    }

    private enum CodingKeys: String, CodingKey {
        case identity
        case shares
        case placementGuarantee = "placement_guarantee"
    }
}

public struct VotingShareDeliveryOutcome: Codable, Hashable, Sendable {
    public let shareIndex: UInt32
    public let acceptedURLs: [URL]
    public let ambiguousURLs: [URL]
    public let targetCount: UInt32

    public init(
        shareIndex: UInt32,
        acceptedURLs: [URL],
        ambiguousURLs: [URL],
        targetCount: UInt32
    ) {
        self.shareIndex = shareIndex
        self.acceptedURLs = acceptedURLs
        self.ambiguousURLs = ambiguousURLs
        self.targetCount = targetCount
    }

    private enum CodingKeys: String, CodingKey {
        case shareIndex = "share_index"
        case acceptedURLs = "accepted_urls"
        case ambiguousURLs = "ambiguous_urls"
        case targetCount = "target_count"
    }
}

public struct VotingShareDeliveryReport: Codable, Hashable, Sendable {
    public let deliveries: [VotingShareDeliveryOutcome]
    public let pendingShareIndices: [UInt32]
    public let cancelled: Bool
    public let placementGuarantee: VotingSharePlacementGuarantee

    public init(
        deliveries: [VotingShareDeliveryOutcome],
        pendingShareIndices: [UInt32],
        cancelled: Bool,
        placementGuarantee: VotingSharePlacementGuarantee
    ) {
        self.deliveries = deliveries
        self.pendingShareIndices = pendingShareIndices
        self.cancelled = cancelled
        self.placementGuarantee = placementGuarantee
    }

    private enum CodingKeys: String, CodingKey {
        case deliveries
        case pendingShareIndices = "pending_share_indices"
        case cancelled
        case placementGuarantee = "placement_guarantee"
    }
}

public struct VotingShareTarget: Codable, Hashable, Sendable {
    public let identity: VotingHelperShareIdentity
    public let serverURL: URL

    public init(
        identity: VotingHelperShareIdentity,
        serverURL: URL
    ) {
        self.identity = identity
        self.serverURL = serverURL
    }

    private enum CodingKeys: String, CodingKey {
        case identity
        case serverURL = "server_url"
    }
}

public struct VotingShareTrackingReport: Codable, Hashable, Sendable {
    public let confirmed: [VotingHelperShareIdentity]
    public let resubmitted: [VotingShareTarget]
    public let ambiguous: [VotingShareTarget]
    public let unrecoverable: [VotingHelperShareIdentity]
    public let cancelled: Bool
    public let nextDelaySeconds: UInt64?

    public init(
        confirmed: [VotingHelperShareIdentity],
        resubmitted: [VotingShareTarget],
        ambiguous: [VotingShareTarget],
        unrecoverable: [VotingHelperShareIdentity],
        cancelled: Bool,
        nextDelaySeconds: UInt64?
    ) {
        self.confirmed = confirmed
        self.resubmitted = resubmitted
        self.ambiguous = ambiguous
        self.unrecoverable = unrecoverable
        self.cancelled = cancelled
        self.nextDelaySeconds = nextDelaySeconds
    }

    private enum CodingKeys: String, CodingKey {
        case confirmed
        case resubmitted
        case ambiguous
        case unrecoverable
        case cancelled
        case nextDelaySeconds = "next_delay_seconds"
    }
}

public struct VotingShareConfirmationReport: Codable, Hashable, Sendable {
    public let confirmed: Bool
    public let cancelled: Bool

    public init(
        confirmed: Bool,
        cancelled: Bool
    ) {
        self.confirmed = confirmed
        self.cancelled = cancelled
    }

    private enum CodingKeys: String, CodingKey {
        case confirmed
        case cancelled
    }
}

public struct VotingBallotIntent: Codable, Hashable, Sendable {
    public let proposalID: UInt32
    public let numOptions: UInt32
    public let decision: VotingBallotDecision

    public init(
        proposalID: UInt32,
        numOptions: UInt32,
        decision: VotingBallotDecision
    ) {
        self.proposalID = proposalID
        self.numOptions = numOptions
        self.decision = decision
    }

    private enum CodingKeys: String, CodingKey {
        case proposalID = "proposal_id"
        case numOptions = "num_options"
        case decision
    }
}
