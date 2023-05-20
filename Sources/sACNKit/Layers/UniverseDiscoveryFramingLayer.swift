//
//  UniverseDiscoveryFramingLayer.swift
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

/// Universe Discovery Framing Layer
///
/// Implements the Universe Discovery Framing Layer and handles creation and parsing.
struct UniverseDiscoveryFramingLayer {

    /// Universe Discovery Layer Vectors
    ///
    /// Enumerates the supported Vectors for this layer.
    ///
    enum Vector: UInt32 {
        /// Contains a  `ExtendedDiscoveryLayer`.
        case extendedDiscovery = 0x00000002
    }
    
    /// Universe Discovery Layer Data Offsets
    ///
    /// Enumerates the data offset for each field in this layer.
    ///
    enum Offset: Int {
        case flagsAndLength = 0
        case vector = 2
        case sourceName = 6
        case reserved = 70
        case data = 74
    }
    
    /// The vector describing the data in the layer.
    private (set) var vector: Vector
    
    /// A name for this source, such as a user specified human-readable string, or serial number for the device.
    private (set) var sourceName: String
    
    /// The data contained in the layer.
    private (set) var data: Data
    
    /// Creates a Framing Layer as Data.
    ///
    /// - Parameters:
    ///    - nameData: The name of this Source as `Data`.
    ///
    /// - Returns: A `UniverseDiscoveryFramingLayer` as a `Data` object.
    ///
    static func createAsData(nameData: Data) -> Data {
        var data = Data()
        data.append(contentsOf: [0x00, 0x00])
        data.append(Vector.extendedDiscovery.rawValue.data)
        data.append(nameData)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        return data
    }
    
    /// Attempts to create a Universe Discovery Framing Layer from the data.
    ///
    /// - Parameters:
    ///    - data: The data to be parsed.
    ///
    /// - Throws: An error of type `UniverseDiscoveryLayerValidationError`
    ///
    /// - Returns: A valid `UniverseDiscoveryFramingLayer`.
    ///
    static func parse(fromData data: Data) throws -> Self {
        guard data.count > Offset.data.rawValue else { throw UniverseDiscoveryFramingLayerValidationError.lengthOutOfRange }
        
        // the flags and length
        guard let flagsAndLength = data.toFlagsAndLength(atOffset: Offset.flagsAndLength.rawValue), flagsAndLength.length == data.count-Offset.flagsAndLength.rawValue else {
            throw UniverseDiscoveryFramingLayerValidationError.invalidFlagsAndLength
        }
        // the vector for this layer
        guard let vector: UInt32 = data.toUInt32(atOffset: Offset.vector.rawValue) else {
            throw UniverseDiscoveryFramingLayerValidationError.unableToParse(field: "Vector")
        }
        guard let validVector = Vector.init(rawValue: vector) else {
            throw UniverseDiscoveryFramingLayerValidationError.invalidVector(vector)
        }
        
        // the name of this source
        guard let sourceName: String = data.toString(ofLength: Source.sourceNameMaxBytes, atOffset: Offset.sourceName.rawValue) else {
            throw UniverseDiscoveryFramingLayerValidationError.unableToParse(field: "Source Name")
        }
        // reserved
        // ignore

        // layer data
        let data = data.subdata(in: Offset.data.rawValue..<data.count)
        
        return Self(vector: validVector, sourceName: sourceName, data: data)
    }
    
}

/// Universe Discovery Framing Layer Data Extension
///
/// Extensions for modifying fields within an existing `UniverseDiscoveryFramingLayer` stored as `Data`.
///
internal extension Data {
    /// Replaces the `UniverseDiscoveryFramingLayer` Flags and Length.
    ///
    /// - Parameters:
    ///    - length: The length to be replaced in the layer.
    ///
    mutating func replacingUniverseDiscoveryFramingFlagsAndLength(with length: UInt16) {
        let flagsAndLength = FlagsAndLength.fromLength(length)
        self.replaceSubrange(UniverseDiscoveryFramingLayer.Offset.flagsAndLength.rawValue...UniverseDiscoveryFramingLayer.Offset.flagsAndLength.rawValue+1, with: flagsAndLength.data)
    }
}

/// Universe Discovery Framing Layer Validation Error
///
/// Enumerates all possible `UniverseDiscoveryFramingLayer` parsing errors.
///
enum UniverseDiscoveryFramingLayerValidationError: LocalizedError {
    
    /// The data is of insufficient length.
    case lengthOutOfRange
    
    /// The flags and length does not match that specified for E1.31.
    case invalidFlagsAndLength
    
    /// The `Vector` is not recognized.
    case invalidVector(_ vector: UInt32)
    
    /// A field could not be parsed from the data.
    case unableToParse(field: String)

    /// A human-readable description of the error useful for logging purposes.
    var logDescription: String {
        switch self {
        case .lengthOutOfRange:
            return "Invalid Length for Universe Discovery Framing Layer."
        case .invalidFlagsAndLength:
            return "Invalid Flags & Length in Universe Discovery Framing Layer."
        case let .invalidVector(vector):
            return "Invalid Vector \(vector) in Universe Discovery Framing Layer."
        case let .unableToParse(field):
            return "Unable to parse \(field) in Universe Discovery Framing Layer."
        }
    }
        
}

