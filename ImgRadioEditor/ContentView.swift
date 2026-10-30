import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var image = MemoryImage()
    @State private var selectedIndices = Set<Int>()
    @State private var hideEmptyChannels = false
    
    @State private var serialManager = SerialManager()
    @State private var isConnected = false
    @State private var showPortDialog = false
    
    // P3.15: единый флаг «занято» для download/upload и отдельный — для отключения
    @State private var isBusy = false
    @State private var isDisconnecting = false
    @State private var statusMessage = ""
    
    // Прогресс
    @State private var progress: Double = 0
    @State private var progressText: String = ""
    @State private var showProgress = false
    
    private let uploadRanges: [Range<Int>] = [0..<0x1D00, 0x1E00..<0x2000]

    private var totalBlocks: Int {
        uploadRanges.reduce(0) { $0 + $1.count / 0x80 }
    }
    
    var body: some View {
        HSplitView {
            // ЛЕВАЯ ПАНЕЛЬ
            VStack(spacing: 0) {
                HStack {
                    Label("Каналы", systemImage: "list.bullet")
                        .font(.headline)
                    Spacer()
                    
                    Toggle(isOn: $hideEmptyChannels) {
                        Image(systemName: hideEmptyChannels ? "eye.slash" : "eye")
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .help(hideEmptyChannels ? "Показать пустые каналы" : "Скрыть пустые каналы")
                    
                    Text("\(image.channels.filter { !$0.isEmpty }.count) / \(image.channels.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .windowBackgroundColor))
                
                Divider()
                
                List(selection: $selectedIndices) {
                    ForEach(displayedChannels) { channel in
                        ChannelRowView(channel: channel)
                            .tag(channel.index)
                            .contextMenu {
                                Button("Очистить канал") {
                                    clearChannel(index: channel.index)
                                }
                            }
                    }
                }
                .listStyle(.inset)
                
                // СТАТУС + ПРОГРЕСС
                VStack(spacing: 6) {
                    if showProgress {
                        VStack(spacing: 4) {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                            HStack(spacing: 8) {
                                Text(progressText)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                // P-D: отмена текущей операции
                                if isBusy {
                                    Button("Отмена") {
                                        serialManager.cancelOperation()
                                        statusMessage = "Отмена..."
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(minWidth: 300, maxWidth: 400)
            
            // ПРАВАЯ ПАНЕЛЬ
            if selectedIndices.count == 1,
               let idx = selectedIndices.first,
               idx > 0, idx <= image.channels.count {
                ChannelEditView(channel: $image.channels[idx - 1], isUV9K: image.radioModel == .uv9k)
            } else if selectedIndices.count > 1 {
                BulkEditView(
                    selectedCount: selectedIndices.count,
                    onApply: { power, bandwidth, s1, s2, s3 in
                        let indices = selectedIndices.map { $0 - 1 }
                        image.applyBulkEdit(to: Set(indices), power: power, bandwidth: bandwidth, scan1: s1, scan2: s2, scan3: s3)
                    },
                    onClear: {
                        let indices = selectedIndices.map { $0 - 1 }
                        image.clearBulk(to: Set(indices))
                        selectedIndices.removeAll()
                    }
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Выберите канал для редактирования")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: openFile) { Label("Открыть", systemImage: "folder") }
                    .disabled(isBusy || isDisconnecting)
                Button(action: importCsv) { Label("Импорт", systemImage: "square.and.arrow.down") }
                    .disabled(image.rawData == nil || isBusy || isDisconnecting)
                Button(action: sortChannels) { Label("Сортировать", systemImage: "arrow.up.arrow.down") }
                    .disabled(image.rawData == nil || isBusy || isDisconnecting)
                Button(action: exportCsv) { Label("Экспорт", systemImage: "square.and.arrow.up") }
                    .disabled(image.channels.isEmpty || isBusy || isDisconnecting)
                Button(action: exportFile) { Label("Сохранить", systemImage: "sdcard") }
                    .disabled(image.rawData == nil || isBusy || isDisconnecting || image.radioModel == .uv9k)
                    .help(image.radioModel == .uv9k ? "Сохранение KG-UV9K пока не поддерживается" : "Сохранить образ")
                
                Divider()
                
                Button(action: {
                    if isConnected {
                        disconnectRadio()
                    } else {
                        showPortDialog = true
                    }
                }) {
                    Label(isConnected ? "Отключить" : "Подключить",
                          systemImage: isConnected ? "cable.connector.slash" : "cable.connector")
                }
                .disabled(isBusy || isDisconnecting)
                
                if isConnected {
                    Button(action: downloadFromRadio) {
                        Label("Скачать", systemImage: "arrow.down.circle")
                    }
                    .disabled(isBusy || isDisconnecting || image.radioModel == .uv9k)
                    .help(image.radioModel == .uv9k ? "Serial для KG-UV9K пока не поддерживается" : "")

                    Button(action: uploadToRadio) {
                        Label("Залить", systemImage: "arrow.up.circle")
                    }
                    .disabled(isBusy || isDisconnecting || image.rawData == nil || image.radioModel == .uv9k)
                    .help(image.radioModel == .uv9k ? "Serial для KG-UV9K пока не поддерживается" : "")
                    
                }
            }
        }
        .sheet(isPresented: $showPortDialog) {
            PortSelectionView { portPath in
                if serialManager.connect(portPath: portPath) {
                    isConnected = true
                    statusMessage = "Порт открыт: \(portPath)"
                } else {
                    statusMessage = "Не удалось открыть порт"
                }
                showPortDialog = false
            }
        }
    }
    
    private var displayedChannels: [K5Channel] {
        if hideEmptyChannels {
            return image.channels.filter { !$0.isEmpty }
        } else {
            return image.channels
        }
    }
    
    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            guard let data = try? Data(contentsOf: url) else { return }
            
            // C: определяем тип дампа по размеру.
            // K5/K6 — 8192 байта (0x2000). UV9K — 32768+ (0x8000), CHIRP дописывает метаданные.
            if data.count == K5ImageParser.fileSize {
                image.radioModel = .k5
                image.rawData = data
                image.channels = K5ImageParser.parse(data)
                image.fileURL = url
                statusMessage = "Открыт образ K5/K6 (\(data.count) байт)"
            } else if data.count >= 0x8000 {
                image.radioModel = .uv9k
                image.rawData = data
                image.channels = WouxunParser.parse(data)
                image.fileURL = url
                statusMessage = "Открыт образ KG-UV9K (\(data.count) байт, \(image.channels.filter { !$0.isEmpty }.count) каналов)"
            } else {
                statusMessage = "Неизвестный формат: \(data.count) байт (ожидается 8192 или ≥32768)"
            }
        }
    }
    
    private func importCsv() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText, UTType.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        let csvRows = CsvImporter.parseCsv(url)
        if csvRows.isEmpty { return }
        
        var existingFreqs = Set<Double>()
        for ch in image.channels {
            if !ch.isEmpty {
                existingFreqs.insert(ch.rxFreq)
            }
        }
        
        var currentIndex = 0
        for row in csvRows {
            if existingFreqs.contains(row.frequency) { continue }
            
            while currentIndex < image.channels.count && !image.channels[currentIndex].isEmpty {
                currentIndex += 1
            }
            if currentIndex >= image.channels.count { break }
            
            var ch = image.channels[currentIndex]
            // B: лимит имени 15 символов (16-й байт — терминатор 0x00 в EEPROM).
            ch.name = String(row.name.prefix(15))
            ch.rxFreq = row.frequency
            
            if row.duplex == "+" {
                ch.offsetDir = 1
                ch.txFreq = row.frequency + row.offset
            } else if row.duplex == "-" {
                ch.offsetDir = 2
                ch.txFreq = row.frequency - row.offset
            } else {
                ch.offsetDir = 0
                ch.txFreq = row.frequency
            }
            
            if row.toneStr.contains("Tone") || row.toneStr.contains("TSQL") {
                ch.toneMode = 1
                ch.rxTone = row.rToneFreq
                ch.txTone = row.rToneFreq
            }
            
            if row.powerStr.contains("5.0") { ch.txPower = 7 }
            else if row.powerStr.contains("2.0") { ch.txPower = 6 }
            else { ch.txPower = 0 }
            
            ch.bandwidth = row.mode == "NFM" ? 1 : 0
            image.channels[currentIndex] = ch
            existingFreqs.insert(row.frequency)
            currentIndex += 1
        }
    }
    
    private func exportCsv() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.commaSeparatedText]
        panel.nameFieldStringValue = "channels.csv"
        if panel.runModal() == .OK, let url = panel.url {
            let result = CsvExporter.export(channels: image.channels, to: url)
            if result.duplicates.isEmpty {
                statusMessage = "Экспортировано в \(url.lastPathComponent)"
            } else {
                let list = result.duplicates.prefix(5).map { String(format: "%.4f", $0) }.joined(separator: ", ")
                let suffix = result.duplicates.count > 5 ? "…" : ""
                statusMessage = "⚠️ Дубликаты частот: \(list)\(suffix) (\(result.duplicates.count))"
            }
        }
    }
    
    private func sortChannels() {
        var activeChannels = image.channels.filter { !$0.isEmpty }
        activeChannels.sort { $0.rxFreq < $1.rxFreq }
        
        var newChannels: [K5Channel] = []
        for (i, var ch) in activeChannels.enumerated() {
            ch = K5Channel(
                index: i + 1, name: ch.name, rxFreq: ch.rxFreq, txFreq: ch.txFreq,
                offsetDir: ch.offsetDir, txPower: ch.txPower, bandwidth: ch.bandwidth,
                isScanlist1: ch.isScanlist1, isScanlist2: ch.isScanlist2, isScanlist3: ch.isScanlist3,
                rxTone: ch.rxTone, txTone: ch.txTone, toneMode: ch.toneMode
            )
            newChannels.append(ch)
        }
        for i in activeChannels.count..<image.channels.count {
            newChannels.append(K5Channel(
                index: i + 1, name: "", rxFreq: 0, txFreq: 0,
                offsetDir: 0, txPower: 0, bandwidth: 0,
                isScanlist1: false, isScanlist2: false, isScanlist3: false,
                rxTone: 0, txTone: 0, toneMode: 0
            ))
        }
        image.channels = newChannels
        selectedIndices.removeAll()
    }
    
    private func exportFile() {
        guard let original = image.rawData else { return }
        guard image.radioModel == .k5 else {
                statusMessage = "Сохранение KG-UV9K пока не поддерживается"
                return
            }
        let newData = K5ImageParser.serialize(channels: image.channels, originalData: original)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.data]
        panel.nameFieldStringValue = "uvk5_edited.img"
        if panel.runModal() == .OK, let url = panel.url {
            try? newData.write(to: url)
        }
    }
    
    private func clearChannel(index: Int) {
        guard index > 0, index <= image.channels.count else { return }
        image.channels[index - 1] = K5Channel(
            index: index, name: "", rxFreq: 0, txFreq: 0,
            offsetDir: 0, txPower: 0, bandwidth: 0,
            isScanlist1: false, isScanlist2: false, isScanlist3: false,
            rxTone: 0, txTone: 0, toneMode: 0
        )
    }
    
    // MARK: - Radio I/O
    
    private func downloadFromRadio() {
        guard isConnected, !isBusy, !isDisconnecting else { return }
        serialManager.resetAbort()
        isBusy = true
        showProgress = true
        progress = 0
        progressText = "Скачивание: 0%"
        statusMessage = "Скачивание..."
        
        let total = totalBlocks
        
        DispatchQueue.global(qos: .userInitiated).async {
            guard serialManager.startSession() else {
                guard image.radioModel == .k5 else {
                        statusMessage = "Serial для KG-UV9K пока не поддерживается"
                        return
                    }
                DispatchQueue.main.async {
                    statusMessage = serialManager.isAborting
                        ? "Скачивание отменено"
                        : "Ошибка: не удалось установить сессию"
                    isBusy = false
                    showProgress = false
                    progress = 0
                }
                return
            }
            
            var fullData = Data(count: K5ImageParser.fileSize)
            var doneBlocks = 0
            
            for range in uploadRanges {
                for offset in stride(from: range.lowerBound, to: range.upperBound, by: 0x80) {
                    if serialManager.isAborting {
                        DispatchQueue.main.async {
                            statusMessage = "Скачивание отменено"
                            isBusy = false
                            showProgress = false
                            progress = 0
                        }
                        return
                    }
                    guard let chunk = serialManager.readMemory(offset: UInt16(offset), length: 0x80) else {
                        DispatchQueue.main.async {
                            statusMessage = serialManager.isAborting
                                ? "Скачивание отменено"
                                : "Ошибка чтения на \(String(format: "0x%04X", offset))"
                            isBusy = false
                            showProgress = false
                            progress = 0
                        }
                        return
                    }
                    fullData.replaceSubrange(offset..<(offset + 0x80), with: chunk)
                    doneBlocks += 1
                    let frac = Double(doneBlocks) / Double(total)
                    // P-D: текущий адрес в progressText
                    let text = String(format: "Скачивание: %d%% (%d/%d) @ 0x%04X",
                                      Int(frac * 100), doneBlocks, total, offset)
                    DispatchQueue.main.async {
                        progress = frac
                        progressText = text
                    }
                }
            }
            
            DispatchQueue.main.async {
                image.rawData = fullData
                image.channels = K5ImageParser.parse(fullData)
                statusMessage = "Скачано \(fullData.count) байт"
                isBusy = false
                showProgress = false
                progress = 0
            }
        }
    }
    
    private func uploadToRadio() {
        guard isConnected, !isBusy, !isDisconnecting else { return }
        guard let original = image.rawData else { return }
        guard image.radioModel == .k5 else {
                statusMessage = "Serial для KG-UV9K пока не поддерживается"
                return
            }
        guard original.count >= K5ImageParser.fileSize else {
            statusMessage = "Ошибка: размер образа меньше \(K5ImageParser.fileSize) байт"
            return
        }
        
        let data = K5ImageParser.serialize(channels: image.channels, originalData: original)
        
        serialManager.resetAbort()
        isBusy = true
        showProgress = true
        progress = 0
        progressText = "Запись: 0%"
        statusMessage = "Запись..."
        
        let total = totalBlocks
        
        DispatchQueue.global(qos: .userInitiated).async {
            guard serialManager.startSession() else {
                DispatchQueue.main.async {
                    statusMessage = serialManager.isAborting
                        ? "Запись отменена"
                        : "Ошибка: не удалось установить сессию"
                    isBusy = false
                    showProgress = false
                    progress = 0
                }
                return
            }
            
            var doneBlocks = 0
            
            for range in uploadRanges {
                for offset in stride(from: range.lowerBound, to: range.upperBound, by: 0x80) {
                    if serialManager.isAborting {
                        DispatchQueue.main.async {
                            statusMessage = "Запись отменена"
                            isBusy = false
                            showProgress = false
                            progress = 0
                        }
                        return
                    }
                    let chunk = data.subdata(in: offset..<(offset + 0x80))
                    if !serialManager.writeMemory(offset: UInt16(offset), data: chunk) {
                        DispatchQueue.main.async {
                            statusMessage = serialManager.isAborting
                                ? "Запись отменена"
                                : "Ошибка записи на \(String(format: "0x%04X", offset))"
                            isBusy = false
                            showProgress = false
                            progress = 0
                        }
                        return
                    }
                    doneBlocks += 1
                    let frac = Double(doneBlocks) / Double(total)
                    let text = String(format: "Запись: %d%% (%d/%d) @ 0x%04X",
                                      Int(frac * 100), doneBlocks, total, offset)
                    DispatchQueue.main.async {
                        progress = frac
                        progressText = text
                    }
                }
            }
            
            let rebootOK = serialManager.rebootRadio()
            
            DispatchQueue.main.async {
                image.rawData = data
                if rebootOK {
                    statusMessage = "Запись завершена, рация перезагружена"
                } else {
                    statusMessage = "Запись завершена, но reboot не подтверждён"
                }
                isBusy = false
                showProgress = false
                progress = 0
            }
        }
    }
    
    /// Перезагружает рацию и закрывает порт, чтобы освободить /dev/cu.usb*.
    private func disconnectRadio() {
        guard isConnected, !isDisconnecting else { return }
        
        isDisconnecting = true
        statusMessage = "Отключение рации..."
        
        DispatchQueue.global(qos: .userInitiated).async {
            serialManager.rebootRadio()
            Thread.sleep(forTimeInterval: 0.5)
            serialManager.disconnect()
            
            DispatchQueue.main.async {
                isConnected = false
                isDisconnecting = false
                statusMessage = "Рация отключена, порт освобождён"
            }
        }
    }
}

// MARK: - ChannelRowView
struct ChannelRowView: View {
    let channel: K5Channel
    var body: some View {
        HStack(spacing: 8) {
            Text("\(channel.index)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .trailing)
            
            if channel.isEmpty {
                Image(systemName: "minus").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.5))
            } else if channel.name.hasPrefix("SOS") {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundColor(.red)
            } else if channel.name.hasPrefix("LPD") {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 10)).foregroundColor(.blue)
            } else if channel.name.hasPrefix("PMR") {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 10)).foregroundColor(.green)
            } else {
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundColor(.accentColor)
            }
            
            Text(channel.displayName).font(.system(size: 12, weight: channel.isEmpty ? .regular : .medium)).foregroundColor(channel.isEmpty ? .secondary : .primary).lineLimit(1)
            Spacer()
            if channel.toneMode > 0 { Image(systemName: "lock.fill").font(.system(size: 8)).foregroundColor(.orange) }
            Text(channel.isEmpty ? "—" : String(format: "%.3f", channel.rxFreq))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(channel.isEmpty ? .secondary : .accentColor)
                .frame(width: 85, alignment: .trailing).lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }.padding(.vertical, 2)
    }
}

