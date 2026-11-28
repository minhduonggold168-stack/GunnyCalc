import CoreGraphics
import Foundation

/// Kết quả sau làm mượt EMA giúp tọa độ và lực bắn ổn định ở tốc độ 25 FPS.
public struct SmoothedBallistics: Equatable, Sendable {
    public let playerNorm: CGPoint
    public let enemyNorm: CGPoint
    public let distanceUnits: Double
    public let deltaY: Double
    public let power: Double
}

/// Bộ lọc trung bình trượt hàm mũ (EMA, mặc định `alpha = 0.35`) chống rung giật tọa độ và lực bắn.
public final class BallisticsEMASmoother {
    public let alpha: Double

    private var isInitialized = false
    private var playerX = 0.20
    private var playerY = 0.68
    private var enemyX = 0.72
    private var enemyY = 0.68
    private var distanceUnits = 10.0
    private var deltaY = 0.0
    private var power = 48.0

    public init(alpha: Double = 0.35) {
        self.alpha = min(max(alpha, 0.05), 1.0)
    }

    public func reset() {
        isInitialized = false
    }

    public func smooth(
        playerNorm rawPlayer: CGPoint,
        enemyNorm rawEnemy: CGPoint,
        distanceUnits rawDistance: Double,
        deltaY rawDeltaY: Double,
        power rawPower: Double,
        targetSwitched: Bool
    ) -> SmoothedBallistics {
        let rawPX = Double(rawPlayer.x)
        let rawPY = Double(rawPlayer.y)
        let rawEX = Double(rawEnemy.x)
        let rawEY = Double(rawEnemy.y)

        let wasInitialized = isInitialized
        let enemyJump = hypot(rawEX - enemyX, rawEY - enemyY)

        if !wasInitialized || targetSwitched || enemyJump > 0.15 {
            isInitialized = true
            playerX = !wasInitialized ? rawPX : blend(prev: playerX, raw: rawPX)
            playerY = !wasInitialized ? rawPY : blend(prev: playerY, raw: rawPY)
            enemyX = rawEX
            enemyY = rawEY
            distanceUnits = rawDistance
            deltaY = rawDeltaY
            power = rawPower
        } else {
            playerX = blend(prev: playerX, raw: rawPX)
            playerY = blend(prev: playerY, raw: rawPY)
            enemyX = blend(prev: enemyX, raw: rawEX)
            enemyY = blend(prev: enemyY, raw: rawEY)
            distanceUnits = blend(prev: distanceUnits, raw: rawDistance)
            deltaY = blend(prev: deltaY, raw: rawDeltaY)
            power = blend(prev: power, raw: rawPower)
        }

        return SmoothedBallistics(
            playerNorm: CGPoint(x: playerX, y: playerY),
            enemyNorm: CGPoint(x: enemyX, y: enemyY),
            distanceUnits: distanceUnits,
            deltaY: deltaY,
            power: power
        )
    }

    private func blend(prev: Double, raw: Double) -> Double {
        guard raw.isFinite else { return prev }
        return alpha * raw + (1.0 - alpha) * prev
    }
}

/// Bộ tính lực bắn thuần túy cho Gunny Mobi bản không gió (gió = 0) dựa trên bảng chuẩn NPH từ cự ly 1 → 20.
/// - Quy chuẩn 1 khung camera trắng trên Minimap = `10.0` đơn vị cự ly.
/// - Hỗ trợ nội suy chính xác tới `0.1` đơn vị cự ly, dải góc thực tế `-30°` đến `85°` và bù trừ chênh cao `deltaY`.
public struct BallisticsEngine: Sendable {
    public static let unitsPerScreen: Double = 10.0
    public static let fullPowerHoldSeconds: Double = 2.20

    // Bảng lực chuẩn chính thức NPH Gunny Mobi không gió (cự ly 1 → 20).
    public static let table20: [Double] = [10, 19, 25, 30, 36, 40, 44, 48, 51, 54, 57, 60, 62, 65, 67, 70, 72, 75, 77, 80]
    public static let table30: [Double] = [14, 20, 24, 28, 32, 35, 38, 41, 44, 47, 50, 52, 55, 57, 60, 62, 65, 67, 69, 72]
    public static let table50: [Double] = [14, 20, 25, 29, 32, 36, 39, 42, 45, 48, 50, 53, 55, 58, 60, 63, 65, 68, 70, 72]
    public static let table65: [Double] = [13, 21, 26, 32, 37, 41, 45, 49, 53, 56, 58, 61, 64, 67, 70, 73, 76, 79, 82, 85]

    public init() {}

