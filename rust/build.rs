extern crate cbindgen;

use std::{env, path::PathBuf};

fn main() {
    // The whole source tree feeds cbindgen (ffi.rs carries the #[repr(C)] types) —
    // watching only lib.rs left the generated header stale after ffi.rs-only edits.
    println!("cargo:rerun-if-changed=rust/src");
    println!("cargo:rerun-if-changed=rust/wrapper.c");
    println!("cargo:rerun-if-changed=rust/wrapper.h");

    let bindings = bindgen::builder()
        .header("rust/wrapper.h")
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
        .allowlist_function("os_log_.*")
        .allowlist_function("os_release")
        .allowlist_function("os_signpost_.*")
        .generate()
        .expect("should be able to generate bindings");

    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("should be able to write bindings");

    cc::Build::new().file("rust/wrapper.c").compile("wrapper");

    let crate_dir = env::var("CARGO_MANIFEST_DIR").unwrap();

    if let Ok(b) = cbindgen::Builder::new()
        .with_crate(crate_dir)
        .with_language(cbindgen::Language::C)
        .rename_item("Account", "FfiAccount")
        .rename_item("Uuid", "FfiUuid")
        .rename_item("Accounts", "FfiAccounts")
        .rename_item("BinaryKey", "FFIBinaryKey")
        .rename_item("EncodedKey", "FFIEncodedKey")
        .rename_item("EncodedKeys", "FFIEncodedKeys")
        .rename_item("SubtreeRoot", "FfiSubtreeRoot")
        .rename_item("SubtreeRoots", "FfiSubtreeRoots")
        .rename_item("Balance", "FfiBalance")
        .rename_item("AccountBalance", "FfiAccountBalance")
        .rename_item("ScanProgress", "FfiScanProgress")
        .rename_item("WalletSummary", "FfiWalletSummary")
        .rename_item("ScanRange", "FfiScanRange")
        .rename_item("ScanRanges", "FfiScanRanges")
        .rename_item("ScanSummary", "FfiScanSummary")
        .rename_item("BlockMeta", "FFIBlockMeta")
        .rename_item("BlocksMeta", "FFIBlocksMeta")
        .rename_item("BoxedSlice", "FfiBoxedSlice")
        .rename_item("TxIds", "FfiTxIds")
        .rename_item("TransactionData", "FfiTransactionData")
        .rename_item("MaxSpendMode", "FfiMaxSpendMode")
        .rename_item("TransactionStatus", "FfiTransactionStatus")
        .rename_item("TransactionDataRequest", "FfiTransactionDataRequest")
        .rename_item("TransactionDataRequests", "FfiTransactionDataRequests")
        .rename_item("Address", "FfiAddress")
        .rename_item("AccountMetadataKey", "FfiAccountMetadataKey")
        .rename_item("SymmetricKeys", "FfiSymmetricKeys")
        .rename_item("HttpRequestHeader", "FfiHttpRequestHeader")
        .rename_item("HttpResponseBytes", "FfiHttpResponseBytes")
        .rename_item("HttpResponseHeader", "FfiHttpResponseHeader")
        .rename_item("SingleUseTaddr", "FfiSingleUseTaddr")
        .rename_item("AddressCheckResult", "FfiAddressCheckResult")
        .rename_item("ZecUsdExchange", "FfiZecUsdExchange")
        .rename_item("Eip681TransactionRequest", "FfiEip681TransactionRequest")
        .rename_item(
            "Eip681TransactionRequestType",
            "FfiEip681TransactionRequestType",
        )
        .rename_item("ErrorReport", "FfiErrorReport")
        .rename_item("Eip681NativeRequest", "FfiEip681NativeRequest")
        .rename_item("Eip681Erc20Request", "FfiEip681Erc20Request")
        .generate()
    {
        b.write_to_file("target/Headers/zcashlc.h");

        // The generated header is the SDK's public C surface. Two regression
        // classes must fail HERE, at the Rust edit, not later as a Swift build
        // error against a rebuilt slice: an item-scope extern block leaking
        // system prototypes into the header (cbindgen re-emits those — see
        // darwin_qos's cbindgen:ignore), and the interactive-proving entry
        // points vanishing.
        let header = std::fs::read_to_string("target/Headers/zcashlc.h")
            .expect("generated zcashlc.h should be readable");
        assert!(
            !header.contains("pthread"),
            "generated zcashlc.h leaks pthread declarations; a cbindgen:ignore suppression regressed"
        );
        for symbol in [
            "zcashlc_proving_interactive_begin",
            "zcashlc_proving_interactive_end",
            "zcashlc_proving_interactive_active",
        ] {
            assert!(
                header.contains(symbol),
                "generated zcashlc.h is missing `{symbol}`"
            );
        }
    }
}
