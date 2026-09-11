//! Wallet-database opener handed to `zcash_voting` so the crate can read the host wallet.
//!
//! Wallet database handles are not `Send`, so the crate's delegation pipeline opens one
//! per stage on the thread that needs it instead of holding one across stages.
//! [`SdkWalletDbOpener`] is how it opens this SDK's: by path, parameterized by
//! [`crate::NetworkParams`] so a custom-parameter chain resolves its consensus parameters
//! the same way every other `zcashlc_*` entry point does, and with the same connection
//! setup the FFI gives its own wallet handles, lock wait included.
//!
//! The crate's own `SqliteWalletDbOpener` is not usable here: it is parameterized by
//! `zcash_voting::Network`, which has no custom-parameter arm, and it wraps a bare
//! connection without the SQLite array module the wallet's queries bind list parameters
//! through.

use rand::rngs::OsRng;
use zcash_client_sqlite::{WalletDb, util::SystemClock};
use zcash_voting::{VotingError, WalletDbOpener};

/// Opens the host wallet database for the voting crate's pipeline stages.
///
/// Read-only by convention rather than by open flag: the crate only reads through the
/// handle, and a read-only connection cannot create the shared-memory index a WAL
/// database needs when no other connection already holds one open.
#[derive(Clone, Debug)]
pub(super) struct SdkWalletDbOpener {
    path: String,
    network_id: u32,
}

// Consumed by session setup, which lands in a later change.
#[allow(dead_code)]
impl SdkWalletDbOpener {
    /// An opener for the wallet database at `path` on the SDK network `network_id`.
    ///
    /// Neither is resolved here: the path is checked and the network id parsed on every
    /// [`WalletDbOpener::open_for_read`], so an opener outlives any single handle and
    /// picks up a custom network registered after it was built.
    pub(super) fn new(path: impl Into<String>, network_id: u32) -> Self {
        Self {
            path: path.into(),
            network_id,
        }
    }
}

impl WalletDbOpener for SdkWalletDbOpener {
    type Conn = rusqlite::Connection;
    type Params = crate::NetworkParams;
    type Clock = SystemClock;
    type Rng = OsRng;

    fn open_for_read(
        &self,
    ) -> Result<WalletDb<Self::Conn, Self::Params, Self::Clock, Self::Rng>, VotingError> {
        // Load-bearing, not a nicety: SQLite creates the file it is asked to open, so a
        // wrong or not-yet-initialized path would otherwise yield an empty database and
        // fail much later as a missing table.
        if !std::path::Path::new(&self.path).exists() {
            return Err(storage(format!(
                "wallet database not found at {}",
                self.path
            )));
        }

        let network = crate::parse_network(self.network_id).map_err(|e| storage(e.to_string()))?;

        // Mirror `crate::wallet_db` (open + busy_timeout + array vtab + wrap) rather than
        // calling `WalletDb::for_path`, which would leave the connection with SQLite's
        // instant-`SQLITE_BUSY` default. `WalletDb::from_connection` requires the array
        // module to have been loaded on the connection it is given.
        //
        // The wait is the host's own `WALLET_DB_BUSY_TIMEOUT`, not a shorter one of this
        // module's: a pipeline stage reads this file while sync may be writing to it, so it
        // has to tolerate exactly the contention every other wallet handle tolerates. A
        // voting read that gave up sooner would fail a stage on a lock the host itself waits
        // out.
        let conn = rusqlite::Connection::open(&self.path).map_err(|e| {
            storage(format!(
                "failed to open wallet database at {}: {e}",
                self.path
            ))
        })?;
        conn.busy_timeout(crate::WALLET_DB_BUSY_TIMEOUT)
            .map_err(|e| storage(format!("failed to set wallet database busy_timeout: {e}")))?;
        rusqlite::vtab::array::load_module(&conn)
            .map_err(|e| storage(format!("failed to load wallet database array module: {e}")))?;

        Ok(WalletDb::from_connection(conn, network, SystemClock, OsRng)
            .with_anchor_retention_interval(crate::anchor_retention_interval(network)))
    }
}

/// Every way this module can fail is a storage failure as far as the crate is concerned.
fn storage(message: impl Into<String>) -> VotingError {
    VotingError::Storage {
        message: message.into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use zcash_protocol::consensus::{NetworkType, Parameters};

    #[test]
    fn opens_initialized_wallet_database() {
        let (_dir, path) = crate::voting::test_support::temp_wallet_db(crate::NETWORK_ID_TESTNET);
        let opener = SdkWalletDbOpener::new(&path, crate::NETWORK_ID_TESTNET);
        let db = opener.open_for_read().expect("open");
        assert_eq!(db.params().network_type(), NetworkType::Test);
    }

    #[test]
    fn missing_path_is_a_typed_error() {
        let opener =
            SdkWalletDbOpener::new("/nonexistent/dir/wallet.db", crate::NETWORK_ID_TESTNET);
        // `WalletDb` is not `Debug`, so the success arm cannot go through `unwrap_err`.
        let err = match opener.open_for_read() {
            Ok(_) => panic!("a missing wallet database must not open"),
            Err(err) => err,
        };
        assert_eq!(err.kind(), zcash_voting::VotingErrorKind::Storage);
        assert!(err.to_string().contains("/nonexistent/dir/wallet.db"));
    }
}
