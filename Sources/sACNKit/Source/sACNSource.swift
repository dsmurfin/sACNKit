//
//  sACNSource.swift
//
//  Copyright (c) 2020 Daniel Murfin
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

/// sACN Source
///
/// An E1.31-2018 sACN Source which Transmits sACN Messages.
final public class sACNSource {

    // MARK: Socket
    
    /// The Internet Protocol version(s) used by the source.
    private let ipMode: sACNIPMode
    
    /// The queue on which socket notifications occur (also used to protect state).
    private let socketDelegateQueue: DispatchQueue
    
    /// The interfaces of sockets to be terminated, and whether they should be removed on completion.
    private var socketsShouldTerminate: [String: Bool]
    
    /// The sockets used for communications (one per interface).
    /// The key for each socket is the interface it is bound to (or an empty string for all interfaces).
    private var sockets: [String: ComponentSocket]
    
    /// The socket listening status (thread-safe getter).
    public var isListening: Bool {
        get { socketDelegateQueue.sync { _isListening } }
    }
    
    /// The private socket listening status.
    private var _isListening: Bool
    
    /// Whether this source should actively output sACN Universe Discovery and Data messages.
    /// This may be useful for backup scenarios to ensure the source is ready to output as soon as required.
    ///
    /// Calling this before `startOutput()` will have no effect.
    public var shouldOutput: Bool {
        get { socketDelegateQueue.sync { _shouldOutput } }
        set { socketDelegateQueue.sync { _shouldOutput = newValue } }
    }
    
    /// The private state of should output.
    private var _shouldOutput: Bool
    
    // MARK: Delegate
    
    /// Changes the source delegate of this source to the the object passed.
    ///
    /// - Parameters:
    ///   - delegate: The delegate to receive notifications.
    ///
    public func setDelegate(_ delegate: sACNSourceDelegate?) {
        delegateQueue.sync {
            self.delegate = delegate
        }
    }
    
    /// Changes the debug delegate of this source to the the object passed.
    ///
    /// - Parameters:
    ///   - delegate: The delegate to receive notifications.
    ///
    public func setDebugDelegate(_ delegate: sACNComponentDebugDelegate?) {
        delegateQueue.sync {
            self.debugDelegate = delegate
        }
    }
    
    /// The delegate which receives notifications from this source.
    private weak var delegate: sACNSourceDelegate?
    
    /// The delegate which receives debug log messages from this source.
    private weak var debugDelegate: sACNComponentDebugDelegate?

    /// The queue on which to send delegate notifications.
    private let delegateQueue: DispatchQueue
    
    /// The previous delegate transmission state.
    /// If `true`, transmission was notified already as active, if `false`, transmission was notified already as inactive.
    private var delegateTransmissionState: Bool?
    
    // MARK: General
    
    /// A globally unique identifier (UUID) representing the source.
    private let cid: UUID
    
    /// A human-readable name for the source.
    private var name: String {
        didSet {
            if name != oldValue {
                nameData = Source.buildNameData(from: name)
            }
        }
    }
    
    /// The `name` of the source stored as `Data`.
    private var nameData: Data
    
    /// The default priority for universes added to this source.
    private var priority: UInt8
    
    /// Whether the source should terminate.
    private var shouldTerminate: Bool
    
    /// The universe numbers added to this source.
    private var universeNumbers: [UInt16]
    
    /// The universes added to this source which may be transmitted.
    private var universes: [SourceUniverse]
    
    /// A pre-compiled root layer as `Data`.
    private var rootLayer: Data
    
    /// A pre-compiled universe discovery message as `Data`.
    private var universeDiscoveryMessages: [Data]
    
    // MARK: Timers
    
    /// The leeway used for timing. Informs the OS how accurate timings should be.
    private static let timingLeeway: DispatchTimeInterval = .nanoseconds(0)
    
    /// The universe discovery interval (10 secs).
    private static let universeDiscoveryInterval: DispatchTimeInterval = DispatchTimeInterval.seconds(10)
    
    /// The data transmit interval (0.227 secs).
    private static let dataTransmitInterval: DispatchTimeInterval = DispatchTimeInterval.interval(1/44)
    
