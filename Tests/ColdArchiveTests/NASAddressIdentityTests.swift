// Copyright (C) 2026 Kevin Zheng
// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import ColdArchive
final class NASAddressIdentityTests:XCTestCase {
    func testAddressTables() {
        XCTAssertEqual(NASAddressIdentity.address(oid:"1.3.6.1.2.1.4.20.1.1.192.168.120.2"),"192.168.120.2")
        XCTAssertEqual(NASAddressIdentity.address(oid:"1.3.6.1.2.1.4.34.1.3.1.4.192.168.120.2"),"192.168.120.2")
        XCTAssertEqual(NASAddressIdentity.address(oid:"1.3.6.1.2.1.4.34.1.3.2.16.32.1.13.184.0.0.0.0.0.0.0.0.0.0.0.1"),"2001:db8::1")
        for oid in ["1.3.6.1.2.1.4.20.1.1.127.0.0.1","1.3.6.1.2.1.4.20.1.1.999.1.1.1","1.3.6.1.2.1.4.34.1.3.1.4.1.2","1.3.6.1.2.1.4.20.1.1.0.0.0.0"] {XCTAssertNil(NASAddressIdentity.address(oid:oid))}
    }
    func testDomainAndLANAddressMatchNASReportedInterface() {
        let interfaces:Set<String>=["192.168.120.2","192.168.121.2"]
        for source in ["192.168.120.2/share","nas.local/share"] {
            XCTAssertEqual(NASAddressIdentity.match(source,host:"public.example.com",interfaces:interfaces,resolve:{_ in ["192.168.120.2"]}),"nas_interface_match")
        }
        XCTAssertEqual(NASAddressIdentity.match("nas.local/share",host:"public.example.com",interfaces:interfaces,resolve:{_ in ["192.168.121.2"]}),"nas_interface_match")
    }
    func testNoGuessingFromNATProxyOrAmbiguousDNS() {
        for addresses:Set<String> in [["28.0.0.74"],["192.168.120.3"],["192.168.120.2","192.168.120.3"]] {
            XCTAssertFalse(NASAddressIdentity.confirmed(NASAddressIdentity.match("other/share",host:"nas",interfaces:["192.168.120.2"],resolve:{_ in addresses})))
        }
        XCTAssertEqual(NASAddressIdentity.match("other/share",host:"nas",interfaces:[],resolve:{_ in XCTFail("No evidence: must not resolve");return []}),"nas_addresses_unavailable")
        XCTAssertEqual(NASAddressIdentity.match("other/share",host:"nas",interfaces:["192.168.120.2"],resolve:{_ in []}),"smb_resolution_failed")
        XCTAssertEqual(NASAddressIdentity.match(nil,host:"nas",interfaces:[]),"not_smb")
        XCTAssertEqual(NASAddressIdentity.match("nas/share",host:"NAS.",interfaces:[]),"same_server_name")
    }
}
