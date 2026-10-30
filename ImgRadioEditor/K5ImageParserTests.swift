import XCTest
@testable import ImgRadioEditor

final class K5ImageParserTests: XCTestCase {

    // MARK: - Helpers

    /// Создаёт «валидный» образ 8192 байт: каналы 1..N с частотами 145.000, 145.100, ...
    private func makeSyntheticImage() -> Data {
        var data = Data(repeating: 0xFF, count: K5ImageParser.fileSize)

        // Заголовок каналов: сбрасываем в 0xFF — уже сделано.
        // Канал 1: 145.000 МГц, симплекс, HIGH, wide, без тонов.
        setChannel(
            in: &data,
            index: 0,
            rxFreq: 145.000,
            txFreq: 145.000,
            offsetDir: 0,
            txPower: 7,
            bandwidth: 0,
            name: "TEST1",
            scan1: true,
            scan2: false,
            scan3: true
        )
        // Канал 2: 433.500 МГц, +5 МГц, LOW, narrow.
        setChannel(
            in: &data,
            index: 1,
            rxFreq: 433.500,
            txFreq: 438.500,
            offsetDir: 1,
            txPower: 0,
            bandwidth: 1,
            name: "TEST2",
            scan1: false,
            scan2: true,
            scan3: false
        )
        // Канал 3: 446.006 МГц, CTCSS 88.5.
        setChannel(
            in: &data,
            index: 2,
            rxFreq: 446.006,
            txFreq: 446.006,
            offsetDir: 0,
            txPower: 6,
            bandwidth: 0,
            name: "PMR1",
            scan1: false,
            scan2: false,
            scan3: false,
            toneMode: 1,
            txTone: 88.5,
            rxTone: 88.5
        )
        return data
    }

