//! Shared fixtures for the voting unit tests.

use zcash_client_sqlite::WalletDb;
use zcash_client_sqlite::util::SystemClock;
use zcash_client_sqlite::wallet::init::init_wallet_db;

/// An initialized, empty wallet database in a fresh temporary directory.
///
/// Returns the directory guard alongside the database path: the guard removes the
/// directory when it drops, so a caller must hold it for as long as it uses the path.
///
/// The schema is the one a real wallet gets. `init_wallet_db` runs the same migrations
/// [`zcashlc_init_data_database`](crate::zcashlc_init_data_database) applies, because the
/// SDK registers no external migrations of its own today (see
/// [`crate::ext_schema::external_migrations`]); no seed is supplied, which is enough for
/// a wallet with no derived accounts.
pub(crate) fn temp_wallet_db(network_id: u32) -> (tempfile::TempDir, String) {
    let dir = tempfile::tempdir().expect("tempdir");
    let path = dir.path().join("wallet.db").to_string_lossy().into_owned();
    let network = crate::parse_network(network_id).expect("network");
    let mut db = WalletDb::for_path(&path, network, SystemClock, rand::rngs::OsRng).expect("open");
    init_wallet_db(&mut db, None).expect("init");
    (dir, path)
}

/// A 64-character lowercase hex round id carrying `tag` in its first byte.
///
/// The remaining 31 bytes are zero, so the little-endian value is `tag` itself: a
/// canonical Pallas base-field encoding, which is what
/// [`zcash_voting::types::validate_vote_round_id_hex`] requires of every round id.
/// One `tag` per test keeps rounds distinct within a shared store.
pub(crate) fn hex_round_id(tag: u8) -> String {
    let mut bytes = [0u8; 32];
    bytes[0] = tag;
    hex::encode(bytes)
}

/// Round parameters that pass `validate_round_params` without naming a real round.
///
/// The three 32-byte commitments are constant filler: nothing below the store
/// layer reads them, and no test here proves or delegates, so distinct-looking
/// bytes are enough to tell the fields apart in a failure dump.
pub(crate) fn synthetic_round_params(
    tag: u8,
    snapshot_height: u64,
) -> zcash_voting::VotingRoundParams {
    zcash_voting::VotingRoundParams {
        vote_round_id: hex_round_id(tag),
        snapshot_height,
        ea_pk: vec![7u8; 32],
        nc_root: vec![8u8; 32],
        nullifier_imt_root: vec![9u8; 32],
    }
}

/// An empty in-memory voting store already scoped to `wallet_id`.
///
/// Each call opens its own `:memory:` database, so tests running in parallel
/// share no rows even when they use the same wallet id.
pub(crate) fn open_memory_store(
    network_id: u32,
    wallet_id: &str,
) -> crate::voting::store::VotingDatabaseHandle {
    let handle = crate::voting::store::VotingDatabaseHandle::open(":memory:", network_id)
        .expect("open in-memory voting store");
    handle.set_wallet_id(wallet_id).expect("set wallet id");
    handle
}

/// [`open_memory_store`] as the raw handle the store FFI takes.
///
/// The caller owns the allocation and must release it with
/// `zcashlc_voting_db_free`.
pub(crate) fn open_memory_store_ptr(
    network_id: u32,
    wallet_id: &str,
) -> *mut crate::voting::store::VotingDatabaseHandle {
    Box::into_raw(Box::new(open_memory_store(network_id, wallet_id)))
}

/// Read a `BoxedSlice` an FFI entry point returned as a UTF-8 string.
///
/// # Safety
///
/// `ptr` must be a non-null `BoxedSlice` that an FFI call returned and that has
/// not been freed; the caller still owns it and must free it afterwards.
pub(crate) unsafe fn boxed_slice_to_string(ptr: *mut crate::ffi::BoxedSlice) -> String {
    assert!(!ptr.is_null(), "boxed slice is null");
    String::from_utf8(unsafe { (*ptr).as_slice() }.to_vec()).expect("boxed slice is UTF-8")
}

/// Take the last FFI error recorded on this thread, as its `Display` text.
///
/// Every voting FFI failure puts `VotingErrorView` JSON there, so callers
/// deserialize the returned string rather than matching on message text.
/// Panics when the slot is empty, which means the call under test reported
/// failure without recording why.
pub(crate) fn last_error_string() -> String {
    ffi_helpers::error_handling::take_last_error()
        .expect("an error in the last-error slot")
        .to_string()
}
