import Foundation

/// Cấu hình App Group dự phòng dùng chung giữa `GunnyCalcApp` và `BroadcastExtension`.
public enum AppGroupConfig {
    public static let suiteName = "group.com.gunny.pipcalc"
}

/// Bộ đệm chia sẻ tùy chọn qua App Group UserDefaults (kênh phụ bên cạnh BSD UDP loopback).
public final class SharedIPC: @unchecked Sendable {
    public static let shared = SharedIPC()

    private let telemetryKey = "gunnycalc.telemetryData.json"
    private let defaults = UserDefaults(suiteName: AppGroupConfig.suiteName)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    private init() {}

    public func saveTelemetry(_ telemetry: TelemetryData) {
        lock.lock()
        defer { lock.unlock() }
        guard let defaults, let data = try? encoder.encode(telemetry) else { return }
        defaults.set(data, forKey: telemetryKey)
    }

    public func loadTelemetry() -> TelemetryData? {
        lock.lock()
        defer { lock.unlock() }
        guard let defaults, let data = defaults.data(forKey: telemetryKey) else { return nil }
        return try? decoder.decode(TelemetryData.self, from: data)
    }
}
