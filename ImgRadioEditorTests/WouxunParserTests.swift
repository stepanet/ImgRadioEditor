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
}
