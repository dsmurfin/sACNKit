//
//  sACNReceiverRaw.swift
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

/// sACN Receiver Raw
///
/// An E1.31-2018 sACN Receiver Raw which receives sACN Messages from a single universe.
/// This class provides raw source data for sources which are online, and notifies of source loss
/// and loss of per-address priority.
public class sACNReceiverRaw {

    // MARK: Socket
    
    /// The Internet Protocol version(s) used by the receiver.
    private let ipMode: sACNIPMode
    
    /// The queue on which socket notifications occur (also used to protect state).
    private let socketDelegateQueue: DispatchQueue
    
    /// The identifiers of sockets and their sampling status.
    ///
    /// The presence of a socket identifier indicates it is either sampling or waiting to sample.
    /// A value of `true` means it is sampling.
    ///
    /// If this receiver is set to listen on all interfaces there will only be a single socket.
    /// Sampling occurs for this socket only.
    private var socketsSampling: [UUID: Bool]
    
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
    public func setDelegate(_ delegate: sACNReceiverRawDelegate?) {
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
    private weak var delegate: sACNReceiverRawDelegate?
    
    /// The delegate which receives debug log messages from this receiver.
    private weak var debugDelegate: sACNComponentDebugDelegate?

    /// The queue on which to send delegate notifications.
    private let delegateQueue: DispatchQueue
    
    // MARK: General

    /// The sACN universe this receiver observes.
    let universe: UInt16
    
    /// Whether preview data is filtered by this receiver.
    private let filterPreviewData: Bool
    
    /// An optional limit on the number of sources this receiver accepts.
    private let sourceLimit: Int?
    
    /// Whether this universe is sampling.
    private var sampling: Bool
    
    /// The sources that have been received.
    private var sources: [UUID: ReceiverRawSource]
    
    // MARK: Timers
    
    /// The leeway used for timing. Informs the OS how accurate timings should be.
    static let timingLeeway: DispatchTimeInterval = .nanoseconds(0)
    
    /// The sACN network data loss timeout (2500 ms).
    static let sourceLossTimeout: UInt64 = 2500
    
    /// How long to wait for a per-address priority start code (0xdd) packet when discovering a source (1500 ms).
    static let perAddressPriorityWait: UInt64 = 1500
    
    /// The length of time to sample a new universe (1500 ms).
    private static let sampleTime: DispatchTimeInterval = DispatchTimeInterval.milliseconds(1500)
    
    /// The length of time for the main heartbeat (500 ms).
    private static let heartbeatTime: DispatchTimeInterval = DispatchTimeInterval.milliseconds(500)
    
    /// The queue on which timers run.
    static let timerQueue: DispatchQueue = DispatchQueue(label: "com.danielmurfin.sACNKit.receiverTimer")
    
    /// The timer used for sampling of sources.
    private var sampleTimer: DispatchSourceTimer?
    
    /// The timer used for checking for source loss and checks.
    private var heartbeatTimer: DispatchSourceTimer?
    
    // MARK: Notification
    
    /// Whether source limit exceeded has been notified.
    private var sourceLimitExceededNotified: Bool
    
    // MARK: - Initialization
    
    /// Creates a new receiver using an interface and delegate queue, and optionally an IP Mode.
    ///
    /// If the universe provided is not valid, this initializes to nil.
    ///
    /// - Parameters:
    ///    - ipMode: Optional: IP mode for this receiver (IPv4/IPv6/Both).
    ///    - interfaces: The network interfaces for this receiver. An interface may be a name (e.g. "en1" or "lo0") or the corresponding IP address (e.g. "192.168.4.35").
    ///    - universe: The universe this receiver listens to.
    ///    - sourceLimit: The number of sources this receiver is able to process. This will be dependent on the hardware on which the receiver is running. Defaults to `4`.
    ///    - filterPreviewData: Optional: Whether source preview data should be filtered out (defaults to `true`).
    ///    - delegateQueue: A delegate queue on which to receive delegate calls from this receiver.
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interfaces must not be empty.
    ///
    public init?(ipMode: sACNIPMode = .ipv4Only, interfaces: Set<String> = [], universe: UInt16, sourceLimit: Int? = 4, filterPreviewData: Bool = true, delegateQueue: DispatchQueue) {
        precondition(!ipMode.usesIPv6() || !interfaces.isEmpty, "At least one interface must be provided for IPv6.")
        
        // the universe provided must be valid
        guard universe.validUniverse() else { return nil }
        
        // sockets
        self.ipMode = ipMode
        let socketDelegateQueue = DispatchQueue(label: "com.danielmurfin.sACNKit.receiverSocketDelegate-\(universe)")
        self.socketDelegateQueue = socketDelegateQueue
        if interfaces.isEmpty {
            let socket = ComponentSocket(type: .receive, ipMode: ipMode, port: UDP.sdtPort, delegateQueue: socketDelegateQueue)
            self.sockets = ["": socket]
            self.socketsSampling = [socket.id: true]
        } else {
            self.sockets = interfaces.reduce(into: [String: ComponentSocket]()) { dict, interface in
                let socket = ComponentSocket(type: .receive, ipMode: ipMode, port: UDP.sdtPort, delegateQueue: socketDelegateQueue)
                dict[interface] = socket
            }
            self.socketsSampling = sockets.map { $0.value.id }.reduce(into: [UUID: Bool]()) { dict, id in
                dict[id] = true
            }
        }
        self._isListening = false
        
        // delegate
        self.delegateQueue = delegateQueue
        
        // general
        self.universe = universe
        self.filterPreviewData = filterPreviewData
        self.sourceLimit = sourceLimit
        self.sampling = false
        self.sources = [:]
        
        // notification
        self.sourceLimitExceededNotified = false
    }
    
    deinit {
        stop()
    }
    
    // MARK: Public API
    
    /// Starts this receiver.
    ///
    /// The receiver will begin listening for sACN Data messages.
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
            // and other checks
            startHeartbeat()
            
            // begin sampling for this universe
            beginSamplingPeriod()
        }
    }
        
    /// Stops this receiver.
    ///
    /// The receiver will stop listening for sACN Data messages.
    public func stop() {
        socketDelegateQueue.sync {
            guard _isListening else { return }
            self._isListening = false
            
            sampleTimer = nil
            stopHeartbeat()
            
            sockets.forEach { interface, socket in
                socket.delegate = nil
                socket.stopListening()
            }
            
            sampling = false
            sources = [:]
        }
    }
    
    /// Updates the interfaces on which this receiver listens for sACN Data messages.
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
                let sample = sampleTimer == nil
                self.socketsSampling = sockets.map { $0.value.id }.reduce(into: [UUID: Bool]()) { dict, id in
                    dict[id] = sample
                }

                // begin sampling again (if not already sampling)
                self.beginSamplingPeriod()
            } else if newInterfaces.isEmpty {
                // not possible for IPv6
                
                // remove existing sockets
                // stops listening on deinit if needed
                sockets.removeAll()
                
                // add socket for all interfaces
                let socket = ComponentSocket(type: .receive, ipMode: self.ipMode, port: UDP.sdtPort, delegateQueue: self.socketDelegateQueue)
                sockets[""] = socket
                socketsSampling.removeAll()
                let sample = sampleTimer == nil
                socketsSampling[socket.id] = sample

                // attempt to listen
                if _isListening {
                    try listenForSocket(socket)
                }
                
                // begin sampling again (if not already sampling)
                self.beginSamplingPeriod()
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
                
                let sample = sampleTimer == nil
                for socketId in newSocketIds {
                    socketsSampling[socketId] = sample
                }
                
                // begin sampling again (if not already sampling)
                self.beginSamplingPeriod()
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
            let hostname = IPv4.multicastHostname(for: universe)
            try socket.join(multicastGroup: hostname)
        }
        if ipMode == .ipv6Only || ipMode == .ipv4And6 {
            let hostname = IPv6.multicastHostname(for: universe)
            try socket.join(multicastGroup: hostname)
        }
    }
    
    // MARK: Timers
    
    /// Starts the main heartbeat timer, which handles source loss and other checks.
    private func startHeartbeat() {
        let timer = DispatchSource.repeatingTimer(interval: Self.heartbeatTime, leeway: Self.timingLeeway, queue: Self.timerQueue) { [weak self] in
            if let _ = self?.heartbeatTimer {
                self?.socketDelegateQueue.async {
                    self?.checkForSourceLoss()
                }
            }
        }
        heartbeatTimer = timer
    }
    
    /// Stops the main heartbeat timer.
    private func stopHeartbeat() {
        heartbeatTimer = nil
    }
    
    /// Begins the initial sampling period for this universe.
    ///
    /// - Parameters:
    ///    - notify: Whether to notify sampling has started (defaults to `true`).
    ///
    private func beginSamplingPeriod(notify: Bool = true) {
        dispatchPrecondition(condition: .onQueue(socketDelegateQueue))

        guard !sampling else { return }
        sampling = true
        
        // notify sampling has started
        if notify {
            delegateQueue.async { self.delegate?.receiverStartedSampling(self) }
        }
        
        let timer = DispatchSource.singleTimer(interval: Self.sampleTime, leeway: Self.timingLeeway, queue: Self.timerQueue) { [weak self] in
            if let _ = self?.sampleTimer {
                self?.endedSamplingPeriod()
            }
        }
        self.sampleTimer = timer
    }
    
    /// Ends the initial sampling period for this universe.
    private func endedSamplingPeriod() {
        socketDelegateQueue.sync {
            sampling = false
            
            // remove any sockets which were sampling
            let keys = socketsSampling.filter { $0.value == true }.map { $0.key }
            keys.forEach { key in
                socketsSampling.removeValue(forKey: key)
            }
            
            // any sockets left should now be sampling
            if !socketsSampling.isEmpty {
                let keys = socketsSampling.keys
                keys.forEach { key in
                    socketsSampling.updateValue(true, forKey: key)
                }
                
                self.beginSamplingPeriod(notify: false)
            } else {
                self.sampleTimer = nil
                
                // notify sampling has ended
                delegateQueue.async { self.delegate?.receiverEndedSampling(self) }
            }
        }
    }
    
    /// Checks for source loss.
    private func checkForSourceLoss() {
        var notifyLostSources: Set<UUID> = []
        var removeLostSources: Set<UUID> = []
        sources.forEach { id, source in
            switch source.state {
            case .waitingForLevels:
                if source.isPAPTimerExpired {
                    // no need to notify, just remove this source
                    // it timed out in a waiting state
                    removeLostSources.insert(id)
                }
            case .waitingForPAP:
                if source.isPacketTimerExpired {
                    // no need to notify, just remove this source
                    // it timed out in a waiting state
                    removeLostSources.insert(id)
                }
            case .hasLevelsOnly, .hasLevelsAndPAP:
                let available = source.available()
                switch available {
                case .offline:
                    // notify this source was 
                    notifyLostSources.insert(id)
                    removeLostSources.insert(id)
                case .online:
                    break
                case .unknown:
                    break
                }
            }
        }
        
        // notify all lost sources
        if !notifyLostSources.isEmpty {
            delegateQueue.async { self.delegate?.receiver(self, lostSources: Array(notifyLostSources)) }
        }
        
        // remove any expired sources
        removeLostSources.forEach { sourceId in
            sources.removeValue(forKey: sourceId)
        }
    }
    
}

