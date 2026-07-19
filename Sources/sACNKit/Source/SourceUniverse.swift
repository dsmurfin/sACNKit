//
//  SourceUniverse.swift
//
//  Copyright (c) 2023 Daniel Murfin
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

import Foundation

/// Source Universe
///
/// A universes contains level and priority information.
class SourceUniverse: Equatable {

    /// The range of data universe numbers.
    static let dataUniverseNumbers: ClosedRange<UInt16> = UInt16.validUniverses

    /// The universe number used for discovery.
    static let discoveryUniverseNumber: UInt16 = 64214

    /// The universe number.
    var number: UInt16

    /// The per-packet priority.
    var priority: UInt8?

    /// The level data (512).
    var levels: [UInt8]

    /// The priority (per-slot) data (512).
    var priorities: [UInt8]?

    /// The pre-composed levels packet (root + framing + DMP levels), mutated in place at frame rate.
    private(set) var levelsPacket: Data

    /// The pre-composed per-address-priority packet (root + framing + DMP priorities), mutated in place.
    private(set) var prioritiesPacket: Data

    /// The last transmitted sequence number for this universe.
    private(set) var sequence: UInt8

    /// The number of transmit ticks since a NULL start-code (levels) packet was last sent, used to drive the
    /// keep-alive cadence (reset to 0 whenever levels are sent, whether on change or keep-alive).
    private(set) var ticksSinceLevels: Int

    /// The number of transmit ticks since a per-address priority (0xDD) packet was last sent, used to drive
    /// the PAP keep-alive cadence (reset to 0 whenever priorities are sent).
    private(set) var ticksSincePriorities: Int

    /// The number of non-changing messages that have been sent (starts at 3 when levels have changed).
    private(set) var dirtyCounter: Int

    /// Whether this universe should immediately send a priority message.
    private(set) var dirtyPriority: Bool

    /// Whether this universe should be terminated.
    private(set) var shouldTerminate: Bool

    /// Whether the universe should be removed after termination.
    private(set) var removeAfterTerminate: Bool

    /// Whether the this universe is pending socket removal.
    private(set) var pendingSocketRemoval: Bool

    /// Initializes a universe with a public `sACNSourceUniverse`.
    ///
    ///  - parameters:
    ///     - universe: A public `sACNSourceUniverse`.
    ///     - sourcePriority: The priority for the source containing this universe.
    ///     - nameData: The name data for the source.
    ///     - rootLayer: The source's pre-compiled root layer (constant for the source's lifetime).
    ///
    init(with universe: sACNSourceUniverse, sourcePriority: UInt8, nameData: Data, rootLayer: Data) {
        self.number = universe.number
        self.priority = universe.priority
        self.levels = universe.levels
        self.priorities = universe.priorities
        let framingLayer = DataFramingLayer.createAsData(nameData: nameData, priority: self.priority ?? sourcePriority, universe: universe.number)
        self.levelsPacket = rootLayer + framingLayer + DMPLayer.createAsData(startCode: .null, values: universe.levels)
        self.prioritiesPacket =
            rootLayer + framingLayer
            + DMPLayer.createAsData(startCode: .perAddressPriority, values: universe.priorities ?? Array(repeating: 0, count: 512))
        self.sequence = 0
        self.ticksSinceLevels = 0
        self.ticksSincePriorities = 0
        self.dirtyCounter = 3
        self.dirtyPriority = true
        self.shouldTerminate = false
        self.removeAfterTerminate = false
        self.pendingSocketRemoval = false
    }

    /// Resets this universe for new transmission.
    func reset() {
        self.ticksSinceLevels = 0
        self.ticksSincePriorities = 0
        self.dirtyCounter = 3
        self.dirtyPriority = true
        self.shouldTerminate = false
        self.removeAfterTerminate = false
        self.pendingSocketRemoval = false
    }

