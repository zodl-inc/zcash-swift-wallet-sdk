//
//  VotingSessionFactoryTests.swift
//  ZcashLightClientKitTests
//

import Combine
import XCTest
@testable import TestUtils
@testable import ZcashLightClientKit

/// Who owns the Tor runtime a voting round rides.
///
/// A round session takes its route once, when it is opened, and keeps it for
/// its whole life — so the decision belongs to the synchronizer that owns the
/// wallet's Tor client, not to the caller holding a `VotingRustBackend`. These
/// tests pin the two ends of that: a `.tor` request against a synchronizer with
/// Tor switched off is refused before any handle is made, and a `.direct`
/// request opens a session that runs over plain HTTP.
final class VotingSessionFactoryTests: ZcashTestCase {
    private let walletId = "voting-session-factory-tests"

    // MARK: - Tor ownership

    /// Tor fails closed. The synchronizer refuses rather than quietly opening
    /// the round on the direct route, which would put the voter's traffic on
    /// the network they asked to stay off.
    func testTorRouteIsRefusedWhenTheSynchronizerHasTorDisabled() async throws {
        let environment = try await makeVotingSessionEnvironment(tag: 0x51, walletId: walletId)
        let synchronizer = try makeSynchronizer()

        do {
            _ = try await synchronizer.makeVotingRoundSession(
                backend: environment.backend,
                inputs: environment.inputs,
                binding: environment.binding,
                route: .tor,
                epoch: 1
            )
            XCTFail("a synchronizer with Tor disabled cannot open a round on Tor")
        } catch let error as ZcashError {
            guard case .torNotEnabled = error else {
                return XCTFail("expected torNotEnabled, got \(error)")
            }
        }

        // The refusal is the whole of it: nothing was written to the sidecar,
        // so the round the caller asked for does not exist half-open.
        XCTAssertEqual(try environment.backend.listRounds(), [])
    }

    // MARK: - Direct route

    func testDirectRouteOpensASessionForTheSyntheticRound() async throws {
        let environment = try await makeVotingSessionEnvironment(tag: 0x52, walletId: walletId)
        let synchronizer = try makeSynchronizer()

        let session = try await synchronizer.makeVotingRoundSession(
            backend: environment.backend,
            inputs: environment.inputs,
            binding: environment.binding,
            route: .direct,
            epoch: 1
        )

        XCTAssertEqual(session.roundId, environment.roundId)
        XCTAssertEqual(try session.plan().roundId, environment.roundId)

        await session.close()
    }

    // MARK: - Adapters

    /// The closure and Combine adapters are pass-throughs; what they have to
    /// get right is carrying both outcomes across the gateway rather than
    /// dropping the refusal or the session.
    func testClosureAdapterDeliversBothOutcomes() async throws {
        let environment = try await makeVotingSessionEnvironment(tag: 0x53, walletId: walletId)
        let synchronizer = ClosureSDKSynchronizer(synchronizer: try makeSynchronizer())

        let refused = expectation(description: "the tor route was refused")
        synchronizer.makeVotingRoundSession(
            backend: environment.backend,
            inputs: environment.inputs,
            binding: environment.binding,
            route: .tor,
            epoch: 1
        ) { result in
            if case .failure(let error) = result, case ZcashError.torNotEnabled = error {
                refused.fulfill()
            }
        }
        await fulfillment(of: [refused], timeout: 10)

        let opened = expectation(description: "the direct route opened a session")
        synchronizer.makeVotingRoundSession(
            backend: environment.backend,
            inputs: environment.inputs,
            binding: environment.binding,
            route: .direct,
            epoch: 1
        ) { result in
            guard case .success(let session) = result else { return }
            XCTAssertEqual(session.roundId, environment.roundId)
            Task {
                await session.close()
                opened.fulfill()
            }
        }
        await fulfillment(of: [opened], timeout: 10)
    }

    func testCombineAdapterDeliversBothOutcomes() async throws {
        let environment = try await makeVotingSessionEnvironment(tag: 0x54, walletId: walletId)
        let synchronizer = CombineSDKSynchronizer(synchronizer: try makeSynchronizer())

        do {
            _ = try await value(
                of: synchronizer.makeVotingRoundSession(
                    backend: environment.backend,
                    inputs: environment.inputs,
                    binding: environment.binding,
                    route: .tor,
                    epoch: 1
                )
            )
            XCTFail("a synchronizer with Tor disabled cannot open a round on Tor")
        } catch let error as ZcashError {
            guard case .torNotEnabled = error else {
                return XCTFail("expected torNotEnabled, got \(error)")
            }
        }

        let session = try await value(
            of: synchronizer.makeVotingRoundSession(
                backend: environment.backend,
                inputs: environment.inputs,
                binding: environment.binding,
                route: .direct,
                epoch: 1
            )
        )

        XCTAssertEqual(session.roundId, environment.roundId)
        await session.close()
    }

    // MARK: - Helpers

    /// An `SDKSynchronizer` over mocked collaborators, with both Tor flags off.
    ///
    /// Nothing here reaches the network: the factory under test either refuses
    /// on the flags or hands the round to the voting backend, which dials
    /// nothing while opening a session.
    private func makeSynchronizer() throws -> SDKSynchronizer {
        mockContainer.mock(type: ZcashRustBackendWelding.self, isSingleton: true) { _ in ZcashRustBackendWeldingMock() }
        mockContainer.mock(type: LightWalletService.self, isSingleton: true) { _ in LightWalletServiceMock() }
        mockContainer.mock(type: TransactionRepository.self, isSingleton: true) { _ in TransactionRepositoryMock() }

        let initializer = Initializer(
            container: mockContainer,
            cacheDbURL: nil,
            fsBlockDbRoot: testTempDirectory,
            generalStorageURL: testGeneralStorageDirectory,
            dataDbURL: try __dataDbURL(),
            torDirURL: try __torDirURL(),
            endpoint: LightWalletEndpointBuilder.default,
            network: ZcashNetworkBuilder.network(for: .testnet),
            spendParamsURL: try __spendParamsURL(),
            outputParamsURL: try __outputParamsURL(),
            saplingParamsSourceURL: SaplingParamsSourceURL.tests,
            isTorEnabled: false,
            isExchangeRateEnabled: false
        )

        return SDKSynchronizer(initializer: initializer)
    }

    /// The one value a `SinglePublisher` carries, or the failure it completes
    /// with. `first()` bounds it to one value so the continuation resumes
    /// exactly once, from the completion.
    private func value<Output>(of publisher: SinglePublisher<Output, Error>) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            var cancellable: AnyCancellable?
            var received: Result<Output, Error>?

            cancellable = publisher
                .first()
                .sink(
                    receiveCompletion: { completion in
                        if case .failure(let error) = completion {
                            received = .failure(error)
                        }
                        continuation.resume(with: received ?? .failure(VotingSessionFactoryFailure.publisherFinishedWithoutAValue))
                        cancellable?.cancel()
                        cancellable = nil
                    },
                    receiveValue: { output in
                        received = .success(output)
                    }
                )
        }
    }
}

/// A publisher that finishes without a value is a failure of this harness, not
/// an outcome the factory can produce.
private enum VotingSessionFactoryFailure: Error {
    case publisherFinishedWithoutAValue
}
