// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Only addresses reported by the configured NAS establish an alias match.
/// DNS overlap alone (especially NAT and proxy addresses) is not device identity.
enum NASAddressIdentity {
    static let tableOIDs=["1.3.6.1.2.1.4.20.1.1","1.3.6.1.2.1.4.34.1.3"]
    static func address(oid:String) -> String? {
        let key=oid.trimmingCharacters(in:CharacterSet(charactersIn:"."))
        var bytes:[UInt8]=[]
        var family=AF_INET
        if key.hasPrefix(tableOIDs[0]+".") {
            let parts=key.dropFirst(tableOIDs[0].count+1).split(separator:".")
            guard parts.count==4 else{return nil}
            for p in parts {guard let n=UInt8(p) else{return nil};bytes.append(n)}
        } else if key.hasPrefix(tableOIDs[1]+".") {
            let raw=key.dropFirst(tableOIDs[1].count+1).split(separator:".",omittingEmptySubsequences:false)
            let parts=raw.compactMap{Int($0)}
            guard parts.count==raw.count else{return nil}
            guard parts.count>=2 else{return nil}
            let count=parts[0]==1 ? 4 : parts[0]==2 ? 16:0
            guard count>0,parts[1]==count,parts.count==count+2 else{return nil}
            family=count==4 ? AF_INET:AF_INET6
            for n in parts.dropFirst(2) {guard let b=UInt8(exactly:n) else{return nil};bytes.append(b)}
        } else {return nil}
        var output=[CChar](repeating:0,count:Int(INET6_ADDRSTRLEN))
        guard bytes.withUnsafeBytes({inet_ntop(family,$0.baseAddress,&output,socklen_t(output.count))}) != nil else{return nil}
        let value=String(cString:output)
        guard value != "0.0.0.0", !value.hasPrefix("127."), value != "::",value != "::1",!value.hasPrefix("fe80:") else{return nil}
        return value
    }
    static func resolve(_ host:String) -> Set<String> {
        var hints=addrinfo();hints.ai_family=AF_UNSPEC;hints.ai_socktype=SOCK_STREAM
        var result:UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host,nil,&hints,&result)==0,let first=result else{return []}
        defer{freeaddrinfo(first)}
        var addresses=Set<String>(),cursor:UnsafeMutablePointer<addrinfo>?=first
        while let row=cursor {
            var buffer=[CChar](repeating:0,count:Int(NI_MAXHOST))
            if getnameinfo(row.pointee.ai_addr,row.pointee.ai_addrlen,&buffer,socklen_t(buffer.count),nil,0,NI_NUMERICHOST)==0 {
                addresses.insert(String(cString:buffer))
            }
            cursor=row.pointee.ai_next
        }
        return addresses
    }
    static func match(_ identity:String?,host:String,interfaces:Set<String>,resolve:(String)->Set<String> = resolve) -> String {
        guard let identity,let part=identity.split(separator:"/",maxSplits:1).first else{return "not_smb"}
        let server=String(part).trimmingCharacters(in:CharacterSet(charactersIn:"[]"))
        if matchesNAS(identity,host:host) {return "same_server_name"}
        guard !interfaces.isEmpty else{return "nas_addresses_unavailable"}
        let addresses=resolve(server)
        guard !addresses.isEmpty else{return "smb_resolution_failed"}
        // Every candidate must belong to this NAS, never accept an ambiguous pool.
        return addresses.isSubset(of:interfaces) ? "nas_interface_match":"different_or_unverified_server"
    }
    static func confirmed(_ reason:String)->Bool { ["same_server_name","nas_interface_match"].contains(reason) }
}