    /// Updates an existing universe with new priorities and values from an `sACNSourceUniverse`.
    ///
    ///  - parameters:
    ///     - universe: A public `sACNSourceUniverse`.
    ///     - sourcePriority: The priority for the source containing this universe (applied when the
    ///       universe has no per-packet priority override).
    ///     - isSourceActive: Whether the source is active.
    ///
    ///  - Throws: An error of type `sACNSourceValidationError`.
    ///
    func update(with universe: sACNSourceUniverse, sourcePriority: UInt8, sourceActive isSourceActive: Bool) throws {
        guard universe.levels.count == 512 else {
            throw sACNSourceValidationError.incorrectLevelsCount
        }
        if let priorities = universe.priorities {
            guard priorities.count == 512 else {
                throw sACNSourceValidationError.incorrectPrioritiesCount
            }
            guard priorities.allSatisfy({ $0.validPriority() }) else {
                throw sACNSourceValidationError.invalidPriorities
            }
        }

        var dirty: Bool = false

        if self.priority != universe.priority {
            self.priority = universe.priority
            // write the effective framing priority - the per-packet override if set, else the source
            // priority - so clearing the override reverts the wire priority instead of leaving it stale
            let effectivePriority = universe.priority ?? sourcePriority
            self.levelsPacket.replacingComposedPriority(with: effectivePriority)
            self.prioritiesPacket.replacingComposedPriority(with: effectivePriority)
            dirty = true
        }

        if self.levels != universe.levels {
            self.levels = universe.levels
            self.levelsPacket.replacingComposedDMPValues(with: universe.levels)
            dirty = true
        }

        if self.priorities != universe.priorities {
            self.priorities = universe.priorities
            if let priorities = priorities {
                self.prioritiesPacket.replacingComposedDMPValues(with: priorities)
            }
            dirty = true
            if isSourceActive {
                dirtyPriority = true
            }
        }

        if isSourceActive && dirty {
            dirtyCounter = 3
        }
    }

    /// Updates an existing universe with levels.
    ///
    ///  - Parameters:
    ///     - levels: The new levels (512).
    ///     - isSourceActive: Whether the source is active.
    ///
    ///  - Throws: An error of type `sACNSourceValidationError`.
    ///
    func update(levels: [UInt8], sourceActive isSourceActive: Bool) throws {
        guard levels.count == 512 else {
            throw sACNSourceValidationError.incorrectLevelsCount
        }

        if self.levels != levels {
            self.levels = levels
            self.levelsPacket.replacingComposedDMPValues(with: levels)
            if isSourceActive {
                dirtyCounter = 3
            }
        }
    }

    /// Updates an existing universe with per-slot priorities.
    ///
    ///  - Parameters:
    ///     - priorities: The new per-slot priorities (512).
    ///     - isSourceActive: Whether the source is active.
    ///
    ///  - Throws: An error of type `sACNSourceValidationError`.
    ///
    func update(priorities: [UInt8]?, sourceActive isSourceActive: Bool) throws {
        if let priorities {
            guard priorities.count == 512 else {
                throw sACNSourceValidationError.incorrectPrioritiesCount
            }
        }

        if self.priorities != priorities {
            self.priorities = priorities
            self.prioritiesPacket.replacingComposedDMPValues(with: priorities ?? Array(repeating: 0, count: 512))
            if isSourceActive {
                dirtyPriority = true
                dirtyCounter = 3
            }
        }

    }

    /// Updates an existing universe with new priorities and values.
    ///
    ///  - parameters:
    ///     - slot: The slot to update.
    ///     - level: The level for this slot.
    ///     - priority: Optional: An optional per-slot priority for this slot.
    ///     - isSourceActive: Whether the source is active.
    ///
    ///  - Throws: An error of type `sACNSourceValidationError`.
    ///
    func update(slot: Int, level: UInt8, priority: UInt8? = nil, sourceActive isSourceActive: Bool) throws {
        guard slot < 512 else {
            throw sACNSourceValidationError.invalidSlotNumber
        }
        if let priority = priority {
            guard priority.validPriority() else {
                throw sACNSourceValidationError.invalidPriorities
            }
        }

        var dirty: Bool = false

        if self.levels[slot] != level {
            self.levels[slot] = level
            self.levelsPacket.replacingComposedDMPValue(level, at: slot)
            dirty = true
        }

        if let priorities = self.priorities, let priority = priority, priorities[slot] != priority {
            self.priorities?[slot] = priority
            self.prioritiesPacket.replacingComposedDMPValue(priority, at: slot)
            dirty = true
            if isSourceActive {
                dirtyPriority = true
            }
        }

        if isSourceActive && dirty {
            dirtyCounter = 3
        }
    }

