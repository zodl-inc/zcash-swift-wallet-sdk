//
//  ServerSwitchDecisionTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import ZcashLightClientKit

final class ServerSwitchDecisionTests: XCTestCase {
    private func endpoint(_ host: String, port: Int = 443, secure: Bool = true) -> LightWalletEndpoint {
        LightWalletEndpoint(address: host, port: port, secure: secure, streamingCallTimeoutInMillis: 10000)
    }

    private func measured(
        _ host: String,
        port: Int = 443,
        secure: Bool = true,
        score: TimeInterval
    ) -> ServerSwitchDecision.MeasuredEndpoint {
        ServerSwitchDecision.MeasuredEndpoint(endpoint: endpoint(host, port: port, secure: secure), score: score)
    }

    private func decide(
        current: LightWalletEndpoint,
        ranked: [ServerSwitchDecision.MeasuredEndpoint]
    ) -> ServerSwitchDecision.Outcome {
        ServerSwitchDecision.decide(current: current, ranked: ranked, thresholds: .blockFetch)
    }

    // MARK: - decide, blockFetch thresholds

    // Rule 1: nothing measurable → stay.
    func testEmptyResultsStays() {
        XCTAssertEqual(decide(current: endpoint("current.example"), ranked: []), .noResults)
    }

    // Rule 2: the fastest survivor is the current server → stay.
    func testBestIsCurrentStays() {
        let outcome = decide(
            current: endpoint("current.example"),
            ranked: [measured("current.example", score: 0.1), measured("other.example", score: 0.3)]
        )
        XCTAssertEqual(outcome, .alreadyBest)
    }

    // Rule 3: current produced no score (unhealthy) → switch regardless of magnitude.
    func testCurrentUnmeasuredSwitches() {
        let outcome = decide(
            current: endpoint("current.example"),
            ranked: [measured("best.example", score: 0.5), measured("other.example", score: 0.6)]
        )
        XCTAssertEqual(outcome, .currentUnhealthy(switchTo: endpoint("best.example")))
    }

    // Rule 4, the ticket case: ~5 ms faster is not worth a synchronizer teardown.
    func testMarginalImprovementStays() {
        let outcome = decide(
            current: endpoint("current.example"),
            ranked: [measured("best.example", score: 0.100), measured("current.example", score: 0.105)]
        )
        XCTAssertEqual(outcome, .improvementInsufficient(improvement: 0.105 - 0.100))
    }

    // Rule 4: absolute gate passes (250 ms) but relative fails (12.5% < 25%) → stay (noise guard).
    func testAbsolutePassRelativeFailStays() {
        let outcome = decide(
            current: endpoint("current.example"),
            ranked: [measured("best.example", score: 1.75), measured("current.example", score: 2.0)]
        )
        XCTAssertEqual(outcome, .improvementInsufficient(improvement: 2.0 - 1.75))
    }

    // Rule 4: relative gate passes (89%) but absolute fails (170 ms < 200 ms) → stay.
    func testRelativePassAbsoluteFailStays() {
        let outcome = decide(
            current: endpoint("current.example"),
            ranked: [measured("best.example", score: 0.02), measured("current.example", score: 0.19)]
        )
        XCTAssertEqual(outcome, .improvementInsufficient(improvement: 0.19 - 0.02))
    }

    // Rule 4: both gates pass → switch.
    func testSubstantialImprovementSwitches() {
        let outcome = decide(
            current: endpoint("current.example"),
            ranked: [measured("best.example", score: 0.15), measured("current.example", score: 0.4)]
        )
        XCTAssertEqual(outcome, .improvementSufficient(switchTo: endpoint("best.example"), improvement: 0.4 - 0.15))
    }

    // Absolute-gate boundary, pinned with binary64-exact operands: 0.5 - 0.3 is exactly the 0.2
    // literal, so this test fails if `>=` ever becomes `>`. (The old operands 0.8/0.6 differ by
    // 0.20000000000000007 and never touched the boundary.)
    func testExactAbsoluteBoundarySwitches() {
        let outcome = decide(
            current: endpoint("current.example"),
            ranked: [measured("best.example", score: 0.3), measured("current.example", score: 0.5)]
        )
        XCTAssertEqual(outcome, .improvementSufficient(switchTo: endpoint("best.example"), improvement: 0.5 - 0.3))
    }

