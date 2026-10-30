import Foundation

class K5ImageParser {
    
    static let channelsStart = 0x0000
    static let channelsCount = 214
    static let namesStart = 0x0F50
    static let attrStart = 0x0D60
    static let fileSize = 0x2000
    /// P3.13: raw-значение «пустой частоты» в EEPROM.
    static let emptyFreqRaw: UInt32 = 0xFFFFFFFF
    
    static let ctcssTones: [Double] = [
        67.0, 69.3, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4,
        88.5, 91.5, 94.8, 97.4, 100.0, 103.5, 107.2, 110.9,
        114.8, 118.8, 123.0, 127.3, 131.8, 136.5, 141.3, 146.2,
        151.4, 156.7, 159.8, 162.2, 165.5, 167.9, 171.3, 173.8,
        177.3, 179.9, 183.5, 186.2, 189.9, 192.8, 196.6, 199.5,
        203.5, 206.5, 210.7, 218.1, 225.7, 229.1, 233.6, 241.8,
        250.3, 254.1
    ]
    
    // Таблица DCS кодов (из Python-драйвера)
    static let dcsCodes: [Int] = [
        23, 25, 26, 31, 32, 36, 43, 47, 51, 53, 54,
        65, 71, 72, 73, 74, 114, 115, 116, 122, 125, 131,
        132, 134, 143, 145, 152, 155, 156, 162, 165, 172, 174,
        205, 212, 223, 225, 226, 243, 244, 245, 246, 251, 252,
        255, 261, 263, 265, 266, 271, 274, 306, 311, 315, 325,
        331, 332, 343, 346, 351, 356, 364, 365, 371, 411, 412,
        413, 423, 431, 432, 445, 446, 452, 454, 455, 462, 464,
        465, 466, 503, 506, 516, 523, 526, 532, 546, 565, 606,
        612, 624, 627, 631, 632, 654, 662, 664, 703, 712, 723,
        731, 732, 734, 743, 754
    ]
    
    static func parse(_ data: Data) -> [K5Channel] {
        var channels: [K5Channel] = []
        
        var names: [String] = []
        for i in 0..<200 {
            let nameOffset = namesStart + (i * 16)
            if nameOffset + 16 <= data.count {
                let nameData = data.subdata(in: nameOffset..<nameOffset+16)
                var nameBytes: [UInt8] = []
                for byte in nameData {
                    if byte == 0x00 || byte == 0xFF { break }
                    if byte >= 0x20 && byte <= 0x7E { nameBytes.append(byte) }
                }
                names.append((String(bytes: nameBytes, encoding: .ascii) ?? "").trimmingCharacters(in: .whitespaces))
            } else {
                names.append("")
            }
        }
        
        for i in 0..<channelsCount {
            let offset = channelsStart + (i * 16)
            guard offset + 16 <= data.count else { break }
            
            let chunk = data.subdata(in: offset..<offset+16)
            let freqRaw = chunk.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
            let offsetRaw = chunk.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
            
            var rxFreq = Double(freqRaw) * 10.0 / 1_000_000.0
            var txFreq = 0.0
            
            if freqRaw == K5ImageParser.emptyFreqRaw || freqRaw == 0 {
                rxFreq = 0
                txFreq = 0
            } else {
                let txOffset = Double(offsetRaw) * 10.0 / 1_000_000.0
                txFreq = rxFreq
                if (chunk[0x0B] >> 4) == 1 { txFreq += txOffset }
                if (chunk[0x0B] >> 4) == 2 { txFreq -= txOffset }
            }
            
            let modulationByte = chunk[0x0B]
            let offsetDir = Int((modulationByte >> 4) & 0x0F)
            
            let powerByte = chunk[0x0C]
            let txPower = Int((powerByte >> 3) & 0x07)
            let bandwidth = Int((powerByte >> 6) & 0x01)
            
            let rxcodeflag = Int(chunk[0x0A] & 0x0F)
            let txcodeflag = Int((chunk[0x0A] >> 4) & 0x0F)
            let rxcodeIdx = Int(chunk[0x08])
            let txcodeIdx = Int(chunk[0x09])
            
            var toneMode = 0
            var rTone = 0.0
            var tTone = 0.0
            
            if txcodeflag == 1 {
                toneMode = 1
                if txcodeIdx < ctcssTones.count { tTone = ctcssTones[txcodeIdx] }
            } else if txcodeflag == 2 {
                toneMode = 2
                if txcodeIdx < dcsCodes.count { tTone = Double(dcsCodes[txcodeIdx]) }
            }
            
            if rxcodeflag == 1 {
                if rxcodeIdx < ctcssTones.count { rTone = ctcssTones[rxcodeIdx] }
            } else if rxcodeflag == 2 {
                if rxcodeIdx < dcsCodes.count { rTone = Double(dcsCodes[rxcodeIdx]) }
            }
            
            let name = (i < 200) ? names[i] : "VFO \(i - 199)"
            
            let attrOffset = attrStart + i
            var scan1 = false, scan2 = false, scan3 = false
            if attrOffset < data.count && i < 207 {
                let attrByte = data[attrOffset]
                scan1 = (attrByte & 0b001) != 0
                scan2 = (attrByte & 0b010) != 0
                scan3 = (attrByte & 0b100) != 0
            }
            
            channels.append(K5Channel(
                index: i + 1,
                name: name,
                rxFreq: rxFreq,
                txFreq: txFreq,
                offsetDir: offsetDir,
                txPower: txPower,
                bandwidth: bandwidth,
                isScanlist1: scan1,
                isScanlist2: scan2,
                isScanlist3: scan3,
                rxTone: rTone,
                txTone: tTone,
                toneMode: toneMode
            ))
        }
        return channels
    }
    
