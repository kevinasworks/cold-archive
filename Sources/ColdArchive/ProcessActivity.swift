// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import NativeMonitor

/// Best-effort process-tree samples. Disk counters exclude cached/logical I/O
/// and must never be presented as application or NAS network throughput.
struct ProcessActivity {
    struct Identity: Hashable { let pid: Int32; let start: UInt64 }
    struct Usage {
        let identity: Identity
        let cpu: UInt64
        let read: UInt64
        let write: UInt64
        let footprint: UInt64
    }
    let processes: [Usage]
    let complete: Bool
    static func sample(pid: Int32) -> Self {
        var pending = [pid], seen = Set<Int32>(), rows: [Usage] = []
        var complete = true
        while let next = pending.popLast() {
            guard seen.insert(next).inserted else { continue }
            if seen.count > 256 { complete = false; break }
            var value = CAProcessUsage()
            if ca_process_usage(next, &value) == 0 {
                rows.append(.init(identity: .init(pid: next, start: value.start),
                                  cpu: value.cpu_ns, read: value.read_bytes,
                                  write: value.write_bytes, footprint: value.footprint))
            } else { complete = false }
            var children = [Int32](repeating: 0, count: 256)
            let count = ca_process_children(next, &children, 256)
            if count < 0 || count >= 256 { complete = false }
            if count > 0 { pending.append(contentsOf: children.prefix(min(Int(count),256)).filter { $0 > 0 }) }
        }
        return .init(processes: rows, complete: complete)
    }
}

struct ProcessActivityDelta {
    private var previous: [ProcessActivity.Identity: ProcessActivity.Usage] = [:]
    struct Sample {
        var readBytes: UInt64 = 0
        var writeBytes: UInt64 = 0
        var cpuNanoseconds: UInt64 = 0
        var footprint: UInt64 = 0
        var complete: Bool
    }
    mutating func observe(_ snapshot: ProcessActivity) -> Sample {
        var result = Sample(complete: snapshot.complete)
        var current: [ProcessActivity.Identity: ProcessActivity.Usage] = [:]
        for row in snapshot.processes {
            current[row.identity] = row
            result.footprint += row.footprint
            if let old = previous[row.identity] {
                result.readBytes += row.read >= old.read ? row.read-old.read : 0
                result.writeBytes += row.write >= old.write ? row.write-old.write : 0
                result.cpuNanoseconds += row.cpu >= old.cpu ? row.cpu-old.cpu : 0
            } else {
                // First observation establishes a baseline, not an interval.
                result.complete = false
            }
        }
        if previous.keys.contains(where: { current[$0] == nil }) { result.complete = false }
        previous = current
        return result
    }
}
