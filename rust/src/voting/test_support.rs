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
