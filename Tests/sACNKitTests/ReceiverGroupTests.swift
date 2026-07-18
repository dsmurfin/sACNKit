import Foundation
import Testing

@testable import sACNKit

/// Exercises `sACNReceiverGroup` state serialization and stream delivery.
///
/// Most tests are socket-free. Tests which add a startable universe bind local sockets (bind and multicast
/// join only; received data is injected through the child receiver's raw-engine seam, so no network traffic
/// is required) and are gated behind `SACNKIT_NETWORK_TESTS=1`, keeping the required CI jobs free of
/// environment-sensitive socket operations.
@Suite("Receiver group")
struct ReceiverGroupTests {

    /// Whether tests which bind sockets are enabled.
    private static let networkTestsEnabled = ProcessInfo.processInfo.environment["SACNKIT_NETWORK_TESTS"] == "1"

    // MARK: Helpers

    private func makeGroup(interfaces: Set<String> = []) -> sACNReceiverGroup {
        sACNReceiverGroup(interfaces: interfaces)
    }

    // MARK: State serialization

    @Test("information(for:on:) throws for an unknown universe")
    func informationUnknownUniverseThrows() async {
        let group = makeGroup()
        await #expect(throws: sACNReceiverValidationError.self) {
            try await group.information(for: UUID(), on: 1)
        }
    }

    @Test("Removing a universe which was never added returns")
    func removeNonexistentUniverse() async {
        let group = makeGroup()
        await group.remove(universe: 1)
    }

    @Test("Adding an invalid universe throws")
    func addInvalidUniverseThrows() async {
        let group = makeGroup()
        await #expect(throws: sACNReceiverValidationError.self) {
            try await group.add(universe: 0)
        }
    }

    @Test("Concurrent remove, information and child access is serialized")
    func concurrentAccess() async {
        let group = makeGroup()

        await withTaskGroup(of: Void.self) { taskGroup in
            for iteration in 0..<200 {
                taskGroup.addTask {
                    let universe = UInt16(1 + iteration % 8)
                    switch iteration % 3 {
                    case 0:
                        await group.remove(universe: universe)
                    case 1:
                        _ = try? await group.information(for: UUID(), on: universe)
                    default:
                        _ = await group.child(for: universe)
                    }
                }
            }
        }
    }

    // MARK: Interface and registration state

    @Test("updateInterfaces applies to universes added later")
    func updateInterfacesPersists() async throws {
        let group = makeGroup()
        try await group.updateInterfaces([TestInterface.loopback])
        #expect(await group.interfaces == [TestInterface.loopback], "updated interfaces must persist for universes added later")
    }

    @Test("A failed add leaves no receiver registered and a retry can succeed", .enabled(if: networkTestsEnabled))
    func addFailureLeavesNoRegistration() async throws {
        // an interface which does not exist forces the child receiver's start() to throw
        let group = makeGroup(interfaces: ["sacnkit-no-such-interface"])
        await #expect(throws: (any Error).self) {
            try await group.add(universe: 1)
        }
        #expect(await group.child(for: 1) == nil, "a failed add must not register a dead receiver")

        // after correcting the interfaces the same add must be retryable
        // (binds local sockets; no network traffic is required)
        try await group.updateInterfaces([])
        try await group.add(universe: 1)
        let child = try #require(await group.child(for: 1))
        #expect(await child.isListening == true)

        await child.stop()
        await group.remove(universe: 1)
    }

    // MARK: Stream delivery

    @Test("Adding a universe delivers its initial samplingStarted event", .enabled(if: networkTestsEnabled))
    func addDeliversSamplingStarted() async throws {
        // the child emits .samplingStarted synchronously during start(); the group must subscribe before
        // starting so this signal is not lost (it is paired with the ~1.5s later .samplingEnded)
        let group = makeGroup()
        let events = StreamCollector(group.events)
        try await group.add(universe: 1)

        #expect(
            await events.waitFor { if case .samplingStarted(let universe) = $0, universe == 1 { return true } else { return false } },
            "the group must deliver the child's initial .samplingStarted(universe:)")

        await group.remove(universe: 1)
    }

    @Test("A data-stream consumer may call back into the group without deadlock", .enabled(if: networkTestsEnabled))
    func consumerMayReenterGroup() async throws {
        // binds local sockets (bind and multicast join only); data is injected through the child receiver's
        // raw-engine seam
        let group = makeGroup()
        try await group.add(universe: 1)
        let child = try #require(await group.child(for: 1))

        // end sampling so injected packets from any socket identifier are accepted
        await child.receiver.endedSamplingPeriod()

        let cid = UUID()
        // a consumer runs off-actor; from within a group data delivery it re-enters the group, including the
        // two riskiest re-entries: add (socket I/O) and removing the universe whose data this is
        let dataStream = group.data
        let outcome = Task { () -> (info: sACNReceiverSource?, addSucceeded: Bool) in
            for await _ in dataStream {
                let info = try? await group.information(for: cid, on: 1)
                var addSucceeded = true
                do { try await group.add(universe: 2) } catch { addSucceeded = false }
                await group.remove(universe: 1)
                return (info, addSucceeded)
            }
            return (nil, false)
        }

        // levels, then per-address priority, then levels produce a merged frame
        let hostname = "192.168.1.10"
        await child.receiver.process(data: sACNTestDataPacket(cid: cid, sequence: 0), ipFamily: .IPv4, socketId: UUID(), hostname: hostname)
        await child.receiver.process(
            data: sACNTestDataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: Array(repeating: 100, count: 512)),
            ipFamily: .IPv4, socketId: UUID(), hostname: hostname)
        await child.receiver.process(data: sACNTestDataPacket(cid: cid, sequence: 2), ipFamily: .IPv4, socketId: UUID(), hostname: hostname)

        let result = await outcome.value
        #expect(result.info?.cid == cid)
        #expect(result.addSucceeded, "add from within a consumer must not throw")
        #expect(await group.child(for: 2) != nil, "add from within a consumer must register the universe")
        #expect(await group.child(for: 1) == nil, "remove of the delivering universe from within its consumer must succeed")

        await group.child(for: 2)?.stop()
        await group.remove(universe: 2)
    }

}
