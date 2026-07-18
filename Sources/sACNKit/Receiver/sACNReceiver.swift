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
/// Combines the functionality of `sACNReceiverRaw` and `sACNMerger`.
///
/// An E1.31-2018 sACN Receiver which receives and merges sACN Messages from a single universe.
///
/// Provides merging of DMX512-A NULL start code (0x00) data.
/// It also supports per-address priority start code (0xdd) merging.
public class sACNReceiver {

    /// A key used to identify the state queue for the current execution context.
    private static let stateQueueSpecificKey = DispatchSpecificKey<Bool>()

    /// The universe for this receiver.
    public let universe: UInt16

    /// The receiver.
    /// Internal to allow tests to drive the merge pipeline without sockets.
    let receiver: sACNReceiverRaw

    /// The merger.
    private let merger: sACNMerger

    /// The merger for sources currently sampling.
    private let samplingMerger: sACNMerger

    /// The sources that have been received.
    private var sources: [UUID: ReceiverSource]

    /// The number of sources which are pending.
    private var numberOfPendingSources = 0

    /// Whether the merger is sampling.
    private var isSampling: Bool = true

    /// The receiver listening status.
    public var isListening: Bool {
        receiver.isListening
    }

    // MARK: Delegate

    /// Changes the receiver delegate of this receiver to the the object passed.
    ///
    /// Passing `nil` does not fence in-flight deliveries: a callback already enqueued
    /// may still be delivered to the previous delegate after this returns.
    ///
    /// - Parameters:
    ///   - delegate: The delegate to receive notifications.
    ///
    public func setDelegate(_ delegate: sACNReceiverDelegate?) {
        performOnStateQueue {
            self.delegate = delegate
        }
    }

    /// Changes the debug delegate of this receiver to the the object passed.
    ///
    /// - Parameters:
    ///   - delegate: The delegate to receive notifications.
    ///
    public func setDebugDelegate(_ delegate: sACNComponentDebugDelegate?) {
        performOnStateQueue {
            self.debugDelegate = delegate
        }
    }

    /// The delegate which receives notifications from this receiver merger.
    private weak var delegate: sACNReceiverDelegate?

    /// The delegate which receives debug log messages from this receiver.
    private weak var debugDelegate: sACNComponentDebugDelegate?

    /// The queue on which to send delegate notifications.
    private let delegateQueue: DispatchQueue

    /// The serial queue on which state is mutated.
    ///
    /// State stays serialized on this queue even if the client's delegate queue is
    /// concurrent; delegate notifications hop asynchronously to the delegate queue.
    private let stateQueue: DispatchQueue

