import Darwin
import Foundation

/// Cấu hình App Group dùng chung giữa `GunnyCalcApp` và `BroadcastExtension`.
public enum AppGroupConfig {
    public static let suiteName = "group.com.gunny.pipcalc"
}

/// Lớp giao tiếp liên tiến trình (IPC) giữa `BroadcastExtension` và `GunnyCalcApp`
/// kết hợp App Group `UserDefaults`, `CFNotificationCenterGetDarwinNotifyCenter` và UDP cục bộ `127.0.0.1:45678`.
public final class SharedIPC: @unchecked Sendable {
    public static let shared = SharedIPC()

    public static let suiteName = AppGroupConfig.suiteName
    public static let telemetryDarwinNotification = "com.gunny.pipcalc.darwin.telemetryUpdated"
    public static let configDarwinNotification = "com.gunny.pipcalc.darwin.configUpdated"
    public static let udpHost = "127.0.0.1"
    public static let udpPort: UInt16 = 45678

    private enum StorageKey {
        static let roiConfig = "gunnycalc.roiConfig.json"
        static let ballisticsConfig = "gunnycalc.ballisticsConfig.json"
        static let telemetryData = "gunnycalc.telemetryData.json"
    }

    private let defaults: UserDefaults?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()
    private let udpLock = NSLock()
    private let udpQueue = DispatchQueue(label: "com.gunny.pipcalc.udp", qos: .userInteractive)

    private var telemetryObserverHandler: ((TelemetryData?) -> Void)?
    private var configObserverHandler: (() -> Void)?
    private var isObservingTelemetry = false
    private var isObservingConfig = false

    private var udpSenderFD: Int32 = -1
    private var udpListenerFD: Int32 = -1
    private var udpReadSource: DispatchSourceRead?
    private var udpTelemetryHandler: ((TelemetryData) -> Void)?

    public init(suiteName: String = AppGroupConfig.suiteName) {
        self.defaults = UserDefaults(suiteName: suiteName)
    }

    deinit {
        stopObservingTelemetry()
        stopObservingConfig()
        stopUDPTelemetryListener()
        closeUDPSenderSocket()
    }

    // MARK: - ROIConfig

    public func saveROIConfig(_ config: ROIConfig, notify: Bool = true) {
        saveCodable(config, forKey: StorageKey.roiConfig)

        var ballistics = loadBallisticsConfig()
        ballistics.minimapROI = config.minimapRect.cgRect
        ballistics.windROI = config.windRect.cgRect
        ballistics.angleROI = config.angleRect.cgRect
        saveCodable(ballistics, forKey: StorageKey.ballisticsConfig)

        if notify {
            postDarwinNotification(name: Self.configDarwinNotification)
        }
    }

    public func loadROIConfig() -> ROIConfig {
        if let saved = loadCodable(ROIConfig.self, forKey: StorageKey.roiConfig) {
            return saved
        }
        return loadBallisticsConfig().roiConfig
    }

    // MARK: - BallisticsConfig

    public func saveBallisticsConfig(_ config: BallisticsConfig, notify: Bool = true) {
        saveCodable(config, forKey: StorageKey.ballisticsConfig)
        saveCodable(config.roiConfig, forKey: StorageKey.roiConfig)
        if notify {
            postDarwinNotification(name: Self.configDarwinNotification)
        }
    }

    public func loadBallisticsConfig() -> BallisticsConfig {
        loadCodable(BallisticsConfig.self, forKey: StorageKey.ballisticsConfig) ?? .default
    }

    // MARK: - TelemetryData

    public func saveTelemetry(_ telemetry: TelemetryData, notify: Bool = true) {
        saveCodable(telemetry, forKey: StorageKey.telemetryData)
        if notify {
            postDarwinNotification(name: Self.telemetryDarwinNotification)
        }
    }

    public func loadTelemetry() -> TelemetryData? {
        loadCodable(TelemetryData.self, forKey: StorageKey.telemetryData)
    }

    // MARK: - Local UDP (127.0.0.1:45678)

    public func sendTelemetryUDP(
        _ telemetry: TelemetryData,
        host: String = SharedIPC.udpHost,
        port: UInt16 = SharedIPC.udpPort
    ) {
        guard let payload = try? encoder.encode(telemetry), !payload.isEmpty else { return }

        udpLock.lock()
        defer { udpLock.unlock() }

        if udpSenderFD < 0 {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            udpSenderFD = fd
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        _ = host.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }

        payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    _ = sendto(
                        udpSenderFD,
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

    public func startUDPTelemetryListener(
        port: UInt16 = SharedIPC.udpPort,
        handler: @escaping (TelemetryData) -> Void
    ) {
        udpLock.lock()
        udpTelemetryHandler = handler
        if udpReadSource != nil {
            udpLock.unlock()
            return
        }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            udpLock.unlock()
            return
        }

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        _ = Self.udpHost.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            close(fd)
            udpLock.unlock()
            return
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: udpQueue)
        source.setEventHandler { [weak self] in
            self?.drainIncomingUDPPackets(fileDescriptor: fd)
        }
        source.setCancelHandler {
            close(fd)
        }

        udpListenerFD = fd
        udpReadSource = source
        udpLock.unlock()

        source.resume()
    }

