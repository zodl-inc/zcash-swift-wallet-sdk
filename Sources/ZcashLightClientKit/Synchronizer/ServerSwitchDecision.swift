//
//  ServerSwitchDecision.swift
//  ZcashLightClientKit
//

import Foundation

/// The pure policy behind `Synchronizer.evaluateServerSwitch`: given the current endpoint and
/// the benchmark's ranked results, decide whether switching is worth a synchronizer teardown.
///
/// A switch tears down and rebuilds the whole synchronizer (sync restart, connection and Tor
/// warmup), so a marginally faster server is all cost and no benefit — and the benchmark's
/// single-shot measurements are noisy enough that small deltas carry no signal at all.
enum ServerSwitchDecision {
    /// One benchmarked endpoint. `score` is whatever the benchmark ranks by (lower is better);
    /// scores are only comparable within a single benchmark run.
    struct MeasuredEndpoint: Equatable {
        let endpoint: LightWalletEndpoint
        let score: TimeInterval
    }

    /// The gates a candidate must clear to justify a switch. Scores are always seconds, but
    /// their scale differs per benchmark — `SDKSynchronizer` ranks by the time to stream a
    /// batch of blocks (whole seconds) while `SlipstreamSynchronizer` ranks by a single
    /// `getInfo` round trip (small fractions of a second) — so each benchmark picks the
    /// preset calibrated for its own scale.
    struct Thresholds {
        /// Minimum absolute score improvement worth a switch.
        let minAbsoluteImprovement: TimeInterval
        /// Minimum improvement relative to the current server's score. A fixed absolute gate
        /// sits inside normal jitter in high-latency regimes; requiring a fraction of the
        /// current score as well keeps noise from triggering switches there.
        let minRelativeImprovement: Double

        /// For scores measuring the streaming of `nBlocksToFetch` compact blocks. Below
        /// ~200 ms the gain is imperceptible for sync workloads and sits inside single-shot
        /// measurement noise.
        static let blockFetch = Thresholds(minAbsoluteImprovement: 0.2, minRelativeImprovement: 0.25)

        /// For scores measuring a single `getInfo` round trip. A fresh connection's RTT
        /// includes TCP and TLS setup, so tens of milliseconds of jitter is normal; 100 ms is
        /// the smallest difference that reliably reflects the server rather than the
        /// measurement.
        static let roundTrip = Thresholds(minAbsoluteImprovement: 0.1, minRelativeImprovement: 0.25)
    }

    enum Outcome: Equatable {
        /// The benchmark produced no healthy results — stay.
        case noResults
        /// The fastest survivor is the current server — stay.
        case alreadyBest
        /// The current server produced no score (failed health checks, unreachable, or failed
        /// the fetch — and, on the `evaluate` path, failed its confirming re-probe too) —
        /// switch to the best regardless of magnitude.
        case currentUnhealthy(switchTo: LightWalletEndpoint)
        /// The best server beats the current one by enough on both gates — switch.
        case improvementSufficient(switchTo: LightWalletEndpoint, improvement: TimeInterval)
        /// The best server is faster, but not by enough to justify the teardown — stay.
        case improvementInsufficient(improvement: TimeInterval)

        var endpointToSwitchTo: LightWalletEndpoint? {
            switch self {
            case .noResults, .alreadyBest, .improvementInsufficient:
                return nil
            case let .currentUnhealthy(endpoint), let .improvementSufficient(endpoint, _):
                return endpoint
            }
        }

        var logDescription: String {
            switch self {
            case .noResults:
                return "stay (no healthy results)"
            case .alreadyBest:
                return "stay (current server is the best)"
            case let .currentUnhealthy(endpoint):
                return "switch to \(endpoint.host):\(endpoint.port) (current server unhealthy or unmeasured)"
            case let .improvementSufficient(endpoint, improvement):
                return "switch to \(endpoint.host):\(endpoint.port) (improvement \(Int(improvement * 1000)) ms)"
            case let .improvementInsufficient(improvement):
                return "stay (improvement \(Int(improvement * 1000)) ms below threshold)"
            }
        }
    }

    // MARK: - Orchestration

