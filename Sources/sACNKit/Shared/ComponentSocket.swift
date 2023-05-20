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
import CocoaAsyncSocket
import Network

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
/// Creates a raw socket for network communications, and handles delegate notifications.
///
class ComponentSocket: NSObject, GCDAsyncUdpSocketDelegate {
 
    /// A unique identifier for this socket.
    let id: UUID
    
    /// The raw socket.
    private var socket: GCDAsyncUdpSocket?
    
    /// The type of socket.
    private let socketType: ComponentSocketType
    
    /// The dispatch queue on which the socket sends and receives messages.
    private let socketQueue: DispatchQueue
    
    /// The Internet Protocol version(s) used by the source.
    private let ipMode: sACNIPMode
    
    /// The interface on which to bind this socket.
    private (set) var interface: String?
    
    /// The UDP port on which to bind this socket.
    private let port: UInt16
    
    /// The delegate to receive notifications.
    weak var delegate: ComponentSocketDelegate?
        
    /// Creates a new Source Socket.
    ///
    /// Component sockets are used for joining multicast groups, and sending and receiving network data.
    ///
    /// - Parameters:
    ///    - type: The type of socket (unicast, multicast).
    ///    - ipMode: IP mode for this socket (IPv4/IPv6/Both).
    ///    - port: Optional: UDP port to bind.
    ///    - delegateQueue: The dispatch queue on which to receive delegate calls from this component.
    ///
    init(type: ComponentSocketType, ipMode: sACNIPMode, port: UInt16 = 0, delegateQueue: DispatchQueue) {
        self.id = UUID()
        self.socketType = type
        self.ipMode = ipMode
        self.port = port
        self.socketQueue = DispatchQueue(label: "com.danielmurfin.sACNKit.componentSocketQueue-\(id.uuidString)")
        super.init()
        self.socket = GCDAsyncUdpSocket(delegate: self, delegateQueue: delegateQueue, socketQueue: self.socketQueue)
    }
    
    /// Allows other services to reuse the port.
    ///
    /// - Throws: An error of type `sACNComponentSocketError`.
    ///
    func enableReusePort() throws {
        do {
            try socket?.enableReusePort(true)
        } catch {
            throw sACNComponentSocketError.couldNotEnablePortReuse
        }
    }

    /// Attempts to join a multicast group.
    ///
    /// - Parameters:
    ///    - multicastGroup: The multicast group hostname.
    ///
    /// - Throws: An error of type `sACNComponentSocketError`
    ///
    func join(multicastGroup: String) throws {
        switch socketType {
        case .transmit:
            break
        case .receive:
            do {
                try socket?.joinMulticastGroup(multicastGroup, onInterface: interface)
            } catch {
                throw sACNComponentSocketError.couldNotJoin(multicastGroup: multicastGroup)
            }
        }
    }
    
    /// Attempts to leave a multicast group.
    ///
    /// - Parameters:
    ///    - multicastGroup: The multicast group hostname.
    ///
    /// - Throws: An error of type `sACNComponentSocketError`
    ///
    func leave(multicastGroup: String) throws {
        switch socketType {
        case .transmit:
            break
        case .receive:
            do {
                try socket?.leaveMulticastGroup(multicastGroup, onInterface: interface)
            } catch {
                throw sACNComponentSocketError.couldNotLeave(multicastGroup: multicastGroup)
            }
        }
    }

    /// Starts listening for network data. Binds sockets, and joins multicast groups as neccessary.
    ///
    /// - Parameters:
    ///    - interface: An optional interface on which to bind the socket. It may be a name (e.g. "en1" or "lo0") or the corresponding IP address (e.g. "192.168.4.35").
    ///    - multicastGroups: An array of multicast group hostnames for this socket.
    ///
    /// - Throws: An error of type `sACNComponentSocketError`.
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interface must not be nil.
    ///
    func startListening(onInterface interface: String?, multicastGroups: [String] = []) throws {
        precondition(!ipMode.usesIPv6() || interface != nil, "An interface must be provided for IPv6.")
        self.interface = interface

        do {
            switch socketType {
            case .transmit:
                // only bind on an interface if not multicast receiver
                try socket?.bind(toPort: port, interface: interface)
                delegate?.debugLog(for: self, with: "Successfully bound unicast to port: \(socket?.localPort() ?? 0) on interface: \(interface ?? "all")")
            case .receive:
                try socket?.bind(toPort: port)
                delegate?.debugLog(for: self, with: "Successfully bound multicast to port: \(port)")
            }
        } catch {
            throw sACNComponentSocketError.couldNotBind(message: "\(id): Could not bind \(socketType.rawValue) socket.")
        }
        
        do {
            switch socketType {
            case .transmit:
                // attempt to set the interface multicast should be sent on (required for IPv6)
                // it should not be possible to have a no interfaces when using IPv6
                if let interface, ipMode.usesIPv6() {
                    try socket?.sendIPv6Multicast(onInterface: interface)
                }
            case .receive:
                break
            }
        } catch {
            throw sACNComponentSocketError.couldNotAssignMulticastInterface(message: "\(id): Could not assign interface for sending multicast on \(socketType.rawValue) socket.")
        }
        
        do {
            try socket?.beginReceiving()
        } catch {
            throw sACNComponentSocketError.couldNotReceive(message: "\(id): Could not receive on \(socketType.rawValue) socket.")
        }
        
        switch socketType {
        case .transmit:
            break
        case .receive:
            for group in multicastGroups {
                try join(multicastGroup: group)
            }
        }
    }
    
