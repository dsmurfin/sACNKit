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
///
final public class sACNSource {

    /// The queue used for read/write operations.
    static let queue: DispatchQueue = DispatchQueue(label: "com.danielmurfin.sACNKit.sourceQueue", attributes: .concurrent)
    
    /// The queue on which socket notifications occur.
    static let socketDelegateQueue: DispatchQueue = DispatchQueue(label: "com.danielmurfin.sACNKit.sourceSocketDelegateQueue")
    
    /// The universe discovery interval (10 secs).
    static let universeDiscoveryInterval: DispatchTimeInterval = DispatchTimeInterval.interval(10)
    
    /// The data transmit interval (0.227 secs).
    static let dataTransmitInterval: DispatchTimeInterval = DispatchTimeInterval.interval(1/44)
    
    /// The leeway used for timing. Informs the OS how accurate timings should be.
    private static let timingLeeway: DispatchTimeInterval = .nanoseconds(0)

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
    
    /// The Internet Protocol version(s) used by the source.
    private let ipMode: sACNIPMode
    
    // MARK: Socket
    
    /// The interface used for communications.
    public var interface: String? {
        didSet {
            stop()
        }
    }
    
    /// The socket used for communications.
    private let socket: ComponentSocket
    
    /// The isocket listening status (thread-safe getter).
    public var isListening: Bool {
        get { Self.queue.sync { _isListening } }
    }
    
    /// The private socket listening status.
    private var _isListening: Bool
    
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
    
    /// The delegate which receives debug log messages from this producer.
    private weak var debugDelegate: sACNComponentDebugDelegate?

    /// The queue on which to send delegate notifications.
    private let delegateQueue: DispatchQueue
    
    // MARK: Timer
    
    /// The queue on which timers run.
    private let timerQueue: DispatchQueue
    
    /// The timer used to delay execution of functions.
    private  var delayExecutionTimer: DispatchSourceTimer?
    
    // MARK: Universe Discovery
    
    /// The universe discovery timer
    private var universeDiscoveryTimer: DispatchSourceTimer?
    
    /// A pre-compiled universe discovery message as `Data`.
    private var universeDiscoveryMessages: [Data]
    
    // MARK: Data Transmit

    /// The data transmit timer.
    private var dataTransmitTimer: DispatchSourceTimer?
    
    /// A pre-compiled root layer as `Data`.
    private var rootLayer: Data
    
    // MARK: General
    
    /// The default priority for universes added to this source.
    private var priority: UInt8
    
    /// The universe numbers added to this source.
    private var universeNumbers: [UInt16]
    
    /// The universe added to this source which may be transmitted.
    private var universes: [Universe]
    
    /// Whether the source should terminate.
    private var shouldTerminate: Bool
    
    /// Whether the source should resume after termination.
    private var shouldResume: Bool
    
    // MARK: - Initialization

    /// Creates a new source using a name, interface and delegate queue, and optionally a CID, IP Mode, Priority.
    ///
    ///  The CID of an sACN source should persist across launches, so should be stored in persistent storage.
    ///
    /// - Parameters:
    ///    - name: Optional: An optional human readable name of this source.
    ///    - cid: Optional: CID for this source.
    ///    - ipMode: Optional: IP mode for this source (IPv4/IPv6/Both).
    ///    - interface: The network interface for this source. The interface may be a name (e.g. "en1" or "lo0") or the corresponding IP address (e.g. "192.168.4.35").
    ///    - priority: Optional: Default priority for this source, used when universes do not have explicit priorities (values permitted 0-200).
    ///    - delegateQueue: A delegate queue on which to receive delegate calls from this source.
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interface must not be nil.
    ///
    public init(name: String? = nil, cid: UUID = UUID(), ipMode: sACNIPMode = .ipv4Only, interface: String?, priority: UInt8 = 100, delegateQueue: DispatchQueue) {
        precondition(!ipMode.usesIPv6() || interface != nil, "An interface must be provided for IPv6.")

        self.cid = cid
        let sourceName = name ?? Source.getDeviceName()
        self.name = sourceName
        self.nameData = Source.buildNameData(from: sourceName)
        self.ipMode = ipMode
        self.interface = interface
        self.socket = ComponentSocket(cid: cid, type: .transmit, ipMode: ipMode, delegateQueue: Self.socketDelegateQueue)
        self._isListening = false
        self.delegateQueue = delegateQueue
        self.timerQueue = DispatchQueue(label: "com.danielmurfin.sACNKit.sourceTimerQueue.\(cid.uuidString)")
        self.universeDiscoveryMessages = []
        self.rootLayer = RootLayer.createAsData(vector: .data, cid: cid)
        self.priority = priority.nearestValidPriority()
        self.universeNumbers = []
        self.universes = []
        self.shouldTerminate = false
        self.shouldResume = false
    }
    
