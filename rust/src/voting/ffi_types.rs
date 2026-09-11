use zeroize::Zeroize;

// =============================================================================
// #[repr(C)] structs for simple, frequently-accessed return types
// =============================================================================

/// Voting hotkey returned by `zcashlc_voting_generate_hotkey`.
///
/// Voting hotkeys are app-owned random values rather than wallet-seed
/// derivations. The caller is responsible for persisting `stored_secret`; a
/// hotkey that is not stored cannot be reconstructed, and the voting ability it
/// represents is lost. Everything else in this struct is derived from
/// `stored_secret` and need not be stored.
#[repr(C)]
pub struct FfiVotingHotkey {
    pub(super) stored_secret: *mut u8,
    pub(super) stored_secret_len: usize,
    pub(super) raw_orchard_address: *mut u8,
    pub(super) raw_orchard_address_len: usize,
    pub(super) address_index: u32,
}

// =============================================================================
// Free functions for #[repr(C)] return types
// =============================================================================

/// Free an `FfiVotingHotkey` value.
///
/// # Safety
///
/// - `ptr` must be non-null and must point to a struct returned by the voting FFI.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_free_hotkey(ptr: *mut FfiVotingHotkey) {
    if !ptr.is_null() {
        let s: Box<FfiVotingHotkey> = unsafe { Box::from_raw(ptr) };
        if !s.stored_secret.is_null() {
            zeroize_free_u8(s.stored_secret, s.stored_secret_len);
        }
        if !s.raw_orchard_address.is_null() {
            crate::free_ptr_from_vec(s.raw_orchard_address, s.raw_orchard_address_len);
        }
        drop(s);
    }
}

/// Zeroize and free a `*mut u8` slice.
///
/// # Safety
///
/// - `ptr` must be non-null and must point to a slice of `u8` values.
/// - `len` must be the length of the slice.
/// - The memory referenced by `ptr` must not be mutated for the duration of the call.
fn zeroize_free_u8(ptr: *mut u8, len: usize) {
    let mut s = unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) };
    s.zeroize();
    drop(s);
}
