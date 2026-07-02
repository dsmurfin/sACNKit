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
    private static let callbackTimeout: DispatchTimeInterval = .milliseconds(2000)

    // MARK: Helpers

    /// A tiny thread-safe box for values written from delegate callbacks.
    private final class LockedBox<T> {

        private let lock = NSLock()
        private var _value: T?

        var value: T? {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }

    }

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
        func inject(_ packet: Data) {
            receiver.receiver.socketDelegateQueue.sync {
                receiver.receiver.process(data: packet, ipFamily: .IPv4, socketId: UUID(), hostname: "192.168.1.10")
            }
        }

        /// Waits for a merged-data callback, returning whether one arrived in time.
        func waitForMerge(timeout: DispatchTimeInterval = ReceiverTests.callbackTimeout) -> Bool {
            delegate.mergedSemaphore.wait(timeout: .now() + timeout) == .success
        }

    }

    /// Creates a receiver for universe 1 whose raw receiver delivers without sockets.
    private func makeHarness(clientQueue: DispatchQueue? = nil) -> Harness {
        let queue = clientQueue ?? DispatchQueue(label: "com.danielmurfin.sACNKitTests.receiverClient")
        queue.setSpecific(key: Self.clientQueueKey, value: true)
        let receiver = sACNReceiver(universe: 1, delegateQueue: queue)!
        let delegate = DelegateMock()
        receiver.setDelegate(delegate)
        // wire the raw receiver as start() would, without opening sockets
        receiver.receiver.setDelegate(receiver)
        receiver.receiver.endedSamplingPeriod()
        return Harness(receiver: receiver, delegate: delegate, clientQueue: queue)
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
        let harness = makeHarness()
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
    func informationFromCallback() {
        let harness = makeHarness()
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
    func informationFromClientQueue() {
        let harness = makeHarness()
        let cid = UUID()

        establishAndMerge(cid: cid, levels: Array(repeating: 128, count: 512), in: harness)
        #expect(harness.waitForMerge())

        let obtained = DispatchSemaphore(value: 0)
        let information = LockedBox<sACNReceiverSource>()
        DispatchQueue.global().async { [receiver = harness.receiver, clientQueue = harness.clientQueue] in
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
    func informationFromUnrelatedQueue() {
        let harness = makeHarness()
        let cid = UUID()

        establishAndMerge(cid: cid, levels: Array(repeating: 128, count: 512), in: harness)
        #expect(harness.waitForMerge())

        let obtained = DispatchSemaphore(value: 0)
        let information = LockedBox<sACNReceiverSource>()
        DispatchQueue.global().async { [receiver = harness.receiver] in
            information.value = try? receiver.information(for: cid)
            obtained.signal()
        }
        #expect(
            obtained.wait(timeout: .now() + Self.callbackTimeout) == .success,
            "information(for:) must not deadlock when called from an unrelated queue")
        #expect(information.value?.cid == cid)
    }

    @Test("information(for:) throws for an unknown source")
    func informationUnknownSourceThrows() {
        let harness = makeHarness()
        #expect(throws: sACNReceiverValidationError.self) {
            try harness.receiver.information(for: UUID())
        }
    }

    @Test("State stays consistent when the client supplies a concurrent queue")
    func concurrentClientQueue() {
        let concurrentQueue = DispatchQueue(label: "com.danielmurfin.sACNKitTests.concurrentClient", attributes: .concurrent)
        let harness = makeHarness(clientQueue: concurrentQueue)
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

}
