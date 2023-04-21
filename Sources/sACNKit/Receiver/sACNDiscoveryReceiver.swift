//
//  sACNDiscoveryReceiver.swift
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

/// sACN Discovery Receiver
///
/// Discovers and provides information on sACN sources.
///
/// An E1.31-2018 sACN Receiver which receives universe discovery messages.
public class sACNDiscoveryReceiver {
    
    // MARK: Socket
    
    /// The Internet Protocol version(s) used by the receiver.
    private let ipMode: sACNIPMode
    
    /// The queue on which socket notifications occur (also used to protect state).
    private let socketDelegateQueue: DispatchQueue
    
    /// The sockets used for communications (one per interface).
    /// The key for each socket is the interface it is bound to (or an empty string for all interfaces).
    private var sockets: [String: ComponentSocket]
    
    /// The socket listening status (thread-safe getter).
    public var isListening: Bool {
        get { socketDelegateQueue.sync { _isListening } }
    }
    
    /// The private socket listening status.
    private var _isListening: Bool
    
    // MARK: Delegate
    
    /// Changes the receiver delegate of this receiver to the the object passed.
    ///
    /// - Parameters:
    ///   - delegate: The delegate to receive notifications.
    ///
    public func setDelegate(_ delegate: sACNDiscoveryReceiverDelegate?) {
        delegateQueue.sync {
            self.delegate = delegate
        }
    }
    
    /// Changes the debug delegate of this receiver to the the object passed.
    ///
    /// - Parameters:
    ///   - delegate: The delegate to receive notifications.
    ///
    public func setDebugDelegate(_ delegate: sACNComponentDebugDelegate?) {
        delegateQueue.sync {
            self.debugDelegate = delegate
        }
    }
    
    /// The delegate which receives notifications from this receiver.
    private weak var delegate: sACNDiscoveryReceiverDelegate?
    
    /// The delegate which receives debug log messages from this receiver.
    private weak var debugDelegate: sACNComponentDebugDelegate?

    /// The queue on which to send delegate notifications.
    private let delegateQueue: DispatchQueue
    
    // MARK: General
    
    /// The discovered sources and their universes:
    private var sources: [UUID: DiscoveryReceiverSource]
    
    // MARK: Timers
    
    /// The leeway used for timing. Informs the OS how accurate timings should be.
    static let timingLeeway: DispatchTimeInterval = .nanoseconds(1_000_000)
    
    /// The length of time for the main heartbeat (500 ms).
    private static let heartbeatTime: DispatchTimeInterval = DispatchTimeInterval.milliseconds(500)
    
    /// The queue on which timers run.
    static let timerQueue: DispatchQueue = DispatchQueue(label: "com.danielmurfin.sACNKit.discoveryReceiverTimer")
    
    /// The timer used for checking for source loss.
    private var heartbeatTimer: DispatchSourceTimer?
    
    // MARK: - Initialization
    
    /// Creates a new receiver to receive sACN discovery messages.
    ///
    /// - Parameters:
    ///    - ipMode: Optional: IP mode for this receiver (IPv4/IPv6/Both).
    ///    - interfaces: The network interfaces for this receiver. An interface may be a name (e.g. "en1" or "lo0") or the corresponding IP address (e.g. "192.168.4.35").
    ///    - delegateQueue: A delegate queue on which to receive delegate calls from this receiver.
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interfaces must not be empty.
    ///
    public init(ipMode: sACNIPMode = .ipv4Only, interfaces: Set<String> = [], delegateQueue: DispatchQueue) {
        precondition(!ipMode.usesIPv6() || !interfaces.isEmpty, "At least one interface must be provided for IPv6.")

        // sockets
        self.ipMode = ipMode
        let socketDelegateQueue = DispatchQueue(label: "com.danielmurfin.sACNKit.discoveryReceiverSocketDelegate")
        self.socketDelegateQueue = socketDelegateQueue
        if interfaces.isEmpty {
            let socket = ComponentSocket(type: .receive, ipMode: ipMode, port: UDP.sdtPort, delegateQueue: socketDelegateQueue)
            self.sockets = ["": socket]
        } else {
            self.sockets = interfaces.reduce(into: [String: ComponentSocket]()) { dict, interface in
                let socket = ComponentSocket(type: .receive, ipMode: ipMode, port: UDP.sdtPort, delegateQueue: socketDelegateQueue)
                dict[interface] = socket
            }
        }
        self._isListening = false
        
        // delegate
        self.delegateQueue = delegateQueue
        
        // general
        self.sources = [:]
    }
    
