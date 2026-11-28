import CoreGraphics
import Darwin
import Foundation

/// Vùng chữ nhật chuẩn hóa theo tỉ lệ `0.0 - 1.0` (gốc trên-trái).
public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        let clampedX = Self.clamp01(x)
        let clampedY = Self.clamp01(y)
        self.x = clampedX
        self.y = clampedY
        self.width = min(Self.clamp01(width), 1.0 - clampedX)
        self.height = min(Self.clamp01(height), 1.0 - clampedY)
    }

    /// Chuyển đổi sang tọa độ CoreImage (gốc dưới-trái) cho ảnh đã dịch về gốc `(0, 0)`.
    public func ciRect(width imageWidth: CGFloat, height imageHeight: CGFloat) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else { return .zero }
        let rectX = floor(CGFloat(x) * imageWidth)
        let rectW = max(1.0, floor(CGFloat(width) * imageWidth))
        let rectH = max(1.0, floor(CGFloat(height) * imageHeight))
        let rectY = floor((1.0 - CGFloat(y + height)) * imageHeight)
        let raw = CGRect(x: rectX, y: rectY, width: rectW, height: rectH)
        return raw.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0.0 }
        return min(max(value, 0.0), 1.0)
    }
}

/// 2 vùng quét siêu gọn cho Gunny Mobi bản không gió (tỉ lệ 0.0 - 1.0, gốc trên-trái).
public enum GunnyROIs {
    /// Dải chiến trường ở giữa Minimap (nằm hoàn toàn dưới nút đỏ [X] và trên thước vàng).
    public static let minimapStrip = NormalizedRect(x: 0.848, y: 0.046, width: 0.148, height: 0.096)
    /// Vùng chữ góc bắn cạnh nhân vật.
    public static let angleBattlefield = NormalizedRect(x: 0.050, y: 0.140, width: 0.820, height: 0.560)
}

/// Gói dữ liệu siêu nhỏ (< 60 bytes JSON) truyền tức thời 30 FPS qua BSD UDP (`127.0.0.1:45678`).
public struct TelemetryData: Codable, Equatable, Sendable {
    public var frameId: Int
    public var angle: Int
    public var power: Double

    public init(frameId: Int = 0, angle: Int = 50, power: Double = 48.0) {
        self.frameId = max(frameId, 0)
        self.angle = min(max(angle, -35), 85)
        let clampedPower = power.isFinite ? min(max(power, 0.0), 100.0) : 0.0
        self.power = (clampedPower * 10.0).rounded() / 10.0
    }

    public static let initialLive = TelemetryData(frameId: 0, angle: 50, power: 48.0)
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

        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
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
