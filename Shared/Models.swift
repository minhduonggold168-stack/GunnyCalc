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

    public func pixelRect(width imageWidth: Int, height imageHeight: Int) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else { return .zero }
        let w = Double(imageWidth)
        let h = Double(imageHeight)
        let raw = CGRect(
            x: x * w,
            y: y * h,
            width: width * w,
            height: height * h
        ).integral
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        return raw.intersection(bounds)
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0.0 }
        return min(max(value, 0.0), 1.0)
    }
}

/// 3 vùng quét cố định chuẩn Gunny Mobi (tỉ lệ chuẩn hóa 0.0 - 1.0).
public enum GunnyROIs {
    public static let minimap = NormalizedRect(x: 0.848, y: 0.005, width: 0.148, height: 0.170)
    public static let wind = NormalizedRect(x: 0.435, y: 0.005, width: 0.130, height: 0.070)
    public static let angle = NormalizedRect(x: 0.080, y: 0.120, width: 0.760, height: 0.600)
}

/// Điểm tọa độ chuẩn hóa `0.0 - 1.0` dọc đường cong parabol quỹ đạo đạn.
public struct TrajectoryPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Gói dữ liệu gọn nhẹ truyền thời gian thực qua BSD UDP loopback (`127.0.0.1:45678`).
public struct TelemetryData: Codable, Equatable, Sendable {
    public var frameId: Int
    public var playerX: Double
    public var playerY: Double
    public var enemyX: Double
    public var enemyY: Double
    public var angle: Double
    public var wind: Double
    public var windDir: Int
    public var power: Double
    public var trajectoryPoints: [TrajectoryPoint]

    public var dx: Double { enemyX - playerX }
    public var dy: Double { playerY - enemyY }
    public var holdSeconds: Double { (min(max(power, 0.0), 100.0) / 100.0) * 2.20 }

    public init(
        frameId: Int = 0,
        playerX: Double = 0.25,
        playerY: Double = 0.65,
        enemyX: Double = 0.75,
        enemyY: Double = 0.65,
        angle: Double = 65.0,
        wind: Double = 0.0,
        windDir: Int = 1,
        power: Double = 0.0,
        trajectoryPoints: [TrajectoryPoint] = []
    ) {
        self.frameId = max(frameId, 0)
        self.playerX = playerX
        self.playerY = playerY
        self.enemyX = enemyX
        self.enemyY = enemyY
        self.angle = angle
        self.wind = wind
        self.windDir = windDir < 0 ? -1 : 1
        self.power = min(max(power, 0.0), 100.0)
        self.trajectoryPoints = trajectoryPoints
    }

    public static let placeholder = TelemetryData(
        frameId: 0,
        playerX: 0.22,
        playerY: 0.70,
        enemyX: 0.78,
        enemyY: 0.68,
        angle: 65.0,
        wind: 0.0,
        windDir: 1,
        power: 45.0,
        trajectoryPoints: []
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
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            socketFD = fd
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        _ = host.withCString { Darwin.inet_pton(AF_INET, $0, &addr.sin_addr) }

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

/// Socket nhận UDP thuần POSIX (`Darwin.socket`, `bind`, `recvfrom`) trên luồng nền ưu tiên cao.
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

        var timeout = timeval(tv_sec: 0, tv_usec: 400_000)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        _ = host.withCString { Darwin.inet_pton(AF_INET, $0, &addr.sin_addr) }

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
        var buffer = [UInt8](repeating: 0, count: 8192)
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
