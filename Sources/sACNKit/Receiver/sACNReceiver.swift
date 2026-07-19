//
//  sACNReceiver.swift
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

/// sACN Receiver
///
/// Combines the functionality of `sACNReceiverRaw` and `sACNMerger`, receiving and merging (HTP +
/// per-address priority) sACN messages from a single universe.
///
/// A `sACNReceiver` is an `actor` that owns a `sACNReceiverRaw` on the **same** runtime/event loop, so the
/// raw receiver delivers each packet into the merge synchronously on the loop (via `RawReceiverSink`) with
/// no `Task` hop - the actor equivalent of the previous shared state queue. Merged output arrives on the
/// `data` `AsyncStream`, lifecycle events on `events`, and debug logs on `debugLog`, rather than via a
/// delegate.
///
public actor sACNReceiver {

    // MARK: Runtime / isolation

    /// The runtime hosting this actor's isolation - **shared with `receiver`** so the raw receiver's on-loop
    /// `assumeIsolated` sink delivery into this actor is valid.
    nonisolated let runtime: sACNRuntime

    /// Pins this actor to the runtime's serial executor (the shared NIO event loop) - the same loop its owned
    /// `sACNReceiverRaw` runs on, so the raw delivers into the merge synchronously on-loop.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        runtime.serialExecutor.asUnownedSerialExecutor()
    }

    // MARK: Events

    /// An event emitted by a receiver.
    public enum Event: Sendable {

        /// The initial sampling period for the universe began.
        case samplingStarted

        /// The initial sampling period for the universe ended.
        case samplingEnded

        /// One or more sources were lost (coalesced).
        case sourcesLost([UUID])

        /// A source stopped sending per-address priority; its levels revert to universe priority in the merge.
        case perAddressPriorityLost(UUID)

        /// The receiver's source limit was reached (a new source was dropped).
        case sourceLimitExceeded

        /// A socket closed with an error (per interface).
        case socketClosed(interface: String?, reason: SocketCloseReason)

    }

    /// The broadcast hub backing `data`. Buffers newest-1: each merged frame is a complete DMX snapshot, so a
    /// slow consumer should get the latest frame rather than replay a backlog of stale ones.
    private nonisolated let dataHub = AsyncStreamHub<sACNReceiverMergedData>(bufferingPolicy: .bufferingNewest(1))

    /// A stream of merged universe data. Each access returns an independent subscription.
    public nonisolated var data: AsyncStream<sACNReceiverMergedData> { dataHub.stream() }

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

    // MARK: General

    /// The universe for this receiver.
    public let universe: UInt16

    /// The raw receiver. Internal so tests can drive the merge pipeline via `receiver.process(...)`.
    let receiver: sACNReceiverRaw

    /// The merger.
    private let merger: sACNMerger

    /// The merger for sources currently sampling.
    private let samplingMerger: sACNMerger

    /// The sources that have been received.
    private var sources: [UUID: ReceiverSource] = [:]

    /// The number of sources which are pending.
    private var numberOfPendingSources = 0

    /// Whether this receiver is actively listening (delegates to the raw receiver, which shares this loop).
    public var isListening: Bool {
        get async { await receiver.isListening }
    }

    // MARK: - Initialization

    /// Creates a new receiver to receive merged sACN for a universe.
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
            ipMode: ipMode, interfaces: interfaces, universe: universe, sourceLimit: sourceLimit, filterPreviewData: filterPreviewData,
            filterCIDs: filterCIDs, sourceLossTimeout: sACNReceiverRaw.sourceLossTimeout,
            perAddressPriorityWait: sACNReceiverRaw.perAddressPriorityWait)
    }

    /// Creates a new receiver, additionally allowing the timing constants to be overridden. Internal seam so
    /// tests can exercise timing-driven behavior quickly.
    init?(
        ipMode: sACNIPMode, interfaces: Set<String>, universe: UInt16, sourceLimit: Int?, filterPreviewData: Bool,
        filterCIDs: Set<UUID>, sourceLossTimeout: UInt64, perAddressPriorityWait: UInt64
    ) {
        precondition(!ipMode.usesIPv6() || !interfaces.isEmpty, "At least one interface must be provided for IPv6.")
        guard universe.validUniverse() else { return nil }

        // The raw receiver MUST share this receiver's runtime: the merge runs synchronously on-loop via the
        // `RawReceiverSink`, whose `assumeIsolated` is only valid because both actors share this executor.
        let runtime = NIORuntime()
        guard
            let receiver = sACNReceiverRaw(
                runtime: runtime, ipMode: ipMode, interfaces: interfaces, universe: universe, sourceLimit: sourceLimit,
                filterPreviewData: filterPreviewData, filterCIDs: filterCIDs, sourceLossTimeout: sourceLossTimeout,
                perAddressPriorityWait: perAddressPriorityWait)
        else { return nil }

        self.runtime = runtime
        self.universe = universe
        self.receiver = receiver
        // Enable per-address-priority-active and universe-priority output tracking (the values are surfaced on
        // `sACNReceiverMergedData`). This only computes those outputs; it does not change the merged levels or
        // winners, and nothing is transmitted (this is a receive-side merge).
        let config = sACNMergerConfig(transmitPerAddressPriorities: false, universePriority: 0, sourceLimit: sourceLimit)
        self.merger = sACNMerger(id: universe, config: config)
        self.samplingMerger = sACNMerger(id: universe, config: config)
    }

    deinit {
        dataHub.finish()
        eventsHub.finish()
        debugLogHub.finish()
    }

    // MARK: - Public API

    /// Starts this receiver: begins listening for sACN Data messages and providing merged output on `data`.
    ///
    /// - Throws: `sACNReceiverValidationError` or `sACNComponentSocketError`.
    ///
    public func start() async throws {
        await receiver.setSink(self)
        try await receiver.start()
    }

    /// Stops this receiver, suspending until teardown completes.
    ///
    /// Previously-learned sources are not cleared from the merged output when the receiver stops, so a
    /// restart republishes them - prefer creating a fresh receiver to receive again.
    ///
    public func stop() async {
        await receiver.stop()
    }

    /// Updates the interfaces on which this receiver listens for sACN Data messages.
    ///
    /// - Parameters:
    ///    - newInterfaces: The new interfaces. Empty means all interfaces (IPv4 only).
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interfaces must not be empty.
    ///
    /// - Throws: `sACNReceiverValidationError` or `sACNComponentSocketError`.
    ///
    public func updateInterfaces(_ newInterfaces: Set<String> = []) async throws {
        try await receiver.updateInterfaces(newInterfaces)
    }

    /// Retrieves source information (CID, IP address, name) for a source identifier.
    ///
    /// Reflects current state rather than a callback payload's snapshot, so it may throw for a source a
    /// just-delivered payload listed as active.
    ///
    /// - Parameters:
    ///    - sourceId: The identifier of the source.
    ///
    /// - Throws: `sACNReceiverValidationError.sourceDoesNotExist` if the source cannot be found.
    ///
    /// - Returns: Source information.
    ///
    public func information(for sourceId: UUID) throws -> sACNReceiverSource {
        guard let source = sources[sourceId] else { throw sACNReceiverValidationError.sourceDoesNotExist }
        let mergerSource = (source.sampling ? samplingMerger : merger).source(identified: sourceId)
        return sACNReceiverSource(receiverSource: source, mergerSource: mergerSource)
    }

    // MARK: Raw event handling

    /// Dispatches a raw receiver event (delivered synchronously via the sink) to the merge handlers.
    private func handle(rawEvent: sACNReceiverRaw.Event) {
        switch rawEvent {
        case .samplingStarted:
            samplingStarted()
        case .samplingEnded:
            samplingEnded()
        case .sourcesLost(let sourceIds):
            sourcesLost(sourceIds)
        case .perAddressPriorityLost(let sourceId):
            perAddressPriorityLost(for: sourceId)
        case .sourceLimitExceeded:
            eventsHub.yield(.sourceLimitExceeded)
        case .socketClosed(let interface, let reason):
            eventsHub.yield(.socketClosed(interface: interface, reason: reason))
        }
    }

    // MARK: Merging

    /// Merges new source data from the receiver.
    ///
    /// - Parameters:
    ///    - sourceData: The new source data.
    ///
    private func mergeData(from sourceData: sACNReceiverRawSourceData) {
        let isSampling = sourceData.isSampling
        let merger = isSampling ? samplingMerger : merger

        if let source = sources[sourceData.cid] {
            // update source info
            source.name = sourceData.name
            source.hostname = sourceData.hostname

            // The source is pending until the first 0x00 packet is received.
            // After the sampling period, this indicates that 0xdd must have either already been notified or timed out.
            if source.pending && sourceData.startCode == .null {
                source.pending = false
                numberOfPendingSources -= 1
            }
        } else {
            // add a source to the merger (as appropriate)
            try? merger.addSource(identified: sourceData.cid)

            // store the source
            let pending = sourceData.startCode == .perAddressPriority
            let source = ReceiverSource(sourceData: sourceData, pending: pending)
            sources[sourceData.cid] = source

            if pending {
                numberOfPendingSources += 1
            }
        }

        switch sourceData.startCode {
        case .null:
            try? merger.updateLevelsForSource(identified: sourceData.cid, newLevels: sourceData.values, newLevelsCount: sourceData.valuesCount)
            try? merger.updateUniversePriorityForSource(identified: sourceData.cid, priority: sourceData.priority)
        case .perAddressPriority:
            try? merger.updatePAPForSource(identified: sourceData.cid, newPriorities: sourceData.values, newPrioritiesCount: sourceData.valuesCount)
        }

        // notify if needed
        if !isSampling && numberOfPendingSources == 0 {
            notifyMerge()
        }
    }

    /// The receiver started sampling.
    private func samplingStarted() {
        eventsHub.yield(.samplingStarted)
    }

    /// The receiver ended sampling.
    private func samplingEnded() {
        sources.forEach { cid, source in
            guard source.sampling else { return }
            guard let sourceData = samplingMerger.source(identified: cid) else { return }

            // add the source to the main merger
            try? merger.addSource(identified: cid)

            // copy sampling levels and universe priority to the main merger
            // (the merger snapshot holds fixed 512-slot arrays, but the update methods
            // require the array to match the received count, so slice before passing)
            try? merger.updateLevelsForSource(
                identified: cid, newLevels: Array(sourceData.levels.prefix(sourceData.levelCount)), newLevelsCount: sourceData.levelCount)
            try? merger.updateUniversePriorityForSource(identified: cid, priority: sourceData.universePriority)

            // copy per-address priority to the main merger
            if !sourceData.usingUniversePriority {
                try? merger.updatePAPForSource(
                    identified: cid, newPriorities: Array(sourceData.addressPriorities.prefix(sourceData.perAddressPriorityCount)),
                    newPrioritiesCount: sourceData.perAddressPriorityCount)
            }

            // remove the source from the sampling merger
            try? samplingMerger.removeSource(identified: cid)

            source.sampling = false
        }

        if sources.count > 0 && numberOfPendingSources == 0 {
            notifyMerge()
        }

        eventsHub.yield(.samplingEnded)
    }

    /// The receiver lost sources.
    ///
    /// - Parameters:
    ///    - sourceIds: The identifiers of the sources which were lost.
    ///
    private func sourcesLost(_ sourceIds: [UUID]) {
        var nonSamplingMergeOccurred = false
        for sourceId in sourceIds {
            guard let source = sources[sourceId] else { continue }
            let merger = source.sampling ? samplingMerger : merger
            try? merger.removeSource(identified: sourceId)
            if !nonSamplingMergeOccurred {
                nonSamplingMergeOccurred = !source.sampling
            }

            // a lost source which never delivered levels must release its
            // pending count, or merged data is gated forever
            if source.pending {
                numberOfPendingSources -= 1
            }
            sources.removeValue(forKey: sourceId)
        }

        if nonSamplingMergeOccurred && numberOfPendingSources == 0 {
            notifyMerge()
        }

        eventsHub.yield(.sourcesLost(sourceIds))
    }

    /// The receiver lost per-address priority for a source: the merge reverts it to universe priority and a
    /// `.perAddressPriorityLost` event is emitted.
    ///
    /// - Parameters:
    ///    - sourceId: The identifier of the source which lost per-address priority.
    ///
    private func perAddressPriorityLost(for sourceId: UUID) {
        guard let source = sources[sourceId] else { return }
        let merger = source.sampling ? samplingMerger : merger

        try? merger.removePAP(forSourceIdentified: sourceId)

        if !source.sampling && numberOfPendingSources == 0 {
            notifyMerge()
        }

        eventsHub.yield(.perAddressPriorityLost(sourceId))
    }

    /// Notifies the new merge values on `data`.
    private func notifyMerge() {
        let activeSources = sources.compactMap { !$0.value.sampling ? $0.value.cid : nil }
        let mergedNotification = sACNReceiverMergedData(
            universe: universe, levels: merger.levels, winners: merger.winners, perAddressPriorities: merger.perAddressPriorities,
            perAddressPrioritiesActive: merger.perAddressPrioritiesActive ?? false, universePriority: merger.universePriority ?? 0,
            activeSources: activeSources, numberOfActiveSources: activeSources.count)
        dataHub.yield(mergedNotification)
    }

}

