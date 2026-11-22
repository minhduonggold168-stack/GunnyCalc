import Foundation

/// Bộ tính toán lực bắn 2D dựa trên phương trình chuyển động ném xiên có gió và chênh lệch độ cao.
public struct BallisticsEngine: Sendable {
    /// Hằng số chuẩn hóa quy đổi tỉ lệ minimap sang hệ quy chiếu lực bắn (0 - 100).
    private static let horizontalRangeScale = 400.0
    private static let verticalElevationScale = 220.0
    private static let gravity = 15.0
    private static let windAccelerationScale = 1.2

    public init() {}

    /// Tính lực bắn `P` (0.0 - 100.0) từ tọa độ chuẩn hóa `dx`, `dy`, góc bắn, gió và cấu hình hiệu chỉnh.
    public func calculatePower(
        dx: Double,
        dy: Double,
        angle: Double,
        wind: Double,
        config: BallisticsConfig
    ) -> Double {
        let distance = abs(dx) * Self.horizontalRangeScale
        let elevation = dy * Self.verticalElevationScale

        guard distance > 0.0001 || abs(elevation) > 0.0001 else {
            return 0.0
        }

        // Góc bắn hợp lệ trong khoảng (1° ... 89°) để tránh chia cho 0 khi cos(θ) → 0.
        let safeAngle = min(max(angle, 1.0), 89.0)
        let theta = safeAngle * .pi / 180.0
        let sinTheta = sin(theta)
        let cosTheta = cos(theta)

        // Quy đổi chiều gió theo hướng bắn (gió thuận > 0, gió ngược < 0).
        let shotSign = dx >= 0.0 ? 1.0 : -1.0
        let directedWind = wind * shotSign
        let windAcceleration = directedWind * config.windFactor * Self.windAccelerationScale

        // Giải hệ phương trình chuyển động ném xiên 2D:
        // x(t) = v0 * cos(θ) * t + 0.5 * a_w * t^2 = D
        // y(t) = v0 * sin(θ) * t - 0.5 * g * t^2   = H
        // => t^2 = 2 * (D * sin(θ) - H * cos(θ)) / (g * cos(θ) + a_w * sin(θ))
        let numerator = 2.0 * (distance * sinTheta - elevation * cosTheta)
        let denominator = Self.gravity * cosTheta + windAcceleration * sinTheta

        guard denominator > 0.0001 else {
            return 100.0
        }

        guard numerator > 0.0 else {
            // Mục tiêu cao hơn đường tiệm cận của góc bắn hiện tại.
            return 0.0
        }

        let tSquared = numerator / denominator
        let flightTime = sqrt(tSquared)
        guard flightTime > 0.0001 else {
            return 0.0
        }

        let initialVelocity = (distance - 0.5 * windAcceleration * tSquared) / (flightTime * cosTheta)
        guard initialVelocity.isFinite else {
            return 0.0
        }

        let rawPower = max(0.0, initialVelocity) * max(0.0, config.powerFactor)
        return min(max(rawPower, 0.0), 100.0)
    }

    /// Tính thời gian cần giữ nút bắn (giây) tương ứng với lực `P` (0 - 100).
    public func calculateHoldSeconds(power: Double, maxHoldSeconds: Double) -> Double {
        let clampedPower = min(max(power, 0.0), 100.0)
        return (clampedPower / 100.0) * max(0.0, maxHoldSeconds)
    }

    /// Tạo gói `TelemetryData` hoàn chỉnh từ kết quả quan sát hình ảnh và cấu hình hiện hành.
    public func computeTelemetry(
        dx: Double,
        dy: Double,
        wind: Double,
        detectedAngle: Double?,
        config: BallisticsConfig,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) -> TelemetryData {
        let effectiveAngle = config.useOCRAngle ? (detectedAngle ?? config.selectedAngle) : config.selectedAngle
        let power = calculatePower(
            dx: dx,
            dy: dy,
            angle: effectiveAngle,
            wind: wind,
            config: config
        )
        let holdSeconds = calculateHoldSeconds(
            power: power,
            maxHoldSeconds: config.maxHoldSeconds
        )

        return TelemetryData(
            dx: dx,
            dy: dy,
            wind: wind,
            angle: effectiveAngle,
            calculatedPower: power,
            holdSeconds: holdSeconds,
            timestamp: timestamp
        )
    }
}
