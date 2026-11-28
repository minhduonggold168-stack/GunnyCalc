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

/// Tọa độ điểm chuẩn hóa (0.0 - 1.0) bên trong Minimap (gốc trên-trái).
public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x.isFinite ? min(max(x, 0.0), 1.0) : 0.5
        self.y = y.isFinite ? min(max(y, 0.0), 1.0) : 0.5
    }
}

/// Các vùng quét chuẩn hóa cố định của Gunny Mobi (tỉ lệ 0.0 - 1.0).
public enum GunnyROIs {
    public static let minimap = NormalizedRect(x: 0.848, y: 0.005, width: 0.148, height: 0.170)
    public static let wind = NormalizedRect(x: 0.420, y: 0.005, width: 0.160, height: 0.062)
    public static let angleBattlefield = NormalizedRect(x: 0.080, y: 0.120, width: 0.760, height: 0.580)
    public static let angleDPad = NormalizedRect(x: 0.075, y: 0.745, width: 0.080, height: 0.130)
    public static let angle = angleBattlefield
}

/// Điểm tọa độ chuẩn hóa `0.0 - 1.0` dọc đường cong parabol quỹ đạo đạn trong khung Minimap.
public struct TrajectoryPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Gói dữ liệu chiến đấu truyền thời gian thực qua BSD UDP loopback (`127.0.0.1:45678`).
public struct TelemetryData: Codable, Equatable, Sendable {
    public var frameId: Int
    public var playerX: Double
    public var playerY: Double
    public var enemyX: Double
    public var enemyY: Double
    public var enemies: [NormalizedPoint]
    public var lockedEnemyIndex: Int
    public var cameraRect: NormalizedRect?
    public var cameraWidthNorm: Double
    public var distanceUnits: Double
    public var deltaYUnits: Double
    public var angle: Double
    public var wind: Double
    public var windDir: Int
    public var power: Double
    public var trajectoryPoints: [TrajectoryPoint]
    public var minimapJPEG: Data?

    public var dx: Double { enemyX - playerX }
    public var dy: Double { playerY - enemyY }
    public var screens: Double { distanceUnits / 10.0 }
    public var holdSeconds: Double { (min(max(power, 0.0), 100.0) / 100.0) * 2.20 }

    public init(
        frameId: Int = 0,
        playerX: Double = 0.20,
        playerY: Double = 0.68,
        enemyX: Double = 0.72,
        enemyY: Double = 0.68,
        enemies: [NormalizedPoint] = [],
        lockedEnemyIndex: Int = 0,
        cameraRect: NormalizedRect? = nil,
        cameraWidthNorm: Double = 0.38,
        distanceUnits: Double = 13.0,
        deltaYUnits: Double = 0.0,
        angle: Double = 56.0,
        wind: Double = 0.0,
        windDir: Int = 1,
        power: Double = 62.0,
        trajectoryPoints: [TrajectoryPoint] = [],
        minimapJPEG: Data? = nil
    ) {
        self.frameId = max(frameId, 0)
        self.playerX = playerX.isFinite ? min(max(playerX, 0.0), 1.0) : 0.20
        self.playerY = playerY.isFinite ? min(max(playerY, 0.0), 1.0) : 0.68
        self.enemyX = enemyX.isFinite ? min(max(enemyX, 0.0), 1.0) : 0.72
        self.enemyY = enemyY.isFinite ? min(max(enemyY, 0.0), 1.0) : 0.68
        self.enemies = enemies
        self.lockedEnemyIndex = max(lockedEnemyIndex, 0)
        self.cameraRect = cameraRect
        self.cameraWidthNorm = cameraWidthNorm.isFinite ? min(max(cameraWidthNorm, 0.08), 0.95) : 0.38
        self.distanceUnits = distanceUnits.isFinite ? max(distanceUnits, 0.0) : 0.0
        self.deltaYUnits = deltaYUnits.isFinite ? deltaYUnits : 0.0
        self.angle = angle.isFinite ? min(max(angle, 10.0), 85.0) : 56.0
        self.wind = wind.isFinite ? min(max(abs(wind), 0.0), 5.0) : 0.0
        self.windDir = windDir < 0 ? -1 : 1
        self.power = power.isFinite ? min(max(power, 0.0), 100.0) : 0.0
        self.trajectoryPoints = trajectoryPoints
        self.minimapJPEG = minimapJPEG
    }

    public static let placeholder = TelemetryData(
        frameId: 0,
        playerX: 0.20,
        playerY: 0.68,
        enemyX: 0.72,
        enemyY: 0.68,
        enemies: [
            NormalizedPoint(x: 0.72, y: 0.68),
            NormalizedPoint(x: 0.84, y: 0.54)
        ],
        lockedEnemyIndex: 0,
        cameraRect: NormalizedRect(x: 0.10, y: 0.24, width: 0.40, height: 0.56),
        cameraWidthNorm: 0.40,
        distanceUnits: 13.0,
        deltaYUnits: 0.0,
        angle: 56.0,
        wind: 0.0,
        windDir: 1,
        power: 62.0,
        trajectoryPoints: [],
        minimapJPEG: nil
    )
}

// MARK: - Pure C BSD UDP Socket (127.0.0.1:45678 Loopback)

public enum BSDUDPConfig {
    public static let host = "127.0.0.1"
    public static let port: UInt16 = 45678
    public static let safeDatagramLimit = 8800
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
        var encoded = try? encoder.encode(telemetry)
        if let size = encoded?.count, size > BSDUDPConfig.safeDatagramLimit {
            var trimmed = telemetry
            trimmed.minimapJPEG = nil
            encoded = try? encoder.encode(trimmed)
        }
        guard let payload = encoded, !payload.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        if socketFD < 0 {
            let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return }
            var noSigPipe: Int32 = 1
            _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var sendBuf: Int32 = 65536
            _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuf, socklen_t(MemoryLayout<Int32>.size))
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

        var rcvBuf: Int32 = 65536
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBuf, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: 0, tv_usec: 400_000)
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
        var buffer = [UInt8](repeating: 0, count: 65535)
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
