import CoreGraphics
import Foundation

/// Kết quả kiểm tra vật cản địa hình dọc quỹ đạo parabol 25 điểm.
public struct TerrainRaycastResult: Equatable, Sendable {
    public let isBlocked: Bool
    public let suggestedAngle: Int

    public init(isBlocked: Bool, suggestedAngle: Int) {
        self.isBlocked = isBlocked
        self.suggestedAngle = min(max(suggestedAngle, -35), 85)
    }
}

/// Thuật toán tự học hiệu chỉnh sau phát bắn (Adaptive Online Calibration):
/// - So sánh điểm rơi thực tế (`actualDistance`) với `targetDistance`; nếu lệch > `0.3` đơn vị, cập nhật `mapScaleMultiplier`
///   bằng bước học `learningRate = 0.15` (giới hạn `0.85 ... 1.15`).
public final class AdaptiveCalibrationEngine {
    public static let learningRate: Double = 0.15
    public static let minMultiplier: Double = 0.85
    public static let maxMultiplier: Double = 1.15
    public static let errorDeadbandUnits: Double = 0.30

    public private(set) var mapScaleMultiplier: Double = 1.0

    public init(initialMultiplier: Double = 1.0) {
        self.mapScaleMultiplier = Self.clampMultiplier(initialMultiplier)
    }

    public func reset() {
        mapScaleMultiplier = 1.0
    }

    public func calibratedDistance(rawDistanceUnits: Double) -> Double {
        guard rawDistanceUnits.isFinite else { return 0.0 }
        return max(rawDistanceUnits, 0.0) * mapScaleMultiplier
    }

    @discardableResult
    public func recordShotOutcome(targetDistance: Double, actualDistance: Double) -> Double {
        guard targetDistance.isFinite, actualDistance.isFinite,
              targetDistance > 0.5, actualDistance > 0.2 else {
            return mapScaleMultiplier
        }

        let error = targetDistance - actualDistance
        guard abs(error) > Self.errorDeadbandUnits else {
            return mapScaleMultiplier
        }

        let desiredRatio = min(max(targetDistance / actualDistance, 0.70), 1.40)
        let targetMultiplier = mapScaleMultiplier * desiredRatio
        let updated = mapScaleMultiplier + Self.learningRate * (targetMultiplier - mapScaleMultiplier)
        mapScaleMultiplier = Self.clampMultiplier(updated)
        return mapScaleMultiplier
    }

    private static func clampMultiplier(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, minMultiplier), maxMultiplier)
    }
}

/// Bộ tính lực bắn tức thời (không làm mượt EMA) theo bảng chuẩn NPH Gunny Mobi không gió + kiểm tra vật cản địa hình (Terrain Raycast).
public struct BallisticsEngine: Sendable {
    public static let unitsPerScreen: Double = 10.0
    public static let minimapTotalUnits: Double = 20.0
    public static let raycastSampleCount: Int = 25

    // Bảng lực chuẩn chính thức NPH Gunny Mobi không gió (cự ly 1 → 20).
    public static let table20: [Double] = [10, 19, 25, 30, 36, 40, 44, 48, 51, 54, 57, 60, 62, 65, 67, 70, 72, 75, 77, 80]
    public static let table30: [Double] = [14, 20, 24, 28, 32, 35, 38, 41, 44, 47, 50, 52, 55, 57, 60, 62, 65, 67, 69, 72]
    public static let table50: [Double] = [14, 20, 25, 29, 32, 36, 39, 42, 45, 48, 50, 53, 55, 58, 60, 63, 65, 68, 70, 72]
    public static let table65: [Double] = [13, 21, 26, 32, 37, 41, 45, 49, 53, 56, 58, 61, 64, 67, 70, 73, 76, 79, 82, 85]

    public init() {}

    /// Tra cứu nội suy tuyến tính chính xác tới `0.1` đơn vị cự ly từ bảng NPH (1 → 20).
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

