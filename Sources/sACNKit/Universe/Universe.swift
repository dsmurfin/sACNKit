//
//  Universe.swift
//
//  Copyright (c) 2022 Daniel Murfin
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
import SwiftUI

/// sACN Universe
///
/// An sACN universes contains level and priority information.
///
public struct sACNUniverse: Equatable {
    
    /// The universe number.
    public private (set) var number: UInt16
    
    /// The per-packet priority.
    public private (set) var priority: UInt8?
    
    /// The level data (512).
    public private (set) var levels: [UInt8]
    
    /// The priority (per-slot) data (512).
    public private (set) var priorities: [UInt8]?
    
    /// Whether this universe uses per-slot priority.
    public var usesPerSlotPriority: Bool {
        return priorities != nil
    }
    
    /// Initializes a universe with an optional per-packet priority and an array of levels.
    /// If less than 512 levels are provided levels will be padded to 512.
    /// If more than 512 levels are provided, levels will be truncated to 512.
    ///
    ///  - Parameters:
    ///     - number: The universe number (values permitted 1-63999)
    ///     - priority: Optional: An optional priority (values permitted 0-200).
    ///     - levels: An array of levels.
    ///     - priorities: Optional: An optional array of priorities.
    ///
    public init(number: UInt16, priority: UInt8? = nil, levels: [UInt8], priorities: [UInt8]? = nil) {
        self.number = number.nearestValidUniverse()
        self.priority = priority?.nearestValidPriority()
        
        // truncate, then pad levels
        var validLevels = levels.prefix(512)
        for _ in validLevels.count..<512 {
            validLevels.append(0)
        }
        self.levels = Array(validLevels)
        
        // truncate, then pad slot priorities
        if let priorities = priorities {
            var validPriorities = priorities.prefix(512)
            for _ in validPriorities.count..<512 {
                validPriorities.append(UInt8.min)
            }
            self.priorities = validPriorities.map { $0.validPriority() ? $0 : UInt8.defaultPriority }
        }
    }
    
    public static func ==(lhs: sACNUniverse, rhs: sACNUniverse) -> Bool {
        return lhs.number == rhs.number
    }
    
}

/// Universe
///
/// A universes contains level and priority information.
///
class Universe: Equatable {
    
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
    
    /// The framing layer.
    private (set) var framingLayer: Data
    
    /// The dmp levels layer.
    private (set) var dmpLevelsLayer: Data
    
    /// The dmp levels layer.
    private (set) var dmpPrioritiesLayer: Data
    
    /// The last transmitted sequence number for this universe.
    private (set) var sequence: UInt8
    
    /// The data transmit timer counter (0...43 @ 44fps)
    private (set) var transmitCounter: Int
    
    /// The number of non-changing messages that have been sent (starts at 3 when levels have changed).
    private (set) var dirtyCounter: Int
    
    /// Whether this universe should immediately send a priority message.
    private (set) var dirtyPriority: Bool
    
    /// Whether this universe should be terminated.
    private (set) var shouldTerminate: Bool
    
    /// Whether the universe should be removed after termination.
    private (set) var removeAfterTerminate: Bool
    
    /// Initializes a universe with a public `sACNUniverse`.
    ///
    ///  - parameters:
    ///     - universe: A public `sACNUniverse`.
    ///     - sourcePriority: The priority for the source containing this universe.
    ///     - nameData: The name data for the source.
    ///
    init(with universe: sACNUniverse, sourcePriority: UInt8, nameData: Data) {
        self.number = universe.number
        self.priority = universe.priority
        self.levels = universe.levels
        self.priorities = universe.priorities
        self.framingLayer = DataFramingLayer.createAsData(nameData: nameData, priority: self.priority ?? sourcePriority, universe: universe.number)
        self.dmpLevelsLayer = DMPLayer.createAsData(startCode: .null, values: universe.levels)
        self.dmpPrioritiesLayer = DMPLayer.createAsData(startCode: .perAddressPriority, values: universe.priorities ?? Array(repeating: 0, count: 512))
        self.sequence = 0
        self.transmitCounter = 0
        self.dirtyCounter = 3
        self.dirtyPriority = true
        self.shouldTerminate = false
        self.removeAfterTerminate = false
    }
    
