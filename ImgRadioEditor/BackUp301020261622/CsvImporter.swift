import Foundation

class CsvImporter {
    
    struct CsvRow {
        let name: String
        let frequency: Double
        let duplex: String
        let offset: Double
        let toneStr: String
        let rToneFreq: Double
        let powerStr: String
        let mode: String
    }
    
    static func parseCsv(_ url: URL) -> [CsvRow] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var rows: [CsvRow] = []
        
        let lines = content.components(separatedBy: .newlines)
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            
            let columns = line.components(separatedBy: ",")
            guard columns.count > 15 else { continue }
            
            let name = columns[1].trimmingCharacters(in: .whitespaces)
            let freqStr = columns[2].trimmingCharacters(in: .whitespaces)
            let duplex = columns[3].trimmingCharacters(in: .whitespaces)
            let offsetStr = columns[4].trimmingCharacters(in: .whitespaces)
            let toneStr = columns[5].trimmingCharacters(in: .whitespaces)
            let rToneStr = columns[6].trimmingCharacters(in: .whitespaces)
            let powerStr = columns[14].trimmingCharacters(in: .whitespaces)
            let mode = columns[12].trimmingCharacters(in: .whitespaces)
            
            if let freq = Double(freqStr) {
                let offset = Double(offsetStr) ?? 0
                let rTone = Double(rToneStr) ?? 0
                rows.append(CsvRow(
                    name: name, frequency: freq, duplex: duplex,
                    offset: offset, toneStr: toneStr,
                    rToneFreq: rTone, powerStr: powerStr, mode: mode
                ))
            }
        }
        return rows
    }
}