    /// Updates an existing universe with new priorities.
    ///
    ///  - parameters:
    ///     - slot: The slot to update.
    ///     - priority: The per-slot priority for this slot.
    ///     - isSourceActive: Whether the source is active.
    ///
    ///  - Throws: An error of type `sACNSourceValidationError`.
    ///
    func update(slot: Int, priority: UInt8, sourceActive isSourceActive: Bool) throws {
        guard slot < 512 else {
            throw sACNSourceValidationError.invalidSlotNumber
        }
        guard priority.validPriority() else {
            throw sACNSourceValidationError.invalidPriorities
        }

        if let priorities = self.priorities, priorities[slot] != priority {
            self.priorities?[slot] = priority
            self.prioritiesPacket.replacingComposedDMPValue(priority, at: slot)
            if isSourceActive {
                dirtyPriority = true
                dirtyCounter = 3
            }
        }
    }

    /// Updates the framing layer data for this universe.
    ///
    ///  - parameters:
    ///     - sourcePriority: The priority for the source containing this universe.
    ///     - nameData: The name data for the source.
    ///
    func updateFramingLayer(withSourcePriority sourcePriority: UInt8, nameData: Data) {
        let framingLayer = DataFramingLayer.createAsData(nameData: nameData, priority: self.priority ?? sourcePriority, universe: number)
        levelsPacket.replacingComposedFraming(with: framingLayer)
        prioritiesPacket.replacingComposedFraming(with: framingLayer)
    }

    /// Stamps the sequence and options into the levels packet in place, ready for transmission.
    ///
    ///  - parameters:
    ///     - sequence: The sequence number to stamp.
    ///     - options: The framing options to stamp.
    ///
    func stampLevels(sequence: UInt8, options: DataFramingLayer.Options) {
        stamp(&levelsPacket, sequence: sequence, options: options)
    }

    /// Stamps the sequence and options into the priorities packet in place, ready for transmission.
    ///
    ///  - parameters:
    ///     - sequence: The sequence number to stamp.
    ///     - options: The framing options to stamp.
    ///
    func stampPriorities(sequence: UInt8, options: DataFramingLayer.Options) {
        stamp(&prioritiesPacket, sequence: sequence, options: options)
    }

    /// Stamps the sequence and options into a composed packet in place.
    ///
    /// Both fields are always written together (never conditionally) so a stale option bit - e.g. a
    /// `terminated` flag from a prior frame - can never leak into a later packet.
    ///
    private func stamp(_ packet: inout Data, sequence: UInt8, options: DataFramingLayer.Options) {
        packet.replacingComposedSequence(with: sequence)
        packet.replacingComposedOptions(with: options)
    }

    /// A copy of the current levels packet with the `terminated` option forced on.
    ///
    /// Used on the socket-termination path, where a terminated variant is needed alongside the normal
    /// packet in the same frame. Callers should stamp the levels packet first so the copy carries the
    /// correct sequence number.
    ///
    ///  - Returns: A terminated copy of the levels packet.
    ///
    func terminatedLevelsPacket() -> Data {
        var packet = levelsPacket
        packet.addingComposedOptions([.terminated])
        return packet
    }

    /// Increments the sequence number for this universe.
    func incrementSequence() {
        sequence &+= 1
    }

    /// Advances the keep-alive tick counters for this universe (called once per transmit tick).
    func incrementKeepAliveCounters() {
        ticksSinceLevels += 1
        ticksSincePriorities += 1
    }

    /// Resets the levels keep-alive counter (call whenever a NULL start-code packet is sent).
    func resetLevelsKeepAlive() {
        ticksSinceLevels = 0
    }

    /// Decrements the dirty messages counter for this universe.
    func decrementDirty() {
        if dirtyCounter > 0 {
            dirtyCounter -= 1
        }
    }

    /// When a priority message has been sent, this resets the dirty state and the PAP keep-alive counter.
    func prioritySent() {
        dirtyPriority = false
        ticksSincePriorities = 0
    }