    /// Resets this universe for new transmission.
    func reset() {
        self.transmitCounter = 0
        self.dirtyCounter = 3
        self.dirtyPriority = true
        self.shouldTerminate = false
        self.removeAfterTerminate = false
    }
    
    /// Updates an existing universe with new priorities and values from an `sACNUniverse`.
    ///
    ///  - parameters:
    ///     - universe: A public `sACNUniverse`.
    ///
    ///  - Throws: An error of type `sACNSourceValidationError`.
    ///
    func update(with universe: sACNUniverse) throws {
        guard universe.levels.count == 512 else {
            throw sACNSourceValidationError.incorrectLevelsCount
        }
        if let priorities = universe.priorities {
            guard priorities.count == 512 else {
                throw sACNSourceValidationError.incorrectPrioritiesCount
            }
            guard priorities.allSatisfy ({ $0.validPriority() }) else {
                throw sACNSourceValidationError.invalidPriorities
            }
        }
        
        var dirty: Bool = false
        
        if self.priority != universe.priority {
            self.priority = universe.priority
            dirty = true
        }
        
        if self.levels != universe.levels {
            self.levels = universe.levels
            self.dmpLevelsLayer.replacingDMPLayerValues(with: universe.levels)
            dirty = true
        }
        
        if self.priorities != universe.priorities {
            self.priorities = universe.priorities
            if let priorities = priorities {
                self.dmpPrioritiesLayer.replacingDMPLayerValues(with: priorities)
            }
            dirty = true
            dirtyPriority = true
        }
        
        if dirty {
            dirtyCounter = 3
        }
    }
    
    /// Updates an existing universe with new priorities and values.
    ///
    ///  - parameters:
    ///     - slot: The slot to update.
    ///     - level: The level for this slot.
    ///     - priority: Optional: An optional per-slot priority for this slot.
    ///
    ///  - Throws: An error of type `sACNSourceValidationError`.
    ///
    func update(slot: Int, level: UInt8, priority: UInt8? = nil) throws {
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
            self.dmpLevelsLayer.replacingDMPLayerValue(level, at: slot)
            dirty = true
        }
        
        if var priorities = self.priorities, let priority = priority, priorities[slot] != priority {
            priorities[slot] = priority
            self.dmpLevelsLayer.replacingDMPLayerValue(priority, at: slot)
            dirty = true
            dirtyPriority = true
        }
        
        if dirty {
            dirtyCounter = 3
        }
    }
    
    /// Updates the framing layer data for this universe.
    ///
    ///  - parameters:
    ///     - sourcePriority: The priority for the source containing this universe.
    ///     - nameData: The name data for the source.
    ///
    func updateFramingLayer(withSourcePriority sourcePriority: UInt8, nameData: Data) {
        framingLayer = DataFramingLayer.createAsData(nameData: nameData, priority: self.priority ?? sourcePriority, universe: number)
    }
    
    /// Increments the sequence number for this universe.
    func incrementSequence() {
        sequence &+= 1
    }
    
    /// Increments the counter for this universe.
    func incrementCounter() {
        if transmitCounter > 42 {
            self.transmitCounter = 0
        } else {
            self.transmitCounter += 1
        }
    }
    
    /// Decrements the dirty messages counter for this universe.
    func decrementDirty() {
        if dirtyCounter > 0 {
            dirtyCounter -= 1
        }
    }
    
    /// When a priority message has been sent, this resets the dirty state.
    func prioritySent() {
        dirtyPriority = false
    }
    
    /// Terminates transmission of this universe.
    ///
    /// - parameters:
    ///     - remove: Whether this universe should be removed after termination.
    ///
    func terminate(remove: Bool) {
        self.shouldTerminate = true
        self.removeAfterTerminate = remove
        self.dirtyCounter = 3
    }
    
    static func ==(lhs: Universe, rhs: Universe) -> Bool {
        return lhs.number == rhs.number
    }
    
}

/// UInt16 Extension
///
/// Universe Extensions to `UInt16`.
///
internal extension UInt16 {
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
