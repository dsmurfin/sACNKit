//
//  LifecycleGate.swift
//
//  Copyright (c) 2026 Daniel Murfin
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

/// Lifecycle Gate
///
/// The shared reserve-before-await lifecycle state machine for the sACN component actors (`sACNSource`,
/// `sACNDiscoveryReceiver`, and the receiver vertical). Held as a `private var gate` on each actor: it never
/// crosses an isolation boundary (non-`Sendable`), and every method is synchronous and runs in the actor's
/// isolation, so the reservation transitions happen atomically before the first `await`.
///
/// The gate owns only the shared parts: the state, the stop-supersede flag, and the `stop()` waiter
/// continuations. **Teardown stays per-component** - the source drains its 3 termination packets over the
/// transmit timer, while the receivers `await` their socket close - so it lives in each actor, not here.
///
struct LifecycleGate {

    /// The lifecycle state.
    ///
    /// `.starting`, `.reconfiguring` and `.stopping` are exclusive "busy" reservations that make `start`,
    /// `stop` and `updateInterfaces` mutually exclusive across their suspension points.
    enum State {

        case idle, starting, listening, reconfiguring, stopping

    }

    private(set) var state: State = .idle

    /// A stop requested while `.starting` or `.reconfiguring`: the in-flight operation observes it and
    /// unwinds to idle instead of proceeding.
    private(set) var stopRequested = false

    /// Continuations from `stop()` callers, all resumed when teardown reaches `.idle`.
    private var stopContinuations: [CheckedContinuation<Void, Never>] = []

    /// Whether the component is actively listening/transmitting (sockets live). Derived from `state` rather
    /// than a separate flag, so the two can never desync.
    var isListening: Bool { state == .listening || state == .reconfiguring }

    /// The outcome of a `reserveStart()`; the component maps it to its own error type.
    enum ReserveResult {

        /// Reserved (`.idle` -> `.starting`); proceed with the start.
        case reserved

        /// Already listening or reconfiguring; the component throws its "already started" error.
        case alreadyActive

        /// A start/stop is transiently in flight; the component throws its "busy" error.
        case busy

    }

    /// Reserves a start: `.idle` -> `.starting` (clearing any stale stop request). `.listening`/
    /// `.reconfiguring` report `.alreadyActive`; the transient `.starting`/`.stopping` report `.busy`.
    mutating func reserveStart() -> ReserveResult {
        switch state {
        case .idle:
            state = .starting
            stopRequested = false
            return .reserved
        case .listening, .reconfiguring:
            return .alreadyActive
        case .starting, .stopping:
            return .busy
        }
    }

    /// How an `updateInterfaces` entry should proceed.
    enum ReconfigureReservation {

        /// Idle: no sockets are bound, so mutate synchronously with no reservation.
        case proceedIdle

        /// Listening: reserve `.reconfiguring` (via `beginReconfigure()`) and rebind all-or-nothing.
        case proceedListening

        /// A start/stop/reconfigure is in flight; the component throws its "busy" error.
        case busy

    }

    /// Classifies an `updateInterfaces` entry. Non-mutating: the `.reconfiguring` transition itself is
    /// `beginReconfigure()`, deferred until after the caller's no-op ("interfaces unchanged") check, so the
    /// busy-rejection is shared here while the reservation still happens at the right point.
    func reserveReconfigure() -> ReconfigureReservation {
        switch state {
        case .idle:
            return .proceedIdle
        case .listening:
            return .proceedListening
        case .starting, .reconfiguring, .stopping:
            return .busy
        }
    }

    /// Reserves a reconfigure by moving `.listening` -> `.reconfiguring`. Call only on the `.proceedListening`
    /// path after the no-op check (`reserveReconfigure()` classified the entry).
    mutating func beginReconfigure() {
        precondition(state == .listening, "beginReconfigure requires a reserved .listening state")
        state = .reconfiguring
    }

    /// Moves to `.listening` (end of a successful start).
    mutating func toListening() {
        state = .listening
    }

    /// Moves to `.stopping` (start of a teardown drain).
    mutating func toStopping() {
        state = .stopping
    }

    /// Flags a stop that is superseding an in-flight start/reconfigure.
    mutating func requestStop() {
        stopRequested = true
    }

    /// Registers a `stop()` caller to be resumed when teardown reaches idle.
    mutating func addStopWaiter(_ continuation: CheckedContinuation<Void, Never>) {
        stopContinuations.append(continuation)
    }

    /// Completes teardown: returns to `.idle`, clears the stop request, and drains and returns the waiters.
    ///
    /// The waiters are emptied in this single isolated mutation, so a `CheckedContinuation` can never be
    /// handed out twice. The caller resumes them: `gate.reachedIdle().forEach { $0.resume() }`.
    mutating func reachedIdle() -> [CheckedContinuation<Void, Never>] {
        state = .idle
        stopRequested = false
        let waiters = stopContinuations
        stopContinuations.removeAll()
        return waiters
    }

}

/// Computes the interface-key diff for a socket reconfiguration, honouring the convention that a single
/// `""` key means "all interfaces" (mutually exclusive with named-interface keys - a never-mixed shape the
/// busy-gating enforces, so the all-interfaces case is exactly `currentKeys == [""]`).
///
/// Shared by the component actors' `updateInterfaces`.
///
/// - Parameters:
///    - currentKeys: The keys of the currently held sockets (`""` for the all-interfaces socket).
///    - newInterfaces: The requested interfaces (empty means all interfaces).
///
/// - Returns: The current interface set (empty == all interfaces), and the keys to add and remove.
///
func interfaceDiff(
    currentKeys: Set<String>, newInterfaces: Set<String>
) -> (existingInterfaces: Set<String>, keysToAdd: Set<String>, keysToRemove: Set<String>) {
    // Enforce the never-mixed shape the callers guarantee: keys are either exactly `[""]` (all interfaces)
    // or all named. A mixed set would make the `== [""]` test below wrong.
    assert(!currentKeys.contains("") || currentKeys == [""], "mixed all-interfaces and named socket keys")
    let existingInterfaces = currentKeys == [""] ? Set<String>() : currentKeys
    let newKeys: Set<String> = newInterfaces.isEmpty ? [""] : newInterfaces
    return (existingInterfaces, newKeys.subtracting(currentKeys), currentKeys.subtracting(newKeys))
}