// MARK: -
// MARK: -

/// sACN Receiver Raw Extension
///
/// Packet processing.
extension sACNReceiverRaw {
    
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
                // universe sync is not currently handled
                // discovery is handled by sACNDiscoveryReceiver
                break
            case .data:
                try processDataPacket(rootLayer: rootLayer, ipFamily: ipFamily, socketId: socketId, hostname: hostname)
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
    
    // MARK: Data
    
    /// Processes an sACN data packet.
    ///
    /// - Parameters:
    ///    - rootLayer: The root layer to process.
    ///    - ipFamily: The `ComponentSocketIPFamily` of the source of the message.
    ///    - socketId: The identifier of the socket on which this message was received.
    ///    - hostname: The hostname (address) of the source of the message.
    ///
    private func processDataPacket(rootLayer: RootLayer, ipFamily: ComponentSocketIPFamily, socketId: UUID, hostname: String) throws {
        let framingLayer = try DataFramingLayer.parse(fromData: rootLayer.data)
        
        // the universe must match this receiver
        guard universe == framingLayer.universe else { return }
        
        // reject a message on a socket which is pending sampling
        let isSampling: Bool
        if !socketsSampling.isEmpty {
            guard let sampling = socketsSampling[socketId], sampling else { return }
            isSampling = true
        } else {
            isSampling = false
        }
        
        var notify = false
        
        let universeData: sACNReceiverRawSourceData?
        let previewData = framingLayer.options.contains(.preview)
        if let existingSource = sources[rootLayer.cid] {
            // reject packets from a different IP family or hostname
            guard existingSource.ipFamily == ipFamily && existingSource.hostname == hostname else { return }
            
            // check if the stream is terminated
            if framingLayer.options.contains(.terminated) {
                existingSource.markTerminated()
            }
            
            // also handles the source being terminated previously but not yet been removed
            guard !existingSource.terminated else { return }
            
            // the sequence must be valid
            guard validSequence(framingLayer.sequenceNumber, previousSequence: existingSource.sequence) else { return }
            existingSource.sequence = framingLayer.sequenceNumber
            
            let dmpLayer = try DMPLayer.parse(fromData: framingLayer.data)
            
            // based on the timecode update timers
            switch dmpLayer.startCode {
            case .null:
                processLevels(for: existingSource, notify: &notify)
            case .perAddressPriority:
                processPerAddressPriority(for: existingSource, notify: &notify)
            }
            
            // construct data only if it should be notified
            universeData = notify ? sACNReceiverRawSourceData(cid: rootLayer.cid, name: framingLayer.sourceName, hostname: hostname, universe: universe, priority: framingLayer.priority, preview: previewData, isSampling: isSampling, startCode: dmpLayer.startCode, valuesCount: dmpLayer.values.count, values: dmpLayer.values) : nil
        } else if !framingLayer.options.contains(.terminated) {
            // process new source data
            let dmpLayer = try DMPLayer.parse(fromData: framingLayer.data)
            let source = createSource(cid: rootLayer.cid, name: framingLayer.sourceName, hostname: hostname, ipFamily: ipFamily, sequence: framingLayer.sequenceNumber, startCode: dmpLayer.startCode, notify: &notify)
            sources[rootLayer.cid] = source
            
            // construct data only if it should be notified
            universeData = notify ? sACNReceiverRawSourceData(cid: rootLayer.cid, name: framingLayer.sourceName, hostname: hostname, universe: universe, priority: framingLayer.priority, preview: previewData, isSampling: isSampling, startCode: dmpLayer.startCode, valuesCount: dmpLayer.values.count, values: dmpLayer.values) : nil
        } else {
            universeData = nil
        }
        
        guard let universeData else { return }
        
        // only notify if this is not preview data, or if we shouldn't filter it
        guard !previewData || !filterPreviewData else { return }
        
        // data is provided synchronously
        delegateQueue.sync { self.delegate?.receiverReceivedUniverseData(self, sourceData: universeData) }
    }
    
