//
//  DataFramingLayer.swift
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

/// Data Framing Layer
///
/// Implements the Data Framing Layer and handles creation and parsing.
///
struct DataFramingLayer {
    
    /// The flags and length. 0x7258: 258 = 600 (starting octet 38) = 638.
    private static let flagsAndLength = Data([0x72, 0x58])

    /// Data Framing Layer Vectors
    ///
    /// Enumerates the supported Vectors for this layer.
    ///
    enum Vector: UInt32 {
        /// Contains a  `DMPLayer`.
        case data = 0x00000002
    }
    
    /// Data Framing Layer Data Offsets
    ///
    /// Enumerates the data offset for each field in this layer.
    ///
    enum Offset: Int {
        case flagsAndLength = 0
        case vector = 2
        case sourceName = 6
        case priority = 70
        case syncAddress = 71
        case sequenceNumber = 73
        case options = 74
        case universe = 75
        case data = 77
    }
    
    /// The options.
    struct Options: OptionSet {
        let rawValue: UInt8

        static let preview = Options(rawValue: 1 << 7)
        static let terminated = Options(rawValue: 1 << 6)
        static let forceSync = Options(rawValue: 1 << 5)
        
        static let none: Options = []
    }
    
    /// The vector describing the data in the layer.
    private var vector: Vector
    
    /// A name for this source, such as a user specified human-readable string, or serial number for the device.
    var sourceName: String
    
    /// The priority of this source.
    var priority: UInt8
    
    /// The sequence number for this message.
    var sequenceNumber: UInt8
    
    /// The options for this message.
    var options: Options
    
    /// The unvierse number for this message.
    var universe: UInt16
    
    /// The data contained in the layer.
    private var data: Data
    
    /// Creates a Framing Layer as Data.
    ///
    /// - Parameters:
    ///    - nameData: The name of this Source as `Data`.
    ///    - priority: The priority for this Source.
    ///    - universe: The universe for this message.
    ///
    /// - Returns: A `DataFramingLayer` as a `Data` object.
    ///
    static func createAsData(nameData: Data, priority: UInt8, universe: UInt16) -> Data {
        var data = Data()
        data.append(contentsOf: DataFramingLayer.flagsAndLength)
        data.append(Vector.data.rawValue.data)
        data.append(nameData)
        data.append(priority.data)
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        data.append(universe.data)
        return data
    }
    
    /// Attempts to create a Data Framing Layer from the data.
    ///
    /// - Parameters:
    ///    - data: The data to be parsed.
    ///
    /// - Throws: An error of type `DataFramingLayerValidationError`
    ///
    /// - Returns: A valid `DataFramingLayer`.
    ///
    static func parse(fromData data: Data) throws -> Self {
        guard data.count > Offset.data.rawValue else { throw DataFramingLayerValidationError.lengthOutOfRange }
        
        // the flags and length
        guard data[Offset.flagsAndLength.rawValue..<Offset.vector.rawValue] == Self.flagsAndLength else {
            throw DataFramingLayerValidationError.invalidFlagsAndLength
        }
        // the vector for this layer
        guard let vector: UInt32 = data.toUInt32(atOffset: Offset.vector.rawValue) else {
            throw DataFramingLayerValidationError.unableToParse(field: "Vector")
        }
        guard let validVector = Vector.init(rawValue: vector) else {
            throw DataFramingLayerValidationError.invalidVector(vector)
        }
        // the name of this source
        guard let sourceName: String = data.toString(ofLength: Source.sourceNameMaxBytes, atOffset: Offset.sourceName.rawValue) else {
            throw DataFramingLayerValidationError.unableToParse(field: "Source Name")
        }
        // the priority of this source
        guard let priority: UInt8 = data.toUInt8(atOffset: Offset.priority.rawValue) else {
            throw DataFramingLayerValidationError.unableToParse(field: "Priority")
        }
        guard UInt8.validPriorities.contains(priority) else {
            throw DataFramingLayerValidationError.invalidPriority(priority)
        }
        // reserved
        // ignore
        // the sequence number
        guard let sequenceNumber: UInt8 = data.toUInt8(atOffset: Offset.sequenceNumber.rawValue) else {
            throw DataFramingLayerValidationError.unableToParse(field: "Sequence Number")
        }
        // options
        guard let options = data.toUInt8(atOffset: Offset.options.rawValue) else {
            throw DataFramingLayerValidationError.unableToParse(field: "Options")
        }
        // the universe number
        guard let universe: UInt16 = data.toUInt16(atOffset: Offset.universe.rawValue) else {
            throw DataFramingLayerValidationError.unableToParse(field: "Universe Number")
        }
        guard Universe.dataUniverseNumbers.contains(universe) else {
            throw DataFramingLayerValidationError.invalidUniverse(universe)
        }

        // layer data
        let data = data.subdata(in: Offset.data.rawValue..<data.count)
        
        return Self(vector: validVector, sourceName: sourceName, priority: priority, sequenceNumber: sequenceNumber, options: Options(rawValue: options), universe: universe, data: data)
    }
    
}

/// Data Framing Layer Data Extension
///
/// Extensions for modifying fields within an existing `DataFramingLayer` stored as `Data`.
///
internal extension Data {
    /// Replaces the `DataFramingLayer` sequence.
    ///
    /// - Parameters:
    ///    - sequence: The sequence to be replaced in the layer.
    ///
    mutating func replacingSequence(with sequence: UInt8) {
        self[DataFramingLayer.Offset.sequenceNumber.rawValue] = sequence
    }
    
    /// Replaces the `DataFramingLayer` options.
    ///
    /// - Parameters:
    ///    - options: The options to be replaced in the layer.
    ///
    mutating func replacingOptions(with options: DataFramingLayer.Options) {
        self[DataFramingLayer.Offset.options.rawValue] = options.rawValue
    }
    
    /// Replaces the `DataFramingLayer` options.
    ///
    /// - Parameters:
    ///    - priority: The options to be replaced in the layer.
    ///
    mutating func replacingPriority(with priority: UInt8) {
        self[DataFramingLayer.Offset.priority.rawValue] = priority
    }
}

/// Data Framing Layer Validation Error
///
/// Enumerates all possible `DataFramingLayer` parsing errors.
///
enum DataFramingLayerValidationError: LocalizedError {
    
    /// The data is of insufficient length.
    case lengthOutOfRange
    
    /// The flags and length does not match that specified for E1.31.
    case invalidFlagsAndLength
    
    /// The `Vector` is not recognized.
    case invalidVector(_ vector: UInt32)
    
    /// The priority is not recognized.
    case invalidPriority(_ priority: UInt8)
    
    /// The universe is not recognized.
    case invalidUniverse(_ universe: UInt16)
    
    /// A field could not be parsed from the data.
    case unableToParse(field: String)

    /// A human-readable description of the error useful for logging purposes.
    var logDescription: String {
        switch self {
        case .lengthOutOfRange:
            return "Invalid Length for Data Framing Layer."
        case .invalidFlagsAndLength:
            return "Invalid Flags & Length in Data Framing Layer."
        case let .invalidVector(vector):
            return "Invalid Vector \(vector) in Data Framing Layer."
        case let .invalidPriority(priority):
            return "Invalid Priority \(priority) in Data Framing Layer."
        case let .invalidUniverse(universe):
            return "Invalid Universe \(universe) in Data Framing Layer."
        case let .unableToParse(field):
            return "Unable to parse \(field) in Data Framing Layer."
        }
    }
        
}

