import Foundation
import Testing

@testable import sACNKit

/// Exercises `sACNReceiver` state safety and merge delivery by driving its internal raw receiver directly,
/// without sockets, and observing the merged `data`/`events` streams.
@Suite("Receiver")
struct ReceiverTests {

    /// Fast timing constants for tests that drive per-address priority expiry.
    private static let fastTimeout: UInt64 = 150

    /// How long to sleep to guarantee a `fastTimeout` timer has expired.
    private static let fastTimeoutExpiry: Duration = .milliseconds(300)

    // MARK: Helpers

    /// A receiver wired to its internal raw receiver, with collectors on its streams.
    private struct Harness {

        let receiver: sACNReceiver
        let merged: StreamCollector<sACNReceiverMergedData>

        /// Injects a packet into the internal raw receiver, as socket callbacks do.
        func inject(_ packet: Data, socketId: UUID = UUID()) async {
            await receiver.receiver.process(data: packet, ipFamily: .IPv4, socketId: socketId, hostname: "192.168.1.10")
        }

        /// Waits until the most recent merged data satisfies the predicate.
        func waitUntilMerged(timeout: Duration = .seconds(10), where predicate: @Sendable (sACNReceiverMergedData) -> Bool) async -> Bool {
            await merged.waitFor(timeout: timeout) { predicate($0) }
        }

    }