    /// The queue on which timers run.
    private let timerQueue: DispatchQueue

    /// The universe discovery timer
    private var universeDiscoveryTimer: DispatchSourceTimer?
    
    /// The data transmit timer.
    private var dataTransmitTimer: DispatchSourceTimer?

    // MARK: - Initialization

    /// Creates a new source using a name, interfaces and delegate queue, and optionally a CID, IP Mode, Priority.
    ///
    /// The CID of an sACN source should persist across launches, so should be stored in persistent storage.
    ///
    /// - Parameters:
    ///    - name: Optional: An optional human readable name of this source.
    ///    - cid: Optional: CID for this source.
    ///    - ipMode: Optional: IP mode for this source (IPv4/IPv6/Both).
    ///    - interfaces: Optional: The network interfaces for this source. An interface may be a name (e.g. "en1" or "lo0") or the corresponding IP address (e.g. "192.168.4.35").
    ///    - priority: Optional: Default priority for this source, used when universes do not have explicit priorities (values permitted 0-200).
    ///    - delegateQueue: A delegate queue on which to receive delegate calls from this source.
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interfaces must not be empty.
    ///
    public init(name: String? = nil, cid: UUID = UUID(), ipMode: sACNIPMode = .ipv4Only, interfaces: Set<String> = [], priority: UInt8 = 100, delegateQueue: DispatchQueue) {
        precondition(!ipMode.usesIPv6() || !interfaces.isEmpty, "At least one interface must be provided for IPv6.")

        // sockets
        self.ipMode = ipMode
        let socketDelegateQueue = DispatchQueue(label: "com.danielmurfin.sACNKit.sourceSocketDelegate")
        self.socketDelegateQueue = socketDelegateQueue
        self.socketsShouldTerminate = [:]
        if interfaces.isEmpty {
            let socket = ComponentSocket(type: .transmit, ipMode: ipMode, delegateQueue: socketDelegateQueue)
            self.sockets = ["": socket]
        } else {
            self.sockets = interfaces.reduce(into: [String: ComponentSocket]()) { dict, interface in
                let socket = ComponentSocket(type: .transmit, ipMode: ipMode, delegateQueue: socketDelegateQueue)
                dict[interface] = socket
            }
        }
        self._isListening = false
        self._shouldOutput = false
        
        // delegate
        self.delegateQueue = delegateQueue
        
        // general
        self.cid = cid
        let sourceName = name ?? Source.getDeviceName()
        self.name = sourceName
        self.nameData = Source.buildNameData(from: sourceName)
        self.priority = priority.nearestValidPriority()
        self.shouldTerminate = false
        self.universeNumbers = []
        self.universes = []
        self.rootLayer = RootLayer.createAsData(vector: .data, cid: cid)
        self.universeDiscoveryMessages = []

        // timers
        self.timerQueue = DispatchQueue(label: "com.danielmurfin.sACNKit.sourceTimerQueue.\(cid.uuidString)")
    }
    
    deinit {
        stop()
    }
        
    // MARK: Public API
    
    /// Starts this source.
    ///
    /// The source will begin transmitting sACN Universe Discovery and Data messages, dependent
    /// on the state of `shouldOutput`. This may be useful for backup scenarios to ensure the source
    /// is ready to output as soon as required.
    ///
    /// - Parameters:
    ///    - shouldOutput: Optional: Whether this source should output (defaults to `true`).
    ///
    /// - Throws: An error of type `sACNSourceValidationError` or `sACNComponentSocketError`.
    ///
    public func start(shouldOutput: Bool = true) throws {
        try socketDelegateQueue.sync {
            guard !_isListening else {
                throw sACNSourceValidationError.sourceStarted
            }
            
            universes.forEach { $0.reset() }
            delegateTransmissionState = nil
            socketsShouldTerminate = [:]

            // begin listening
            try sockets.forEach { interface, socket in
                try listenForSocket(socket, on: interface.isEmpty ? nil : interface)
            }
            self._isListening = true
            self._shouldOutput = shouldOutput
            
            // start heartbeats
            startDataTransmit()
            startUniverseDiscovery()
            
            if delegateTransmissionState != true && !universes.isEmpty {
                delegateTransmissionState = true
                delegateQueue.async {
                    self.delegate?.transmissionStarted()
                }
            }
        }
    }
    
