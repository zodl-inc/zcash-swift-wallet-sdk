/// Minimum seed length accepted by Zcash seed-based key derivation.
pub(super) const MIN_SEED_LEN: usize = 32;

/// Length of a Pallas seed fingerprint in bytes.
// Consumed by the session and store FFI, which land in a later change.
#[allow(dead_code)]
pub(super) const SEED_FINGERPRINT_LEN: usize = 32;

/// Orchard full viewing key byte length at the voting FFI boundary.
// Asserted by the `keys` tests today; consumed by the session FFI in a later change.
#[allow(dead_code)]
pub(super) const ORCHARD_FVK_LEN: usize = 96;

/// Byte length of Keystone / RedPallas signatures at the voting FFI boundary.
// Consumed by the session and store FFI, which land in a later change.
#[allow(dead_code)]
pub(super) const KEYSTONE_SIGNATURE_LEN: usize = 64;

/// Byte length of ZIP-244 PCZT sighashes at the voting FFI boundary.
// Consumed by the session and store FFI, which land in a later change.
#[allow(dead_code)]
pub(super) const PCZT_SIGHASH_LEN: usize = 32;

/// Byte length of randomized verification keys at the voting FFI boundary.
// Consumed by the session and store FFI, which land in a later change.
#[allow(dead_code)]
pub(super) const RANDOMIZED_KEY_LEN: usize = 32;
