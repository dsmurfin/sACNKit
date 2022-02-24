//
//  DMPLayer.swift
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

/// DMP Layer
///
/// Implements the DMP Layer and handles creation and parsing.
///
struct DMPLayer {
    
    /// The flags and length. 0x720b: 20b = 523 (starting octet 115) = 638
    private static let flagsAndLength = Data([0x72, 0x0b])
    
    /// The address type and data type, first property address (DMX512-A START Code is at DMP address 0), and address increment.
    private static let addressPropertyBlock = Data([0xa1, 0x00, 0x00, 0x00, 0x01])
    
    /// The number of slots in the message (plus the START Code).
    private static let propertyValueCount = Data([0x02, 0x01])

    /// DMP Layer Vectors
    ///
    /// Enumerates the supported Vectors for this layer.
    ///
    enum Vector: UInt8 {
        /// Contains a Set Property message.
        case setProperty = 0x02
    }
    
    /// DMP Layer Data Offsets
    ///
    /// Enumerates the data offset for each field in this layer.
    ///
    enum Offset: Int {
        case flagsAndLength = 0
        case vector = 2
        case addressTypeDataType = 3
        case firstPropertyAddress = 4
        case addressIncrement = 6
        case propertyValueCount = 8
        case propertyValues = 10
    }
    
    /// DMP Layer DMX512-A START Codes
    ///
    /// Enumerates the data offset for each field in this layer.
    ///
    enum STARTCode: UInt8 {
        /// Contains dmx level data.
        case null = 0x00
        /// Contains per-slot priority data.
        case perAddressPriority = 0xdd
    }
    
    /// The start code for this message.
    var startCode: STARTCode
    
    /// The values for this message.
    var values: [UInt8]
    
    /// Creates a DMP Layer as Data.
    ///
    /// - Parameters:
    ///    - startCode: The Start Code for this message.
    ///    - values: An array of values to be included.
    ///
    /// - Returns: A `DMPLayer` as a `Data` object.
    ///
    static func createAsData(startCode: STARTCode, values: [UInt8]) -> Data {
        var data = Data()
        data.append(contentsOf: DMPLayer.flagsAndLength)
        data.append(Vector.setProperty.rawValue.data)
        data.append(DMPLayer.addressPropertyBlock)
        data.append(DMPLayer.propertyValueCount)
        data.append(startCode.rawValue.data)
        data.append(contentsOf: values)
        return data
    }
    
    /// Attempts to create a DMP Layer from the data.
    ///
    /// - Parameters:
    ///    - data: The data to be parsed.
    ///
    /// - Throws: An error of type `DMPLayerValidationError`
    ///
    /// - Returns: A valid `DMPLayer`.
    ///
    static func parse(fromData data: Data) throws -> Self {
        guard data.count > Offset.propertyValues.rawValue+1 else { throw DMPLayerValidationError.lengthOutOfRange }
        
        // the flags and length
        guard data[Offset.flagsAndLength.rawValue...Offset.vector.rawValue-1] == Self.flagsAndLength else {
            throw DMPLayerValidationError.invalidFlagsAndLength
        }
        // the vector for this layer
        guard let vector: UInt8 = data.toUInt8(atOffset: Offset.vector.rawValue) else {
            throw DMPLayerValidationError.unableToParse(field: "Vector")
        }
        guard let _ = Vector.init(rawValue: vector) else {
            throw DMPLayerValidationError.invalidVector(vector)
        }
        // the address property block
        guard data[Offset.addressTypeDataType.rawValue...Offset.propertyValueCount.rawValue-1] == DMPLayer.addressPropertyBlock else {
            throw DMPLayerValidationError.invalidAddressPropertyBlock
        }
        // the number of property values
        guard let propertyValueCount: UInt16 = data.toUInt16(atOffset: Offset.propertyValueCount.rawValue) else {
            throw DMPLayerValidationError.unableToParse(field: "Property Value Count")
        }
        guard propertyValueCount < 513 else {
            throw DMPLayerValidationError.invalidPropertyValueCount(propertyValueCount)
        }
        // the START Code
        guard let code: UInt8 = data.toUInt8(atOffset: Offset.propertyValues.rawValue), let STARTCode = STARTCode(rawValue: code) else {
            throw DMPLayerValidationError.unableToParse(field: "START Code")
        }
        let propertyValuesOffset = Offset.propertyValues.rawValue+1
        let values = data.subdata(in: propertyValuesOffset..<propertyValuesOffset+Int(propertyValueCount)-1).bytes

        return Self(startCode: STARTCode, values: values)
    }
    
}

/// DMP Layer Data Extension
///
/// Extensions for modifying fields within an existing `DMPLayer` stored as `Data`.
///
internal extension Data {
    /// Replaces the `DMPLayer` values.
    ///
    /// - Parameters:
    ///    - values: The values to be replaced in the layer.
    ///
    mutating func replacingDMPLayerValues(with values: [UInt8]) {
        self.replaceSubrange(DMPLayer.Offset.propertyValues.rawValue+1..<DMPLayer.Offset.propertyValues.rawValue+1+values.count, with: values)
    }
    
    /// Replaces the `DMPLayer` value at a specific offset.
    ///
    /// - Parameters:
    ///    - value: The value to be replaced in the layer.
    ///    - offset: The offset of the value to be replaced.
    ///
    mutating func replacingDMPLayerValue(_ value: UInt8, at offset: Int) {
        self[DMPLayer.Offset.propertyValues.rawValue+offset+1] = value
    }
}

/// DMP Layer Validation Error
///
/// Enumerates all possible `DMPLayer` parsing errors.
///
enum DMPLayerValidationError: LocalizedError {
    
    /// The data is of insufficient length.
    case lengthOutOfRange
    
    /// The flags and length does not match that specified for E1.31.
    case invalidFlagsAndLength
    
    /// The `Vector` is not recognized.
    case invalidVector(_ vector: UInt8)
    
    /// The address propert block does not match that specified for E1.31.
    case invalidAddressPropertyBlock
    
    /// The property value count is not recognized.
    case invalidPropertyValueCount(_ count: UInt16)
    
    /// A field could not be parsed from the data.
    case unableToParse(field: String)

    /// A human-readable description of the error useful for logging purposes.
    var logDescription: String {
        switch self {
        case .lengthOutOfRange:
            return "Invalid Length for DMP Layer."
        case .invalidFlagsAndLength:
            return "Invalid Flags & Length in DMP Layer."
        case let .invalidVector(vector):
            return "Invalid Vector \(vector) in DMP Layer."
        case .invalidAddressPropertyBlock:
            return "Invalid Address Type & Data Type/First Property Address/Address Increment in DMP Layer."
        case let .invalidPropertyValueCount(count):
            return "Invalid Property Value Count \(count) in DMP Layer."
        case let .unableToParse(field):
            return "Unable to parse \(field) in DMP Layer."
        }
    }
        
}

