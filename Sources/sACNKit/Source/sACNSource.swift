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

/// sACN Source
///
/// An E1.31-2018 sACN Source which Transmits sACN Messages.
///
/// A `sACNSource` is an `actor` isolated to an internal `sACNRuntime` (the shared NIO event loop). Its
/// lifecycle and mutation API are `async`; lifecycle events (transmission started/ended, socket closed)
/// are delivered on the `events` `AsyncStream` and debug logs on the separate `debugLog` stream, rather
/// than via a delegate.
public actor sACNSource {

    typealias UniverseData = (universeNumber: UInt16, data: Data)

    // MARK: Runtime / isolation

    /// The runtime hosting this actor's isolation, timers, and sockets.
    nonisolated let runtime: sACNRuntime

    /// Pins this actor to the runtime's serial executor (the shared NIO event loop). This is what lets the
    /// transport deliver into the actor's isolation synchronously (`assumeIsolated` from a loop callback,
    /// no `Task` hop) and why the platform floor is macOS 15 / iOS 18 - see `EventLoopSerialExecutor`.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        runtime.serialExecutor.asUnownedSerialExecutor()
    }

    // MARK: Events

    /// An event emitted by a source.
    public enum Event: Sendable {

        /// The source began actively transmitting universe data.
        case transmissionStarted

        /// The source stopped transmitting universe data.
        case transmissionEnded

        /// A socket closed with an error (per interface).
        case socketClosed(interface: String?, reason: SocketCloseReason)

    }

    /// The broadcast hub backing `events`.
    private nonisolated let eventsHub = AsyncStreamHub<Event>(bufferingPolicy: .bufferingNewest(64))

    /// A stream of source lifecycle events.
    ///
    /// Each access returns an independent subscription. `transmissionStarted`/`transmissionEnded` are
    /// **edge-triggered** and not replayed, so subscribe **before** calling `start()` to observe the first
    /// `transmissionStarted`; a subscriber attaching afterwards can seed its state from `isTransmitting`.
    /// Debug logs are delivered on the separate `debugLog` stream, so log chatter cannot evict a lifecycle
    /// event from this stream's buffer.
    public nonisolated var events: AsyncStream<Event> { eventsHub.stream() }

    /// The broadcast hub backing `debugLog`.
    private nonisolated let debugLogHub = AsyncStreamHub<String>(bufferingPolicy: .bufferingNewest(64))

    /// A stream of human-readable debug log messages, kept separate from `events` so verbose logging never
    /// competes with lifecycle events for buffer space. Each access returns an independent subscription.
    public nonisolated var debugLog: AsyncStream<String> { debugLogHub.stream() }

    // MARK: Lifecycle

    /// The lifecycle state, reserved synchronously before any `await` so a reentrant call cannot race.
    ///
    /// `.starting`, `.reconfiguring` and `.stopping` are exclusive "busy" reservations that make `start`,
    /// `stop` and `updateInterfaces` mutually exclusive across their suspension points; every mutating
    /// entry point transitions through this.
    private enum Lifecycle {

        case idle, starting, listening, reconfiguring, stopping

    }

    private var lifecycle: Lifecycle = .idle

    /// Whether the source is actively transmitting (sockets live). Derived from `lifecycle` - `.listening`
    /// or `.reconfiguring` - rather than a separate flag, so the two can never desync.
    public var isListening: Bool { lifecycle == .listening || lifecycle == .reconfiguring }

    /// Whether the source is currently transmitting universe data (mirrors the last `transmissionStarted`/
    /// `transmissionEnded` event). Lets a subscriber that attached to `events` after `start()` - and so
    /// missed the edge-triggered `transmissionStarted` - seed its state.
    public var isTransmitting: Bool { transmissionState == true }

    /// A stop requested while `.starting` or `.reconfiguring`: the in-flight operation observes it and
    /// unwinds into the termination drain instead of proceeding.
    private var stopRequested = false

    /// Continuations from `stop()` callers, all resumed when the termination drain reaches `.idle`.
    private var stopContinuations: [CheckedContinuation<Void, Never>] = []

    /// Whether this source should actively output sACN Universe Discovery and Data messages.
    public var shouldOutput: Bool { _shouldOutput }

    private var _shouldOutput = false

    /// Updates whether this source should actively output sACN Universe Discovery and Data messages.
    ///
    /// This may be useful for backup scenarios to ensure the source is ready to output as soon as required.
    /// Calling this before `start()` primes the flag; it is ignored while the source is starting, stopping
    /// or reconfiguring - in particular a `shouldOutput(true)` during the termination drain must not
    /// resurrect terminating universes (which would strand the drain short of idle).
    ///
    /// - Parameters:
    ///    - output: Whether the source should output.
    ///
    public func shouldOutput(_ output: Bool) {
        guard lifecycle == .idle || lifecycle == .listening else { return }
        guard _shouldOutput != output else { return }
        if output {
            universes.forEach { $0.reset() }
        } else {
            universes.forEach { $0.terminate(remove: false) }
        }
        _shouldOutput = output
    }

    // MARK: Sockets

    /// The Internet Protocol version(s) used by the source.
    private let ipMode: sACNIPMode

    /// The interfaces of sockets pending removal once their termination drain completes (membership =
    /// pending removal). Only interface reconfiguration marks sockets here; a full `stop()` does not - the
    /// universes' own `shouldTerminate` drives termination there and the sockets close at teardown, so a
    /// `false`/absent entry would be redundant.
    private var socketsShouldTerminate: Set<String> = []

    /// The sockets used for communications (one per interface, keyed by interface or "" for all).
    private var sockets: [String: ComponentSocket] = [:]

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
    private var shouldTerminate = false

    /// The universe numbers added to this source.
    private var universeNumbers: [UInt16] = []

    /// The universes added to this source which may be transmitted.
    /// Internal read access allows tests to stage transmit states the public API only reaches when listening.
    private(set) var universes: [SourceUniverse] = []

    /// A pre-compiled root layer as `Data`.
    private let rootLayer: Data

    /// A pre-compiled universe discovery message as `Data`.
    private var universeDiscoveryMessages: [Data] = []

    /// The last transmission state emitted on `events`, so started/ended fire once per transition.
    private var transmissionState: Bool?

    // MARK: Timers

    /// The universe discovery interval (10 secs).
    private static let universeDiscoveryInterval: Duration = .seconds(10)

    /// The data transmit interval (~22.7 ms, ~44 fps).
    private static let dataTransmitInterval: Duration = .seconds(1) / 44

    /// The universe discovery timer.
    private var universeDiscoveryTask: (any RuntimeTask)?

    /// The data transmit timer.
    private var dataTransmitTask: (any RuntimeTask)?

    // MARK: - Initialization

    /// Creates a new source using a name and interfaces, and optionally a CID, IP Mode and priority.
    ///
    /// The CID of an sACN source should persist across launches, so should be stored in persistent storage.
    ///
    /// - Parameters:
    ///    - name: Optional: An optional human readable name of this source.
    ///    - cid: Optional: CID for this source.
    ///    - ipMode: Optional: IP mode for this source (IPv4/IPv6/Both).
    ///    - interfaces: Optional: The network interfaces for this source. An interface may be a name (e.g. "en1" or "lo0") or the corresponding IP address (e.g. "192.168.4.35").
    ///    - priority: Optional: Default priority for this source (values permitted 0-200).
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interfaces must not be empty.
    ///
    public init(name: String? = nil, cid: UUID = UUID(), ipMode: sACNIPMode = .ipv4Only, interfaces: Set<String> = [], priority: UInt8 = 100) {
        precondition(!ipMode.usesIPv6() || !interfaces.isEmpty, "At least one interface must be provided for IPv6.")

        let runtime = NIORuntime()
        self.runtime = runtime
        self.ipMode = ipMode
        if interfaces.isEmpty {
            self.sockets = ["": runtime.makeSocket(type: .transmit, ipMode: ipMode, port: 0)]
        } else {
            self.sockets = interfaces.reduce(into: [String: ComponentSocket]()) { dict, interface in
                dict[interface] = runtime.makeSocket(type: .transmit, ipMode: ipMode, port: 0)
            }
        }

        self.cid = cid
        let sourceName = name ?? Source.getDeviceName()
        self.name = sourceName
        self.nameData = Source.buildNameData(from: sourceName)
        self.priority = priority.nearestValidPriority()
        self.rootLayer = RootLayer.createAsData(vector: .data, cid: cid)
    }

    deinit {
        // The timer tasks self-cancel when released; the sockets close on dealloc. Finish the hubs so any
        // active consumers terminate rather than hang.
        eventsHub.finish()
        debugLogHub.finish()
    }

    // MARK: - Public API

    /// Starts this source.
    ///
    /// The source will begin transmitting sACN Universe Discovery and Data messages, dependent on
    /// `shouldOutput`. This may be useful for backup scenarios to ensure the source is ready to output.
    ///
    /// - Parameters:
    ///    - shouldOutput: Optional: Whether this source should output (defaults to `true`).
    ///
    /// - Throws: An error of type `sACNSourceValidationError` or `sACNComponentSocketError`.
    ///
    public func start(shouldOutput: Bool = true) async throws {
        guard lifecycle == .idle else {
            throw sACNSourceValidationError.sourceStarted
        }
        lifecycle = .starting
        stopRequested = false

        universes.forEach { $0.reset() }
        transmissionState = nil
        socketsShouldTerminate = []

        do {
            for (interface, socket) in sockets {
                try await listenForSocket(socket, on: interface.isEmpty ? nil : interface)
                // A `stop()` that interleaved this bind closed the sockets; unwind rather than proceed.
                if stopRequested { throw CancellationError() }
            }
        } catch {
            // Roll back: close anything opened, return to idle, and release any waiting `stop()` caller.
            // No error event is emitted - a `CancellationError` here means a stop superseded the start
            // (via `stopRequested` / the closed sockets), which is not a failure to report.
            sockets.values.forEach { $0.close() }
            reachedIdle()
            throw error
        }

        _shouldOutput = shouldOutput
        lifecycle = .listening

        startDataTransmit()
        startUniverseDiscovery()

        if !universes.isEmpty {
            setTransmitting(true)
        }
    }

    /// Stops this source, suspending until teardown completes.
    ///
    /// When stopped, the source sends its 3 E1.31 termination packets, closes its sockets and returns to
    /// idle; this call **awaits that drain** (~68 ms from `.listening`; immediate when starting or already
    /// idle), so `await stop()` followed by `try await start()` is safe. Concurrent `stop()` callers all
    /// resume together when the drain completes.
    ///
    public func stop() async {
        switch lifecycle {
        case .idle:
            return
        case .starting, .reconfiguring:
            // Supersede the in-flight start/reconfigure: close the sockets (which aborts any in-flight
            // bind) and flag it; that operation observes `stopRequested` and unwinds to idle, resuming us.
            stopRequested = true
            _shouldOutput = false
            sockets.values.forEach { $0.close() }
        case .listening:
            beginTerminationDrain()
        case .stopping:
            break  // a drain is already underway; wait for the same completion below
        }
        // Every non-idle arm resumes here when the drain reaches idle (`reachedIdle`).
        await withCheckedContinuation { stopContinuations.append($0) }
    }

    /// Enters the termination drain from `.listening`: keeps the transmit timer running to push the 3 E1.31
    /// termination packets, after which `sendDataMessages` reaches idle and resumes the `stop()` callers.
    private func beginTerminationDrain() {
        lifecycle = .stopping
        _shouldOutput = false
        stopUniverseDiscovery()
        stopDataTransmit()
    }

    /// Completes the termination drain: returns to idle, clears the drain flags, and resumes every waiting
    /// `stop()` caller. Called from the `sendDataMessages` teardown and from `start()`'s stop-superseded
    /// rollback - the two paths that reach idle.
    private func reachedIdle() {
        lifecycle = .idle
        shouldTerminate = false
        stopRequested = false
        let continuations = stopContinuations
        stopContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    /// Sets the transmission state and emits the matching edge event once per transition. The single owner
    /// of `transmissionState`, so every start/resume/stop edge - including output resuming via
    /// `shouldOutput(true)` after a drain - emits `transmissionStarted`/`transmissionEnded` exactly once and
    /// `isTransmitting` never goes stale.
    private func setTransmitting(_ transmitting: Bool) {
        guard transmissionState != transmitting else { return }
        transmissionState = transmitting
        eventsHub.yield(transmitting ? .transmissionStarted : .transmissionEnded)
    }

    /// Updates the interfaces on which this source transmits.
    ///
    /// - Parameters:
    ///    - newInterfaces: The new interfaces. An interface may be a name (e.g. "en1"/"lo0") or an IP.
    ///      Empty means all interfaces (IPv4 only).
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interfaces must not be empty.
    ///
    /// - Throws: `sACNSourceValidationError.sourceBusy` if a start/stop/reconfigure or a socket-termination
    ///   drain from a prior reconfigure is still in flight; otherwise an error of type
    ///   `sACNComponentSocketError` if a bind fails (the change then rolls back all-or-nothing).
    ///
    public func updateInterfaces(_ newInterfaces: Set<String> = []) async throws {
        precondition(!ipMode.usesIPv6() || !newInterfaces.isEmpty, "At least one interface must be provided for IPv6.")

        // Reject a reconfigure that would race an in-flight start/stop/reconfigure.
        switch lifecycle {
        case .idle, .listening:
            break
        case .starting, .reconfiguring, .stopping:
            throw sACNSourceValidationError.sourceBusy
        }

        // Reject while a prior reconfigure's socket-termination drain is still marking sockets: the diff
        // would be computed against a socket set that includes terminating keys, and a revert during that
        // ~68 ms window can converge to zero live sockets. The reservation discipline covers this bounded
        // window - retry once the drain completes.
        guard socketsShouldTerminate.isEmpty else {
            throw sACNSourceValidationError.sourceBusy
        }

        // The keys are `""` (all interfaces) or one per named interface; the two shapes never coexist.
        let existingKeys = Set(sockets.keys.filter { !$0.isEmpty })
        let existingInterfaces = sockets.keys.contains("") ? Set<String>() : existingKeys
        guard existingInterfaces != newInterfaces else { return }

        let newKeys: Set<String> = newInterfaces.isEmpty ? [""] : newInterfaces
        let currentKeys = Set(sockets.keys)
        let keysToAdd = newKeys.subtracting(currentKeys)
        let keysToRemove = currentKeys.subtracting(newKeys)

        // Idle: no sockets are bound, so there are no awaits - mutate directly with no reservation.
        guard lifecycle == .listening else {
            keysToRemove.forEach { sockets.removeValue(forKey: $0) }
            for key in keysToAdd {
                sockets[key] = runtime.makeSocket(type: .transmit, ipMode: ipMode, port: 0)
                socketsShouldTerminate.remove(key)
            }
            return
        }

        // Listening: reserve `.reconfiguring` and bind every new socket into a temp map first. If any bind
        // fails (or a `stop()` interleaves), discard the temp sockets and leave the live set untouched -
        // all-or-nothing, so a partial failure never leaves a half-bound or shape-broken socket set.
        lifecycle = .reconfiguring
        do {
            var boundSockets: [String: ComponentSocket] = [:]
            do {
                for key in keysToAdd {
                    let socket = runtime.makeSocket(type: .transmit, ipMode: ipMode, port: 0)
                    try await listenForSocket(socket, on: key.isEmpty ? nil : key)
                    if stopRequested {
                        socket.close()
                        throw CancellationError()
                    }
                    boundSockets[key] = socket
                }
            } catch {
                boundSockets.values.forEach { $0.close() }
                finishReconfigure()
                throw error
            }

            // Commit: terminate/drop the removed interfaces, then install the freshly bound sockets.
            terminateOrDropSockets(forKeys: keysToRemove)
            for (key, socket) in boundSockets {
                sockets[key] = socket
                socketsShouldTerminate.remove(key)
            }
        }
        finishReconfigure()
    }

    /// Restores the lifecycle after a `.reconfiguring` reservation: back to `.listening`, or - if a
    /// `stop()` interleaved and set `stopRequested` - into the termination drain that resumes it.
    private func finishReconfigure() {
        if stopRequested {
            beginTerminationDrain()
        } else {
            lifecycle = .listening
        }
    }

    /// Terminates the universes on the given sockets (marking them for removal after the drain), or drops
    /// the sockets outright when nothing is being transmitted.
    private func terminateOrDropSockets(forKeys keys: Set<String>) {
        guard !keys.isEmpty else { return }
        if universes.isEmpty {
            keys.forEach { sockets.removeValue(forKey: $0) }
        } else {
            keys.forEach { socketsShouldTerminate.insert($0) }
            universes.forEach { $0.terminateSockets() }
        }
    }

    /// Adds a new universe to this source.
    ///
    /// If a universe with this number already exists, it will not be added.
    ///
    /// - Parameters:
    ///    - universe: The universe to add.
    ///
    /// - Throws: An error of type `sACNSourceValidationError`.
    ///
    public func addUniverse(_ universe: sACNSourceUniverse) throws {
        guard !shouldTerminate else {
            throw sACNSourceValidationError.sourceTerminating
        }
        guard !universeNumbers.contains(universe.number) else {
            throw sACNSourceValidationError.universeExists
        }

        let internalUniverse = SourceUniverse(
            with: universe, sourcePriority: self.priority, nameData: self.nameData, rootLayer: self.rootLayer)
        self.universes.append(internalUniverse)
        self.universeNumbers.append(universe.number)
        self.universeNumbers.sort()

        if isListening {
            setTransmitting(true)
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
        guard universeNumbers.contains(number) else {
            throw sACNSourceValidationError.universeDoesNotExist
        }

        if isListening {
            if let internalUniverse = universes.first(where: { $0.number == number }) {
                internalUniverse.terminate(remove: true)
            }
        } else {
            universes.removeAll(where: { $0.number == number })
            universeNumbers.removeAll(where: { $0 == number })
        }

        updateUniverseDiscoveryMessages()
    }

    /// Updates the human-readable name of this source.
    ///
    /// - Parameters:
    ///    - name: A human-readable name for this source.
    ///
    public func update(name: String) {
        self.name = name
        updateUniverseDiscoveryMessages()
        updateDataFramingLayers()
    }

    /// Updates the priority of this source.
    ///
    /// - Parameters:
    ///    - priority: A new priority for this source (values permitted 0-200).
    ///
    public func update(priority: UInt8) {
        self.priority = priority.nearestValidPriority()
        updateDataFramingLayers()
    }

    /// Updates an existing universe using the per-packet priority, levels and optionally per-slot priorities.
    ///
    ///  - Parameters:
    ///     - universe: An `sACNSourceUniverse`.
    ///
    ///  - Throws: An error of type `sACNSourceValidationError`.
    ///
    public func updateLevels(with universe: sACNSourceUniverse) throws {
        let internalUniverse = try requireUpdatableUniverse(number: universe.number)
        try internalUniverse.update(with: universe, sourcePriority: self.priority, sourceActive: isListening)
    }

    /// Updates an existing universe with levels.
    ///
    ///  - Parameters:
    ///     - levels: The new levels (512).
    ///     - universeNumber: The universe number to update.
    ///
    ///  - Throws: An error of type `sACNSourceValidationError`.
    ///
    public func updateLevels(_ levels: [UInt8], in universeNumber: UInt16) throws {
        let internalUniverse = try requireUpdatableUniverse(number: universeNumber)
        try internalUniverse.update(levels: levels, sourceActive: isListening)
    }

    /// Updates an existing universe with per-slot priorities.
    ///
    /// If `nil` is passed, this source will no longer output per-slot priority.
    ///
    ///  - Parameters:
    ///     - priorities: Optional new per-slot priorities (512).
    ///     - universeNumber: The universe number to update.
    ///
    ///  - Throws: An error of type `sACNSourceValidationError`.
    ///
    public func updatePriorities(_ priorities: [UInt8]?, in universeNumber: UInt16) throws {
        let internalUniverse = try requireUpdatableUniverse(number: universeNumber)
        try internalUniverse.update(priorities: priorities, sourceActive: isListening)
    }

    /// Updates a slot of an existing universe with a level and optionally per-slot priority.
    ///
    ///  - Parameters:
    ///     - slot: The slot to update (0-511).
    ///     - universeNumber: The universe number to update.
    ///     - level: The level for this slot.
    ///     - priority: Optional: An optional per-slot priority for this slot.
    ///
    ///  - Throws: An error of type `sACNSourceValidationError`.
    ///
    public func updateSlot(slot: Int, in universeNumber: UInt16, level: UInt8, priority: UInt8? = nil) throws {
        let internalUniverse = try requireUpdatableUniverse(number: universeNumber)
        try internalUniverse.update(slot: slot, level: level, priority: priority, sourceActive: isListening)
    }

    /// Updates a slot of an existing universe with a per-slot priority.
    ///
    ///  - Parameters:
    ///     - slot: The slot to update (0-511).
    ///     - universeNumber: The universe number to update.
    ///     - priority: The per-slot priority for this slot.
    ///
    ///  - Throws: An error of type `sACNSourceValidationError`.
    ///
    public func updateSlot(slot: Int, in universeNumber: UInt16, priority: UInt8) throws {
        let internalUniverse = try requireUpdatableUniverse(number: universeNumber)
        try internalUniverse.update(slot: slot, priority: priority, sourceActive: isListening)
    }

    /// Test seam: the numbers of the universes currently held (reflecting drain-time removals), for
    /// lifecycle assertions. `[UInt16]` is `Sendable`, unlike the `SourceUniverse` array itself.
    var currentUniverseNumbers: [UInt16] {
        universes.map(\.number)
    }

    /// Test seam: terminates a specific universe in place (as `shouldOutput(false)` does for all
    /// universes), so the transmit-builder characterization tests can stage a present-but-inactive state.
    func terminate(universe number: UInt16, remove: Bool) {
        universes.first { $0.number == number }?.terminate(remove: remove)
    }

    /// Test seam (performance guard): whether the packet emitted for the first universe shares backing
    /// storage with that universe's stored pre-composed packet - i.e. it was handed over, not reallocated
    /// per frame. Computed in-isolation so no off-actor `Data` copy perturbs the buffer identity.
    func emittedPacketSharesStorage(perAddressPriority: Bool) -> Bool {
        guard let universe = universes.first else { return false }
        let startCodeOffset = RootLayer.Offset.data.rawValue + DataFramingLayer.Offset.data.rawValue + DMPLayer.Offset.propertyValues.rawValue
        let wantedStartCode = perAddressPriority ? DMX.STARTCode.perAddressPriority.rawValue : DMX.STARTCode.null.rawValue
        let (messages, _) = buildDataMessages()
        guard let message = messages.first(where: { Array($0.data)[startCodeOffset] == wantedStartCode }) else { return false }
        let stored = perAddressPriority ? universe.prioritiesPacket : universe.levelsPacket
        return message.data.withUnsafeBytes { emitted in stored.withUnsafeBytes { s in emitted.baseAddress == s.baseAddress } }
    }

    /// Looks up a universe that is valid to update, or throws.
    private func requireUpdatableUniverse(number: UInt16) throws -> SourceUniverse {
        guard let internalUniverse = universes.first(where: { $0.number == number }) else {
            throw sACNSourceValidationError.universeDoesNotExist
        }
        guard !isListening || !internalUniverse.removeAfterTerminate else {
            throw sACNSourceValidationError.universeTerminating
        }
        return internalUniverse
    }

    // MARK: - General

    /// Attempts to start listening for a socket on an optional interface.
    private func listenForSocket(_ socket: ComponentSocket, on interface: String? = nil) async throws {
        socket.delegate = self
        try await socket.startListening(onInterface: interface)
    }

    // MARK: - Timers / Messaging

    /// Starts this source's universe discovery timer.
    private func startUniverseDiscovery() {
        // send a discovery message straight away (already isolated - no hop)
        sendUniverseDiscoveryMessage()
        universeDiscoveryTask = runtime.scheduleRepeated(after: Self.universeDiscoveryInterval, every: Self.universeDiscoveryInterval) {
            [weak self] in
            self?.assumeIsolated { $0.sendUniverseDiscoveryMessage() }
        }
    }

    /// Stops this source's universe discovery heartbeat.
    private func stopUniverseDiscovery() {
        universeDiscoveryTask?.cancel()
        universeDiscoveryTask = nil
    }

    /// Starts this source's data transmission heartbeat.
    private func startDataTransmit() {
        dataTransmitTask = runtime.scheduleRepeated(after: Self.dataTransmitInterval, every: Self.dataTransmitInterval) { [weak self] in
            self?.assumeIsolated { $0.sendDataMessages() }
        }
    }

    /// Stops this source's data transmission for all sockets (marking termination; the timer keeps running
    /// until `sendDataMessages` observes termination is complete).
    ///
    /// Deliberately does **not** touch `socketsShouldTerminate`: the universes' `shouldTerminate` drives the
    /// termination packets and the sockets close at teardown, so populating it here would be redundant - and
    /// overwriting it would clobber a pending interface-removal mark from a concurrent `updateInterfaces`.
    private func stopDataTransmit() {
        shouldTerminate = true
        universes.forEach { $0.terminate(remove: false) }
    }

    /// Sends the Universe Discovery messages for this source.
    private func sendUniverseDiscoveryMessage() {
        guard lifecycle != .idle, _shouldOutput else { return }

        sockets.forEach { _, socket in
            for message in universeDiscoveryMessages {
                if ipMode.usesIPv4() {
                    socket.send(message: message, host: IPv4.universeDiscoveryHostname, port: UDP.sdtPort)
                }
                if ipMode.usesIPv6() {
                    socket.send(message: message, host: IPv6.universeDiscoveryHostname, port: UDP.sdtPort)
                }
            }
        }

        debugLogHub.yield("Sending universe discovery message(s) multicast")
    }

    /// Sends the data messages for this source (the ~44 fps heartbeat and termination drain).
    ///
    /// Also runs while `.reconfiguring`: `updateInterfaces` only mutates state synchronously between its
    /// binds, so a tick interleaved at one of its suspensions sees a consistent (pre-commit) socket set -
    /// and dropping ticks for the bind duration would starve NULL keep-alives and time the source out at
    /// otherwise-healthy receivers.
    private func sendDataMessages() {
        guard lifecycle == .listening || lifecycle == .reconfiguring || lifecycle == .stopping else { return }

        let universesToRemove = universes.filter { $0.removeAfterTerminate && $0.shouldTerminate && $0.dirtyCounter < 1 }
        let universesReadyForSocketRemoval = universes.filter { $0.pendingSocketRemoval && $0.dirtyCounter < 1 }
        self.universes.removeAll(where: { universesToRemove.contains($0) })
        self.universeNumbers.removeAll(where: { universesToRemove.map { universe in universe.number }.contains($0) })

        let activeUniverses = universes.filter { !$0.shouldTerminate || $0.dirtyCounter > 0 }

        if activeUniverses.isEmpty {
            setTransmitting(false)

            // Drop (not merely un-mark) any sockets pending removal, so a reconfigure interrupted by a stop
            // does not leave a removed interface in the dict to be re-bound on the next start.
            socketsShouldTerminate.forEach { sockets.removeValue(forKey: $0) }
            socketsShouldTerminate.removeAll()

            if self.shouldTerminate {
                // the source has finished terminating: stop the timer, close the sockets, and reach idle
                // (clearing the drain flags and resuming any `stop()` caller awaiting completion)
                dataTransmitTask?.cancel()
                dataTransmitTask = nil
                sockets.values.forEach { $0.close() }
                reachedIdle()
            }
            return
        }

        setTransmitting(true)

        // A socket-termination drain has finished (its universes sent their 3 packets): drop the removed
        // sockets and clear the marks. One branch covers both whole-universe and socket-only removals, so a
        // tick where both are ready cannot strand `pendingSocketRemoval`.
        if !socketsShouldTerminate.isEmpty && (!universesToRemove.isEmpty || !universesReadyForSocketRemoval.isEmpty) {
            socketsShouldTerminate.forEach { sockets.removeValue(forKey: $0) }
            socketsShouldTerminate.removeAll()
            universesReadyForSocketRemoval.forEach { $0.terminateSocketsComplete() }
        }

        let (universeMessages, socketTerminationMessages) = buildDataMessages()

        sockets.forEach { interface, socket in
            let messages = socketsShouldTerminate.contains(interface) ? socketTerminationMessages : universeMessages

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

    // MARK: - Build and Update Data

    /// Builds and updates the universe discovery messages for this source.
    private func updateUniverseDiscoveryMessages() {
        let univCount = universeNumbers.count
        let univMax = UniverseDiscoveryLayer.maxUniverseNumbers

        let pageCount = min((univCount / univMax) + (univCount % univMax == 0 ? 0 : 1), Int(UInt8.max))

        var pages = [Data]()
        for page in 0..<pageCount {
            let first = page * univMax
            let last = min(first + univMax, univCount)
            let pageUniverseNumbers = Array(universeNumbers[first..<last])

            var rootLayer = RootLayer.createAsData(vector: .extended, cid: cid)
            var framingLayer = UniverseDiscoveryFramingLayer.createAsData(nameData: nameData)
            let universeDiscoveryLayer = UniverseDiscoveryLayer.createAsData(
                page: UInt8(page), lastPage: UInt8(pageCount - 1), universeList: pageUniverseNumbers)

            let framingLayerLength = UInt16(framingLayer.count + universeDiscoveryLayer.count)
            framingLayer.replacingUniverseDiscoveryFramingFlagsAndLength(with: framingLayerLength)

            let rootLayerLength = UInt16(rootLayer.count + framingLayer.count + universeDiscoveryLayer.count - RootLayer.lengthCountOffset)
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

    // MARK: - Message building

    /// Builds the data (and socket-termination) messages for the currently active universes.
    ///
    /// Advances each universe's transmit state machine (sequence, dirty and transmit counters) and returns
    /// the packets to send, performing no socket I/O. Extracted from `sendDataMessages()` so the transmit
    /// cadence and termination behavior can be unit tested (`await source.buildDataMessages()`).
    ///
    /// - Returns: The universe messages to send, and the messages to send to terminating sockets.
    ///
    func buildDataMessages() -> (messages: [UniverseData], socketTermination: [UniverseData]) {
        let activeUniverses = universes.filter { !$0.shouldTerminate || $0.dirtyCounter > 0 }

        var universeMessages = [UniverseData]()
        var socketTerminationMessages = [UniverseData]()

        for universe in activeUniverses {

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
                // stamp sequence/options into the pre-composed packet in place (no per-frame rebuild)
                universe.stampLevels(sequence: universe.sequence, options: framingOptions)

                let terminationUniverse: UniverseData?
                if !socketsShouldTerminate.isEmpty || (universe.shouldTerminate && universe.dirtyCounter > 0) {
                    // the rare socket-termination path needs a `.terminated` variant alongside the normal
                    // packet: one explicit copy off the just-stamped packet (same sequence)
                    terminationUniverse = UniverseData(universeNumber: universe.number, data: universe.terminatedLevelsPacket())
                } else {
                    terminationUniverse = nil
                }

                if !socketsShouldTerminate.isEmpty, let terminationUniverse {
                    socketTerminationMessages.append(terminationUniverse)
                }

                if universe.shouldTerminate && universe.dirtyCounter > 0, let terminationUniverse {
                    universeMessages.append(terminationUniverse)
                    universe.incrementSequence()
                } else if _shouldOutput {
                    universeMessages.append(UniverseData(universeNumber: universe.number, data: universe.levelsPacket))
                    universe.incrementSequence()
                }
                universe.decrementDirty()
            }

            if sendPriority {
                universe.stampPriorities(sequence: universe.sequence, options: framingOptions)

                if _shouldOutput || (universe.shouldTerminate && universe.dirtyCounter > 0) {
                    universeMessages.append((universeNumber: universe.number, data: universe.prioritiesPacket))
                    universe.incrementSequence()
                    universe.prioritySent()
                }
            }

            universe.incrementCounter()
        }

        return (universeMessages, socketTerminationMessages)
    }

}

/// sACN Source Validation Error
///
/// Enumerates all possible `sACNSource` parsing errors.
///
public enum sACNSourceValidationError: LocalizedError, Sendable {

    /// The source is started.
    case sourceStarted

    /// The source is busy with an in-flight start, stop or interface reconfiguration.
    case sourceBusy

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
        case .sourceBusy:
            return "The source is busy starting, stopping or reconfiguring"
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

/// `ComponentSocketDelegate` conformance.
///
/// The source's sockets are actor-path sockets (`sACNRuntime.makeSocket`): they deliver on the event loop
/// this actor is isolated to, so these `nonisolated` methods `assumeIsolated` into the actor with no hop.
///
extension sACNSource: ComponentSocketDelegate {

    nonisolated func receivedMessage(
        for socket: ComponentSocket, withData data: Data, sourceHostname: String, sourcePort: UInt16, ipFamily: ComponentSocketIPFamily
    ) {
        // sACN sources do not process received messages.
    }

    nonisolated func socket(_ socket: ComponentSocket, socketDidCloseWith reason: SocketCloseReason) {
        let interface = socket.interface
        assumeIsolated { source in
            guard source.isListening else { return }
            source.eventsHub.yield(.socketClosed(interface: interface, reason: reason))
        }
    }

    nonisolated func debugLog(for socket: ComponentSocket, with logMessage: String) {
        assumeIsolated { $0.debugLogHub.yield(logMessage) }
    }

}
