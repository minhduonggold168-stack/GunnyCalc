import Foundation

/// Bộ tính lực bắn tức thời (không làm mượt EMA, độ trễ 0 khung hình) theo bảng chuẩn NPH Gunny Mobi không gió.
/// - Quy chuẩn toàn chiều rộng Minimap = `20.0` đơn vị cự ly (`1 màn hình = 10.0 đơn vị`).
/// - Nội suy tuyến tính chính xác tới `0.1` đơn vị cự ly cho dải góc `-35° ... 85°`.
public struct BallisticsEngine: Sendable {
    public static let minimapTotalUnits: Double = 20.0

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
            // Góc âm hoặc ngang khi đứng trên cao bắn xuống thấp: tham chiếu mượt theo bảng góc thấp 20°.
            rawPower = lookupTable(Self.table20, distanceUnits: d)
        }

        let clamped = rawPower.isFinite ? min(max(rawPower, 0.0), 100.0) : 0.0
        return (clamped * 10.0).rounded() / 10.0
    }
}