// MARK: - ChannelEditView
struct ChannelEditView: View {
    
    @Binding var channel: K5Channel
    /// C: UV9K — скрываем блок тонов (несовместимая модель) и лимит имени 8.
    
    var isUV9K: Bool = false
    
    
    
    // P2.12: последние валидные значения — для отката при неверном вводе.
    @State private var lastValidRx: Double = 0
    @State private var lastValidTx: Double = 0
    // P2.12: флаги ошибок для подсветки полей.
    @State private var rxInvalid: Bool = false
    @State private var txInvalid: Bool = false
    
    
    // P2.12: допустимые диапазоны K5 (МГц).
    private static let freqRanges: [ClosedRange<Double>] = [
        136.0...174.0,
        400.0...470.0
    ]

    private static func isValidFreq(_ mhz: Double) -> Bool {
        guard mhz > 0 else { return false }
        return freqRanges.contains { $0.contains(mhz) }
    }

    private var rxFreqString: Binding<String> {
        Binding(
            get: { String(format: "%.3f", channel.rxFreq) },
            set: { newText in
                guard let val = Double(newText.replacingOccurrences(of: ",", with: ".")) else {
                    rxInvalid = true
                    return
                }
                guard Self.isValidFreq(val) else {
                    // P2.12: вне диапазона — подсветить и откатить к последнему валидному.
                    rxInvalid = true
                    return
                }
                rxInvalid = false
                lastValidRx = val
                channel.rxFreq = val
                if channel.offsetDir == 0 {
                    channel.txFreq = val
                    lastValidTx = val
                    txInvalid = false
                }
            }
        )
    }