    /// Stops this source.
    ///
    /// When stopped, this source will no longer transmit sACN messages.
    ///
    public func stop() {
        socketDelegateQueue.sync {
            guard _isListening else { return }
            self._isListening = false
            
            // stops heartbeats
            stopUniverseDiscovery()
            stopDataTransmit()
            
            // stop listening on socket occurs after
            // final termination is sent
        }
    }
    
    /// Updates the interfaces on which this source transmits for sACN Universe Discovery and Data messages.
    ///
    /// - Parameters:
    ///    - interfaces: The new interfaces for this source. An interface may be a name (e.g. "en1" or "lo0") or the corresponding IP address (e.g. "192.168.4.35").
    ///    Empty interfaces means receive on all interfaces (IPv4 only).
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interfaces must not be empty.
    ///
    /// - Throws: An error of type `sACNComponentSocketError`.
    /// 
    public func updateInterfaces(_ newInterfaces: Set<String> = []) throws {
        precondition(!ipMode.usesIPv6() || !newInterfaces.isEmpty, "At least one interface must be provided for IPv6.")
        
        try socketDelegateQueue.sync { [self] in
            let existingInterfaces = {
                if let firstSocket = sockets.first, firstSocket.key.isEmpty {
                    return Set<String>()
                } else {
                    return Set(sockets.keys)
                }
            }()
            guard existingInterfaces != newInterfaces else { return }
            
            if existingInterfaces.isEmpty {
                // not possible for IPv6
                
                // terminate all universes on existing sockets, removing the sockets but not the universes
                let socketIds = sockets.reduce(into: [String: Bool]()) { dict, socket in
                    dict[socket.key] = true
                }
                socketsShouldTerminate = socketIds
                universes.forEach { universe in
                    universe.terminateSockets()
                }

                // add each new interfaces
                for interface in newInterfaces {
                    let socket = ComponentSocket(type: .transmit, ipMode: ipMode, delegateQueue: socketDelegateQueue)
                    sockets[interface] = socket
                    socketsShouldTerminate.removeValue(forKey: interface)
                    
                    // attempt to listen
                    if _isListening {
                        try listenForSocket(socket, on: interface)
                    }
                }
            } else if newInterfaces.isEmpty {
                // not possible for IPv6
                
                // terminate all universes on existing sockets, removing the sockets but not the universes
                let socketIds = sockets.reduce(into: [String: Bool]()) { dict, socket in
                    dict[socket.key] = true
                }
                socketsShouldTerminate = socketIds
                universes.forEach { universe in
                    universe.terminateSockets()
                }
                
                // add socket for all interfaces
                let socket = ComponentSocket(type: .transmit, ipMode: ipMode, delegateQueue: socketDelegateQueue)
                sockets[""] = socket
                socketsShouldTerminate.removeValue(forKey: "")

                // attempt to listen
                if _isListening {
                    try listenForSocket(socket)
                }
            } else {
                let interfacesToRemove = existingInterfaces.subtracting(newInterfaces)
                let interfacesToAdd = newInterfaces.subtracting(existingInterfaces)
                
                // terminate all universes on sockets no longer needed, removing the sockets but not the universes
                let socketsToRemove = sockets.filter { interfacesToRemove.contains($0.key) }
                if !socketsToRemove.isEmpty {
                    let socketIds = socketsToRemove.reduce(into: [String: Bool]()) { dict, socket in
                        dict[socket.key] = true
                    }
                    socketsShouldTerminate = socketIds
                    universes.forEach { universe in
                        universe.terminateSockets()
                    }
                }
                
                // add each new interface
                var newSocketIds: [UUID] = []
                for interface in interfacesToAdd {
                    let socket = ComponentSocket(type: .transmit, ipMode: ipMode, delegateQueue: socketDelegateQueue)
                    sockets[interface] = socket
                    newSocketIds.append(socket.id)
                    socketsShouldTerminate.removeValue(forKey: interface)

                    // attempt to listen
                    if _isListening {
                        try listenForSocket(socket, on: interface)
                    }
                }
            }
        }
        
    }
    
