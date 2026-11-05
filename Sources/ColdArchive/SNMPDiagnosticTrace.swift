// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// In-process callback, synchronous on the serial SNMP queue. No packet payload,
/// username, key, engine ID or raw endpoint is written to either logging system.
final class SNMPDiagnosticTrace {
    let log:DiagnosticLog
    let base:[String:Any]
    let started=ProcessInfo.processInfo.systemUptime
    private var phase="resolution"
    private var sends=0,receives=0,sendFailures=0,receiveFailures=0,sentBytes=0,receivedBytes=0
    init(log:DiagnosticLog,operation:String,origin:String,stage:String,target:String,oid:String) {
        self.log=log
        base=["operation":operation,"origin":origin,"stage":stage,"target_ref":target,"oid":oid,"query_id":UUID().uuidString]
    }
    static func scope(_ address:String)->String {
        var ipv4=in_addr()
        if inet_pton(AF_INET,address,&ipv4)==1 {
            let a=UInt32(bigEndian:ipv4.s_addr)
            if a>>24==127{return "loopback"}
            if a>>24==10 || a>>20==0xac1 || a>>16==0xc0a8{return "private"}
            if a>>16==0xa9fe{return "link_local"}
            if a>>22==0x191{return "shared"}
            return "other_ipv4" // Not called public: may include reserved/synthetic space.
        }
        var ipv6=in6_addr()
        if inet_pton(AF_INET6,address,&ipv6)==1{return "ipv6"}
        return "invalid"
    }
    func receive(_ event:String,_ value:String,_ number:Int,_ systemError:Int) {
        switch event {
        case "dns_begin":phase="resolution"
        case "transport_begin":phase="transport_open"
        case "session_begin":phase="session_open"
        case "query_begin":phase="query"
        default:break
        }
        var fields:[String:Any]=["event":"snmp_"+event,"network_stage":phase,"native_value":number,"system_error":systemError,"elapsed_ms":(ProcessInfo.processInfo.systemUptime-started)*1000]
        switch event {
        case "dns_address","selected_address","source_address":
            fields["address_ref"]=log.target("address:"+value)
            fields["address_scope"]=Self.scope(value);fields["family"]=number
        case "route_interface":
            fields["interface_ref"]=log.target("interface:"+value)
            fields["interface_name"]=value
            // Do not infer the originating VPN application from utun.
            fields["interface_kind"]=value.hasPrefix("utun") ? "tunnel":value.hasPrefix("en") ? "ethernet_or_wifi":value.hasPrefix("lo") ? "loopback":"other"
        default:fields["code"]=value
        }
        if event=="query_error" || event=="session_error" || event=="transport_error" {fields["library_error"]=number}
        if event=="usm_report" {
            let reports=[1:"unsupported_security_level",2:"not_in_time_window",3:"unknown_user",4:"unknown_engine",5:"wrong_digest",6:"decryption_error"]
            fields["code"]=reports[number] ?? "unknown_report"
        }
        if value=="failed" || event.hasSuffix("error") {fields["outcome"]="failed"}
        if event=="udp_send" || event=="tcp_send" {if number>=0{sends+=1;sentBytes+=number}else{sendFailures+=1}}
        if event=="udp_receive" || event=="tcp_receive" {if number>=0{receives+=1;receivedBytes+=number}else{receiveFailures+=1}}
        log.write(fields.merging(base){_,new in new})
    }
    func finish(success:Bool) {
        // Counts describe observed transport calls, not estimated retries. A
        // successful send is kernel acceptance, never proof of remote delivery.
        let code=success ? "query_completed":sendFailures>0 ? "local_send_failed":receives>0 ? "received_but_query_failed":sends>0 ? "sent_without_observed_receive":"failed_before_observed_send"
        log.write(base.merging(["event":"snmp_transport_summary","network_stage":phase,"outcome":success ? "success":"failed","code":code,"send_count":sends,"receive_count":receives,"send_failures":sendFailures,"receive_failures":receiveFailures,"bytes_sent":sentBytes,"bytes_received":receivedBytes,"elapsed_ms":(ProcessInfo.processInfo.systemUptime-started)*1000]){_,new in new})
    }
}
