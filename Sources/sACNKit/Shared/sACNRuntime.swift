//
//  sACNRuntime.swift
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

/// Runtime Task
///
/// A cancellable scheduled task (repeating or one-shot) minted by an `sACNRuntime`.
///
/// **Ownership contract:** the handle must be **retained** for as long as the task should run. Dropping
/// the handle is equivalent to `cancel()` (the `NIORuntime` conformers deinit-cancel by construction), so
/// a re-arming call site must retain the new handle - and, because cancellation is not a strict barrier
/// (see `cancel()`), should also cancel the old one and keep its tick body idempotent.
///
protocol RuntimeTask: Sendable {

    /// Cancels the scheduled task: no *future* occurrences are scheduled after this returns.
    ///
    /// Cancellation is **not** a strict barrier - an occurrence already dequeued or in flight when
    /// `cancel()` lands may still complete once (e.g. an off-loop cancel racing a due tick). Tick bodies
    /// must therefore remain safe to run once after teardown (guard on the owner's lifecycle state),
    /// rather than relying on cancellation alone.
    func cancel()

}

/// sACN Runtime
///
/// The internal execution/transport seam that keeps SwiftNIO out of the component actors. It bundles the
/// three things a component actor needs as **one matched serial context**: the `SerialExecutor` the actor
/// is isolated to, timer scheduling on that same context, and (added when the first actor needs it) sockets
/// that deliver on it. They must share one context, or synchronous in-isolation packet delivery would break.
///
/// NIO is confined to the conforming `NIORuntime`; components depend only on this protocol. This is not
/// public API - a future alternative transport is a new conformer, a contained internal change.
///
protocol sACNRuntime: Sendable {

    /// The serial executor a component actor isolates itself to (`unownedExecutor`).
    var serialExecutor: any SerialExecutor { get }

    /// Schedules a repeating task on the runtime's serial context.
    ///
    /// - Parameters:
    ///    - after: The delay before the first occurrence.
    ///    - every: The interval between occurrences.
    ///    - body: The work to run on each occurrence.
    ///
    /// - Returns: A cancellable `RuntimeTask`.
    ///
    func scheduleRepeated(after: Duration, every: Duration, _ body: @escaping @Sendable () -> Void) -> any RuntimeTask

    /// Schedules a one-shot task on the runtime's serial context.
    ///
    /// - Parameters:
    ///    - after: The delay before the task runs.
    ///    - body: The work to run.
    ///
    /// - Returns: A cancellable `RuntimeTask`.
    ///
    func scheduleOnce(after: Duration, _ body: @escaping @Sendable () -> Void) -> any RuntimeTask

}