    private var txFreqString: Binding<String> {
        Binding(
            get: { String(format: "%.3f", channel.txFreq) },
            set: { newText in
                guard let val = Double(newText.replacingOccurrences(of: ",", with: ".")) else {
                    txInvalid = true
                    return
                }
                guard Self.isValidFreq(val) else {
                    txInvalid = true
                    return
                }
                txInvalid = false
                lastValidTx = val
                channel.txFreq = val
                if channel.offsetDir == 0 {
                    channel.rxFreq = val
                    lastValidRx = val
                    rxInvalid = false
                }
            }
        )
    }

    private var txCtcssIndex: Binding<Int> {
        Binding(
            get: {
                if let idx = K5ImageParser.ctcssTones.firstIndex(of: channel.txTone) { return idx }
                return 0
            },
            set: { channel.txTone = K5ImageParser.ctcssTones[$0] }
        )
    }

    private var rxCtcssIndex: Binding<Int> {
        Binding(
            get: {
                if let idx = K5ImageParser.ctcssTones.firstIndex(of: channel.rxTone) { return idx }
                return 0
            },
            set: { channel.rxTone = K5ImageParser.ctcssTones[$0] }
        )
    }

    private var txDcsIndex: Binding<Int> {
        Binding(
            get: {
                let code = Int(channel.txTone)
                if let idx = K5ImageParser.dcsCodes.firstIndex(of: code) { return idx }
                return 0
            },
            set: { channel.txTone = Double(K5ImageParser.dcsCodes[$0]) }
        )
    }

