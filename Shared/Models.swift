import CoreGraphics
import Foundation

/// Vùng chữ nhật chuẩn hóa theo tỉ lệ `0.0 - 1.0` so với kích thước khung hình.
/// Đảm bảo hoạt động chính xác trên mọi kích thước và độ phân giải màn hình iPhone.
public struct NormalizedRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        let clampedX = Self.clamp01(x)
        let clampedY = Self.clamp01(y)
        self.x = clampedX
        self.y = clampedY
        self.width = min(Self.clamp01(width), 1.0 - clampedX)
        self.height = min(Self.clamp01(height), 1.0 - clampedY)
    }

    /// Trả về `CGRect` chuẩn hóa (`0.0 ... 1.0`).
    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    /// Chuyển đổi từ tọa độ chuẩn hóa (gốc trên-trái) sang tọa độ pixel thực tế của khung hình.
    public func pixelRect(width imageWidth: Int, height imageHeight: Int) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else { return .zero }
        let w = Double(imageWidth)
        let h = Double(imageHeight)
        let raw = CGRect(
            x: x * w,
            y: y * h,
            width: width * w,
            height: height * h
        ).integral
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        return raw.intersection(bounds)
    }

    /// Chuyển đổi từ tọa độ chuẩn hóa (gốc trên-trái) sang tọa độ pixel thực tế theo `CGSize`.
    public func pixelRect(for imageSize: CGSize) -> CGRect {
        pixelRect(width: Int(imageSize.width), height: Int(imageSize.height))
    }

    /// Chuyển đổi sang hệ tọa độ chuẩn hóa của Apple Vision (gốc dưới-trái, `0.0 - 1.0`).
    public var visionNormalizedRect: CGRect {
        CGRect(
            x: x,
            y: 1.0 - y - height,
            width: width,
            height: height
        )
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0.0 }
        return min(max(value, 0.0), 1.0)
    }
}

public typealias NormalizedROI = NormalizedRect

/// Cấu hình 3 vùng nhận diện (ROI) chuẩn hóa trên màn hình game.
public struct ROIConfig: Codable, Equatable, Sendable {
    public var minimapRect: NormalizedRect
    public var windRect: NormalizedRect
    public var angleRect: NormalizedRect

    public init(
        minimapRect: NormalizedRect,
        windRect: NormalizedRect,
        angleRect: NormalizedRect
    ) {
        self.minimapRect = minimapRect
        self.windRect = windRect
        self.angleRect = angleRect
    }

    public static let `default` = ROIConfig(
        minimapRect: NormalizedRect(x: 0.72, y: 0.03, width: 0.25, height: 0.20),
        windRect: NormalizedRect(x: 0.44, y: 0.03, width: 0.12, height: 0.07),
        angleRect: NormalizedRect(x: 0.11, y: 0.78, width: 0.10, height: 0.08)
    )
}

/// Tham số hiệu chỉnh đạn đạo và thời gian giữ thanh lực.
public struct BallisticsConfig: Codable, Equatable, Sendable {
    public var selectedAngle: Double
    public var powerFactor: Double
    public var windFactor: Double
    public var maxHoldSeconds: Double
    public var useOCRAngle: Bool

    public init(
        selectedAngle: Double = 65.0,
        powerFactor: Double = 1.0,
        windFactor: Double = 1.0,
        maxHoldSeconds: Double = 2.2,
        useOCRAngle: Bool = false
    ) {
        self.selectedAngle = selectedAngle
        self.powerFactor = powerFactor
        self.windFactor = windFactor
        self.maxHoldSeconds = maxHoldSeconds
        self.useOCRAngle = useOCRAngle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.selectedAngle = try container.decodeIfPresent(Double.self, forKey: .selectedAngle) ?? 65.0
        self.powerFactor = try container.decodeIfPresent(Double.self, forKey: .powerFactor) ?? 1.0
        self.windFactor = try container.decodeIfPresent(Double.self, forKey: .windFactor) ?? 1.0
        self.maxHoldSeconds = try container.decodeIfPresent(Double.self, forKey: .maxHoldSeconds) ?? 2.2
        self.useOCRAngle = try container.decodeIfPresent(Bool.self, forKey: .useOCRAngle) ?? false
    }

    public static let `default` = BallisticsConfig()
}

/// Dữ liệu đo đạc và kết quả tính lực bắn theo thời gian thực.
public struct TelemetryData: Codable, Equatable, Sendable {
    public var dx: Double
    public var dy: Double
    public var wind: Double
    public var angle: Double
    public var calculatedPower: Double
    public var holdSeconds: Double
    public var timestamp: TimeInterval

    public init(
        dx: Double,
        dy: Double,
        wind: Double,
        angle: Double,
        calculatedPower: Double,
        holdSeconds: Double,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.dx = dx
        self.dy = dy
        self.wind = wind
        self.angle = angle
        self.calculatedPower = min(max(calculatedPower, 0.0), 100.0)
        self.holdSeconds = max(holdSeconds, 0.0)
        self.timestamp = timestamp
    }

    public static let placeholder = TelemetryData(
        dx: 0.0,
        dy: 0.0,
        wind: 0.0,
        angle: 65.0,
        calculatedPower: 0.0,
        holdSeconds: 0.0,
        timestamp: 0
    )
}
