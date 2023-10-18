//
//  sACNSourceUniverse.swift
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

/// sACN Source Universe
///
/// An sACN universes contains level and priority information.
public struct sACNSourceUniverse {
    
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
        var validLevels = levels.prefix(DMX.addressCount)
        for _ in validLevels.count..<DMX.addressCount {
            validLevels.append(0)
        }
        self.levels = Array(validLevels)
        
        // truncate, then pad slot priorities
        if let priorities = priorities {
            var validPriorities = priorities.prefix(DMX.addressCount)
            for _ in validPriorities.count..<DMX.addressCount {
                validPriorities.append(UInt8.min)
            }
            self.priorities = validPriorities.map { $0.validPriority() ? $0 : UInt8.defaultPriority }
        }
    }
    
    /// Updates the per-packet priority.
    ///
    /// - Parameters:
    ///    - priority: The new per-packet priority.
    ///
    public mutating func updatePriority(_ priority: UInt8) {
        self.priority = priority.nearestValidPriority()
    }
    
    /// Updates all levels.
    ///
    /// If less than 512 levels are provided levels will be padded with zeros to 512.
    /// If more than 512 levels are provided, levels will be truncated to 512.
    ///
    /// - Parameters:
    ///    - levels: The new levels.
    ///
    public mutating func updateLevels(levels: [UInt8]) {
        var validLevels = levels.prefix(DMX.addressCount)
        for _ in validLevels.count..<DMX.addressCount {
            validLevels.append(0)
        }
        self.levels = Array(validLevels)
    }
    
    /// Updates all levels with a complete set of 512 new levels.
    ///
    /// - Parameters:
    ///    - levels: The new levels (512).
    ///
    /// - Precondition: A complete set of 512 levels must be provided.
    ///
    public mutating func updateLevelsComplete(levels: [UInt8]) {
        precondition(levels.count == DMX.addressCount, "A set of 512 levels must be provided.")
        self.levels = levels
    }
    
    /// Updates all priorities.
    ///
    /// If less than 512 priorities (per-slot) are provided priorities will be padded with defaults to 512.
    ///
    /// - Parameters:
    ///    - priorities: The new priorities (per-slot).
    ///
    public mutating func updatePriorities(priorities: [UInt8]) {
        var validPriorities = priorities.prefix(DMX.addressCount)
        for _ in validPriorities.count..<DMX.addressCount {
            validPriorities.append(UInt8.min)
        }
        self.priorities = validPriorities.map { $0.validPriority() ? $0 : UInt8.defaultPriority }
    }
    
    /// Updates all priorities (per-slot) with a complete set of 512 new priorities.
    ///
    /// - Parameters:
    ///    - priorities: The new priorities (per-slot) (512).
    ///
    /// - Precondition: A complete set of 512 levels must be provided.
    ///
    public mutating func updatePrioritiesComplete(priorities: [UInt8]) {
        precondition(priorities.count == DMX.addressCount, "A complete set of 512 priorities must be provided.")
        self.priorities = priorities
    }
    
}

/// sACN Source Universe Extension
///
/// Equatable conformance.
extension sACNSourceUniverse: Equatable {
    public static func ==(lhs: sACNSourceUniverse, rhs: sACNSourceUniverse) -> Bool {
        return lhs.number == rhs.number
    }
}
