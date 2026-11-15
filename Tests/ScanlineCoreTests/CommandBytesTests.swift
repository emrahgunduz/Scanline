import Testing
@testable import ScanlineCore

// Every expected value below is copied from the Capture Tool trace (traces/scan1).

@Test func memoryReadMatchesTrace() {
    #expect(IRIScanExpress4.memReadCDB(address: 0x0046_2240, length: 0x10000).hex
            == "c3070046224000010000000000000000")
    #expect(IRIScanExpress4.memReadCDB(address: 0x004F_2240, length: 32256).hex
            == "c307004f224000007e00000000000000")
    #expect(IRIScanExpress4.memReadCDB(address: 0x013C_EE40, length: 15552).hex
            == "c307013cee4000003cc0000000000000")
}

@Test func bridgeCommandsMatchTrace() {
    #expect(IRIScanExpress4.bridgeCDB(0xFF, 0x02, 0, length: 4).hex == "c5070000000000000004ff0200000000")
    #expect(IRIScanExpress4.bridgeCDB(0x02, 0x03, 0, length: 89).hex == "c5070000000000000059020300000000")
    #expect(IRIScanExpress4.bridgeCDB(0x02, 0x01, 1, length: 4).hex == "c5070000000000000004020101000000")
    #expect(IRIScanExpress4.bridgeCDB(0x02, 0x02, 2, length: 24).hex == "c5070000000000000018020202000000")
}

@Test func avisionCommandsMatchTrace() {
    #expect(IRIScanExpress4.cdb10(0x28, type: 0x00, qualifier: 0x0A0D, length: 0x1FEAE0).hex == "280000000a0d1feae000")
    #expect(IRIScanExpress4.cdb10(0x28, type: 0x69, qualifier: 0x0A0D, length: 0x80).hex == "280069000a0d00008000")
    #expect(IRIScanExpress4.cdb10(0x28, type: 0xA0, qualifier: 0x0A0D, length: 2).hex == "2800a0000a0d00000200")
    #expect(IRIScanExpress4.setWindow300Gray.count == 89)
    #expect(IRIScanExpress4.setWindow300Gray.hex ==
        "24000000000000004f0000000000000000470000012c012c00000000000000000000288000004380808080050800000300000000000000000000ff1de0ff001e6010e01000006400640064c00000000b000000000000000000")
}

@Test func bandHeaderParsing() {
    let st = hexBytes("010000000100000000000000200a0000f000000040224600")
    #expect(le32(st, 12) == 2592)
    #expect(le32(st, 16) == 240)
    #expect(le32(st, 20) == 0x0046_2240)
}
