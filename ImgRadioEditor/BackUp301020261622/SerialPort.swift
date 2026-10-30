import Foundation
import Darwin

public final class SerialPort {
    private var fd: Int32 = -1
    private let lock = NSLock()
    private var _connected = false
    private var abortRequested = false

    public init() {}
    
    public var isAborting: Bool {
        lock.lock(); defer { lock.unlock() }
        return abortRequested
    }

    public func requestAbort() {
        lock.lock(); abortRequested = true; lock.unlock()
    }

    public func clearAbort() {
        lock.lock(); abortRequested = false; lock.unlock()
    }

    public var connected: Bool {
        lock.lock(); defer { lock.unlock() }
        return _connected && !abortRequested
    }


    public static func listPorts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.usb") }.sorted().map { "/dev/" + $0 }
    }

    public func connect(path: String, baudRate: Int) -> Int32 {
        disconnect()

        let h = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        if h < 0 { return errno }

        if ioctl(h, TIOCEXCL) != 0 {
            let e = errno; close(h); return e
        }

        var t = termios()
        if tcgetattr(h, &t) != 0 {
            let e = errno; close(h); return e
        }
        cfmakeraw(&t)
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(CSIZE | PARENB | CSTOPB | CRTSCTS)
        t.c_cflag |= tcflag_t(CS8)
        t.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY | INPCK | ISTRIP | PARMRK)
        t.c_iflag |= tcflag_t(IGNBRK)
        withUnsafeMutableBytes(of: &t.c_cc) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 0
        }
        cfsetspeed(&t, speed_t(baudRate))
        
        if tcsetattr(h, TCSANOW, &t) != 0 {
            cfsetspeed(&t, speed_t(B9600))
            _ = tcsetattr(h, TCSANOW, &t)
            var speed = speed_t(baudRate)
            _ = ioctl(h, SerialPort.IOSSIOSPEED, &speed)
        }

        var bits: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = ioctl(h, TIOCMBIS, &bits)

        tcflush(h, TCIOFLUSH)

        lock.lock()
        fd = h
        _connected = true
        abortRequested = false
        lock.unlock()
        return 0
    }

    public func disconnect() {
        lock.lock()
        let h = fd
        fd = -1
        _connected = false
        lock.unlock()
        guard h >= 0 else { return }
        tcdrain(h)
        var bits: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = ioctl(h, TIOCMBIC, &bits)
        _ = ioctl(h, TIOCNXCL)
        close(h)
    }

    public func rxBytes(into buf: inout [UInt8], max: Int) -> Int {
        guard connected, max > 0 else { return connected ? 0 : -1 }
        lock.lock(); let h = fd; lock.unlock()
        if h < 0 { return -1 }
        if buf.count < max { buf = [UInt8](repeating: 0, count: max) }
        let n = buf.withUnsafeMutableBytes { read(h, $0.baseAddress, max) }
        if n < 0 {
            if errno == EAGAIN || errno == EINTR { return 0 }
            return -1
        }
        return n
    }

    public func txBytes(_ data: [UInt8]) -> Int {
        guard connected else { return 0 }
        lock.lock(); let h = fd; lock.unlock()
        if h < 0 { return 0 }
        var sent = 0
        let deadline = Date().addingTimeInterval(5)
        while sent < data.count {
            let n = data.withUnsafeBytes { raw -> Int in
                write(h, raw.baseAddress!.advanced(by: sent), data.count - sent)
            }
            if n > 0 {
                sent += n
                continue
            }
            if n < 0 && errno != EAGAIN && errno != EINTR { break }
            if Date() > deadline || !connected { break }
            var p = pollfd(fd: h, events: Int16(POLLOUT), revents: 0)
            _ = poll(&p, 1, 10)
        }
        return sent
    }

    static let IOSSIOSPEED: UInt = 0x8008_5402
}
