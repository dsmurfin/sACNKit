//
//  ComponentSocket.swift
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

/// Component Socket Type
///
/// Enumerates the types of component sockets.
///
enum ComponentSocketType: String {
    /// Used for transmit communications (transmitting sACN messages).
    case transmit = "transmit"
    /// Used for receiving multicast communications (receiving sACN messages).
    case receive = "receive"
}

/// Source Socket IP Family
///
/// Enumerates the possible IP families.
///
enum ComponentSocketIPFamily: String {
    /// IPv4.
    case IPv4 = "IPv4"
    /// IPv6.
    case IPv6 = "IPv6"
}

// MARK: -
// MARK: -

/// Component Socket
///
/// The internal socket abstraction: binds sockets, joins/leaves multicast groups, sends and
/// receives datagrams, and reports back via `ComponentSocketDelegate`. Implemented by
/// `NIOComponentSocket` (SwiftNIO).
///
protocol ComponentSocket: AnyObject {

    /// A unique identifier for this socket. Datagrams are tagged with it so receivers can
    /// attribute traffic to the socket it arrived on.
    var id: UUID { get }

    /// The interface on which this socket is bound (a name or IP), or `nil` for all interfaces.
    var interface: String? { get }

    /// The delegate to receive notifications.
    ///
    /// Conforming types must store this reference **weakly**: owners hold their sockets strongly
    /// and set `socket.delegate = self`, so a strong reference here would form a retain cycle that
    /// leaks the component and prevents the close-on-dealloc teardown owners rely on.
    var delegate: ComponentSocketDelegate? { get set }

    /// Attempts to join a multicast group.
    func join(multicastGroup: String) async throws

    /// Attempts to leave a multicast group.
    func leave(multicastGroup: String) async throws

    /// Starts listening for network data, binding sockets on an optional interface.
    ///
    /// Sockets are minted by `sACNRuntime.makeSocket` and deliver into an event-loop-isolated actor.
    func startListening(onInterface interface: String?) async throws

    /// Stops listening for network data, closing this socket.
    func stopListening() async

    /// Closes this socket's channels fire-and-forget, without blocking or awaiting.
    ///
    /// Safe to call from any context including the event loop (an actor teardown running on the loop uses
    /// this rather than the blocking/awaiting stop variants).
    func close()

    /// Sends a message to a specific host and port.
    func send(message data: Data, host: String, port: UInt16)

}

extension ComponentSocket {

    /// Starts listening on `interface`, then joins the given multicast group for each enabled address family,
    /// rolling the listen back (via `stopListening()`) if any join fails.
    ///
    /// Shared by the receiver components, which differ only in the group they join (a per-universe data group
    /// vs the fixed universe-discovery group), so the bind + join-failure rollback lives in one place. The
    /// caller sets `delegate` and computes the group hostnames in its own isolation, passing them as plain
    /// values.
    ///
    /// - Parameters:
    ///    - interface: An optional interface on which to listen (`nil` means all interfaces).
    ///    - ipMode: The enabled address families.
    ///    - ipv4Group: The IPv4 multicast group hostname to join (used only when IPv4 is enabled).
    ///    - ipv6Group: The IPv6 multicast group hostname to join (used only when IPv6 is enabled).
    ///
    func startListeningAndJoin(
        onInterface interface: String?, ipMode: sACNIPMode, ipv4Group: String, ipv6Group: String
    ) async throws {
        try await startListening(onInterface: interface)
        do {
            if ipMode.usesIPv4() {
                try await join(multicastGroup: ipv4Group)
            }
            if ipMode.usesIPv6() {
                try await join(multicastGroup: ipv6Group)
            }
        } catch {
            await stopListening()
            throw error
        }
    }

}

// MARK: -
// MARK: -

/// Component Socket Delegate
///
/// Notifies observers when new messages are received, and provides debug information.
///
/// Required methods for objects implementing this delegate.
///
protocol ComponentSocketDelegate: AnyObject {

    /// Called when a message has been received.
    ///
    /// - Parameters:
    ///    - socket: The socket which received a message.
    ///    - data: The message as `Data`.
    ///    - sourceHostname: The hostname of the source of the message.
    ///    - sourcePort: The UDP port of the source of the message.
    ///    - ipFamily: The `ComponentSocketIPFamily` of the source of the message.
    ///
    func receivedMessage(
        for socket: ComponentSocket, withData data: Data, sourceHostname: String, sourcePort: UInt16, ipFamily: ComponentSocketIPFamily)

    /// Called when the socket was closed with an error (clean closes deliver no callback - delta B-3).
    ///
    /// - Parameters:
    ///    - socket: The socket which was closed.
    ///    - reason: The reason the socket closed (a `Sendable` errno + message).
    ///
    func socket(_ socket: ComponentSocket, socketDidCloseWith reason: SocketCloseReason)

    /// Called when a debug socket log is produced.
    ///
    /// - Parameters:
    ///    - socket: The socket for which this log event occured.
    ///    - logMessage: The debug message.
    ///
    func debugLog(for socket: ComponentSocket, with logMessage: String)

}

// MARK: -
// MARK: -

/// Socket Close Reason
///
/// A `Sendable` value describing why a socket closed, so it can cross into an `AsyncStream` event (an
/// opaque `any Error` is not statically `Sendable`). Carried on the async component `events` streams.
///
public struct SocketCloseReason: Error, Sendable {

    /// The errno code, if the underlying error carried one.
    public let errnoCode: CInt?

    /// A human-readable description of the close.
    public let message: String

    /// Creates a close reason. The `errnoCode` is extracted transport-side (from the underlying
    /// `IOError`) where the errno is available, so this seam type stays free of SwiftNIO.
    public init(errnoCode: CInt? = nil, message: String) {
        self.errnoCode = errnoCode
        self.message = message
    }

}

// MARK: -
// MARK: -

/// Source Socket Error
///
/// Enumerates all possible `sACNComponentSocketError` errors.
///
public enum sACNComponentSocketError: LocalizedError, Sendable {

    /// It was not possible to join this multicast group.
    case couldNotJoin(multicastGroup: String)

    /// It was not possible to leave this multicast group.
    case couldNotLeave(multicastGroup: String)

    /// It was not possible to bind to a port/interface.
    case couldNotBind(message: String)

    /// It was not possible to assign the interface on which to send multicast.
    case couldNotAssignMulticastInterface(message: String)

    /**
     A human-readable description of the error useful for logging purposes.
    */
    public var logDescription: String {
        switch self {
        case let .couldNotJoin(multicastGroup):
            return "Could not join multicast group \(multicastGroup)"
        case let .couldNotLeave(multicastGroup):
            return "Could not leave multicast group \(multicastGroup)"
        case let .couldNotBind(message), let .couldNotAssignMulticastInterface(message):
            return message
        }
    }

}
