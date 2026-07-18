import Foundation
import Testing

@testable import sACNKit

/// Characterizes packet-in to stream-out behavior of the `sACNReceiverRaw` actor without sockets, by
/// injecting crafted wire packets via the internal `process` seam and observing the `data`/`events` streams.
@Suite("Receiver raw")
struct ReceiverRawTests {

    // MARK: Helpers

    /// A receiver and collectors draining its `data` and `events` streams.
    private struct Harness {

        let receiver: sACNReceiverRaw
        let data: StreamCollector<sACNReceiverRawSourceData>
        let events: StreamCollector<sACNReceiverRaw.Event>

        /// Injects a packet into the actor, as a socket callback does.
        func inject(_ packet: Data, socketId: UUID = UUID(), hostname: String = "192.168.1.10") async {
            await receiver.process(data: packet, ipFamily: .IPv4, socketId: socketId, hostname: hostname)
        }

    }

    /// Creates a receiver with fast timing constants and stream collectors.
    ///
    /// - Parameters:
    ///    - endSampling: Whether to immediately end the initial sampling state, so packets from any socket
    ///    are accepted (defaults to `true`).
    ///
    private func makeHarness(
        endSampling: Bool = true, sourceLossTimeout: UInt64 = 60, perAddressPriorityWait: UInt64 = 60
    ) async throws -> Harness {
        let receiver = try #require(
            sACNReceiverRaw(
                runtime: NIORuntime(), ipMode: .ipv4Only, interfaces: [], universe: 1, sourceLimit: 4, filterPreviewData: true,
                filterCIDs: [], sourceLossTimeout: sourceLossTimeout, perAddressPriorityWait: perAddressPriorityWait))
        let harness = Harness(receiver: receiver, data: StreamCollector(receiver.data), events: StreamCollector(receiver.events))
        if endSampling {
            await receiver.endedSamplingPeriod()
        }
        return harness
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
    /// - Returns: The next valid sequence number (the collector holds one data frame - the PAP).
    ///
    private func establishSource(cid: UUID, in harness: Harness) async -> UInt8 {
        await harness.inject(dataPacket(cid: cid, sequence: 0))
        await harness.inject(dataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: Array(repeating: 100, count: 512)))
        #expect(await harness.data.waitForCount(1), "expected a per-address priority data frame while establishing a source")
        return 2
    }

    /// Extracts the per-address-priority-lost source ids from an events collector, in order.
    private func papLostSources(_ events: StreamCollector<sACNReceiverRaw.Event>) -> [UUID] {
        events.all.compactMap { event in
            if case .perAddressPriorityLost(let source) = event { return source }
            return nil
        }
    }

    /// Whether an event is a per-address-priority-lost event.
    private static let isPAPLost: @Sendable (sACNReceiverRaw.Event) -> Bool = { event in
        if case .perAddressPriorityLost = event { return true } else { return false }
    }

    // MARK: Delivery characterization

    @Test("A new source's levels are held until per-address priority arrives, then delivered with payload fidelity")
    func newSourceHeldUntilPAP() async throws {
        let harness = try await makeHarness()
        let cid = UUID()
        let levels: [UInt8] = (0..<512).map { UInt8($0 % 256) }
        let priorities: [UInt8] = [200] + Array(repeating: 100, count: 511)

        // levels for a new source are held while waiting for per-address priority; the priority packet and the
        // following levels are the only two frames delivered (the held levels never notify)
        await harness.inject(dataPacket(cid: cid, sequence: 0, values: levels))
        await harness.inject(
            dataPacket(cid: cid, name: "Fixture", sequence: 1, priority: 150, startCode: .perAddressPriority, values: priorities))
        await harness.inject(dataPacket(cid: cid, name: "Fixture", sequence: 2, priority: 150, values: levels))

        #expect(await harness.data.waitForCount(2))
        #expect(await harness.data.expectNoMore(count: 2), "the held levels for a new source must not notify before per-address priority")

        let received = harness.data.all
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
    }

    @Test("Packets with invalid sequence numbers are discarded")
    func sequenceFiltering() async throws {
        let harness = try await makeHarness()
        let cid = UUID()
        var sequence = await establishSource(cid: cid, in: harness)

        // a repeated and an older sequence number are both rejected
        await harness.inject(dataPacket(cid: cid, sequence: sequence - 1))
        await harness.inject(dataPacket(cid: cid, sequence: sequence - 2))

        // the next sequence number is accepted
        await harness.inject(dataPacket(cid: cid, sequence: sequence))
        sequence += 1

        // a jump back of 20 or more is accepted (source reset)
        await harness.inject(dataPacket(cid: cid, sequence: sequence &- 21))

        // the establishing PAP frame plus the two accepted frames; the rejected pair never notified
        #expect(await harness.data.waitForCount(3))
        #expect(await harness.data.expectNoMore(count: 3), "repeated or older sequence numbers should be discarded")
    }

    @Test("Preview data is filtered when preview filtering is enabled")
    func previewFiltering() async throws {
        let harness = try await makeHarness()
        let cid = UUID()
        let sequence = await establishSource(cid: cid, in: harness)

        await harness.inject(dataPacket(cid: cid, sequence: sequence, options: .preview))
        await harness.inject(dataPacket(cid: cid, sequence: sequence + 1))

        #expect(await harness.data.waitForCount(2))
        #expect(await harness.data.expectNoMore(count: 2), "preview data should be filtered")
    }

    @Test("During sampling, data is delivered immediately and marked as sampling")
    func samplingDelivery() async throws {
        let harness = try await makeHarness(endSampling: false)
        let samplingSocketId = try #require(await harness.receiver.socketsSampling.keys.first)
        await harness.receiver.beginSamplingPeriod()
        #expect(await harness.events.waitFor { if case .samplingStarted = $0 { return true } else { return false } })

        // a packet from a socket which is not sampling is rejected
        await harness.inject(dataPacket(cid: UUID(), sequence: 0), socketId: UUID())

        // a new source's levels notify immediately during sampling
        await harness.inject(dataPacket(cid: UUID(), sequence: 0), socketId: samplingSocketId)
        #expect(await harness.data.waitForCount(1))
        #expect(await harness.data.expectNoMore(count: 1), "packets from unknown sockets should be rejected while sampling")
        #expect(harness.data.all.last?.isSampling == true)
    }

    @Test("Packets for another universe are ignored")
    func universeMismatchIgnored() async throws {
        let harness = try await makeHarness()
        await harness.inject(dataPacket(cid: UUID(), universe: 2, sequence: 0))
        await harness.inject(dataPacket(cid: UUID(), universe: 2, sequence: 1, startCode: .perAddressPriority))
        #expect(await harness.data.expectNoMore(count: 0), "packets for another universe should be ignored")
    }

    @Test("A new source which is already terminated is ignored")
    func terminatedNewSourceIgnored() async throws {
        let harness = try await makeHarness()
        await harness.inject(dataPacket(cid: UUID(), sequence: 0, options: .terminated))
        #expect(await harness.data.expectNoMore(count: 0), "a terminated stream should not create a source")
    }

    @Test("A stream consumer may call back into the receiver without deadlocking")
    func reentrantConsumerMayCallBack() async throws {
        let harness = try await makeHarness()
        let cid = UUID()

        // a consumer runs off-actor; re-entering the receiver (isListening, stop) from within a data delivery
        // must not deadlock against in-flight packet processing
        let dataStream = harness.receiver.data
        let consumer = Task { [receiver = harness.receiver] in
            for await _ in dataStream {
                _ = await receiver.isListening
                await receiver.stop()
                break
            }
        }

        await harness.inject(dataPacket(cid: cid, sequence: 0))
        await harness.inject(dataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: Array(repeating: 100, count: 512)))

        await consumer.value  // completes only if the re-entrant stop did not deadlock
    }

    @Test("Per-address priority loss is notified exactly once")
    func perAddressPriorityLoss() async throws {
        let harness = try await makeHarness()
        let cid = UUID()
        var sequence = await establishSource(cid: cid, in: harness)

        // let the per-address priority timer expire, then send levels only
        try await Task.sleep(for: .milliseconds(120))
        await harness.inject(dataPacket(cid: cid, sequence: sequence))
        sequence &+= 1
        #expect(await harness.events.waitForCount(1, where: Self.isPAPLost))
        #expect(await harness.data.waitForCount(2), "the levels which triggered the loss should still be delivered")

        // further levels packets must not notify loss again
        await harness.inject(dataPacket(cid: cid, sequence: sequence))
        #expect(await harness.data.waitForCount(3))
        #expect(await harness.events.expectNoMore(count: 1, where: Self.isPAPLost), "loss should only be notified once")

        #expect(papLostSources(harness.events) == [cid])
    }

    @Test("Data frames preserve packet order")
    func orderingPreserved() async throws {
        let harness = try await makeHarness()
        let cid = UUID()
        var sequence = await establishSource(cid: cid, in: harness)

        let count = 20
        for index in 0..<count {
            var values = Array(repeating: UInt8(0), count: 512)
            values[0] = UInt8(index)
            await harness.inject(dataPacket(cid: cid, sequence: sequence, values: values))
            sequence &+= 1
        }
        #expect(await harness.data.waitForCount(count + 1))

        // drop the establishing frame, keep the ordered burst
        let burst = harness.data.all.dropFirst().map { $0.values[0] }
        #expect(Array(burst) == (0..<count).map { UInt8($0) }, "data frames must arrive in packet order")
    }

    @Test("Per-address priority loss is notified again after priorities resume")
    func perAddressPriorityLossAfterResumption() async throws {
        let harness = try await makeHarness()
        let cid = UUID()
        var sequence = await establishSource(cid: cid, in: harness)

        // let the per-address priority timer expire, then send levels only
        try await Task.sleep(for: .milliseconds(120))
        await harness.inject(dataPacket(cid: cid, sequence: sequence))
        sequence &+= 1
        #expect(await harness.events.waitForCount(1, where: Self.isPAPLost))

        // per-address priority resumes
        await harness.inject(dataPacket(cid: cid, sequence: sequence, startCode: .perAddressPriority, values: Array(repeating: 100, count: 512)))
        sequence &+= 1

        // a second loss must be notified
        try await Task.sleep(for: .milliseconds(120))
        await harness.inject(dataPacket(cid: cid, sequence: sequence))
        #expect(await harness.events.waitForCount(2, where: Self.isPAPLost), "a second loss must be notified after per-address priority resumed")
        #expect(papLostSources(harness.events) == [cid, cid])
    }

    // MARK: Sampling lifecycle

    @Test("endedSamplingPeriod ends sampling and notifies")
    func endedSamplingPeriodNotifies() async throws {
        let harness = try await makeHarness(endSampling: false)
        await harness.receiver.endedSamplingPeriod()
        #expect(await harness.events.waitFor { if case .samplingEnded = $0 { return true } else { return false } })
    }

    @Test("Ending the final sampling period stops the timer and does not re-arm")
    func finalSamplingPeriodDoesNotReArm() async throws {
        let harness = try await makeHarness(endSampling: false)
        await harness.receiver.beginSamplingPeriod()
        #expect(await harness.events.waitFor { if case .samplingStarted = $0 { return true } else { return false } })

        // the single socket's sampling period ends: it stops the timer and emits samplingEnded once
        await harness.receiver.endedSamplingPeriod()
        #expect(await harness.events.waitFor { if case .samplingEnded = $0 { return true } else { return false } })

        // past the production sampling window a re-armed timer would fire another samplingEnded; it must not
        let isSamplingEnded: @Sendable (sACNReceiverRaw.Event) -> Bool = { if case .samplingEnded = $0 { return true } else { return false } }
        #expect(await harness.events.expectNoMore(count: 1, quiet: .seconds(2), where: isSamplingEnded), "the sampling timer must not re-arm")
    }

    @Test("The sampling timer ends the sampling period and notifies")
    func samplingTimerEndsSampling() async throws {
        let harness = try await makeHarness(endSampling: false)
        await harness.receiver.beginSamplingPeriod()
        #expect(await harness.events.waitFor { if case .samplingStarted = $0 { return true } else { return false } })

        // the production sampling period is 1500 ms; the single-shot timer fires and ends sampling
        #expect(
            await harness.events.waitFor(timeout: .milliseconds(2500)) { if case .samplingEnded = $0 { return true } else { return false } })
    }

}