    // Relative-gate boundary, exact: 8.0 - 6.0 == 2.0 == 0.25 * 8.0 in binary64, so this test
    // fails if the relative `>=` ever becomes `>`. The absolute gate passes non-marginally.
    func testExactRelativeBoundarySwitches() {
        let outcome = decide(
            current: endpoint("current.example"),
            ranked: [measured("best.example", score: 6.0), measured("current.example", score: 8.0)]
        )
        XCTAssertEqual(outcome, .improvementSufficient(switchTo: endpoint("best.example"), improvement: 8.0 - 6.0))
    }

    // Equal scores with a different server ranked first → improvement 0 → stay.
    func testEqualScoresStays() {
        let outcome = decide(
            current: endpoint("current.example"),
            ranked: [measured("best.example", score: 0.3), measured("current.example", score: 0.3)]
        )
        XCTAssertEqual(outcome, .improvementInsufficient(improvement: 0))
    }

    // Identity includes the port: same host on a different port is NOT the current server.
    func testSameHostDifferentPortIsADifferentServer() {
        let outcome = decide(
            current: endpoint("host.example", port: 443),
            ranked: [measured("host.example", port: 9067, score: 0.1), measured("host.example", port: 443, score: 0.9)]
        )
        XCTAssertEqual(outcome.endpointToSwitchTo?.port, 9067)
    }

    // Identity includes the TLS flag: the TLS and plaintext forms of one host:port are different
    // servers — the gates apply, this is not `.alreadyBest`.
    func testSameHostPortDifferentSecureIsADifferentServer() {
        let outcome = decide(
            current: endpoint("host.example", secure: false),
            ranked: [
                measured("host.example", secure: true, score: 0.1),
                measured("host.example", secure: false, score: 0.9)
            ]
        )
        XCTAssertEqual(
            outcome,
            .improvementSufficient(switchTo: endpoint("host.example", secure: true), improvement: 0.9 - 0.1)
        )
    }

    // Current mid-list: its own score is what the comparison uses.
    func testCurrentMidListUsesItsOwnScore() {
        let outcome = decide(
            current: endpoint("current.example"),
            ranked: [
                measured("best.example", score: 0.1),
                measured("second.example", score: 0.2),
                measured("current.example", score: 0.5)
            ]
        )
        XCTAssertEqual(outcome, .improvementSufficient(switchTo: endpoint("best.example"), improvement: 0.5 - 0.1))
    }

    // Single survivor that IS current → stay.
    func testOnlyCurrentSurvivedStays() {
        let outcome = decide(current: endpoint("current.example"), ranked: [measured("current.example", score: 0.4)])
        XCTAssertEqual(outcome, .alreadyBest)
    }

    // MARK: - decide, roundTrip thresholds

    // At RTT scale the 100 ms absolute gate is reachable: 150 ms vs 20 ms clears both gates.
    func testRoundTripSubstantialImprovementSwitches() {
        let outcome = ServerSwitchDecision.decide(
            current: endpoint("current.example"),
            ranked: [measured("best.example", score: 0.02), measured("current.example", score: 0.15)],
            thresholds: .roundTrip
        )
        XCTAssertEqual(outcome, .improvementSufficient(switchTo: endpoint("best.example"), improvement: 0.15 - 0.02))
    }

    // 60 ms of RTT improvement is inside single-shot noise → stay.
    func testRoundTripMarginalImprovementStays() {
        let outcome = ServerSwitchDecision.decide(
            current: endpoint("current.example"),
            ranked: [measured("best.example", score: 0.02), measured("current.example", score: 0.08)],
            thresholds: .roundTrip
        )
        XCTAssertEqual(outcome, .improvementInsufficient(improvement: 0.08 - 0.02))
    }

    // MARK: - Log descriptions

    // Every outcome renders the decisive fact, exactly.
    func testLogDescriptions() {
        XCTAssertEqual(
            ServerSwitchDecision.Outcome.noResults.logDescription,
            "stay (no healthy results)"
        )
        XCTAssertEqual(
            ServerSwitchDecision.Outcome.alreadyBest.logDescription,
            "stay (current server is the best)"
        )
        XCTAssertEqual(
            ServerSwitchDecision.Outcome.currentUnhealthy(switchTo: endpoint("b.example")).logDescription,
            "switch to b.example:443 (current server unhealthy or unmeasured)"
        )
        XCTAssertEqual(
            ServerSwitchDecision.Outcome.improvementSufficient(
                switchTo: endpoint("b.example"),
                improvement: 0.25
            ).logDescription,
            "switch to b.example:443 (improvement 250 ms)"
        )
        XCTAssertEqual(
            ServerSwitchDecision.Outcome.improvementInsufficient(improvement: 0.005).logDescription,
            "stay (improvement 5 ms below threshold)"
        )
    }

