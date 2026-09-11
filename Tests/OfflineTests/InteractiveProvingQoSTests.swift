//
//  InteractiveProvingQoSTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import ZcashLightClientKit

final class InteractiveProvingQoSTests: XCTestCase {
    func testBoostSessionsAreRefcountedAndSaturateAtZero() {
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 0)
        VotingRustBackend.beginInteractiveProvingBoost()
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 1)
        VotingRustBackend.beginInteractiveProvingBoost()
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 2)
        VotingRustBackend.endInteractiveProvingBoost()
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 1)
        VotingRustBackend.endInteractiveProvingBoost()
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 0)
        VotingRustBackend.endInteractiveProvingBoost()
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 0)
    }

    func testWarmProvingCachesLeavesBoostCountAtZero() throws {
        try VotingRustBackend.warmProvingCaches()
        XCTAssertEqual(VotingRustBackend.interactiveProvingBoostCount(), 0)
    }
}
