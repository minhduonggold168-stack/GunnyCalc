import Foundation

/// Kết quả sau làm mượt EMA giúp chỉ số chiến đấu đứng yên sắc nét, không rung giật.
public struct SmoothedBallistics: Equatable, Sendable {
    public let playerX: Double
    public let playerY: Double
    public let enemyX: Double
    public let enemyY: Double
    public let distanceUnits: Double
    public let deltaYUnits: Double
    public let power: Double
}

/// Bộ lọc trung bình trượt hàm mũ (EMA, mặc định `alpha = 0.35`) cho tọa độ và lực bắn.
public final class BallisticsEMASmoother {
    public let alpha: Double

    private var isInitialized = false
    private var playerX = 0.20
    private var playerY = 0.68
    private var enemyX = 0.72
    private var enemyY = 0.68
    private var distanceUnits = 13.0
    private var deltaYUnits = 0.0
    private var power = 62.0

    public init(alpha: Double = 0.35) {
        self.alpha = min(max(alpha, 0.05), 1.0)
    }

    public func reset() {
        isInitialized = false
    }

    public func smooth(
        playerX rawPX: Double,
        playerY rawPY: Double,
        enemyX rawEX: Double,
        enemyY rawEY: Double,
        distanceUnits rawDistance: Double,
        deltaYUnits rawDeltaY: Double,
        power rawPower: Double,
        targetSwitched: Bool
    ) -> SmoothedBallistics {
        let wasInitialized = isInitialized
        let enemyJump = hypot(rawEX - enemyX, rawEY - enemyY)

        if !wasInitialized || targetSwitched || enemyJump > 0.15 {
            isInitialized = true
            playerX = !wasInitialized ? rawPX : blend(prev: playerX, raw: rawPX)
            playerY = !wasInitialized ? rawPY : blend(prev: playerY, raw: rawPY)
            enemyX = rawEX
            enemyY = rawEY
            distanceUnits = rawDistance
            deltaYUnits = rawDeltaY
            power = rawPower
        } else {
            playerX = blend(prev: playerX, raw: rawPX)
            playerY = blend(prev: playerY, raw: rawPY)
            enemyX = blend(prev: enemyX, raw: rawEX)
            enemyY = blend(prev: enemyY, raw: rawEY)
            distanceUnits = blend(prev: distanceUnits, raw: rawDistance)
            deltaYUnits = blend(prev: deltaYUnits, raw: rawDeltaY)
            power = blend(prev: power, raw: rawPower)
        }

        return SmoothedBallistics(
            playerX: playerX,
            playerY: playerY,
            enemyX: enemyX,
            enemyY: enemyY,
            distanceUnits: distanceUnits,
            deltaYUnits: deltaYUnits,
            power: power
        )
    }

    private func blend(prev: Double, raw: Double) -> Double {
        guard raw.isFinite else { return prev }
        return alpha * raw + (1.0 - alpha) * prev
    }
}

/// Bộ tính toán đạn đạo Gunny Mobi chuẩn hóa theo thước Minimap:
/// - 1 màn hình (chiều rộng khung camera trắng) = `10.0` đơn vị.
/// - Tầm bắn tối đa tại góc `45°`, lực `100.0`, gió `0.0` = `33.5` đơn vị.
/// - Điểm neo chuẩn thực tế: cự ly `13.0`, góc `56°`, gió `0.0` -> lực `62.0`.
public struct BallisticsEngine: Sendable {
    public static let unitsPerScreen: Double = 10.0
    public static let maxRangeAt45FullPower: Double = 33.5

    // Hằng số vật lý lực cản không khí tuyến tính hiệu chỉnh chuẩn Gunny Mobi.
    private static let gravity: Double = 211.942810
    private static let dragGamma: Double = 0.878324
    private static let windAccelPerUnit: Double = 6.2127

    public init() {}

    /// Tính lực bắn `0.0 ... 100.0` theo cự ly (`distanceUnits`), chênh cao (`deltaYUnits`, dương khi địch cao hơn), góc (`10°...85°`) và gió theo hướng bắn (`directedWind = signedWind * shotSign`).
    public func calculatePower(
        distanceUnits: Double,
        deltaYUnits: Double,
        angle: Double,
        directedWind: Double
    ) -> Double {
        let safeDistance = max(distanceUnits, 0.0)
        guard safeDistance > 0.05 || abs(deltaYUnits) > 0.05 else {
            return 0.0
        }

        let safeAngle = min(max(angle, 10.0), 85.0)
        let safeWind = min(max(directedWind, -5.0), 5.0)

        var loPower = 0.0
        var foundBracket = false
        var hiPower = 100.0

        for step in 1...25 {
            let candidateP = Double(step) * 4.0
            if let impact = simulateImpact(
                power: candidateP,
                angleDeg: safeAngle,
                directedWind: safeWind,
                deltaYUnits: deltaYUnits
            ), impact.range >= safeDistance {
                loPower = Double(step - 1) * 4.0
                hiPower = candidateP
                foundBracket = true
                break
            }
        }

        guard foundBracket else {
            return 100.0
        }

        for _ in 0..<32 {
            let mid = 0.5 * (loPower + hiPower)
            if let impact = simulateImpact(
                power: mid,
                angleDeg: safeAngle,
                directedWind: safeWind,
                deltaYUnits: deltaYUnits
            ), impact.range >= safeDistance {
                hiPower = mid
            } else {
                loPower = mid
            }
        }

        let solved = 0.5 * (loPower + hiPower)
        return solved.isFinite ? min(max(solved, 0.0), 100.0) : 0.0
    }