    /// Executes work synchronized on the state queue, immediately when already on it.
    private func performOnStateQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: Self.stateQueueSpecificKey) == true {
            try work()
        } else {
            try stateQueue.sync { try work() }
        }
    }

    // MARK: - Initialization

    /// Creates a new receiver to receive sACN for a universe.
    ///
    /// If the universe provided is not valid, this initializes to nil.
    ///
    /// - Parameters:
    ///    - ipMode: Optional: IP mode for this receiver (IPv4/IPv6/Both).
    ///    - interfaces: The network interfaces for this receiver. An interface may be a name (e.g. "en1" or "lo0") or the corresponding IP address (e.g. "192.168.4.35").
    ///    - universe: The universe this receiver listens to.
    ///    - sourceLimit: The number of sources this receiver is able to process. This will be dependent on the hardware on which the receiver is running. Defaults to `4`.
    ///    - filterPreviewData: Optional: Whether source preview data should be filtered out (defaults to `true`).
    ///    - filtersCIDs: Optional: A list of CIDs which should be ignored (defaults to none).
    ///    - delegateQueue: A delegate queue on which to receive delegate calls from this receiver.
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interfaces must not be empty.
    ///
    public convenience init?(
        ipMode: sACNIPMode = .ipv4Only, interfaces: Set<String> = [], universe: UInt16, sourceLimit: Int? = 4, filterPreviewData: Bool = true,
        filterCIDs: Set<UUID> = [], delegateQueue: DispatchQueue
    ) {
        self.init(
            ipMode: ipMode, interfaces: interfaces, universe: universe, sourceLimit: sourceLimit, filterPreviewData: filterPreviewData,
            filterCIDs: filterCIDs, delegateQueue: delegateQueue, sourceLossTimeout: sACNReceiverRaw.sourceLossTimeout,
            perAddressPriorityWait: sACNReceiverRaw.perAddressPriorityWait)
    }

    /// Creates a new receiver, additionally allowing the timing constants to be overridden.
    ///
    /// Internal seam so tests can exercise timing-driven behavior quickly.
    ///
    init?(
        ipMode: sACNIPMode, interfaces: Set<String>, universe: UInt16, sourceLimit: Int?, filterPreviewData: Bool,
        filterCIDs: Set<UUID>, delegateQueue: DispatchQueue, sourceLossTimeout: UInt64, perAddressPriorityWait: UInt64
    ) {
        precondition(!ipMode.usesIPv6() || !interfaces.isEmpty, "At least one interface must be provided for IPv6.")

        // the universe provided must be valid
        guard universe.validUniverse() else { return nil }

        self.universe = universe
        let stateQueue = DispatchQueue(label: "com.danielmurfin.sACNKit.receiverState-\(universe)")
        stateQueue.setSpecific(key: Self.stateQueueSpecificKey, value: true)
        self.stateQueue = stateQueue
        guard
            let receiver = sACNReceiverRaw(
                ipMode: ipMode, interfaces: interfaces, universe: universe, sourceLimit: sourceLimit, filterPreviewData: filterPreviewData,
                filterCIDs: filterCIDs, delegateQueue: stateQueue, sourceLossTimeout: sourceLossTimeout,
                perAddressPriorityWait: perAddressPriorityWait)
        else { return nil }
        self.receiver = receiver
        let config = sACNMergerConfig(sourceLimit: sourceLimit)
        merger = sACNMerger(id: universe, config: config)
        samplingMerger = sACNMerger(id: universe, config: config)
        sources = [:]
        self.delegateQueue = delegateQueue
    }

    // MARK: Public API

    /// Starts this receiver.
    ///
    /// The receiver will begin listening for sACN Data messages and provide
    /// merged output using the delegate.
    ///
    /// - Throws: An error of type `sACNReceiverValidationError` or `sACNComponentSocketError`.
    ///
    public func start() throws {
        receiver.setDelegate(self)
        try receiver.start()
    }

    /// Stops this receiver.
    ///
    /// The receiver will stop listening for sACN Data messages and cease
    /// providing merged output.
    ///
    /// This is not a delivery barrier: callbacks already enqueued to the delegate
    /// queue may still be delivered after this returns.
    ///
    /// To receive again, prefer creating a fresh receiver instead of restarting this
    /// one: previously learned sources are not cleared from the merged output when
    /// the receiver is stopped, so a restart republishes them.
    ///
    public func stop() {
        receiver.stop()
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
        try receiver.updateInterfaces(newInterfaces)
    }

    /// Retrieves source information such as CID, IP Address and name using a sources identifier.
    ///
    ///- Parameters:
    ///   - sourceId: The identifier of the source.
    ///
    /// - Throws: An `sACNReceiverValidationError` if the source cannot be found.
    ///
    /// - Returns: Source information.
    ///
    /// May be called from any queue, including from within delegate callbacks.
    /// Reflects current state rather than a callback payload's snapshot, so it may
    /// throw for a source a just-delivered payload listed as active.
    public func information(for sourceId: UUID) throws -> sACNReceiverSource {
        try performOnStateQueue {
            guard let source = sources[sourceId] else { throw sACNReceiverValidationError.sourceDoesNotExist }
            return sACNReceiverSource(receiverSource: source)
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
        isSampling = true
        let delegate = delegate
        delegateQueue.async { delegate?.receiverStartedSampling(self) }
    }

    /// The receiver ended sampling.
    private func samplingEnded() {
        isSampling = false

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

        let delegate = delegate
        delegateQueue.async { delegate?.receiverEndedSampling(self) }
    }

    /// The receiver lost sources.
    ///
    /// - Parameters:
    ///    - sourceIds: The identifiers of the source which were lost.
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

        let delegate = delegate
        delegateQueue.async { delegate?.receiver(self, lostSources: sourceIds) }
    }

    /// The receiver lost per-address priority for a source.
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
    }

    /// The receiver discovered too many sources.
    private func sourceLimitExceeded() {
        let delegate = delegate
        delegateQueue.async { delegate?.receiverExceededSources(self) }
    }

    /// Notifies the new merge values.
    private func notifyMerge() {
        let activeSources = sources.compactMap { !$0.value.sampling ? $0.value.cid : nil }
        let mergedNotification = sACNReceiverMergedData(
            universe: universe, levels: merger.levels, winners: merger.winners, activeSources: activeSources,
            numberOfActiveSources: activeSources.count)
        let delegate = delegate
        delegateQueue.async { delegate?.receiverMergedData(self, mergedData: mergedNotification) }
    }

}

/// sACN Receiver Extension
///
/// sACN Receiver Raw Delegate Conformance.
extension sACNReceiver: sACNReceiverRawDelegate {
    public func receiver(_ receiver: sACNReceiverRaw, interface: String?, socketDidCloseWithError error: Error?) {
        let delegate = delegate
        delegateQueue.async { delegate?.receiver(self, interface: interface, socketDidCloseWithError: error) }
    }

    public func receiverReceivedUniverseData(_ receiver: sACNReceiverRaw, sourceData: sACNReceiverRawSourceData) {
        mergeData(from: sourceData)
    }

    public func receiverStartedSampling(_ receiver: sACNReceiverRaw) {
        samplingStarted()
    }

    public func receiverEndedSampling(_ receiver: sACNReceiverRaw) {
        samplingEnded()
    }

    public func receiver(_ receiver: sACNReceiverRaw, lostSources: [UUID]) {
        sourcesLost(lostSources)
    }

    public func receiver(_ receiver: sACNReceiverRaw, lostPerAddressPriorityFor source: UUID) {
        perAddressPriorityLost(for: source)
    }

    public func receiverExceededSources(_ receiver: sACNReceiverRaw) {
        sourceLimitExceeded()
    }

}

/// sACN Receiver Validation Error
///
/// Enumerates all possible `sACNReceiver` parsing errors.
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