    // MARK: - blockFetchScore

    private func score(
        elapsed: TimeInterval,
        blocksReceived: UInt64,
        requiredBlocks: UInt64 = 100,
        threshold: TimeInterval = 60.0,
        retainOverThreshold: Bool = false
    ) -> TimeInterval? {
        ServerSwitchDecision.blockFetchScore(
            elapsed: elapsed,
            blocksReceived: blocksReceived,
            requiredBlocks: requiredBlocks,
            threshold: threshold,
            retainOverThreshold: retainOverThreshold
        )
    }

    // A full delivery under the threshold scores its elapsed time.
    func testFetchScoreNormalDelivery() {
        XCTAssertEqual(score(elapsed: 12.5, blocksReceived: 100), 12.5)
    }

    // An empty stream must never score — a 0.0 "measurement" would win every ranking.
    func testFetchScoreEmptyStreamRuledOut() {
        XCTAssertNil(score(elapsed: 0, blocksReceived: 0))
    }

    // A truncated stream (closed cleanly after a few blocks) must not score either.
    func testFetchScoreTruncatedStreamRuledOut() {
        XCTAssertNil(score(elapsed: 0.4, blocksReceived: 7))
    }

    // Crossing the threshold rules a candidate out entirely.
    func testFetchScoreOverThresholdRuledOut() {
        XCTAssertNil(score(elapsed: 60.05, blocksReceived: 100))
    }

    // The current server keeps a censored score past the threshold so the gates still apply:
    // a 250 ms threshold miss must produce a gated comparison, not an unconditional switch.
    func testFetchScoreOverThresholdCurrentIsCensored() {
        XCTAssertEqual(score(elapsed: 60.05, blocksReceived: 40, retainOverThreshold: true), 60.05)
    }

    // Delivering everything but too slowly is still over threshold for a candidate.
    func testFetchScoreSlowFullDeliveryRuledOut() {
        XCTAssertNil(score(elapsed: 75.0, blocksReceived: 100))
    }

    // A non-positive elapsed time is a broken measurement, current server or not.
    func testFetchScoreNonPositiveElapsedRuledOut() {
        XCTAssertNil(score(elapsed: -3.0, blocksReceived: 100, retainOverThreshold: true))
        XCTAssertNil(score(elapsed: 0, blocksReceived: 100, retainOverThreshold: true))
    }

    // MARK: - evaluate (orchestration driver)

    private final class BenchmarkStub {
        private(set) var requests: [[LightWalletEndpoint]] = []
        private var queued: [[ServerSwitchDecision.MeasuredEndpoint]]

        init(_ queued: [[ServerSwitchDecision.MeasuredEndpoint]]) {
            self.queued = queued
        }

        func benchmark(_ endpoints: [LightWalletEndpoint]) async -> [ServerSwitchDecision.MeasuredEndpoint] {
            requests.append(endpoints)
            guard !queued.isEmpty else { return [] }
            return queued.removeFirst()
        }
    }

    private func evaluate(
        current: LightWalletEndpoint,
        candidates: [LightWalletEndpoint],
        stub: BenchmarkStub
    ) async -> LightWalletEndpoint? {
        await ServerSwitchDecision.evaluate(
            current: current,
            candidates: candidates,
            thresholds: .blockFetch,
            logger: NullLogger(),
            benchmark: stub.benchmark
        )
    }

    // The current server is always measured: a candidate list without it gets it appended.
    func testEvaluateUnionsCurrentIntoCandidates() async {
        let stub = BenchmarkStub([
            [measured("current.example", score: 0.1), measured("a.example", score: 0.4)]
        ])
        let result = await evaluate(current: endpoint("current.example"), candidates: [endpoint("a.example")], stub: stub)

        XCTAssertNil(result)
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertEqual(stub.requests[0].map(\.host), ["a.example", "current.example"])
    }

    // A list that already contains the current server (same host+port+secure) is passed as-is.
    func testEvaluateDoesNotDuplicateCurrent() async {
        let stub = BenchmarkStub([
            [measured("current.example", score: 0.1)]
        ])
        _ = await evaluate(
            current: endpoint("current.example"),
            candidates: [endpoint("current.example"), endpoint("a.example")],
            stub: stub
        )

        XCTAssertEqual(stub.requests[0].map(\.host), ["current.example", "a.example"])
    }

