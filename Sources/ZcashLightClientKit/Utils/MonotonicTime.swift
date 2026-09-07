//
//  MonotonicTime.swift
//  ZcashLightClientKit
//

import Foundation

extension DispatchTime {
    /// Seconds elapsed from `earlier` to `self` on the monotonic uptime clock.
    ///
    /// Benchmark timings must not use the wall clock: an NTP step or a manual clock change
    /// mid-measurement would produce a negative or wildly wrong elapsed time, and these values
    /// feed threshold arithmetic, not just ordering. `self` must not precede `earlier`.
    func secondsSince(_ earlier: DispatchTime) -> TimeInterval {
        TimeInterval(uptimeNanoseconds - earlier.uptimeNanoseconds) / 1_000_000_000
    }
}
