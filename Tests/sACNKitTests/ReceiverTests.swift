import Foundation
import Testing

@testable import sACNKit

/// Exercises `sACNReceiver` state safety and merge delivery by driving its internal
/// raw receiver directly, without sockets.
@Suite("Receiver")
struct ReceiverTests {

    /// A key used to identify the client delegate queue inside delegate callbacks.
    private static let clientQueueKey = DispatchSpecificKey<Bool>()

    /// The timeout for waiting on an expected delegate callback or bounded call.
    /// Generous because CI runners are small and heavily loaded under parallel
    /// test execution; a passing wait returns as soon as it is signalled.
    private static let callbackTimeout: DispatchTimeInterval = .milliseconds(10000)

    /// The timeout for asserting a callback does not arrive.
    private static let quietTimeout: DispatchTimeInterval = .milliseconds(100)

    /// Fast timing constants for tests that drive per-address priority expiry.
    private static let fastTimeout: UInt64 = 150

    /// How long to sleep to guarantee a `fastTimeout` timer has expired.
    private static let fastTimeoutExpiry: TimeInterval = 0.3

    // MARK: Helpers

    /// A recording `sACNReceiverDelegate`.
    private final class DelegateMock: sACNReceiverDelegate {

        private let lock = NSLock()
        let mergedSemaphore = DispatchSemaphore(value: 0)
        private var _merged: [sACNReceiverMergedData] = []
        private var _mergedInClientContext: [Bool] = []
        var merged: [sACNReceiverMergedData] { lock.withLock { _merged } }
        var mergedInClientContext: [Bool] { lock.withLock { _mergedInClientContext } }
        var onMerged: ((sACNReceiverMergedData) -> Void)?

        func receiver(_ receiver: sACNReceiver, interface: String?, socketDidCloseWithError error: Error?) {}

        func receiverMergedData(_ receiver: sACNReceiver, mergedData: sACNReceiverMergedData) {
            lock.withLock {
                _merged.append(mergedData)
                _mergedInClientContext.append(DispatchQueue.getSpecific(key: ReceiverTests.clientQueueKey) == true)
            }
            onMerged?(mergedData)
            mergedSemaphore.signal()
        }

        func receiverStartedSampling(_ receiver: sACNReceiver) {}

        func receiverEndedSampling(_ receiver: sACNReceiver) {}

        func receiver(_ receiver: sACNReceiver, lostSources: [UUID]) {}

        func receiverExceededSources(_ receiver: sACNReceiver) {}

    }

    /// A receiver wired to its internal raw receiver, with a recording delegate.
    private struct Harness {

        let receiver: sACNReceiver
        let delegate: DelegateMock
        let clientQueue: DispatchQueue

        /// Injects a packet into the internal raw receiver, as socket callbacks do.
        func inject(_ packet: Data, socketId: UUID = UUID()) {
            receiver.receiver.socketDelegateQueue.sync {
                receiver.receiver.process(data: packet, ipFamily: .IPv4, socketId: socketId, hostname: "192.168.1.10")
            }
        }

        /// Waits for a merged-data callback, returning whether one arrived in time.
        func waitForMerge(timeout: DispatchTimeInterval = ReceiverTests.callbackTimeout) -> Bool {
            delegate.mergedSemaphore.wait(timeout: .now() + timeout) == .success
        }

        /// Waits until the most recent merged data satisfies the predicate, returning whether it did in time.
        func waitUntilMerged(where predicate: (sACNReceiverMergedData) -> Bool) -> Bool {
            let deadline = Date() + 10.0
            while Date() < deadline {
                if let merged = delegate.merged.last, predicate(merged) { return true }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return false
        }

    }