    private var rxDcsIndex: Binding<Int> {
        Binding(
            get: {
                let code = Int(channel.rxTone)
                if let idx = K5ImageParser.dcsCodes.firstIndex(of: code) { return idx }
                return 0
            },
            set: { channel.rxTone = Double(K5ImageParser.dcsCodes[$0]) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Канал \(channel.index)").font(.title2).fontWeight(.semibold)
                        Text(channel.isEmpty ? "Пустой канал" : "Активный канал")
                            .font(.caption)
                            .foregroundColor(channel.isEmpty ? .secondary : .green)
                    }
                    Spacer()
                    if !channel.isEmpty {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.title)
                            .foregroundColor(.accentColor)
                    }
                }.padding(.bottom, 4)

                Divider()

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Имя", systemImage: "textformat").frame(width: 100, alignment: .leading)
                            TextField("Имя канала", text: $channel.name)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: channel.name) { _, newValue in
                                    let maxLen = isUV9K ? 8 : 15
                                        if newValue.count > maxLen {
                                            channel.name = String(newValue.prefix(maxLen))
                                        }
                                    }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Label("Приём", systemImage: "arrow.down").frame(width: 100, alignment: .leading)
                                TextField("МГц", text: rxFreqString)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(rxInvalid ? Color.red : Color.clear, lineWidth: 1)
                                    )
                                Text("МГц").foregroundColor(.secondary)
                            }
                            if rxInvalid {
                                Text("Допустимо: 136–174 или 400–470 МГц")
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .padding(.leading, 108)
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Label("Передача", systemImage: "arrow.up").frame(width: 100, alignment: .leading)
                                TextField("МГц", text: txFreqString)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(txInvalid ? Color.red : Color.clear, lineWidth: 1)
                                    )
                                Text("МГц").foregroundColor(.secondary)
                            }
                            if txInvalid {
                                Text("Допустимо: 136–174 или 400–470 МГц")
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .padding(.leading, 108)
                            }
                        }
                    }.padding(8)
                } label: { Label("Основное", systemImage: "info.circle") }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Мощность", systemImage: "bolt.fill").frame(width: 100, alignment: .leading)
                            Picker("", selection: $channel.txPower) {
                                Text("LOW").tag(0)
                                Text("MID").tag(6)
                                Text("HIGH").tag(7)
                            }.pickerStyle(.segmented)
                        }
                        HStack {
                            Label("Ширина", systemImage: "arrow.left.and.right").frame(width: 100, alignment: .leading)
                            Picker("", selection: $channel.bandwidth) {
                                Text("Wide (12.5)").tag(0)
                                Text("Narrow (6.25)").tag(1)
                            }.pickerStyle(.segmented)
                        }
                    }.padding(8)
                } label: { Label("Настройки", systemImage: "slider.horizontal.3") }

                if !isUV9K {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label("Режим", systemImage: "lock.fill").frame(width: 100, alignment: .leading)
                                Picker("", selection: $channel.toneMode) {
                                    Text("OFF").tag(0)
                                    Text("CTCSS").tag(1)
                                    Text("DCS").tag(2)
                                }
                                .pickerStyle(.segmented)
                                .onChange(of: channel.toneMode) { _, newMode in
                                    if newMode == 1 {
                                        if !K5ImageParser.ctcssTones.contains(channel.txTone) {
                                            channel.txTone = K5ImageParser.ctcssTones[0]
                                        }
                                        if !K5ImageParser.ctcssTones.contains(channel.rxTone) {
                                            channel.rxTone = K5ImageParser.ctcssTones[0]
                                        }
                                    } else if newMode == 2 {
                                        if !K5ImageParser.dcsCodes.contains(Int(channel.txTone)) {
                                            channel.txTone = Double(K5ImageParser.dcsCodes[0])
                                        }
                                        if !K5ImageParser.dcsCodes.contains(Int(channel.rxTone)) {
                                            channel.rxTone = Double(K5ImageParser.dcsCodes[0])
                                        }
                                    }
                                }
                            }
                            
                            if channel.toneMode == 1 {
                                HStack {
                                    Label("TX CTCSS", systemImage: "waveform").frame(width: 100, alignment: .leading)
                                    Picker("", selection: txCtcssIndex) {
                                        ForEach(0..<K5ImageParser.ctcssTones.count, id: \.self) { i in
                                            Text(String(format: "%.1f Гц", K5ImageParser.ctcssTones[i])).tag(i)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 140)
                                }
                                HStack {
                                    Label("RX CTCSS", systemImage: "waveform.path").frame(width: 100, alignment: .leading)
                                    Picker("", selection: rxCtcssIndex) {
                                        ForEach(0..<K5ImageParser.ctcssTones.count, id: \.self) { i in
                                            Text(String(format: "%.1f Гц", K5ImageParser.ctcssTones[i])).tag(i)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 140)
                                }
                            } else if channel.toneMode == 2 {
                                HStack {
                                    Label("TX DCS", systemImage: "number").frame(width: 100, alignment: .leading)
                                    Picker("", selection: txDcsIndex) {
                                        ForEach(0..<K5ImageParser.dcsCodes.count, id: \.self) { i in
                                            Text(String(format: "%03d", K5ImageParser.dcsCodes[i])).tag(i)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 100)
                                }
                                HStack {
                                    Label("RX DCS", systemImage: "number.circle").frame(width: 100, alignment: .leading)
                                    Picker("", selection: rxDcsIndex) {
                                        ForEach(0..<K5ImageParser.dcsCodes.count, id: \.self) { i in
                                            Text(String(format: "%03d", K5ImageParser.dcsCodes[i])).tag(i)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 100)
                                }
                            }
                        }.padding(8)
                    } label: { Label("Тоны", systemImage: "waveform") }}

                GroupBox {
                    HStack(spacing: 20) {
                        Toggle("List 1", isOn: $channel.isScanlist1)
                        Toggle("List 2", isOn: $channel.isScanlist2)
                        Toggle("List 3", isOn: $channel.isScanlist3)
                        Spacer()
                    }.padding(8)
                } label: { Label("Сканирование", systemImage: "arrow.triangle.2.circlepath") }
            }.padding(20)
        }
        .onAppear {
            lastValidRx = channel.rxFreq
            lastValidTx = channel.txFreq
            rxInvalid = false
            txInvalid = false
        }
        .onChange(of: channel.index) { _, _ in
            // P2.12: при переключении канала сбрасываем состояние валидации.
            lastValidRx = channel.rxFreq
            lastValidTx = channel.txFreq
            rxInvalid = false
            txInvalid = false
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
    }
}

