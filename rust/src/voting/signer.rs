//! Software delegation signing and the Keystone signature the device sends back.
//!
//! Two ways to reach the same 64-byte RedPallas SpendAuth signature the crate
//! needs for one delegation bundle. A software wallet derives it here from its
//! own seed; a Keystone wallet's device produced it, and [`keystone_signature_input`]
//! is where it is lifted out of the PCZT the device signed.
//!
//! The crate stopped deriving account keys on the caller's behalf in 2.0 and
//! documents the replacement on `delegate::DelegationSigningRequest`: a
//! software wallet uses `account_index`, `network`, `sighash` and `alpha` to
//! derive its account SpendAuth key locally, randomize it, sign `sighash`, and
//! hand back the signature. So the seed never crosses into `zcash_voting`.
//!
//! # Key material
//!
//! [`SeedSpendAuthSigner`] is the only thing in the voting FFI that holds root
//! seed material, and it holds it for one round-driver run: the session builds
//! it when the run starts, hands the crate an `Arc<dyn SpendAuthSigner>` over
//! it, and drops it when the run ends, at which point [`Zeroizing`] wipes the
//! bytes. Nothing is logged, nothing is persisted, and nothing but the 64-byte
//! signature leaves the signer — not the sighash, not the alpha, not the
//! derived keys. It deliberately has no `Debug`: there is no redacted rendering
//! of a seed worth the risk that someone prints one.

use ff::PrimeField;
use pasta_curves::pallas;
use zcash_voting::delegate::{
    DelegationSigningRequest, KeystoneSigningRequest, spend_auth_signature,
};
use zcash_voting::storage::KeystoneSignatureInput;
use zcash_voting::{Network, SpendAuthSigner, VotingError};
use zeroize::Zeroizing;
use zip32::AccountId;

use super::constants::MIN_SEED_LEN;
use super::helpers::{usk_from_seed, voting_network};

/// One run's software signer: the wallet seed, and the chain to derive on.
///
/// `network_id` is the SDK's own numeric network, which is what
/// [`usk_from_seed`] derives through, so a custom-parameter chain resolves its
/// consensus parameters the same way every other `zcashlc_*` entry point does.
/// `network` is the crate's view of the same chain, and every request the crate
/// hands over must name it — see [`sign_delegation_request`].
// Consumed by session setup, which lands in a later change.
#[allow(dead_code)]
pub(super) struct SeedSpendAuthSigner {
    seed: Zeroizing<Vec<u8>>,
    network_id: u32,
    network: Network,
}

// Consumed by session setup, which lands in a later change.
#[allow(dead_code)]
impl SeedSpendAuthSigner {
    /// A signer over `seed`, rejecting anything too short to derive from and
    /// any `network_id` / `network` pair that does not name one chain.
    ///
    /// The seed is wrapped before it is checked, so even a rejected one is
    /// wiped when this returns rather than left in a freed allocation.
    ///
    /// The pair is checked once, here, rather than on every signature: it is
    /// what makes deriving through the SDK's numeric network equivalent to
    /// deriving through the network each request names, and the session builds
    /// both from one value, so a disagreement is a host bug and not something
    /// a request can provoke.
    pub(super) fn new(seed: Vec<u8>, network_id: u32, network: Network) -> anyhow::Result<Self> {
        let seed = Zeroizing::new(seed);
        if seed.len() < MIN_SEED_LEN {
            return Err(anyhow::anyhow!(
                "seed must be at least {} bytes, got {}",
                MIN_SEED_LEN,
                seed.len()
            ));
        }
        let id_network = voting_network(network_id)?;
        if id_network != network {
            return Err(anyhow::anyhow!(
                "network id {} is {:?}, which is not the signer's network {:?}",
                network_id,
                id_network,
                network
            ));
        }
        Ok(Self {
            seed,
            network_id,
            network,
        })
    }
}

