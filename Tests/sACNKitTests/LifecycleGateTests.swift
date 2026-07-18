import Testing

@testable import sACNKit

/// Enumerates the shared `LifecycleGate` transition table directly, so the state machine the component
/// actors all lean on is trustworthy independent of their (timing-dependent, gated) suites.
@Suite("LifecycleGate")
struct LifecycleGateTests {

    /// Builds a gate in a given state via the public transitions.
    private func gate(in state: LifecycleGate.State) -> LifecycleGate {
        var gate = LifecycleGate()
        switch state {
        case .idle:
            break
        case .starting:
            _ = gate.reserveStart()
        case .listening:
            _ = gate.reserveStart()
            gate.toListening()
        case .reconfiguring:
            _ = gate.reserveStart()
            gate.toListening()
            gate.beginReconfigure()
        case .stopping:
            _ = gate.reserveStart()
            gate.toListening()
            gate.toStopping()
        }
        return gate
    }

    @Test("reserveStart maps every state and reserves only from idle")
    func reserveStartTable() {
        var idle = gate(in: .idle)
        #expect(idle.reserveStart() == .reserved)
        #expect(idle.state == .starting)

        for active in [LifecycleGate.State.listening, .reconfiguring] {
            var gate = gate(in: active)
            #expect(gate.reserveStart() == .alreadyActive)
            #expect(gate.state == active)  // unchanged
        }
        for transient in [LifecycleGate.State.starting, .stopping] {
            var gate = gate(in: transient)
            #expect(gate.reserveStart() == .busy)
            #expect(gate.state == transient)  // unchanged
        }
    }

    @Test("reserveReconfigure classifies every state without mutating")
    func reserveReconfigureTable() {
        #expect(gate(in: .idle).reserveReconfigure() == .proceedIdle)
        #expect(gate(in: .listening).reserveReconfigure() == .proceedListening)
        for busy in [LifecycleGate.State.starting, .reconfiguring, .stopping] {
            #expect(gate(in: busy).reserveReconfigure() == .busy)
        }

        let gate = gate(in: .listening)
        _ = gate.reserveReconfigure()
        #expect(gate.state == .listening)  // non-mutating
    }

    @Test("beginReconfigure moves listening to reconfiguring")
    func beginReconfigure() {
        var gate = gate(in: .listening)
        gate.beginReconfigure()
        #expect(gate.state == .reconfiguring)
    }

    @Test("isListening is true only for listening and reconfiguring")
    func isListeningDerivation() {
        #expect(gate(in: .idle).isListening == false)
        #expect(gate(in: .starting).isListening == false)
        #expect(gate(in: .listening).isListening == true)
        #expect(gate(in: .reconfiguring).isListening == true)
        #expect(gate(in: .stopping).isListening == false)
    }

    @Test("a stop request survives transitions until reachedIdle clears it")
    func stopRequestSurvivesUntilIdle() {
        var gate = gate(in: .listening)
        gate.requestStop()
        #expect(gate.stopRequested)
        gate.toStopping()
        #expect(gate.stopRequested)  // survives the transition

        _ = gate.reachedIdle()
        #expect(gate.stopRequested == false)  // cleared at idle
        #expect(gate.state == .idle)
    }

    @Test("reachedIdle drains its waiters exactly once")
    func reachedIdleDrainsWaitersOnce() async {
        var gate = gate(in: .listening)
        gate.toStopping()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gate.addStopWaiter(continuation)
            let waiters = gate.reachedIdle()
            #expect(waiters.count == 1)
            #expect(gate.reachedIdle().isEmpty)  // drained - never handed out twice
            waiters.forEach { $0.resume() }
        }
        #expect(gate.state == .idle)
    }

    @Test("interfaceDiff handles the all/named shapes")
    func interfaceDiffShapes() {
        // all -> named
        let toNamed = interfaceDiff(currentKeys: [""], newInterfaces: ["en0", "en1"])
        #expect(toNamed.existingInterfaces == [])
        #expect(toNamed.keysToAdd == ["en0", "en1"])
        #expect(toNamed.keysToRemove == [""])

        // named -> all
        let toAll = interfaceDiff(currentKeys: ["en0"], newInterfaces: [])
        #expect(toAll.existingInterfaces == ["en0"])
        #expect(toAll.keysToAdd == [""])
        #expect(toAll.keysToRemove == ["en0"])

        // named -> named (overlap preserved)
        let named = interfaceDiff(currentKeys: ["en0", "en1"], newInterfaces: ["en1", "en2"])
        #expect(named.existingInterfaces == ["en0", "en1"])
        #expect(named.keysToAdd == ["en2"])
        #expect(named.keysToRemove == ["en0"])

        // all -> all (no change)
        let noop = interfaceDiff(currentKeys: [""], newInterfaces: [])
        #expect(noop.existingInterfaces == [])
        #expect(noop.keysToAdd == [])
        #expect(noop.keysToRemove == [])
    }

}
