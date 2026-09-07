//
//  SlipstreamEngineControlling.swift
//  ZcashLightClientKit
//
//  Created for Slipstream task [MOB-1850].
//

import Foundation

/// The engine surface `SlipstreamSynchronizer` drives.
///
/// `SlipstreamEngine` is the production conformer; tests inject a gated fake so lifecycle
/// interleavings — a stop that lands mid-restart, a reopen that fails, a start racing a wipe — can
/// be reproduced deterministically without an FFI handle, a wallet database or a server. Those
/// interleavings are the ones that have gone wrong in the field, and none of them can be provoked
/// on the real engine, whose timing belongs to Rust and to the network.
///
/// The protocol carries EXACTLY the members the synchronizer calls, with the concrete engine's
/// signatures verbatim, so the seam is a substitution rather than an adaptation. Two consequences
/// follow from that fidelity and are deliberate:
///
/// - `Actor` inheritance, so the synchronizer can hold `any SlipstreamEngineControlling` and await
///   its members exactly as it awaited the concrete actor's. The real engine serialises every C FFI
///   call on its own executor, and that serialisation is part of the contract (`walletSummary` runs
///   on the engine's actor precisely so it cannot race `close()`), so it is a requirement here too.
/// - No default arguments. A protocol requirement cannot carry them, so `walletSummary` and
///   `drainEvents` are called with their values spelled out at the synchronizer's call sites; the
///   concrete engine keeps its defaults for its other callers.
///
/// `reopen` and `snapshot` are declared `async` although `SlipstreamEngine`'s are not. A synchronous
/// method is a valid witness for an `async` requirement, so the engine is untouched and every call
/// site already spelled `await` (the members are actor-isolated), but a FAKE may now suspend inside
/// them — which is the whole point of the seam, since a restart's reopen and the poll loop's
/// snapshot are two of the moments a deliberate stop has to be able to land in. The rest keep the
/// concrete engine's signatures verbatim.
///
/// `SlipstreamEngine.restoreAnchor` stays outside: it is `static` and handle-less by design (it
/// runs before `open()`), so it is not part of the instance surface a fake would stand in for.
protocol SlipstreamEngineControlling: Actor {
    func open(network: ZcashNetwork) throws
    func setAlternates(_ endpoints: [LightWalletEndpoint])
    func start(ufvk: String?, birthday: BlockHeight, torDir: String?) async throws
    func stop() async -> Bool
    func notifyTxChange()
    func close()
    func reopen(server newServer: LightWalletEndpoint, network: ZcashNetwork) async throws
    func walletSummary(confirmationsPolicy: ConfirmationsPolicy) -> WalletSummary?
    func snapshot() async -> SlipstreamSnapshot?
    func drainEvents(capacity: Int) -> [SlipstreamEngineEvent]
}

extension SlipstreamEngine: SlipstreamEngineControlling {}
