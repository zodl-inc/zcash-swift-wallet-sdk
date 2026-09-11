//! Voting-hotkey FFI.
//!
//! Voting hotkeys are app-owned random values rather than wallet-seed
//! derivations, so neither entry point touches the sidecar database or the
//! wallet: one draws fresh random material, the other rebuilds the same hotkey
//! from a secret the caller stored. Both survived the move to the
//! `zcash_voting` 4.0 round driver unchanged, because the crate's hotkey API
//! did.

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use zcash_voting as voting;

use crate::unwrap_exc_or_null;

use super::ffi_types::FfiVotingHotkey;
use super::helpers::{bytes_from_ptr, voting_hotkey_to_ffi, voting_network};

/// Generate a new voting hotkey for `network_id`.
///
/// Voting hotkeys are app-owned random values, not wallet-seed derivations, so
/// the caller must persist the returned `stored_secret`. It cannot be recovered
/// from the wallet seed, and losing it forfeits the voting ability delegated to
/// that hotkey. Every other field is derived from the secret and need not be
/// stored.
///
/// Returns a pointer to `FfiVotingHotkey` on success, or null on error.
/// Call `zcashlc_voting_free_hotkey` to free the returned pointer.
///
/// # Safety
///
/// No pointer parameters.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_generate_hotkey(network_id: u32) -> *mut FfiVotingHotkey {
    let res = catch_panic(|| {
        let network = voting_network(network_id)?;
        let hotkey = voting::hotkey::generate_random_voting_hotkey(network)
            .map_err(|e| anyhow!("generate_random_voting_hotkey failed: {}", e))?;

        Ok(Box::into_raw(Box::new(voting_hotkey_to_ffi(hotkey)?)))
    });
    unwrap_exc_or_null(res)
}

/// Derive the voting hotkey a stored secret describes, for `network_id`.
///
/// Returns the same `FfiVotingHotkey` shape as `zcashlc_voting_generate_hotkey`,
/// with the Orchard address and address index derived from `stored_secret`.
/// This lets a caller that persisted only the secret hand the SDK the full
/// semantic hotkey again. Returns null on error. Call
/// `zcashlc_voting_free_hotkey` to free the returned pointer.
///
/// # Safety
///
/// - `stored_secret` must be valid for `stored_secret_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_hotkey_from_stored_secret(
    stored_secret: *const u8,
    stored_secret_len: usize,
    network_id: u32,
) -> *mut FfiVotingHotkey {
    let res = catch_panic(|| {
        let network = voting_network(network_id)?;
        let secret = unsafe { bytes_from_ptr(stored_secret, stored_secret_len) }?;
        let hotkey = voting::VotingHotkey::from_stored_secret(secret, network)
            .map_err(|e| anyhow!("VotingHotkey::from_stored_secret failed: {}", e))?;

        Ok(Box::into_raw(Box::new(voting_hotkey_to_ffi(hotkey)?)))
    });
    unwrap_exc_or_null(res)
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::voting::ffi_types::zcashlc_voting_free_hotkey;

    /// Raw Orchard address byte length `zcash_voting` returns for a hotkey.
    ///
    /// The crate performs this length check itself when reconstructing a
    /// hotkey, so the value survives only as the expectation asserted here.
    const HOTKEY_RAW_ADDRESS_LEN: usize = 43;

    #[test]
    fn generate_hotkey_returns_freeable_ffi_value() {
        let hotkey = unsafe { zcashlc_voting_generate_hotkey(crate::NETWORK_ID_MAINNET) };

        assert!(!hotkey.is_null());
        let hotkey_ref = unsafe { hotkey.as_ref() }.expect("hotkey");
        assert_eq!(
            hotkey_ref.stored_secret_len,
            voting::hotkey::VOTING_HOTKEY_STORED_SECRET_LEN
        );
        assert_eq!(hotkey_ref.raw_orchard_address_len, HOTKEY_RAW_ADDRESS_LEN);
        assert!(!hotkey_ref.stored_secret.is_null());
        assert!(!hotkey_ref.raw_orchard_address.is_null());

        unsafe { zcashlc_voting_free_hotkey(hotkey) };
    }

    #[test]
    fn generate_hotkey_rejects_unknown_network_id() {
        assert!(unsafe { zcashlc_voting_generate_hotkey(99) }.is_null());
    }

    #[test]
    fn generated_hotkeys_are_random_and_reconstructible() {
        let first = unsafe { zcashlc_voting_generate_hotkey(crate::NETWORK_ID_MAINNET) };
        let second = unsafe { zcashlc_voting_generate_hotkey(crate::NETWORK_ID_MAINNET) };
        let first_ref = unsafe { first.as_ref() }.expect("hotkey");
        let second_ref = unsafe { second.as_ref() }.expect("hotkey");

        let first_secret = unsafe {
            std::slice::from_raw_parts(first_ref.stored_secret, first_ref.stored_secret_len)
        };
        let second_secret = unsafe {
            std::slice::from_raw_parts(second_ref.stored_secret, second_ref.stored_secret_len)
        };
        assert_ne!(
            first_secret, second_secret,
            "hotkeys must be independently random"
        );

        // The stored secret is the only material the caller needs to keep: the
        // address must be recoverable from it alone.
        let recovered =
            voting::VotingHotkey::from_stored_secret(first_secret, voting::Network::Mainnet)
                .expect("stored secret round-trips");
        let first_address = unsafe {
            std::slice::from_raw_parts(
                first_ref.raw_orchard_address,
                first_ref.raw_orchard_address_len,
            )
        };
        assert_eq!(recovered.raw_orchard_address(), first_address);

        unsafe {
            zcashlc_voting_free_hotkey(first);
            zcashlc_voting_free_hotkey(second);
        }
    }
}
