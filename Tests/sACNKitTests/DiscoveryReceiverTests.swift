import Foundation
import Testing

@testable import sACNKit

/// Characterizes the `sACNDiscoveryReceiver` actor's paged universe-list assembly by injecting packets
/// directly through the internal `process(data:)` seam - no sockets, so these run ungated.
@Suite("Discovery receiver assembly")
struct DiscoveryReceiverTests {

    private func inject(_ receiver: sACNDiscoveryReceiver, _ packet: Data) async {
        await receiver.process(data: packet)
    }

    @Test("A single-page discovery packet notifies the full universe list", .timeLimit(.minutes(1)))
    func singlePageNotifiesFullList() async throws {
        let receiver = sACNDiscoveryReceiver()
        var discovery = receiver.discovery.makeAsyncIterator()
        let cid = UUID()

        await inject(receiver, sACNTestDiscoveryPacket(cid: cid, name: "Src", universes: [1, 2, 3]))

        let info = try #require(await discovery.next())
        #expect(info.cid == cid)
        #expect(info.name == "Src")
        #expect(info.universes == [1, 2, 3])
    }

    @Test("Universe discovery notifies only after the final page, with the assembled list", .timeLimit(.minutes(1)))
    func multiPageNotifiesAfterLastPage() async throws {
        let receiver = sACNDiscoveryReceiver()
        var discovery = receiver.discovery.makeAsyncIterator()
        let cid = UUID()

        // page 0 of 1 (not the last page): must not notify yet
        await inject(receiver, sACNTestDiscoveryPacket(cid: cid, page: 0, lastPage: 1, universes: [1, 2, 3]))
        // page 1 of 1 (the last page): notifies the assembled list
        await inject(receiver, sACNTestDiscoveryPacket(cid: cid, page: 1, lastPage: 1, universes: [4, 5, 6]))

        // a premature notification after page 0 would make the first yield [1, 2, 3]
        let info = try #require(await discovery.next())
        #expect(info.universes == [1, 2, 3, 4, 5, 6])
    }

    @Test("An unchanged universe list is not re-notified", .timeLimit(.minutes(1)))
    func unchangedListNotRenotified() async throws {
        let receiver = sACNDiscoveryReceiver()
        var discovery = receiver.discovery.makeAsyncIterator()
        let cid = UUID()

        await inject(receiver, sACNTestDiscoveryPacket(cid: cid, universes: [1, 2, 3]))
        await inject(receiver, sACNTestDiscoveryPacket(cid: cid, universes: [1, 2, 3]))  // identical -> no notify
        await inject(receiver, sACNTestDiscoveryPacket(cid: cid, universes: [1, 2, 3, 4]))  // changed -> notify

        let first = try #require(await discovery.next())
        #expect(first.universes == [1, 2, 3])
        // the identical packet enqueued nothing, so the next yield is the changed list
        let second = try #require(await discovery.next())
        #expect(second.universes == [1, 2, 3, 4])
    }

    @Test("An unordered universe list is not notified", .timeLimit(.minutes(1)))
    func unorderedListNotNotified() async throws {
        let receiver = sACNDiscoveryReceiver()
        var discovery = receiver.discovery.makeAsyncIterator()
        let unordered = UUID()
        let ordered = UUID()

        // an unordered single-page list clears dirty and does not notify
        await inject(receiver, sACNTestDiscoveryPacket(cid: unordered, universes: [3, 1, 2]))
        // an ordered list from a different source does notify
        await inject(receiver, sACNTestDiscoveryPacket(cid: ordered, universes: [1, 2]))

        // the first (and only) yield is the ordered source; the unordered one never notified
        let info = try #require(await discovery.next())
        #expect(info.cid == ordered)
        #expect(info.universes == [1, 2])
    }

    @Test("A malformed discovery packet is surfaced on the debugLog stream", .timeLimit(.minutes(1)))
    func malformedPacketLogsToDebug() async throws {
        let receiver = sACNDiscoveryReceiver()
        var debug = receiver.debugLog.makeAsyncIterator()

        // a truncated universe-discovery packet fails the discovery-layer parse - previously this class of
        // error fell into the silent catch and never reached the diagnostic stream
        var packet = sACNTestDiscoveryPacket(cid: UUID(), universes: [1, 2, 3])
        packet.removeLast()
        await inject(receiver, packet)

        #expect(try #require(await debug.next()).isEmpty == false)
    }

    @Test("Source loss coalesces every expired source into one event and removes them", .timeLimit(.minutes(1)))
    func sourceLossCoalescesAndRemoves() async throws {
        let receiver = sACNDiscoveryReceiver()
        var events = receiver.events.makeAsyncIterator()
        let cid1 = UUID()
        let cid2 = UUID()

        await inject(receiver, sACNTestDiscoveryPacket(cid: cid1, universes: [1, 2]))
        await inject(receiver, sACNTestDiscoveryPacket(cid: cid2, universes: [3, 4]))
        #expect(await receiver.trackedSourceCount == 2)

        // expire both, then run one loss check (bypassing the heartbeat's listening guard via the seam)
        await receiver.expireAllSourceTimersForTesting()
        await receiver.checkForSourceLoss()

        let event = try #require(await events.next())
        guard case .sourcesLost(let cids) = event else {
            Issue.record("expected .sourcesLost, got \(event)")
            return
        }
        #expect(Set(cids) == [cid1, cid2])  // both coalesced into a single event
        #expect(await receiver.trackedSourceCount == 0)  // both removed
    }

}

/// End-to-end: a real `sACNSource` transmitting universe discovery over localhost multicast, received by
/// the `sACNDiscoveryReceiver` actor - the first exercise of actor-path socket inbound delivery. Multicast
/// on shared CI runners is unreliable, so gated behind `SACNKIT_NETWORK_TESTS=1`.
@Suite("Discovery loopback", .enabled(if: ProcessInfo.processInfo.environment["SACNKIT_NETWORK_TESTS"] == "1"))
struct DiscoveryLoopbackTests {

    @Test("A source's universe discovery reaches the receiver, and loss is reported", .timeLimit(.minutes(1)))
    func discoveryEndToEndAndLoss() async throws {
        let universe: UInt16 = 100
        // A known CID so we can pick out our own source: other suites run in parallel and every `sACNSource`
        // transmits universe discovery on the same well-known group, so this receiver sees theirs too.
        let cid = UUID()
        let receiver = sACNDiscoveryReceiver()
        var discovery = receiver.discovery.makeAsyncIterator()
        var events = receiver.events.makeAsyncIterator()
        try await receiver.start()

        let source = sACNSource(name: "Disc Source", cid: cid)
        try await source.addUniverse(sACNSourceUniverse(number: universe, levels: Array(repeating: 0, count: 512)))
        try await source.start()

        func teardown() async {
            await source.stop()
            await receiver.stop()
        }

        do {
            // our source sends a universe-discovery message immediately on start; skip any other sources
            var received: sACNDiscoveryReceiverSource?
            while received == nil {
                let next = try #require(await discovery.next())
                if next.cid == cid { received = next }
            }
            #expect(received?.name == "Disc Source")
            #expect(received?.universes == [universe])

            // force source-loss without waiting the 20 s discovery timeout, then let the 500 ms heartbeat
            // detect it (the receiver is listening, so the heartbeat is running)
            await receiver.expireAllSourceTimersForTesting()
            var lostOurs = false
            while !lostOurs {
                let event = try #require(await events.next())
                if case .sourcesLost(let cids) = event, cids.contains(cid) { lostOurs = true }
            }
        } catch {
            await teardown()
            throw error
        }
        await teardown()
    }

}