    /// Sinh 30 điểm quỹ đạo parabol thực tế trong hệ tọa độ Minimap (`0.0 - 1.0`) nối từ người chơi tới mục tiêu.
    public func generateMinimapTrajectoryPoints(
        playerX: Double,
        playerY: Double,
        enemyX: Double,
        enemyY: Double,
        cameraWidthNorm: Double,
        minimapAspectHOverW: Double,
        angleDeg: Double,
        signedWind: Double,
        power: Double
    ) -> [TrajectoryPoint] {
        let stepCount = 30
        let safeCamW = min(max(cameraWidthNorm, 0.08), 0.95)
        let safeAspect = min(max(minimapAspectHOverW, 0.35), 2.5)
        let safeAngle = min(max(angleDeg, 10.0), 85.0)
        let safePower = min(max(power, 1.0), 100.0)

        let shotSign = enemyX >= playerX ? 1.0 : -1.0
        let directedWind = min(max(signedWind * shotSign, -5.0), 5.0)
        let deltaYUnits = ((playerY - enemyY) * safeAspect / safeCamW) * Self.unitsPerScreen

        let flightTime: Double
        if let impact = simulateImpact(
            power: safePower,
            angleDeg: safeAngle,
            directedWind: directedWind,
            deltaYUnits: deltaYUnits
        ) {
            flightTime = max(impact.flightTime, 0.12)
        } else {
            let theta = safeAngle * .pi / 180.0
            let estimatedT = (2.0 * safePower * sin(theta)) / Self.gravity
            flightTime = max(estimatedT, 0.25)
        }

        let endPhys = positionAt(
            time: flightTime,
            power: safePower,
            angleDeg: safeAngle,
            directedWind: directedWind
        )
        let endNormX = playerX + shotSign * (endPhys.x / Self.unitsPerScreen) * safeCamW
        let endNormY = playerY - (endPhys.y / Self.unitsPerScreen) * safeCamW / safeAspect
        let residualX = enemyX - endNormX
        let residualY = enemyY - endNormY

        var points: [TrajectoryPoint] = []
        points.reserveCapacity(stepCount)

        for i in 0..<stepCount {
            let u = Double(i) / Double(stepCount - 1)
            let t = u * flightTime
            let pos = positionAt(
                time: t,
                power: safePower,
                angleDeg: safeAngle,
                directedWind: directedWind
            )
            let rawX = playerX + shotSign * (pos.x / Self.unitsPerScreen) * safeCamW + u * residualX
            let rawY = playerY - (pos.y / Self.unitsPerScreen) * safeCamW / safeAspect + u * residualY
            points.append(
                TrajectoryPoint(
                    x: min(max(rawX, 0.01), 0.99),
                    y: min(max(rawY, 0.02), 0.98)
                )
            )
        }

        return points
    }