    deinit {
        stop()
    }
        
    // MARK: - Public API
    
    /// Starts this source.
    ///
    /// The source will begin transmitting sACN Universe Discovery and Data messages.
    ///
    /// - Throws: An error of type `ComponentSocketError`.
    ///
    public func start() throws {
        guard !isListening else {
            throw sACNSourceValidationError.sourceStarted
        }
        
        Self.queue.sync(flags: .barrier) {
            if self.shouldTerminate {
                self.shouldResume = true
                return
            }
        }
        
        socket.delegate = self

        // begin listening
        try socket.startListening(onInterface: self.interface)
        Self.queue.sync(flags: .barrier) {
            self._isListening = true
        }
        
        // start heartbeats
        startDataTransmit()
        startUniverseDiscovery()
    }
    
    /// Stops this source.
    ///
    /// When stopped, this source will no longer transmit sACN messages.
    ///
    public func stop() {
        guard isListening else { return }
        
        // stops heartbeats
        stopUniverseDiscovery()
        stopDataTransmit()
        
        // stop listening on socket occurs after
        // final termination is sent
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
    public func addUniverse(_ universe: sACNUniverse) throws {
        let shouldTerminate = Self.queue.sync { self.shouldTerminate }
        
        guard !shouldTerminate else {
            throw sACNSourceValidationError.universeExists
        }
        
        let universeNumbers = Self.queue.sync { self.universeNumbers }

        guard !universeNumbers.contains(universe.number) else {
            throw sACNSourceValidationError.universeExists
        }
        
        Self.queue.sync(flags: .barrier) {
            let internalUniverse = Universe(with: universe, sourcePriority: self.priority, nameData: self.nameData)
            self.universes.append(internalUniverse)
            self.universeNumbers.append(universe.number)
            self.universeNumbers.sort()
            
            if universeNumbers.count == 1 {
                delegateQueue.async {
                    self.delegate?.transmissionStarted()
                }
            }
        }
        
        updateUniverseDiscoveryMessages()
    }
    
    /// Removes an existing universe with the number provided.
    ///
    /// - Parameters:
    ///    - number: The universe number to be removed.
    ///
    /// - Throws: An error of type `sACNSourceValidationError`.
    ///
    public func removeUniverse(with number: UInt16) throws {
        let universeNumbers = Self.queue.sync { self.universeNumbers }

        guard universeNumbers.contains(number) else {
            throw sACNSourceValidationError.universeDoesNotExist
        }
        
        Self.queue.sync(flags: .barrier) {
            let internalUniverse = self.universes.first(where: { $0.number == number })
            internalUniverse?.terminate()
        }
        
        updateUniverseDiscoveryMessages()
    }
    
    /// Updates the human-readable name of this source.
    ///
    /// - Parameters:
    ///    - name: A human-readable name for this source.
    ///
    public func update(name: String) {
        Self.queue.sync(flags: .barrier) {
            self.name = name
        }
        
        // rebuild all messages and layers dependent on name data
        updateUniverseDiscoveryMessages()
        updateDataFramingLayers()
    }
    
    /// Updates the priority of this source.
    ///
    /// - Parameters:
    ///    - priority: A new priority for this source (values permitted 0-200).
    ///
    public func update(priority: UInt8) {
        let validPriority = priority.nearestValidPriority()
        Self.queue.sync(flags: .barrier) {
            self.priority = validPriority
        }
        
        updateDataFramingLayers()
    }
    
    /// Updates an existing universe using the per-packet priority, levels and optionally per-slot priorities of an existing `sACNUniverse`.
    ///
    /// Values will be checked to see if changes require output changes.
    /// It is safe to send the same values without impacting output adversely.
    ///
    ///  - parameters:
    ///     - universe: An `sACNUniverse`.
    ///
    ///  - Throws: An error of type `sACNSourceValidationError`.
    ///
    public func updateLevels(with universe: sACNUniverse) throws {
        let internalUniverse = Self.queue.sync { self.universes.first(where: { $0.number == universe.number }) }
        guard let internalUniverse = internalUniverse else {
            throw sACNSourceValidationError.universeDoesNotExist
        }
        guard !internalUniverse.shouldTerminate else {
            throw sACNSourceValidationError.universeTerminating
        }
        
        try Self.queue.sync(flags: .barrier) {
            try internalUniverse.update(with: universe)
        }
    }
    
    /// Updates a slot of an existing universe with a level and optionally per-slot priority.
    ///
    /// Values will be checked to see if changes require output changes.
    /// It is safe to send the same values without impacting output adversely.
    ///
    /// If a priority is provided it will only be processed if per-slot priorities have previously been added using the
    /// `addUniverse`, or `updateLevels` methods
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
        let internalUniverse = Self.queue.sync { self.universes.first(where: { $0.number == universeNumber }) }
        guard let internalUniverse = internalUniverse else {
            throw sACNSourceValidationError.universeDoesNotExist
        }
        guard !internalUniverse.shouldTerminate else {
            throw sACNSourceValidationError.universeTerminating
        }
        
        try Self.queue.sync(flags: .barrier) {
            let internalUniverse = self.universes.first(where: { $0.number == universeNumber })
            try internalUniverse?.update(slot: slot, level: level, priority: priority)
        }
    }

