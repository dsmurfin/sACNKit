import Foundation
import NIOCore
import Testing

@testable import sACNKit

/// Exercises `NetworkInterfaceResolver`'s matching core against fixed descriptor
/// lists (no device enumeration, no sockets), so it runs on every platform in the
/// required CI jobs.
@Suite("Network interface resolver")
struct NetworkInterfaceResolverTests {

    private typealias Resolver = NetworkInterfaceResolver
    private typealias Descriptor = NetworkInterfaceResolver.Descriptor

    private func descriptor(_ name: String, _ ip: String, _ family: ComponentSocketIPFamily, index: Int = 1) throws -> Descriptor {
        Descriptor(name: name, address: try SocketAddress(ipAddress: ip, port: 0), family: family, interfaceIndex: index)
    }

    @Test("Resolves an interface by name for the requested family")
    func matchByName() throws {
        let devices = [try descriptor("en0", "192.168.1.10", .IPv4), try descriptor("en0", "fe80::1", .IPv6, index: 2)]
        let chosen = try Resolver.select(interface: "en0", family: .IPv4, from: devices)
        #expect(chosen.address.ipAddress == "192.168.1.10")
        #expect(chosen.family == .IPv4)
    }

    @Test("Resolves an interface by IP literal")
    func matchByIP() throws {
        let devices = [try descriptor("en0", "192.168.1.10", .IPv4)]
        let chosen = try Resolver.select(interface: "192.168.1.10", family: .IPv4, from: devices)
        #expect(chosen.name == "en0")
    }

    @Test("Resolves the localhost and loopback aliases to the loopback device")
    func matchAliases() throws {
        let devices = [
            try descriptor("lo0", "127.0.0.1", .IPv4),
            try descriptor("lo0", "::1", .IPv6, index: 1),
            try descriptor("en0", "10.0.0.1", .IPv4, index: 2),
        ]
        #expect(try Resolver.select(interface: "localhost", family: .IPv4, from: devices).address.ipAddress == "127.0.0.1")
        #expect(try Resolver.select(interface: "loopback", family: .IPv6, from: devices).address.ipAddress == "::1")
    }

    @Test("Filters by address family")
    func familyFilter() throws {
        let devices = [try descriptor("en0", "192.168.1.10", .IPv4), try descriptor("en0", "fe80::1", .IPv6, index: 2)]
        #expect(try Resolver.select(interface: "en0", family: .IPv6, from: devices).family == .IPv6)
    }

    @Test("Throws for an unknown interface")
    func unknownThrows() {
        #expect(throws: Resolver.ResolverError.self) {
            try Resolver.select(interface: "sacnkit-no-such-interface", family: .IPv4, from: [])
        }
    }

    @Test("Throws when the name exists only in the other family")
    func wrongFamilyThrows() throws {
        let devices = [try descriptor("en0", "192.168.1.10", .IPv4)]
        #expect(throws: Resolver.ResolverError.self) {
            try Resolver.select(interface: "en0", family: .IPv6, from: devices)
        }
    }

    @Test("nil and empty interface resolve to the family wildcard")
    func wildcardForNilAndEmpty() throws {
        let v4 = try Resolver.bindAddress(interface: nil, family: .IPv4, port: 5568, from: [])
        #expect(v4.ipAddress == "0.0.0.0")
        #expect(v4.port == 5568)
        let v6 = try Resolver.bindAddress(interface: "", family: .IPv6, port: 5568, from: [])
        #expect(v6.ipAddress == "::")
        #expect(v6.port == 5568)
    }

    @Test("A specific interface binds to that interface's address")
    func bindToInterfaceAddress() throws {
        let devices = [try descriptor("en0", "192.168.1.10", .IPv4)]
        let address = try Resolver.bindAddress(interface: "en0", family: .IPv4, port: 5568, from: devices)
        #expect(address.ipAddress == "192.168.1.10")
        #expect(address.port == 5568)
    }

}
