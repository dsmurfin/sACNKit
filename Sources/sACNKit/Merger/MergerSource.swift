//
//  MergerSource.swift
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

/// Merger Source
///
class MergerSource {
    
    /// The unique identifer for this merger source.
    var id: UUID
    
    /// The (512) DMX512-A NULL start code (0x00) levels.
    var levels: [UInt8]
    
    /// The number of levels being used.
    ///
    /// Some sources don't use all 512 levels, so this tells us how many levels
    /// in `levels` to use.
    var levelCount: Int
    
    /// The sACN universe priority.
    var universePriority: UInt8

    /// The sACN per-address start code (0xdd) priorities (0 means not sourced).
    ///
    /// If the source uses universe priority `usingUniversePriority` will be true,
    /// and this contains the universe priority in every slot (used for the merge).
    var addressPriorities: [UInt8]
    
    /// Whether the source is using universe priority.
    var usingUniversePriority: Bool

    var perAddressPriorityCount: Int
    
    var universePriorityUninitialized: Bool
    
    init(id: UUID?) {
        self.id = id ?? UUID()
        self.levels = Array(repeating: 0, count: DMX.addressCount)
        self.levelCount = 0
        self.universePriority = 0
        self.usingUniversePriority = true
        self.addressPriorities = Array(repeating: 0, count: DMX.addressCount)
        self.perAddressPriorityCount = 0
        self.universePriorityUninitialized = true
    }
    
}