impl SpendAuthSigner for SeedSpendAuthSigner {
    fn sign(&self, request: DelegationSigningRequest) -> Result<[u8; 64], VotingError> {
        sign_delegation_request(&self.seed, self.network_id, self.network, request)
    }
}

/// Signs one delegation bundle's PCZT sighash with the account's own Orchard
/// SpendAuth key, randomized by the request's `alpha`.
///
/// Every check here is about refusing to sign something this wallet was not
/// asked to sign:
///
/// - the seed must be the one the request names, by ZIP-32 fingerprint, before
///   any key is derived from it;
/// - the request must be for `expected_network`, the network the session was
///   opened on;
/// - `alpha` must decode as a canonical Pallas scalar, so a signature is never
///   produced under a randomizer the crate could not have chosen.
///
/// Only the resulting signature is returned; the request itself is copied
/// nowhere.
///
/// `network_id` is what the derivation uses and `expected_network` is what the
/// request is matched against, so the caller must pass two that name one chain
/// or the derived key is not the account key the request's `alpha` was drawn
/// against. [`SeedSpendAuthSigner::new`] is where that is checked for the
/// signer path.
// Consumed by session setup, which lands in a later change.
#[allow(dead_code)]
pub(super) fn sign_delegation_request(
    seed: &[u8],
    network_id: u32,
    expected_network: Network,
    request: DelegationSigningRequest,
) -> Result<[u8; 64], VotingError> {
    // Bind the request to this exact wallet seed before deriving any keys.
    // `from_seed` is also the seed-length check: it returns `None` for anything
    // outside ZIP-32's accepted range, short seeds included.
    let seed_fingerprint = zip32::fingerprint::SeedFingerprint::from_seed(seed)
        .ok_or_else(|| invalid_input("seed length is not valid for ZIP-32"))?;
    if seed_fingerprint.to_bytes() != request.seed_fingerprint {
        return Err(invalid_input(
            "wallet seed fingerprint does not match the delegation signing request",
        ));
    }

    if request.network != expected_network {
        return Err(invalid_input(
            "delegation signing request network does not match the open voting session",
        ));
    }

    let account = AccountId::try_from(request.account_index).map_err(|_| {
        invalid_input(format!(
            "account_index must be < 2^31, got {}",
            request.account_index
        ))
    })?;

    // Decode the randomizer before deriving, so a malformed request never
    // produces key material.
    let alpha = Option::<pallas::Scalar>::from(pallas::Scalar::from_repr(request.alpha))
        .ok_or_else(|| invalid_input("delegation alpha is not a canonical Pallas scalar"))?;

    let usk = usk_from_seed(network_id, seed, account)
        .map_err(|e| internal(format!("failed to derive the account spending key: {e}")))?;
    let ask = orchard::keys::SpendAuthorizingKey::from(usk.orchard());

    let signature = ask
        .randomize(&alpha)
        .sign(rand::rngs::OsRng, &request.sighash);
    let bytes: [u8; 64] = (&signature).into();
    Ok(bytes)
}

/// Lifts the SpendAuth signature a Keystone device produced out of the PCZT it
/// signed, as the tuple the sidecar stores for the bundle.
///
/// The sighash and `rk` come from the request the device was given, not from
/// the PCZT it returned: they are what the stored signature is later verified
/// against, so they must be the values this wallet set up the bundle with.
// Consumed by the session FFI's Keystone signature storage, which lands in a later change.
#[allow(dead_code)]
pub(super) fn keystone_signature_input(
    request: &KeystoneSigningRequest,
    signed_pczt: &[u8],
) -> Result<KeystoneSignatureInput, VotingError> {
    let sig = spend_auth_signature(signed_pczt, request.action_index as usize)?;
    Ok(KeystoneSignatureInput {
        bundle_index: request.bundle_index,
        sig: sig.to_vec(),
        sighash: request.pczt_sighash.clone(),
        rk: request.rk.clone(),
    })
}

/// Something about the request, the seed or the pairing of the two is wrong —
/// all of it host-side, none of it the crate's.
fn invalid_input(message: impl Into<String>) -> VotingError {
    VotingError::InvalidInput {
        message: message.into(),
    }
}

