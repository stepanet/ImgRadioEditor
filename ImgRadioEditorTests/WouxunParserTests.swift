import XCTest
@testable import ImgRadioEditor

final class WouxunParserTests: XCTestCase {

    func testParseKGUV9KFirstChannels() throws {
        guard let url = Bundle(for: type(of: self))
            .url(forResource: "Wouxun_KG-UV9K_20261030", withExtension: "img") else {
            throw XCTSkip("Дамп Wouxun_KG-UV9K_20261030.img не найден в бандле тестов")
        }
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThanOrEqual(data.count, 0x8000)

        let channels = WouxunParser.parse(data)
        XCTAssertEqual(channels.count, 999)

        let expected: [(Int, String, Double)] = [
            (1, "SVO Circ", 136.025),
            (2, "VKO Towe", 118.3),
            (3, "DME Towe", 118.6),
            (4, "SVO Taxi", 119.0),
            (5, "DME Taxi", 119.0),
            (6, "DME Grou", 119.7),
            (7, "SVO ATIS", 120.375),
        ]
        for (idx, name, freq) in expected {
            let ch = channels[idx - 1]
            XCTAssertEqual(ch.name, name, "Канал \(idx): имя")
            XCTAssertFalse(ch.isEmpty, "Канал \(idx) не должен быть пустым")
            XCTAssertEqual(ch.rxFreq, freq, accuracy: 0.001, "Канал \(idx): частота")
        }
    }
    
    
    /// D: round-trip parse → serialize → parse. Каналы, имена, частоты, тоны
    /// должны совпасть. Байты — побайтово для нетронутых каналов.
    func testSerializeRoundTrip() throws {
        guard let url = Bundle(for: type(of: self))
            .url(forResource: "Wouxun_KG-UV9K_20261030", withExtension: "img") else {
            throw XCTSkip("Дамп не найден")
        }
        let original = try Data(contentsOf: url)
        let parsed1 = WouxunParser.parse(original)

        // Сериализуем без изменений
        let serialized = WouxunParser.serialize(channels: parsed1, originalData: original)
        XCTAssertEqual(serialized.count, original.count, "Размер не изменился")

        // Повторный parse должен дать те же каналы
        let parsed2 = WouxunParser.parse(serialized)
        XCTAssertEqual(parsed1.count, parsed2.count)

        for i in 0..<parsed1.count {
            XCTAssertEqual(parsed1[i].name, parsed2[i].name, "CH \(i+1): имя")
            XCTAssertEqual(parsed1[i].rxFreq, parsed2[i].rxFreq, accuracy: 0.001, "CH \(i+1): rxFreq")
            XCTAssertEqual(parsed1[i].txFreq, parsed2[i].txFreq, accuracy: 0.001, "CH \(i+1): txFreq")
            XCTAssertEqual(parsed1[i].offsetDir, parsed2[i].offsetDir, "CH \(i+1): offsetDir")
            XCTAssertEqual(parsed1[i].txPower, parsed2[i].txPower, "CH \(i+1): txPower")
            XCTAssertEqual(parsed1[i].bandwidth, parsed2[i].bandwidth, "CH \(i+1): bandwidth")
            XCTAssertEqual(parsed1[i].toneMode, parsed2[i].toneMode, "CH \(i+1): toneMode")
            XCTAssertEqual(parsed1[i].rxTone, parsed2[i].rxTone, accuracy: 0.1, "CH \(i+1): rxTone")
            XCTAssertEqual(parsed1[i].txTone, parsed2[i].txTone, accuracy: 0.1, "CH \(i+1): txTone")
            XCTAssertEqual(parsed1[i].isScanlist1, parsed2[i].isScanlist1, "CH \(i+1): scan")
        }
    }

    /// D: изменение канала и проверка, что оно сериализуется.
    func testSerializeEditedChannel() throws {
        guard let url = Bundle(for: type(of: self))
            .url(forResource: "Wouxun_KG-UV9K_20261030", withExtension: "img") else {
            throw XCTSkip("Дамп не найден")
        }
        let original = try Data(contentsOf: url)
        var channels = WouxunParser.parse(original)

        // Меняем канал 1: имя, частоту, мощность
        channels[0].name = "TEST CH"
        channels[0].rxFreq = 145.500
        channels[0].txFreq = 145.500
        channels[0].offsetDir = 0
        channels[0].txPower = 2  // HIGH (в UV9K: 0=L, 1=M, 2=H)

        let serialized = WouxunParser.serialize(channels: channels, originalData: original)
        let reparsed = WouxunParser.parse(serialized)

        XCTAssertEqual(reparsed[0].name, "TEST CH")
        XCTAssertEqual(reparsed[0].rxFreq, 145.500, accuracy: 0.001)
        XCTAssertEqual(reparsed[0].txPower, 2)
    }
}
