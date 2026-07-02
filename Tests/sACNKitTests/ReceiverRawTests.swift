import Foundation
import Testing

@testable import sACNKit

/// Characterizes packet-in to delegate-out behavior of `sACNReceiverRaw` without sockets,
/// by injecting crafted wire packets via the internal `process` seam.
@Suite("Receiver raw")
struct ReceiverRawTests {

    /// A key used to identify the test delegate queue inside delegate callbacks.
    private static let delegateQueueKey = DispatchSpecificKey<Bool>()

    /// The timeout for waiting on an expected delegate callback.
    private static let callbackTimeout: DispatchTimeInterval = .milliseconds(2000)

    /// The timeout for asserting a callback does not arrive.
    private static let quietTimeout: DispatchTimeInterval = .milliseconds(100)

    // MARK: Helpers

    /// A recording `sACNReceiverRawDelegate`.
    ///
    /// State is only mutated on the (serial) delegate queue; tests read it after
    /// waiting on the corresponding semaphore.
    private final class DelegateMock: sACNReceiverRawDelegate {

        let dataSemaphore = DispatchSemaphore(value: 0)
        let samplingStartedSemaphore = DispatchSemaphore(value: 0)
        let samplingEndedSemaphore = DispatchSemaphore(value: 0)
        let papLostSemaphore = DispatchSemaphore(value: 0)
        private(set) var data: [sACNReceiverRawSourceData] = []
        private(set) var dataOnDelegateQueue: [Bool] = []
        private(set) var lostPerAddressPriority: [UUID] = []
        private(set) var papLostOnDelegateQueue: [Bool] = []
        var onData: ((sACNReceiverRawSourceData) -> Void)?

        func receiver(_ receiver: sACNReceiverRaw, interface: String?, socketDidCloseWithError error: Error?) {}

        func receiverReceivedUniverseData(_ receiver: sACNReceiverRaw, sourceData: sACNReceiverRawSourceData) {
            data.append(sourceData)
            dataOnDelegateQueue.append(DispatchQueue.getSpecific(key: ReceiverRawTests.delegateQueueKey) == true)
            onData?(sourceData)
            dataSemaphore.signal()
        }

        func receiverStartedSampling(_ receiver: sACNReceiverRaw) {
            samplingStartedSemaphore.signal()
        }

        func receiverEndedSampling(_ receiver: sACNReceiverRaw) {
            samplingEndedSemaphore.signal()
        }

        func receiver(_ receiver: sACNReceiverRaw, lostSources: [UUID]) {}

        func receiver(_ receiver: sACNReceiverRaw, lostPerAddressPriorityFor source: UUID) {
            lostPerAddressPriority.append(source)
            papLostOnDelegateQueue.append(DispatchQueue.getSpecific(key: ReceiverRawTests.delegateQueueKey) == true)
            papLostSemaphore.signal()
        }

        func receiverExceededSources(_ receiver: sACNReceiverRaw) {}

    }

    /// A receiver, its recording delegate, and the serial delegate queue callbacks arrive on.
    private struct Harness {

        let receiver: sACNReceiverRaw
        let delegate: DelegateMock
        let delegateQueue: DispatchQueue

        /// Injects a packet on the socket delegate queue, as socket callbacks do.
        func inject(_ packet: Data, socketId: UUID = UUID(), hostname: String = "192.168.1.10") {
            receiver.socketDelegateQueue.sync {
                receiver.process(data: packet, ipFamily: .IPv4, socketId: socketId, hostname: hostname)
            }
        }

        /// Waits for a data callback, returning whether one arrived in time.
        func waitForData(timeout: DispatchTimeInterval = ReceiverRawTests.callbackTimeout) -> Bool {
            delegate.dataSemaphore.wait(timeout: .now() + timeout) == .success
        }

    }

    /// Creates a receiver with fast timing constants and a recording delegate.
    ///
    /// - Parameters:
    ///    - endSampling: Whether to immediately end the initial sampling state, so packets
    ///    from any socket are accepted (defaults to `true`).
    ///
    private func makeHarness(endSampling: Bool = true, sourceLossTimeout: UInt64 = 60, perAddressPriorityWait: UInt64 = 60) -> Harness {
        let delegateQueue = DispatchQueue(label: "com.danielmurfin.sACNKitTests.receiverRawDelegate")
        delegateQueue.setSpecific(key: Self.delegateQueueKey, value: true)
        let receiver = sACNReceiverRaw(
            ipMode: .ipv4Only, interfaces: [], universe: 1, sourceLimit: 4, filterPreviewData: true, filterCIDs: [],
            delegateQueue: delegateQueue, sourceLossTimeout: sourceLossTimeout, perAddressPriorityWait: perAddressPriorityWait)!
        let delegate = DelegateMock()
        receiver.setDelegate(delegate)
        if endSampling {
            receiver.endedSamplingPeriod()
        }
        return Harness(receiver: receiver, delegate: delegate, delegateQueue: delegateQueue)
    }