    /// Adds a new universe to this source.
    ///
    /// If a universe with this number already exists, this universe will not be added.
    ///
    /// - Parameters:
    ///    - universe: The universe to add.
    ///
    /// - Throws: An error of type `sACNSourceValidationError`.
    ///
    public func addUniverse(_ universe: sACNSourceUniverse) throws {
        try socketDelegateQueue.sync {
            guard !shouldTerminate else {
                throw sACNSourceValidationError.sourceTerminating
            }
                        
            guard !universeNumbers.contains(universe.number) else {
                throw sACNSourceValidationError.universeExists
            }
            
            let internalUniverse = SourceUniverse(with: universe, sourcePriority: self.priority, nameData: self.nameData)
            self.universes.append(internalUniverse)
            self.universeNumbers.append(universe.number)
            self.universeNumbers.sort()
            
            if _isListening && delegateTransmissionState != true {
                delegateTransmissionState = true
                delegateQueue.async {
                    self.delegate?.transmissionStarted()
                }
            }
            
            updateUniverseDiscoveryMessages()
        }
    }
    
    /// Removes an existing universe with the number provided.
    ///
    /// - Parameters:
    ///    - number: The universe number to be removed.
    ///
    /// - Throws: An error of type `sACNSourceValidationError`.
    ///
    public func removeUniverse(with number: UInt16) throws {
        try socketDelegateQueue.sync {
            guard universeNumbers.contains(number) else {
                throw sACNSourceValidationError.universeDoesNotExist
            }
            
            if _isListening {
                if let internalUniverse = universes.first(where: { $0.number == number }) {
                    // terminate this universe on all sockets, removing the universe, but keeping the sockets
                    let socketIds = sockets.reduce(into: [String: Bool]()) { dict, socket in
                        dict[socket.key] = false
                    }
                    socketsShouldTerminate = socketIds
                    internalUniverse.terminate(remove: true)
                }
            } else {
                universes.removeAll(where: { $0.number == number })
                universeNumbers.removeAll(where: { $0 == number })
            }
            
            updateUniverseDiscoveryMessages()
        }
    }
    
    /// Updates the human-readable name of this source.
    ///
    /// - Parameters:
    ///    - name: A human-readable name for this source.
    ///
    public func update(name: String) {
        socketDelegateQueue.sync {
            self.name = name
            
            // rebuild all messages and layers dependent on name data
            updateUniverseDiscoveryMessages()
            updateDataFramingLayers()
        }
    }
    
    /// Updates the priority of this source.
    ///
    /// - Parameters:
    ///    - priority: A new priority for this source (values permitted 0-200).
    ///
    public func update(priority: UInt8) {
        socketDelegateQueue.sync {
            let validPriority = priority.nearestValidPriority()
            self.priority = validPriority
        
            updateDataFramingLayers()
        }
    }
    
    /// Updates an existing universe using the per-packet priority, levels and optionally per-slot priorities of an existing `sACNUniverse`.
    ///
    /// Values will be checked to see if changes require output changes.
    /// It is safe to send the same values without impacting output adversely.
    ///
    ///  - parameters:
    ///     - universe: An `sACNSourceUniverse`.
    ///
    ///  - Throws: An error of type `sACNSourceValidationError`.
    ///
    public func updateLevels(with universe: sACNSourceUniverse) throws {
        try socketDelegateQueue.sync {
            let internalUniverse = self.universes.first(where: { $0.number == universe.number })
            guard let internalUniverse = internalUniverse else {
                throw sACNSourceValidationError.universeDoesNotExist
            }
            
            guard !_isListening || !internalUniverse.removeAfterTerminate else {
                throw sACNSourceValidationError.universeTerminating
            }
            
            try internalUniverse.update(with: universe, sourceActive: _isListening)
        }
    }
    