    // MARK: - Timers / Messaging
    
    /// Starts this source's universe discovery timer.
    private func startUniverseDiscovery() {
        timerQueue.sync {
            let timer = DispatchSource.repeatingTimer(interval: Self.universeDiscoveryInterval, leeway: Self.timingLeeway, queue: timerQueue) { [weak self] in
                if let _ = self?.universeDiscoveryTimer {
                    self?.sendUniverseDiscoveryMessage()
                }
            }
            universeDiscoveryTimer = timer
        }
    }
    
    /// Stops this source's universe discovery heartbeat.
    private func stopUniverseDiscovery() {
        timerQueue.sync { universeDiscoveryTimer = nil }
    }
    
    /// Starts this source's data transmission heartbeat.
    private func startDataTransmit() {
        timerQueue.sync {
            let timer = DispatchSource.repeatingTimer(interval: Self.dataTransmitInterval, leeway: Self.timingLeeway, queue: timerQueue) { [weak self] in
                if let _ = self?.dataTransmitTimer {
                    self?.sendDataMessages()
                }
            }
            dataTransmitTimer = timer
        }
    }
    
    /// Stops this source's data transmission.
    private func stopDataTransmit() {
        Self.queue.sync(flags: .barrier) {
            self.shouldTerminate = true
            self.universes.forEach { $0.terminate() }
        }
    }

    /// Sends the Universe Discovery messages for this source.
    private func sendUniverseDiscoveryMessage() {
        let theUniverseDiscoveryMessages = Self.queue.sync { self.universeDiscoveryMessages }
        guard !theUniverseDiscoveryMessages.isEmpty else { return }

        for message in theUniverseDiscoveryMessages {
            if ipMode.usesIPv4() {
                socket.send(message: message, host: IPv4.universeDiscoveryHostname, port: UDP.sdtPort)
            }
            if ipMode.usesIPv6() {
                socket.send(message: message, host: IPv6.universeDiscoveryHostname, port: UDP.sdtPort)
            }
        }
        
        delegateQueue.async { self.debugDelegate?.debugLog("Sending universe discovery message(s) multicast") }
    }
    
