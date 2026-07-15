//
//  NetworkInterfaceResolver.swift
//
//  Copyright (c) 2023 Daniel Murfin
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import NIOCore
import NIOPosix

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Resolves interface name-or-IP strings to SwiftNIO devices and bind addresses.
///
/// `GCDAsyncUdpSocket` resolved the interface string (a name like `en0`/`lo0`, an IP
/// literal, or the aliases `localhost`/`loopback`) internally. SwiftNIO's
/// `DatagramBootstrap.bind` and `MulticastChannel.joinGroup` take `SocketAddress` /
/// `NIONetworkDevice` instead, so this bridges the public sACNKit interface strings to
/// them. The matching core works on plain `Descriptor` values so it is unit-testable
/// without enumerating real devices.
enum NetworkInterfaceResolver {

    /// A value-type view of a network interface for a single address family.
    struct Descriptor: Equatable {

        /// The interface name (e.g. `en0`, `lo0`).
        let name: String

        /// The interface address for its family.
        let address: SocketAddress

        /// The address family of `address`.
        let family: ComponentSocketIPFamily

        /// The kernel interface index.
        let interfaceIndex: Int

    }

    /// Errors thrown while resolving an interface.
    enum ResolverError: Error {

        /// No interface matched the given name/IP for the requested family.
        case noMatchingInterface(interface: String, family: ComponentSocketIPFamily)

        /// The resolved address string could not form a `SocketAddress`.
        case invalidAddress(String)

    }

    /// The interface strings `GCDAsyncUdpSocket` mapped directly to the loopback address.
    private static let loopbackAliases: Set<String> = ["localhost", "loopback"]

    // MARK: Production entry points

    /// The device matching an interface name-or-IP for a family, from the live device list.
    ///
    /// - Parameters:
    ///    - interface: The interface name, IP literal, or `localhost`/`loopback` alias.
    ///    - family: The address family to resolve within.
    ///
    /// - Returns: The matching `NIONetworkDevice` (used for multicast join and IPv6 egress).
    ///
    /// - Throws: `ResolverError.noMatchingInterface` if nothing matches.
    ///
    static func device(matching interface: String, family: ComponentSocketIPFamily) throws(ResolverError) -> NIONetworkDevice {
        let paired = liveDevices().compactMap { device -> (descriptor: Descriptor, device: NIONetworkDevice)? in
            guard let descriptor = Descriptor(device) else { return nil }
            return (descriptor, device)
        }
        let chosen = try select(interface: interface, family: family, from: paired.map(\.descriptor))
        guard let match = paired.first(where: { $0.descriptor == chosen })?.device else {
            throw ResolverError.noMatchingInterface(interface: interface, family: family)
        }
        return match
    }

    /// The address to bind for a family: the interface's address, or the family wildcard for nil/"".
    ///
    /// - Parameters:
    ///    - interface: The interface name/IP/alias, or `nil`/`""` for all interfaces.
    ///    - family: The address family to bind within.
    ///    - port: The UDP port to bind.
    ///
    /// - Returns: A bindable `SocketAddress`.
    ///
    /// - Throws: `ResolverError` if a named interface cannot be resolved.
    ///
    static func bindAddress(interface: String?, family: ComponentSocketIPFamily, port: UInt16) throws(ResolverError) -> SocketAddress {
        try bindAddress(interface: interface, family: family, port: port, from: liveDevices().compactMap(Descriptor.init))
    }

    // MARK: Testable core

    /// Selects the descriptor matching an interface name-or-IP for a family.
    ///
    /// - Parameters:
    ///    - interface: The interface name, IP literal, or `localhost`/`loopback` alias.
    ///    - family: The address family to match within.
    ///    - descriptors: The candidate interfaces to match against.
    ///
    /// - Returns: The matching descriptor.
    ///
    /// - Throws: `ResolverError.noMatchingInterface` if nothing matches.
    ///
    static func select(
        interface: String, family: ComponentSocketIPFamily, from descriptors: [Descriptor]
    ) throws(ResolverError) -> Descriptor {
        let candidates = descriptors.filter { $0.family == family }
        if loopbackAliases.contains(interface.lowercased()),
            let loopback = candidates.first(where: { $0.address.isLoopback })
        {
            return loopback
        }
        if let match = candidates.first(where: { $0.name == interface || $0.address.ipAddress == interface }) {
            return match
        }
        throw ResolverError.noMatchingInterface(interface: interface, family: family)
    }

