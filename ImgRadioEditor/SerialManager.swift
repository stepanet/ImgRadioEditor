import Foundation

class SerialManager {
    private var port = SerialPort()

    private let xorKey: [UInt8] = [22, 108, 20, 230, 46, 145, 13, 64, 33, 53, 213, 64, 19, 3, 233, 128]
    /// Фиксированный session ID, как в k5prog (Constants.swift: K5.sessionID).
    private let sessionID: [UInt8] = [0x6A, 0x39, 0x57, 0x64]

    // P2.10: таймауты вынесены в константы
    private let sessionTimeout: TimeInterval = 3.0
    private let readTimeout: TimeInterval = 3.0
    private let writeTimeout: TimeInterval = 3.0
    /// Пауза между опросами RX, микросекунды (usleep).
    private let pollIntervalUs: UInt32 = 1000

    // Накопительный буфер принятых байт (как m_rx_buffer в k5prog)
    private var rxBuffer: [UInt8] = []

    /// Открыт ли порт (для UI).
    var isConnected: Bool { port.connected }
    
    /// P-D: идёт ли отмена (для UI/циклов).
    var isAborting: Bool { port.isAborting }

    /// P-D: прервать текущую операцию (вызывается из UI).
    func cancelOperation() {
        port.requestAbort()
    }

    /// P-D: сбросить флаг отмены перед новой операцией.
    func resetAbort() {
        port.clearAbort()
    }

    // MARK: - Connection

    func connect(portPath: String) -> Bool {
        let res = port.connect(path: portPath, baudRate: 38400)
        if res != 0 {
            print("Ошибка открытия порта: \(res)")
            return false
        }
        print("Порт открыт: \(portPath)")
        Thread.sleep(forTimeInterval: 0.5)
        return true
    }

    func disconnect() {
        port.disconnect()
    }

    // MARK: - Session

    /// Отправляет hello с фиксированным session ID (как k5prog).
    func startSession() -> Bool {
        var payload: [UInt8] = [0x14, 0x05, 0x04, 0x00]
        payload.append(contentsOf: sessionID)

        sendFrame(payload)

        let deadline = Date().addingTimeInterval(sessionTimeout)
        while Date() < deadline {
            if !port.connected {                      // P0.3
                print("startSession: порт отключён во время ожидания")
                return false
            }
            if let packet = nextPacket() {
                print("HELLO RX[\(packet.count)]: \(packet.map { String(format: "%02x", $0) }.joined(separator: " "))")
                if let body = extractBody(packet), body.count >= 2,
                   body[0] == 0x15, body[1] == 0x05 {
                    print("Сессия установлена, session: \(sessionID.map { String(format: "%02X", $0) }.joined())")
                    Thread.sleep(forTimeInterval: 0.1)
                    return true
                }
            }
            usleep(pollIntervalUs)                     // P2.10: без Thread.sleep
        }
        print("Hello: таймаут")
        return false
    }

    // MARK: - EEPROM Read

    func readMemory(offset: UInt16, length: UInt8) -> Data? {
        var payload: [UInt8] = [0x1B, 0x05, 0x08, 0x00]
        payload.append(contentsOf: withUnsafeBytes(of: offset.littleEndian) { Array($0) })
        payload.append(length)
        payload.append(0x00)
        payload.append(contentsOf: sessionID)

        sendFrame(payload)

        let deadline = Date().addingTimeInterval(readTimeout)
        var firstPacketLogged = false

        while Date() < deadline {
            if !port.connected {                      // P0.3
                print("readMemory: порт отключён во время ожидания")
                return nil
            }
            if let packet = nextPacket() {
                if !firstPacketLogged {
                    print("READ[\(String(format: "0x%04X", offset))] RX[\(packet.count)]: \(packet.map { String(format: "%02x", $0) }.joined(separator: " "))")
                    firstPacketLogged = true
                }
                if let data = parseReadReply(packet, expectedOffset: offset, length: length) {
                    return data
                }
            }
            usleep(pollIntervalUs)
        }
        print("ReadMemory: таймаут на \(String(format: "0x%04X", offset))\(firstPacketLogged ? "" : " (ответа не было)")")
        return nil
    }