    public func stopUDPTelemetryListener() {
        udpLock.lock()
        let source = udpReadSource
        udpReadSource = nil
        udpListenerFD = -1
        udpTelemetryHandler = nil
        udpLock.unlock()

        source?.cancel()
    }

    private func closeUDPSenderSocket() {
        udpLock.lock()
        let fd = udpSenderFD
        udpSenderFD = -1
        udpLock.unlock()
        if fd >= 0 {
            close(fd)
        }
    }

    private func drainIncomingUDPPackets(fileDescriptor fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        var latestData: Data?

        while true {
            let received = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return recvfrom(fd, baseAddress, rawBuffer.count, 0, nil, nil)
            }
            if received > 0 {
                latestData = Data(buffer[0..<received])
            } else {
                break
            }
        }

        guard let packetData = latestData,
              let telemetry = try? JSONDecoder().decode(TelemetryData.self, from: packetData) else {
            return
        }

        udpLock.lock()
        let handler = udpTelemetryHandler
        udpLock.unlock()

        guard let handler else { return }
        DispatchQueue.main.async {
            handler(telemetry)
        }
    }

    // MARK: - Darwin Notification Center

    public func postDarwinNotification(name: String) {
        guard let center = CFNotificationCenterGetDarwinNotifyCenter() else { return }
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    public func startObservingTelemetry(handler: @escaping (TelemetryData?) -> Void) {
        lock.lock()
        telemetryObserverHandler = handler
        let alreadyRegistered = isObservingTelemetry
        isObservingTelemetry = true
        lock.unlock()

        guard !alreadyRegistered,
              let center = CFNotificationCenterGetDarwinNotifyCenter() else { return }

        let observerPointer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observerPointer,
            darwinTelemetryCallback,
            Self.telemetryDarwinNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    public func stopObservingTelemetry() {
        lock.lock()
        let wasRegistered = isObservingTelemetry
        isObservingTelemetry = false
        telemetryObserverHandler = nil
        lock.unlock()

        guard wasRegistered,
              let center = CFNotificationCenterGetDarwinNotifyCenter() else { return }

        let observerPointer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            center,
            observerPointer,
            CFNotificationName(Self.telemetryDarwinNotification as CFString),
            nil
        )
    }

    public func startObservingConfig(handler: @escaping () -> Void) {
        lock.lock()
        configObserverHandler = handler
        let alreadyRegistered = isObservingConfig
        isObservingConfig = true
        lock.unlock()

        guard !alreadyRegistered,
              let center = CFNotificationCenterGetDarwinNotifyCenter() else { return }

        let observerPointer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observerPointer,
            darwinConfigCallback,
            Self.configDarwinNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    public func stopObservingConfig() {
        lock.lock()
        let wasRegistered = isObservingConfig
        isObservingConfig = false
        configObserverHandler = nil
        lock.unlock()

        guard wasRegistered,
              let center = CFNotificationCenterGetDarwinNotifyCenter() else { return }

        let observerPointer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(
            center,
            observerPointer,
            CFNotificationName(Self.configDarwinNotification as CFString),
            nil
        )
    }

    // MARK: - Private Helpers

    private func saveCodable<T: Encodable>(_ value: T, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let defaults, let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func loadCodable<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let defaults, let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    fileprivate func handleTelemetryNotification() {
        lock.lock()
        let handler = telemetryObserverHandler
        lock.unlock()

        guard let handler else { return }
        let latest = loadTelemetry()
        DispatchQueue.main.async {
            handler(latest)
        }
    }

    fileprivate func handleConfigNotification() {
        lock.lock()
        let handler = configObserverHandler
        lock.unlock()

        guard let handler else { return }
        DispatchQueue.main.async {
            handler()
        }
    }
}

private let darwinTelemetryCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    let ipc = Unmanaged<SharedIPC>.fromOpaque(observer).takeUnretainedValue()
    ipc.handleTelemetryNotification()
}

private let darwinConfigCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    let ipc = Unmanaged<SharedIPC>.fromOpaque(observer).takeUnretainedValue()
    ipc.handleConfigNotification()
}

public extension BallisticsConfig {
    /// Luôn trả về cấu hình kèm bộ tọa độ mặc định Gunny Mobi ngay từ lần chạy đầu tiên.
    static func load() -> BallisticsConfig {
        SharedIPC.shared.loadBallisticsConfig()
    }

    func save(notify: Bool = true) {
        SharedIPC.shared.saveBallisticsConfig(self, notify: notify)
    }
}
