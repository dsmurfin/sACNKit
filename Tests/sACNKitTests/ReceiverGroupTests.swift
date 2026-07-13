import Foundation
import Testing

@testable import sACNKit

/// Exercises `sACNReceiverGroup` state serialization and callback delivery.
///
/// Most tests are socket-free. Tests which add a startable universe bind local
/// sockets (bind and multicast join only; received data is injected through the
/// child receiver's raw-engine seam, so no network traffic is required) and are
/// gated behind `SACNKIT_NETWORK_TESTS=1` with the loopback suite, keeping the
/// required CI jobs free of environment-sensitive socket operations.
@Suite("Receiver group")
struct ReceiverGroupTests {

    /// Whether tests which bind sockets are enabled.
    private static let networkTestsEnabled = ProcessInfo.processInfo.environment["SACNKIT_NETWORK_TESTS"] == "1"

    /// The timeout for waiting on an expected delegate callback or bounded call.
    private static let callbackTimeout: DispatchTimeInterval = .milliseconds(10000)

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

    /// A recording `sACNReceiverGroupDelegate`.
    private final class DelegateMock: sACNReceiverGroupDelegate {

        var onMergedData: ((sACNReceiverMergedData) -> Void)?

        func receiverGroup(
            _ receiverGroup: sACNReceiverGroup, interface: String?, socketDidCloseWithError error: Error?, forUniverse universe: UInt16
        ) {}

        func receiverGroupMergedData(_ receiverGroup: sACNReceiverGroup, mergedData: sACNReceiverMergedData) {
            onMergedData?(mergedData)
        }

        func receiverGroupStartedSampling(_ receiverGroup: sACNReceiverGroup, forUniverse universe: UInt16) {}

        func receiverGroupEndedSampling(_ receiverGroup: sACNReceiverGroup, forUniverse universe: UInt16) {}

        func receiverGroup(_ receiverGroup: sACNReceiverGroup, lostSources: [UUID], forUniverse universe: UInt16) {}

        func receiverGroupExceededSources(_ receiverGroup: sACNReceiverGroup, forUniverse universe: UInt16) {}

    }

    private func makeGroup(interfaces: Set<String> = []) -> sACNReceiverGroup {
        sACNReceiverGroup(interfaces: interfaces, delegateQueue: DispatchQueue(label: "com.danielmurfin.sACNKitTests.receiverGroupClient"))
    }

    // MARK: State serialization

    @Test("information(for:on:) throws for an unknown universe")
    func informationUnknownUniverseThrows() {
        let group = makeGroup()
        #expect(throws: sACNReceiverValidationError.self) {
            try group.information(for: UUID(), on: 1)
        }
    }

    @Test("Removing a universe which was never added returns")
    func removeNonexistentUniverse() {
        let group = makeGroup()
        group.remove(universe: 1)
    }

    @Test("Adding an invalid universe throws")
    func addInvalidUniverseThrows() {
        let group = makeGroup()
        #expect(throws: sACNReceiverValidationError.self) {
            try group.add(universe: 0)
        }
    }

    @Test("Concurrent remove, information and delegate access is serialized")
    func concurrentAccess() {
        let group = makeGroup()

        DispatchQueue.concurrentPerform(iterations: 200) { iteration in
            let universe = UInt16(1 + iteration % 8)
            switch iteration % 3 {
            case 0:
                group.remove(universe: universe)
            case 1:
                _ = try? group.information(for: UUID(), on: universe)
            default:
                group.setDelegate(nil)
            }
        }
    }

    // MARK: Interface and registration state

    @Test("updateInterfaces applies to universes added later")
    func updateInterfacesPersists() throws {
        let group = makeGroup()
        try group.updateInterfaces(["lo0"])
        #expect(group.interfaces == ["lo0"], "updated interfaces must persist for universes added later")
    }

    @Test("A failed add leaves no receiver registered and a retry can succeed", .enabled(if: networkTestsEnabled))
    func addFailureLeavesNoRegistration() throws {
        // an interface which does not exist forces the child receiver's start() to throw
        let group = makeGroup(interfaces: ["sacnkit-no-such-interface"])
        #expect(throws: (any Error).self) {
            try group.add(universe: 1)
        }
        #expect(group.receivers[1] == nil, "a failed add must not register a dead receiver")

        // after correcting the interfaces the same add must be retryable
        // (binds local sockets; no network traffic is required)
        try group.updateInterfaces([])
        try group.add(universe: 1)
        defer { group.receivers[1]?.stop() }
        #expect(group.receivers[1] != nil)
        #expect(group.receivers[1]?.isListening == true)
    }

    // MARK: Callback delivery

    @Test("Group callbacks may call back into the group without deadlock", .enabled(if: networkTestsEnabled))
    func callbacksMayReenterGroup() throws {
        // binds local sockets (bind and multicast join only); data is injected
        // through the child receiver's raw-engine seam
        let group = makeGroup()
        let delegate = DelegateMock()
        group.setDelegate(delegate)
        try group.add(universe: 1)
        let child = try #require(group.receivers[1])
        defer {
            child.stop()
            group.receivers[2]?.stop()
        }

        // end sampling so injected packets from any socket identifier are accepted
        child.receiver.endedSamplingPeriod()

        let cid = UUID()
        let reentered = DispatchSemaphore(value: 0)
        let information = LockedBox<sACNReceiverSource>()
        let addError = LockedBox<any Error>()
        delegate.onMergedData = { _ in
            // re-enter the group from within a delegate callback, including the two
            // riskiest re-entries: add (socket I/O while holding the state queue)
            // and removing the universe whose callback this is
            information.value = try? group.information(for: cid, on: 1)
            do {
                try group.add(universe: 2)
            } catch {
                addError.value = error
            }
            group.remove(universe: 1)
            reentered.signal()
        }

        // levels, then per-address priority, then levels produce a merged callback
        child.receiver.socketDelegateQueue.sync {
            let hostname = "192.168.1.10"
            child.receiver.process(data: sACNTestDataPacket(cid: cid, sequence: 0), ipFamily: .IPv4, socketId: UUID(), hostname: hostname)
            child.receiver.process(
                data: sACNTestDataPacket(cid: cid, sequence: 1, startCode: .perAddressPriority, values: Array(repeating: 100, count: 512)),
                ipFamily: .IPv4, socketId: UUID(), hostname: hostname)
            child.receiver.process(data: sACNTestDataPacket(cid: cid, sequence: 2), ipFamily: .IPv4, socketId: UUID(), hostname: hostname)
        }

        #expect(
            reentered.wait(timeout: .now() + Self.callbackTimeout) == .success,
            "re-entering the group from a delegate callback must not deadlock")
        #expect(information.value?.cid == cid)
        #expect(addError.value == nil, "add from within a callback must not throw")
        #expect(group.receivers[2] != nil, "add from within a callback must register the universe")
        #expect(group.receivers[1] == nil, "remove of the delivering universe from within its callback must succeed")
    }

}
