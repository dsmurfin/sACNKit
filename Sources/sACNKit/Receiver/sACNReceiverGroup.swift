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
/// An E1.31-2018 sACN Receiver which receives and merges sACN Messages from multiple universes, managing a
/// number of `sACNReceiver`s behind a single API. All managed receivers share the same interfaces, IP mode
/// and source limit; instantiate `sACNReceiver`s directly for discrete settings.
///
/// A `sACNReceiverGroup` is an `actor`. Each child `sACNReceiver` owns its own runtime (its own serial
/// executor, hence its own isolation); the group consumes each child's streams via a per-child `Task` and
/// re-yields (tagging the universe) into its own `data`/`events`/`debugLog` streams - a one-way async
/// fan-in, so a group of actors never has to synchronously drive an actor child. The fan-in is async, so it
/// stays correct regardless of whether a child's underlying event loop happens to coincide with another's.
///
public actor sACNReceiverGroup {

    // MARK: Runtime / isolation

    /// The runtime hosting this actor's isolation. Each child owns a separate runtime (a distinct executor
    /// and isolation), though the underlying event loops are drawn from a shared group and may coincide.
    nonisolated let runtime: sACNRuntime

    /// Pins this actor to its runtime's serial executor. Each child owns a separate runtime/executor and
    /// fans in via async `Task`s, so the group never synchronously drives a child - correct whether or not
    /// their underlying event loops coincide.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        runtime.serialExecutor.asUnownedSerialExecutor()
    }

    // MARK: Events

    /// An event emitted by a receiver group, tagged with the universe it came from.
    public enum Event: Sendable {

        /// The initial sampling period for a universe began.
        case samplingStarted(universe: UInt16)

        /// The initial sampling period for a universe ended.
        case samplingEnded(universe: UInt16)

        /// One or more sources were lost for a universe (coalesced).
        case sourcesLost([UUID], universe: UInt16)

        /// A universe's source limit was reached (a new source was dropped).
        case sourceLimitExceeded(universe: UInt16)

        /// A socket closed with an error (per interface and universe).
        case socketClosed(interface: String?, reason: SocketCloseReason, universe: UInt16)

    }

    /// The broadcast hub backing `data`. Buffers newest-1: each merged frame is a complete DMX snapshot for
    /// its universe, so a slow consumer should get the latest rather than replay a backlog of stale frames.
    private nonisolated let dataHub = AsyncStreamHub<sACNReceiverMergedData>(bufferingPolicy: .bufferingNewest(1))

    /// A stream of merged universe data (the universe is carried in the payload). Each access returns an
    /// independent subscription.
    public nonisolated var data: AsyncStream<sACNReceiverMergedData> { dataHub.stream() }

    /// The broadcast hub backing `events`.
    private nonisolated let eventsHub = AsyncStreamHub<Event>(bufferingPolicy: .bufferingNewest(64))

    /// A stream of receiver-group lifecycle events. Each access returns an independent subscription.
    /// Best-effort, drop-oldest (buffers newest-64): a consumer that stalls for long enough can miss an event
    /// such as `.sourcesLost` (a delta from the old never-drop delegate callbacks).
    public nonisolated var events: AsyncStream<Event> { eventsHub.stream() }

    /// The broadcast hub backing `debugLog`.
    private nonisolated let debugLogHub = AsyncStreamHub<String>(bufferingPolicy: .bufferingNewest(64))

    /// A stream of human-readable debug log messages. Each access returns an independent subscription.
    public nonisolated var debugLog: AsyncStream<String> { debugLogHub.stream() }

    // MARK: General

    /// The Internet Protocol version(s) used by the receivers in this group.
    private let ipMode: sACNIPMode

    /// Whether preview data is filtered by the receivers.
    private let filterPreviewData: Bool

    /// An optional limit on the number of sources the receivers in this group accept.
    private let sourceLimit: Int?

    /// A list of CIDs the receivers should filter.
    private let filterCIDs: Set<UUID>

    /// The interfaces on which the receivers in this group receive data. Internal read for tests.
    private(set) var interfaces: Set<String>

    /// A subscribed child receiver: the receiver plus the `Task`s draining its streams up into the group.
    private struct ChildSubscription {

        let receiver: sACNReceiver
        let tasks: [Task<Void, Never>]

    }

    /// The child receivers and their forwarding tasks, identified by universe.
    private var children: [UInt16: ChildSubscription] = [:]

    /// Whether a structural mutation (`add`/`remove`/`updateInterfaces`) is in flight. Actor reentrancy can
    /// interleave other calls at each `await`, so these serialize one-at-a-time through `beginMutation()`.
    private var mutating = false

    /// Callers awaiting the in-flight mutation to complete, woken in FIFO order by `endMutation()`.
    ///
    /// Wakeup order is not acquisition order: a caller arriving between the release and a woken waiter's
    /// resumption may acquire first, which is why `beginMutation()` re-checks `mutating` in a loop (the
    /// condition-variable idiom) - a barged waiter safely re-appends itself and the resume chain continues.
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Initialization

    /// Creates a new receiver to receive sACN for one or more universes.
    ///
    /// - Parameters:
    ///    - ipMode: Optional: IP mode for this receiver (IPv4/IPv6/Both).
    ///    - interfaces: The network interfaces for this receiver. An interface may be a name (e.g. "en1" or "lo0") or the corresponding IP address (e.g. "192.168.4.35").
    ///    - sourceLimit: The number of sources this receiver is able to process (defaults to `4`).
    ///    - filterPreviewData: Optional: Whether source preview data should be filtered out (defaults to `true`).
    ///    - filterCIDs: Optional: A list of CIDs which should be ignored (defaults to none).
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interfaces must not be empty.
    ///
    public init(
        ipMode: sACNIPMode = .ipv4Only, interfaces: Set<String> = [], sourceLimit: Int? = 4, filterPreviewData: Bool = true,
        filterCIDs: Set<UUID> = []
    ) {
        precondition(!ipMode.usesIPv6() || !interfaces.isEmpty, "At least one interface must be provided for IPv6.")

        self.runtime = NIORuntime()
        self.ipMode = ipMode
        self.interfaces = interfaces
        self.filterPreviewData = filterPreviewData
        self.sourceLimit = sourceLimit
        self.filterCIDs = filterCIDs
    }

    deinit {
        // The forwarding tasks hold `self` weakly and their child's streams finish when the child (released
        // with `children`) deinits, so they self-complete. Finish the group's hubs so consumers terminate.
        dataHub.finish()
        eventsHub.finish()
        debugLogHub.finish()
    }

    // MARK: - Public API

    /// Adds a new universe to this receiver group.
    ///
    /// The universe number must be valid; adding an already-present universe returns successfully. The child
    /// is registered only after it has successfully started, so a failed add leaves nothing behind and can
    /// be retried.
    ///
    /// - Parameters:
    ///    - universe: The universe number to add.
    ///
    /// - Throws: `sACNReceiverValidationError` or `sACNComponentSocketError`.
    ///
    public func add(universe: UInt16) async throws {
        guard universe.validUniverse() else { throw sACNReceiverValidationError.universeNumberInvalid }

        await beginMutation()
        defer { endMutation() }

        // Serialized: if a concurrent add already brought this universe up, it is registered here; if it
        // threw, nothing is registered and we start it below.
        guard children[universe] == nil else { return }

        guard
            let receiver = sACNReceiver(
                ipMode: ipMode, interfaces: interfaces, universe: universe, sourceLimit: sourceLimit,
                filterPreviewData: filterPreviewData, filterCIDs: filterCIDs)
        else {
            throw sACNReceiverValidationError.universeNumberInvalid
        }

        // Subscribe to the child's streams before starting it, so its synchronous `.samplingStarted` (and any
        // start-window `.socketClosed`) emitted during start() is drained rather than lost.
        let subscription = subscription(for: receiver, universe: universe)
        do {
            try await receiver.start()
        } catch {
            subscription.tasks.forEach { $0.cancel() }
            throw error
        }
        children[universe] = subscription
    }

    /// Removes a universe from this receiver group. If the universe is not present, this returns
    /// successfully. The child's forwarding tasks are cancelled and the child is released (which closes its
    /// sockets on dealloc).
    ///
    /// - Parameters:
    ///    - universe: The universe number to remove.
    ///
    public func remove(universe: UInt16) async {
        await beginMutation()
        defer { endMutation() }

        guard let subscription = children.removeValue(forKey: universe) else { return }
        subscription.tasks.forEach { $0.cancel() }
    }

    /// Updates the interfaces on which this receiver group listens for sACN Data messages.
    ///
    /// - Parameters:
    ///    - newInterfaces: The new interfaces. Empty means all interfaces (IPv4 only).
    ///
    /// - Precondition: If `ipMode` is `ipv6only` or `ipv4And6`, interfaces must not be empty.
    ///
    /// - Throws: `sACNReceiverValidationError` or `sACNComponentSocketError`. If this throws, the update may
    ///   have applied to only some universes; the new interfaces are still recorded, so universes added later
    ///   use them and retrying with the same set converges.
    ///
    public func updateInterfaces(_ newInterfaces: Set<String> = []) async throws {
        precondition(!ipMode.usesIPv6() || !newInterfaces.isEmpty, "At least one interface must be provided for IPv6.")

        await beginMutation()
        defer { endMutation() }

        // persist first so universes added later use the new interfaces even if a child throws part-way
        interfaces = newInterfaces

        for subscription in Array(children.values) {
            try await subscription.receiver.updateInterfaces(newInterfaces)
        }
    }

    /// Retrieves source information (CID, IP address, name) for a source in a universe.
    ///
    /// Reflects current state rather than a callback payload's snapshot, so it may throw for a source a
    /// just-delivered payload listed as active.
    ///
    /// - Parameters:
    ///    - sourceId: The identifier of the source.
    ///    - universe: The universe for which to get the source information.
    ///
    /// - Throws: `sACNReceiverValidationError.sourceDoesNotExist` if the source cannot be found.
    ///
    /// - Returns: Source information.
    ///
    public func information(for sourceId: UUID, on universe: UInt16) async throws -> sACNReceiverSource {
        guard let subscription = children[universe] else { throw sACNReceiverValidationError.sourceDoesNotExist }
        return try await subscription.receiver.information(for: sourceId)
    }

    // MARK: Mutation serialization

    /// Reserves the structural-mutation lock, suspending until any in-flight `add`/`remove`/`updateInterfaces`
    /// completes. Restores the old serialized group's one-at-a-time guarantee across the actor's suspension
    /// points, so concurrent mutations cannot interleave into inconsistent child/interface state.
    private func beginMutation() async {
        while mutating {
            await withCheckedContinuation { mutationWaiters.append($0) }
        }
        mutating = true
    }

    /// Releases the structural-mutation lock and resumes the next waiter (if any).
    private func endMutation() {
        mutating = false
        guard !mutationWaiters.isEmpty else { return }
        mutationWaiters.removeFirst().resume()
    }

    // MARK: Child fan-in

    /// Builds a subscription that drains a child's `data`/`events`/`debugLog` up into this group's hubs
    /// (tagging events with the universe). Each drain `Task` holds `self` weakly and captures only the
    /// child's streams (not the child), so it neither cycles nor retains the child; it ends when the child's
    /// stream finishes (on remove/dealloc) or the task is cancelled.
    private func subscription(for receiver: sACNReceiver, universe: UInt16) -> ChildSubscription {
        let dataStream = receiver.data
        let eventsStream = receiver.events
        let debugStream = receiver.debugLog

        let dataTask = Task { [weak self] in
            for await frame in dataStream { await self?.forward(data: frame) }
        }
        let eventsTask = Task { [weak self] in
            for await event in eventsStream { await self?.forward(event: event, universe: universe) }
        }
        let debugTask = Task { [weak self] in
            for await message in debugStream { await self?.forward(log: message) }
        }

        return ChildSubscription(receiver: receiver, tasks: [dataTask, eventsTask, debugTask])
    }

    /// Re-yields a child's merged data (the universe is already in the payload).
    private func forward(data frame: sACNReceiverMergedData) {
        dataHub.yield(frame)
    }

    /// Re-yields a child's event, tagged with the universe.
    private func forward(event: sACNReceiver.Event, universe: UInt16) {
        switch event {
        case .samplingStarted:
            eventsHub.yield(.samplingStarted(universe: universe))
        case .samplingEnded:
            eventsHub.yield(.samplingEnded(universe: universe))
        case .sourcesLost(let sourceIds):
            eventsHub.yield(.sourcesLost(sourceIds, universe: universe))
        case .sourceLimitExceeded:
            eventsHub.yield(.sourceLimitExceeded(universe: universe))
        case .socketClosed(let interface, let reason):
            eventsHub.yield(.socketClosed(interface: interface, reason: reason, universe: universe))
        }
    }

    /// Re-yields a child's debug log message.
    private func forward(log message: String) {
        debugLogHub.yield(message)
    }

    // MARK: Test seams

    /// Test seam: the child receiver for a universe (drives the merge pipeline via its raw receiver).
    func child(for universe: UInt16) -> sACNReceiver? {
        children[universe]?.receiver
    }

}
