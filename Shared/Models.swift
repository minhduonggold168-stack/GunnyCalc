import CoreGraphics
import Darwin
import Foundation

/// Quy đổi khung chuẩn hóa gốc trên-trái (`0.0 - 1.0`, Top-Left) sang tọa độ pixel CoreImage gốc dưới-trái (Bottom-Left).
public func ciRectFromTopLeft(normRect: CGRect, imageWidth: CGFloat, imageHeight: CGFloat) -> CGRect {
    let x = normRect.origin.x * imageWidth
    let w = normRect.size.width * imageWidth
    let h = normRect.size.height * imageHeight
    let y = (1.0 - normRect.origin.y - normRect.size.height) * imageHeight
    return CGRect(x: x, y: y, width: w, height: h).integral
}

/// 2 vùng quét cố định (tọa độ chuẩn hóa Top-Left `0.0 - 1.0`) cho Gunny Mobi bản không gió.
public enum GunnyROIs {
    /// Vùng cắt Minimap chuẩn cho phân cụm HSV, đo khung camera trắng và trích xuất địa hình 32 cột.
    public static let minimapStrip = CGRect(x: 0.848, y: 0.042, width: 0.148, height: 0.114)
    /// Vùng chiến trường nửa trên chứa chữ `Góc XX°` cạnh nhân vật.
    public static let angleBattlefield = CGRect(x: 0.050, y: 0.140, width: 0.820, height: 0.540)
}

/// Gói dữ liệu siêu nhẹ truyền thời gian thực 30 FPS qua BSD UDP (`127.0.0.1:45678`).
public struct TelemetryData: Codable, Equatable, Sendable {
    public var frameId: Int
    public var angle: Int
    public var power: Double
    public var isBlocked: Bool
    public var suggestedAngle: Int

    public init(
        frameId: Int = 0,
        angle: Int = 50,
        power: Double = 48.0,
        isBlocked: Bool = false,
        suggestedAngle: Int = 50
    ) {
        self.frameId = max(frameId, 0)
        self.angle = min(max(angle, -35), 85)
        let clampedPower = power.isFinite ? min(max(power, 0.0), 100.0) : 0.0
        self.power = (clampedPower * 10.0).rounded() / 10.0
        self.isBlocked = isBlocked
        self.suggestedAngle = min(max(suggestedAngle, -35), 85)
    }

    public static let initialLive = TelemetryData(
        frameId: 0,
        angle: 50,
        power: 48.0,
        isBlocked: false,
        suggestedAngle: 50
    )
}

// MARK: - Pure C BSD UDP Socket (127.0.0.1:45678 Loopback)

public enum BSDUDPConfig {
    public static let host = "127.0.0.1"
    public static let port: UInt16 = 45678
}

/// Socket gửi UDP thuần POSIX (`Darwin.socket`, `sendto`) gắn vào `127.0.0.1:45678`.
public final class BSDUDPSender: @unchecked Sendable {
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private var socketFD: Int32 = -1

    public init() {}

    deinit {
        closeSocket()
    }

    public func send(_ telemetry: TelemetryData, host: String = BSDUDPConfig.host, port: UInt16 = BSDUDPConfig.port) {
        guard let payload = try? encoder.encode(telemetry), !payload.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        if socketFD < 0 {
            let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return }
            var noSigPipe: Int32 = 1
            _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            socketFD = fd
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let ptonStatus = host.withCString { Darwin.inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard ptonStatus == 1 else { return }

        payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    _ = Darwin.sendto(
                        socketFD,
                        baseAddress,
                        payload.count,
                        0,
                        sockPtr,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
    }

    private func closeSocket() {
        lock.lock()
        let fd = socketFD
        socketFD = -1
        lock.unlock()
        if fd >= 0 {
            _ = Darwin.close(fd)
        }
    }
}

/// Socket nhận UDP thuần POSIX (`Darwin.socket`, `bind`, `recvfrom`) độ trễ cực thấp trên luồng `.userInteractive`.
public final class BSDUDPReceiver: @unchecked Sendable {
    private let stateLock = NSLock()
    private let queue = DispatchQueue.global(qos: .userInteractive)
    private var isRunning = false
    private var socketFD: Int32 = -1

    public init() {}

    deinit {
        stop()
    }

    public func start(
        host: String = BSDUDPConfig.host,
        port: UInt16 = BSDUDPConfig.port,
        onReceive: @escaping @Sendable (TelemetryData) -> Void
    ) {
        stateLock.lock()
        if isRunning {
            stateLock.unlock()
            return
        }

        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            stateLock.unlock()
            return
        }

        var yes: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let ptonStatus = host.withCString { Darwin.inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard ptonStatus == 1 else {
            _ = Darwin.close(fd)
            stateLock.unlock()
            return
        }

        let bindStatus = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindStatus == 0 else {
            _ = Darwin.close(fd)
            stateLock.unlock()
            return
        }

        socketFD = fd
        isRunning = true
        stateLock.unlock()

        queue.async { [weak self] in
            self?.receiveLoop(fd: fd, onReceive: onReceive)
        }
    }

    public func stop() {
        stateLock.lock()
        isRunning = false
        let fd = socketFD
        socketFD = -1
        stateLock.unlock()

        if fd >= 0 {
            _ = Darwin.close(fd)
        }
    }

    private func receiveLoop(fd: Int32, onReceive: @escaping @Sendable (TelemetryData) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 256)
        let decoder = JSONDecoder()

        while true {
            stateLock.lock()
            let active = isRunning && socketFD == fd
            stateLock.unlock()
            if !active { break }

            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return Darwin.recvfrom(fd, baseAddress, rawBuffer.count, 0, nil, nil)
            }

            if bytesRead > 0 {
                let packet = Data(buffer[0..<bytesRead])
                if let telemetry = try? decoder.decode(TelemetryData.self, from: packet) {
                    onReceive(telemetry)
                }
            }
        }
    }
}
