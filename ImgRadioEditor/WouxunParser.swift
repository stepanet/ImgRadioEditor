import Foundation

/// Parser for Wouxun KG-UV9K EEPROM images (CHIRP format).
///
/// Memory map (from CHIRP `kguv9dplus.py`, `_MEM_FORMAT02`):
/// - Channels: 0xa00 + i*16, i in 0..<999
/// - Names:    0x4900 + i*8,  8 bytes ASCII, padding \0
/// - Valid:    0x7000 + i,    1 byte: 0x41 = valid, 0xFC = invalid
///
/// Channel layout (16 bytes, big-endian):
///   @0  u32 rxfreq   (units 10 Hz)
///   @4  u32 txfreq   (units 10 Hz, 0xFFFFFFFF = TX off)
///   @8  u16 txtone   (CTCSS: code in 0.1 Hz; DCS: 0x8000|code, 0x4000=polarity)
///   @10 u16 rxtone
///   @12 u8  qt/misc
///   @13 u8  bit7/scan/bit5/pwr(2)/mod/fm_dev(2)
///   @14 u8  state    (0xFC = valid, 0xFF = empty)
///   @15 u8  c3
class WouxunParser {

    static let channelsStart = 0xa00
    static let channelsCount = 999
    static let channelSize = 16

    static let namesStart = 0x4900
    static let nameSize = 8

    static let validStart = 0x7000

    
    
    // CHIRP constants
    private static let MEM_VALID: UInt8 = 0xFC
    private static let MEM_INVALID: UInt8 = 0xFF
    private static let CHAN_VALID: UInt8 = 0x41
    private static let CHAN_INVALID: UInt8 = 0xFC

    // Power levels (CHIRP: L=1W, M=2W, H=5W)
    private static let powerLevels = [1, 2, 5]  // watts
    private static let powerLabels = ["L", "M", "H"]

    // MARK: - Parse

    static func parse(_ data: Data) -> [K5Channel] {
        var channels: [K5Channel] = []
        guard data.count >= channelsStart + channelsCount * channelSize else {
            return channels
        }
        
        

        for i in 0..<channelsCount {
            
            
            
            
            let offset = channelsStart + i * channelSize
            let chunk = data.subdata(in: offset..<offset + channelSize)
            let b0 = chunk[chunk.startIndex + 0]
            let b1 = chunk[chunk.startIndex + 1]
            let b2 = chunk[chunk.startIndex + 2]
            let b3 = chunk[chunk.startIndex + 3]
            

            let manual = (UInt32(b0) << 24) | (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3)
            
            let rxFreqRaw = readU32BE(chunk, 0)
                        
            let txFreqRaw = readU32BE(chunk, 4)
            let txToneRaw = readU16BE(chunk, 8)
            let rxToneRaw = readU16BE(chunk, 10)
            let misc = chunk[chunk.startIndex + 12]
            let flags = chunk[chunk.startIndex + 13]
            let state = chunk[chunk.startIndex + 14]

            // Empty detection: state == 0xFF or rxfreq out of range
            let isEmpty = (state == MEM_INVALID) || (rxFreqRaw > 999_999_999)
            if isEmpty {
                channels.append(K5Channel(
                    index: i + 1, name: "", rxFreq: 0, txFreq: 0,
                    offsetDir: 0, txPower: 0, bandwidth: 0,
                    isScanlist1: false, isScanlist2: false, isScanlist3: false,
                    rxTone: 0, txTone: 0, toneMode: 0
                ))
                continue
            }

            let rxFreqHz = Double(rxFreqRaw) * 10.0
            let rxFreqMHz = rxFreqHz / 1_000_000.0

            // TX frequency / offset direction
            var offsetDir = 0
            var txFreqMHz = rxFreqMHz
            if txFreqRaw == 0xFFFF_FFFF {
                offsetDir = 3  // TX off
                txFreqMHz = rxFreqMHz
            } else {
                let txFreqHz = Double(txFreqRaw) * 10.0
                txFreqMHz = txFreqHz / 1_000_000.0
                let diff = abs(txFreqHz - rxFreqHz)
                if diff < 1000 {
                    offsetDir = 0  // simplex
                } else if diff > 70_000_000 {
                    offsetDir = 4  // split
                } else if txFreqHz > rxFreqHz {
                    offsetDir = 1  // plus
                } else {
                    offsetDir = 2  // minus
                }
            }

            // Name
            let nameOffset = namesStart + i * nameSize
            var name = ""
            if nameOffset + nameSize <= data.count {
                let nameBytes = data.subdata(in: nameOffset..<nameOffset + nameSize)
                name = String(bytes: nameBytes, encoding: .ascii)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                    .trimmingCharacters(in: .whitespaces) ?? ""
            }

            // Tones
            let (toneMode, rxTone, txTone) = decodeTones(tx: txToneRaw, rx: rxToneRaw)

            // Power / bandwidth / mode
            let pwr = Int((flags >> 3) & 0x03)
            let isAM = ((flags >> 2) & 0x01) == 1
            let fmDev = Int(flags & 0x03)
            let bandwidth = fmDev == 0 ? 0 : 1
            let _ = isAM  // K5Channel не имеет поля для AM — игнорируем

            // Scan
            let scanEnabled = ((flags >> 6) & 0x01) == 1
            let isScanlist1 = scanEnabled

            channels.append(K5Channel(
                index: i + 1,
                name: name,
                rxFreq: rxFreqMHz,
                txFreq: txFreqMHz,
                offsetDir: offsetDir,
                txPower: pwr,
                bandwidth: bandwidth,
                isScanlist1: isScanlist1,
                isScanlist2: false,
                isScanlist3: false,
                rxTone: rxTone,
                txTone: txTone,
                toneMode: toneMode
            ))
        }
        return channels
    }

    // MARK: - Helpers

    private static func readU32BE(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return (UInt32(data[base]) << 24)
            | (UInt32(data[base + 1]) << 16)
            | (UInt32(data[base + 2]) << 8)
            | UInt32(data[base + 3])
    }

    private static func readU16BE(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return (UInt16(data[base]) << 8) | UInt16(data[base + 1])
    }

    /// Decode Wouxun tone encoding into (toneMode, rxTone, txTone).
    /// - CTCSS: `code` in 0.1 Hz units, e.g. 885 → 88.5 Hz
    /// - DCS:   `0x8000 | code`, polarity bit `0x4000` (I/N)
    private static func decodeTones(tx: UInt16, rx: UInt16) -> (Int, Double, Double) {
        func decode(_ raw: UInt16) -> (mode: Int, value: Double) {
            if raw == 0 || raw == 0xFFFF { return (0, 0) }
            if (raw & 0x8000) != 0 {
                // DCS
                let code = raw & 0x3FFF
                return (2, Double(code))
            } else {
                // CTCSS: code in 0.1 Hz
                return (1, Double(raw) / 10.0)
            }
        }
        let txD = decode(tx)
        let rxD = decode(rx)
        let mode = max(txD.mode, rxD.mode)
        return (mode, rxD.value, txD.value)
    }
}
