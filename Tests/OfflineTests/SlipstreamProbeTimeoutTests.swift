//
//  SlipstreamProbeTimeoutTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

/// Coverage for `SlipstreamSynchronizer.probe(_:timeoutSeconds:using:)`, the per-endpoint
/// benchmark probe extracted so it can be bounded independently of the endpoint's own gRPC
/// single-call default (MOB-1849). A slow service must not be able to hold up the probe past
/// its timeout, and every path -- timeout or success -- must close the service's connections.
final class SlipstreamProbeTimeoutTests: XCTestCase {
    private func endpoint(_ host: String = "current.example", port: Int = 443, secure: Bool = true) -> LightWalletEndpoint {
        LightWalletEndpoint(address: host, port: port, secure: secure, streamingCallTimeoutInMillis: 10000)
    }

    /// A `getInfo` that sleeps 2 s raced against a 0.1 s timeout must time out and return nil
    /// well under 1 s -- the probe's whole point is that it does not wait for a slow service.
    func testProbeTimesOutAndClosesConnections() async {
        let service = LightWalletServiceMock()
        service.closeConnectionsClosure = {}
        service.getInfoModeClosure = { _ in
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return LightWalletdInfoMock()
        }

        let start = Date()
        let result = await SlipstreamSynchronizer.probe(endpoint(), timeoutSeconds: 0.1, using: service)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 1.0)
        XCTAssertEqual(service.closeConnectionsCallsCount, 1)
    }

    /// A service that answers immediately produces a non-nil result with a non-negative round
    /// trip, and still closes the connection -- the bound must not change happy-path behavior.
    func testProbeReturnsResultAndClosesConnections() async {
        let service = LightWalletServiceMock()
        service.closeConnectionsClosure = {}
        service.getInfoModeReturnValue = LightWalletdInfoMock()

        let result = await SlipstreamSynchronizer.probe(
            endpoint(),
            timeoutSeconds: SlipstreamSynchronizer.serverProbeTimeoutSeconds,
            using: service
        )

        XCTAssertNotNil(result)
        XCTAssertGreaterThanOrEqual(result?.roundTrip ?? -1, 0)
        XCTAssertEqual(service.closeConnectionsCallsCount, 1)
    }
}
