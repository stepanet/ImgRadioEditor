import Foundation

class WouxunParser {
    
    // Смещение, которое мы нашли на скриншоте (0x2560 в HEX = 9568 в десятичном)
    static let channelsStart = 0x2560
    static let channelsCount = 999
    static let channelSize = 16
    
    static func parse(_ data: Data) -> [K5Channel] {
        var channels: [K5Channel] = []
        
        for i in 0..<channelsCount {
            let offset = channelsStart + (i * channelSize)
            guard offset + channelSize <= data.count else { break }
            
            let chunk = data.subdata(in: offset..<offset+channelSize)
            
            // Читаем первые 4 байта (частота приёма)
            let freqRaw = chunk.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
            
            // Проверка на пустой канал (0xFFFFFFFF или 0)
            if freqRaw == 0xFFFFFFFF || freqRaw == 0 {
                continue
            }
            
            // Пытаемся вычислить частоту.
            // Если 831367170 разделить на 1000, получится ~831367 МГц (слишком много).
            // Скорее всего, это частота в 10 Гц, но с каким-то множителем.
            // Пока ставим заглушку, чтобы увидеть, что каналы читаются.
            let rxFreq = Double(freqRaw) / 1_000_000.0
            
            channels.append(K5Channel(
                index: i + 1,
                name: "CH-\(i + 1)", // Имена пока не читаем, они лежат в другом месте
                rxFreq: rxFreq,
                txFreq: rxFreq, // Пока ставим симплекс
                offsetDir: 0,
                txPower: 0,
                bandwidth: 0,
                isScanlist1: false,
                isScanlist2: false,
                isScanlist3: false,
                rxTone: 0,
                txTone: 0,
                toneMode: 0
            ))
        }
        return channels
    }
}