    /// Tính hoàn chỉnh cự ly (`distanceUnits`), độ lệch cao (`deltaYUnits`), lực bắn (`power`), làm mượt EMA và đóng gói `TelemetryData`.
    public func buildTelemetry(
        frameId: Int,
        playerX: Double,
        playerY: Double,
        enemyX: Double,
        enemyY: Double,
        enemies: [NormalizedPoint] = [],
        lockedEnemyIndex: Int = 0,
        cameraRect: NormalizedRect? = nil,
        cameraWidthNorm: Double = 0.38,
        minimapAspectHOverW: Double = 0.72,
        angle: Double,
        windMagnitude: Double,
        windDir: Int,
        minimapJPEG: Data? = nil,
        smoother: BallisticsEMASmoother? = nil,
        targetSwitched: Bool = false
    ) -> TelemetryData {
        let safeCamW = min(max(cameraWidthNorm, 0.08), 0.95)
        let safeAspect = min(max(minimapAspectHOverW, 0.35), 2.5)
        let safeDir = windDir < 0 ? -1 : 1
        let signedWind = min(max(abs(windMagnitude), 0.0), 5.0) * Double(safeDir)
        let safeAngle = min(max(angle, 10.0), 85.0)

        let rawDistanceUnits = (abs(enemyX - playerX) / safeCamW) * Self.unitsPerScreen
        let rawDeltaYUnits = ((playerY - enemyY) * safeAspect / safeCamW) * Self.unitsPerScreen
        let shotSign = enemyX >= playerX ? 1.0 : -1.0
        let rawPower = calculatePower(
            distanceUnits: rawDistanceUnits,
            deltaYUnits: rawDeltaYUnits,
            angle: safeAngle,
            directedWind: signedWind * shotSign
        )

        let resolved: SmoothedBallistics
        if let smoother {
            resolved = smoother.smooth(
                playerX: playerX,
                playerY: playerY,
                enemyX: enemyX,
                enemyY: enemyY,
                distanceUnits: rawDistanceUnits,
                deltaYUnits: rawDeltaYUnits,
                power: rawPower,
                targetSwitched: targetSwitched
            )
        } else {
            resolved = SmoothedBallistics(
                playerX: playerX,
                playerY: playerY,
                enemyX: enemyX,
                enemyY: enemyY,
                distanceUnits: rawDistanceUnits,
                deltaYUnits: rawDeltaYUnits,
                power: rawPower
            )
        }

        let points = generateMinimapTrajectoryPoints(
            playerX: resolved.playerX,
            playerY: resolved.playerY,
            enemyX: resolved.enemyX,
            enemyY: resolved.enemyY,
            cameraWidthNorm: safeCamW,
            minimapAspectHOverW: safeAspect,
            angleDeg: safeAngle,
            signedWind: signedWind,
            power: resolved.power
        )

        let finalEnemies = enemies.isEmpty
            ? [NormalizedPoint(x: resolved.enemyX, y: resolved.enemyY)]
            : enemies
        let clampedLockedIndex = min(max(lockedEnemyIndex, 0), max(finalEnemies.count - 1, 0))

        return TelemetryData(
            frameId: frameId,
            playerX: resolved.playerX,
            playerY: resolved.playerY,
            enemyX: resolved.enemyX,
            enemyY: resolved.enemyY,
            enemies: finalEnemies,
            lockedEnemyIndex: clampedLockedIndex,
            cameraRect: cameraRect,
            cameraWidthNorm: safeCamW,
            distanceUnits: resolved.distanceUnits,
            deltaYUnits: resolved.deltaYUnits,
            angle: safeAngle,
            wind: abs(windMagnitude),
            windDir: safeDir,
            power: resolved.power,
            trajectoryPoints: points,
            minimapJPEG: minimapJPEG
        )
    }

    // MARK: - Projectile Motion Helpers

    private func positionAt(
        time t: Double,
        power: Double,
        angleDeg: Double,
        directedWind: Double
    ) -> (x: Double, y: Double) {
        let theta = angleDeg * .pi / 180.0
        let vx0 = power * cos(theta)
        let vy0 = power * sin(theta)
        let gamma = Self.dragGamma
        let g = Self.gravity
        let vw = (directedWind * Self.windAccelPerUnit) / gamma

        let expFactor = 1.0 - exp(-gamma * t)
        let x = ((vx0 - vw) / gamma) * expFactor + vw * t
        let y = ((vy0 + g / gamma) / gamma) * expFactor - (g / gamma) * t
        return (x, y)
    }

    private func simulateImpact(
        power: Double,
        angleDeg: Double,
        directedWind: Double,
        deltaYUnits: Double
    ) -> (range: Double, flightTime: Double)? {
        guard power > 0.0001 else { return nil }

        let theta = angleDeg * .pi / 180.0
        let vy0 = power * sin(theta)
        let gamma = Self.dragGamma
        let g = Self.gravity

        let tPeak = log((gamma * vy0 + g) / g) / gamma
        let peakPos = positionAt(time: tPeak, power: power, angleDeg: angleDeg, directedWind: directedWind)
        guard peakPos.y >= deltaYUnits else {
            return nil
        }

        var lo = tPeak
        var hi = max(tPeak * 2.0, 0.20)
        while positionAt(time: hi, power: power, angleDeg: angleDeg, directedWind: directedWind).y > deltaYUnits && hi < 40.0 {
            hi *= 2.0
        }

        guard positionAt(time: hi, power: power, angleDeg: angleDeg, directedWind: directedWind).y <= deltaYUnits else {
            return nil
        }

        for _ in 0..<45 {
            let mid = 0.5 * (lo + hi)
            if positionAt(time: mid, power: power, angleDeg: angleDeg, directedWind: directedWind).y > deltaYUnits {
                lo = mid
            } else {
                hi = mid
            }
        }

        let tImpact = 0.5 * (lo + hi)
        let endPos = positionAt(time: tImpact, power: power, angleDeg: angleDeg, directedWind: directedWind)
        return (endPos.x, tImpact)
    }
}
