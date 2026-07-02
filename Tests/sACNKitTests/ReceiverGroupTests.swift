import Foundation
import Testing

@testable import sACNKit

/// Exercises `sACNReceiverGroup` state serialization without sockets.
///
/// Universe additions start sockets, so end-to-end group behavior is covered by the
/// network-gated loopback tests; these tests cover the lock-free-racing surfaces
/// (`remove`, `information`, delegate setters).
@Suite("Receiver group")
struct ReceiverGroupTests {

    private func makeGroup() -> sACNReceiverGroup {
        sACNReceiverGroup(delegateQueue: DispatchQueue(label: "com.danielmurfin.sACNKitTests.receiverGroupClient"))
    }

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

}