    /// Updates an existing universe with levels.
    ///
    /// Values will be checked to see if changes require output changes.
    /// It is safe to send the same values without impacting output adversely.
    ///
    ///  - Parameters:
    ///     - levels: The new levels (512).
    ///     - universeNumber: The universe number to update.
    ///
    ///  - Throws: An error of type `sACNSourceValidationError`.
    ///
    public func updateLevels(_ levels: [UInt8], in universeNumber: UInt16) throws {
        try socketDelegateQueue.sync {
            let internalUniverse = self.universes.first(where: { $0.number == universeNumber })
            guard let internalUniverse = internalUniverse else {
                throw sACNSourceValidationError.universeDoesNotExist
            }
            
            guard !_isListening || !internalUniverse.removeAfterTerminate else {
                throw sACNSourceValidationError.universeTerminating
            }
            
            try internalUniverse.update(levels: levels, sourceActive: _isListening)
        }
    }
    
    /// Updates an existing universe with per-slot priorities.
    ///
    /// If `nil` is passed to `priorities`, this source will no longer output
    /// per-slot priority.
    ///
    /// Values will be checked to see if changes require output changes.
    /// It is safe to send the same values without impacting output adversely.
    ///
    ///  - Parameters:
    ///     - priorities: Optional new per-slot priorities (512).
    ///     - universeNumber: The universe number to update.
    ///
    ///  - Throws: An error of type `sACNSourceValidationError`.
    ///
    public func updatePriorities(_ priorities: [UInt8]?, in universeNumber: UInt16) throws {
        try socketDelegateQueue.sync {
            let internalUniverse = self.universes.first(where: { $0.number == universeNumber })
            guard let internalUniverse = internalUniverse else {
                throw sACNSourceValidationError.universeDoesNotExist
            }
            
            guard !_isListening || !internalUniverse.removeAfterTerminate else {
                throw sACNSourceValidationError.universeTerminating
            }
            
            try internalUniverse.update(priorities: priorities, sourceActive: _isListening)
        }
    }
    
    /// Updates a slot of an existing universe with a level and optionally per-slot priority.
    ///
    /// Values will be checked to see if changes require output changes.
    /// It is safe to send the same values without impacting output adversely.
    ///
    /// If a priority is provided it will only be processed if per-slot priorities have previously been added using the
    /// `addUniverse`, or `updateLevels(:sACNSourceUniverse)` methods
    ///
    ///  - parameters:
    ///     - slot: The slot to update (0-511).
    ///     - universeNumber: The universe number to update.
    ///     - level: The level for this slot.
    ///     - priority: Optional: An optional per-slot priority for this slot.
    ///
    ///  - Throws: An error of type `sACNSourceValidationError`.
    ///
    public func updateSlot(slot: Int, in universeNumber: UInt16, level: UInt8, priority: UInt8? = nil) throws {
        try socketDelegateQueue.sync {
            let internalUniverse = self.universes.first(where: { $0.number == universeNumber })
            guard let internalUniverse = internalUniverse else {
                throw sACNSourceValidationError.universeDoesNotExist
            }
            
            guard !_isListening || !internalUniverse.removeAfterTerminate else {
                throw sACNSourceValidationError.universeTerminating
            }
            
            try internalUniverse.update(slot: slot, level: level, priority: priority, sourceActive: _isListening)
        }
    }
    
    /// Updates a slot of an existing universe with a per-slot priority.
    ///
    /// Values will be checked to see if changes require output changes.
    /// It is safe to send the same values without impacting output adversely.
    ///
    /// If a priority is provided it will only be processed if per-slot priorities have previously been added using the
    /// `addUniverse`, or `updateLevels(:sACNSourceUniverse)` methods
    ///
    ///  - parameters:
    ///     - slot: The slot to update (0-511).
    ///     - universeNumber: The universe number to update.
    ///     - priority: The per-slot priority for this slot.
    ///
    ///  - Throws: An error of type `sACNSourceValidationError`.
    ///
    public func updateSlot(slot: Int, in universeNumber: UInt16, priority: UInt8) throws {
        try socketDelegateQueue.sync {
            let internalUniverse = self.universes.first(where: { $0.number == universeNumber })
            guard let internalUniverse = internalUniverse else {
                throw sACNSourceValidationError.universeDoesNotExist
            }
            
            guard !_isListening || !internalUniverse.removeAfterTerminate else {
                throw sACNSourceValidationError.universeTerminating
            }
            
            try internalUniverse.update(slot: slot, priority: priority, sourceActive: _isListening)
        }
    }
    
