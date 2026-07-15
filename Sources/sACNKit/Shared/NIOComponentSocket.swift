//
//  NIOComponentSocket.swift
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

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOFoundationCompat
import NIOPosix

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// NIO Component Socket
///
/// A `ComponentSocket` backed by SwiftNIO. A single facade owns up to two datagram channels (one
/// per address family, following `ipMode`), bound and delivered on **one** shared event loop so
/// cross-family callback ordering matches the total order `GCDAsyncUdpSocket` got from its shared
/// socket queue.
///
/// Concurrency: `NIOComponentSocket` is `@unchecked Sendable`. All mutable state lives behind a
/// single `NIOLockedValueBox`, and every delegate callback is delivered on the caller-supplied
/// `delegateQueue` (the owner's `socketDelegateQueue`, which doubles as its state mutex) - matching
/// where `GCDAsyncUdpSocket` delivered. See docs/modernization/phase-3.md and
/// `.claude/rules/threading.md` for the event-loop tier of the lock hierarchy.
///
final class NIOComponentSocket: ComponentSocket, @unchecked Sendable {

    /// A unique identifier for this socket.
    let id = UUID()

    /// The type of socket.
    private let socketType: ComponentSocketType

    /// The Internet Protocol version(s) used by this socket.
    private let ipMode: sACNIPMode

    /// The UDP port on which to bind this socket.
    private let port: UInt16

    /// The queue on which delegate callbacks are delivered (the owner's state mutex).
    private let delegateQueue: DispatchQueue

    /// The single event loop on which this facade's channels are bound and read.
    private let eventLoop: EventLoop

    /// The mutable state guarded by `NIOLockedValueBox`.
    private struct State {

        /// The delegate to receive notifications (held weakly to avoid a retain cycle).
        weak var delegate: ComponentSocketDelegate?

        /// The interface on which this socket is bound (a name or IP), or `nil` for all interfaces.
        var interface: String?

        /// The open channels, keyed by address family.
        var channels: [ComponentSocketIPFamily: Channel] = [:]

        /// Whether a close callback has already been delivered for the current listen cycle.
        var closeReported = false

        /// The first error seen during the current listen cycle.
        var firstError: Error?

    }

    /// The lock-guarded mutable state.
    private let state = NIOLockedValueBox(State())

    /// A unique identifier for this socket.
    ///
    /// Component sockets are used for joining multicast groups, and sending and receiving network data.
    ///
    /// - Parameters:
    ///    - type: The type of socket (transmit, receive).
    ///    - ipMode: IP mode for this socket (IPv4/IPv6/Both).
    ///    - port: Optional: UDP port to bind.
    ///    - delegateQueue: The dispatch queue on which to receive delegate calls from this component.
    ///
    init(type: ComponentSocketType, ipMode: sACNIPMode, port: UInt16 = 0, delegateQueue: DispatchQueue) {
        self.socketType = type
        self.ipMode = ipMode
        self.port = port
        self.delegateQueue = delegateQueue
        self.eventLoop = MultiThreadedEventLoopGroup.singleton.next()
    }

    deinit {
        // Owners rely on close-on-dealloc: drop and close any open channels. Cannot block here,
        // so this is fire-and-forget.
        let channels = state.withLockedValue { state -> [Channel] in
            let channels = Array(state.channels.values)
            state.channels = [:]
            return channels
        }
        for channel in channels {
            channel.close(promise: nil)
        }
    }

    /// The interface on which this socket is bound, or `nil` for all interfaces.
    var interface: String? {
        state.withLockedValue { $0.interface }
    }

    /// The delegate to receive notifications (stored weakly).
    var delegate: ComponentSocketDelegate? {
        get { state.withLockedValue { $0.delegate } }
        set { state.withLockedValue { $0.delegate = newValue } }
    }

    /// Allows other services to reuse the port.
    ///
    /// No-op: `SO_REUSEPORT` is applied to receive channels at bind time, keyed off `socketType`
    /// (see `makeBootstrap`). Retained to satisfy the `ComponentSocket` protocol.
    ///
    func enableReusePort() throws {}

