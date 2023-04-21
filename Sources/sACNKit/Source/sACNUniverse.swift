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
public struct sACNSourceUniverse: Equatable {
    
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
    
    public static func ==(lhs: sACNSourceUniverse, rhs: sACNSourceUniverse) -> Bool {
        return lhs.number == rhs.number
    }
    
}
