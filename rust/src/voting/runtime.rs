//! Shared Tokio runtime, process-wide proving-policy configuration, and the
//! process-wide direct HTTP transport for the voting host.
//!
//! `zcash_voting`'s proving pool is fixed once per process behind its own
//! `OnceLock`: the first caller (an explicit [`configure_proving`], or an
//! implicit default the crate applies on first proving/warm-up use) wins,
//! and every later call either repeats that exact policy (success) or
//! reports [`ProvingConfigureOutcome::AlreadyConfigured`] without changing
//! the running pool.

use std::sync::{Arc, OnceLock};

use ffi_helpers::panic::catch_panic;
use zcash_voting::{
    DirectRoute, HyperTransport, ProvingConfigurationError, ProvingPolicy,
    configure_proving_runtime,
};

use crate::unwrap_exc_or;

use super::errors::{internal, invalid_input};
use super::helpers::bytes_from_ptr;

static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
static DIRECT: OnceLock<Arc<HyperTransport<DirectRoute>>> = OnceLock::new();

/// The shared multi-thread Tokio runtime that drives voting session work.
///
/// Built lazily on first use and reused by every session thereafter — one
/// process-wide runtime rather than one per session.
pub(super) fn runtime() -> &'static tokio::runtime::Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("zcash-voting")
            .enable_all()
            .build()
            .expect("voting runtime")
    })
}

/// The process-wide direct HTTP transport for PIR and vote-tree traffic.
///
/// Chain and helper traffic route through the transport selected at session
/// open (Tor or direct); PIR and vote-tree traffic always use this shared
/// direct transport instead, because neither carries anything that identifies
/// the voter to an observer and both are throughput-sensitive enough that
/// routing them over Tor would cost far more than it bought.
pub(super) fn direct_transport() -> Arc<HyperTransport<DirectRoute>> {
    DIRECT
        .get_or_init(|| Arc::new(HyperTransport::new()))
        .clone()
}

/// Outcome of a [`configure_proving`] call.
pub(super) enum ProvingConfigureOutcome {
    /// This call fixed the process-wide proving policy.
    Configured,
    /// The proving policy was already fixed (by this call's own process, an
    /// earlier explicit configuration, or an implicit default).
    AlreadyConfigured,
}

/// Fixes the process-wide proving policy, or reports that one is already fixed.
pub(super) fn configure_proving(policy: ProvingPolicy) -> anyhow::Result<ProvingConfigureOutcome> {
    match configure_proving_runtime(policy) {
        Ok(()) => Ok(ProvingConfigureOutcome::Configured),
        Err(ProvingConfigurationError::AlreadyConfigured) => {
            Ok(ProvingConfigureOutcome::AlreadyConfigured)
        }
        Err(other) => Err(internal(other.to_string())),
    }
}

/// Fixes the process-wide proving policy from a JSON-encoded `ProvingPolicyDto`.
///
/// Returns `0` when this call configured the pool, `1` when it was already
/// configured, `-1` on error (including malformed JSON).
///
/// # Safety
///
/// `policy_json` must be valid for reads of `policy_json_len` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_configure(
    policy_json: *const u8,
    policy_json_len: usize,
) -> i32 {
    let res = catch_panic(|| {
        let bytes = unsafe { bytes_from_ptr(policy_json, policy_json_len) }?;
        let dto: super::wire::ProvingPolicyDto = serde_json::from_slice(bytes)
            .map_err(|e| invalid_input(format!("proving policy JSON: {e}")))?;
        Ok(match configure_proving(dto.into_policy())? {
            ProvingConfigureOutcome::Configured => 0,
            ProvingConfigureOutcome::AlreadyConfigured => 1,
        })
    });
    unwrap_exc_or(res, -1)
}

/// Starts the process-lifetime proving-key cache warm-up and returns at once.
///
/// A no-op on any call after the first in this process.
///
/// # Safety
///
/// Takes no pointers; always safe to call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_warm_proving_caches() -> i32 {
    let res = catch_panic(|| {
        zcash_voting::start_proving_cache_warmup();
        Ok(0)
    });
    unwrap_exc_or(res, -1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_is_multi_thread_and_shared() {
        let a = runtime() as *const _;
        let b = runtime() as *const _;
        assert_eq!(a, b);
        assert_eq!(runtime().block_on(async { 1 + 1 }), 2);
    }

    #[test]
    fn configure_twice_reports_already_configured() {
        let policy = crate::voting::wire::ProvingPolicyDto {
            cpu_worker_count: None,
            max_active_heavy_jobs: Some(1),
        }
        .into_policy();
        let other = crate::voting::wire::ProvingPolicyDto {
            cpu_worker_count: Some(1),
            max_active_heavy_jobs: Some(2),
        }
        .into_policy();
        let first = configure_proving(policy).unwrap();
        // The process-wide pool is created once; the test binary may already have configured
        // it (`configure_proving_runtime` treats identical repeats as success), so `first`'s
        // outcome isn't asserted. `other` always differs from `policy`, so `second` always
        // conflicts with whatever is fixed by the time it runs and reliably reports
        // `AlreadyConfigured`.
        let second = configure_proving(other).unwrap();
        assert!(matches!(second, ProvingConfigureOutcome::AlreadyConfigured));
        let _ = first;
    }

    #[test]
    fn configure_ffi_rejects_invalid_json() {
        let bad = b"{";
        assert_eq!(
            unsafe { zcashlc_voting_configure(bad.as_ptr(), bad.len()) },
            -1
        );
    }
}