    private func setChannel(
        in data: inout Data,
        index: Int,
        rxFreq: Double,
        txFreq: Double,
        offsetDir: Int,
        txPower: Int,
        bandwidth: Int,
        name: String,
        scan1: Bool,
        scan2: Bool,
        scan3: Bool,
        toneMode: Int = 0,
        txTone: Double = 0,
        rxTone: Double = 0
    ) {
        let chOffset = K5ImageParser.channelsStart + index * 16
        let freqRaw = rxFreq > 0 ? UInt32((rxFreq * 1_000_000.0) / 10.0) : K5ImageParser.emptyFreqRaw
        let offsetRaw = offsetDir != 0 ? UInt32((abs(txFreq - rxFreq) * 1_000_000.0) / 10.0) : 0

        data.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: freqRaw.littleEndian, toByteOffset: chOffset, as: UInt32.self)
            ptr.storeBytes(of: offsetRaw.littleEndian, toByteOffset: chOffset + 4, as: UInt32.self)
        }

        var rxcodeflag = 0
        var txcodeflag = 0
        var rxcodeIdx: UInt8 = 0
        var txcodeIdx: UInt8 = 0
        if toneMode == 1 {
            txcodeflag = 1
            if let idx = K5ImageParser.ctcssTones.firstIndex(of: txTone) { txcodeIdx = UInt8(idx) }
            rxcodeflag = 1
            if let idx = K5ImageParser.ctcssTones.firstIndex(of: rxTone) { rxcodeIdx = UInt8(idx) }
        } else if toneMode == 2 {
            txcodeflag = 2
            if let idx = K5ImageParser.dcsCodes.firstIndex(of: Int(txTone)) { txcodeIdx = UInt8(idx) }
            rxcodeflag = 2
            if let idx = K5ImageParser.dcsCodes.firstIndex(of: Int(rxTone)) { rxcodeIdx = UInt8(idx) }
        }

        data[chOffset + 0x08] = rxcodeIdx
        data[chOffset + 0x09] = txcodeIdx
        data[chOffset + 0x0A] = (UInt8(txcodeflag) << 4) | UInt8(rxcodeflag)
        data[chOffset + 0x0B] = (data[chOffset + 0x0B] & 0x0F) | (UInt8(offsetDir) << 4)
        data[chOffset + 0x0C] = (data[chOffset + 0x0C] & 0b11000111) | (UInt8(txPower) << 3)
        data[chOffset + 0x0C] = (data[chOffset + 0x0C] & 0b10111111) | (UInt8(bandwidth) << 6)

        let nameOffset = K5ImageParser.namesStart + index * 16
        var nameBytes = Array(name.utf8.prefix(15))
        nameBytes.append(0x00)
        while nameBytes.count < 16 { nameBytes.append(0xFF) }
        data.replaceSubrange(nameOffset..<nameOffset+16, with: nameBytes)

        let attrOffset = K5ImageParser.attrStart + index
        if index < 207 {
            var attrByte: UInt8 = 0
            if scan1 { attrByte |= 0b001 }
            if scan2 { attrByte |= 0b010 }
            if scan3 { attrByte |= 0b100 }
            data[attrOffset] = attrByte
        }
    }

    // MARK: - Round-trip

    func testParseSerializeParseRoundTrip() {
        let original = makeSyntheticImage()

        // 1) parse → channelsA
        let channelsA = K5ImageParser.parse(original)
        XCTAssertEqual(channelsA.count, K5ImageParser.channelsCount)

        // 2) serialize(channelsA) → dataB
        let dataB = K5ImageParser.serialize(channels: channelsA, originalData: original)
        XCTAssertEqual(dataB.count, original.count)

        // 3) parse(dataB) → channelsC
        let channelsC = K5ImageParser.parse(dataB)

        // Сравниваем все каналы
        for i in 0..<channelsA.count {
            let a = channelsA[i]
            let c = channelsC[i]
            XCTAssertEqual(a.index, c.index, "index канала \(i)")
            XCTAssertEqual(a.name, c.name, "name канала \(i)")
            XCTAssertEqual(a.rxFreq, c.rxFreq, accuracy: 0.0001, "rxFreq канала \(i)")
            XCTAssertEqual(a.txFreq, c.txFreq, accuracy: 0.0001, "txFreq канала \(i)")
            XCTAssertEqual(a.offsetDir, c.offsetDir, "offsetDir канала \(i)")
            XCTAssertEqual(a.txPower, c.txPower, "txPower канала \(i)")
            XCTAssertEqual(a.bandwidth, c.bandwidth, "bandwidth канала \(i)")
            XCTAssertEqual(a.isScanlist1, c.isScanlist1, "scan1 канала \(i)")
            XCTAssertEqual(a.isScanlist2, c.isScanlist2, "scan2 канала \(i)")
            XCTAssertEqual(a.isScanlist3, c.isScanlist3, "scan3 канала \(i)")
            XCTAssertEqual(a.toneMode, c.toneMode, "toneMode канала \(i)")
            XCTAssertEqual(a.rxTone, c.rxTone, accuracy: 0.001, "rxTone канала \(i)")
            XCTAssertEqual(a.txTone, c.txTone, accuracy: 0.001, "txTone канала \(i)")
            XCTAssertEqual(a.isEmpty, c.isEmpty, "isEmpty канала \(i)")
        }
    }

    func testSerializePreservesNameTermination() {
        let original = Data(repeating: 0xFF, count: K5ImageParser.fileSize)
        var channels = K5ImageParser.parse(original)

        // Имя ровно 15 символов — старый код терял терминатор
        channels[0].name = "ABCDEFGHIJKLMNO"  // 15 символов
        channels[0].rxFreq = 145.000
        channels[0].txFreq = 145.000

        let data = K5ImageParser.serialize(channels: channels, originalData: original)
        let nameOffset = K5ImageParser.namesStart
        let nameBytes = Array(data[nameOffset..<(nameOffset + 16)])

        XCTAssertEqual(nameBytes[15], 0x00, "16-й байт имени должен быть 0x00 (терминатор)")
        XCTAssertEqual(String(bytes: nameBytes[0..<15], encoding: .ascii), "ABCDEFGHIJKLMNO")
    }

    func testSerializePreservesOffsetRawWhenOffsetDirZero() {
        var original = Data(repeating: 0xFF, count: K5ImageParser.fileSize)
        let chOffset = K5ImageParser.channelsStart
        // Ручное «грязное» значение offsetRaw (не 0), но offsetDir = 0
        let dirtyOffset: UInt32 = 0xDEADBEEF
        original.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: K5ImageParser.emptyFreqRaw.littleEndian, toByteOffset: chOffset, as: UInt32.self)
            ptr.storeBytes(of: dirtyOffset.littleEndian, toByteOffset: chOffset + 4, as: UInt32.self)
        }
        original[chOffset + 0x0B] = 0x00  // offsetDir = 0

        var channels = K5ImageParser.parse(original)
        channels[0].rxFreq = 145.000
        channels[0].txFreq = 145.000
        channels[0].offsetDir = 0

        let data = K5ImageParser.serialize(channels: channels, originalData: original)
        let resultOffset = data.withUnsafeBytes { $0.load(fromByteOffset: chOffset + 4, as: UInt32.self) }

        XCTAssertEqual(resultOffset, dirtyOffset, "P0.2: offsetRaw при offsetDir == 0 не должен обнуляться")
    }
}