    /// Attempts to join a multicast group.
    ///
    /// - Parameters:
    ///    - multicastGroup: The multicast group hostname.
    ///
    /// - Throws: An error of type `sACNComponentSocketError`.
    ///
    func join(multicastGroup: String) throws {
        guard socketType == .receive else { return }
        let family: ComponentSocketIPFamily = multicastGroup.contains(":") ? .IPv6 : .IPv4
        guard let channel = channel(for: family) as? MulticastChannel else { return }
        do {
            let group = try SocketAddress(ipAddress: multicastGroup, port: Int(port))
            let device = try joinDevice(family: family)
            try channel.joinGroup(group, device: device).wait()
        } catch {
            throw sACNComponentSocketError.couldNotJoin(multicastGroup: multicastGroup)
        }
    }

    /// Attempts to leave a multicast group.
    ///
    /// - Parameters:
    ///    - multicastGroup: The multicast group hostname.
    ///
    /// - Throws: An error of type `sACNComponentSocketError`.
    ///
    func leave(multicastGroup: String) throws {
        guard socketType == .receive else { return }
        let family: ComponentSocketIPFamily = multicastGroup.contains(":") ? .IPv6 : .IPv4
        guard let channel = channel(for: family) as? MulticastChannel else { return }
        do {
            let group = try SocketAddress(ipAddress: multicastGroup, port: Int(port))
            let device = try joinDevice(family: family)
            try channel.leaveGroup(group, device: device).wait()
        } catch {
            throw sACNComponentSocketError.couldNotLeave(multicastGroup: multicastGroup)
        }
    }

    /// Starts listening for network data, binding fresh channels for the enabled families.
    ///
    /// Channels are recreated on every call, so a facade may be stopped and restarted (owners reuse
    /// their sockets across `stop()`/`start()`). Each listen cycle resets the close latch.
    ///
    /// - Parameters:
    ///    - interface: An optional interface on which to bind (a name like "en1"/"lo0", an IP, or
    ///      the aliases "localhost"/"loopback").
    ///
    /// - Throws: An error of type `sACNComponentSocketError`.
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interface must not be nil.
    ///
    func startListening(onInterface interface: String?) throws {
        precondition(!ipMode.usesIPv6() || interface != nil, "An interface must be provided for IPv6.")

        state.withLockedValue { state in
            state.interface = interface
            state.closeReported = false
            state.firstError = nil
        }

        var opened: [ComponentSocketIPFamily: Channel] = [:]
        do {
            if ipMode.usesIPv4() {
                opened[.IPv4] = try bindChannel(family: .IPv4, interface: interface)
            }
            if ipMode.usesIPv6() {
                opened[.IPv6] = try bindChannel(family: .IPv6, interface: interface)
            }
        } catch {
            for channel in opened.values {
                try? channel.close().wait()
            }
            throw error
        }

        state.withLockedValue { $0.channels = opened }
    }

    /// Stops listening for network data, synchronously closing this socket's channels.
    func stopListening() {
        let channels = state.withLockedValue { state -> [Channel] in
            let channels = Array(state.channels.values)
            state.channels = [:]
            // An intentional stop is a clean close: suppress any late error callback for this cycle.
            state.closeReported = true
            return channels
        }
        for channel in channels {
            try? channel.close().wait()
        }
    }

    /// Sends a message to a specific host and port.
    ///
    /// - Parameters:
    ///    - data: The data to be sent.
    ///    - host: The destination hostname for this message.
    ///    - port: The destination port for this message.
    ///
    func send(message data: Data, host: String, port: UInt16) {
        let family: ComponentSocketIPFamily = host.contains(":") ? .IPv6 : .IPv4
        guard let channel = channel(for: family) else { return }
        let address: SocketAddress
        do {
            address = try SocketAddress(ipAddress: host, port: Int(port))
        } catch {
            return
        }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let envelope = AddressedEnvelope(remoteAddress: address, data: buffer)
        // Report only failures. A per-success hop onto the delegate queue would add per-datagram
        // churn on the state/delivery queue at frame rate for output no one observes; successful
        // sends were debug-only noise. Failures still reach the debug delegate, as they did before.
        channel.writeAndFlush(envelope).whenFailure { [weak self] error in
            self?.reportSendFailure(error)
        }
    }

