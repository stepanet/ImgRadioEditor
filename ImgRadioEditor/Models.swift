import Combine
import Foundation

struct K5Channel: Identifiable, Hashable {
    var id: Int { index }
    let index: Int
    var name: String
    var rxFreq: Double
    var txFreq: Double
    var offsetDir: Int     // 0 - none, 1 - plus, 2 - minus
    var txPower: Int
    var bandwidth: Int
    var isScanlist1: Bool
    var isScanlist2: Bool
    var isScanlist3: Bool
    
    // Тоны
    var rxTone: Double     // Для CTCSS - Гц, для DCS - код (например 23)
    var txTone: Double
    var toneMode: Int      // 0 - None, 1 - CTCSS, 2 - DCS
    
    var isEmpty: Bool {
        // P3.13: пусто = rxFreq == 0 (очищено) или raw == 0xFFFFFFFF (эквивалент 42949.67295).
        return rxFreq == 0 || rxFreq == Double(K5ImageParser.emptyFreqRaw) * 10.0 / 1_000_000.0
    }
    
    var displayName: String {
        name.isEmpty ? "<Без имени>" : name
    }
    
    // Для отображения тона в списке
    var toneString: String {
        if toneMode == 1 { return String(format: "CT %.1f", txTone) }
        if toneMode == 2 { return String(format: "DCS %03d", Int(txTone)) }
        return ""
    }
}

/// P3.4: @MainActor — все обращения к channels/rawData/fileURL
/// происходят на главном потоке. UI-биндинги в ContentView уже main.
/// Из фоновых задач (downloadFromRadio/uploadToRadio) изменения
/// делаются через DispatchQueue.main.async — это совместимо.
@MainActor
final class MemoryImage: ObservableObject {
    @Published var channels: [K5Channel] = []
    var rawData: Data? = nil
    var fileURL: URL? = nil
    
    // Массовое редактирование
    func applyBulkEdit(to indices: Set<Int>, power: Int?, bandwidth: Int?, scan1: Bool?, scan2: Bool?, scan3: Bool?) {
        for i in indices {
            guard i >= 0 && i < channels.count else { continue }
            if let p = power { channels[i].txPower = p }
            if let b = bandwidth { channels[i].bandwidth = b }
            if let s1 = scan1 { channels[i].isScanlist1 = s1 }
            if let s2 = scan2 { channels[i].isScanlist2 = s2 }
            if let s3 = scan3 { channels[i].isScanlist3 = s3 }
        }
    }
    
    // Массовая очистка
    func clearBulk(to indices: Set<Int>) {
        for i in indices {
            guard i >= 0 && i < channels.count else { continue }
            channels[i] = K5Channel(
                index: channels[i].index, name: "", rxFreq: 0, txFreq: 0,
                offsetDir: 0, txPower: 0, bandwidth: 0,
                isScanlist1: false, isScanlist2: false, isScanlist3: false,
                rxTone: 0, txTone: 0, toneMode: 0
            )
        }
    }
}