    // When the current server is ranked, no re-probe happens.
    func testEvaluateSkipsReprobeWhenCurrentRanked() async {
        let stub = BenchmarkStub([
            [measured("best.example", score: 0.15), measured("current.example", score: 0.4)]
        ])
        let result = await evaluate(current: endpoint("current.example"), candidates: [endpoint("best.example")], stub: stub)

        XCTAssertEqual(result?.host, "best.example")
        XCTAssertEqual(stub.requests.count, 1)
    }

    // A current server missing from the first run gets exactly one confirming re-probe; when the
    // re-probe answers, the outcome is gated — a transient failure cannot force a switch.
    func testEvaluateReprobeRecoversCurrentAndGatesTheDecision() async {
        let stub = BenchmarkStub([
            [measured("best.example", score: 0.38)],
            [measured("current.example", score: 0.4)]
        ])
        let result = await evaluate(current: endpoint("current.example"), candidates: [endpoint("best.example")], stub: stub)

        XCTAssertNil(result)
        XCTAssertEqual(stub.requests.count, 2)
        XCTAssertEqual(stub.requests[1].map(\.host), ["current.example"])
    }

    // When the re-probed current measures faster than every candidate, the wallet stays.
    func testEvaluateReprobedCurrentCanWinOutright() async {
        let stub = BenchmarkStub([
            [measured("best.example", score: 0.38)],
            [measured("current.example", score: 0.2)]
        ])
        let result = await evaluate(current: endpoint("current.example"), candidates: [endpoint("best.example")], stub: stub)

        XCTAssertNil(result)
    }

    // Two consecutive missing measurements mean the current server really is unhealthy →
    // unconditional switch to the best candidate.
    func testEvaluateSwitchesWhenReprobeFailsToo() async {
        let stub = BenchmarkStub([
            [measured("best.example", score: 0.38)],
            []
        ])
        let result = await evaluate(current: endpoint("current.example"), candidates: [endpoint("best.example")], stub: stub)

        XCTAssertEqual(result?.host, "best.example")
        XCTAssertEqual(stub.requests.count, 2)
    }

    // No healthy results at all → stay, and the re-probe was still attempted for current.
    func testEvaluateNoResultsStays() async {
        let stub = BenchmarkStub([[], []])
        let result = await evaluate(current: endpoint("current.example"), candidates: [endpoint("a.example")], stub: stub)

        XCTAssertNil(result)
        XCTAssertEqual(stub.requests.count, 2)
    }

    // An empty candidate list still measures the current server and stays on it.
    func testEvaluateEmptyCandidatesMeasuresCurrent() async {
        let stub = BenchmarkStub([
            [measured("current.example", score: 0.3)]
        ])
        let result = await evaluate(current: endpoint("current.example"), candidates: [], stub: stub)

        XCTAssertNil(result)
        XCTAssertEqual(stub.requests[0].map(\.host), ["current.example"])
    }

    // A cancelled evaluation returns nil (stay) without acting on the benchmark's answer, even
    // when that answer would clear both gates.
    func testEvaluateCancelledReturnsStay() async {
        let current = endpoint("current.example")
        let task = Task { () -> LightWalletEndpoint? in
            await ServerSwitchDecision.evaluate(
                current: current,
                candidates: [self.endpoint("best.example")],
                thresholds: .blockFetch,
                logger: NullLogger(),
                benchmark: { _ in
                    // Park until the surrounding task is cancelled, then report a result that
                    // would otherwise clear both gates.
                    while !Task.isCancelled {
                        await Task.yield()
                    }
                    return [
                        self.measured("best.example", score: 0.1),
                        self.measured("current.example", score: 9.0)
                    ]
                }
            )
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }

    // MARK: - Endpoint identity

    func testIsSameServerRequiresHostPortAndSecure() {
        XCTAssertTrue(endpoint("a.example").isSameServer(as: endpoint("a.example")))
        XCTAssertFalse(endpoint("a.example").isSameServer(as: endpoint("b.example")))
        XCTAssertFalse(endpoint("a.example", port: 443).isSameServer(as: endpoint("a.example", port: 9067)))
        XCTAssertFalse(endpoint("a.example", secure: true).isSameServer(as: endpoint("a.example", secure: false)))
    }
}