    /// Creates a wired receiver for universe 1 with a recording delegate, without sockets.
    private func makeReceiver(
        clientQueue: DispatchQueue, sourceLossTimeout: UInt64, perAddressPriorityWait: UInt64
    ) throws -> (receiver: sACNReceiver, delegate: DelegateMock) {
        clientQueue.setSpecific(key: Self.clientQueueKey, value: true)
        let receiver = try #require(
            sACNReceiver(
                ipMode: .ipv4Only, interfaces: [], universe: 1, sourceLimit: 4, filterPreviewData: true, filterCIDs: [],
                delegateQueue: clientQueue, sourceLossTimeout: sourceLossTimeout, perAddressPriorityWait: perAddressPriorityWait))
        let delegate = DelegateMock()
        receiver.setDelegate(delegate)
        // wire the raw receiver as start() would, without opening sockets
        receiver.receiver.setDelegate(receiver)
        return (receiver, delegate)
    }

    /// Creates a receiver for universe 1 whose raw receiver delivers without sockets.
    private func makeHarness(
        clientQueue: DispatchQueue? = nil, sourceLossTimeout: UInt64 = sACNReceiverRaw.sourceLossTimeout,
        perAddressPriorityWait: UInt64 = sACNReceiverRaw.perAddressPriorityWait
    ) throws -> Harness {
        let queue = clientQueue ?? DispatchQueue(label: "com.danielmurfin.sACNKitTests.receiverClient")
        let (receiver, delegate) = try makeReceiver(
            clientQueue: queue, sourceLossTimeout: sourceLossTimeout, perAddressPriorityWait: perAddressPriorityWait)
        receiver.receiver.endedSamplingPeriod()
        return Harness(receiver: receiver, delegate: delegate, clientQueue: queue)
    }

    /// Creates a receiver for universe 1 whose raw receiver is actively sampling, without sockets.
    ///
    /// - Returns: The harness and the socket identifier registered as sampling,
    /// which must be passed when injecting packets.
    ///
    private func makeSamplingHarness(
        sourceLossTimeout: UInt64 = sACNReceiverRaw.sourceLossTimeout,
        perAddressPriorityWait: UInt64 = sACNReceiverRaw.perAddressPriorityWait
    ) throws -> (harness: Harness, socketId: UUID) {
        let queue = DispatchQueue(label: "com.danielmurfin.sACNKitTests.receiverClient")
        let (receiver, delegate) = try makeReceiver(
            clientQueue: queue, sourceLossTimeout: sourceLossTimeout, perAddressPriorityWait: perAddressPriorityWait)
        receiver.receiver.socketDelegateQueue.sync {
            receiver.receiver.beginSamplingPeriod()
        }
        let socketId = try #require(receiver.receiver.socketsSampling.keys.first)
        return (Harness(receiver: receiver, delegate: delegate, clientQueue: queue), socketId)
    }

    /// Builds a complete sACN data packet (root + framing + DMP).
    private func dataPacket(
        cid: UUID, sequence: UInt8, priority: UInt8 = 100, startCode: DMX.STARTCode = .null,
        values: [UInt8] = Array(repeating: 0, count: 512)
    ) -> Data {
        var framing = DataFramingLayer.createAsData(nameData: Source.buildNameData(from: "Test Source"), priority: priority, universe: 1)
        framing.replacingSequence(with: sequence)
        framing.append(DMPLayer.createAsData(startCode: startCode, values: values))
        var packet = RootLayer.createAsData(vector: .data, cid: cid)
        packet.append(framing)
        packet.replacingRootLayerFlagsAndLength(with: UInt16(packet.count - RootLayer.Offset.flagsAndLength.rawValue))
        return packet
    }