    /// Builds a complete sACN data packet (root + framing + DMP).
    private func dataPacket(
        cid: UUID, name: String = "Test Source", universe: UInt16 = 1, sequence: UInt8, priority: UInt8 = 100,
        options: DataFramingLayer.Options = .none, startCode: DMX.STARTCode = .null, values: [UInt8] = Array(repeating: 0, count: 512)
    ) -> Data {
        var framing = DataFramingLayer.createAsData(nameData: Source.buildNameData(from: name), priority: priority, universe: universe)
        framing.replacingSequence(with: sequence)
        framing.replacingOptions(with: options)
        framing.append(DMPLayer.createAsData(startCode: startCode, values: values))
        var packet = RootLayer.createAsData(vector: .data, cid: cid)
        packet.append(framing)
        packet.replacingRootLayerFlagsAndLength(with: UInt16(packet.count - RootLayer.Offset.flagsAndLength.rawValue))
        return packet
    }

    /// Establishes a source in the `hasLevelsAndPAP` state by sending levels then per-address priority.
    ///
    /// - Returns: The next valid sequence number.
    ///
    private func establishSource(cid: UUID, in harness: Harness) -> UInt8 {
        harness.inject(dataPacket(cid: cid, sequence: 0))
        harness.inject(dataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: Array(repeating: 100, count: 512)))
        #expect(harness.waitForData(), "expected a per-address priority data callback while establishing a source")
        return 2
    }

    // MARK: Delivery characterization

    @Test("A new source's levels are held until per-address priority arrives, then delivered with payload fidelity")
    func newSourceHeldUntilPAP() throws {
        let harness = makeHarness()
        let cid = UUID()
        let levels: [UInt8] = (0..<512).map { UInt8($0 % 256) }
        let priorities: [UInt8] = [200] + Array(repeating: 100, count: 511)

        // levels for a new source are held while waiting for per-address priority
        harness.inject(dataPacket(cid: cid, sequence: 0, values: levels))
        #expect(!harness.waitForData(timeout: Self.quietTimeout), "levels for a new source should not notify before per-address priority")

        // per-address priority is delivered
        harness.inject(dataPacket(cid: cid, name: "Fixture", sequence: 1, priority: 150, startCode: .perAddressPriority, values: priorities))
        #expect(harness.waitForData())

        // subsequent levels are delivered
        harness.inject(dataPacket(cid: cid, name: "Fixture", sequence: 2, priority: 150, values: levels))
        #expect(harness.waitForData())

        let received = harness.delegate.data
        try #require(received.count == 2)
        #expect(received[0].startCode == .perAddressPriority)
        #expect(received[0].values == priorities)
        #expect(received[1].cid == cid)
        #expect(received[1].name == "Fixture")
        #expect(received[1].hostname == "192.168.1.10")
        #expect(received[1].universe == 1)
        #expect(received[1].priority == 150)
        #expect(received[1].preview == false)
        #expect(received[1].isSampling == false)
        #expect(received[1].startCode == .null)
        #expect(received[1].valuesCount == 512)
        #expect(received[1].values == levels)
        #expect(harness.delegate.dataOnDelegateQueue.allSatisfy { $0 }, "data must be delivered on the delegate queue")
    }

    @Test("Packets with invalid sequence numbers are discarded")
    func sequenceFiltering() {
        let harness = makeHarness()
        let cid = UUID()
        var sequence = establishSource(cid: cid, in: harness)

        // a repeated and an older sequence number are both rejected
        harness.inject(dataPacket(cid: cid, sequence: sequence - 1))
        harness.inject(dataPacket(cid: cid, sequence: sequence - 2))
        #expect(!harness.waitForData(timeout: Self.quietTimeout), "repeated or older sequence numbers should be discarded")

        // the next sequence number is accepted
        harness.inject(dataPacket(cid: cid, sequence: sequence))
        #expect(harness.waitForData())
        sequence += 1

        // a jump back of 20 or more is accepted (source reset)
        harness.inject(dataPacket(cid: cid, sequence: sequence &- 21))
        #expect(harness.waitForData())
    }

    @Test("Preview data is filtered when preview filtering is enabled")
    func previewFiltering() {
        let harness = makeHarness()
        let cid = UUID()
        let sequence = establishSource(cid: cid, in: harness)

        harness.inject(dataPacket(cid: cid, sequence: sequence, options: .preview))
        #expect(!harness.waitForData(timeout: Self.quietTimeout), "preview data should be filtered")

        harness.inject(dataPacket(cid: cid, sequence: sequence + 1))
        #expect(harness.waitForData())
    }

    @Test("During sampling, data is delivered immediately and marked as sampling")
    func samplingDelivery() throws {
        let harness = makeHarness(endSampling: false)
        let samplingSocketId = try #require(harness.receiver.socketsSampling.keys.first)
        harness.receiver.socketDelegateQueue.sync {
            harness.receiver.beginSamplingPeriod()
        }
        #expect(harness.delegate.samplingStartedSemaphore.wait(timeout: .now() + Self.callbackTimeout) == .success)

        // a packet from a socket which is not sampling is rejected
        harness.inject(dataPacket(cid: UUID(), sequence: 0), socketId: UUID())
        #expect(!harness.waitForData(timeout: Self.quietTimeout), "packets from unknown sockets should be rejected while sampling")

        // a new source's levels notify immediately during sampling
        harness.inject(dataPacket(cid: UUID(), sequence: 0), socketId: samplingSocketId)
        #expect(harness.waitForData())
        #expect(harness.delegate.data.last?.isSampling == true)
    }

    @Test("Packets for another universe are ignored")
    func universeMismatchIgnored() {
        let harness = makeHarness()
        harness.inject(dataPacket(cid: UUID(), universe: 2, sequence: 0))
        harness.inject(dataPacket(cid: UUID(), universe: 2, sequence: 1, startCode: .perAddressPriority))
        #expect(!harness.waitForData(timeout: Self.quietTimeout), "packets for another universe should be ignored")
    }

    @Test("A new source which is already terminated is ignored")
    func terminatedNewSourceIgnored() {
        let harness = makeHarness()
        harness.inject(dataPacket(cid: UUID(), sequence: 0, options: .terminated))
        #expect(!harness.waitForData(timeout: Self.quietTimeout), "a terminated stream should not create a source")
    }

    @Test("A client may call back into the receiver from within a data callback")
    func reentrantCallbackDoesNotDeadlock() {
        let harness = makeHarness()
        let cid = UUID()

        let reentered = DispatchSemaphore(value: 0)
        harness.delegate.onData = { [weak receiver = harness.receiver, weak delegate = harness.delegate] _ in
            // calling back into the receiver requires its internal queue and
            // must not deadlock against in-flight packet processing
            _ = receiver?.isListening
            receiver?.setDelegate(delegate)
            receiver?.stop()
            reentered.signal()
        }

        harness.inject(dataPacket(cid: cid, sequence: 0))
        harness.inject(dataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: Array(repeating: 100, count: 512)))
        #expect(
            reentered.wait(timeout: .now() + Self.callbackTimeout) == .success,
            "re-entering the receiver from a data callback must not deadlock")
    }

    @Test("Per-address priority loss is notified exactly once, on the delegate queue")
    func perAddressPriorityLoss() throws {
        let harness = makeHarness()
        let cid = UUID()
        var sequence = establishSource(cid: cid, in: harness)

        // let the per-address priority timer expire, then send levels only
        usleep(120_000)
        harness.inject(dataPacket(cid: cid, sequence: sequence))
        sequence &+= 1
        #expect(harness.delegate.papLostSemaphore.wait(timeout: .now() + Self.callbackTimeout) == .success)
        #expect(harness.waitForData(), "the levels which triggered the loss should still be delivered")

        // further levels packets must not notify loss again
        harness.inject(dataPacket(cid: cid, sequence: sequence))
        #expect(harness.waitForData())
        #expect(harness.delegate.papLostSemaphore.wait(timeout: .now() + Self.quietTimeout) == .timedOut, "loss should only be notified once")

        #expect(harness.delegate.lostPerAddressPriority == [cid])
        let onQueue = try #require(harness.delegate.papLostOnDelegateQueue.first)
        #expect(onQueue, "per-address priority loss must be delivered on the delegate queue")
    }

    @Test("Data callbacks preserve packet order")
    func orderingPreserved() {
        let harness = makeHarness()
        let cid = UUID()
        var sequence = establishSource(cid: cid, in: harness)

        let count = 20
        for index in 0..<count {
            var values = Array(repeating: UInt8(0), count: 512)
            values[0] = UInt8(index)
            harness.inject(dataPacket(cid: cid, sequence: sequence, values: values))
            sequence &+= 1
        }
        for _ in 0..<count {
            #expect(harness.waitForData())
        }

        // drop the establishing callback, keep the ordered burst
        let burst = harness.delegate.data.dropFirst().map { $0.values[0] }
        #expect(Array(burst) == (0..<count).map { UInt8($0) }, "data callbacks must arrive in packet order")
    }

}
