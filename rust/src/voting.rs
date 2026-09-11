//! C FFI for coinholder voting.
//!
//! The SDK hosts the `zcash_voting` 4.0 native round driver: it owns the
//! sidecar handle, a per-round session (executor, driver, delegation pipeline,
//! chain and helper clients, PIR fleet, cancellation control), the transport
//! route, the wallet-database opener and the software signer. Orchestration,
//! chain submission, helper delivery, share tracking and recovery planning are
//! the crate's.

pub mod constants;
pub mod errors;
pub mod ffi_types;
pub mod helpers;
pub mod hotkey;
pub mod keys;
pub mod route;
pub mod runtime;
pub mod session;
pub mod session_ffi;
pub mod signer;
pub mod store;
pub mod store_ffi;
#[cfg(test)]
pub(crate) mod test_support;
pub mod wallet_access;
pub mod wire;