// MARK: - BulkEditView
struct BulkEditView: View {
    let selectedCount: Int
    let onApply: (Int?, Int?, Bool?, Bool?, Bool?) -> Void
    let onClear: () -> Void
    @State private var power: Int? = nil
    @State private var bandwidth: Int? = nil
    @State private var s1: Bool? = nil
    @State private var s2: Bool? = nil
    @State private var s3: Bool? = nil

    var body: some View {
        Form {
            Section("Массовое редактирование (\(selectedCount) каналов)") {
                Picker("Мощность", selection: $power) { Text("Не менять").tag(Int?.none); Text("LOW").tag(Int?.some(0)); Text("MID").tag(Int?.some(6)); Text("HIGH").tag(Int?.some(7)) }
                Picker("Ширина", selection: $bandwidth) { Text("Не менять").tag(Int?.none); Text("Wide").tag(Int?.some(0)); Text("Narrow").tag(Int?.some(1)) }
            }
            Section("Сканирование") {
                Picker("List 1", selection: $s1) { Text("Не менять").tag(Bool?.none); Text("Вкл").tag(Bool?.some(true)); Text("Выкл").tag(Bool?.some(false)) }
                Picker("List 2", selection: $s2) { Text("Не менять").tag(Bool?.none); Text("Вкл").tag(Bool?.some(true)); Text("Выкл").tag(Bool?.some(false)) }
                Picker("List 3", selection: $s3) { Text("Не менять").tag(Bool?.none); Text("Вкл").tag(Bool?.some(true)); Text("Выкл").tag(Bool?.some(false)) }
            }
            HStack { Button("Применить") { onApply(power, bandwidth, s1, s2, s3) }.buttonStyle(.borderedProminent); Spacer(); Button("Очистить каналы", role: .destructive) { onClear() } }.padding(.top)
        }.padding()
    }
}