    /// The bind address for a family from a fixed descriptor list (wildcard for nil/"").
    ///
    /// - Parameters:
    ///    - interface: The interface name/IP/alias, or `nil`/`""` for all interfaces.
    ///    - family: The address family to bind within.
    ///    - port: The UDP port to bind.
    ///    - descriptors: The candidate interfaces to resolve a named interface against.
    ///
    /// - Returns: A bindable `SocketAddress`.
    ///
    /// - Throws: `ResolverError` if a named interface cannot be resolved.
    ///
    static func bindAddress(
        interface: String?, family: ComponentSocketIPFamily, port: UInt16, from descriptors: [Descriptor]
    ) throws(ResolverError) -> SocketAddress {
        guard let interface, !interface.isEmpty else {
            return wildcard(family: family, port: port)
        }
        let descriptor = try select(interface: interface, family: family, from: descriptors)
        // Substitute the port on the interface's own address rather than reparsing its printable
        // form, so an IPv6 zone id survives (see `SocketAddress.withPort`).
        return descriptor.address.withPort(port)
    }

    /// The all-interfaces wildcard address for a family.
    ///
    /// - Parameters:
    ///    - family: The address family.
    ///    - port: The UDP port to bind.
    ///
    /// - Returns: `0.0.0.0:port` for IPv4 or `[::]:port` for IPv6.
    ///
    static func wildcard(family: ComponentSocketIPFamily, port: UInt16) -> SocketAddress {
        // 0.0.0.0 and :: are always-valid literals, so the throwing initializer cannot fail here.
        switch family {
        case .IPv4:
            return try! SocketAddress(ipAddress: "0.0.0.0", port: Int(port))
        case .IPv6:
            return try! SocketAddress(ipAddress: "::", port: Int(port))
        }
    }

    // MARK: Helpers

    private static func liveDevices() -> [NIONetworkDevice] {
        (try? System.enumerateDevices()) ?? []
    }

}

extension NetworkInterfaceResolver.Descriptor {

    /// Builds a descriptor from a device, or `nil` if it has no family-typed address.
    init?(_ device: NIONetworkDevice) {
        guard let address = device.address, let family = address.componentIPFamily else { return nil }
        self.name = device.name
        self.address = address
        self.family = family
        self.interfaceIndex = device.interfaceIndex
    }

}

extension SocketAddress {

    /// The `ComponentSocketIPFamily` of this address, or `nil` for non-IP addresses.
    var componentIPFamily: ComponentSocketIPFamily? {
        switch self {
        case .v4:
            return .IPv4
        case .v6:
            return .IPv6
        case .unixDomainSocket:
            return nil
        }
    }

    /// Whether this address is an IPv4 or IPv6 loopback address.
    var isLoopback: Bool {
        switch self {
        case .v4:
            return ipAddress?.hasPrefix("127.") ?? false
        case .v6:
            return ipAddress == "::1"
        case .unixDomainSocket:
            return false
        }
    }

    /// This address with its port replaced, preserving every other field.
    ///
    /// Reconstructing an address from its printable `ipAddress` string drops the IPv6 zone id
    /// (`inet_ntop` omits `%scope`), which the kernel rejects when binding a link-local address.
    /// Copying the underlying `sockaddr` keeps `sin6_scope_id` intact.
    ///
    func withPort(_ port: UInt16) -> SocketAddress {
        switch self {
        case .v4(let address):
            var storage = address.address
            storage.sin_port = in_port_t(port).bigEndian
            return SocketAddress(storage, host: address.host)
        case .v6(let address):
            var storage = address.address
            storage.sin6_port = in_port_t(port).bigEndian
            return SocketAddress(storage, host: address.host)
        case .unixDomainSocket:
            return self
        }
    }

}