    // MARK: General
    
    /// Attempts to start listening for a socket on an optional interface.
    ///
    /// - Parameters:
    ///    - socket: The socket to start listening.
    ///    - interface: Optional: An optional interface on which to listen (`nil` means all interfaces).
    ///
    /// - Throws: An error of type `sACNComponentSocketError`.
    ///
    private func listenForSocket(_ socket: ComponentSocket, on interface: String? = nil) throws {
        socket.delegate = self
        try socket.startListening(onInterface: interface)
    }

    // MARK: Timers / Messaging
    
    /// Starts this source's universe discovery timer.
    private func startUniverseDiscovery() {
        timerQueue.async { [self] in
            // send a discovery message straight away
            self.socketDelegateQueue.async {
                self.sendUniverseDiscoveryMessage()
            }
            
            let timer = DispatchSource.repeatingTimer(interval: Self.universeDiscoveryInterval, leeway: Self.timingLeeway, queue: timerQueue) { [weak self] in
                if let _ = self?.universeDiscoveryTimer {
                    self?.socketDelegateQueue.async {
                        self?.sendUniverseDiscoveryMessage()
                    }
                }
            }
            universeDiscoveryTimer = timer
        }
    }
    
    /// Stops this source's universe discovery heartbeat.
    private func stopUniverseDiscovery() {
        timerQueue.sync {
            universeDiscoveryTimer?.cancel()
            universeDiscoveryTimer = nil
        }
    }
    
    /// Starts this source's data transmission heartbeat.
    private func startDataTransmit() {
        timerQueue.async { [self] in
            let timer = DispatchSource.repeatingTimer(interval: Self.dataTransmitInterval, leeway: Self.timingLeeway, queue: timerQueue) { [weak self] in
                if let _ = self?.dataTransmitTimer {
                    self?.socketDelegateQueue.async {
                        self?.sendDataMessages()
                    }
                }
            }
            dataTransmitTimer = timer
        }
    }
    
    /// Stops this source's data transmission for all sockets.
    private func stopDataTransmit() {
        shouldTerminate = true
        let socketIds = sockets.reduce(into: [String: Bool]()) { dict, socket in
            dict[socket.key] = false
        }
        socketsShouldTerminate = socketIds
        // terminate all universes on all sockets, but keep the sockets and universes present
        universes.forEach { $0.terminate(remove: false) }
    }

    /// Sends the Universe Discovery messages for this source.
    private func sendUniverseDiscoveryMessage() {
        guard _shouldOutput else { return }
        
        sockets.forEach { interface, socket in
            for message in universeDiscoveryMessages {
                if ipMode.usesIPv4() {
                    socket.send(message: message, host: IPv4.universeDiscoveryHostname, port: UDP.sdtPort)
                }
                if ipMode.usesIPv6() {
                    socket.send(message: message, host: IPv6.universeDiscoveryHostname, port: UDP.sdtPort)
                }
            }
        }
        
        delegateQueue.async { self.debugDelegate?.debugLog("Sending universe discovery message(s) multicast") }
    }
    
    // MARK: Build and Update Data
    
    /// Builds and updates the universe discovery messages for this source.
    private func updateUniverseDiscoveryMessages() {
        let univCount = universeNumbers.count
        let univMax = UniverseDiscoveryLayer.maxUniverseNumbers
        
        // how many pages are required (must be capped at max pages even if more exist)
        let pageCount = min((univCount / univMax) + (univCount % univMax == 0 ? 0 : 1 ), Int(UInt8.max))
        
        var pages = [Data]()
        for page in 0..<pageCount {
            let first = page*univMax
            let last = min(first+univMax, univCount)
            let pageUniverseNumbers = Array(universeNumbers[first..<last])
            
            // layers
            var rootLayer = RootLayer.createAsData(vector: .extended, cid: cid)
            var framingLayer = UniverseDiscoveryFramingLayer.createAsData(nameData: nameData)
            let universeDiscoveryLayer = UniverseDiscoveryLayer.createAsData(page: UInt8(page), lastPage: UInt8(pageCount-1), universeList: pageUniverseNumbers)

            // calculate and insert framing layer length
            let framingLayerLength: UInt16 =  UInt16(framingLayer.count + universeDiscoveryLayer.count)
            framingLayer.replacingUniverseDiscoveryFramingFlagsAndLength(with: framingLayerLength)
            
            // calculate and insert root layer length
            let rootLayerLength: UInt16 = UInt16(rootLayer.count + framingLayer.count + universeDiscoveryLayer.count - RootLayer.lengthCountOffset)
            rootLayer.replacingRootLayerFlagsAndLength(with: rootLayerLength)
            
            pages.append(rootLayer + framingLayer + universeDiscoveryLayer)
        }
        
        self.universeDiscoveryMessages = pages
    }
    