    /// Runs the whole switch evaluation: benchmarks the candidates (always including
    /// `current`), gives a missing current server one confirming re-probe before treating it
    /// as unhealthy, decides, and logs the outcome.
    ///
    /// `benchmark` measures the given endpoints and returns the healthy survivors sorted
    /// ascending by score; both invocations must measure the same way so their scores are
    /// comparable. Returns the endpoint to switch to, or nil to stay — including when the
    /// surrounding task is cancelled, because staying is the safe answer for an aborted
    /// evaluation.
    static func evaluate(
        current: LightWalletEndpoint,
        candidates: [LightWalletEndpoint],
        thresholds: Thresholds,
        logger: Logger,
        benchmark: ([LightWalletEndpoint]) async -> [MeasuredEndpoint]
    ) async -> LightWalletEndpoint? {
        // The current server is always measured, so its absence from the results can only
        // mean it failed the benchmark — never that the caller left it out of the list.
        var toMeasure = candidates
        if !toMeasure.contains(where: { $0.isSameServer(as: current) }) {
            toMeasure.append(current)
        }

        var ranked = await benchmark(toMeasure)

        if Task.isCancelled {
            logger.info("[evaluateServerSwitch] cancelled during benchmark -> stay")
            return nil
        }

        // One confirming re-probe before the unconditional-switch branch: a single transient
        // failure (one lost RPC, one broken stream) must not tear the synchronizer down.
        if !ranked.contains(where: { $0.endpoint.isSameServer(as: current) }) {
            let reprobe = await benchmark([current])

            if Task.isCancelled {
                logger.info("[evaluateServerSwitch] cancelled during re-probe -> stay")
                return nil
            }

            if let confirmed = reprobe.first(where: { $0.endpoint.isSameServer(as: current) }) {
                ranked = (ranked + [confirmed]).sorted { $0.score < $1.score }
            }
        }

        let outcome = decide(current: current, ranked: ranked, thresholds: thresholds)

        let scores = ranked
            .map { "\($0.endpoint.host):\($0.endpoint.port)=\(Int($0.score * 1000))ms" }
            .joined(separator: ", ")
        logger.info(
            "[evaluateServerSwitch] current=\(current.host):\(current.port) ranked=[\(scores)] -> \(outcome.logDescription)"
        )

        return outcome.endpointToSwitchTo
    }

    // MARK: - Decision

    /// Decides whether to leave `current` for the best entry of `ranked`.
    /// - Parameters:
    ///   - current: The endpoint the wallet is connected to right now.
    ///   - ranked: Healthy benchmark survivors sorted ascending by `score` (best first).
    ///   - thresholds: The gate preset calibrated for the benchmark that produced `ranked`.
    static func decide(
        current: LightWalletEndpoint,
        ranked: [MeasuredEndpoint],
        thresholds: Thresholds
    ) -> Outcome {
        guard let best = ranked.first else { return .noResults }

        guard !best.endpoint.isSameServer(as: current) else { return .alreadyBest }

        guard let currentMeasurement = ranked.first(where: { $0.endpoint.isSameServer(as: current) }) else {
            return .currentUnhealthy(switchTo: best.endpoint)
        }

        let improvement = currentMeasurement.score - best.score
        let meetsAbsoluteGate = improvement >= thresholds.minAbsoluteImprovement
        let meetsRelativeGate = improvement >= thresholds.minRelativeImprovement * currentMeasurement.score

        if meetsAbsoluteGate && meetsRelativeGate {
            return .improvementSufficient(switchTo: best.endpoint, improvement: improvement)
        } else {
            return .improvementInsufficient(improvement: improvement)
        }
    }

    // MARK: - Block-fetch scoring

    /// Classifies one endpoint's block-fetch measurement into a retained score or a rejection.
    ///
    /// An endpoint that delivered fewer blocks than requested is ruled out — an empty or
    /// truncated stream would otherwise record a near-zero elapsed time and win the ranking
    /// outright. An endpoint that crossed `threshold` is ruled out too, except the current
    /// server on the decision path (`retainOverThreshold`): keeping it with its elapsed time
    /// as a censored score means the hysteresis gates still apply, instead of a threshold miss
    /// of any margin producing an unconditional switch. Censoring understates how slow that
    /// server really is, which errs toward staying.
    ///
    /// - Returns: The score to rank the endpoint by, or nil when it must be ruled out.
    static func blockFetchScore(
        elapsed: TimeInterval,
        blocksReceived: UInt64,
        requiredBlocks: UInt64,
        threshold: TimeInterval,
        retainOverThreshold: Bool
    ) -> TimeInterval? {
        guard elapsed > 0 else { return nil }

        if elapsed >= threshold {
            return retainOverThreshold ? elapsed : nil
        }

        guard blocksReceived >= requiredBlocks else { return nil }

        return elapsed
    }
}
