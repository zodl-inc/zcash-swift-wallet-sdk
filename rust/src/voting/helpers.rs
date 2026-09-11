use anyhow::anyhow;
use serde::Serialize;
use zcash_keys::keys::UnifiedSpendingKey;
use zcash_voting as voting;
use zip32::AccountId;

use super::constants::MIN_SEED_LEN;
use super::errors::{internal, invalid_input};
use super::ffi_types::FfiVotingHotkey;

// =============================================================================
// Helper functions
// =============================================================================

/// Borrow a byte slice from a raw `(ptr, len)` pair.
///
/// When `len == 0`, returns an empty slice without reading `ptr`, so `ptr` may be null.
///
/// Centralizing the null + length check here lets every voting FFI byte input - strings,
/// JSON payloads, anything else - share one boundary contract instead of open-coding it
/// per call site. `str_from_ptr` delegates to this helper.
///
/// # Safety
///
/// When `len > 0`, `ptr` must be non-null and valid for reads for `len` bytes, and the
/// memory must not be mutated for the duration of the call. The returned slice must not
/// outlive the underlying allocation.
pub(super) unsafe fn bytes_from_ptr<'a>(ptr: *const u8, len: usize) -> anyhow::Result<&'a [u8]> {
    if len == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() {
        return Err(invalid_input("FFI pointer is null but length is non-zero"));
    }
    Ok(unsafe { std::slice::from_raw_parts(ptr, len) })
}

/// Parse a UTF-8 string from a raw pointer and length.
///
/// When `len == 0`, returns the empty string without reading `ptr`, so `ptr` may be null.
///
/// # Safety
///
/// Same contract as `bytes_from_ptr`.
pub(super) unsafe fn str_from_ptr(ptr: *const u8, len: usize) -> anyhow::Result<String> {
    let bytes = unsafe { bytes_from_ptr(ptr, len) }?;
    let text = std::str::from_utf8(bytes)
        .map_err(|e| invalid_input(format!("FFI string is not valid UTF-8: {e}")))?;
    Ok(text.to_string())
}

/// Return JSON-serialized bytes as `*mut ffi::BoxedSlice`.
///
/// A DTO this crate defines that will not serialize is this crate's fault, not
/// the host's, so the failure crosses as `internal` rather than `invalid_input`.
pub(super) fn json_to_boxed_slice<T: Serialize>(
    value: &T,
) -> anyhow::Result<*mut crate::ffi::BoxedSlice> {
    let json =
        serde_json::to_vec(value).map_err(|e| internal(format!("failed to encode JSON: {e}")))?;
    Ok(crate::ffi::BoxedSlice::some(json))
}

/// Derive the account's unified spending key from `seed`.
///
/// The network is resolved through [`crate::parse_network`] rather than from a
/// bare `Network`, so a custom (modified-mainnet or regtest) chain derives
/// through the same consensus parameters as every other `zcashlc_*` entry
/// point.
pub(super) fn usk_from_seed(
    network_id: u32,
    seed: &[u8],
    account: AccountId,
) -> anyhow::Result<UnifiedSpendingKey> {
    if seed.len() < MIN_SEED_LEN {
        return Err(anyhow!(
            "seed must be at least {} bytes, got {}",
            MIN_SEED_LEN,
            seed.len()
        ));
    }

    let network = crate::parse_network(network_id)?;
    let usk = UnifiedSpendingKey::from_seed(&network, seed, account)
        .map_err(|e| anyhow!("failed to derive UnifiedSpendingKey: {}", e))?;

    Ok(usk)
}

/// Map the SDK's numeric network id onto `zcash_voting`'s network selector.
///
/// `zcash_voting` replaced the numeric `network_id` convention with a typed
/// enum, so every call into the crate needs this conversion at the boundary.
///
/// The custom slot ([`crate::NETWORK_ID_REGTEST`]) has no voting identity of
/// its own: a modified-mainnet chain votes with mainnet hotkeys and HRPs, so
/// its voting network follows the registered base network. Deriving it through
/// [`crate::parse_network`] also means an unconfigured custom slot errors here
/// rather than silently passing for Regtest.
pub(super) fn voting_network(network_id: u32) -> anyhow::Result<voting::Network> {
    match network_id {
        crate::NETWORK_ID_TESTNET => Ok(voting::Network::Testnet),
        crate::NETWORK_ID_MAINNET => Ok(voting::Network::Mainnet),
        crate::NETWORK_ID_REGTEST => {
            use zcash_protocol::consensus::{NetworkType, Parameters};
            // `parse_network` reports an unconfigured custom slot as a bare
            // message; re-wrap it so this failure reaches Swift as typed JSON
            // like every other one.
            let params =
                crate::parse_network(network_id).map_err(|e| invalid_input(e.to_string()))?;
            match params.network_type() {
                NetworkType::Main => Ok(voting::Network::Mainnet),
                NetworkType::Test => Ok(voting::Network::Testnet),
                NetworkType::Regtest => Ok(voting::Network::Regtest),
            }
        }
        other => Err(invalid_input(format!(
            "Invalid network type: {}. Expected {}, {}, or {} for Testnet, Mainnet, or a custom network, respectively.",
            other,
            crate::NETWORK_ID_TESTNET,
            crate::NETWORK_ID_MAINNET,
            crate::NETWORK_ID_REGTEST,
        ))),
    }
}