    /// Terminates transmission of this universe.
    ///
    /// `remove` is **sticky**: once a universe has been marked for removal (e.g. by `removeUniverse`), a
    /// later `terminate(remove: false)` - as `stop()` issues for every universe - must not downgrade it
    /// back to keep, or the universe would survive the drain and reappear after a restart. Cleared by
    /// `reset()`.
    ///
    /// - Parameters:
    ///    - remove: Whether this universe should be removed after termination.
    ///
    func terminate(remove: Bool) {
        self.shouldTerminate = true
        if remove {
            self.removeAfterTerminate = true
        }
        self.dirtyCounter = 3
    }

    /// Terminates transmission of this universe for some sockets.
    func terminateSockets() {
        self.pendingSocketRemoval = true
        self.dirtyCounter = 3
    }

    /// Termination of transmission for sockets is complete.
    func terminateSocketsComplete() {
        self.pendingSocketRemoval = false
    }

    static func == (lhs: SourceUniverse, rhs: SourceUniverse) -> Bool {
        return lhs.number == rhs.number
    }

}

/// Composed-Packet Data Extension
///
/// In-place writers for fields within a full, pre-composed data packet (root + framing + DMP). Each
/// field's absolute offset is the root-layer length plus its layer-relative `Offset`, so the layer
/// `Offset` enums remain the single source of truth. These must only be used on a zero-based composed
/// packet - never on a standalone layer or a slice, where the offsets would be wrong. They are distinct
/// from the layer-relative replacers (e.g. `replacingSequence`) precisely to avoid that mix-up.
///
private extension Data {

    /// The offset of the framing layer within a composed packet (the root-layer length).
    static let composedFramingBase = RootLayer.Offset.data.rawValue

    /// The offset of the DMP layer within a composed packet.
    static let composedDMPBase = composedFramingBase + DataFramingLayer.Offset.data.rawValue

    /// Replaces the framing-layer sequence number.
    mutating func replacingComposedSequence(with sequence: UInt8) {
        self[Data.composedFramingBase + DataFramingLayer.Offset.sequenceNumber.rawValue] = sequence
    }

    /// Replaces the framing-layer options.
    mutating func replacingComposedOptions(with options: DataFramingLayer.Options) {
        self[Data.composedFramingBase + DataFramingLayer.Offset.options.rawValue] = options.rawValue
    }

    /// Sets additional framing-layer option bits, preserving any already set.
    mutating func addingComposedOptions(_ options: DataFramingLayer.Options) {
        self[Data.composedFramingBase + DataFramingLayer.Offset.options.rawValue] |= options.rawValue
    }

    /// Replaces the framing-layer priority.
    mutating func replacingComposedPriority(with priority: UInt8) {
        self[Data.composedFramingBase + DataFramingLayer.Offset.priority.rawValue] = priority
    }

    /// Replaces the DMP-layer property values (levels or per-address priorities).
    mutating func replacingComposedDMPValues(with values: [UInt8]) {
        let start = Data.composedDMPBase + DMPLayer.Offset.propertyValues.rawValue + 1
        self.replaceSubrange(start..<start + values.count, with: values)
    }

    /// Replaces a single DMP-layer property value at a slot offset.
    mutating func replacingComposedDMPValue(_ value: UInt8, at offset: Int) {
        self[Data.composedDMPBase + DMPLayer.Offset.propertyValues.rawValue + offset + 1] = value
    }

    /// Replaces the entire framing layer, leaving the root and DMP regions intact.
    mutating func replacingComposedFraming(with framing: Data) {
        self.replaceSubrange(Data.composedFramingBase..<Data.composedDMPBase, with: framing)
    }

}

/// UInt16 Extension
///
/// Universe Extensions to `UInt16`.
extension UInt16 {
    /// The minimum permitted value for universe.
    static let minUniverse: UInt16 = 1

    /// The maximum permitted value for universe.
    static let maxUniverse: UInt16 = 63999

    /// The range of valid universes.
    static let validUniverses: ClosedRange<UInt16> = minUniverse...maxUniverse

    /// Determines whether this universe is valid.
    ///
    /// - Returns: Whether this universe is valid.
    ///
    func validUniverse() -> Bool {
        return UInt16.minUniverse...UInt16.maxUniverse ~= self
    }

    /// Calculates the nearest valid universe to the one specified.
    ///
    /// - Returns: A valid universe nearest to the value specified.
    ///
    func nearestValidUniverse() -> UInt16 {
        self < Self.minUniverse ? Self.minUniverse : self > Self.maxUniverse ? Self.maxUniverse : self
    }
}
