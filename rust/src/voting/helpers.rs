use anyhow::anyhow;
use serde::Serialize;
use zcash_client_sqlite::util::SystemClock;
use zcash_keys::keys::UnifiedSpendingKey;
use zcash_voting as voting;
use zip32::AccountId;

use super::constants::MIN_SEED_LEN;
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
        return Err(anyhow!("FFI pointer is null but length is non-zero"));
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
    Ok(std::str::from_utf8(bytes)?.to_string())
}

/// Return JSON-serialized bytes as `*mut ffi::BoxedSlice`.
// Consumed by the session and store FFI, which land in a later change.
#[allow(dead_code)]
pub(super) fn json_to_boxed_slice<T: Serialize>(
    value: &T,
) -> anyhow::Result<*mut crate::ffi::BoxedSlice> {
    let json = serde_json::to_vec(value)?;
    Ok(crate::ffi::BoxedSlice::some(json))
}

/// Open the wallet database.
///
/// The store is parameterized by `NetworkParams` rather than `Network` so that a
/// custom (modified-mainnet or regtest) chain resolves its consensus parameters
/// the same way every other `zcashlc_*` entry point does.
// Consumed by the session and store FFI, which land in a later change.
#[allow(dead_code)]
pub(super) fn open_wallet_db(
    wallet_db_path: &str,
    network_id: u32,
) -> anyhow::Result<
    zcash_client_sqlite::WalletDb<
        rusqlite::Connection,
        crate::NetworkParams,
        SystemClock,
        rand::rngs::OsRng,
    >,
> {
    let network = crate::parse_network(network_id)?;
    zcash_client_sqlite::WalletDb::for_path(wallet_db_path, network, SystemClock, rand::rngs::OsRng)
        .map_err(|e| anyhow!("failed to open wallet DB: {}", e))
}

// Consumed by the session and store FFI, which land in a later change.
#[allow(dead_code)]
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
pub(super) fn voting_network(network_id: u32) -> anyhow::Result<voting::Network> {
    match network_id {
        crate::NETWORK_ID_TESTNET => Ok(voting::Network::Testnet),
        crate::NETWORK_ID_MAINNET => Ok(voting::Network::Mainnet),
        other => Err(anyhow!(
            "Invalid network type: {}. Expected either {} or {} for Testnet or Mainnet, respectively.",
            other,
            crate::NETWORK_ID_TESTNET,
            crate::NETWORK_ID_MAINNET,
        )),
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
        assert!(err.to_string().contains("null"));
    }

    #[test]
    fn str_from_ptr_zero_len_accepts_null() {
        let s = unsafe { str_from_ptr(std::ptr::null(), 0) }.expect("empty");
        assert!(s.is_empty());
    }

    #[test]
    fn str_from_ptr_rejects_null_when_nonzero_len() {
        let err = unsafe { str_from_ptr(std::ptr::null(), 3) }.expect_err("null");
        assert!(err.to_string().contains("null"));
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