// MARK: - PortSelectionView
struct PortSelectionView: View {
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ports: [String] = []
    @State private var selected: String?
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label("Доступные порты", systemImage: "cable.connector")
                    .font(.headline)
                Spacer()
                Button {
                    refreshPorts()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Обновить список")
            }

            if ports.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cable.connector.slash")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Порты не найдены")
                        .foregroundColor(.secondary)
                    Text("Подключите рацию USB-кабелем и нажмите «Обновить»")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(ports, id: \.self) { port in
                            PortRow(port: port, selected: selected == port) {
                                selected = port
                            }
                        }
                    }
                }
                .frame(maxHeight: 240)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .cornerRadius(8)
            }

            HStack {
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Подключиться") {
                    if let p = selected {
                        onSelect(p)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            refreshPorts()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                refreshPorts()
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func refreshPorts() {
        let found = SerialPort.listPorts()
        if found != ports {
            ports = found
            if let s = selected, !ports.contains(s) {
                selected = ports.first
            } else if selected == nil {
                selected = ports.first
            }
        }
    }
}

// MARK: - PortRow
private struct PortRow: View {
    let port: String
    let selected: Bool
    let onTap: () -> Void

    private var shortName: String {
        (port as NSString).lastPathComponent
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortName)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.primary)
                    Text(port)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.15) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}
