//
//  VotingTypesTests.swift
//  ZcashLightClientKitTests
//

import XCTest
@testable import ZcashLightClientKit

/// The Swift wire types must mirror the JSON the voting FFI exchanges: the
/// request DTOs of `rust/src/voting/wire.rs` and the `zcash_voting::wire`
/// views. Every fixture here is written in the crate's own shape — snake_case
/// keys, base64 byte fields, and the fields this SDK does not model left in,
/// so decoding proves the types ignore what they do not name.
final class VotingTypesTests: XCTestCase {
    // MARK: - Round run report

    func testDecodesRoundRunReportWithDelegationSignatureQuiescence() throws {
        let json = """
        {
          "quiescence": {
            "kind": "needs_delegation_signatures",
            "open_proposals": [],
            "unrostered_intents": [],
            "bundles": [0, 1],
            "shares": [],
            "step": null,
            "chain_outcome": null,
            "remaining": []
          },
          "plan": null,
          "tally": {"completed_proposals": 0, "total_proposals": 2, "remaining_obligations": 2},
          "failures": [],
          "skipped_bundles": [],
          "chain_outcomes": [],
          "share_deliveries": [],
          "delegations": []
        }
        """

        let report = try decode(VotingRoundRunReport.self, from: json)

        XCTAssertEqual(report.quiescence.kind, .needsDelegationSignatures)
        XCTAssertEqual(report.quiescence.bundles, [0, 1])
        XCTAssertTrue(report.quiescence.shares.isEmpty)
        XCTAssertNil(report.quiescence.step)
        XCTAssertNil(report.plan)
        XCTAssertEqual(report.tally.totalProposals, 2)
        XCTAssertEqual(report.tally.remainingObligations, 2)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(report.skippedBundles.isEmpty)
        XCTAssertTrue(report.chainOutcomes.isEmpty)
    }