        let tailSlope = (table[19] - table[15]) / 4.0
        return table[19] + (distanceUnits - 20.0) * tailSlope
    }

    /// Tính lực bắn (`0.0 ... 100.0`, làm tròn 1 chữ số thập phân) từ `distanceUnits` và góc nguyên `angle` (`-35 ... 85`).
    public func calculatePower(distanceUnits: Double, angle: Int) -> Double {
        let d = distanceUnits.isFinite ? max(distanceUnits, 0.0) : 0.0
        guard d > 0.05 else { return 0.0 }

        let safeAngle = Double(min(max(angle, -35), 85))
        let rawPower: Double

        if safeAngle >= 65.0 {
            let p65 = lookupTable(Self.table65, distanceUnits: d)
            let sin2 = max(sin(2.0 * safeAngle * .pi / 180.0), 0.08)
            rawPower = p65 * sqrt(sin(130.0 * .pi / 180.0) / sin2)
        } else if safeAngle >= 50.0 {
            let t = (safeAngle - 50.0) / 15.0
            let p50 = lookupTable(Self.table50, distanceUnits: d)
            let p65 = lookupTable(Self.table65, distanceUnits: d)
            rawPower = p50 + t * (p65 - p50)
        } else if safeAngle >= 30.0 {
            let t = (safeAngle - 30.0) / 20.0
            let p30 = lookupTable(Self.table30, distanceUnits: d)
            let p50 = lookupTable(Self.table50, distanceUnits: d)
            rawPower = p30 + t * (p50 - p30)
        } else if safeAngle >= 20.0 {
            let t = (safeAngle - 20.0) / 10.0
            let p20 = lookupTable(Self.table20, distanceUnits: d)
            let p30 = lookupTable(Self.table30, distanceUnits: d)
            rawPower = p20 + t * (p30 - p20)
        } else if safeAngle >= 5.0 {
            let p20 = lookupTable(Self.table20, distanceUnits: d)
            let sin2 = max(sin(2.0 * safeAngle * .pi / 180.0), 0.14)
            rawPower = p20 * sqrt(sin(40.0 * .pi / 180.0) / sin2)
        } else {
            rawPower = lookupTable(Self.table20, distanceUnits: d)
        }

        let clamped = rawPower.isFinite ? min(max(rawPower, 0.0), 100.0) : 0.0
        return (clamped * 10.0).rounded() / 10.0
    }

    // MARK: - Terrain Raycast Check (25-Point Parabolic Collision vs 32-Column Terrain Profile)

    /// Mô phỏng 25 điểm quỹ đạo parabol tại `angle` và đối chiếu với `terrainProfile` (32 cột độ cao từ đáy `0.0` lên đỉnh `1.0`).
    /// Nếu quỹ đạo cắt xuyên qua địa hình ở giữa (`isBlocked = true`), tự tìm góc tối thiểu vượt qua vật cản (`suggestedAngle`).
    public func checkTerrainObstruction(
        playerPos: CGPoint,
        enemyPos: CGPoint,
        minimapAspectHOverW: Double,
        terrainProfile: [Double],
        angle: Int
    ) -> TerrainRaycastResult {
        let clampedAngle = min(max(angle, -35), 85)
        guard terrainProfile.count >= 4 else {
            return TerrainRaycastResult(isBlocked: false, suggestedAngle: clampedAngle)
        }

        let absDx = abs(Double(enemyPos.x - playerPos.x))
        guard absDx >= 0.03 else {
            return TerrainRaycastResult(isBlocked: false, suggestedAngle: clampedAngle)
        }

        let safeAspect = min(max(minimapAspectHOverW, 0.18), 2.5)
        let hStart = min(max(1.0 - Double(playerPos.y), 0.0), 1.0)
        let hEnd = min(max(1.0 - Double(enemyPos.y), 0.0), 1.0)

        if isParabolicPathClear(
            angle: clampedAngle,
            hStart: hStart,
            hEnd: hEnd,
            absDx: absDx,
            aspect: safeAspect,
            terrainProfile: terrainProfile
        ) {
            return TerrainRaycastResult(isBlocked: false, suggestedAngle: clampedAngle)
        }

        // Tự động tìm góc nâng tối thiểu vượt qua vật cản (trong dải tới 85°).
        let searchStart = min(max(clampedAngle + 1, 10), 85)
        if searchStart <= 85 {
            for candidate in searchStart...85 {
                if isParabolicPathClear(
                    angle: candidate,
                    hStart: hStart,
                    hEnd: hEnd,
                    absDx: absDx,
                    aspect: safeAspect,
                    terrainProfile: terrainProfile
                ) {
                    return TerrainRaycastResult(isBlocked: true, suggestedAngle: candidate)
                }
            }
        }

        return TerrainRaycastResult(isBlocked: true, suggestedAngle: 85)
    }

    private func isParabolicPathClear(
        angle: Int,
        hStart: Double,
        hEnd: Double,
        absDx: Double,
        aspect: Double,
        terrainProfile: [Double]
    ) -> Bool {
        let theta = Double(angle) * .pi / 180.0
        let curvature = (absDx * tan(theta)) / aspect - (hEnd - hStart)
        let clearanceMargin = 0.025
        let colMax = terrainProfile.count - 1

        // Kiểm tra 25 điểm quỹ đạo (bỏ qua 2 điểm sát chân người chơi và 2 điểm sát điểm chạm mục tiêu).
        for k in 2..<(Self.raycastSampleCount - 2) {
            let u = Double(k) / Double(Self.raycastSampleCount - 1)
            let projHeight = hStart + (hEnd - hStart) * u + curvature * u * (1.0 - u)

            let colFloat = u * Double(colMax)
            let idxLo = min(max(Int(floor(colFloat)), 0), colMax)
            let idxHi = min(max(Int(ceil(colFloat)), 0), colMax)
            let terrainHeight = max(terrainProfile[idxLo], terrainProfile[idxHi])

            if projHeight < (terrainHeight + clearanceMargin) {
                return false
            }
        }

        return true
    }
}
