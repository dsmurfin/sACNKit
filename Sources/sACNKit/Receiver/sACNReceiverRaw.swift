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

/// A synchronous, in-isolation sink for a `sACNReceiverRaw`'s output.
///
/// The merged receiver (`sACNReceiver`) owns a raw receiver on the **same** runtime/event loop and adopts
/// this to receive raw output on the loop with no `Task` hop, preserving the ordered per-packet merge. The
/// conformer's methods are `nonisolated` and `assumeIsolated` into its own isolation (valid because it
/// shares the raw's executor). Held **weakly** by the raw receiver (the owner holds the raw strongly).
///
protocol RawReceiverSink: AnyObject {

    func rawReceiverDidReceive(_ data: sACNReceiverRawSourceData)

    func rawReceiverDidEmit(_ event: sACNReceiverRaw.Event)

    func rawReceiverDidLog(_ message: String)

}

/// sACN Receiver Raw
///
/// An E1.31-2018 sACN Receiver Raw which receives sACN Messages from a single universe, providing raw
/// per-source data for online sources and notifying of source loss and loss of per-address priority.
///
/// A `sACNReceiverRaw` is an `actor` isolated to an internal `sACNRuntime` (a shared NIO event loop). Its
/// lifecycle and mutation API are `async`; per-source data arrives on the `data` `AsyncStream`, lifecycle
/// events on `events`, and debug logs on `debugLog`, rather than via a delegate.
///
public actor sACNReceiverRaw {

    // MARK: Runtime / isolation

    /// The runtime hosting this actor's isolation, timers, and sockets.
    nonisolated let runtime: sACNRuntime

    /// Pins this actor to the runtime's serial executor (the shared NIO event loop), so the transport can
    /// deliver received packets into the actor's isolation synchronously (`assumeIsolated` from the channel
    /// handler, no `Task` hop) - see `EventLoopSerialExecutor`.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        runtime.serialExecutor.asUnownedSerialExecutor()
    }

    // MARK: Events

    /// An event emitted by a raw receiver.
    public enum Event: Sendable {

        /// The initial sampling period for the universe began.
        case samplingStarted

        /// The initial sampling period for the universe ended.
        case samplingEnded

        /// One or more sources were lost (coalesced).
        case sourcesLost([UUID])

        /// A source stopped sending per-address priority (its levels revert to universe priority).
        case perAddressPriorityLost(UUID)

        /// The receiver's source limit was reached (a new source was dropped).
        case sourceLimitExceeded

        /// A socket closed with an error (per interface).
        case socketClosed(interface: String?, reason: SocketCloseReason)

    }

    /// The broadcast hub backing `data`. Buffers newest-64 (not newest-1 like the merged snapshot streams):
    /// this stream interleaves frames from distinct sources, which must not collapse into one another.
    private nonisolated let dataHub = AsyncStreamHub<sACNReceiverRawSourceData>(bufferingPolicy: .bufferingNewest(64))

    /// A stream of raw per-source universe data. Each access returns an independent subscription.
    public nonisolated var data: AsyncStream<sACNReceiverRawSourceData> { dataHub.stream() }

    /// The broadcast hub backing `events`.
    private nonisolated let eventsHub = AsyncStreamHub<Event>(bufferingPolicy: .bufferingNewest(64))

    /// A stream of receiver lifecycle events. Each access returns an independent subscription. Best-effort,
    /// drop-oldest (buffers newest-64): a consumer that stalls for long enough can miss an event such as
    /// `.sourcesLost` (a delta from the old never-drop delegate callbacks).
    public nonisolated var events: AsyncStream<Event> { eventsHub.stream() }

    /// The broadcast hub backing `debugLog`.
    private nonisolated let debugLogHub = AsyncStreamHub<String>(bufferingPolicy: .bufferingNewest(64))

    /// A stream of human-readable debug log messages. Each access returns an independent subscription.
    public nonisolated var debugLog: AsyncStream<String> { debugLogHub.stream() }

    /// An optional synchronous, in-isolation sink (the merged receiver embedding this raw receiver). Held
    /// weakly. Every emit both yields to the public hub and, if set, delivers to the sink on the loop.
    private weak var rawSink: (any RawReceiverSink)?

    // MARK: Lifecycle

    /// The reserve-before-await lifecycle state machine (shared with the other component actors).
    private var gate = LifecycleGate()

    /// Whether the receiver is actively listening.
    public var isListening: Bool { gate.isListening }

    // MARK: Sockets

    /// The Internet Protocol version(s) used by the receiver.
    private let ipMode: sACNIPMode

    /// The sockets used for communications (one per interface, keyed by interface or "" for all).
    private var sockets: [String: ComponentSocket] = [:]

    /// The identifiers of sockets and their sampling status. Presence means sampling or waiting to sample;
    /// a value of `true` means actively sampling. `internal private(set)` so tests can inspect it.
    private(set) var socketsSampling: [UUID: Bool] = [:]

    // MARK: General

    /// The sACN universe this receiver observes.
    let universe: UInt16

    /// Whether preview data is filtered by this receiver.
    private let filterPreviewData: Bool

    /// An optional limit on the number of sources this receiver accepts.
    private let sourceLimit: Int?

    /// A list of CIDs this receiver should filter.
    private var filterCIDs: Set<UUID>

    /// Whether this universe is sampling.
    private var sampling = false

    /// The sources that have been received.
    private var sources: [UUID: ReceiverRawSource] = [:]

    /// Whether source-limit-exceeded has been notified (latched so it fires once).
    private var sourceLimitExceededNotified = false

    // MARK: Timers

    /// The sACN network data loss timeout (2500 ms).
    static let sourceLossTimeout: UInt64 = 2500

    /// How long to wait for a per-address priority (0xDD) packet when discovering a source (1500 ms).
    static let perAddressPriorityWait: UInt64 = 1500

    /// The network data loss timeout for this receiver (defaults to `Self.sourceLossTimeout`; overridable for tests).
    let sourceLossTimeout: UInt64

    /// The per-address priority wait for this receiver (defaults to `Self.perAddressPriorityWait`; overridable for tests).
    let perAddressPriorityWait: UInt64

    /// The length of time to sample a new universe (1500 ms).
    private static let sampleTime: Duration = .milliseconds(1500)

    /// The main heartbeat interval (500 ms), driving source-loss evaluation.
    private static let heartbeatInterval: Duration = .milliseconds(500)

    /// The sampling timer (single-shot, self-re-arming for staggered per-socket sampling).
    private var sampleTask: (any RuntimeTask)?

    /// The heartbeat timer.
    private var heartbeatTask: (any RuntimeTask)?

    // MARK: - Initialization

    /// Creates a new receiver to receive raw sACN data for a single universe.
    ///
    /// If the universe provided is not valid, this initializes to `nil`.
    ///
    /// - Parameters:
    ///    - ipMode: Optional: IP mode for this receiver (IPv4/IPv6/Both).
    ///    - interfaces: The network interfaces for this receiver. An interface may be a name (e.g. "en1" or "lo0") or the corresponding IP address (e.g. "192.168.4.35").
    ///    - universe: The universe this receiver listens to.
    ///    - sourceLimit: The number of sources this receiver is able to process (defaults to `4`).
    ///    - filterPreviewData: Optional: Whether source preview data should be filtered out (defaults to `true`).
    ///    - filterCIDs: Optional: A list of CIDs which should be ignored (defaults to none).
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interfaces must not be empty.
    ///
    public init?(
        ipMode: sACNIPMode = .ipv4Only, interfaces: Set<String> = [], universe: UInt16, sourceLimit: Int? = 4,
        filterPreviewData: Bool = true, filterCIDs: Set<UUID> = []
    ) {
        self.init(
            runtime: NIORuntime(), ipMode: ipMode, interfaces: interfaces, universe: universe, sourceLimit: sourceLimit,
            filterPreviewData: filterPreviewData, filterCIDs: filterCIDs, sourceLossTimeout: Self.sourceLossTimeout,
            perAddressPriorityWait: Self.perAddressPriorityWait)
    }

    /// Creates a new receiver on an injected runtime, additionally allowing the timing constants to be
    /// overridden. Internal seam: the merged receiver shares its runtime with the raw receiver (so the merge
    /// runs on the same loop), and tests exercise timing-driven behavior quickly.
    init?(
        runtime: sACNRuntime, ipMode: sACNIPMode, interfaces: Set<String>, universe: UInt16, sourceLimit: Int?,
        filterPreviewData: Bool, filterCIDs: Set<UUID>, sourceLossTimeout: UInt64, perAddressPriorityWait: UInt64
    ) {
        precondition(!ipMode.usesIPv6() || !interfaces.isEmpty, "At least one interface must be provided for IPv6.")
        guard universe.validUniverse() else { return nil }

        self.runtime = runtime
        self.ipMode = ipMode
        self.universe = universe
        self.filterPreviewData = filterPreviewData
        self.sourceLimit = sourceLimit
        self.filterCIDs = filterCIDs
        self.sourceLossTimeout = sourceLossTimeout
        self.perAddressPriorityWait = perAddressPriorityWait

        if interfaces.isEmpty {
            let socket = runtime.makeSocket(type: .receive, ipMode: ipMode, port: UDP.sdtPort)
            self.sockets = ["": socket]
            self.socketsSampling = [socket.id: true]
        } else {
            for interface in interfaces {
                let socket = runtime.makeSocket(type: .receive, ipMode: ipMode, port: UDP.sdtPort)
                sockets[interface] = socket
                socketsSampling[socket.id] = true
            }
        }
    }

    deinit {
        // The timers self-cancel when released; the sockets close on dealloc. Finish the hubs so any active
        // consumers terminate rather than hang.
        dataHub.finish()
        eventsHub.finish()
        debugLogHub.finish()
    }

    // MARK: - Public API

    /// Sets (or clears) the synchronous in-isolation sink (the embedding merged receiver). Internal.
    func setSink(_ sink: (any RawReceiverSink)?) {
        rawSink = sink
    }

    /// Starts this receiver: binds its sockets, joins the universe's multicast group, and begins listening
    /// (with an initial sampling period) for sACN Data messages delivered on `data`.
    ///
    /// - Throws: `sACNReceiverValidationError` or `sACNComponentSocketError`.
    ///
    public func start() async throws {
        switch gate.reserveStart() {
        case .reserved:
            break
        case .alreadyActive:
            throw sACNReceiverValidationError.receiverStarted
        case .busy:
            throw sACNReceiverValidationError.receiverBusy
        }

        do {
            for (interface, socket) in sockets {
                try await listenForSocket(socket, on: interface.isEmpty ? nil : interface)
                if gate.stopRequested { throw CancellationError() }
            }
        } catch {
            let superseded = gate.stopRequested
            sockets.values.forEach { socket in
                socket.delegate = nil
                socket.close()
            }
            reachedIdle()
            throw superseded ? CancellationError() : error
        }

        gate.toListening()
        startHeartbeat()
        // Re-seed sampling for every current socket so each start begins a uniform fresh sampling period
        // (matching first-start semantics); a restart after `updateInterfaces` otherwise leaves retained
        // sockets absent from the map, which `processDataPacket` would reject for the whole sampling window.
        socketsSampling = Dictionary(uniqueKeysWithValues: sockets.values.map { ($0.id, true) })
        beginSamplingPeriod()
    }

    /// Stops this receiver, suspending until its sockets have closed (a receiver has nothing to flush, so
    /// this awaits the actual close; superseding an in-flight start/reconfigure aborts it and resolves on
    /// unwind, rebind-safe via `SO_REUSEPORT`).
    public func stop() async {
        switch gate.state {
        case .idle:
            return
        case .starting, .reconfiguring:
            gate.requestStop()
            sockets.values.forEach { $0.close() }
            await withCheckedContinuation { gate.addStopWaiter($0) }
        case .listening:
            await teardown()
        case .stopping:
            await withCheckedContinuation { gate.addStopWaiter($0) }
        }
    }

    /// Tears down from `.listening`: cancels the timers, closes every socket (awaiting the close), clears
    /// state, and reaches idle.
    private func teardown() async {
        gate.toStopping()
        stopSampling()
        // Clear `sampling` before the first await so a sample tick that already dequeued cannot run
        // `endedSamplingPeriod` (and re-arm) mid-teardown - it guards on `sampling`.
        sampling = false
        stopHeartbeat()
        // Nil every delegate before any close, so no still-open socket delivers a packet (creating a source
        // the `sources = [:]` below would silently drop, with no `.sourcesLost`) while we await the closes.
        sockets.values.forEach { $0.delegate = nil }
        for socket in sockets.values {
            await socket.stopListening()
        }
        sources = [:]
        reachedIdle()
    }

    /// Returns to idle and resumes every waiting `stop()` caller.
    private func reachedIdle() {
        gate.reachedIdle().forEach { $0.resume() }
    }

    /// Updates the interfaces on which this receiver listens for sACN Data messages.
    ///
    /// - Parameters:
    ///    - newInterfaces: The new interfaces. An interface may be a name (e.g. "en1"/"lo0") or an IP.
    ///      Empty means all interfaces (IPv4 only).
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interfaces must not be empty.
    ///
    /// - Throws: `sACNReceiverValidationError.receiverBusy` if a start/stop/reconfigure is in flight;
    ///   otherwise `sACNComponentSocketError` if a bind fails (the change rolls back all-or-nothing).
    ///
    public func updateInterfaces(_ newInterfaces: Set<String> = []) async throws {
        precondition(!ipMode.usesIPv6() || !newInterfaces.isEmpty, "At least one interface must be provided for IPv6.")

        let reservation = gate.reserveReconfigure()
        guard reservation != .busy else { throw sACNReceiverValidationError.receiverBusy }

        let (existingInterfaces, keysToAdd, keysToRemove) = interfaceDiff(
            currentKeys: Set(sockets.keys), newInterfaces: newInterfaces)
        guard existingInterfaces != newInterfaces else { return }

        // Idle: no sockets are bound, so there are no awaits - mutate directly with no reservation.
        guard reservation == .proceedListening else {
            keysToRemove.forEach { key in
                if let socket = sockets.removeValue(forKey: key) { socketsSampling.removeValue(forKey: socket.id) }
            }
            for key in keysToAdd {
                let socket = runtime.makeSocket(type: .receive, ipMode: ipMode, port: UDP.sdtPort)
                sockets[key] = socket
                socketsSampling[socket.id] = true
            }
            return
        }

        // Listening: reserve `.reconfiguring` and bind + join every new socket into a temp map first. Only
        // commit if all succeed (all-or-nothing).
        gate.beginReconfigure()
        var boundSockets: [String: ComponentSocket] = [:]
        do {
            for key in keysToAdd {
                let socket = runtime.makeSocket(type: .receive, ipMode: ipMode, port: UDP.sdtPort)
                try await listenForSocket(socket, on: key.isEmpty ? nil : key)
                if gate.stopRequested {
                    socket.close()
                    throw CancellationError()
                }
                boundSockets[key] = socket
            }
        } catch {
            let superseded = gate.stopRequested
            boundSockets.values.forEach { $0.close() }
            await finishReconfigure()
            throw superseded ? CancellationError() : error
        }

        // Commit: drop the removed sockets (and their sampling entries), install the freshly bound ones, and
        // re-seed sampling for the added sockets (sampling only if a sampling period is not already running).
        for key in keysToRemove {
            if let socket = sockets.removeValue(forKey: key) {
                socket.delegate = nil
                socket.close()
                socketsSampling.removeValue(forKey: socket.id)
            }
        }
        let sample = sampleTask == nil
        for (key, socket) in boundSockets {
            sockets[key] = socket
            socketsSampling[socket.id] = sample
        }
        beginSamplingPeriod()
        await finishReconfigure()
    }

    /// Restores the lifecycle after a `.reconfiguring` reservation: back to `.listening`, or - if a `stop()`
    /// interleaved - through teardown to idle.
    private func finishReconfigure() async {
        if gate.stopRequested {
            await teardown()
        } else {
            gate.toListening()
        }
    }

    // MARK: General

    /// Attempts to start listening for a socket on an optional interface, joining the universe's multicast
    /// group for each enabled family (rolling back on a join failure via the shared `startListeningAndJoin`).
    private func listenForSocket(_ socket: ComponentSocket, on interface: String? = nil) async throws {
        socket.delegate = self
        try await socket.startListeningAndJoin(
            onInterface: interface, ipMode: ipMode, ipv4Group: IPv4.multicastHostname(for: universe),
            ipv6Group: IPv6.multicastHostname(for: universe))
    }

    // MARK: Emit

    /// Delivers raw source data to the public `data` stream and, if embedded, the merged receiver's sink.
    private func emit(data: sACNReceiverRawSourceData) {
        dataHub.yield(data)
        rawSink?.rawReceiverDidReceive(data)
    }

    /// Delivers a lifecycle event to the public `events` stream and, if embedded, the merged receiver's sink.
    private func emit(_ event: Event) {
        eventsHub.yield(event)
        rawSink?.rawReceiverDidEmit(event)
    }

    /// Delivers a debug message to the public `debugLog` stream and, if embedded, the merged receiver's sink.
    private func log(_ message: String) {
        debugLogHub.yield(message)
        rawSink?.rawReceiverDidLog(message)
    }

    // MARK: Timers

    /// Starts the main heartbeat, which drives source-loss evaluation.
    private func startHeartbeat() {
        heartbeatTask = runtime.scheduleRepeated(after: Self.heartbeatInterval, every: Self.heartbeatInterval) { [weak self] in
            self?.assumeIsolated { $0.heartbeatTick() }
        }
    }

    /// Stops the main heartbeat.
    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// The heartbeat tick: evaluates source loss while listening.
    private func heartbeatTick() {
        guard gate.isListening else { return }
        checkForSourceLoss()
    }

    /// Cancels the sampling timer.
    private func stopSampling() {
        sampleTask?.cancel()
        sampleTask = nil
    }

    /// The sampling tick: ends the sampling period if one is still active. Guards on `sampling` (which
    /// `teardown` clears alongside cancelling the timer) so a tick that raced a stop cannot re-arm.
    private func sampleTick() {
        guard sampling else { return }
        endedSamplingPeriod()
    }

    /// Begins the initial sampling period for this universe (internal seam). Schedules a single-shot timer
    /// that re-arms per staggered socket.
    ///
    /// - Parameters:
    ///    - notify: Whether to emit `.samplingStarted` (defaults to `true`).
    ///
    func beginSamplingPeriod(notify: Bool = true) {
        guard !sampling else { return }
        sampling = true

        if notify {
            emit(.samplingStarted)
        }

        // Cancel any prior one-shot before reassigning, so a re-arm never leaks an armed timer (honours the
        // `RuntimeTask` ownership contract; the `guard !sampling` above already prevents re-entry).
        sampleTask?.cancel()
        sampleTask = runtime.scheduleOnce(after: Self.sampleTime) { [weak self] in
            self?.assumeIsolated { $0.sampleTick() }
        }
    }

    /// Ends the initial sampling period for this universe (internal seam). Sockets that were sampling are
    /// dropped; any remaining sockets begin sampling (staggered) and the timer re-arms, otherwise sampling
    /// ends and `.samplingEnded` is emitted.
    func endedSamplingPeriod() {
        sampling = false

        // remove any sockets which were sampling
        socketsSampling.filter { $0.value }.keys.forEach { socketsSampling.removeValue(forKey: $0) }

        // any sockets left should now be sampling
        if !socketsSampling.isEmpty {
            socketsSampling.keys.forEach { socketsSampling.updateValue(true, forKey: $0) }
            beginSamplingPeriod(notify: false)
        } else {
            stopSampling()
            emit(.samplingEnded)
        }
    }

    /// Checks for source loss, coalescing lost sources into a single `.sourcesLost` event (internal seam).
    func checkForSourceLoss() {
        var notifyLostSources: Set<UUID> = []
        var removeLostSources: Set<UUID> = []
        sources.forEach { id, source in
            switch source.state {
            case .waitingForLevels:
                if source.isPAPTimerExpired {
                    // timed out in a waiting state - remove without notifying
                    removeLostSources.insert(id)
                }
            case .waitingForPAP:
                if source.isPacketTimerExpired {
                    // timed out in a waiting state - remove without notifying
                    removeLostSources.insert(id)
                }
            case .hasLevelsOnly, .hasLevelsAndPAP:
                switch source.available() {
                case .offline:
                    notifyLostSources.insert(id)
                    removeLostSources.insert(id)
                case .online, .unknown:
                    break
                }
            }
        }

        if !notifyLostSources.isEmpty {
            emit(.sourcesLost(Array(notifyLostSources)))
        }

        removeLostSources.forEach { sourceId in
            sources.removeValue(forKey: sourceId)
        }
    }

    // MARK: Test seams

    /// Test seam: the number of sources currently tracked.
    var trackedSourceCount: Int {
        sources.count
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
    /// Internal so the state machine can be characterization-tested by injecting packets directly
    /// (`await receiver.process(data:...)`).
    ///
    /// - Parameters:
    ///    - data: The data to process.
    ///    - ipFamily: The `ComponentSocketIPFamily` of the source of the message.
    ///    - socketId: The identifier of the socket on which this message was received.
    ///    - hostname: The hostname (address) of the source of the message.
    ///
    func process(data: Data, ipFamily: ComponentSocketIPFamily, socketId: UUID, hostname: String) {
        do {
            let rootLayer = try RootLayer.parse(fromData: data)

            guard !filterCIDs.contains(rootLayer.cid) else { return }

            switch rootLayer.vector {
            case .extended:
                // universe sync is not currently handled; discovery is handled by sACNDiscoveryReceiver
                break
            case .data:
                try processDataPacket(rootLayer: rootLayer, ipFamily: ipFamily, socketId: socketId, hostname: hostname)
            }
        } catch let error as RootLayerValidationError {
            log(error.logDescription)
        } catch let error as DataFramingLayerValidationError {
            log(error.logDescription)
        } catch let error as DMPLayerValidationError {
            log(error.logDescription)
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

        let previewData = framingLayer.options.contains(.preview)

        // Peel the DMP layer and run the per-source state machine (existing or new). `dmpLayer` stays nil
        // when the packet produces no source (a new terminated stream), so nothing is notified.
        let dmpLayer: DMPLayer?
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

            let layer = try DMPLayer.parse(fromData: framingLayer.data)

            // based on the timecode update timers
            switch layer.startCode {
            case .null:
                processLevels(for: existingSource, notify: &notify)
            case .perAddressPriority:
                processPerAddressPriority(for: existingSource, notify: &notify)
            }
            dmpLayer = layer
        } else if !framingLayer.options.contains(.terminated) {
            // process new source data
            let layer = try DMPLayer.parse(fromData: framingLayer.data)
            let source = createSource(
                cid: rootLayer.cid, name: framingLayer.sourceName, hostname: hostname, ipFamily: ipFamily, sequence: framingLayer.sequenceNumber,
                startCode: layer.startCode, notify: &notify)
            sources[rootLayer.cid] = source
            dmpLayer = layer
        } else {
            dmpLayer = nil
        }

        // notify only if the state machine flagged it, and not for filtered preview data
        guard let dmpLayer, notify else { return }
        guard !previewData || !filterPreviewData else { return }

        emit(
            data: sACNReceiverRawSourceData(
                cid: rootLayer.cid, name: framingLayer.sourceName, hostname: hostname, universe: universe, priority: framingLayer.priority,
                sequence: framingLayer.sequenceNumber, options: sACNDataOptions(rawValue: framingLayer.options.rawValue),
                syncUniverse: framingLayer.syncAddress, preview: previewData, isSampling: isSampling, startCode: dmpLayer.startCode,
                valuesCount: dmpLayer.values.count, values: dmpLayer.values))
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
                source.startPAPTimer(withInterval: sourceLossTimeout)
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
            if source.markPerAddressPriorityLost() {
                emit(.perAddressPriorityLost(source.cid))
            }
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
            source.resetPerAddressPriorityLost()
            source.startPAPTimer(withInterval: sourceLossTimeout)
        case .hasLevelsAndPAP:
            source.resetPAPTimer()
        }
    }

    /// Creates a new source with the information provided, and starts timers for per-address priority and
    /// source loss as required. Returns `nil` (and emits `.sourceLimitExceeded` once) if the source limit
    /// has been reached.
    ///
    /// - Parameters:
    ///    - cid: The unique identifier of the source.
    ///    - name: The name of the source as received.
    ///    - hostname: The hostname of the source.
    ///    - ipFamily: The IP family.
    ///    - sequence: The current sequence number.
    ///    - startCode: The DMX512-A START code.
    ///    - notify: Inout: Whether to notify.
    ///
    private func createSource(
        cid: UUID, name: String, hostname: String, ipFamily: ComponentSocketIPFamily, sequence: UInt8, startCode: DMX.STARTCode, notify: inout Bool
    ) -> ReceiverRawSource? {
        // notify universe data during and after the sampling period
        notify = true

        // if there is a source limit it must not have been reached
        if let sourceLimit, sources.count >= sourceLimit {
            if !sourceLimitExceededNotified {
                sourceLimitExceededNotified = true
                emit(.sourceLimitExceeded)
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

        let source = ReceiverRawSource(
            cid: cid, hostname: hostname, ipFamily: ipFamily, name: name, sequence: sequence, state: state, sourceLossTimeout: sourceLossTimeout)
        source.startPacketTimer()

        if sampling {
            switch startCode {
            case .null:
                // when in the sampling period waiting for per-address priority is not neccessary
                break
            case .perAddressPriority:
                // need to wait for levels (ignore per-address priority packets until a level packet is received)
                source.startPAPTimer(withInterval: sourceLossTimeout)
            }
        } else {
            // even if this is a per-address priority packet make sure level packets are being sent before notifying
            switch startCode {
            case .null:
                source.startPAPTimer(withInterval: perAddressPriorityWait)
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

    /// Checks if a sequence number is valid in relation to the previous number.
    ///
    /// - Parameters:
    ///    - newSequence: The new sequence number.
    ///    - previousSequence: The old sequence number.
    ///
    private func validSequence(_ newSequence: UInt8, previousSequence: UInt8) -> Bool {
        let seqnumCmp = Int8(bitPattern: newSequence) &- Int8(bitPattern: previousSequence)
        return (seqnumCmp > 0 || seqnumCmp <= -20)
    }

}

// MARK: -
// MARK: -

/// `ComponentSocketDelegate` conformance.
///
/// The receiver's sockets are actor-path sockets (`sACNRuntime.makeSocket`): they deliver on the event loop
/// this actor is isolated to, so these `nonisolated` methods `assumeIsolated` into the actor with no hop.
///
extension sACNReceiverRaw: ComponentSocketDelegate {

    nonisolated func receivedMessage(
        for socket: ComponentSocket, withData data: Data, sourceHostname: String, sourcePort: UInt16, ipFamily: ComponentSocketIPFamily
    ) {
        let socketId = socket.id
        assumeIsolated { $0.process(data: data, ipFamily: ipFamily, socketId: socketId, hostname: sourceHostname) }
    }

    nonisolated func socket(_ socket: ComponentSocket, socketDidCloseWith reason: SocketCloseReason) {
        let interface = socket.interface
        assumeIsolated { receiver in
            guard receiver.isListening else { return }
            receiver.emit(.socketClosed(interface: interface, reason: reason))
        }
    }

    nonisolated func debugLog(for socket: ComponentSocket, with logMessage: String) {
        assumeIsolated { $0.log(logMessage) }
    }

}