// MARK: -
// MARK: -

/// `RawReceiverSink` conformance.
///
/// The raw receiver shares this actor's event loop, so it delivers on the loop and these `nonisolated`
/// methods `assumeIsolated` into this actor with no hop - the ordered per-packet merge pipeline.
///
extension sACNReceiver: RawReceiverSink {

    nonisolated func rawReceiverDidReceive(_ data: sACNReceiverRawSourceData) {
        assumeIsolated { $0.mergeData(from: data) }
    }

    nonisolated func rawReceiverDidEmit(_ event: sACNReceiverRaw.Event) {
        assumeIsolated { $0.handle(rawEvent: event) }
    }

    nonisolated func rawReceiverDidLog(_ message: String) {
        assumeIsolated { $0.debugLogHub.yield(message) }
    }

}

// MARK: -
// MARK: -

/// sACN Receiver Validation Error
///
/// Enumerates all possible `sACNReceiver` validation errors.
public enum sACNReceiverValidationError: LocalizedError, Sendable {

    /// The receiver is started.
    case receiverStarted

    /// The receiver is busy with an in-flight start, stop or interface reconfiguration.
    case receiverBusy

    /// The universe number is invalid.
    case universeNumberInvalid

    /// The source does not exist.
    case sourceDoesNotExist

    /// A human-readable description of the error useful for logging purposes.
    public var logDescription: String {
        switch self {
        case .receiverStarted:
            return "The receiver is already started"
        case .receiverBusy:
            return "The receiver is busy starting, stopping or reconfiguring"
        case .universeNumberInvalid:
            return "The universe number is invalid"
        case .sourceDoesNotExist:
            return "The source does not exist"
        }
    }

}
