// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct LogicalWriteMeter {
    private var previous:[String:Row]=[:]
    struct Context:Hashable {let domain:String;let stage:String}
    struct Row:Decodable {
        let bytes:UInt64;let calls:UInt64;let seconds:Double
        var domain:String?;var stage:String?;var pid:Int32?;var valid:Bool?
    }
    struct Sample {
        var bytes:UInt64=0;var calls:UInt64=0;var seconds:Double=0;var complete=true
        var producers=Set<Int32>()
        mutating func add(_ value:Self) {
            bytes += value.bytes;calls += value.calls;seconds += value.seconds
            complete = complete && value.complete;producers.formUnion(value.producers)
        }
    }
    mutating func sample(root:URL)->Sample {
        sampleDomains(root:root).values.reduce(Sample()) {value,next in var value=value;value.add(next);return value}
    }
    mutating func sampleDomains(root:URL)->[Context:Sample] {
        let folder=root.appendingPathComponent("observations")
        guard let files=try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil) else {return [:]}
        var result:[Context:Sample]=[:]
        for file in files where !file.lastPathComponent.hasSuffix(".tmp") {
            guard let data=try? Data(contentsOf:file),data.count<4096,
                  let row=try? JSONDecoder().decode(Row.self,from:data),row.seconds.isFinite,row.seconds>=0 else {
                result[Context(domain:"unknown",stage:"unknown"),default:Sample()].complete=false;continue
            }
            let key=Context(domain:row.domain ?? "unknown",stage:row.stage ?? "target_write")
            if row.valid==false {result[key,default:Sample()].complete=false}
            let old=previous[file.lastPathComponent]
            if let old,row.bytes<old.bytes || row.calls<old.calls || row.seconds<old.seconds {result[key,default:Sample()].complete=false}
            else {
                result[key,default:Sample()].bytes += row.bytes-(old?.bytes ?? 0)
                result[key,default:Sample()].calls += row.calls-(old?.calls ?? 0)
                result[key,default:Sample()].seconds += row.seconds-(old?.seconds ?? 0)
                if let pid=row.pid {result[key,default:Sample()].producers.insert(pid)}
            }
            previous[file.lastPathComponent]=row
        }
        return result
    }
}