    deinit {
        stop()
    }
    
    // MARK: Public API
    
    /// Starts this discovery receiver.
    ///
    /// The receiver will begin listening for sACN Universe Discovery messages.
    ///
    /// - Throws: An error of type `sACNReceiverValidationError` or `sACNComponentSocketError`.
    ///
    public func start() throws {
        try socketDelegateQueue.sync {
            guard !_isListening else {
                throw sACNReceiverValidationError.receiverStarted
            }
            
            // begin listening
            try sockets.forEach { interface, socket in
                try listenForSocket(socket, on: interface.isEmpty ? nil : interface)
            }
            self._isListening = true
            
            // starts the main heartbeat to handle source loss
            startHeartbeat()
        }
    }
        
    /// Stops this receiver.
    ///
    /// The receiver will stop listening for sACN Universe Discovery messages.
    public func stop() {
        socketDelegateQueue.sync {
            guard _isListening else { return }

            stopHeartbeat()
            
            sockets.forEach { interface, socket in
                socket.delegate = nil
                socket.stopListening()
            }
            
            sources = [:]
        }
    }
    
    /// Updates the interfaces on which this receiver listens for sACN Universe Discovery messages.
    ///
    /// - Parameters:
    ///    - interfaces: The new interfaces for this receiver. An interface may be a name (e.g. "en1" or "lo0") or the corresponding IP address (e.g. "192.168.4.35").
    ///    Empty interfaces means listen on all interfaces (IPv4 only).
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interfaces must not be empty.
    ///
    public func updateInterfaces(_ newInterfaces: Set<String> = []) throws {
        precondition(!ipMode.usesIPv6() || !newInterfaces.isEmpty, "At least one interface must be provided for IPv6.")

        try socketDelegateQueue.sync {
            let existingInterfaces = {
                if let firstSocket = self.sockets.first, firstSocket.key.isEmpty {
                    return Set<String>()
                } else {
                    return Set(self.sockets.keys)
                }
            }()
            guard existingInterfaces != newInterfaces else { return }
            
            if existingInterfaces.isEmpty {
                // not possible for IPv6
                
                // remove existing sockets
                // stops listening on deinit if needed
                self.sockets.removeAll()

                // add each new interfaces
                for interface in newInterfaces {
                    let socket = ComponentSocket(type: .receive, ipMode: self.ipMode, port: UDP.sdtPort, delegateQueue: self.socketDelegateQueue)
                    sockets[interface] = socket
                    
                    // attempt to listen
                    if _isListening {
                        try listenForSocket(socket, on: interface)
                    }
                }
            } else if newInterfaces.isEmpty {
                // not possible for IPv6
                
                // remove existing sockets
                // stops listening on deinit if needed
                sockets.removeAll()
                
                // add socket for all interfaces
                let socket = ComponentSocket(type: .receive, ipMode: self.ipMode, port: UDP.sdtPort, delegateQueue: self.socketDelegateQueue)
                sockets[""] = socket

                // attempt to listen
                if _isListening {
                    try listenForSocket(socket)
                }
            } else {
                let interfacesToRemove = existingInterfaces.subtracting(newInterfaces)
                let interfacesToAdd = newInterfaces.subtracting(existingInterfaces)
                
                // remove sockets for interfaces no longer needed
                // stops listening on deinit if needed
                for interface in interfacesToRemove {
                    sockets.removeValue(forKey: interface)
                }
                
                // add each new interface
                var newSocketIds: [UUID] = []
                for interface in interfacesToAdd {
                    let socket = ComponentSocket(type: .receive, ipMode: self.ipMode, port: UDP.sdtPort, delegateQueue: self.socketDelegateQueue)
                    sockets[interface] = socket
                    newSocketIds.append(socket.id)
                    
                    // attempt to listen
                    if _isListening {
                        try listenForSocket(socket, on: interface)
                    }
                }
            }
        }
    }
    
    // MARK: General
    
