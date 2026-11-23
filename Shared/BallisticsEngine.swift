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

    /// Tạo danh sách 30 điểm quỹ đạo parabol ném xiên 2D chuẩn hóa trong khung `0.0 - 1.0` (chừa lề 10% xung quanh).
    public func generateTrajectoryPoints(
        dx: Double,
        dy: Double,
        angleDeg: Double,
        wind: Double,
        power: Double
    ) -> [TrajectoryPoint] {
        let stepCount = 30
        let targetX = dx * Self.horizontalRangeScale
        let targetY = dy * Self.verticalElevationScale
        let distance = abs(targetX)

        guard distance > 0.0001 || abs(targetY) > 0.0001 else {
            return []
        }

        let safeAngle = min(max(angleDeg, 1.0), 89.0)
        let theta = safeAngle * .pi / 180.0
        let sinTheta = sin(theta)
        let cosTheta = cos(theta)
        let shotSign = dx >= 0.0 ? 1.0 : -1.0

        let speed = max(power, 1.0)
        let vx0 = shotSign * speed * cosTheta
        let vy0 = speed * sinTheta
        let ax = wind * Self.windAccelerationScale

        // Giải thời gian bay T để đạn đi hết quãng đường ngang targetX dưới gia tốc gió ax:
        // 0.5 * ax * T^2 + vx0 * T - targetX = 0
        let flightTime: Double
        if abs(ax) > 1e-6 {
            let discriminant = vx0 * vx0 + 2.0 * ax * targetX
            if discriminant >= 0.0 {
                let sqrtDisc = sqrt(discriminant)
                let t1 = (-vx0 + sqrtDisc) / ax
                let t2 = (-vx0 - sqrtDisc) / ax
                let candidates = [t1, t2].filter { $0 > 0.0001 }
                flightTime = candidates.min() ?? max(distance / max(abs(vx0), 1.0), 0.1)
            } else {
                flightTime = max(distance / max(abs(vx0), 1.0), 0.1)
            }
        } else {
            flightTime = max(distance / max(abs(vx0), 1.0), 0.1)
        }

        // Hiệu chỉnh trọng lực tương đương sao cho ở thời điểm T đường cong chạm chính xác (targetX, targetY).
        let rawGravity = 2.0 * (vy0 * flightTime - targetY) / (flightTime * flightTime)
        let effectiveGravity = rawGravity > 0.05 ? rawGravity : Self.gravity

        var rawPoints: [(x: Double, y: Double)] = []
        rawPoints.reserveCapacity(stepCount)

        for i in 0..<stepCount {
            let u = Double(i) / Double(stepCount - 1)
            let t = u * flightTime
            let px = vx0 * t + 0.5 * ax * t * t
            let py = vy0 * t - 0.5 * effectiveGravity * t * t
            rawPoints.append((px, py))
        }

        guard let minX = rawPoints.map(\.x).min(),
              let maxX = rawPoints.map(\.x).max(),
              let minY = rawPoints.map(\.y).min(),
              let maxY = rawPoints.map(\.y).max() else {
            return []
        }

        let spanX = maxX - minX
        let spanY = maxY - minY
        let margin = 0.10
        let usableSpan = 1.0 - 2.0 * margin

        return rawPoints.map { pt in
            let normX: Double
            if spanX > 1e-6 {
                normX = margin + ((pt.x - minX) / spanX) * usableSpan
            } else {
                normX = 0.5
            }

            // Đảo trục Y về hệ tọa độ màn hình (y = 0 ở trên, y = 1 ở dưới) để đỉnh parabol nằm gần mép trên 0.10.
            let normY: Double
            if spanY > 1e-6 {
                normY = margin + ((maxY - pt.y) / spanY) * usableSpan
            } else {
                normY = 0.5
            }

            return TrajectoryPoint(x: normX, y: normY)
        }
    }

    /// Tạo gói `TelemetryData` hoàn chỉnh từ kết quả quan sát hình ảnh và cấu hình hiện hành.
    public func computeTelemetry(
        dx: Double,
        dy: Double,
        wind: Double,
        windDirection: Int? = nil,
        detectedAngle: Double?,
        config: BallisticsConfig,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        frameCount: Int = 0
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
        let trajectory = generateTrajectoryPoints(
            dx: dx,
            dy: dy,
            angleDeg: effectiveAngle,
            wind: wind * config.windFactor,
            power: power
        )

        return TelemetryData(
            dx: dx,
            dy: dy,
            wind: wind,
            windDirection: windDirection,
            angle: effectiveAngle,
            calculatedPower: power,
            holdSeconds: holdSeconds,
            timestamp: timestamp,
            frameCount: frameCount,
            trajectoryPoints: trajectory
        )
    }
}
