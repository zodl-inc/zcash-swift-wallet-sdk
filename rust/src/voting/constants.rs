/// Minimum seed length accepted by Zcash seed-based key derivation.
pub(super) const MIN_SEED_LEN: usize = 32;

/// Orchard full viewing key byte length at the voting FFI boundary.
///
/// Only the `keys` tests read it: the FFI itself copies the encoded key
/// straight out of the UFVK without naming a length, so this is the shape
/// those tests pin rather than a bound the boundary enforces.
#[cfg(test)]
pub(super) const ORCHARD_FVK_LEN: usize = 96;