// =============================================================================
// Internal helpers
// =============================================================================

/// Convert a `voting::VotingHotkey` to the FFI representation.
///
/// The caller owns the returned allocation and must release it with
/// `zcashlc_voting_free_hotkey`, which zeroizes the secret.
pub(super) fn voting_hotkey_to_ffi(
    hotkey: voting::VotingHotkey,
) -> anyhow::Result<FfiVotingHotkey> {
    let (secret_ptr, secret_len) = crate::ptr_from_vec(hotkey.stored_secret().to_vec());
    let (addr_ptr, addr_len) = crate::ptr_from_vec(hotkey.raw_orchard_address().to_vec());
    Ok(FfiVotingHotkey {
        stored_secret: secret_ptr,
        stored_secret_len: secret_len,
        raw_orchard_address: addr_ptr,
        raw_orchard_address_len: addr_len,
        address_index: hotkey.address_index(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use zcash_protocol::consensus::{MAIN_NETWORK, TEST_NETWORK};

    #[test]
    fn bytes_from_ptr_zero_len_accepts_null() {
        let bytes = unsafe { bytes_from_ptr(std::ptr::null(), 0) }.expect("empty");
        assert!(bytes.is_empty());
    }

    #[test]
    fn bytes_from_ptr_rejects_null_when_nonzero_len() {
        let err = unsafe { bytes_from_ptr(std::ptr::null(), 3) }.expect_err("null");
        // The boundary contract is that every voting FFI failure is
        // `VotingErrorView` JSON, so Swift never has to parse message text.
        let view: zcash_voting::VotingErrorView =
            serde_json::from_str(&err.to_string()).expect("json error");
        assert_eq!(serde_json::to_value(view.kind).unwrap(), "invalid_input");
        assert!(view.message.contains("null"));
    }

    #[test]
    fn str_from_ptr_zero_len_accepts_null() {
        let s = unsafe { str_from_ptr(std::ptr::null(), 0) }.expect("empty");
        assert!(s.is_empty());
    }

    #[test]
    fn str_from_ptr_rejects_null_when_nonzero_len() {
        let err = unsafe { str_from_ptr(std::ptr::null(), 3) }.expect_err("null");
        let view: zcash_voting::VotingErrorView =
            serde_json::from_str(&err.to_string()).expect("json error");
        assert_eq!(serde_json::to_value(view.kind).unwrap(), "invalid_input");
    }

    /// The custom slot's voting identity follows the registered base network,
    /// so a modified-mainnet chain keeps mainnet hotkeys and HRPs. Asserted
    /// through the store FFI, which is where the process-global custom-network
    /// slot is configured exactly once (see
    /// `store_ffi::tests::db_open_custom_network_derives_voting_network_from_base`);
    /// here only the two standard ids and the rejection are checked, because a
    /// second writer of that global would race it.
    #[test]
    fn voting_network_maps_standard_ids_and_rejects_unknown() {
        assert_eq!(
            voting_network(crate::NETWORK_ID_TESTNET).unwrap(),
            voting::Network::Testnet
        );
        assert_eq!(
            voting_network(crate::NETWORK_ID_MAINNET).unwrap(),
            voting::Network::Mainnet
        );
        let err = voting_network(99).expect_err("unknown network id");
        let view: zcash_voting::VotingErrorView =
            serde_json::from_str(&err.to_string()).expect("json error");
        assert_eq!(serde_json::to_value(view.kind).unwrap(), "invalid_input");
    }

    #[test]
    fn usk_from_seed_uses_sdk_network_ids() {
        let seed = [7u8; 32];
        let account = AccountId::try_from(0).expect("account 0");

        let mainnet_usk = usk_from_seed(1, &seed, account).expect("mainnet usk");
        let expected_mainnet =
            UnifiedSpendingKey::from_seed(&MAIN_NETWORK, &seed, account).expect("mainnet seed");
        assert_eq!(
            mainnet_usk
                .to_unified_full_viewing_key()
                .encode(&MAIN_NETWORK),
            expected_mainnet
                .to_unified_full_viewing_key()
                .encode(&MAIN_NETWORK)
        );

        let testnet_usk = usk_from_seed(0, &seed, account).expect("testnet usk");
        let expected_testnet =
            UnifiedSpendingKey::from_seed(&TEST_NETWORK, &seed, account).expect("testnet seed");
        assert_eq!(
            testnet_usk
                .to_unified_full_viewing_key()
                .encode(&TEST_NETWORK),
            expected_testnet
                .to_unified_full_viewing_key()
                .encode(&TEST_NETWORK)
        );
    }

    #[test]
    fn usk_from_seed_rejects_short_seed() {
        let seed = [7u8; MIN_SEED_LEN - 1];
        let account = AccountId::try_from(0).expect("account 0");

        let err = usk_from_seed(1, &seed, account).expect_err("short seed");

        assert!(
            err.to_string()
                .contains("seed must be at least 32 bytes, got 31")
        );
    }
}