    /// Stops listening for network data.
    ///
    /// Closes this socket.
    ///
    func stopListening() {
        socket?.close()
    }
    
    /// Sends a message to a specific host and port.
    ///
    /// - Parameters:
    ///    - data: The data to be sent.
    ///    - host: The destination hostname for this message.
    ///    - port: The destination port for this message.
    ///
    func send(message data: Data, host: String, port: UInt16) {
        socket?.send(data, toHost: host, port: port, withTimeout: -1, tag: 0)
    }
    
    /// Safely accesses the type of this socket and returns a string.
    ///
    /// - Returns: A string representing the type of this socket.
    ///
    private func socketTypeString() -> String {
        socketType.rawValue.capitalized
    }
    
    // MARK: - GCD Async UDP Socket Delegate
    
    /// GCD Async UDP Socket Delegate
    ///
    /// Implements all required delegate methods for `GCDAsyncUdpSocket`.
    ///
    
    /// Called when the datagram with the given tag has been sent.
    public func udpSocket(_ sock: GCDAsyncUdpSocket, didSendDataWithTag tag: Int) {
        delegate?.debugLog(for: self, with: "\(socketTypeString()) socket did send data")
    }
    
    /// Called if an error occurs while trying to send a datagram. This could be due to a timeout, or something more serious such as the data being too large to fit in a single packet.
    public func udpSocket(_ sock: GCDAsyncUdpSocket, didNotSendDataWithTag tag: Int, dueToError error: Error?) {
        delegate?.debugLog(for: self, with: "\(socketTypeString()) socket did not send data due to error \(String(describing: error?.localizedDescription))")
    }
    
    /// Called when the socket has received a datagram.
    public func udpSocket(_ sock: GCDAsyncUdpSocket, didReceive data: Data, fromAddress address: Data, withFilterContext filterContext: Any?) {
        guard let hostname = GCDAsyncUdpSocket.host(fromAddress: address) else { return }
        let port = GCDAsyncUdpSocket.port(fromAddress: address)
        let ipFamily: ComponentSocketIPFamily = GCDAsyncUdpSocket.isIPv6Address(address) ? .IPv6 : .IPv4
        
        delegate?.debugLog(for: self, with: "Socket received data of length \(data.count), from \(ipFamily.rawValue) \(hostname):\(port)")
        delegate?.receivedMessage(for: self, withData: data, sourceHostname: hostname, sourcePort: port, ipFamily: ipFamily)
    }
    
    /// Called when the socket is closed.
    public func udpSocketDidClose(_ sock: GCDAsyncUdpSocket, withError error: Error?) {
        delegate?.debugLog(for: self, with: "\(socketTypeString()) socket did close, with error \(String(describing: error?.localizedDescription))")
        delegate?.socket(self, socketDidCloseWithError: error)
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
    func receivedMessage(for socket: ComponentSocket, withData data: Data, sourceHostname: String, sourcePort: UInt16, ipFamily: ComponentSocketIPFamily)
    
    /// Called when the socket was closed.
    ///
    /// - Parameters:
    ///    - socket: The socket which was closed.
    ///    - error: An optional error which occured when the socket was closed.
    ///
    func socket(_ socket: ComponentSocket, socketDidCloseWithError error: Error?)
    
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

/// Source Socket Error
///
/// Enumerates all possible `sACNComponentSocketError` errors.
///
public enum sACNComponentSocketError: LocalizedError {
    
    /// It was not possible to enable port reuse.
    case couldNotEnablePortReuse
    
    /// It was not possible to join this multicast group.
    case couldNotJoin(multicastGroup: String)
    
    /// It was not possible to leave this multicast group.
    case couldNotLeave(multicastGroup: String)
    
    /// It was not possible to bind to a port/interface.
    case couldNotBind(message: String)
    
    /// It was not possible to assign the interface on which to send multicast.
    case couldNotAssignMulticastInterface(message: String)
    
    /// It was not possible to start receiving data, e.g. because no bind occured first.
    case couldNotReceive(message: String)

    /**
     A human-readable description of the error useful for logging purposes.
    */
    public var logDescription: String {
        switch self {
        case .couldNotEnablePortReuse:
            return "Could not enable port reuse"
        case let .couldNotJoin(multicastGroup):
            return "Could not join multicast group \(multicastGroup)"
        case let .couldNotLeave(multicastGroup):
            return "Could not leave multicast group \(multicastGroup)"
        case let .couldNotBind(message), let .couldNotReceive(message), let .couldNotAssignMulticastInterface(message):
            return message
        }
    }
        
}
