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
/// Discovers and provides information on sACN sources by receiving E1.31-2018 universe discovery messages.
///
/// A `sACNDiscoveryReceiver` is an `actor` isolated to an internal `sACNRuntime` (the shared NIO event
/// loop). Its lifecycle and mutation API are `async`; discovered source information arrives on the
/// `discovery` `AsyncStream`, lifecycle events (source loss, socket closed) on `events`, and debug logs on
/// the separate `debugLog` stream, rather than via a delegate.
public actor sACNDiscoveryReceiver {

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

    /// An event emitted by a discovery receiver.
    public enum Event: Sendable {

        /// One or more sources were lost (coalesced to reduce notifications).
        case sourcesLost([UUID])

        /// A socket closed with an error (per interface).
        case socketClosed(interface: String?, reason: SocketCloseReason)

    }

    /// The broadcast hub backing `discovery`.
    private nonisolated let discoveryHub = AsyncStreamHub<sACNDiscoveryReceiverSource>(bufferingPolicy: .bufferingNewest(64))

    /// A stream of discovered source information (CID, name, universe list).
    ///
    /// Each access returns an independent subscription. Buffering keeps the most recent 64 updates for a
    /// slow consumer (per-source, low rate) rather than collapsing to the latest, and debug logs are
    /// delivered on the separate `debugLog` stream.
    public nonisolated var discovery: AsyncStream<sACNDiscoveryReceiverSource> { discoveryHub.stream() }

    /// The broadcast hub backing `events`.
    private nonisolated let eventsHub = AsyncStreamHub<Event>(bufferingPolicy: .bufferingNewest(64))

    /// A stream of receiver lifecycle events. Each access returns an independent subscription.
    public nonisolated var events: AsyncStream<Event> { eventsHub.stream() }

    /// The broadcast hub backing `debugLog`.
    private nonisolated let debugLogHub = AsyncStreamHub<String>(bufferingPolicy: .bufferingNewest(64))

    /// A stream of human-readable debug log messages, kept separate from `events` so verbose logging never
    /// competes with lifecycle events for buffer space. Each access returns an independent subscription.
    public nonisolated var debugLog: AsyncStream<String> { debugLogHub.stream() }

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

    // MARK: General

    /// The discovered sources and their universes.
    private var sources: [UUID: DiscoveryReceiverSource] = [:]

    // MARK: Timers

    /// The main heartbeat interval (500 ms), driving source-loss evaluation.
    private static let heartbeatInterval: Duration = .milliseconds(500)

    /// The heartbeat timer.
    private var heartbeatTask: (any RuntimeTask)?

    // MARK: - Initialization

    /// Creates a new receiver to receive sACN discovery messages.
    ///
    /// - Parameters:
    ///    - ipMode: Optional: IP mode for this receiver (IPv4/IPv6/Both).
    ///    - interfaces: The network interfaces for this receiver. An interface may be a name (e.g. "en1" or "lo0") or the corresponding IP address (e.g. "192.168.4.35").
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interfaces must not be empty.
    ///
    public init(ipMode: sACNIPMode = .ipv4Only, interfaces: Set<String> = []) {
        precondition(!ipMode.usesIPv6() || !interfaces.isEmpty, "At least one interface must be provided for IPv6.")

        let runtime = NIORuntime()
        self.runtime = runtime
        self.ipMode = ipMode
        if interfaces.isEmpty {
            self.sockets = ["": runtime.makeSocket(type: .receive, ipMode: ipMode, port: UDP.sdtPort)]
        } else {
            self.sockets = interfaces.reduce(into: [String: ComponentSocket]()) { dict, interface in
                dict[interface] = runtime.makeSocket(type: .receive, ipMode: ipMode, port: UDP.sdtPort)
            }
        }
    }

    deinit {
        // The heartbeat task self-cancels when released; the sockets close on dealloc. Finish the hubs so
        // any active consumers terminate rather than hang.
        discoveryHub.finish()
        eventsHub.finish()
        debugLogHub.finish()
    }

    // MARK: - Public API

    /// Starts this discovery receiver.
    ///
    /// The receiver binds its sockets, joins the universe-discovery multicast group, and begins listening
    /// for sACN Universe Discovery messages delivered on `discovery`.
    ///
    /// - Throws: An error of type `sACNReceiverValidationError` or `sACNComponentSocketError`.
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
        sources = [:]

        do {
            for (interface, socket) in sockets {
                try await listenForSocket(socket, on: interface.isEmpty ? nil : interface)
                // A `stop()` that interleaved this bind closed the sockets; unwind rather than proceed.
                if gate.stopRequested { throw CancellationError() }
            }
        } catch {
            // Roll back: close anything opened, return to idle, and release any waiting `stop()` caller.
            // When a stop superseded the start, report `CancellationError` uniformly - a mid-bind abort
            // already throws it, but a mid-*join* abort surfaces the socket's `couldNotJoin`, a spurious
            // multicast failure that is not the real outcome.
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
    }

    /// Stops this receiver, suspending until teardown completes.
    ///
    /// The receiver stops the heartbeat, closes its sockets (leaving the multicast group), and returns to
    /// idle. From `.listening` this **awaits the actual socket close** - a receiver has nothing to flush -
    /// so a subsequent `start()` on the fixed sACN port is deterministic. Superseding an in-flight
    /// `start()`/`updateInterfaces()` instead aborts it and resolves once it unwinds; those channels close
    /// asynchronously, but `SO_REUSEPORT` keeps an immediate re-bind safe.
    ///
    public func stop() async {
        switch gate.state {
        case .idle:
            return
        case .starting, .reconfiguring:
            // Supersede the in-flight start/reconfigure: close the sockets (which aborts any in-flight
            // bind) and flag it; that operation observes `stopRequested` and unwinds to idle, resuming us.
            gate.requestStop()
            sockets.values.forEach { $0.close() }
            await withCheckedContinuation { gate.addStopWaiter($0) }
        case .listening:
            await teardown()
        case .stopping:
            // A teardown is already underway; wait for the same completion.
            await withCheckedContinuation { gate.addStopWaiter($0) }
        }
    }

    /// Tears down from `.listening` (or a superseded `.reconfiguring`): stops the heartbeat, closes every
    /// socket (awaiting the close), clears state, and reaches idle.
    private func teardown() async {
        gate.toStopping()
        stopHeartbeat()
        for socket in sockets.values {
            socket.delegate = nil
            await socket.stopListening()
        }
        sources = [:]
        reachedIdle()
    }

    /// Returns to idle and resumes every waiting `stop()` caller. Called from `teardown()` and from
    /// `start()`'s stop-superseded rollback.
    private func reachedIdle() {
        gate.reachedIdle().forEach { $0.resume() }
    }

    /// Updates the interfaces on which this receiver listens for sACN Universe Discovery messages.
    ///
    /// - Parameters:
    ///    - newInterfaces: The new interfaces. An interface may be a name (e.g. "en1"/"lo0") or an IP.
    ///      Empty means all interfaces (IPv4 only).
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interfaces must not be empty.
    ///
    /// - Throws: `sACNReceiverValidationError.receiverBusy` if a start/stop/reconfigure is in flight;
    ///   otherwise `sACNComponentSocketError` if a bind fails (the change then rolls back all-or-nothing).
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
            keysToRemove.forEach { sockets.removeValue(forKey: $0) }
            for key in keysToAdd {
                sockets[key] = runtime.makeSocket(type: .receive, ipMode: ipMode, port: UDP.sdtPort)
            }
            return
        }

        // Listening: reserve `.reconfiguring` and bind + join every new socket into a temp map first. If any
        // fails (or a `stop()` interleaves), discard the temp sockets and leave the live set untouched.
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
            // Report a supersede as `CancellationError` (a mid-join abort otherwise surfaces couldNotJoin).
            throw superseded ? CancellationError() : error
        }

        // Commit: close the removed sockets, then install the freshly bound ones. Nil the delegate before
        // the fire-and-forget close so an in-flight datagram from a just-removed interface cannot still
        // enter `process()` before the async close lands. Fire-and-forget is deliberate here: there is
        // nothing to flush, and `SO_REUSEPORT` keeps rebinding the fixed port safe.
        for key in keysToRemove {
            if let socket = sockets.removeValue(forKey: key) {
                socket.delegate = nil
                socket.close()
            }
        }
        for (key, socket) in boundSockets {
            sockets[key] = socket
        }
        await finishReconfigure()
    }

    /// Restores the lifecycle after a `.reconfiguring` reservation: back to `.listening`, or - if a
    /// `stop()` interleaved and set `stopRequested` - through teardown to idle (resuming that caller).
    private func finishReconfigure() async {
        if gate.stopRequested {
            await teardown()
        } else {
            gate.toListening()
        }
    }

    // MARK: General

    /// Attempts to start listening for a socket on an optional interface, joining the discovery multicast
    /// group for each enabled family.
    ///
    /// - Parameters:
    ///    - socket: The socket to start listening.
    ///    - interface: Optional: An optional interface on which to listen (`nil` means all interfaces).
    ///
    private func listenForSocket(_ socket: ComponentSocket, on interface: String? = nil) async throws {
        socket.delegate = self
        try await socket.startListeningAndJoin(
            onInterface: interface, ipMode: ipMode, ipv4Group: IPv4.universeDiscoveryHostname,
            ipv6Group: IPv6.universeDiscoveryHostname)
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

    /// The heartbeat tick: evaluates source loss while listening (guarded so a tick that outlived the
    /// listening window does nothing).
    private func heartbeatTick() {
        guard gate.isListening else { return }
        checkForSourceLoss()
    }

    /// Checks for source loss, coalescing every lost source into a single `.sourcesLost` event and removing
    /// them. Internal (not lifecycle-guarded) so the loss path can be characterization-tested via the seam.
    func checkForSourceLoss() {
        var removeLostSources: Set<UUID> = []
        sources.forEach { id, source in
            if source.isTimerExpired {
                removeLostSources.insert(id)
            }
        }

        if !removeLostSources.isEmpty {
            eventsHub.yield(.sourcesLost(Array(removeLostSources)))
        }

        removeLostSources.forEach { sourceId in
            sources.removeValue(forKey: sourceId)
        }
    }

    // MARK: Test seams

    /// Test seam: the number of sources currently tracked (for asserting discovery/source-loss state).
    var trackedSourceCount: Int {
        sources.count
    }

    /// Test seam: forces every tracked source's loss timer to expire, so the source-loss path can be
    /// exercised without waiting the 20 s discovery timeout. `interval: 0` means "already expired".
    func expireAllSourceTimersForTesting() {
        sources.values.forEach { $0.timer.start(interval: 0) }
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
    /// Internal so the receiver's paged-assembly behavior can be characterization-tested by injecting
    /// packets directly (`await receiver.process(data:)`).
    ///
    /// - Parameters:
    ///    - data: The data to process.
    ///
    func process(data: Data) {
        do {
            let rootLayer = try RootLayer.parse(fromData: data)

            switch rootLayer.vector {
            case .extended:
                try processExtendedPacket(rootLayer: rootLayer)
            case .data:
                // handled by sACNReceiverRaw
                break
            }
        } catch let error as RootLayerValidationError {
            debugLogHub.yield(error.logDescription)
        } catch let error as UniverseDiscoveryFramingLayerValidationError {
            debugLogHub.yield(error.logDescription)
        } catch let error as UniverseDiscoveryLayerValidationError {
            debugLogHub.yield(error.logDescription)
        } catch {
            // unknown error
        }
    }

    // MARK: Extended

    /// Processes an sACN extended packet.
    ///
    /// - Parameters:
    ///    - rootLayer: The root layer to process.
    ///
    private func processExtendedPacket(rootLayer: RootLayer) throws {
        let framingLayer = try UniverseDiscoveryFramingLayer.parse(fromData: rootLayer.data)
        let discoveryLayer = try UniverseDiscoveryLayer.parse(fromData: framingLayer.data)

        processUniverseDiscovery(cid: rootLayer.cid, name: framingLayer.sourceName, discoveryLayer: discoveryLayer)
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
                let existingUniverseBlock =
                    source.universes.count >= source.nextUniverseIndex + universeCount
                    ? Array(source.universes[source.nextUniverseIndex..<source.nextUniverseIndex + universeCount]) : []
                if universeCount > numberOfRemainingUniverses || (page == lastPage && universeCount < numberOfRemainingUniverses)
                    || existingUniverseBlock != discoveryLayer.universeList
                {
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
                            let info = sACNDiscoveryReceiverSource(cid: cid, name: name, universes: source.universes)
                            discoveryHub.yield(info)
                        }
                    }
                }
            }
        }
    }

    /// Creates a new discovery source with the information provided, and starts its timer.
    ///
    /// - Parameters:
    ///    - cid: The unique identifier of the source.
    ///    - name: The name of the source.
    ///
    private func createDiscoverySource(cid: UUID, name: String) {
        let source = DiscoveryReceiverSource(name: name)
        sources[cid] = source
        source.startTimer()
    }

}

// MARK: -
// MARK: -

/// `ComponentSocketDelegate` conformance.
///
/// The receiver's sockets are actor-path sockets (`sACNRuntime.makeSocket`): they deliver on the event loop
/// this actor is isolated to, so these `nonisolated` methods `assumeIsolated` into the actor with no hop.
///
extension sACNDiscoveryReceiver: ComponentSocketDelegate {

    nonisolated func receivedMessage(
        for socket: ComponentSocket, withData data: Data, sourceHostname: String, sourcePort: UInt16, ipFamily: ComponentSocketIPFamily
    ) {
        assumeIsolated { $0.process(data: data) }
    }

    nonisolated func socket(_ socket: ComponentSocket, socketDidCloseWith reason: SocketCloseReason) {
        let interface = socket.interface
        assumeIsolated { receiver in
            guard receiver.isListening else { return }
            receiver.eventsHub.yield(.socketClosed(interface: interface, reason: reason))
        }
    }

    nonisolated func debugLog(for socket: ComponentSocket, with logMessage: String) {
        assumeIsolated { $0.debugLogHub.yield(logMessage) }
    }

}
