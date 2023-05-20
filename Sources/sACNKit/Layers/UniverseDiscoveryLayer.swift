//
//  UniverseDiscoveryLayer.swift
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

/// Universe Discovery Layer
///
/// Implements the Universe Discovery Layer and handles creation and parsing.
struct UniverseDiscoveryLayer {
    
    /// The maximum number of universe numbers to include in this layer.
    static let maxUniverseNumbers = 512

    /// Universe Discovery Layer Vectors
    ///
    /// Enumerates the supported Vectors for this layer.
    ///
    enum Vector: UInt32 {
        /// Contains a  `UniverseDiscoveryUniverseList`.
        case discoveryUniverseList = 0x00000001
    }
    
    /// Universe Discovery Layer Data Offsets
    ///
    /// Enumerates the data offset for each field in this layer.
    ///
    enum Offset: Int {
        case flagsAndLength = 0
        case vector = 2
        case page = 6
        case lastPage = 7
        case listOfUniverses = 8
    }
    
    /// The page number.
    var page: UInt8
    
    /// The last page number.
    var lastPage: UInt8
    
    /// A list of universes.
    var universeList: [UInt16]
    
    /// Creates a Universe Discovery Layer as Data.
    ///
    /// - Parameters:
    ///    - page: This page number.
    ///    - lastPage: The last page number.
    ///    - universeList: The universes to include in this message.
    ///
    /// - Returns: A `UniverseDiscoveryLayer` as a `Data` object.
    ///
    static func createAsData(page: UInt8, lastPage: UInt8, universeList: [UInt16]) -> Data {
        var data = Data()
        let flagsAndLength = FlagsAndLength.fromLength(UInt16((universeList.count*2)+Self.Offset.listOfUniverses.rawValue))
        data.append(flagsAndLength.data)
        data.append(Vector.discoveryUniverseList.rawValue.data)
        data.append(page.data)
        data.append(lastPage.data)
        for universe in universeList {
            data.append(universe.data)
        }
        return data
    }
    
    /// Attempts to create a Universe Discovery Layer from the data.
    ///
    /// - Parameters:
    ///    - data: The data to be parsed.
    ///
    /// - Throws: An error of type `UniverseDiscoveryLayerValidationError`
    ///
    /// - Returns: A valid `UniverseDiscoveryLayer`.
    ///
    static func parse(fromData data: Data) throws -> Self {
        guard data.count >= Offset.listOfUniverses.rawValue else { throw UniverseDiscoveryLayerValidationError.lengthOutOfRange }
        
        // the flags and length
        guard let flagsAndLength = data.toFlagsAndLength(atOffset: Offset.flagsAndLength.rawValue), flagsAndLength.length == data.count-Offset.flagsAndLength.rawValue else {
            throw UniverseDiscoveryLayerValidationError.invalidFlagsAndLength
        }        
        // the vector for this layer
        guard let vector: UInt32 = data.toUInt32(atOffset: Offset.vector.rawValue) else {
            throw UniverseDiscoveryLayerValidationError.unableToParse(field: "Vector")
        }
        guard let validVector = Vector.init(rawValue: vector), validVector == .discoveryUniverseList else {
            throw UniverseDiscoveryLayerValidationError.invalidVector(vector)
        }
        // the page
        guard let page: UInt8 = data.toUInt8(atOffset: Offset.page.rawValue) else {
            throw UniverseDiscoveryLayerValidationError.unableToParse(field: "Page")
        }
        // the last page
        guard let lastPage: UInt8 = data.toUInt8(atOffset: Offset.lastPage.rawValue) else {
            throw UniverseDiscoveryLayerValidationError.unableToParse(field: "Last Page")
        }

        // universe numbers data
        let universeNumbersData = data.subdata(in: Offset.listOfUniverses.rawValue..<data.count)
        
        // the remaining data should be a multiple of universe number's size
        guard universeNumbersData.count.isMultiple(of: 2) else { throw UniverseDiscoveryLayerValidationError.invalidUniverseNumbers }
        var universeNumbers = [UInt16]()
        for offset in stride(from: 0, to: universeNumbersData.count, by: 2) {
            guard let universeNumber = universeNumbersData.toUInt16(atOffset: offset) else { continue }
            universeNumbers.append(universeNumber)
        }
        
        return Self(page: page, lastPage: lastPage, universeList: universeNumbers)
    }
    
}

/// Universe Discovery Layer Validation Error
///
/// Enumerates all possible `UniverseDiscoveryLayer` parsing errors.
///
enum UniverseDiscoveryLayerValidationError: LocalizedError {
    
    /// The data is of insufficient length.
    case lengthOutOfRange
    
    /// The flags and length does not match that specified for E1.31.
    case invalidFlagsAndLength
    
    /// The `Vector` is not recognized.
    case invalidVector(_ vector: UInt32)
    
    /// The universe numbers list is invalid.
    case invalidUniverseNumbers
    
    /// A field could not be parsed from the data.
    case unableToParse(field: String)

    /// A human-readable description of the error useful for logging purposes.
    var logDescription: String {
        switch self {
        case .lengthOutOfRange:
            return "Invalid Length for Universe Discovery Layer."
        case .invalidFlagsAndLength:
            return "Invalid Flags & Length in Universe Discovery Layer."
        case let .invalidVector(vector):
            return "Invalid Vector \(vector) in Universe Discovery Layer."
        case .invalidUniverseNumbers:
            return "Invalid List of Universes in Universe Discovery Layer."
        case let .unableToParse(field):
            return "Unable to parse \(field) in Universe Discovery Layer."
        }
    }
        
}
