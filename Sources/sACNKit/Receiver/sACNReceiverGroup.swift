//
//  sACNReceiverGroup.swift
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

/// sACN Receiver Group
///
/// An E1.31-2018 sACN Receiver which receives and merges sACN Messages from multiple universes.
///
/// This provides a convenience method to manage, and receive notifications from multiple `sACNReceiver`s.
/// All `sACNReceiver`s managed by this group listen on the same interface(s) and with the same
/// `sACNIPMode`. They also use the same source limit.
///
/// To allow discrete settings, instantiate and manage a number of `sACNReceiver`s directly.
final public class sACNReceiverGroup {

    /// A key used to identify the state queue for the current execution context.
    private static let stateQueueSpecificKey = DispatchSpecificKey<Bool>()

    /// The Internet Protocol version(s) used by the receivers in this group.
    private let ipMode: sACNIPMode

    /// The interfaces on which the receivers in this group should receive data.
    private var interfaces: Set<String> = []

    // MARK: Delegate

    /// Changes the receiver delegate of this receiver to the the object passed.
    ///
    /// - Parameters:
    ///   - delegate: The delegate to receive notifications.
    ///
    public func setDelegate(_ delegate: sACNReceiverGroupDelegate?) {
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

    /// The delegate which receives notifications from this receiver.
    private weak var delegate: sACNReceiverGroupDelegate?

    /// The delegate which receives debug log messages from this receiver.
    private weak var debugDelegate: sACNComponentDebugDelegate?

    /// The queue on which to send delegate notifications.
    private let delegateQueue: DispatchQueue

    /// The serial queue on which state is mutated.
    ///
    /// State stays serialized on this queue even if the client's delegate queue is
    /// concurrent; delegate notifications hop asynchronously to the delegate queue.
    /// Child receivers deliver their callbacks on this queue.
    private let stateQueue: DispatchQueue

    /// Executes work synchronized on the state queue, immediately when already on it.
    private func performOnStateQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: Self.stateQueueSpecificKey) == true {
            try work()
        } else {
            try stateQueue.sync { try work() }
        }
    }

    // MARK: General

    /// Whether preview data is filtered by this receivers.
    private let filterPreviewData: Bool

    /// An optional limit on the number of sources the receivers in this group accept.
    private let sourceLimit: Int?

    /// A list of CIDs this receiver should filter.
    private let filterCIDs: Set<UUID>

    /// The receivers, identified by their universe.
    private var receivers: [UInt16: sACNReceiver]

    // MARK: - Initialization

    /// Creates a new receiver to receive sACN for one or more universes.
    ///
    /// - Parameters:
    ///    - ipMode: Optional: IP mode for this receiver (IPv4/IPv6/Both).
    ///    - interfaces: The network interfaces for this receiver. An interface may be a name (e.g. "en1" or "lo0") or the corresponding IP address (e.g. "192.168.4.35").
    ///    - sourceLimit: The number of sources this receiver is able to process. This will be dependent on the hardware on which the receiver is running. Defaults to `4`.
    ///    - filterPreviewData: Optional: Whether source preview data should be filtered out (defaults to `true`).
    ///    - filtersCIDs: Optional: A list of CIDs which should be ignored (defaults to none).
    ///    - delegateQueue: A delegate queue on which to receive delegate calls from this receiver.
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interfaces must not be empty.
    ///
    public init(
        ipMode: sACNIPMode = .ipv4Only, interfaces: Set<String> = [], sourceLimit: Int? = 4, filterPreviewData: Bool = true,
        filterCIDs: Set<UUID> = [], delegateQueue: DispatchQueue
    ) {
        precondition(!ipMode.usesIPv6() || !interfaces.isEmpty, "At least one interface must be provided for IPv6.")

        self.ipMode = ipMode
        self.interfaces = interfaces
        self.filterPreviewData = filterPreviewData
        self.sourceLimit = sourceLimit
        self.filterCIDs = filterCIDs
        receivers = [:]
        self.delegateQueue = delegateQueue
        let stateQueue = DispatchQueue(label: "com.danielmurfin.sACNKit.receiverGroupState")
        stateQueue.setSpecific(key: Self.stateQueueSpecificKey, value: true)
        self.stateQueue = stateQueue
    }

    // MARK: Public API

    /// Adds a new universe to this receiver group.
    ///
    /// The universe number must be valid. If the universe has already been added,
    /// this returns successfully.
    ///
    /// - Parameters:
    ///    - universe: The universe number to add.
    ///
    /// - Throws: An `sACNReceiverValidationError` or `sACNComponentSocketError`..
    ///
    public func add(universe: UInt16) throws {
        guard universe.validUniverse() else { throw sACNReceiverValidationError.universeNumberInvalid }

        try performOnStateQueue { [self] in
            guard receivers[universe] == nil else { return }

            guard
                let receiver = sACNReceiver(
                    ipMode: ipMode, interfaces: interfaces, universe: universe, sourceLimit: sourceLimit, filterPreviewData: filterPreviewData,
                    filterCIDs: filterCIDs, delegateQueue: stateQueue)
            else {
                throw sACNReceiverValidationError.universeNumberInvalid
            }
            receivers[universe] = receiver
            receiver.setDelegate(self)
            try receiver.start()
        }
    }

    /// Removes a universe from this receiver group.
    ///
    /// If this universe does not exist, this returns successfully.
    ///
    /// - Parameters:
    ///    - universe: The universe number to remove.
    ///
    public func remove(universe: UInt16) {
        performOnStateQueue {
            _ = receivers.removeValue(forKey: universe)
        }
    }

    /// Updates the interfaces on which this receiver group listens for sACN Universe Discovery and Data messages.
    ///
    /// - Parameters:
    ///    - interfaces: The new interfaces for this receiver group. An interface may be a name (e.g. "en1" or "lo0") or the corresponding IP address (e.g. "192.168.4.35").
    ///    Empty interfaces means listen on all interfaces (IPv4 only).
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interfaces must not be empty.
    ///
    /// - Throws: An `sACNReceiverValidationError` error.
    ///
    public func updateInterfaces(_ newInterfaces: Set<String> = []) throws {
        precondition(!ipMode.usesIPv6() || !newInterfaces.isEmpty, "At least one interface must be provided for IPv6.")

        try performOnStateQueue {
            try receivers.forEach { _, receiver in
                try receiver.updateInterfaces(newInterfaces)
            }
        }
    }

    /// Retrieves source information such as CID, IP Address and name using a sources identifier.
    ///
    ///- Parameters:
    ///   - sourceId: The identifier of the source.
    ///   - universe: The universe for which to get the source information.
    ///
    /// - Throws: An `sACNReceiverValidationError` if the source cannot be found.
    ///
    /// - Returns: Source information.
    ///
    /// May be called from any queue, including from within delegate callbacks.
    public func information(for sourceId: UUID, on universe: UInt16) throws -> sACNReceiverSource {
        try performOnStateQueue {
            guard let receiver = receivers[universe] else { throw sACNReceiverValidationError.sourceDoesNotExist }
            return try receiver.information(for: sourceId)
        }
    }

}

