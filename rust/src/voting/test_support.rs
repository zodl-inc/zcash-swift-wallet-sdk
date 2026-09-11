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

/// Snapshot height every synthetic session fixture uses.
///
/// Not an arbitrary number: note selection resolves the voting note version
/// from the snapshot height and `zcash_voting` accepts only Ironwood / NU6.3
/// notes, so a height below that activation is refused before the wallet is
/// read at all. This one is above NU6.3 on mainnet (3_428_143) and testnet
/// (4_134_000) alike, so one constant serves both.
pub(crate) const SYNTHETIC_SNAPSHOT_HEIGHT: u64 = 4_200_000;

/// Endpoint every synthetic fixture points its chain, helper, tree and PIR
/// fleets at.
///
/// Port 9 is the discard port: nothing listens, and a connection to loopback
/// there is refused immediately rather than hanging. Session construction
/// dials nothing, so these are never contacted; the value exists so a test
/// that accidentally performs I/O fails fast instead of reaching a real host.
pub(crate) const UNROUTABLE_ENDPOINT: &str = "http://127.0.0.1:9/";

/// A prost-encoded lightwalletd `TreeState` for `height` with empty trees.
///
/// Empty `sapling_tree` / `orchard_tree` / `ironwood_tree` strings decode to
/// empty commitment trees rather than failing, so this is a usable anchor and
/// a usable account birthday without carrying real frontier bytes.
pub(crate) fn synthetic_tree_state(height: u64) -> Vec<u8> {
    use prost::Message as _;

    zcash_client_backend::proto::service::TreeState {
        network: "test".to_string(),
        height,
        hash: "00".repeat(32),
        time: 0,
        sapling_tree: String::new(),
        orchard_tree: String::new(),
        ironwood_tree: String::new(),
    }
    .encode_to_vec()
}

/// [`temp_wallet_db`] plus one UFVK-only account, returning its UUID.
///
/// Two things the voting pipeline needs that an empty wallet cannot give it:
/// an account to select notes for, and a fully scanned height at or above the
/// round snapshot. The account is imported view-only from a UFVK derived off a
/// fixed seed — voting reads through the Orchard viewing key and never spends
/// here — and its birthday is [`SYNTHETIC_SNAPSHOT_HEIGHT`] + 1, which puts the
/// wallet's fully scanned height exactly at the snapshot. The account holds no
/// notes, which is the point: note selection then fails as `NoSpendableNotes`
/// rather than as "no such account".
pub(crate) fn temp_wallet_db_with_account(network_id: u32) -> (tempfile::TempDir, String, String) {
    use prost::Message as _;
    use zcash_client_backend::data_api::{
        Account as _, AccountBirthday, AccountPurpose, WalletRead as _, WalletWrite,
    };

    let (dir, path) = temp_wallet_db(network_id);
    let network = crate::parse_network(network_id).expect("network");
    let mut db = WalletDb::for_path(&path, network, SystemClock, rand::rngs::OsRng).expect("open");

    let usk = crate::voting::helpers::usk_from_seed(network_id, &[7u8; 32], zip32::AccountId::ZERO)
        .expect("unified spending key");
    let ufvk = usk.to_unified_full_viewing_key();

    let treestate = zcash_client_backend::proto::service::TreeState::decode(
        synthetic_tree_state(SYNTHETIC_SNAPSHOT_HEIGHT).as_slice(),
    )
    .expect("tree state");
    let birthday = AccountBirthday::from_treestate(treestate, None).expect("birthday");

    let account = db
        .import_account_ufvk("voting", &ufvk, &birthday, AccountPurpose::ViewOnly, None)
        .expect("import account");
    let account_uuid = account.id().expose_uuid().to_string();

    // `zcash_voting` refuses a wallet whose fully scanned height is below the
    // round snapshot, and it derives that height the way `WalletSummary` does:
    // the fully scanned block when there is one, otherwise the block below the
    // wallet birthday. Asserting it here means a change to the birthday or to
    // the synthetic tree state fails at the fixture, naming itself, instead of
    // surfacing as an unrelated refusal in whichever test runs first.
    //
    // The two expressions below restate that derivation rather than call it —
    // the crate's own is private — so this assertion is coupled to it: if a
    // later `zcash_voting` computes the fully scanned height some other way,
    // this fixture agrees with a rule the crate no longer applies, and the
    // mismatch surfaces in the tests that select notes rather than here.
    let scanned = db
        .block_fully_scanned()
        .expect("fully scanned block")
        .map(|meta| meta.block_height())
        .or_else(|| {
            db.get_wallet_birthday()
                .expect("wallet birthday")
                .map(|birthday| birthday - 1)
        })
        .expect("an imported account gives the wallet a birthday");
    assert_eq!(
        u64::from(u32::from(scanned)),
        SYNTHETIC_SNAPSHOT_HEIGHT,
        "fixture wallet is no longer scanned exactly to the voting snapshot"
    );

    (dir, path, account_uuid)
}