    static func serialize(channels: [K5Channel], originalData: Data) -> Data {
        var data = originalData
        
        for (i, ch) in channels.enumerated() {
            let offset = channelsStart + (i * 16)
            guard offset + 16 <= data.count else { break }
            
            var freqRaw: UInt32 = K5ImageParser.emptyFreqRaw
            var offsetRaw: UInt32 = 0

            if !ch.isEmpty {
                freqRaw = UInt32((ch.rxFreq * 1_000_000.0) / 10.0)
                if ch.offsetDir != 0 {
                    offsetRaw = UInt32((abs(ch.txFreq - ch.rxFreq) * 1_000_000.0) / 10.0)
                } else {
                    // P0.2: при offsetDir == 0 не затираем оригинальный offsetRaw,
                    // если он уже был в образе (может использоваться рацией/CHIRP).
                    let existing = data.withUnsafeBytes {
                        $0.load(fromByteOffset: offset + 4, as: UInt32.self)
                    }
                    offsetRaw = existing
                }
            }
            
            data.withUnsafeMutableBytes { ptr in
                ptr.storeBytes(of: freqRaw.littleEndian, toByteOffset: offset, as: UInt32.self)
                ptr.storeBytes(of: offsetRaw.littleEndian, toByteOffset: offset + 4, as: UInt32.self)
            }
            
            var rxcodeflag = 0
            var txcodeflag = 0
            var rxcodeIdx: UInt8 = 0
            var txcodeIdx: UInt8 = 0
            
            if ch.toneMode == 1 {
                txcodeflag = 1
                if let idx = ctcssTones.firstIndex(of: ch.txTone) {
                    txcodeIdx = UInt8(idx)
                }
            } else if ch.toneMode == 2 {
                txcodeflag = 2
                if let idx = dcsCodes.firstIndex(of: Int(ch.txTone)) {
                    txcodeIdx = UInt8(idx)
                }
            }
            
            if ch.rxTone > 0 {
                if ch.toneMode == 1 {
                    rxcodeflag = 1
                    if let idx = ctcssTones.firstIndex(of: ch.rxTone) {
                        rxcodeIdx = UInt8(idx)
                    }
                } else if ch.toneMode == 2 {
                    rxcodeflag = 2
                    if let idx = dcsCodes.firstIndex(of: Int(ch.rxTone)) {
                        rxcodeIdx = UInt8(idx)
                    }
                }
            }
            
            data[offset + 0x08] = rxcodeIdx
            data[offset + 0x09] = txcodeIdx
            data[offset + 0x0A] = (UInt8(txcodeflag) << 4) | UInt8(rxcodeflag)
            
            let oldModByte = data[offset + 0x0B]
            let newModByte = (oldModByte & 0x0F) | (UInt8(ch.offsetDir) << 4)
            data[offset + 0x0B] = newModByte
            
            let oldPowerByte = data[offset + 0x0C]
            var newPowerByte = oldPowerByte
            newPowerByte = (newPowerByte & 0b11000111) | (UInt8(ch.txPower) << 3)
            newPowerByte = (newPowerByte & 0b10111111) | (UInt8(ch.bandwidth) << 6)
            data[offset + 0x0C] = newPowerByte
            
            if i < 200 {
                let nameOffset = namesStart + (i * 16)
                if nameOffset + 16 <= data.count {
                    var nameBytes = ch.name.utf8.prefix(15).map { $0 }
                    if nameBytes.count < 16 {
                        nameBytes.append(0x00)
                        while nameBytes.count < 16 { nameBytes.append(0xFF) }
                    }
                    data.replaceSubrange(nameOffset..<nameOffset+16, with: nameBytes)
                }
            }
            
            let attrOffset = attrStart + i
            if attrOffset < data.count && i < 207 {
                var attrByte = data[attrOffset] & 0b11111000
                if ch.isScanlist1 { attrByte |= 0b001 }
                if ch.isScanlist2 { attrByte |= 0b010 }
                if ch.isScanlist3 { attrByte |= 0b100 }
                data[attrOffset] = attrByte
            }
        }
        return data
    }
}