    /// Tra cứu nội suy tuyến tính bảng lực chuẩn NPH theo cự ly chính xác tới `0.1` đơn vị.
    public func lookupTable(_ table: [Double], distanceUnits: Double) -> Double {
        guard table.count == 20, distanceUnits.isFinite, distanceUnits > 0.0 else {
            return 0.0
        }

        if distanceUnits <= 1.0 {
            return distanceUnits * table[0]
        }

        if distanceUnits <= 20.0 {
            let lower = Int(floor(distanceUnits))
            if lower >= 20 {
                return table[19]
            }
            let fraction = distanceUnits - Double(lower)
            let pLow = table[lower - 1]
            let pHigh = table[lower]
            return pLow + fraction * (pHigh - pLow)
        }

        // Ngoại suy mượt ngoài 20 đơn vị theo độ dốc đoạn cuối bảng NPH (16 → 20).
        let tailSlope = (table[19] - table[15]) / 4.0
        return table[19] + (distanceUnits - 20.0) * tailSlope
    }

    /// Tính lực bắn (`0.0 ... 100.0`) không gió từ `distanceUnits`, `angle` (`-30°...85°`) và `deltaY` (dương nếu địch cao hơn).
    public func calculatePower(
        distanceUnits: Double,
        angle: Double,
        deltaY: Double
    ) -> Double {
        let d = distanceUnits.isFinite ? max(distanceUnits, 0.0) : 0.0
        let dy = deltaY.isFinite ? deltaY : 0.0
        guard d > 0.05 || abs(dy) > 0.05 else {
            return 0.0
        }

        let safeAngle = min(max(angle.isFinite ? angle : 50.0, -30.0), 85.0)
        let theta = safeAngle * .pi / 180.0

        // Trường hợp góc rất thấp hoặc góc âm (-30° ..< 5°) khi đứng trên cao bắn xuống thấp.
        if safeAngle < 5.0 {
            let refDistance = max(d, 1.0)
            let p20 = lookupTable(Self.table20, distanceUnits: refDistance)
            let gEff = (p20 * p20 * sin(40.0 * .pi / 180.0)) / refDistance
            let verticalClearance = d * tan(theta) - dy
            guard verticalClearance > 0.20 else {
                return 100.0
            }
            let cosTheta = max(cos(theta), 0.10)
            let rawPower = sqrt((gEff * d * d) / (2.0 * cosTheta * cosTheta * verticalClearance))
            return rawPower.isFinite ? min(max(rawPower, 0.0), 100.0) : 100.0
        }

        let levelPower = interpolateLevelPower(distanceUnits: d, angleDeg: safeAngle)
        guard abs(dy) >= 0.02 else {
            return min(max(levelPower, 0.0), 100.0)
        }

        // Bù trừ chênh cao địa hình chính xác theo hình học parabol không gió.
        let verticalRiseRef = max(d * tan(theta), 0.25)
        let elevationFactor = 1.0 - (dy / verticalRiseRef)
        guard elevationFactor > 0.12 else {
            return 100.0
        }

        let adjustedPower = levelPower / sqrt(elevationFactor)
        return adjustedPower.isFinite ? min(max(adjustedPower, 0.0), 100.0) : 100.0
    }

    public func holdSeconds(forPower power: Double) -> Double {
        let clamped = power.isFinite ? min(max(power, 0.0), 100.0) : 0.0
        return (clamped / 100.0) * Self.fullPowerHoldSeconds
    }

    /// Sinh 30 điểm quỹ đạo parabol không gió (`CGPoint`, tọa độ chuẩn hóa `0.0 - 1.0` trên Minimap) nối từ `playerNorm` tới `enemyNorm`.
    public func generateMinimapTrajectoryPoints(
        playerNorm: CGPoint,
        enemyNorm: CGPoint,
        angleDeg: Double,
        minimapAspectHOverW: Double
    ) -> [CGPoint] {
        let stepCount = 30
        let px = Double(playerNorm.x)
        let py = Double(playerNorm.y)
        let ex = Double(enemyNorm.x)
        let ey = Double(enemyNorm.y)

        let dx = ex - px
        let dyScreen = ey - py
        let absDx = abs(dx)
        let safeAspect = min(max(minimapAspectHOverW, 0.35), 2.5)
        let safeAngle = min(max(angleDeg, -30.0), 85.0)
        let theta = safeAngle * .pi / 180.0

        // Đường parabol tiếp tuyến đúng góc bắn tại điểm xuất phát và cắm thẳng vào mục tiêu.
        let slopeScreen = tan(theta) / safeAspect
        let rawCurvature = dyScreen + absDx * slopeScreen
        let maxTopClearance = max(min(py, ey) - 0.04, 0.05)
        let archHeight: Double
        if rawCurvature > 0.0 {
            archHeight = min(rawCurvature * 0.25, maxTopClearance)
        } else {
            archHeight = 0.02
        }

        var points: [CGPoint] = []
        points.reserveCapacity(stepCount)

        for i in 0..<stepCount {
            let u = Double(i) / Double(stepCount - 1)
            let x = px + dx * u
            let y = py + dyScreen * u - archHeight * 4.0 * u * (1.0 - u)
            points.append(
                CGPoint(
                    x: min(max(x, 0.01), 0.99),
                    y: min(max(y, 0.02), 0.98)
                )
            )
        }

        return points
    }

