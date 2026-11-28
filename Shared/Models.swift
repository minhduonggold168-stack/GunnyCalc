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

/// Các vùng quét cố định cho Gunny Mobi bản không gió (tỉ lệ chuẩn hóa 0.0 - 1.0, gốc trên-trái).
public enum GunnyROIs {
    public static let minimap = NormalizedRect(x: 0.848, y: 0.005, width: 0.148, height: 0.170)
    public static let angleBattlefield = NormalizedRect(x: 0.040, y: 0.120, width: 0.850, height: 0.620)

    // 3 dấu hiệu nhận diện giao diện chiến đấu Gunny Mobi (khóa isInBattle).
    public static let battleCloseButton = NormalizedRect(x: 0.940, y: 0.005, width: 0.050, height: 0.050)
    public static let battleMinimapRuler = NormalizedRect(x: 0.848, y: 0.145, width: 0.147, height: 0.030)
    public static let battlePowerBar = NormalizedRect(x: 0.300, y: 0.880, width: 0.420, height: 0.070)
}

/// Gói dữ liệu chiến đấu bản không gió truyền thời gian thực 25 FPS qua BSD UDP (`127.0.0.1:45678`).
public struct TelemetryData: Codable, Equatable, Sendable {
    public var frameId: Int
    public var isInBattle: Bool
    public var distanceUnits: Double
    public var deltaY: Double
    public var angle: Double
    public var power: Double
    public var holdSeconds: Double
    public var playerNorm: CGPoint
    public var enemyNorm: CGPoint
    public var allEnemiesNorm: [CGPoint]
    public var minimapJPEG: Data?
    public var trajectoryPoints: [CGPoint]
    public var power30: Double
    public var power50: Double
    public var power65: Double

    public var screens: Double { distanceUnits / 10.0 }

    public init(
        frameId: Int = 0,
        isInBattle: Bool = false,
        distanceUnits: Double = 0.0,
        deltaY: Double = 0.0,
        angle: Double = 50.0,
        power: Double = 0.0,
        holdSeconds: Double = 0.0,
        playerNorm: CGPoint = CGPoint(x: 0.20, y: 0.68),
        enemyNorm: CGPoint = CGPoint(x: 0.72, y: 0.68),
        allEnemiesNorm: [CGPoint] = [],
        minimapJPEG: Data? = nil,
        trajectoryPoints: [CGPoint] = [],
        power30: Double = 0.0,
        power50: Double = 0.0,
        power65: Double = 0.0
    ) {
        self.frameId = max(frameId, 0)
        self.isInBattle = isInBattle
        self.distanceUnits = distanceUnits.isFinite ? max(distanceUnits, 0.0) : 0.0
        self.deltaY = deltaY.isFinite ? deltaY : 0.0
        self.angle = angle.isFinite ? min(max(angle, -30.0), 85.0) : 50.0
        self.power = power.isFinite ? min(max(power, 0.0), 100.0) : 0.0
        self.holdSeconds = holdSeconds.isFinite ? max(holdSeconds, 0.0) : (self.power / 100.0) * 2.20
        self.playerNorm = Self.clampPoint(playerNorm)
        self.enemyNorm = Self.clampPoint(enemyNorm)
        self.allEnemiesNorm = allEnemiesNorm.map { Self.clampPoint($0) }
        self.minimapJPEG = minimapJPEG
        self.trajectoryPoints = trajectoryPoints.map { Self.clampPoint($0) }
        self.power30 = power30.isFinite ? min(max(power30, 0.0), 100.0) : 0.0
        self.power50 = power50.isFinite ? min(max(power50, 0.0), 100.0) : 0.0
        self.power65 = power65.isFinite ? min(max(power65, 0.0), 100.0) : 0.0
    }

    public static func waiting(frameId: Int = 0) -> TelemetryData {
        TelemetryData(frameId: frameId, isInBattle: false)
    }

    private static func clampPoint(_ pt: CGPoint) -> CGPoint {
        let x = pt.x.isFinite ? min(max(pt.x, 0.0), 1.0) : 0.5
        let y = pt.y.isFinite ? min(max(pt.y, 0.0), 1.0) : 0.5
        return CGPoint(x: x, y: y)
    }
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

        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
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
