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
/// Concurrency: `NIOComponentSocket` is `@unchecked Sendable`, all mutable state behind a single
/// `NIOLockedValueBox`. Callbacks are delivered on `eventLoop` (see `deliver(_:)`) - synchronously when
/// already there - so an owning actor isolated to that loop (the socket is minted by `sACNRuntime.makeSocket`
/// on the actor's loop) receives callbacks in-isolation (via `assumeIsolated` in its `nonisolated` delegate
/// methods) with no queue hop. See docs/modernization/phase-4.md and `.claude/rules/threading.md`.
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

    /// The single event loop on which this facade's channels are bound and read, and on which delegate
    /// callbacks are delivered. An owner isolated to this loop receives callbacks **on the loop**
    /// (synchronously when already there), so its `nonisolated` delegate methods can `assumeIsolated` in.
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

        /// A monotonic listen-cycle epoch, bumped on every stop, so an async bind that suspended across a
        /// stop can detect it is stale and not store channels into a stopped socket.
        var epoch: UInt64 = 0

    }

    /// The lock-guarded mutable state.
    private let state = NIOLockedValueBox(State())

    /// Creates a socket bound to a specific event loop, delivering callbacks **on that loop** (used by
    /// `sACNRuntime.makeSocket` so the socket and its owning actor share one serial context).
    init(type: ComponentSocketType, ipMode: sACNIPMode, port: UInt16 = 0, eventLoop: EventLoop) {
        self.socketType = type
        self.ipMode = ipMode
        self.port = port
        self.eventLoop = eventLoop
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

    /// Attempts to join a multicast group.
    ///
    /// - Parameters:
    ///    - multicastGroup: The multicast group hostname.
    ///
    /// - Throws: An error of type `sACNComponentSocketError`.
    ///
    func join(multicastGroup: String) async throws {
        guard let future = membershipFuture(joining: true, multicastGroup: multicastGroup) else { return }
        do {
            try await future.get()
        } catch {
            throw sACNComponentSocketError.couldNotJoin(multicastGroup: multicastGroup)
        }
    }

    /// The future to join or leave a multicast group, or `nil` for a transmit socket / missing channel.
    private func membershipFuture(joining: Bool, multicastGroup: String) -> EventLoopFuture<Void>? {
        guard socketType == .receive else { return nil }
        let family: ComponentSocketIPFamily = multicastGroup.contains(":") ? .IPv6 : .IPv4
        guard let channel = channel(for: family) as? MulticastChannel else { return nil }
        do {
            let group = try SocketAddress(ipAddress: multicastGroup, port: Int(port))
            let device = try joinDevice(family: family)
            return joining ? channel.joinGroup(group, device: device) : channel.leaveGroup(group, device: device)
        } catch {
            return channel.eventLoop.makeFailedFuture(error)
        }
    }

    /// Attempts to leave a multicast group.
    ///
    /// - Parameters:
    ///    - multicastGroup: The multicast group hostname.
    ///
    /// - Throws: An error of type `sACNComponentSocketError`.
    ///
    func leave(multicastGroup: String) async throws {
        guard let future = membershipFuture(joining: false, multicastGroup: multicastGroup) else { return }
        do {
            try await future.get()
        } catch {
            throw sACNComponentSocketError.couldNotLeave(multicastGroup: multicastGroup)
        }
    }

    /// Starts listening for network data, binding fresh channels for the enabled families.
    ///
    /// Channels are recreated on every call, so a facade may be stopped and restarted (owners reuse their
    /// sockets across `stop()`/`start()`). Each listen cycle resets the close latch. If a `stopListening()`
    /// interleaves the bind (actor reentrancy across the suspension), this throws `CancellationError` after
    /// closing the just-opened channels - the stop wins, and the socket is left stopped. Returning without
    /// throwing therefore means the socket is listening.
    ///
    /// - Parameters:
    ///    - interface: An optional interface on which to bind (a name like "en1"/"lo0", an IP, or the aliases
    ///      "localhost"/"loopback").
    ///
    /// - Throws: An error of type `sACNComponentSocketError`.
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interface must not be nil.
    ///
    func startListening(onInterface interface: String?) async throws {
        precondition(!ipMode.usesIPv6() || interface != nil, "An interface must be provided for IPv6.")

        let epoch = state.withLockedValue { state -> UInt64 in
            state.interface = interface
            state.closeReported = false
            return state.epoch
        }

        var opened: [ComponentSocketIPFamily: Channel] = [:]
        do {
            if ipMode.usesIPv4() {
                opened[.IPv4] = try await bindChannelAsync(family: .IPv4, interface: interface)
            }
            if ipMode.usesIPv6() {
                opened[.IPv6] = try await bindChannelAsync(family: .IPv6, interface: interface)
            }
        } catch {
            for channel in opened.values {
                try? await channel.close().get()
            }
            throw error
        }

        // A stop that interleaved the binds above bumped the epoch: the socket is now stopped, so close
        // the just-opened channels rather than resurrecting a stopped socket, and report cancellation.
        let stale = state.withLockedValue { state -> Bool in
            guard state.epoch == epoch else { return true }
            state.channels = opened
            return false
        }
        if stale {
            for channel in opened.values {
                try? await channel.close().get()
            }
            throw CancellationError()
        }
    }

    /// Stops listening for network data, closing this socket's channels.
    func stopListening() async {
        let channels = state.withLockedValue { state -> [Channel] in
            let channels = Array(state.channels.values)
            state.channels = [:]
            state.closeReported = true
            state.epoch &+= 1
            return channels
        }
        for channel in channels {
            try? await channel.close().get()
        }
    }

    /// Closes this socket's channels fire-and-forget (no blocking, no awaiting), so it is safe from any
    /// context including the event loop.
    func close() {
        let channels = state.withLockedValue { state -> [Channel] in
            let channels = Array(state.channels.values)
            state.channels = [:]
            state.closeReported = true
            state.epoch &+= 1
            return channels
        }
        for channel in channels {
            channel.close(promise: nil)
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
    private func bindChannelAsync(family: ComponentSocketIPFamily, interface: String?) async throws -> Channel {
        let channel: Channel
        do {
            let address: SocketAddress
            switch socketType {
            case .transmit:
                address = try NetworkInterfaceResolver.bindAddress(interface: interface, family: family, port: port)
            case .receive:
                address = NetworkInterfaceResolver.wildcard(family: family, port: port)
            }
            channel = try await makeBootstrap(family: family).bind(to: address).get()
        } catch {
            throw sACNComponentSocketError.couldNotBind(message: "\(id): Could not bind \(socketType.rawValue) socket.")
        }

        if socketType == .transmit, family == .IPv6, let interface {
            do {
                let device = try NetworkInterfaceResolver.device(matching: interface, family: .IPv6)
                // IPV6_MULTICAST_IF is an IPPROTO_IPV6-level option; the default socketOption level is
                // SOL_SOCKET, so name the level explicitly. The value type is platform-dependent (CInt on
                // Darwin, Int on Linux), so build it from the alias rather than hardcoding CInt.
                try await channel.setOption(
                    ChannelOptions.Types.SocketOption(level: .ipv6, name: .ipv6_multicast_if),
                    value: ChannelOptions.Types.SocketOption.Value(device.interfaceIndex)
                ).get()
            } catch {
                try? await channel.close().get()
                throw sACNComponentSocketError.couldNotAssignMulticastInterface(
                    message: "\(id): Could not assign interface for sending multicast on \(socketType.rawValue) socket.")
            }
        }

        return channel
    }

    // MARK: - Delivery

    /// Delivers work to the owner: runs it **on the event loop** (synchronously when already there - the hot
    /// path - so the owner's `nonisolated` delegate methods can `assumeIsolated` in without a queue hop).
    private func deliver(_ work: @escaping @Sendable () -> Void) {
        if eventLoop.inEventLoop {
            work()
        } else {
            eventLoop.execute(work)
        }
    }

    /// Delivers a received datagram to the owner.
    fileprivate func deliverReceived(data: Data, host: String, port: UInt16, family: ComponentSocketIPFamily) {
        deliver { [self] in
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
            let channels = state.channels
            state.channels = [:]
            return (Array(channels.values), shouldReport)
        }
        for channel in channels {
            channel.close(promise: nil)
        }
        guard shouldReport else { return }
        let reason = Self.closeReason(error)
        deliver { [self] in
            guard let delegate = state.withLockedValue({ $0.delegate }) else { return }
            delegate.socket(self, socketDidCloseWith: reason)
        }
    }

    /// Builds a `SocketCloseReason`, extracting the errno from the underlying NIO `IOError` when present.
    private static func closeReason(_ error: Error) -> SocketCloseReason {
        SocketCloseReason(errnoCode: (error as? IOError)?.errnoCode, message: "\(error)")
    }

    /// Delivers a send failure to the debug delegate.
    private func reportSendFailure(_ error: Error) {
        deliver { [self] in
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