/// Session inputs for `account_uuid` in the wallet at `wallet_db_path`.
///
/// `tag` picks the round id, as everywhere else in these fixtures, so tests
/// sharing a store keep distinct rounds. Every endpoint is
/// [`UNROUTABLE_ENDPOINT`]: opening a session must not reach the network.
pub(super) fn synthetic_session_inputs(
    tag: u8,
    wallet_db_path: &str,
    account_uuid: &str,
) -> crate::voting::wire::SessionInputsDto {
    // Derived from the shared round-params fixture rather than restated, so
    // the filler commitments stay identical across the store and session tests.
    let params = synthetic_round_params(tag, SYNTHETIC_SNAPSHOT_HEIGHT);
    crate::voting::wire::SessionInputsDto {
        account_uuid: account_uuid.to_string(),
        wallet_db_path: wallet_db_path.to_string(),
        round_params: crate::voting::wire::RoundParamsDto {
            vote_round_id: params.vote_round_id,
            snapshot_height: params.snapshot_height,
            ea_pk: params.ea_pk,
            nc_root: params.nc_root,
            nullifier_imt_root: params.nullifier_imt_root,
        },
        round_name: format!("synthetic round {tag}"),
        anchor_tree_state: synthetic_tree_state(SYNTHETIC_SNAPSHOT_HEIGHT),
        chain_endpoints: vec![UNROUTABLE_ENDPOINT.to_string()],
        vote_tree_node_urls: vec![UNROUTABLE_ENDPOINT.to_string()],
        helper_urls: vec![UNROUTABLE_ENDPOINT.to_string()],
        pir_endpoints: vec![UNROUTABLE_ENDPOINT.to_string()],
        // The production layout `zcash_voting` compiles against
        // (`pir_types::COMPILED_PIR_LAYOUT`). Not decorative: `PirFleet::new`
        // validates the layout against YPIR's minima — Tier 1 needs at least
        // 2048 rows (`2^tier0_layers`) and 28_672 item bits
        // (`2^tier1_layers * 768`) — so a made-up shape fails at session open.
        pir_layout: crate::voting::wire::PirLayoutDto {
            pir_depth: 19,
            tier0_layers: 12,
            tier1_layers: 7,
            poly_len: 4096,
        },
        ceremony_start_seconds: Some(1_000),
        vote_end_time_seconds: Some(2_000_000_000),
    }
}

/// A binding whose roster is proposals `1..=roster_len`, three options each.
///
/// `zcash_voting` refuses an empty roster, a repeated proposal id and an
/// option count outside its supported range, so the ids start at 1 and the
/// option count is a plain multi-option ballot.
pub(super) fn synthetic_binding(
    roster_len: usize,
    hotkey_secret: Option<Vec<u8>>,
) -> crate::voting::wire::SessionBindingDto {
    crate::voting::wire::SessionBindingDto {
        roster: (1..=roster_len)
            .map(|proposal_id| crate::voting::wire::RosterEntryDto {
                proposal_id: proposal_id as u32,
                num_options: 3,
            })
            .collect(),
        hotkey_secret,
    }
}