    /// Attempts to start listening for a socket on an optional interface.
    ///
    /// - Parameters:
    ///    - socket: The socket to start listening.
    ///    - interface: Optional: An optional interface on which to listen (`nil` means all interfaces).
    ///
    private func listenForSocket(_ socket: ComponentSocket, on interface: String? = nil) throws {
        socket.delegate = self
        try socket.enableReusePort()
        try socket.startListening(onInterface: interface)
        
        // attempt to join multicast grousp
        if ipMode == .ipv4Only || ipMode == .ipv4And6 {
            let hostname = IPv4.universeDiscoveryHostname
            try socket.join(multicastGroup: hostname)
        }
        if ipMode == .ipv6Only || ipMode == .ipv4And6 {
            let hostname = IPv6.universeDiscoveryHostname
            try socket.join(multicastGroup: hostname)
        }
    }
    
    // MARK: Timers
    
    /// Starts the main heartbeat timer, which handles source loss.
    private func startHeartbeat() {
        let timer = DispatchSource.repeatingTimer(interval: Self.heartbeatTime, leeway: Self.timingLeeway, queue: Self.timerQueue) { [weak self] in
            if let _ = self?.heartbeatTimer {
                self?.checkForSourceLoss()
            }
        }
        heartbeatTimer = timer
    }
    
    /// Stops the main heartbeat timer.
    private func stopHeartbeat() {
        heartbeatTimer = nil
    }
    
    /// Checks for source loss.
    private func checkForSourceLoss() {
        var removeLostSources: Set<UUID> = []
        sources.forEach { id, source in
            if source.isTimerExpired {
                removeLostSources.insert(id)
            }
        }

        // notify all lost sources
        if !removeLostSources.isEmpty {
            delegate?.discoveryReceiver(self, lostSources: Array(removeLostSources))
        }

        // remove any expired sources
        removeLostSources.forEach { sourceId in
            sources.removeValue(forKey: sourceId)
        }
    }
    
}

// MARK: -
// MARK: -

/// sACN Discovery Receiver Extension
///
/// Packet processing.
extension sACNDiscoveryReceiver {
    
    /// Processes data as sACN.
    ///
    /// - Parameters:
    ///    - data: The data to process.
    ///    - ipFamily: The `ComponentSocketIPFamily` of the source of the message.
    ///    - socketId: The identifier of the socket on which this message was received.
    ///    - hostname: The hostname (address) of the source of the message.
    ///
    private func process(data: Data, ipFamily: ComponentSocketIPFamily, socketId: UUID, hostname: String) {
        do {
            let rootLayer = try RootLayer.parse(fromData: data)

            switch rootLayer.vector {
            case .extended:
                try processExtendedPacket(rootLayer: rootLayer, ipFamily: ipFamily, socketId: socketId, hostname: hostname)
            case .data:
                // handled by sACNReceiverRaw
                break
            }
        } catch let error as RootLayerValidationError {
            delegateQueue.async { self.debugDelegate?.debugLog(error.logDescription) }
        } catch let error as DataFramingLayerValidationError {
            delegateQueue.async { self.debugDelegate?.debugLog(error.logDescription) }
        } catch let error as DMPLayerValidationError {
            delegateQueue.async { self.debugDelegate?.debugLog(error.logDescription) }
        } catch {
            // unknown error
        }
    }
    
    // MARK: Extended
    
    /// Processes an sACN extended packet.
    ///
    /// - Parameters:
    ///    - rootLayer: The root layer to process.
    ///    - ipFamily: The `ComponentSocketIPFamily` of the source of the message.
    ///    - socketId: The identifier of the socket on which this message was received.
    ///    - hostname: The hostname (address) of the source of the message.
    ///
    private func processExtendedPacket(rootLayer: RootLayer, ipFamily: ComponentSocketIPFamily, socketId: UUID, hostname: String) throws {
        do {
            let framingLayer = try UniverseDiscoveryFramingLayer.parse(fromData: rootLayer.data)
            let discoveryLayer = try UniverseDiscoveryLayer.parse(fromData: framingLayer.data)
            
            processUniverseDiscovery(cid: rootLayer.cid, name: framingLayer.sourceName, discoveryLayer: discoveryLayer)
        } catch {
            // try to parse extended sync here if implemented
            // let framingLayer = try UniverseSyncFramingLayer etc.
            
            // throw the error
            throw error
        }
    }
    
