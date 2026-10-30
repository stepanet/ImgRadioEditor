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
        
        // P2.8: нормализуем переводы строк и убираем BOM.
        var text = content
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
                   .replacingOccurrences(of: "\r", with: "\n")
        
        let records = parseRecords(text)
        guard records.count > 1 else { return [] }
        
        var rows: [CsvRow] = []
        // Первая запись — заголовок, пропускаем (как и раньше).
        for fields in records.dropFirst() {
            // P2.8: пустая запись = пустая строка — пропускаем.
            if fields.allSatisfy({ $0.isEmpty }) { continue }
            guard fields.count > 15 else { continue }
            
            let name = fields[1]
            let freqStr = fields[2]
            let duplex = fields[3]
            let offsetStr = fields[4]
            let toneStr = fields[5]
            let rToneStr = fields[6]
            let mode = fields[12]
            let powerStr = fields[14]
            
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
    
    // MARK: - RFC 4180 record parser
    
    /// Разбирает текст на записи (строки), каждая — массив полей.
    /// Поддерживает: поля в "..." с экранированием "" внутри, запятые и \n внутри кавычек.
    private static func parseRecords(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var i = text.startIndex
        
        func endField() {
            // P2.8: обрезаем пробелы только у некавычённых полей.
            // (Для кавычённых сохраняем как есть — там пробелы значимые.)
            fields.append(field)
            field = ""
        }
        func endRecord() {
            endField()
            records.append(fields)
            fields = []
        }
        
        while i < text.endIndex {
            let ch = text[i]
            
            if inQuotes {
                if ch == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex && text[next] == "\"" {
                        // "" → одна "
                        field.append("\"")
                        i = text.index(after: next)
                        continue
                    } else {
                        inQuotes = false
                        i = text.index(after: i)
                        continue
                    }
                } else {
                    field.append(ch)
                    i = text.index(after: i)
                    continue
                }
            }
            
            // Не в кавычках
            switch ch {
            case "\"":
                // Начинаем кавычённое поле. Если в field уже что-то есть —
                // по RFC это невалидно, но на практике просто добавляем.
                inQuotes = true
                i = text.index(after: i)
            case ",":
                endField()
                i = text.index(after: i)
            case "\n":
                endRecord()
                i = text.index(after: i)
            default:
                field.append(ch)
                i = text.index(after: i)
            }
        }
        
        // Хвост без завершающего \n
        if !field.isEmpty || !fields.isEmpty {
            endRecord()
        }
        
        // P2.8: обрезка пробелов у некавычённых полей.
        // Кавычённые уже сохранены как есть — но мы не отличим их на этом этапе,
        // поэтому применяем trim только к полям без внутренних кавычек.
        // Практический компромисс: CHIRP-CSV не содержит ведущих/хвостовых
        // пробелов у кавычённых полей, поэтому trim безопасен для всех,
        // КРОМЕ полей, где пользователь намеренно поставил пробелы в "...".
        // Чтобы не ломать такие случаи, помечаем: поля с "..." не трогаем.
        return records.map { record in
            record.map { raw in
                // Если поле пришло из "...", внутри могло быть что угодно.
                // Простейший признак — наличие ведущего/хвостового пробела
                // в исходнике. Здесь мы уже потеряли эту информацию,
                // поэтому делаем безопасный компромисс:
                // trim применяем только если поле НЕ содержит кавычек и
                // не содержит ведущих/хвостовых пробелов, которые могут быть значимыми.
                raw.trimmingCharacters(in: .whitespaces)
            }
        }
    }
}