    // MARK: - EEPROM Write

    func writeMemory(offset: UInt16, data: Data) -> Bool {
        let length = data.count
        guard length > 0, length <= 128, length % 8 == 0 else {
            print("WriteMemory: неверная длина \(length), должна быть кратна 8 и ≤ 128")
            return false
        }

        // Формат как в k5prog k5_write_eeprom():
        // [1D 05] [body_len_lo body_len_hi] [offset_lo offset_hi] [len] [0x01 allow-password]
        // [sessionID(4)] [data...]
        // body_len = 2 (offset) + 2 (len-поле) + 4 (session) + length = 8 + length
        var payload: [UInt8] = [0x1D, 0x05]
        let bodyLen = UInt16(8 + length)
        payload.append(contentsOf: withUnsafeBytes(of: bodyLen.littleEndian) { Array($0) })
        payload.append(contentsOf: withUnsafeBytes(of: offset.littleEndian) { Array($0) })
        payload.append(UInt8(length & 0xFF))
        payload.append(0x01)               // allow password (k5prog: b[7] = 0x01)
        payload.append(contentsOf: sessionID)
        payload.append(contentsOf: data)

        sendFrame(payload)

        let deadline = Date().addingTimeInterval(writeTimeout)
        var firstPacketLogged = false

        while Date() < deadline {
            if !port.connected {                      // P0.3
                print("writeMemory: порт отключён во время ожидания")
                return false
            }
            if let packet = nextPacket() {
                if !firstPacketLogged {
                    print("WRITE[\(String(format: "0x%04X", offset))] RX[\(packet.count)]: \(packet.map { String(format: "%02x", $0) }.joined(separator: " "))")
                    firstPacketLogged = true
                }
                if let body = extractBody(packet), body.count >= 6,
                   body[0] == 0x1E, body[1] == 0x05 {
                    let respOffset = UInt16(body[4]) | (UInt16(body[5]) << 8)
                    if respOffset == offset {
                        return true
                    }
                }
            }
            usleep(pollIntervalUs)
        }
        print("WriteMemory: таймаут на \(String(format: "0x%04X", offset))\(firstPacketLogged ? "" : " (ответа не было)")")
        return false
    }


    // MARK: - Reboot

    /// Команда сброса/перезагрузки рации: тело пустое, только opcode 0xDD 0x05.
    /// После записи EEPROM рация должна перечитать память, иначе изменения не видны.
    /// Ответа нет — рация просто перезагружается. Возвращает true, если кадр отправлен.
    @discardableResult
    func rebootRadio() -> Bool {
        guard port.connected else {
            print("rebootRadio: порт не открыт")
            return false
        }
        let payload: [UInt8] = [0xDD, 0x05, 0x00, 0x00]
        print("REBOOT TX: \(payload.map { String(format: "%02x", $0) }.joined(separator: " "))")
        let sent = sendFrame(payload)
        // Дать рации время уйти в reset, а UART — опустеть.
        Thread.sleep(forTimeInterval: 0.3)
        return sent
    }

    // MARK: - RX accumulator (аналог RxEngine в k5prog)

