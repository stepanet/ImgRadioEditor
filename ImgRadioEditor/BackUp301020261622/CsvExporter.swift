import Foundation

/// Результат экспорта CSV: позволяет UI показать предупреждение о дубликатах.
struct CsvExportResult {
    let duplicates: [Double]
    let url: URL
}

class CsvExporter {
    
    /// Экспортирует каналы в CHIRP-совместимый CSV.
    /// - Returns: информацию о дубликатах частот (если были) и URL файла.
    @discardableResult
    static func export(channels: [K5Channel], to url: URL) -> CsvExportResult {
        var csvString = "Location,Name,Frequency,Duplex,Offset,Tone,rToneFreq,cToneFreq,DtcsCode,DtcsPolarity,RxDtcsCode,CrossMode,Mode,TStep,Skip,Power,Comment,URCALL,RPT1CALL,RPT2CALL,DVCODE\n"
        
        let activeChannels = channels.filter { !$0.isEmpty }
        
        // Проверка на дубликаты (P1.7: собираем и возвращаем наружу, а не только print)
        var seenFreqs = Set<Double>()
        var duplicates: [Double] = []
        
        for ch in activeChannels {
            if seenFreqs.contains(ch.rxFreq) {
                duplicates.append(ch.rxFreq)
            } else {
                seenFreqs.insert(ch.rxFreq)
            }
        }
        
        for (i, ch) in activeChannels.enumerated() {
            let location = i + 1
            // Запятые в имени заменяем пробелами, чтобы не ломать CSV без кавычек.
            let name = ch.name.replacingOccurrences(of: ",", with: " ")
            let freq = String(format: "%.6f", ch.rxFreq)
            
            var duplex = ""
            var offset = "0.000000"
            if ch.offsetDir == 1 {
                duplex = "+"
                offset = String(format: "%.6f", abs(ch.txFreq - ch.rxFreq))
            } else if ch.offsetDir == 2 {
                duplex = "-"
                offset = String(format: "%.6f", abs(ch.txFreq - ch.rxFreq))
            }
            
            var tone = ""
            var rToneFreq = "88.5"
            var dtcsCode = "023"
            
            if ch.toneMode == 1 {
                tone = "Tone"
                rToneFreq = String(format: "%.1f", ch.txTone)
            } else if ch.toneMode == 2 {
                tone = "DTCS"
                dtcsCode = String(format: "%03d", Int(ch.txTone))
            }
            
            let mode = ch.bandwidth == 1 ? "NFM" : "FM"
            let tStep = "12.50"
            
            var power = "1.0W"
            if ch.txPower == 6 { power = "2.0W" }
            if ch.txPower == 7 { power = "5.0W" }
            
            let line = "\(location),\(name),\(freq),\(duplex),\(offset),\(tone),\(rToneFreq),88.5,\(dtcsCode),NN,\(dtcsCode),Tone->Tone,\(mode),\(tStep),,\(power),,,,,"
            csvString += line + "\n"
        }
        
        try? csvString.write(to: url, atomically: true, encoding: .utf8)
        
        return CsvExportResult(duplicates: duplicates, url: url)
    }
}
