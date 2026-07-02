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