    /// Creates a wired receiver for universe 1, with the merge sink connected as `start()` would, but
    /// without opening sockets.
    private func makeReceiver(
        sourceLossTimeout: UInt64, perAddressPriorityWait: UInt64
    ) async throws -> sACNReceiver {
        let receiver = try #require(
            sACNReceiver(
                ipMode: .ipv4Only, interfaces: [], universe: 1, sourceLimit: 4, filterPreviewData: true, filterCIDs: [],
                sourceLossTimeout: sourceLossTimeout, perAddressPriorityWait: perAddressPriorityWait))
        // wire the raw receiver's sink as start() would, without opening sockets
        await receiver.receiver.setSink(receiver)
        return receiver
    }

    /// Creates a receiver for universe 1 whose raw receiver delivers without sockets.
    private func makeHarness(
        sourceLossTimeout: UInt64 = sACNReceiverRaw.sourceLossTimeout, perAddressPriorityWait: UInt64 = sACNReceiverRaw.perAddressPriorityWait
    ) async throws -> Harness {
        let receiver = try await makeReceiver(sourceLossTimeout: sourceLossTimeout, perAddressPriorityWait: perAddressPriorityWait)
        let merged = StreamCollector(receiver.data)
        await receiver.receiver.endedSamplingPeriod()
        return Harness(receiver: receiver, merged: merged)
    }

    /// Creates a receiver for universe 1 whose raw receiver is actively sampling, without sockets.
    ///
    /// - Returns: The harness and the socket identifier registered as sampling, which must be passed when
    /// injecting packets.
    ///
    private func makeSamplingHarness(
        sourceLossTimeout: UInt64 = sACNReceiverRaw.sourceLossTimeout, perAddressPriorityWait: UInt64 = sACNReceiverRaw.perAddressPriorityWait
    ) async throws -> (harness: Harness, socketId: UUID) {
        let receiver = try await makeReceiver(sourceLossTimeout: sourceLossTimeout, perAddressPriorityWait: perAddressPriorityWait)
        let merged = StreamCollector(receiver.data)
        await receiver.receiver.beginSamplingPeriod()
        let socketId = try #require(await receiver.receiver.socketsSampling.keys.first)
        return (Harness(receiver: receiver, merged: merged), socketId)
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
    private func establishAndMerge(cid: UUID, levels: [UInt8], in harness: Harness) async {
        await harness.inject(dataPacket(cid: cid, sequence: 0, values: levels))
        await harness.inject(dataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: Array(repeating: 100, count: 512)))
        await harness.inject(dataPacket(cid: cid, sequence: 2, values: levels))
    }

    // MARK: Tests

    @Test("Merged data is delivered on the data stream")
    func mergedDataDelivered() async throws {
        let harness = try await makeHarness()
        let cid = UUID()
        let levels: [UInt8] = (0..<512).map { UInt8($0 % 256) }

        await establishAndMerge(cid: cid, levels: levels, in: harness)
        #expect(await harness.merged.waitForCount(1))

        let merged = try #require(harness.merged.all.first)
        #expect(merged.universe == 1)
        #expect(merged.levels == levels)
        #expect(merged.activeSources == [cid])
        #expect(merged.numberOfActiveSources == 1)
    }

    @Test("information(for:) may be called from within a data-stream consumer")
    func informationFromConsumer() async throws {
        let harness = try await makeHarness()
        let cid = UUID()

        // a consumer runs off-actor; re-entering the receiver (information) from within a merged delivery
        // must not deadlock and must observe the just-delivered source
        let dataStream = harness.receiver.data
        let obtained = Task { [receiver = harness.receiver] () -> sACNReceiverSource? in
            for await _ in dataStream {
                return try? await receiver.information(for: cid)
            }
            return nil
        }

        await establishAndMerge(cid: cid, levels: Array(repeating: 128, count: 512), in: harness)
        #expect(await obtained.value?.cid == cid)
    }

    @Test("information(for:) returns source information after a merge")
    func informationReturnsSource() async throws {
        let harness = try await makeHarness()
        let cid = UUID()

        await establishAndMerge(cid: cid, levels: Array(repeating: 128, count: 512), in: harness)
        #expect(await harness.merged.waitForCount(1))

        let information = try await harness.receiver.information(for: cid)
        #expect(information.cid == cid)
    }

    @Test("information(for:) throws for an unknown source")
    func informationUnknownSourceThrows() async throws {
        let harness = try await makeHarness()
        await #expect(throws: sACNReceiverValidationError.self) {
            try await harness.receiver.information(for: UUID())
        }
    }

    @Test("State stays consistent under concurrent public API calls while packets arrive")
    func concurrentAPIAccess() async throws {
        let harness = try await makeHarness()
        let cid = UUID()
        await establishAndMerge(cid: cid, levels: Array(repeating: 128, count: 512), in: harness)
        #expect(await harness.merged.waitForCount(1))

        // hammer the public API and packet injection concurrently; the actor serializes all of it
        await withTaskGroup(of: Void.self) { group in
            for iteration in 0..<100 {
                group.addTask { [receiver = harness.receiver] in
                    switch iteration % 3 {
                    case 0:
                        _ = try? await receiver.information(for: cid)
                    case 1:
                        _ = await receiver.isListening
                    default:
                        await harness.inject(dataPacket(cid: cid, sequence: UInt8((3 + iteration) % 256), values: Array(repeating: 64, count: 512)))
                    }
                }
            }
        }
        #expect(harness.merged.count >= 1)
    }

    // MARK: Phase 5 - richer merge surface

    @Test("Merged data surfaces per-address priorities, the active flag, and the universe priority")
    func mergedDataSurfacesPriorityFields() async throws {
        let harness = try await makeHarness()
        let cid = UUID()
        let levels = Array(repeating: UInt8(255), count: 512)
        var priorities = Array(repeating: UInt8(120), count: 512)
        priorities[0] = 0  // slot 0 unsourced

        await harness.inject(dataPacket(cid: cid, sequence: 0, values: levels))
        await harness.inject(dataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: priorities))
        await harness.inject(dataPacket(cid: cid, sequence: 2, values: levels))
        #expect(await harness.merged.waitForCount(1))

        let merged = try #require(harness.merged.all.last)
        #expect(merged.perAddressPrioritiesActive == true)
        #expect(merged.perAddressPriorities[0] == 0)  // unsourced slot
        #expect(merged.perAddressPriorities[1] == 120)  // winning per-address priority
        #expect(merged.universePriority == 100)  // the source's universe priority (packet default)
    }

    @Test("information(for:) surfaces per-source priority information")
    func informationSurfacesPriorityInfo() async throws {
        let harness = try await makeHarness()
        let cid = UUID()
        let levels = Array(repeating: UInt8(255), count: 512)
        var priorities = Array(repeating: UInt8(120), count: 512)
        priorities[0] = 0

        await harness.inject(dataPacket(cid: cid, sequence: 0, values: levels))
        await harness.inject(dataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: priorities))
        await harness.inject(dataPacket(cid: cid, sequence: 2, values: levels))
        #expect(await harness.merged.waitForCount(1))

        let info = try await harness.receiver.information(for: cid)
        #expect(info.usingUniversePriority == false)
        #expect(info.universePriority == 100)
        #expect(info.perAddressPriorities?.count == 512)
        #expect(info.perAddressPriorities?[0] == 0)
        #expect(info.perAddressPriorities?[1] == 120)
    }

    @Test("After per-address priority loss a source reports universe priority with no per-address priorities")
    func informationUniversePriorityAfterPAPLoss() async throws {
        let harness = try await makeHarness(sourceLossTimeout: Self.fastTimeout, perAddressPriorityWait: Self.fastTimeout)
        let cid = UUID()
        let levels = Array(repeating: UInt8(200), count: 512)

        await harness.inject(dataPacket(cid: cid, sequence: 0, values: levels))
        await harness.inject(dataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: Array(repeating: 100, count: 512)))
        await harness.inject(dataPacket(cid: cid, sequence: 2, values: levels))
        #expect(await harness.merged.waitForCount(1))

        // let per-address priority time out, then deliver levels to surface the loss (reverts to universe priority)
        try await Task.sleep(for: Self.fastTimeoutExpiry)
        await harness.inject(dataPacket(cid: cid, sequence: 3, values: levels))
        #expect(await harness.waitUntilMerged { $0.perAddressPrioritiesActive == false })

        let info = try await harness.receiver.information(for: cid)
        #expect(info.usingUniversePriority == true)
        #expect(info.perAddressPriorities == nil)
    }

    @Test("Losing per-address priority emits a perAddressPriorityLost event")
    func perAddressPriorityLostEmitsEvent() async throws {
        let harness = try await makeHarness(sourceLossTimeout: Self.fastTimeout, perAddressPriorityWait: Self.fastTimeout)
        let events = StreamCollector(harness.receiver.events)
        let cid = UUID()
        let levels = Array(repeating: UInt8(255), count: 512)

        await harness.inject(dataPacket(cid: cid, sequence: 0, values: levels))
        await harness.inject(dataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: Array(repeating: 100, count: 512)))
        await harness.inject(dataPacket(cid: cid, sequence: 2, values: levels))
        #expect(await harness.merged.waitForCount(1))

        // let the per-address priority timer expire, then deliver levels to surface the loss
        try await Task.sleep(for: Self.fastTimeoutExpiry)
        await harness.inject(dataPacket(cid: cid, sequence: 3, values: levels))
        #expect(await events.waitFor { if case .perAddressPriorityLost(let id) = $0, id == cid { return true } else { return false } })
    }

    // MARK: Per-address priority and sampling regression tests

    @Test("Per-address priorities captured during sampling are applied when sampling ends")
    func samplingPAPAppliedWhenSamplingEnds() async throws {
        let (harness, socketId) = try await makeSamplingHarness()
        let cid = UUID()
        let levels = Array(repeating: UInt8(255), count: 512)
        var priorities = Array(repeating: UInt8(100), count: 512)
        priorities[0] = 0

        await harness.inject(dataPacket(cid: cid, sequence: 0, values: levels), socketId: socketId)
        await harness.inject(dataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: priorities), socketId: socketId)
        #expect(await harness.merged.expectNoMore(count: 0), "no merged data should be delivered while sampling")

        await harness.receiver.receiver.endedSamplingPeriod()
        #expect(await harness.merged.waitForCount(1))
        let merged = try #require(harness.merged.all.last)
        #expect(merged.levels[0] == 0, "slot 0 has per-address priority 0 (unsourced) so must not output its level")
        #expect(merged.winners[0] == nil)
        #expect(merged.levels[1] == 255)
        #expect(merged.winners[1] == cid)
    }

    @Test("Losing per-address priority for a sampling source does not deliver merged data")
    func papLossWhileSamplingStaysQuiet() async throws {
        let (harness, socketId) = try await makeSamplingHarness(sourceLossTimeout: Self.fastTimeout, perAddressPriorityWait: Self.fastTimeout)
        let cid = UUID()

        await harness.inject(dataPacket(cid: cid, sequence: 0), socketId: socketId)
        await harness.inject(
            dataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: Array(repeating: 100, count: 512)), socketId: socketId)

        // let the per-address priority timer expire, then deliver levels to surface the loss
        try await Task.sleep(for: Self.fastTimeoutExpiry)
        await harness.inject(dataPacket(cid: cid, sequence: 2), socketId: socketId)
        #expect(await harness.merged.expectNoMore(count: 0), "per-address priority loss must not notify merged data while sampling")
    }

    @Test("Per-address priority loss, resumption and a second loss are all reflected in merged data")
    func secondPAPLossReflectedInMergedData() async throws {
        let harness = try await makeHarness(sourceLossTimeout: Self.fastTimeout, perAddressPriorityWait: Self.fastTimeout)
        let cid = UUID()
        let levels = Array(repeating: UInt8(255), count: 512)
        var priorities = Array(repeating: UInt8(100), count: 512)
        priorities[0] = 0

        // establish the source with per-address priorities (slot 0 unsourced)
        await harness.inject(dataPacket(cid: cid, sequence: 0, values: levels))
        await harness.inject(dataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: priorities))
        await harness.inject(dataPacket(cid: cid, sequence: 2, values: levels))
        #expect(await harness.waitUntilMerged { $0.levels[0] == 0 && $0.levels[1] == 255 })

        // first loss: universe priority applies to every slot again
        try await Task.sleep(for: Self.fastTimeoutExpiry)
        await harness.inject(dataPacket(cid: cid, sequence: 3, values: levels))
        #expect(await harness.waitUntilMerged { $0.levels[0] == 255 }, "merged data must reflect the first per-address priority loss")

        // per-address priority resumes (slot 0 unsourced again)
        await harness.inject(dataPacket(cid: cid, sequence: 4, startCode: .perAddressPriority, values: priorities))
        #expect(await harness.waitUntilMerged { $0.levels[0] == 0 }, "merged data must reflect resumed per-address priorities")

        // a second loss must also be delivered and reflected
        try await Task.sleep(for: Self.fastTimeoutExpiry)
        await harness.inject(dataPacket(cid: cid, sequence: 5, values: levels))
        #expect(await harness.waitUntilMerged { $0.levels[0] == 255 }, "merged data must reflect a second per-address priority loss")
    }

    @Test("Short packets during sampling still transfer to the main merger when sampling ends")
    func samplingShortPacketsAppliedWhenSamplingEnds() async throws {
        let (harness, socketId) = try await makeSamplingHarness()
        let cid = UUID()
        let levels = Array(repeating: UInt8(255), count: 100)
        var priorities = Array(repeating: UInt8(100), count: 100)
        priorities[0] = 0

        await harness.inject(sACNTestDataPacket(cid: cid, sequence: 0, values: levels), socketId: socketId)
        await harness.inject(sACNTestDataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: priorities), socketId: socketId)

        // a second source sends only per-address priority during sampling;
        // it has no levels so there is nothing to transfer
        let papOnlyCid = UUID()
        await harness.inject(
            sACNTestDataPacket(cid: papOnlyCid, sequence: 0, startCode: .perAddressPriority, values: Array(repeating: 100, count: 100)),
            socketId: socketId)

        await harness.receiver.receiver.endedSamplingPeriod()
        #expect(await harness.merged.waitForCount(1))
        let merged = try #require(harness.merged.all.last)
        #expect(merged.levels[0] == 0, "slot 0 has per-address priority 0 (unsourced) so must not output its level")
        #expect(merged.levels[1] == 255, "levels from a short packet must survive the transfer out of sampling")
        #expect(merged.winners[1] == cid)
        // beyond the short packet the source holds universe priority with no
        // levels, matching the live (non-sampling) path for short packets
        #expect(merged.levels[100] == 0, "slots beyond the short packet must output zero")
        #expect(merged.activeSources == [cid], "a source which only sent per-address priority during sampling has nothing to transfer")
    }

    @Test("Per-address priority loss surfaced by a preview-filtered packet still delivers merged data")
    func papLossViaPreviewPacketDeliversMergedData() async throws {
        let harness = try await makeHarness(sourceLossTimeout: Self.fastTimeout, perAddressPriorityWait: Self.fastTimeout)
        let cid = UUID()
        let levels = Array(repeating: UInt8(255), count: 512)
        var priorities = Array(repeating: UInt8(100), count: 512)
        priorities[0] = 0

        await harness.inject(sACNTestDataPacket(cid: cid, sequence: 0, values: levels))
        await harness.inject(sACNTestDataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: priorities))
        await harness.inject(sACNTestDataPacket(cid: cid, sequence: 2, values: levels))
        #expect(await harness.waitUntilMerged { $0.levels[0] == 0 && $0.levels[1] == 255 })

        // a preview-flagged packet is filtered from data delivery, so the loss
        // path's own notification is the only merged delivery
        try await Task.sleep(for: Self.fastTimeoutExpiry)
        await harness.inject(sACNTestDataPacket(cid: cid, sequence: 3, options: .preview, values: levels))
        #expect(
            await harness.waitUntilMerged { $0.levels[0] == 255 },
            "per-address priority loss must deliver merged data even when the triggering packet is preview-filtered")
    }

    @Test("A pending source lost before delivering levels does not gate merged data forever")
    func lostPendingSourceReleasesPendingCount() async throws {
        let harness = try await makeHarness(sourceLossTimeout: Self.fastTimeout, perAddressPriorityWait: Self.fastTimeout)
        let pendingCid = UUID()

        // levels for a new source are held, so its first delivered packet is the
        // per-address priority packet, creating a pending source
        await harness.inject(sACNTestDataPacket(cid: pendingCid, sequence: 0))
        await harness.inject(
            sACNTestDataPacket(cid: pendingCid, sequence: 1, startCode: .perAddressPriority, values: Array(repeating: 100, count: 512)))

        // let the source time out, then drive the loss check as the heartbeat would
        try await Task.sleep(for: Self.fastTimeoutExpiry)
        await harness.receiver.receiver.checkForSourceLoss()

        // a fresh source must still produce merged data
        let cid = UUID()
        let levels = Array(repeating: UInt8(128), count: 512)
        await harness.inject(sACNTestDataPacket(cid: cid, sequence: 0, values: levels))
        await harness.inject(sACNTestDataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: Array(repeating: 100, count: 512)))
        await harness.inject(sACNTestDataPacket(cid: cid, sequence: 2, values: levels))
        #expect(await harness.waitUntilMerged { $0.levels[0] == 128 }, "merged data must not be gated by a lost pending source")
    }

}