    /// Delivers levels then per-address priority then levels, producing a merged notification.
    private func establishAndMerge(cid: UUID, levels: [UInt8], in harness: Harness) {
        harness.inject(dataPacket(cid: cid, sequence: 0, values: levels))
        harness.inject(dataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: Array(repeating: 100, count: 512)))
        harness.inject(dataPacket(cid: cid, sequence: 2, values: levels))
    }

    // MARK: Tests

    @Test("Merged data is delivered in the client queue's context")
    func mergedDataDelivered() throws {
        let harness = try makeHarness()
        let cid = UUID()
        let levels: [UInt8] = (0..<512).map { UInt8($0 % 256) }

        establishAndMerge(cid: cid, levels: levels, in: harness)
        #expect(harness.waitForMerge())

        let merged = try #require(harness.delegate.merged.first)
        #expect(merged.universe == 1)
        #expect(merged.levels == levels)
        #expect(merged.activeSources == [cid])
        #expect(merged.numberOfActiveSources == 1)
        #expect(harness.delegate.mergedInClientContext.allSatisfy { $0 }, "callbacks must execute in the client queue's context")
    }

    @Test("information(for:) may be called from within a delegate callback")
    func informationFromCallback() throws {
        let harness = try makeHarness()
        let cid = UUID()

        let obtained = DispatchSemaphore(value: 0)
        let information = LockedBox<sACNReceiverSource>()
        harness.delegate.onMerged = { [weak receiver = harness.receiver] _ in
            information.value = try? receiver?.information(for: cid)
            obtained.signal()
        }

        establishAndMerge(cid: cid, levels: Array(repeating: 128, count: 512), in: harness)
        #expect(
            obtained.wait(timeout: .now() + Self.callbackTimeout) == .success,
            "information(for:) must not deadlock when called from a delegate callback")
        #expect(information.value?.cid == cid)
    }

    @Test("information(for:) may be called from the client's serial queue")
    func informationFromClientQueue() throws {
        let harness = try makeHarness()
        let cid = UUID()

        establishAndMerge(cid: cid, levels: Array(repeating: 128, count: 512), in: harness)
        #expect(harness.waitForMerge())

        let obtained = DispatchSemaphore(value: 0)
        let information = LockedBox<sACNReceiverSource>()
        DispatchQueue.global(qos: .userInitiated).async { [receiver = harness.receiver, clientQueue = harness.clientQueue] in
            clientQueue.sync {
                information.value = try? receiver.information(for: cid)
            }
            obtained.signal()
        }
        #expect(
            obtained.wait(timeout: .now() + Self.callbackTimeout) == .success,
            "information(for:) must not deadlock when called from the client queue")
        #expect(information.value?.cid == cid)
    }

    @Test("information(for:) may be called from an unrelated queue")
    func informationFromUnrelatedQueue() throws {
        let harness = try makeHarness()
        let cid = UUID()

        establishAndMerge(cid: cid, levels: Array(repeating: 128, count: 512), in: harness)
        #expect(harness.waitForMerge())

        let obtained = DispatchSemaphore(value: 0)
        let information = LockedBox<sACNReceiverSource>()
        DispatchQueue.global(qos: .userInitiated).async { [receiver = harness.receiver] in
            information.value = try? receiver.information(for: cid)
            obtained.signal()
        }
        #expect(
            obtained.wait(timeout: .now() + Self.callbackTimeout) == .success,
            "information(for:) must not deadlock when called from an unrelated queue")
        #expect(information.value?.cid == cid)
    }

    @Test("information(for:) throws for an unknown source")
    func informationUnknownSourceThrows() throws {
        let harness = try makeHarness()
        #expect(throws: sACNReceiverValidationError.self) {
            try harness.receiver.information(for: UUID())
        }
    }

    @Test("State stays consistent when the client supplies a concurrent queue")
    func concurrentClientQueue() throws {
        let concurrentQueue = DispatchQueue(label: "com.danielmurfin.sACNKitTests.concurrentClient", qos: .userInitiated, attributes: .concurrent)
        let harness = try makeHarness(clientQueue: concurrentQueue)
        let cid = UUID()
        establishAndMerge(cid: cid, levels: Array(repeating: 128, count: 512), in: harness)
        #expect(harness.waitForMerge())

        // hammer the public API from many threads while more packets arrive
        DispatchQueue.concurrentPerform(iterations: 100) { iteration in
            switch iteration % 3 {
            case 0:
                _ = try? harness.receiver.information(for: cid)
            case 1:
                harness.receiver.setDelegate(harness.delegate)
            default:
                harness.inject(dataPacket(cid: cid, sequence: UInt8((3 + iteration) % 256), values: Array(repeating: 64, count: 512)))
            }
        }
        #expect(harness.delegate.merged.count >= 1)
    }

    // MARK: Per-address priority and sampling regression tests

    @Test("Per-address priorities captured during sampling are applied when sampling ends")
    func samplingPAPAppliedWhenSamplingEnds() throws {
        let (harness, socketId) = try makeSamplingHarness()
        let cid = UUID()
        let levels = Array(repeating: UInt8(255), count: 512)
        var priorities = Array(repeating: UInt8(100), count: 512)
        priorities[0] = 0

        harness.inject(dataPacket(cid: cid, sequence: 0, values: levels), socketId: socketId)
        harness.inject(dataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: priorities), socketId: socketId)
        #expect(!harness.waitForMerge(timeout: Self.quietTimeout), "no merged data should be delivered while sampling")

        harness.receiver.receiver.endedSamplingPeriod()
        #expect(harness.waitForMerge())
        let merged = try #require(harness.delegate.merged.last)
        #expect(merged.levels[0] == 0, "slot 0 has per-address priority 0 (unsourced) so must not output its level")
        #expect(merged.winners[0] == nil)
        #expect(merged.levels[1] == 255)
        #expect(merged.winners[1] == cid)
    }

    @Test("Losing per-address priority for a sampling source does not deliver merged data")
    func papLossWhileSamplingStaysQuiet() throws {
        let (harness, socketId) = try makeSamplingHarness(
            sourceLossTimeout: Self.fastTimeout, perAddressPriorityWait: Self.fastTimeout)
        let cid = UUID()

        harness.inject(dataPacket(cid: cid, sequence: 0), socketId: socketId)
        harness.inject(
            dataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: Array(repeating: 100, count: 512)),
            socketId: socketId)

        // let the per-address priority timer expire, then deliver levels to surface the loss
        Thread.sleep(forTimeInterval: Self.fastTimeoutExpiry)
        harness.inject(dataPacket(cid: cid, sequence: 2), socketId: socketId)
        #expect(!harness.waitForMerge(timeout: Self.quietTimeout), "per-address priority loss must not notify merged data while sampling")
    }

    @Test("Per-address priority loss, resumption and a second loss are all reflected in merged data")
    func secondPAPLossReflectedInMergedData() throws {
        let harness = try makeHarness(sourceLossTimeout: Self.fastTimeout, perAddressPriorityWait: Self.fastTimeout)
        let cid = UUID()
        let levels = Array(repeating: UInt8(255), count: 512)
        var priorities = Array(repeating: UInt8(100), count: 512)
        priorities[0] = 0

        // establish the source with per-address priorities (slot 0 unsourced)
        harness.inject(dataPacket(cid: cid, sequence: 0, values: levels))
        harness.inject(dataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: priorities))
        harness.inject(dataPacket(cid: cid, sequence: 2, values: levels))
        #expect(harness.waitUntilMerged { $0.levels[0] == 0 && $0.levels[1] == 255 })

        // first loss: universe priority applies to every slot again
        Thread.sleep(forTimeInterval: Self.fastTimeoutExpiry)
        harness.inject(dataPacket(cid: cid, sequence: 3, values: levels))
        #expect(harness.waitUntilMerged { $0.levels[0] == 255 }, "merged data must reflect the first per-address priority loss")

        // per-address priority resumes (slot 0 unsourced again)
        harness.inject(dataPacket(cid: cid, sequence: 4, startCode: .perAddressPriority, values: priorities))
        #expect(harness.waitUntilMerged { $0.levels[0] == 0 }, "merged data must reflect resumed per-address priorities")

        // a second loss must also be delivered and reflected
        Thread.sleep(forTimeInterval: Self.fastTimeoutExpiry)
        harness.inject(dataPacket(cid: cid, sequence: 5, values: levels))
        #expect(harness.waitUntilMerged { $0.levels[0] == 255 }, "merged data must reflect a second per-address priority loss")
    }

    @Test("Short packets during sampling still transfer to the main merger when sampling ends")
    func samplingShortPacketsAppliedWhenSamplingEnds() throws {
        let (harness, socketId) = try makeSamplingHarness()
        let cid = UUID()
        let levels = Array(repeating: UInt8(255), count: 100)
        var priorities = Array(repeating: UInt8(100), count: 100)
        priorities[0] = 0

        harness.inject(sACNTestDataPacket(cid: cid, sequence: 0, values: levels), socketId: socketId)
        harness.inject(sACNTestDataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: priorities), socketId: socketId)

        // a second source sends only per-address priority during sampling;
        // it has no levels so there is nothing to transfer
        let papOnlyCid = UUID()
        harness.inject(
            sACNTestDataPacket(cid: papOnlyCid, sequence: 0, startCode: .perAddressPriority, values: Array(repeating: 100, count: 100)),
            socketId: socketId)

        harness.receiver.receiver.endedSamplingPeriod()
        #expect(harness.waitForMerge())
        let merged = try #require(harness.delegate.merged.last)
        #expect(merged.levels[0] == 0, "slot 0 has per-address priority 0 (unsourced) so must not output its level")
        #expect(merged.levels[1] == 255, "levels from a short packet must survive the transfer out of sampling")
        #expect(merged.winners[1] == cid)
        // beyond the short packet the source holds universe priority with no
        // levels, matching the live (non-sampling) path for short packets
        #expect(merged.levels[100] == 0, "slots beyond the short packet must output zero")
        #expect(merged.activeSources == [cid], "a source which only sent per-address priority during sampling has nothing to transfer")
    }

    @Test("Per-address priority loss surfaced by a preview-filtered packet still delivers merged data")
    func papLossViaPreviewPacketDeliversMergedData() throws {
        let harness = try makeHarness(sourceLossTimeout: Self.fastTimeout, perAddressPriorityWait: Self.fastTimeout)
        let cid = UUID()
        let levels = Array(repeating: UInt8(255), count: 512)
        var priorities = Array(repeating: UInt8(100), count: 512)
        priorities[0] = 0

        harness.inject(sACNTestDataPacket(cid: cid, sequence: 0, values: levels))
        harness.inject(sACNTestDataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: priorities))
        harness.inject(sACNTestDataPacket(cid: cid, sequence: 2, values: levels))
        #expect(harness.waitUntilMerged { $0.levels[0] == 0 && $0.levels[1] == 255 })

        // a preview-flagged packet is filtered from data delivery, so the loss
        // path's own notification is the only merged delivery
        Thread.sleep(forTimeInterval: Self.fastTimeoutExpiry)
        harness.inject(sACNTestDataPacket(cid: cid, sequence: 3, options: .preview, values: levels))
        #expect(
            harness.waitUntilMerged { $0.levels[0] == 255 },
            "per-address priority loss must deliver merged data even when the triggering packet is preview-filtered")
    }

    @Test("A pending source lost before delivering levels does not gate merged data forever")
    func lostPendingSourceReleasesPendingCount() throws {
        let harness = try makeHarness(sourceLossTimeout: Self.fastTimeout, perAddressPriorityWait: Self.fastTimeout)
        let pendingCid = UUID()

        // levels for a new source are held, so its first delivered packet is the
        // per-address priority packet, creating a pending source
        harness.inject(sACNTestDataPacket(cid: pendingCid, sequence: 0))
        harness.inject(sACNTestDataPacket(cid: pendingCid, sequence: 1, startCode: .perAddressPriority, values: Array(repeating: 100, count: 512)))

        // let the source time out, then drive the loss check as the heartbeat would
        Thread.sleep(forTimeInterval: Self.fastTimeoutExpiry)
        harness.receiver.receiver.socketDelegateQueue.sync {
            harness.receiver.receiver.checkForSourceLoss()
        }

        // a fresh source must still produce merged data
        let cid = UUID()
        let levels = Array(repeating: UInt8(128), count: 512)
        harness.inject(sACNTestDataPacket(cid: cid, sequence: 0, values: levels))
        harness.inject(sACNTestDataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: Array(repeating: 100, count: 512)))
        harness.inject(sACNTestDataPacket(cid: cid, sequence: 2, values: levels))
        #expect(harness.waitUntilMerged { $0.levels[0] == 128 }, "merged data must not be gated by a lost pending source")
    }

}
