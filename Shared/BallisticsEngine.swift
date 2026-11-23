import Foundation

/// Bộ tính toán lực bắn 2D (0...100) và sinh 30 điểm quỹ đạo parabol từ tọa độ người chơi tới mục tiêu.
public struct BallisticsEngine: Sendable {
    private static let horizontalRangeScale = 400.0
    private static let verticalElevationScale = 220.0
    private static let gravity = 15.0
    private static let windAccelerationScale = 1.2

    public init() {}

    /// Tính lực bắn `power` (0.0 ... 100.0) theo `(dx = enemyX - playerX, dy = playerY - enemyY)`, góc bắn và gió có hướng (`wind * windDir`).
    public func calculatePower(
        dx: Double,
        dy: Double,
        angle: Double,
        signedWind: Double
    ) -> Double {
        let distance = abs(dx) * Self.horizontalRangeScale
        let elevation = dy * Self.verticalElevationScale

        guard distance > 0.0001 || abs(elevation) > 0.0001 else {
            return 0.0
        }

        let safeAngle = min(max(angle, 1.0), 89.0)
        let theta = safeAngle * .pi / 180.0
        let sinTheta = sin(theta)
        let cosTheta = cos(theta)

        // Quy đổi chiều gió theo hướng bắn (+ thuận gió, - ngược gió).
        let shotSign = dx >= 0.0 ? 1.0 : -1.0
        let directedWind = signedWind * shotSign
        let windAcceleration = directedWind * Self.windAccelerationScale

        let numerator = 2.0 * (distance * sinTheta - elevation * cosTheta)
        let denominator = Self.gravity * cosTheta + windAcceleration * sinTheta

        guard denominator > 0.0001 else {
            return 100.0
        }
        guard numerator > 0.0 else {
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

        return min(max(initialVelocity, 0.0), 100.0)
    }

    /// Sinh 30 điểm quỹ đạo parabol chuẩn hóa `0.0 - 1.0` nối chính xác từ `(playerX, playerY)` tới `(enemyX, enemyY)`.
    public func generateTrajectoryPoints(
        playerX: Double,
        playerY: Double,
        enemyX: Double,
        enemyY: Double,
        angleDeg: Double,
        signedWind: Double,
        power: Double
    ) -> [TrajectoryPoint] {
        let stepCount = 30
        let px = min(max(playerX, 0.06), 0.94)
        let ex = min(max(enemyX, 0.06), 0.94)

        // Ánh xạ tọa độ đứng vào nửa dưới khung ngắm để dành khoảng trống phía trên cho đỉnh parabol.
        let py = 0.42 + min(max(playerY, 0.0), 1.0) * 0.48
        let ey = 0.42 + min(max(enemyY, 0.0), 1.0) * 0.48

        let dx = ex - px
        let dyUp = py - ey
        let safeAngle = min(max(angleDeg, 10.0), 85.0)
        let theta = safeAngle * .pi / 180.0

        // Độ cao vồng parabol tỉ lệ với góc bắn và lực bắn, giữ đỉnh luôn >= 0.06 trong khung vẽ.
        let desiredRise = max(abs(dx) * tan(theta) * 0.24, 0.14) + (power / 100.0) * 0.08
        let highestEndpoint = min(py, ey)
        let maxSafeRise = max(highestEndpoint - 0.07, 0.05)
        let archRise = min(desiredRise, maxSafeRise)

        // Độ uốn ngang theo gió có hướng.
        let windBend = -0.025 * signedWind * max(abs(dx), 0.15)

        var points: [TrajectoryPoint] = []
        points.reserveCapacity(stepCount)

        for i in 0..<stepCount {
            let u = Double(i) / Double(stepCount - 1)
            let arcFactor = 4.0 * u * (1.0 - u)
            let x = min(max(px + dx * u + windBend * arcFactor, 0.03), 0.97)
            let y = min(max(py - dyUp * u - archRise * arcFactor, 0.05), 0.95)
            points.append(TrajectoryPoint(x: x, y: y))
        }

        return points
    }

    /// Tính hoàn chỉnh `power` và 30 điểm parabol thành `TelemetryData`.
    public func buildTelemetry(
        frameId: Int,
        playerX: Double,
        playerY: Double,
        enemyX: Double,
        enemyY: Double,
        angle: Double,
        windMagnitude: Double,
        windDir: Int
    ) -> TelemetryData {
        let safeDir = windDir < 0 ? -1 : 1
        let signedWind = abs(windMagnitude) * Double(safeDir)
        let dx = enemyX - playerX
        let dy = playerY - enemyY

        let power = calculatePower(
            dx: dx,
            dy: dy,
            angle: angle,
            signedWind: signedWind
        )

        let points = generateTrajectoryPoints(
            playerX: playerX,
            playerY: playerY,
            enemyX: enemyX,
            enemyY: enemyY,
            angleDeg: angle,
            signedWind: signedWind,
            power: power
        )

        return TelemetryData(
            frameId: frameId,
            playerX: playerX,
            playerY: playerY,
            enemyX: enemyX,
            enemyY: enemyY,
            angle: angle,
            wind: abs(windMagnitude),
            windDir: safeDir,
            power: power,
            trajectoryPoints: points
        )
    }
}
