import Foundation
import Testing

@testable import sACNKit

/// Characterizes build -> parse round-trips and malformed-input handling for the E1.31 wire layers.
@Suite("Wire-format layers")
struct LayerTests {

    // MARK: - DMPLayer

    @Test("DMPLayer round-trips a null start-code packet")
    func dmpNullRoundTrip() throws {
        let values: [UInt8] = (0..<512).map { UInt8($0 % 256) }
        let data = DMPLayer.createAsData(startCode: .null, values: values)
        let parsed = try DMPLayer.parse(fromData: data)
        #expect(parsed.startCode == .null)
        #expect(parsed.values == values)
    }

    @Test("DMPLayer round-trips a per-address-priority packet")
    func dmpPAPRoundTrip() throws {
        let values: [UInt8] = [200] + Array(repeating: 100, count: 511)
        let data = DMPLayer.createAsData(startCode: .perAddressPriority, values: values)
        let parsed = try DMPLayer.parse(fromData: data)
        #expect(parsed.startCode == .perAddressPriority)
        #expect(parsed.values == values)
    }

    @Test("DMPLayer parse rejects truncated data")
    func dmpTruncated() {
        #expect(throws: (any Error).self) {
            try DMPLayer.parse(fromData: Data([0x00, 0x01, 0x02]))
        }
    }

    @Test("DMPLayer parse throws its own error type for a bad flags/length field")
    func dmpBadFlagsAndLengthErrorType() {
        var data = DMPLayer.createAsData(startCode: .null, values: Array(repeating: 0, count: 512))
        data[1] = 0xFF  // corrupt the flags/length so it no longer matches the data
        #expect(throws: DMPLayerValidationError.self) {
            try DMPLayer.parse(fromData: data)
        }
    }

    // MARK: - DataFramingLayer (the hardcoded flags/length matches a canonical 523-byte DMP payload)

    /// A framing layer wrapping a canonical null start-code DMP layer (a full 600-byte framing packet).
    private func dataFramingData(nameData: Data, priority: UInt8 = 100, universe: UInt16 = 1) -> Data {
        var data = DataFramingLayer.createAsData(nameData: nameData, priority: priority, universe: universe)
        data.append(DMPLayer.createAsData(startCode: .null, values: Array(repeating: 0, count: 512)))
        return data
    }

    @Test("DataFramingLayer round-trips over a canonical DMP payload")
    func dataFramingRoundTrip() throws {
        let dmpData = DMPLayer.createAsData(startCode: .null, values: Array(repeating: 128, count: 512))
        var data = DataFramingLayer.createAsData(nameData: Source.buildNameData(from: "Layer Test Source"), priority: 150, universe: 42)
        data.append(dmpData)
        let parsed = try DataFramingLayer.parse(fromData: data)
        #expect(parsed.sourceName == "Layer Test Source")
        #expect(parsed.priority == 150)
        #expect(parsed.sequenceNumber == 0)
        #expect(parsed.options == .none)
        #expect(parsed.syncAddress == 0)
        #expect(parsed.universe == 42)
        #expect(parsed.data == dmpData)
    }

    @Test("DataFramingLayer parses the synchronization universe (address)")
    func dataFramingParsesSyncAddress() throws {
        var data = dataFramingData(nameData: Source.buildNameData(from: "Sync Source"))
        data.replacingSyncAddress(with: 20001)
        let parsed = try DataFramingLayer.parse(fromData: data)
        #expect(parsed.syncAddress == 20001)
    }

    @Test("DataFramingLayer parse rejects an unknown vector")
    func dataFramingInvalidVector() {
        var data = dataFramingData(nameData: Source.buildNameData(from: "Test"))
        data[DataFramingLayer.Offset.vector.rawValue + 3] = 0xFF
        #expect(throws: DataFramingLayerValidationError.self) {
            try DataFramingLayer.parse(fromData: data)
        }
    }

    @Test("DataFramingLayer parse rejects an out-of-range priority")
    func dataFramingInvalidPriority() {
        var data = dataFramingData(nameData: Source.buildNameData(from: "Test"))
        data[DataFramingLayer.Offset.priority.rawValue] = 201  // valid priorities are 0-200
        #expect(throws: DataFramingLayerValidationError.self) {
            try DataFramingLayer.parse(fromData: data)
        }
    }

    @Test("DataFramingLayer parse rejects an invalid universe")
    func dataFramingInvalidUniverse() {
        var data = dataFramingData(nameData: Source.buildNameData(from: "Test"))
        data[DataFramingLayer.Offset.universe.rawValue] = 0x00  // universe 0 (valid data universes are 1-63999)
        data[DataFramingLayer.Offset.universe.rawValue + 1] = 0x00
        #expect(throws: DataFramingLayerValidationError.self) {
            try DataFramingLayer.parse(fromData: data)
        }
    }

    // MARK: - UniverseDiscoveryFramingLayer (build writes zero flags/length; patch before self-parse)

    @Test("UniverseDiscoveryFramingLayer round-trips over a universe-list payload")
    func discoveryFramingRoundTrip() throws {
        var data = UniverseDiscoveryFramingLayer.createAsData(nameData: Source.buildNameData(from: "Discovery Source"))
        data.append(UniverseDiscoveryLayer.createAsData(page: 0, lastPage: 0, universeList: [1, 2, 3]))
        data.replacingUniverseDiscoveryFramingFlagsAndLength(with: UInt16(data.count))
        let parsed = try UniverseDiscoveryFramingLayer.parse(fromData: data)
        #expect(parsed.vector == .extendedDiscovery)
        #expect(parsed.sourceName == "Discovery Source")
        let inner = try UniverseDiscoveryLayer.parse(fromData: parsed.data)
        #expect(inner.universeList == [1, 2, 3])
    }

    @Test("UniverseDiscoveryFramingLayer parse rejects an unknown vector")
    func discoveryFramingInvalidVector() {
        var data = UniverseDiscoveryFramingLayer.createAsData(nameData: Source.buildNameData(from: "Test"))
        data.append(UniverseDiscoveryLayer.createAsData(page: 0, lastPage: 0, universeList: [1]))
        data.replacingUniverseDiscoveryFramingFlagsAndLength(with: UInt16(data.count))
        data[UniverseDiscoveryFramingLayer.Offset.vector.rawValue + 3] = 0xFF
        #expect(throws: UniverseDiscoveryFramingLayerValidationError.self) {
            try UniverseDiscoveryFramingLayer.parse(fromData: data)
        }
    }

    // MARK: - UniverseDiscoveryLayer (self-round-trips: flags/length are computed on build)

    @Test(
        "UniverseDiscoveryLayer round-trips a universe list",
        arguments: [
            [UInt16](),
            [1],
            [1, 100, 63999],
            (1...512).map { UInt16($0) },
        ])
    func discoveryRoundTrip(list: [UInt16]) throws {
        let data = UniverseDiscoveryLayer.createAsData(page: 0, lastPage: 0, universeList: list)
        let parsed = try UniverseDiscoveryLayer.parse(fromData: data)
        #expect(parsed.page == 0)
        #expect(parsed.lastPage == 0)
        #expect(parsed.universeList == list)
    }

    @Test("UniverseDiscoveryLayer parse rejects truncated data")
    func discoveryTruncated() {
        #expect(throws: (any Error).self) {
            try UniverseDiscoveryLayer.parse(fromData: Data([0x00, 0x01]))
        }
    }

    @Test("UniverseDiscoveryLayer parse rejects a length field inconsistent with the data")
    func discoveryInconsistentLength() {
        var data = UniverseDiscoveryLayer.createAsData(page: 0, lastPage: 0, universeList: [1, 2])
        data.append(0xFF)  // stray trailing byte -> stored length no longer matches
        #expect(throws: (any Error).self) {
            try UniverseDiscoveryLayer.parse(fromData: data)
        }
    }

    @Test("UniverseDiscoveryLayer parse rejects an odd universe-list byte count")
    func discoveryOddUniverseListLength() {
        var data = UniverseDiscoveryLayer.createAsData(page: 0, lastPage: 0, universeList: [1])
        data.removeLast()  // half a universe number remains in the list region
        data.replaceSubrange(0...1, with: FlagsAndLength.fromLength(UInt16(data.count)).data)
        #expect(throws: UniverseDiscoveryLayerValidationError.self) {
            try UniverseDiscoveryLayer.parse(fromData: data)
        }
    }

    // MARK: - RootLayer (build hardcodes the data-packet flags/length; patch before self-parse)

    @Test("RootLayer round-trips vector, CID and payload")
    func rootRoundTrip() throws {
        let cid = UUID(uuidString: "11223344-5566-7788-99AA-BBCCDDEEFF00")!
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        var data = RootLayer.createAsData(vector: .data, cid: cid)
        data.append(payload)
        data.replacingRootLayerFlagsAndLength(with: UInt16(data.count - RootLayer.Offset.flagsAndLength.rawValue))
        let parsed = try RootLayer.parse(fromData: data)
        #expect(parsed.vector == .data)
        #expect(parsed.cid == cid)
        #expect(parsed.data == payload)
    }

    @Test("RootLayer parse rejects truncated data")
    func rootTruncated() {
        #expect(throws: (any Error).self) {
            try RootLayer.parse(fromData: Data(repeating: 0, count: 10))
        }
    }

    @Test("RootLayer parse rejects an unknown vector")
    func rootInvalidVector() {
        var data = RootLayer.createAsData(vector: .data, cid: UUID())
        data.append(Data([0x01, 0x02]))
        data.replacingRootLayerFlagsAndLength(with: UInt16(data.count - RootLayer.Offset.flagsAndLength.rawValue))
        data[RootLayer.Offset.vector.rawValue + 3] = 0xFF
        #expect(throws: RootLayerValidationError.self) {
            try RootLayer.parse(fromData: data)
        }
    }

    @Test("RootLayer parse rejects a corrupted ACN packet identifier")
    func rootInvalidPacketIdentifier() {
        var data = RootLayer.createAsData(vector: .data, cid: UUID())
        data.append(Data([0x01, 0x02]))
        data.replacingRootLayerFlagsAndLength(with: UInt16(data.count - RootLayer.Offset.flagsAndLength.rawValue))
        data[RootLayer.Offset.acnPacketIdentifier.rawValue] = 0xFF
        #expect(throws: RootLayerValidationError.self) {
            try RootLayer.parse(fromData: data)
        }
    }

    @Test("RootLayer parse rejects a corrupted preamble")
    func rootCorruptPreamble() throws {
        let cid = UUID()
        var data = RootLayer.createAsData(vector: .data, cid: cid)
        data.append(Data([0x01, 0x02]))
        data.replacingRootLayerFlagsAndLength(with: UInt16(data.count - RootLayer.Offset.flagsAndLength.rawValue))
        data[0] = 0xFF  // break the preamble
        #expect(throws: (any Error).self) {
            try RootLayer.parse(fromData: data)
        }
    }

}
