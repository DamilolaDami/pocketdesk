import Testing
@testable import PDProtocol

@Suite struct NALUnitsTests {
    @Test func appendThenSplitRoundTrips() throws {
        let vps: [UInt8] = [0x40, 0x01, 0x0C]
        let sps: [UInt8] = [0x42, 0x01, 0x01, 0x01]
        var payload: [UInt8] = []
        NALUnits.append(vps, to: &payload)
        NALUnits.append(sps, to: &payload)
        #expect(payload.prefix(4) == [0, 0, 0, 3])

        let units = try NALUnits.split(payload)
        #expect(units.map(Array.init) == [vps, sps])
        #expect(units.map { NALUnits.hevcType(of: $0) } == [NALUnits.HEVCType.vps.rawValue, NALUnits.HEVCType.sps.rawValue])
    }

    @Test func rejectsTruncatedPayload() {
        #expect(throws: WireError.truncated) { try NALUnits.split([0, 0, 0, 9, 1, 2]) }
        #expect(throws: WireError.truncated) { try NALUnits.split([0, 0]) }
        #expect(throws: WireError.truncated) { try NALUnits.split([0, 0, 0, 0]) }
    }
}