    /// Builds and updates the data framing layers for all universes of this source.
    private func updateDataFramingLayers() {
        for (index, _) in universes.enumerated() {
            universes[index].updateFramingLayer(withSourcePriority: self.priority, nameData: self.nameData)
        }
    }
    
}

// MARK: -
// MARK: -

/// sACN Source Extension
///
/// Extensions to `sACNSource` to handle message creation and transmission.
///
private extension sACNSource {
    
    /// Sends the data messages for this source.
    private func sendDataMessages() {
        guard _shouldOutput else { return }

        // remove all universes which are full terminated and should be removed
        let universesToRemove = universes.filter { $0.removeAfterTerminate && $0.shouldTerminate && $0.dirtyCounter < 1 }
        let universesReadyForSocketRemoval = universes.filter { $0.pendingSocketRemoval && $0.dirtyCounter < 1 }
        self.universes.removeAll(where: { universesToRemove.contains($0) })
        self.universeNumbers.removeAll(where: { universesToRemove.map { universe in universe.number }.contains($0) })
        
        let activeUniverses = universes.filter { !$0.shouldTerminate || $0.dirtyCounter > 0 }
        
        if activeUniverses.isEmpty {
            // notify transmission ended (once)
            if delegateTransmissionState != false {
                delegateTransmissionState = false
                delegateQueue.async {
                    self.delegate?.transmissionEnded()
                }
            }
            
            // termination of all universes to be removed is complete
            if self.shouldTerminate {
                // the source should terminate
                timerQueue.sync {
                    dataTransmitTimer?.cancel()
                    dataTransmitTimer = nil
                }
                
                sockets.forEach { _, socket in
                    socket.stopListening()
                }
                
                // the source is now terminated
                shouldTerminate = false
                _isListening = false
            }
            return
        } else if !universesToRemove.isEmpty && !socketsShouldTerminate.isEmpty {
            // not all universes were removed, but some were and there may be sockets which should terminate
            socketsShouldTerminate.forEach { interface, remove in
                if remove {
                    // deinit first stops listening
                    sockets.removeValue(forKey: interface)
                }
            }
            socketsShouldTerminate.removeAll()
        } else if !universesReadyForSocketRemoval.isEmpty && !socketsShouldTerminate.isEmpty {
            // all universes are ready for socket removal
            socketsShouldTerminate.forEach { interface, remove in
                if remove {
                    // deinit first stops listening
                    sockets.removeValue(forKey: interface)
                }
            }
            socketsShouldTerminate.removeAll()
            universesReadyForSocketRemoval.forEach { $0.terminateSocketsComplete() }
        }
        
        var universeMessages = [(universeNumber: UInt16, data: Data)]()
        var socketTerminationMessages = [(universeNumber: UInt16, data: Data)]()

        let rootLayer = rootLayer
            
        for (index, _) in activeUniverses.enumerated() {
            let universe = universes[index]
            
            // should levels be sent?
            let sendLevels: Bool
            switch universe.transmitCounter {
            case 0, 11, 22, 33:
                sendLevels = true
            default:
                sendLevels = universe.dirtyCounter > 0 ? true : false
            }
            
            let framingOptions: DataFramingLayer.Options = universe.shouldTerminate ? [.terminated] : .none
            
            // should per-slot priority be sent?
            let sendPriority: Bool
            if !universe.shouldTerminate, universe.priorities != nil {
                sendPriority = universe.dirtyPriority || universe.transmitCounter == 0
            } else {
                sendPriority = false
            }

            if sendLevels {
                var framingLayer = universe.framingLayer
                framingLayer.replacingSequence(with: universe.sequence)
                framingLayer.replacingOptions(with: framingOptions)
                
                let dmpLayer = universe.dmpLevelsLayer

                let levels = rootLayer+framingLayer+dmpLayer
                universeMessages.append((universeNumber: universe.number, data: levels))
                
                if !socketsShouldTerminate.isEmpty {
                    let framingOptions: DataFramingLayer.Options = [.terminated]
                    var framingLayer = universe.framingLayer
                    framingLayer.replacingSequence(with: universe.sequence)
                    framingLayer.replacingOptions(with: framingOptions)
                    let levels = rootLayer+framingLayer+dmpLayer
                    socketTerminationMessages.append((universeNumber: universe.number, data: levels))
                }
                
                universe.incrementSequence()
                universe.decrementDirty()
            }
            
            if sendPriority {
                var framingLayer = universe.framingLayer
                framingLayer.replacingSequence(with: universe.sequence)
                framingLayer.replacingOptions(with: framingOptions)
                
                let dmpLayer = universe.dmpPrioritiesLayer

                let priorities = rootLayer+framingLayer+dmpLayer
                universeMessages.append((universeNumber: universe.number, data: priorities))
                
                universe.incrementSequence()
                universe.prioritySent()
            }
            
            universe.incrementCounter()
        }
        
        sockets.forEach { interface, socket in
            let messages = socketsShouldTerminate[interface] != nil ? socketTerminationMessages : universeMessages
            for universeMessage in messages {
                if ipMode.usesIPv4() {
                    let hostname = IPv4.multicastHostname(for: universeMessage.universeNumber)
                    socket.send(message: universeMessage.data, host: hostname, port: UDP.sdtPort)
                }
                if ipMode.usesIPv6() {
                    let hostname = IPv6.multicastHostname(for: universeMessage.universeNumber)
                    socket.send(message: universeMessage.data, host: hostname, port: UDP.sdtPort)
                }
            }
        }
    }
    
}