    /// Processes an sACN universe discovery packet.
    ///
    /// - Parameters:
    ///    - cid: The CID of the source.
    ///    - name: The name of the source.
    ///    - discoveryLayer: The discovery layer containing a universe list.
    ///
    private func processUniverseDiscovery(cid: UUID, name: String, discoveryLayer: UniverseDiscoveryLayer) {
        if sources[cid] == nil {
            createDiscoverySource(cid: cid, name: name)
        }

        if let source = sources[cid] {
            source.resetTimer()
            
            let page = discoveryLayer.page
            let lastPage = discoveryLayer.lastPage
            let universeCount = discoveryLayer.universeList.count
            
            // pages are tracked so notification only occurs when all pages have been received
            // it is assumed pages are received in order from 0 to the last page
            if page != 0 && page != source.nextPage {
                // out-of-sequence (start over)
                source.nextUniverseIndex = 0
                source.nextPage = 0
            } else {
                // this page begins or continues a sequence of pages
                if page == 0 {
                    source.nextUniverseIndex = 0
                    source.nextPage = 0
                }
                
                // check if this page modifies the universe list
                let numberOfRemainingUniverses = source.universeCount - source.nextUniverseIndex
                let existingUniverseBlock = source.universes.count >= source.nextUniverseIndex+universeCount ? Array(source.universes[source.nextUniverseIndex..<source.nextUniverseIndex+universeCount]) : []
                if universeCount > numberOfRemainingUniverses || (page == lastPage && universeCount < numberOfRemainingUniverses) || existingUniverseBlock != discoveryLayer.universeList {
                    source.dirty = true
                    
                    source.universes.removeSubrange(source.nextUniverseIndex...)
                    source.universes += discoveryLayer.universeList
                    source.universeCount = source.nextUniverseIndex + universeCount
                    
                    if page < lastPage {
                        source.nextUniverseIndex += universeCount
                        source.nextPage += 1
                    } else {
                        // this is the last page
                        source.nextUniverseIndex = 0
                        source.nextPage = 0

                        // only mark dirty if the universes are ordered
                        if source.dirty {
                            source.dirty = zip(source.universes, source.universes.dropFirst()).allSatisfy { $0 <= $1 }
                        }
                        
                        if source.dirty {
                            source.dirty = false
                            source.lastNotifiedUniverseCount = source.universeCount
                            let info = sACNDiscoveryReceiverSource(cid: cid, name: name, universes: source.universes)
                            delegateQueue.async { self.delegate?.discoveryReceiverReceivedInfo(self, sourceInformation: info) }
                        }
                    }
                }
            }
        }
    }
    
    /// Creates a new discovery source with the information provided, and starts timer as required.
    ///
    /// - Parameters:
    ///    - cid: The unique identifier of the source.
    ///
    private func createDiscoverySource(cid: UUID, name: String) {
        let source = DiscoveryReceiverSource(name: name)
        sources[cid] = source
        source.startTimer()
    }
    
}

// MARK: -
// MARK: -

/// sACNDiscoveryReceiver Extension
///
/// `ComponentSocketDelegate` conformance.
extension sACNDiscoveryReceiver: ComponentSocketDelegate {
    /// Called when a message has been received.
    ///
    /// - Parameters:
    ///    - socket: The socket which received a message.
    ///    - data: The message as `Data`.
    ///    - sourceHostname: The hostname of the source of the message.
    ///    - sourcePort: The UDP port of the source of the message.
    ///    - ipFamily: The `ComponentSocketIPFamily` of the source of the message.
    ///
    func receivedMessage(for socket: ComponentSocket, withData data: Data, sourceHostname: String, sourcePort: UInt16, ipFamily: ComponentSocketIPFamily) {
        process(data: data, ipFamily: ipFamily, socketId: socket.id, hostname: sourceHostname)
    }
    
    /// Called when the socket was closed.
    ///
    /// - Parameters:
    ///    - socket: The socket which was closed.
    ///    - error: An optional error which occured when the socket was closed.
    ///
    func socket(_ socket: ComponentSocket, socketDidCloseWithError error: Error?) {
        guard error != nil, self._isListening else { return }
        delegateQueue.async { self.delegate?.discoveryReceiver(self, interface: socket.interface, socketDidCloseWithError: error) }
    }
    
    /// Called when a debug socket log is produced.
    ///
    /// - Parameters:
    ///    - socket: The socket for which this log event occured.
    ///    - logMessage: The debug message.
    ///
    func debugLog(for socket: ComponentSocket, with logMessage: String) {
        delegateQueue.async { self.debugDelegate?.debugSocketLog(logMessage) }
    }
}