    // MARK: - Binding

    /// Builds a `DatagramBootstrap` for a family, applying the socket options for this socket type.
    private func makeBootstrap(family: ComponentSocketIPFamily) -> DatagramBootstrap {
        var bootstrap = DatagramBootstrap(group: eventLoop)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelOption(ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 2048))
            .channelInitializer { [weak self] channel in
                guard let self else { return channel.eventLoop.makeSucceededVoidFuture() }
                return channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(DatagramHandler(family: family, owner: self))
                }
            }
        if family == .IPv6 {
            // Keep the families strictly separate. Without IPV6_V6ONLY a wildcard [::] bind is
            // dual-stack on Linux (net.ipv6.bindv6only defaults to 0), so an IPv4 sender would be
            // delivered on the v6 channel as a v4-mapped ::ffff:a.b.c.d - breaking the per-family
            // reporting the two-channel design exists to guarantee. macOS defaults this on already.
            bootstrap = bootstrap.channelOption(
                ChannelOptions.Types.SocketOption(level: .ipv6, name: .ipv6_v6only), value: 1)
        }
        if socketType == .receive {
            // SO_REUSEPORT (necessary and sufficient for duplicate wildcard binds of 5568 on Darwin);
            // no named NIOBSDSocket.Option case, so use the raw value.
            bootstrap = bootstrap.channelOption(
                ChannelOptions.socketOption(NIOBSDSocket.Option(rawValue: SO_REUSEPORT)), value: 1)
        }
        return bootstrap
    }

    /// Binds a channel for a family and, for IPv6 transmit sockets, sets the multicast egress interface.
    private func bindChannel(family: ComponentSocketIPFamily, interface: String?) throws -> Channel {
        let channel: Channel
        do {
            let address: SocketAddress
            switch socketType {
            case .transmit:
                // Transmit binds to the interface's address (as GCDAsyncUdpSocket did).
                address = try NetworkInterfaceResolver.bindAddress(interface: interface, family: family, port: port)
            case .receive:
                // Receive binds the wildcard on all addresses; interface selection happens at join.
                address = NetworkInterfaceResolver.wildcard(family: family, port: port)
            }
            channel = try makeBootstrap(family: family).bind(to: address).wait()
        } catch {
            throw sACNComponentSocketError.couldNotBind(message: "\(id): Could not bind \(socketType.rawValue) socket.")
        }

        if socketType == .transmit, family == .IPv6, let interface {
            do {
                let device = try NetworkInterfaceResolver.device(matching: interface, family: .IPv6)
                // IPV6_MULTICAST_IF is an IPPROTO_IPV6-level option; the default socketOption level
                // is SOL_SOCKET, so name the level explicitly.
                try channel.setOption(
                    ChannelOptions.Types.SocketOption(level: .ipv6, name: .ipv6_multicast_if),
                    value: CInt(device.interfaceIndex)
                ).wait()
            } catch {
                try? channel.close().wait()
                throw sACNComponentSocketError.couldNotAssignMulticastInterface(
                    message: "\(id): Could not assign interface for sending multicast on \(socketType.rawValue) socket.")
            }
        }

        return channel
    }

    // MARK: - Delivery

    /// Delivers a received datagram on the delegate queue.
    fileprivate func deliverReceived(data: Data, host: String, port: UInt16, family: ComponentSocketIPFamily) {
        delegateQueue.async { [self] in
            guard let delegate = state.withLockedValue({ $0.delegate }) else { return }
            delegate.debugLog(for: self, with: "Socket received data of length \(data.count), from \(family.rawValue) \(host):\(port)")
            delegate.receivedMessage(for: self, withData: data, sourceHostname: host, sourcePort: port, ipFamily: family)
        }
    }

    /// Handles a channel error: closes the whole facade and reports it once per listen cycle.
    ///
    /// Mirrors `GCDAsyncUdpSocket`, which tears down the entire socket on a fatal send/recv error.
    /// Transient errors (would-block / interrupted) are ignored.
    ///
    fileprivate func handleError(_ error: Error) {
        guard Self.isFatal(error) else { return }
        let (channels, shouldReport) = state.withLockedValue { state -> ([Channel], Bool) in
            let shouldReport = !state.closeReported
            state.closeReported = true
            if state.firstError == nil { state.firstError = error }
            let channels = state.channels
            state.channels = [:]
            return (Array(channels.values), shouldReport)
        }
        for channel in channels {
            channel.close(promise: nil)
        }
        guard shouldReport else { return }
        delegateQueue.async { [self] in
            guard let delegate = state.withLockedValue({ $0.delegate }) else { return }
            delegate.socket(self, socketDidCloseWithError: error)
        }
    }

    /// Delivers a send failure to the debug delegate on the delegate queue.
    private func reportSendFailure(_ error: Error) {
        delegateQueue.async { [self] in
            guard let delegate = state.withLockedValue({ $0.delegate }) else { return }
            delegate.debugLog(for: self, with: "\(socketTypeString) socket did not send data due to error \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    /// The open channel for a family, if any.
    private func channel(for family: ComponentSocketIPFamily) -> Channel? {
        state.withLockedValue { $0.channels[family] }
    }

    /// The device to pass to multicast join/leave for a family (nil = kernel default / all interfaces).
    private func joinDevice(family: ComponentSocketIPFamily) throws -> NIONetworkDevice? {
        guard let interface = state.withLockedValue({ $0.interface }), !interface.isEmpty else {
            return nil
        }
        return try NetworkInterfaceResolver.device(matching: interface, family: family)
    }

    /// A capitalized string representing the type of this socket.
    private var socketTypeString: String {
        socketType.rawValue.capitalized
    }

    /// Whether an error should tear the socket down (fatal), versus a transient or per-destination
    /// error the socket survives.
    ///
    /// `GCDAsyncUdpSocket` reported send/ICMP failures via a debug callback and kept the socket open;
    /// only genuine socket death closed it. So a single unreachable destination (delivered on Linux as
    /// an asynchronous ICMP error on unconnected UDP) must not tear down a socket serving every
    /// universe. Send failures are already surfaced through the write path.
    ///
    private static func isFatal(_ error: Error) -> Bool {
        guard let ioError = error as? IOError else { return true }
        let nonFatal: Set<CInt> = [
            EAGAIN, EWOULDBLOCK, EINTR,
            ECONNREFUSED, EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN, ECONNRESET, EMSGSIZE,
        ]
        return !nonFatal.contains(ioError.errnoCode)
    }

}

// MARK: -
// MARK: -

/// The inbound handler for a single datagram channel, hopping received datagrams and errors up to
/// its owning `NIOComponentSocket`. Runs only on its channel's event loop.
private final class DatagramHandler: ChannelInboundHandler {

    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    /// The address family of this channel (reported with each datagram).
    private let family: ComponentSocketIPFamily

    /// The owning facade (weak to avoid a channel -> handler -> facade retain cycle).
    private weak var owner: NIOComponentSocket?

    init(family: ComponentSocketIPFamily, owner: NIOComponentSocket) {
        self.family = family
        self.owner = owner
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data
        let payload = buffer.readData(length: buffer.readableBytes) ?? Data()
        let host = envelope.remoteAddress.ipAddress ?? ""
        let port = UInt16(envelope.remoteAddress.port ?? 0)
        owner?.deliverReceived(data: payload, host: host, port: port, family: family)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        owner?.handleError(error)
    }

}