/// Socket-binding characterization of `sACNReceiverRaw` (bind + multicast join on loopback), gated behind
/// `SACNKIT_NETWORK_TESTS=1` with the loopback suites.
@Suite("Receiver raw sockets", .enabled(if: ProcessInfo.processInfo.environment["SACNKIT_NETWORK_TESTS"] == "1"))
struct ReceiverRawSocketTests {

    @Test("Restarting after a sampling cycle re-samples every retained socket", .timeLimit(.minutes(1)))
    func restartReSeedsSampling() async throws {
        let receiver = try #require(
            sACNReceiverRaw(
                runtime: NIORuntime(), ipMode: .ipv4Only, interfaces: [TestInterface.loopback], universe: 1, sourceLimit: 4,
                filterPreviewData: true, filterCIDs: [], sourceLossTimeout: 60, perAddressPriorityWait: 60))

        try await receiver.start()
        // ending the sampling cycle drains the retained socket from the sampling map
        await receiver.endedSamplingPeriod()
        #expect(await receiver.socketsSampling.isEmpty)
        await receiver.stop()

        // a restart must re-seed the retained socket as sampling (without the re-seed it would stay absent,
        // and processDataPacket would drop its packets for the whole 1500 ms window)
        try await receiver.start()
        #expect(await receiver.socketsSampling.count == 1)
        #expect(await receiver.socketsSampling.values.allSatisfy { $0 })
        await receiver.stop()
    }

}