    /// Decides whether level data should be notified for a source.
    ///
    /// - Parameters:
    ///    - source: The source for which level data has been received.
    ///    - notify: Inout: Whether to notify.
    ///
    private func processLevels(for source: ReceiverRawSource, notify: inout Bool) {
        // notify universe data during and after the sampling period
        notify = true
        
        // we received something (even if it's invalid)
        source.dmxReceivedSinceLastTick = true
        source.startPacketTimer()
        
        let currentSourceState = source.state
        switch currentSourceState {
        case .waitingForLevels:
            if sampling {
                // we are sampling so notify
                source.state = .hasLevelsAndPAP
            } else {
                // wait for a per-address priority packet
                source.state = .waitingForPAP
                notify = false
            }
        case .waitingForPAP:
            if source.isPAPTimerExpired {
                // per-address priority waiting period has expired
                // let the timer run again in case it is received later
                source.state = .hasLevelsOnly
                source.startPAPTimer(withInterval: Self.sourceLossTimeout)
            } else {
                // a DMX packet was received during per-address priority waiting period
                notify = false
            }
        case .hasLevelsOnly:
            // receiving more level data
            break
        case .hasLevelsAndPAP:
            guard source.isPAPTimerExpired else { break }
            // the source stopped sending per-address priorities but continues to send levels
            source.notifyPerAddressLost(using: delegate, from: self)
            source.state = .hasLevelsOnly
        }
    }
    