    /// Tính hoàn chỉnh thông số chiến đấu không gió, 3 mức lực góc chuẩn (30°, 50°, 65°), làm mượt EMA và đóng gói `TelemetryData`.
    public func buildBattleTelemetry(
        frameId: Int,
        playerNorm: CGPoint,
        enemyNorm: CGPoint,
        allEnemiesNorm: [CGPoint],
        cameraWidthNorm: Double,
        minimapAspectHOverW: Double,
        angle: Double,
        minimapJPEG: Data?,
        smoother: BallisticsEMASmoother? = nil,
        targetSwitched: Bool = false
    ) -> TelemetryData {
        let safeCamW = min(max(cameraWidthNorm, 0.12), 0.90)
        let safeAspect = min(max(minimapAspectHOverW, 0.35), 2.5)
        let safeAngle = min(max(angle.isFinite ? angle : 50.0, -30.0), 85.0)

        let rawDistanceUnits = (abs(Double(enemyNorm.x - playerNorm.x)) / safeCamW) * Self.unitsPerScreen
        let rawDeltaY = ((Double(playerNorm.y - enemyNorm.y) * safeAspect) / safeCamW) * Self.unitsPerScreen
        let rawPower = calculatePower(
            distanceUnits: rawDistanceUnits,
            angle: safeAngle,
            deltaY: rawDeltaY
        )

        let resolved: SmoothedBallistics
        if let smoother {
            resolved = smoother.smooth(
                playerNorm: playerNorm,
                enemyNorm: enemyNorm,
                distanceUnits: rawDistanceUnits,
                deltaY: rawDeltaY,
                power: rawPower,
                targetSwitched: targetSwitched
            )
        } else {
            resolved = SmoothedBallistics(
                playerNorm: playerNorm,
                enemyNorm: enemyNorm,
                distanceUnits: rawDistanceUnits,
                deltaY: rawDeltaY,
                power: rawPower
            )
        }

        let p30 = calculatePower(distanceUnits: resolved.distanceUnits, angle: 30.0, deltaY: resolved.deltaY)
        let p50 = calculatePower(distanceUnits: resolved.distanceUnits, angle: 50.0, deltaY: resolved.deltaY)
        let p65 = calculatePower(distanceUnits: resolved.distanceUnits, angle: 65.0, deltaY: resolved.deltaY)

        let trajectory = generateMinimapTrajectoryPoints(
            playerNorm: resolved.playerNorm,
            enemyNorm: resolved.enemyNorm,
            angleDeg: safeAngle,
            minimapAspectHOverW: safeAspect
        )

        let finalEnemies = allEnemiesNorm.isEmpty ? [resolved.enemyNorm] : allEnemiesNorm

        return TelemetryData(
            frameId: frameId,
            isInBattle: true,
            distanceUnits: resolved.distanceUnits,
            deltaY: resolved.deltaY,
            angle: safeAngle,
            power: resolved.power,
            holdSeconds: holdSeconds(forPower: resolved.power),
            playerNorm: resolved.playerNorm,
            enemyNorm: resolved.enemyNorm,
            allEnemiesNorm: finalEnemies,
            minimapJPEG: minimapJPEG,
            trajectoryPoints: trajectory,
            power30: p30,
            power50: p50,
            power65: p65
        )
    }

    // MARK: - Angle Table Interpolation

    private func interpolateLevelPower(distanceUnits d: Double, angleDeg: Double) -> Double {
        if angleDeg >= 65.0 {
            let p65 = lookupTable(Self.table65, distanceUnits: d)
            let sin2 = max(sin(2.0 * angleDeg * .pi / 180.0), 0.08)
            return p65 * sqrt(sin(130.0 * .pi / 180.0) / sin2)
        }

        if angleDeg >= 50.0 {
            let t = (angleDeg - 50.0) / 15.0
            let p50 = lookupTable(Self.table50, distanceUnits: d)
            let p65 = lookupTable(Self.table65, distanceUnits: d)
            return p50 + t * (p65 - p50)
        }

        if angleDeg >= 30.0 {
            let t = (angleDeg - 30.0) / 20.0
            let p30 = lookupTable(Self.table30, distanceUnits: d)
            let p50 = lookupTable(Self.table50, distanceUnits: d)
            return p30 + t * (p50 - p30)
        }

        if angleDeg >= 20.0 {
            let t = (angleDeg - 20.0) / 10.0
            let p20 = lookupTable(Self.table20, distanceUnits: d)
            let p30 = lookupTable(Self.table30, distanceUnits: d)
            return p20 + t * (p30 - p20)
        }

        // Góc thấp từ 5° đến 20°.
        let p20 = lookupTable(Self.table20, distanceUnits: d)
        let sin2 = max(sin(2.0 * angleDeg * .pi / 180.0), 0.14)
        return p20 * sqrt(sin(40.0 * .pi / 180.0) / sin2)
    }
}
