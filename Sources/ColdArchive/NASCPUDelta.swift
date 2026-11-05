// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// DS923+ runs Linux: these mutually exclusive /proc/stat counters exclude
/// guest duplication and the alternate rawKernel field. IO wait is not CPU work.
struct NASCPUDelta {
    static let fields=[50,51,52,53,54,56,61,64]
    private var previous:([Double],Double)?
    mutating func sample(values:[String:Double],time:Double)->(busy:Double,wait:Double)? {
        let raw=Self.fields.compactMap{values["1.3.6.1.4.1.2021.11.\($0).0"]}
        guard raw.count==Self.fields.count,raw.allSatisfy({$0.isFinite && $0>=0}) else {previous=nil;return nil}
        defer{previous=(raw,time)}
        guard let (old,when)=previous,time-when>=1,time-when<=30 else{return nil}
        let delta=zip(raw,old).map(-)
        // Restart/wrap/inconsistent snapshots need a new baseline, not a spike.
        guard delta.allSatisfy({$0>=0}),delta.reduce(0,+)>0 else{return nil}
        let total=delta.reduce(0,+)
        let busy=delta[0]+delta[1]+delta[2]+delta[5]+delta[6]
        return (100*busy/total,100*delta[4]/total)
    }
}