    /// Delays the execution of a closure.
    ///
    /// - Parameters:
    ///    - interval: The number of milliseconds to delay the execution.
    ///    - completion: The closure to be executed on completion.
    ///
    private func delayExecution(by interval: Int, completion: @escaping () -> Void) {
        timerQueue.sync {
            let timer = DispatchSource.singleTimer(interval: .milliseconds(interval), leeway: Self.timingLeeway, queue: timerQueue) { [weak self] in
                if let _ = self?.delayExecutionTimer {
                    completion()
                }
            }
            delayExecutionTimer = timer
        }
    }
    
    /// Stops this source's delayed execution timer.
    private func stopDelayExecution() {
        timerQueue.sync { delayExecutionTimer = nil }
    }
    
    // MARK: - Build and Update Data
    
    /// Builds and updates the universe discovery messages for this source.
    func updateUniverseDiscoveryMessages() {
        let cid = Self.queue.sync { self.cid }
        let nameData = Self.queue.sync { self.nameData }
        let universeNumbers = Self.queue.sync { self.universeNumbers }

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
        
        Self.queue.sync(flags: .barrier) {
            self.universeDiscoveryMessages = pages
        }
    }
    
    /// Builds and updates the data framing layers for all universes of this source.
    func updateDataFramingLayers() {
        Self.queue.sync(flags: .barrier) {
            for (index, _) in universes.enumerated() {
                universes[index].updateFramingLayer(withSourcePriority: self.priority, nameData: self.nameData)
            }
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
        // remove all fully terminated universes
        Self.queue.sync(flags: .barrier) {
            let universesToRemove = universes.filter { $0.shouldTerminate && $0.dirtyCounter < 1 }
            let countToRemove = universesToRemove.count
            
            self.universes.removeAll(where: { universesToRemove.contains($0) })
            self.universeNumbers.removeAll(where: { universesToRemove.map { universe in universe.number }.contains($0) })
                
            // termination of all universes is complete
            if self.universes.isEmpty {
                if countToRemove > 0 {
                    delegateQueue.async {
                        self.delegate?.transmissionEnded()
                    }
                }
                if self.shouldTerminate {
                    // the source should terminate
                    dataTransmitTimer = nil
                    socket.stopListening()
                    
                    // the source is now terminated
                    self.shouldTerminate = false
                    
                    if self.shouldResume {
                        DispatchQueue.main.async {
                            try? self.start()
                        }
                    }
                }
                return
            }
        }

        var universeMessages = [(universeNumber: UInt16, data: Data)]()
        Self.queue.sync(flags: .barrier) {
            let rootLayer = self.rootLayer

            for (index, _) in universes.enumerated() {
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
        }

        for universeMessage in universeMessages {
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
    var logDescription: String {
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

/// Component Socket Delegate
///
/// Required methods for objects implementing this delegate.
///
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
        Self.queue.sync(flags: .barrier) {
            self._isListening = false
        }
        delegateQueue.async { self.delegate?.source(self, socketDidCloseWithError: error) }
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

// MARK: -
// MARK: -

/// sACN Source Delegate
///
/// Required methods for objects implementing this delegate.
///
public protocol sACNSourceDelegate: AnyObject {
    /// Called when the socket was closed for this source.
    ///
    /// - Parameters:
    ///    - source: The source for which the socket was closed.
    ///    - error: An optional error which occured when the socket was closed.
    ///
    func source(_ source: sACNSource, socketDidCloseWithError error: Error?)
    
    /// Notifies the delegate that the source is actively transmitting universe data messages.
    func transmissionStarted()
    
    /// Notifies the delegate that the source has stopped transmitting universe data messages.
    /// Note: This does not indicate that the source is stopped, it could simply be no universes have been added.
    func transmissionEnded()
}