    func testDecodesRoundRunReportFailureRecordAndChainOutcome() throws {
        let json = """
        {
          "quiescence": {
            "kind": "failures",
            "open_proposals": [],
            "unrostered_intents": [],
            "bundles": [],
            "shares": [{"bundle_index": 0, "proposal_id": 7, "share_index": 2}],
            "step": null,
            "chain_outcome": null,
            "remaining": []
          },
          "plan": null,
          "tally": {"completed_proposals": 1, "total_proposals": 2, "remaining_obligations": 1},
          "failures": [
            {
              "step": {
                "kind": "advance_vote_batch",
                "bundle_index": 0,
                "proposal_id": 7,
                "choice": 1,
                "share_index": 0
              },
              "bundle_index": 0,
              "failure": {
                "kind": "helper_delivery_incomplete",
                "step": null,
                "strongest_chain_state": null,
                "chain_outcome": null,
                "message": "two of three helpers accepted",
                "plan": null,
                "share_deliveries": [],
                "delegation": null
              }
            }
          ],
          "skipped_bundles": [0],
          "chain_outcomes": [
            {
              "step": {
                "kind": "advance_delegation",
                "bundle_index": 0,
                "proposal_id": 0,
                "choice": 0,
                "share_index": 0
              },
              "outcome": {
                "kind": "confirmed",
                "confirmation_source": "tree",
                "transaction_hash": "aa",
                "candidate_transaction_hash": null,
                "final_van_position": 12,
                "vote_commitment_positions": [3, 4],
                "diagnostic": null
              }
            }
          ]
        }
        """

        let report = try decode(VotingRoundRunReport.self, from: json)

        XCTAssertEqual(report.quiescence.kind, .failures)
        XCTAssertEqual(report.quiescence.shares, [VotingShareKey(bundleIndex: 0, proposalId: 7, shareIndex: 2)])
        XCTAssertEqual(report.skippedBundles, [0])
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.bundleIndex, 0)
        XCTAssertEqual(report.failures.first?.failure.kind, .helperDeliveryIncomplete)
        XCTAssertEqual(report.failures.first?.failure.message, "two of three helpers accepted")
        XCTAssertEqual(report.failures.first?.step?.kind, .advanceVoteBatch)
        XCTAssertEqual(report.failures.first?.step?.proposalId, 7)
        XCTAssertEqual(report.chainOutcomes.first?.step.kind, .advanceDelegation)
        XCTAssertEqual(report.chainOutcomes.first?.outcome.kind, .confirmed)
        XCTAssertEqual(report.chainOutcomes.first?.outcome.confirmationSource, "tree")
        XCTAssertEqual(report.chainOutcomes.first?.outcome.finalVanPosition, 12)
        XCTAssertEqual(report.chainOutcomes.first?.outcome.voteCommitmentPositions, [3, 4])
        XCTAssertNil(report.chainOutcomes.first?.outcome.diagnosticMessage)
    }

    // MARK: - Round plan

    func testDecodesRoundPlanFieldNames() throws {
        let plan = try decode(VotingRoundPlan.self, from: Self.roundPlanJson)

        XCTAssertEqual(plan.roundId, "round-1")
        XCTAssertFalse(plan.pendingRecovery)
        XCTAssertTrue(plan.blockingRecovery)
        XCTAssertFalse(plan.blockingShareWork)
        XCTAssertTrue(plan.hasUnconfirmedShares)
        XCTAssertTrue(plan.hotkeyBound)
        XCTAssertFalse(plan.completedForDisplay)
        XCTAssertEqual(plan.completedVoteDisplay?.votedAt, 1_700_000_000)
        XCTAssertEqual(
            plan.completedVoteDisplay?.choices,
            [VotingCompletedVoteChoice(proposalId: 7, choice: 1), VotingCompletedVoteChoice(proposalId: 8, choice: nil)]
        )
        XCTAssertFalse(plan.needsDraftSetup)
        XCTAssertTrue(plan.needsBundleSetup)
        XCTAssertTrue(plan.needsDelegationSigning)
        XCTAssertFalse(plan.hasInFlightDelegation)
        XCTAssertEqual(plan.delegationBundlesNeedingWork, [0, 1])
        XCTAssertEqual(plan.delegationBundlesNeedingSigning, [1])
        XCTAssertTrue(plan.needsVotePolling)
        XCTAssertTrue(plan.hasRemainingVoteOrShareWork)
        XCTAssertTrue(plan.hasRecoverableVoteOrShareWork)
        XCTAssertEqual(plan.primaryAction, .delegate)
        XCTAssertEqual(plan.openProposals, [7, 8])
        XCTAssertEqual(plan.unrosteredIntents, [9])
        XCTAssertFalse(plan.immediateShareConfirmed)
        XCTAssertFalse(plan.allDecided)

        XCTAssertEqual(plan.delegationStatuses.count, 2)
        XCTAssertEqual(plan.delegationStatuses.first?.bundleIndex, 0)
        XCTAssertEqual(plan.delegationStatuses.first?.phase, .submittedDelegation)
        XCTAssertEqual(plan.delegationStatuses.first?.txHash, "ff")
        XCTAssertEqual(plan.delegationStatuses.first?.terminal, false)
        XCTAssertEqual(plan.delegationStatuses.last?.phase, .prepared)
        XCTAssertNil(plan.delegationStatuses.last?.txHash)
        XCTAssertEqual(plan.delegationStatuses.last?.terminal, true)
    }

    func testDecodesUnknownEnumRawValuesAsUnknown() throws {
        let json = Self.roundPlanJson
            .replacingOccurrences(of: "\"primary_action\": \"delegate\"", with: "\"primary_action\": \"future_action\"")
            .replacingOccurrences(of: "\"phase\": \"prepared\"", with: "\"phase\": \"future_phase\"")

        let plan = try decode(VotingRoundPlan.self, from: json)

        XCTAssertEqual(plan.primaryAction, .unknown)
        XCTAssertEqual(plan.delegationStatuses.last?.phase, .unknown)
    }

    // MARK: - Events

    func testDecodesRoundDriveEventWithUnknownKind() throws {
        let json = """
        {
          "kind": "future_kind",
          "step": null,
          "plan": null,
          "tally": null,
          "progress": null,
          "disposition": null,
          "failure_kind": null,
          "message": "a kind this SDK does not name",
          "delay_seconds": null,
          "bundle_index": null
        }
        """

        let event = try decode(VotingRoundDriveEvent.self, from: json)

        XCTAssertEqual(event.kind, .unknown)
        XCTAssertEqual(event.message, "a kind this SDK does not name")
        XCTAssertNil(event.step)
        XCTAssertNil(event.progress)
    }

    func testDecodesRoundDriveEventStepProgress() throws {
        let json = """
        {
          "kind": "step_progress",
          "step": {"kind": "delegate", "bundle_index": 1, "proposal_id": 0, "choice": 0, "share_index": 0},
          "plan": null,
          "tally": null,
          "progress": {
            "kind": "delegation",
            "step": null,
            "bundle_index": 1,
            "proposal_id": null,
            "delegation_progress": "proof_progress",
            "vote_commit_stage": null,
            "proof_progress": 0.25,
            "tree_height": null,
            "vote_keys": [],
            "chain_outcome": null,
            "share_delivery": null,
            "share": null,
            "share_confirmed": null
          },
          "disposition": null,
          "failure_kind": null,
          "message": null,
          "delay_seconds": null,
          "bundle_index": null
        }
        """

        let event = try decode(VotingRoundDriveEvent.self, from: json)

        XCTAssertEqual(event.kind, .stepProgress)
        XCTAssertEqual(event.step?.kind, .delegate)
        XCTAssertEqual(event.step?.bundleIndex, 1)
        XCTAssertEqual(event.progress?.kind, .delegation)
        XCTAssertEqual(event.progress?.bundleIndex, 1)
        XCTAssertEqual(event.progress?.delegationProgress, .proofProgress)
        XCTAssertEqual(event.progress?.proofProgress, 0.25)
        XCTAssertNil(event.progress?.shareConfirmed)
    }

    func testDecodesSessionEventEnvelopes() throws {
        let roundDrive = """
        {
          "kind": "round_drive",
          "event": {
            "kind": "awaiting_repoll",
            "step": null,
            "plan": null,
            "tally": null,
            "progress": null,
            "disposition": null,
            "failure_kind": null,
            "message": null,
            "delay_seconds": 2.0,
            "bundle_index": null
          }
        }
        """
        let shareTracking = """
        {
          "kind": "share_tracking",
          "event": {
            "kind": "pass_failed",
            "pass": 3,
            "report": null,
            "message": "helper unreachable",
            "delay_seconds": null
          }
        }
        """
        let delegationProgress = """
        {
          "kind": "delegation_progress",
          "progress": {"bundle_index": 2, "stage": "proof_progress", "fraction": 0.5}
        }
        """

        switch try decode(VotingSessionEvent.self, from: roundDrive) {
        case .roundDrive(let event):
            XCTAssertEqual(event.kind, .awaitingRepoll)
            XCTAssertEqual(event.delaySeconds, 2)
        default:
            XCTFail("expected a round drive event")
        }

        switch try decode(VotingSessionEvent.self, from: shareTracking) {
        case .shareTracking(let event):
            XCTAssertEqual(event.kind, .passFailed)
            XCTAssertEqual(event.pass, 3)
            XCTAssertEqual(event.message, "helper unreachable")
        default:
            XCTFail("expected a share tracking event")
        }

        switch try decode(VotingSessionEvent.self, from: delegationProgress) {
        case .delegationProgress(let progress):
            XCTAssertEqual(progress.bundleIndex, 2)
            XCTAssertEqual(progress.stage, .proofProgress)
            XCTAssertEqual(progress.fraction, 0.5)
        default:
            XCTFail("expected a delegation progress event")
        }
    }

    func testDecodesSessionEventWithUnknownKindAsUnknown() throws {
        let json = """
        {"kind": "future_kind", "payload": {"anything": 1}}
        """

        XCTAssertEqual(try decode(VotingSessionEvent.self, from: json), .unknown)
    }

    func testDecodesDelegationProgressWithUnknownStage() throws {
        let json = """
        {"bundle_index": 0, "stage": "future_stage", "fraction": null}
        """

        let progress = try decode(VotingDelegationProgress.self, from: json)

        XCTAssertEqual(progress.stage, .unknown)
        XCTAssertNil(progress.fraction)
    }

    // MARK: - Share tracking

    func testDecodesShareTrackingRunReport() throws {
        let json = """
        {
          "quiescence": {
            "kind": "pass_budget_exhausted",
            "messages": ["helper 2 timed out"],
            "unrecoverable": []
          },
          "passes": 4,
          "confirmed": [{"bundle_index": 0, "proposal_id": 7, "share_index": 1}],
          "resubmitted": [],
          "ambiguous": [],
          "unrecoverable": [{"bundle_index": 0, "proposal_id": 7, "share_index": 2}],
          "failures": ["helper 2 timed out"]
        }
        """

        let report = try decode(VotingShareTrackingRunReport.self, from: json)

        XCTAssertEqual(report.quiescence.kind, .passBudgetExhausted)
        XCTAssertEqual(report.quiescence.messages, ["helper 2 timed out"])
        XCTAssertEqual(report.passes, 4)
        XCTAssertEqual(report.confirmed, [VotingShareKey(bundleIndex: 0, proposalId: 7, shareIndex: 1)])
        XCTAssertEqual(report.unrecoverable, [VotingShareKey(bundleIndex: 0, proposalId: 7, shareIndex: 2)])
        XCTAssertEqual(report.failures, ["helper 2 timed out"])
    }

    // MARK: - Session and store results

    func testDecodesProofStatusFromStatusEnvelope() throws {
        XCTAssertEqual(try decode(VotingDelegationProofStatus.self, from: #"{"status": "generated"}"#), .generated)
        XCTAssertEqual(try decode(VotingDelegationProofStatus.self, from: #"{"status": "reused"}"#), .reused)
        XCTAssertEqual(try decode(VotingDelegationProofStatus.self, from: #"{"status": "future"}"#), .unknown)
    }

    func testDecodesChainSubmissionOutcomeDiagnosticMessage() throws {
        let json = """
        {
          "kind": "rejected",
          "confirmation_source": null,
          "transaction_hash": null,
          "candidate_transaction_hash": "abcd",
          "final_van_position": null,
          "vote_commitment_positions": [],
          "diagnostic": {"kind": "nullifier_already_spent", "message": "nullifier already spent"}
        }
        """

        let outcome = try decode(VotingChainSubmissionOutcome.self, from: json)

        XCTAssertEqual(outcome.kind, .rejected)
        XCTAssertEqual(outcome.candidateTransactionHash, "abcd")
        XCTAssertEqual(outcome.diagnosticMessage, "nullifier already spent")
    }

    func testDecodesKeystoneAndLayoutResults() throws {
        let request = try decode(
            VotingKeystoneSigningRequest.self,
            from: """
            {
              "bundle_index": 1,
              "bundle_count": 3,
              "redacted_pczt": "AQID",
              "pczt_sighash": "BAUG",
              "rk": "BwgJ",
              "action_index": 0,
              "display_memo": "memo",
              "eligible_weight_zatoshi": 1000,
              "delegated_weight_zatoshi": 500
            }
            """
        )
        XCTAssertEqual(request.bundleIndex, 1)
        XCTAssertEqual(request.bundleCount, 3)
        XCTAssertEqual(request.redactedPczt, Data([1, 2, 3]))
        XCTAssertEqual(request.pcztSighash, Data([4, 5, 6]))
        XCTAssertEqual(request.randomizedKey, Data([7, 8, 9]))
        XCTAssertEqual(request.displayMemo, "memo")
        XCTAssertEqual(request.eligibleWeightZatoshi, 1000)
        XCTAssertEqual(request.delegatedWeightZatoshi, 500)

        let record = try decode(
            VotingKeystoneSignatureRecord.self,
            from: #"{"bundle_index": 2, "sig": "AQID", "sighash": "BAUG", "rk": "BwgJ"}"#
        )
        XCTAssertEqual(record.bundleIndex, 2)
        XCTAssertEqual(record.sig, Data([1, 2, 3]))
        XCTAssertEqual(record.sighash, Data([4, 5, 6]))
        XCTAssertEqual(record.randomizedKey, Data([7, 8, 9]))

        let batch = try decode(
            VotingKeystoneSignatureBatchResult.self,
            from: #"{"inserted": 2, "already_present": 1}"#
        )
        XCTAssertEqual(batch.inserted, 2)
        XCTAssertEqual(batch.alreadyPresent, 1)

        let layout = try decode(
            VotingBundleLayout.self,
            from: """
            {
              "bundle_count": 2,
              "eligible_weight": 5000,
              "dropped_count": 1,
              "privacy_trim_dropped_bundles": 0,
              "privacy_trim_dropped_notes": 3
            }
            """
        )
        XCTAssertEqual(layout.bundleCount, 2)
        XCTAssertEqual(layout.eligibleWeight, 5000)
        XCTAssertEqual(layout.droppedCount, 1)
        XCTAssertEqual(layout.privacyTrimDroppedBundles, 0)
        XCTAssertEqual(layout.privacyTrimDroppedNotes, 3)
    }

    func testDecodesEligibilityPrecomputeSummaryAndPendingRound() throws {
        let eligibility = try decode(
            VotingEligibilityReport.self,
            from: """
            {
              "distinct_note_count": 4,
              "eligible_weight": 9000,
              "is_eligible": true,
              "privacy_trim_dropped_value_zatoshi": 250
            }
            """
        )
        XCTAssertEqual(eligibility.distinctNoteCount, 4)
        XCTAssertEqual(eligibility.eligibleWeight, 9000)
        XCTAssertTrue(eligibility.isEligible)
        XCTAssertEqual(eligibility.privacyTrimDroppedValueZatoshi, 250)

        let precompute = try decode(
            VotingPirPrecomputeReport.self,
            from: #"{"bundle_index": 1, "cached": 12, "fetched": 3, "bundle_count": 2}"#
        )
        XCTAssertEqual(precompute.bundleIndex, 1)
        XCTAssertEqual(precompute.cached, 12)
        XCTAssertEqual(precompute.fetched, 3)
        XCTAssertEqual(precompute.bundleCount, 2)

        let summary = try decode(
            VotingRoundSummary.self,
            from: """
            {
              "round_id": "r1",
              "wallet_id": "w1",
              "phase": "delegationconstructed",
              "network": "testnet",
              "snapshot_height": 42,
              "created_at": 99
            }
            """
        )
        XCTAssertEqual(summary.roundId, "r1")
        XCTAssertEqual(summary.walletId, "w1")
        XCTAssertEqual(summary.phase, "delegationconstructed")
        XCTAssertEqual(summary.network, "testnet")
        XCTAssertEqual(summary.snapshotHeight, 42)
        XCTAssertEqual(summary.createdAt, 99)

        let pending = try decode(
            VotingPendingShareRound.self,
            from: #"{"wallet_id": "w1", "round_id": "r1", "session_json": null}"#
        )
        XCTAssertEqual(pending.walletId, "w1")
        XCTAssertEqual(pending.roundId, "r1")
        XCTAssertNil(pending.sessionJson)
    }

    // MARK: - Errors

    func testDecodesVotingErrorFromWireJson() throws {
        let json = """
        {
          "kind": "no_spendable_notes",
          "retryable": false,
          "message": "m",
          "bundle_index": null,
          "setup_field": null,
          "snapshot_height": 10,
          "required_weight_zatoshi": 1,
          "selected_weight_zatoshi": 0,
          "bundle_note_slots": 5,
          "selected_notes": 0,
          "http_status": null,
          "endpoint": null
        }
        """

        let error = try decode(VotingError.self, from: json)

        XCTAssertEqual(error.kind, .noSpendableNotes)
        XCTAssertFalse(error.retryable)
        XCTAssertEqual(error.message, "m")
        XCTAssertNil(error.bundleIndex)
        XCTAssertNil(error.httpStatus)
        XCTAssertNil(error.endpoint)
    }

    func testDecodesVotingErrorWithUnknownKindAsOther() throws {
        let json = """
        {"kind": "future_kind", "retryable": true, "message": "m", "bundle_index": 3, "http_status": 503, "endpoint": "https://pir.example"}
        """

        let error = try decode(VotingError.self, from: json)

        XCTAssertEqual(error.kind, .other)
        XCTAssertTrue(error.retryable)
        XCTAssertEqual(error.bundleIndex, 3)
        XCTAssertEqual(error.httpStatus, 503)
        XCTAssertEqual(error.endpoint, "https://pir.example")
    }

    func testFromLastErrorMessageDecodesTheWireEnvelope() {
        let json = """
        {"kind": "pir_unavailable", "retryable": true, "message": "pir down", "bundle_index": null, "http_status": 502, "endpoint": "https://pir.example"}
        """

        let error = VotingError.fromLastErrorMessage(json)

        XCTAssertEqual(error.kind, .pirUnavailable)
        XCTAssertTrue(error.retryable)
        XCTAssertEqual(error.message, "pir down")
        XCTAssertEqual(error.httpStatus, 502)
        XCTAssertEqual(error.endpoint, "https://pir.example")
    }

    func testFromLastErrorMessageKeepsPlainTextAsOther() {
        let error = VotingError.fromLastErrorMessage("plain text")

        XCTAssertEqual(error.kind, .other)
        XCTAssertFalse(error.retryable)
        XCTAssertEqual(error.message, "plain text")
        XCTAssertNil(error.bundleIndex)
        XCTAssertNil(error.httpStatus)
        XCTAssertNil(error.endpoint)
    }

    // MARK: - Requests

    func testEncodesBallotIntentDecisions() throws {
        let choice = try encodedObject(VotingBallotIntent(proposalId: 3, decision: .choice(1)))
        XCTAssertEqual(choice["proposal_id"] as? UInt32, 3)
        XCTAssertEqual(choice["decision"] as? String, "choice")
        XCTAssertEqual(choice["option"] as? UInt32, 1)

        let skipped = try encodedObject(VotingBallotIntent(proposalId: 4, decision: .skipped))
        XCTAssertEqual(skipped["proposal_id"] as? UInt32, 4)
        XCTAssertEqual(skipped["decision"] as? String, "skipped")
        XCTAssertNil(skipped["option"])

        let json = try encodedString(VotingBallotIntent(proposalId: 3, decision: .choice(1)))
        XCTAssertTrue(json.contains("\"decision\":\"choice\""), json)
        XCTAssertTrue(json.contains("\"option\":1"), json)
    }

    func testEncodesDelegationSignerVariants() throws {
        let none = try encodedObject(VotingDelegationSigner.none)
        XCTAssertEqual(none["kind"] as? String, "none")
        XCTAssertEqual(none.count, 1)

        let stored = try encodedObject(VotingDelegationSigner.keystoneStored)
        XCTAssertEqual(stored["kind"] as? String, "keystone_stored")
        XCTAssertEqual(stored.count, 1)

        let json = try encodedString(VotingDelegationSigner.software(seed: [1, 2, 3]))
        XCTAssertTrue(json.contains("\"kind\":\"software\""), json)
        XCTAssertTrue(json.contains("\"seed\":\"AQID\""), json)
    }

    func testEncodesDefaultDrivePolicy() throws {
        let json = try encodedString(VotingRoundDrivePolicy.default)
        XCTAssertTrue(json.contains("\"max_bundle_concurrency\":2"), json)
        XCTAssertTrue(json.contains("\"max_proof_concurrency\":1"), json)

        let object = try encodedObject(VotingRoundDrivePolicy.default)
        XCTAssertEqual(object["pending_repoll_seconds"] as? Double, 2)
        XCTAssertEqual(object["failure_isolation"] as? String, "skip_bundle")
        XCTAssertEqual(object["max_dispatches"] as? Int, 512)
        XCTAssertEqual(object["progress_baseline"] as? String, "run")
    }

    func testEncodesDefaultTrackingAndProvingPolicies() throws {
        let tracking = try encodedObject(VotingShareTrackingPolicy.default)
        XCTAssertEqual(tracking["failure_retry_seconds"] as? Double, 15)
        XCTAssertEqual(tracking["max_consecutive_failures"] as? UInt32, 240)
        XCTAssertNil(tracking["max_passes"])

        let bounded = try encodedObject(VotingShareTrackingPolicy(maxPasses: 5))
        XCTAssertEqual(bounded["max_passes"] as? UInt32, 5)

        let proving = try encodedObject(VotingProvingPolicy.default)
        XCTAssertNil(proving["cpu_worker_count"])
        XCTAssertEqual(proving["max_active_heavy_jobs"] as? Int, 1)
    }

    func testEncodesHostOverridesOmittingAbsentAndClearedValues() throws {
        let empty = try encodedObject(VotingHostOverrides())
        XCTAssertTrue(empty.isEmpty, "\(empty)")

        let present = try encodedObject(
            VotingHostOverrides(
                helperUrls: ["https://helper.example"],
                ceremonyStartSeconds: .some(1_700_000_000),
                voteEndTimeSeconds: .some(nil)
            )
        )
        XCTAssertEqual(present["helper_urls"] as? [String], ["https://helper.example"])
        XCTAssertNil(present["vote_tree_node_urls"])
        XCTAssertEqual(present["ceremony_start_seconds"] as? UInt64, 1_700_000_000)
        XCTAssertNil(present["vote_end_time_seconds"], "an inner nil cannot be expressed to Rust and is encoded as absent")
    }

    func testEncodesSessionInputsWithCrateFieldNamesAndBase64Bytes() throws {
        let inputs = VotingSessionInputs(
            accountUUID: "11111111-1111-1111-1111-111111111111",
            walletDbPath: "/tmp/wallet.sqlite3",
            roundParams: VotingRoundParameters(
                voteRoundId: "round-1",
                snapshotHeight: 10,
                eaPk: Data([1, 2, 3]),
                ncRoot: Data([4, 5, 6]),
                nullifierImtRoot: Data([7, 8, 9])
            ),
            roundName: "Q3 governance",
            anchorTreeState: Data([1, 2, 3]),
            chainEndpoints: ["https://chain.example"],
            voteTreeNodeUrls: ["https://tree.example"],
            helperUrls: ["https://helper.example"],
            pirEndpoints: ["https://pir.example"],
            pirLayout: VotingPirLayout(pirDepth: 1, tier0Layers: 2, tier1Layers: 3, polyLen: 2048),
            ceremonyStartSeconds: 1_700_000_000,
            voteEndTimeSeconds: nil
        )

        let object = try encodedObject(inputs)

        XCTAssertEqual(object["account_uuid"] as? String, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(object["wallet_db_path"] as? String, "/tmp/wallet.sqlite3")
        XCTAssertEqual(object["round_name"] as? String, "Q3 governance")
        XCTAssertEqual(object["anchor_tree_state"] as? String, "AQID")
        XCTAssertEqual(object["chain_endpoints"] as? [String], ["https://chain.example"])
        XCTAssertEqual(object["vote_tree_node_urls"] as? [String], ["https://tree.example"])
        XCTAssertEqual(object["helper_urls"] as? [String], ["https://helper.example"])
        XCTAssertEqual(object["pir_endpoints"] as? [String], ["https://pir.example"])
        XCTAssertEqual(object["ceremony_start_seconds"] as? UInt64, 1_700_000_000)
        XCTAssertNil(object["vote_end_time_seconds"])

        let params = try XCTUnwrap(object["round_params"] as? [String: Any])
        XCTAssertEqual(params["vote_round_id"] as? String, "round-1")
        XCTAssertEqual(params["snapshot_height"] as? UInt64, 10)
        XCTAssertEqual(params["ea_pk"] as? String, "AQID")
        XCTAssertEqual(params["nc_root"] as? String, "BAUG")
        XCTAssertEqual(params["nullifier_imt_root"] as? String, "BwgJ")

        let layout = try XCTUnwrap(object["pir_layout"] as? [String: Any])
        XCTAssertEqual(layout["pir_depth"] as? UInt32, 1)
        XCTAssertEqual(layout["tier0_layers"] as? UInt32, 2)
        XCTAssertEqual(layout["tier1_layers"] as? UInt32, 3)
        XCTAssertEqual(layout["poly_len"] as? UInt32, 2048)
    }

    func testEncodesSessionBindingAndSignedBundle() throws {
        let unbound = try encodedObject(
            VotingSessionBinding(roster: [VotingProposalRosterEntry(proposalId: 1, numOptions: 2)])
        )
        let roster = try XCTUnwrap(unbound["roster"] as? [[String: Any]])
        XCTAssertEqual(roster.first?["proposal_id"] as? UInt32, 1)
        XCTAssertEqual(roster.first?["num_options"] as? UInt32, 2)
        XCTAssertNil(unbound["hotkey_secret"])

        let bound = try encodedObject(
            VotingSessionBinding(roster: [], hotkeySecret: Data([1, 2, 3]))
        )
        XCTAssertEqual(bound["hotkey_secret"] as? String, "AQID")

        let signed = try encodedObject(
            VotingKeystoneSignedBundle(bundleIndex: 1, signedPczt: Data([4, 5, 6]))
        )
        XCTAssertEqual(signed["bundle_index"] as? UInt32, 1)
        XCTAssertEqual(signed["signed_pczt"] as? String, "BAUG")
    }

    func testSecretBearingRequestsRedactTheirDescription() {
        let binding = VotingSessionBinding(roster: [], hotkeySecret: Data([1, 2, 3]))
        let signer = VotingDelegationSigner.software(seed: [1, 2, 3])

        XCTAssertEqual("\(binding)", "--redacted--")
        XCTAssertEqual(String(reflecting: binding), "--redacted--")
        XCTAssertEqual("\(signer)", "--redacted--")
        XCTAssertEqual(String(reflecting: signer), "--redacted--")
    }

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try JSONDecoder().decode(type, from: data)
    }

    private func encodedString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try XCTUnwrap(String(data: try encoder.encode(value), encoding: .utf8))
    }

    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static let roundPlanJson = """
    {
      "round_id": "round-1",
      "pending_recovery": false,
      "blocking_recovery": true,
      "blocking_share_work": false,
      "has_unconfirmed_shares": true,
      "hotkey_bound": true,
      "completed_vote_artifact": false,
      "completed_for_display": false,
      "completed_vote_display": {
        "choices": [
          {"proposal_id": 7, "choice": 1},
          {"proposal_id": 8, "choice": null}
        ],
        "voted_at": 1700000000
      },
      "needs_draft_setup": false,
      "needs_bundle_setup": true,
      "needs_delegation_signing": true,
      "has_in_flight_delegation": false,
      "delegation_bundles_needing_work": [0, 1],
      "delegation_bundles_needing_signing": [1],
      "needs_vote_polling": true,
      "has_remaining_vote_or_share_work": true,
      "has_recoverable_vote_or_share_work": true,
      "primary_action": "delegate",
      "next_steps": [],
      "delegation_statuses": [
        {
          "bundle_index": 0,
          "phase": "submitted_delegation",
          "tx_hash": "ff",
          "submission_diagnostic": null,
          "terminal": false
        },
        {
          "bundle_index": 1,
          "phase": "prepared",
          "tx_hash": null,
          "submission_diagnostic": null,
          "terminal": true
        }
      ],
      "recovered_delegation_work": [],
      "recovered_vote_work": [],
      "open_proposals": [7, 8],
      "unrostered_intents": [9],
      "immediate_share_key": null,
      "immediate_share_confirmed": false,
      "all_decided": false
    }
    """
}