/// A derivation that should not have been able to fail did.
fn internal(message: impl Into<String>) -> VotingError {
    VotingError::Internal {
        message: message.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use zcash_voting::Network;
    use zcash_voting::delegate::DelegationSigningRequest;

    fn request_for(seed: &[u8], alpha: [u8; 32]) -> DelegationSigningRequest {
        let fp = zip32::fingerprint::SeedFingerprint::from_seed(seed)
            .unwrap()
            .to_bytes();
        DelegationSigningRequest {
            account_index: 0,
            network: Network::Testnet,
            seed_fingerprint: fp,
            sighash: [7u8; 32],
            alpha,
        }
    }

    /// The only property that matters for the derivation: what comes back is a
    /// signature the crate's own `rk` accepts, so the delegation it guards
    /// verifies on chain.
    #[test]
    fn signature_verifies_under_the_randomized_key() {
        let seed = [1u8; 32];
        let alpha = pasta_curves::pallas::Scalar::from(5u64);
        let request = request_for(&seed, ff::PrimeField::to_repr(&alpha));

        let sig =
            sign_delegation_request(&seed, crate::NETWORK_ID_TESTNET, Network::Testnet, request)
                .unwrap();

        let usk = crate::voting::helpers::usk_from_seed(
            crate::NETWORK_ID_TESTNET,
            &seed,
            zip32::AccountId::ZERO,
        )
        .unwrap();
        let ask = orchard::keys::SpendAuthorizingKey::from(usk.orchard());
        let rk = orchard::primitives::redpallas::VerificationKey::from(&ask.randomize(&alpha));
        let signature = orchard::primitives::redpallas::Signature::<
            orchard::primitives::redpallas::SpendAuth,
        >::from(sig);
        assert!(rk.verify(&request.sighash, &signature).is_ok());
    }

    #[test]
    fn fingerprint_mismatch_is_invalid_input() {
        let request = request_for(&[2u8; 32], [0u8; 32]);

        let err = sign_delegation_request(
            &[1u8; 32],
            crate::NETWORK_ID_TESTNET,
            Network::Testnet,
            request,
        )
        .unwrap_err();

        assert_eq!(err.kind(), zcash_voting::VotingErrorKind::InvalidInput);
        assert!(err.to_string().contains("fingerprint"), "unexpected: {err}");
    }

    #[test]
    fn non_canonical_alpha_is_rejected() {
        let request = request_for(&[1u8; 32], [0xffu8; 32]);

        let err = sign_delegation_request(
            &[1u8; 32],
            crate::NETWORK_ID_TESTNET,
            Network::Testnet,
            request,
        )
        .unwrap_err();

        assert_eq!(err.kind(), zcash_voting::VotingErrorKind::InvalidInput);
        assert!(err.to_string().contains("alpha"), "unexpected: {err}");
    }

    #[test]
    fn network_mismatch_is_rejected() {
        let request = request_for(&[1u8; 32], [0u8; 32]);

        let err = sign_delegation_request(
            &[1u8; 32],
            crate::NETWORK_ID_TESTNET,
            Network::Mainnet,
            request,
        )
        .unwrap_err();

        assert_eq!(err.kind(), zcash_voting::VotingErrorKind::InvalidInput);
        assert!(err.to_string().contains("network"), "unexpected: {err}");
    }

    #[test]
    fn short_seed_is_rejected() {
        let request = request_for(&[1u8; 32], [0u8; 32]);

        let err = sign_delegation_request(
            &[1u8; 16],
            crate::NETWORK_ID_TESTNET,
            Network::Testnet,
            request,
        )
        .unwrap_err();

        assert_eq!(err.kind(), zcash_voting::VotingErrorKind::InvalidInput);
        assert!(err.to_string().contains("ZIP-32"), "unexpected: {err}");
    }

    #[test]
    fn seed_signer_rejects_a_seed_too_short_to_derive_from() {
        // The signer holds seed material and so has no `Debug`, which is what
        // keeps the success arm out of `unwrap_err`.
        let err = match SeedSpendAuthSigner::new(
            vec![1u8; 16],
            crate::NETWORK_ID_TESTNET,
            Network::Testnet,
        ) {
            Ok(_) => panic!("a seed too short to derive from must not build a signer"),
            Err(err) => err,
        };

        assert!(err.to_string().contains("seed must be at least 32 bytes"));
    }

    /// The pair is what makes deriving through the SDK's numeric network
    /// equivalent to deriving through the network the request names, so a pair
    /// that disagrees must not become a signer at all.
    #[test]
    fn seed_signer_rejects_a_network_pair_that_disagrees() {
        let err = match SeedSpendAuthSigner::new(
            vec![1u8; 32],
            crate::NETWORK_ID_MAINNET,
            Network::Testnet,
        ) {
            Ok(_) => panic!("a network id and network that disagree must not build a signer"),
            Err(err) => err,
        };

        assert!(err.to_string().contains("network"), "unexpected: {err}");
    }

    /// The trait impl is the only way the crate reaches the derivation, so it
    /// gets the same end-to-end check the free function does.
    #[test]
    fn seed_signer_signs_through_the_trait() {
        let seed = [1u8; 32];
        let alpha = pasta_curves::pallas::Scalar::from(9u64);
        let request = request_for(&seed, ff::PrimeField::to_repr(&alpha));
        let signer =
            SeedSpendAuthSigner::new(seed.to_vec(), crate::NETWORK_ID_TESTNET, Network::Testnet)
                .unwrap();

        let sig = zcash_voting::SpendAuthSigner::sign(&signer, request).unwrap();

        let usk = crate::voting::helpers::usk_from_seed(
            crate::NETWORK_ID_TESTNET,
            &seed,
            zip32::AccountId::ZERO,
        )
        .unwrap();
        let ask = orchard::keys::SpendAuthorizingKey::from(usk.orchard());
        let rk = orchard::primitives::redpallas::VerificationKey::from(&ask.randomize(&alpha));
        let signature = orchard::primitives::redpallas::Signature::<
            orchard::primitives::redpallas::SpendAuth,
        >::from(sig);
        assert!(rk.verify(&request.sighash, &signature).is_ok());
    }

    #[test]
    fn seed_signer_rejects_a_request_for_another_network() {
        let seed = [1u8; 32];
        let request = request_for(&seed, [0u8; 32]);
        let signer =
            SeedSpendAuthSigner::new(seed.to_vec(), crate::NETWORK_ID_MAINNET, Network::Mainnet)
                .unwrap();

        let err = zcash_voting::SpendAuthSigner::sign(&signer, request).unwrap_err();

        assert_eq!(err.kind(), zcash_voting::VotingErrorKind::InvalidInput);
        assert!(err.to_string().contains("network"), "unexpected: {err}");
    }

    fn keystone_request() -> zcash_voting::delegate::KeystoneSigningRequest {
        zcash_voting::delegate::KeystoneSigningRequest {
            pczt_bytes: vec![1, 2, 3],
            redacted_pczt_bytes: vec![4, 5, 6],
            pczt_sighash: vec![7u8; 32],
            rk: vec![8u8; 32],
            action_index: 0,
            display_memo: "round".to_string(),
            eligible_weight_zatoshi: 10,
            delegated_weight_zatoshi: 10,
            bundle_count: 1,
            bundle_index: 0,
        }
    }

    /// A signature can only be stored against a PCZT the crate can read, so
    /// bytes that are not one must not reach storage as an empty signature.
    #[test]
    fn keystone_signature_input_rejects_bytes_that_are_not_a_pczt() {
        let request = keystone_request();

        let err = keystone_signature_input(&request, b"not a pczt").unwrap_err();

        assert!(err.to_string().contains("PCZT"), "unexpected error: {err}");
    }
}