    /// Decides whether per-address priority data should be notified for a source.
    ///
    /// - Parameters:
    ///    - source: The source for which per-address priority data has been received.
    ///    - notify: Inout: Whether to notify.
    ///
    private func processPerAddressPriority(for source: ReceiverRawSource, notify: inout Bool) {
        notify = true
        
        let currentSourceState = source.state
        switch currentSourceState {
        case .waitingForLevels:
            // still waiting for levels (ignore per-address priority until at least
            // one level packet has been received)
            notify = false
            source.resetPAPTimer()
        case .waitingForPAP, .hasLevelsOnly:
            source.state = .hasLevelsAndPAP
            source.startPAPTimer(withInterval: Self.sourceLossTimeout)
        case .hasLevelsAndPAP:
            source.resetPAPTimer()
        }
    }
    
    /// Creates a new source with the information provided, and starts timer for per-address
    /// priority and source loss as required.
    ///
    /// If the source limit has been reached no new source will be returned, in addition
    /// if it has not already been notified a sources exceeded notification will occur.
    ///
    /// - Parameters:
    ///    - cid: The unique identifier of the source.
    ///    - name: The name of the source as received.
    ///    - hostname: The hostname of the source.
    ///    - ipFamily:The IP family.
    ///    - sequence: The current sequence number.
    ///    - startCode: The DMX512-A START code.
    ///    - notify: Inout: Whether to notify.
    ///
    /// - Returns: An optional `ReceiverSource`.
    ///
    private func createSource(cid: UUID, name: String, hostname: String, ipFamily: ComponentSocketIPFamily, sequence: UInt8, startCode: DMX.STARTCode, notify: inout Bool) -> ReceiverRawSource? {
        // notify universe data during and after the sampling period
        notify = true
        
        // if there is a source limit it must not have been reached
        if let sourceLimit, sources.count >= sourceLimit {
            if !sourceLimitExceededNotified {
                sourceLimitExceededNotified = true
                delegateQueue.async { self.delegate?.receiverExceededSources(self) }
            }
            return nil
        }
        
        let state: ReceiverRawSource.State = {
            if sampling {
                switch startCode {
                case .null:
                    return .hasLevelsOnly
                case .perAddressPriority:
                    return .waitingForLevels
                }
            } else {
                switch startCode {
                case .null:
                    return .waitingForPAP
                case .perAddressPriority:
                    return .waitingForLevels
                }
            }
        }()
        
        let source = ReceiverRawSource(cid: cid, hostname: hostname, ipFamily: ipFamily, name: name, sequence: sequence, state: state)
        source.startPacketTimer()
        
        if sampling {
            switch startCode {
            case .null:
                // when in the sampling period waiting for per-address priority is not neccessary
                break
            case .perAddressPriority:
                // need to wait for levels (ignore per-address priority packets until a level packet is received)
                source.startPAPTimer(withInterval: Self.sourceLossTimeout)
            }
        } else {
            // even if this is a per-address priority packet make sure level packets are being sent before notifying
            switch startCode {
            case .null:
                source.startPAPTimer(withInterval: Self.perAddressPriorityWait)
            case .perAddressPriority:
                break
            }
        }
        
        // do not notify during sampling if this is per-address priority
        if (sampling && startCode == .perAddressPriority) || !sampling {
            notify = false
        }
        
        return source
    }
    
    /// Removes a single source from this receiver.
    ///
    /// - Parameters:
    ///    - cid: The CID of the source to remove.
    ///
    private func removeSource(withCid cid: UUID) {
        sources.removeValue(forKey: cid)
    }
    
    /// Removes all sources from this receiver.
    private func removeAllSources() {
        sourceLimitExceededNotified = false
        sources = [:]
    }
    
    /// Checks if a sequence number is valid in relation to the previous number.
    ///
    /// - Parameters:
    ///    - newSequence: The new sequence number.
    ///    - oldSequence: The old sequence number.
    ///
    private func validSequence(_ newSequence: UInt8, previousSequence: UInt8) -> Bool {
        let seqnumCmp = Int8(bitPattern: newSequence) &- Int8(bitPattern: previousSequence)
        return (seqnumCmp > 0 || seqnumCmp <= -20)
    }
    
}

// MARK: -
// MARK: -

/// sACNReceiverRaw Extension
///
/// `ComponentSocketDelegate` conformance.
extension sACNReceiverRaw: ComponentSocketDelegate {
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
        delegateQueue.async { self.delegate?.receiver(self, interface: socket.interface, socketDidCloseWithError: error) }
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
