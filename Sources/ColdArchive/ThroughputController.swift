// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Unit-agnostic feedback controller. The caller must supply comparable work
/// rates (never mix bytes/sec and completions/sec), settled windows and demand.
/// Admission changes never cancel work already in flight.
struct ThroughputController {
    struct Observation {
        var rate: Double
        var duration: Double
        var active: Int
        var waiting: Int
        var ceiling: Int
        var reliable = true
        var congested = false
        var critical = false
        var context = "default"
        var explorationPermitted = false
    }
    struct Decision {
        let previous: Int
        let target: Int
        let reason: String
        var changed: Bool { previous != target }
    }
    private(set) var target: Int
    private(set) var baseline: Double?
    private var samples: [Double] = []
    private var trialFrom: Int?
    private var stableWindows = 0
    private var context: String?
    private var coarse = true
    private var unknownWindows = 0
    private var probeLowerNext=false
    private let minimumWindow: Double
    private let reprobeWindows: Int

    init(initial: Int = 1, minimumWindow: Double = 1, reprobeWindows: Int = 5) {
        target = max(1, initial)
        self.minimumWindow = minimumWindow
        self.reprobeWindows = max(1, reprobeWindows)
    }

    mutating func observe(_ o: Observation) -> Decision {
        let old = target
        func decision(_ reason: String) -> Decision { .init(previous: old, target: target, reason: reason) }
        let ceiling = max(1, o.ceiling)
        if target > ceiling {
            target = ceiling
            resetMeasurements()
            return decision("safety_ceiling")
        }
        // Do not stack reductions before normal completion enforces the last one.
        if o.active > target { return decision("draining_existing_work") }
        if o.critical {
            target = max(1, target / 2)
            resetMeasurements()
            return decision("critical_resource_pressure")
        }
        if context == nil {context=o.context}
        else if context != o.context {
            context = o.context
            resetMeasurements()
            return decision("context_changed")
        }
        guard o.waiting > 0, o.active >= target else {
            samples.removeAll()
            return decision("insufficient_demand")
        }
        guard o.reliable, o.duration + min(0.01,minimumWindow*0.01) >= minimumWindow, o.rate.isFinite, o.rate > 0 else {
            samples.removeAll()
            // Long-running opaque parsers may expose no usable byte counters.
            // Explicitly labelled, slow exploration is allowed only with live
            // activity/headroom evidence, never reported as a measured gain.
            if o.duration+min(0.01,minimumWindow*0.01)>=minimumWindow,o.explorationPermitted,!o.congested {
                unknownWindows += 1
                if unknownWindows>=3,target<ceiling {
                    unknownWindows=0;target += 1;baseline=nil;trialFrom=nil
                    return decision("unmeasured_activity_probe")
                }
            } else {unknownWindows=0}
            return decision("insufficient_measurement")
        }
        unknownWindows=0
        samples.append(o.rate)
        guard samples.count >= 3 else { return decision("collecting_windows") }
        let sorted = samples.sorted()
        let rate = sorted[sorted.count / 2]
        // Estimate noise from the actual observations instead of a single sample.
        let deviations = samples.map { abs($0 - rate) }.sorted()
        let noise = max(rate * 0.03, deviations[deviations.count / 2] * 2)
        samples.removeAll()
        if let reference = baseline, let prior = trialFrom {
            trialFrom = nil
            let lowerTrial=target<prior
            if rate > reference + noise || (lowerTrial && rate>=reference-noise) {
                baseline = max(rate,reference)
                stableWindows = 0
                if lowerTrial {
                    if target>1 {
                        trialFrom=target;target -= 1
                        return decision("lower_probe_retained_continue")
                    }
                    probeLowerNext=false
                    stableWindows = -reprobeWindows
                    return decision("lower_probe_retained")
                }
                if !o.congested,target<ceiling {
                    trialFrom=target
                    target=min(ceiling,target+(coarse ? target:1))
                    return decision("probe_gain_and_continue")
                }
                return decision("probe_gain_confirmed")
            }
            // A plateau is not an emergency: return to the less costly setting
            // after repeated settled measurements, then re-probe later.
            target = prior
            baseline = nil
            coarse = false
            probeLowerNext = !lowerTrial && prior>1
            stableWindows = -reprobeWindows
            return decision(lowerTrial ? "lower_probe_regression":(rate < reference - noise ? "probe_regression" : "probe_no_gain"))
        }
        if let reference = baseline, rate < reference - noise, o.congested, target > 1 {
            target = max(1, target - max(1, target / 4))
            resetMeasurements()
            coarse = false
            return decision("sustained_congestion_and_regression")
        }
        baseline = rate
        if stableWindows < 0 {
            stableWindows += 1
            return decision("stable_reprobe_cooldown")
        }
        if probeLowerNext,target>1 {
            probeLowerNext=false;trialFrom=target;target -= 1
            return decision("probe_lower")
        }
        if o.congested { return decision("congestion_without_proven_regression") }
        guard target < ceiling else { return decision("at_safety_ceiling") }
        trialFrom = target
        target = min(ceiling, target + (coarse ? target : 1))
        return decision("probe_higher")
    }

    mutating func resetMeasurements() {
        samples.removeAll()
        baseline = nil
        trialFrom = nil
        stableWindows = 0
        unknownWindows = 0
        probeLowerNext=false
    }
}