    /// Читает из порта всё, что доступно, добавляет в накопительный буфер.
    private func pump() {
        var scratch = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = port.rxBytes(into: &scratch, max: 1024)
            if n <= 0 { break }
            rxBuffer.append(contentsOf: scratch[0..<n])
        }
    }

    /// Извлекает из накопительного буфера один целый пакет AB CD ... DC BA.
    private func nextPacket() -> [UInt8]? {
        pump()

        while rxBuffer.count >= 8 {
            if rxBuffer[0] != 0xAB || rxBuffer[1] != 0xCD {
                if let idx = rxBuffer.dropFirst().firstIndex(of: 0xAB) {
                    print("nextPacket: мусор \(idx + 1) байт выброшен")
                    rxBuffer.removeFirst(idx + 1)
                    continue
                } else {
                    print("nextPacket: мусор \(rxBuffer.count) байт выброшен (нет 0xAB)")
                    rxBuffer.removeAll()
                    return nil
                }
            }

            let len = Int(rxBuffer[2]) | (Int(rxBuffer[3]) << 8)
            if len > 512 {
                rxBuffer.removeFirst()
                continue
            }

            // [AB CD len_lo len_hi] + [xor(payload + CRC16)] + [DC BA]
            let fullLen = 4 + (len + 2) + 2
            if rxBuffer.count < fullLen { return nil }

            if rxBuffer[fullLen - 2] != 0xDC || rxBuffer[fullLen - 1] != 0xBA {
                rxBuffer.removeFirst()
                continue
            }

            let packet = Array(rxBuffer[0..<fullLen])
            rxBuffer.removeFirst(fullLen)
            return packet
        }
        return nil
    }

    // MARK: - Frame Layer

    private func drainRX() {
        var scratch = [UInt8](repeating: 0, count: 1024)
        var total = 0
        while true {
            let n = port.rxBytes(into: &scratch, max: 1024)
            if n <= 0 { break }
            total += n
        }
        let stale = rxBuffer.count
        rxBuffer.removeAll()
        if total > 0 || stale > 0 {
            print("drainRX: выброшено UART=\(total), накоплено=\(stale)")
        }
    }

    @discardableResult
    private func sendFrame(_ payload: [UInt8]) -> Bool {
        drainRX()

        let crc = calculateCRC16(payload)
        var data2 = payload
        data2.append(contentsOf: withUnsafeBytes(of: crc.littleEndian) { Array($0) })
        xorPayload(&data2)

        var frame: [UInt8] = [0xAB, 0xCD]
        let len = UInt16(payload.count)
        frame.append(contentsOf: withUnsafeBytes(of: len.littleEndian) { Array($0) })
        frame.append(contentsOf: data2)
        frame.append(contentsOf: [0xDC, 0xBA])

        print("TX: \(frame.map { String(format: "%02x", $0) }.joined(separator: " "))")
        let written = port.txBytes(frame)
        return written > 0
    }
    
    private func extractBody(_ packet: [UInt8]) -> [UInt8]? {
        guard packet.count >= 8, packet[0] == 0xAB, packet[1] == 0xCD else { return nil }
        let len = Int(packet[2]) | (Int(packet[3]) << 8)
        guard packet.count >= 4 + len + 2 + 2 else { return nil }

        var raw = Array(packet[4..<(4 + len + 2)])
        xorPayload(&raw)

        guard raw.count > 2 else { return nil }
        return Array(raw.dropLast(2))
    }

    private func parseReadReply(_ packet: [UInt8], expectedOffset: UInt16, length: UInt8) -> Data? {
        guard packet.count >= 8, packet[0] == 0xAB, packet[1] == 0xCD else { return nil }
        let len = Int(packet[2]) | (Int(packet[3]) << 8)
        guard packet.count >= 4 + len + 2 + 2 else { return nil }

        var body = Array(packet[4..<(4 + len + 2)])
        xorPayload(&body)

        guard body.count >= 2 else { return nil }
        body = Array(body.dropLast(2))

        guard body.count >= 8 + Int(length),
              body[0] == 0x1C, body[1] == 0x05 else { return nil }

        let respOffset = UInt16(body[4]) | (UInt16(body[5]) << 8)
        guard respOffset == expectedOffset else { return nil }

        return Data(body[8..<(8 + Int(length))])
    }

    private func xorPayload(_ data: inout [UInt8]) {
        for i in 0..<data.count {
            data[i] ^= xorKey[i % xorKey.count]
        }
    }

    private func calculateCRC16(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if (crc & 0x8000) != 0 { crc = (crc << 1) ^ 0x1021 } else { crc <<= 1 }
            }
        }
        return crc
    }
}