/// sACN Source Validation Error
///
/// Enumerates all possible `sACNSource` parsing errors.
///
public enum sACNSourceValidationError: LocalizedError {
    
    /// The source is started.
    case sourceStarted
    
    /// The source is terminating.
    case sourceTerminating
    
    /// The universe is terminating.
    case universeTerminating
    
    /// The universe already exists.
    case universeExists
    
    /// The universe does not exist.
    case universeDoesNotExist
    
    /// There are an incorrect number of levels.
    case incorrectLevelsCount
    
    /// There are an incorrect number of priorities.
    case incorrectPrioritiesCount
    
    /// There are invalid priorities provided.
    case invalidPriorities
    
    /// The slot number is invalid.
    case invalidSlotNumber

    /// A human-readable description of the error useful for logging purposes.
    public var logDescription: String {
        switch self {
        case .sourceStarted:
            return "The source is already started"
        case .sourceTerminating:
            return "The source is terminating"
        case .universeTerminating:
            return "The universe is terminating"
        case .universeExists:
            return "The universe already exists"
        case .universeDoesNotExist:
            return "The universe does not exist"
        case .incorrectLevelsCount:
            return "An incorrect number of levels was provided (must be 512)"
        case .incorrectPrioritiesCount:
            return "An incorrect number of priorities was provided (must be 512)"
        case .invalidPriorities:
            return "Invalid priorities were provided"
        case .invalidSlotNumber:
            return "The slot number is invalid"
        }
    }
        
}

// MARK: -
// MARK: -

/// sACN Source Extension
///
/// `ComponentSocketDelegate` conformance.
extension sACNSource: ComponentSocketDelegate {
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
        // sACN sources do not process messages
    }
    
    /// Called when the socket was closed.
    ///
    /// - Parameters:
    ///    - socket: The socket which was closed.
    ///    - error: An optional error which occured when the socket was closed.
    ///
    func socket(_ socket: ComponentSocket, socketDidCloseWithError error: Error?) {
        guard error != nil, self._isListening else { return }
        delegateQueue.async { self.delegate?.source(self, interface: socket.interface, socketDidCloseWithError: error) }
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