/// sACN Receiver Group Extension
///
/// sACN Receiver Delegate Conformance.
extension sACNReceiverGroup: sACNReceiverDelegate {
    public func receiver(_ receiver: sACNReceiver, interface: String?, socketDidCloseWithError error: Error?) {
        let delegate = delegate
        delegateQueue.async { delegate?.receiverGroup(self, interface: interface, socketDidCloseWithError: error, forUniverse: receiver.universe) }
    }

    public func receiverMergedData(_ receiver: sACNReceiver, mergedData: sACNReceiverMergedData) {
        let delegate = delegate
        delegateQueue.async { delegate?.receiverGroupMergedData(self, mergedData: mergedData) }
    }

    public func receiverStartedSampling(_ receiver: sACNReceiver) {
        let delegate = delegate
        delegateQueue.async { delegate?.receiverGroupStartedSampling(self, forUniverse: receiver.universe) }
    }

    public func receiverEndedSampling(_ receiver: sACNReceiver) {
        let delegate = delegate
        delegateQueue.async { delegate?.receiverGroupEndedSampling(self, forUniverse: receiver.universe) }
    }

    public func receiver(_ receiver: sACNReceiver, lostSources: [UUID]) {
        let delegate = delegate
        delegateQueue.async { delegate?.receiverGroup(self, lostSources: lostSources, forUniverse: receiver.universe) }
    }

    public func receiverExceededSources(_ receiver: sACNReceiver) {
        let delegate = delegate
        delegateQueue.async { delegate?.receiverGroupExceededSources(self, forUniverse: receiver.universe) }
    }
}
