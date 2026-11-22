import Foundation

/// Cấu hình App Group dùng chung giữa `GunnyCalcApp` và `BroadcastExtension`.
public enum AppGroupConfig {
    public static let suiteName = "group.com.gunny.pipcalc"
}

/// Lớp giao tiếp liên tiến trình (IPC) giữa `BroadcastExtension` và `GunnyCalcApp`
/// sử dụng App Group `UserDefaults` và `CFNotificationCenterGetDarwinNotifyCenter`.
public final class SharedIPC: @unchecked Sendable {
    public static let shared = SharedIPC()

    public static let suiteName = AppGroupConfig.suiteName
    public static let telemetryDarwinNotification = "com.gunny.pipcalc.darwin.telemetryUpdated"
    public static let configDarwinNotification = "com.gunny.pipcalc.darwin.configUpdated"

    private enum StorageKey {
        static let roiConfig = "gunnycalc.roiConfig.json"
        static let ballisticsConfig = "gunnycalc.ballisticsConfig.json"
        static let telemetryData = "gunnycalc.telemetryData.json"
    }

    private let defaults: UserDefaults?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    private var telemetryObserverHandler: ((TelemetryData?) -> Void)?
    private var configObserverHandler: (() -> Void)?
    private var isObservingTelemetry = false
    private var isObservingConfig = false

    public init(suiteName: String = AppGroupConfig.suiteName) {
        self.defaults = UserDefaults(suiteName: suiteName)
    }

    deinit {
        stopObservingTelemetry()
        stopObservingConfig()
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
