import CoreGraphics
import CoreVideo
import Foundation

// MARK: - Zero-Copy Raw Pixel Buffer View (BGRA & NV12, Zero Allocation Rotation)

/// Hướng xoay của `CVPixelBuffer` gốc so với chiều hiển thị logic ngang (tương ứng EXIF orientation tag).
public enum RawBufferOrientation: UInt32, Sendable {
    case up = 1        // Đã đúng chiều hiển thị
    case down = 3      // Xoay 180°
    case right = 6     // Buffer vật lý đứng dọc, hiển thị xoay 90° theo chiều kim đồng hồ
    case left = 8      // Buffer vật lý đứng dọc, hiển thị xoay 90° ngược chiều kim đồng hồ

    public init(exifRawValue: UInt32) {
        switch exifRawValue {
        case 3: self = .down
        case 6: self = .right
        case 8: self = .left
        default: self = .up
        }
    }
}

/// Lớp đọc pixel không cấp phát (Zero-Copy) trực tiếp từ vùng nhớ thô `BGRA` hoặc `420f/420v` (NV12) của `CVPixelBuffer`.
/// Tự động ánh xạ tọa độ logic `(lx, ly)` sang chỉ số mảng vật lý `(rawRow * bytesPerRow + rawCol * 4)` mà không tạo bộ đệm xoay mới.
public struct RawFrameBuffer {
    public enum PixelLayout {
        case bgra32(base: UnsafePointer<UInt8>, bytesPerRow: Int)
        case nv12(
            yBase: UnsafePointer<UInt8>,
            yBytesPerRow: Int,
            uvBase: UnsafePointer<UInt8>,
            uvBytesPerRow: Int,
            fullRange: Bool
        )
    }

    public let rawWidth: Int
    public let rawHeight: Int
    public let orientation: RawBufferOrientation
    public let layout: PixelLayout

    /// Kích thước logic sau khi áp dụng hướng xoay màn hình (không cấp phát RAM).
    public var width: Int {
        switch orientation {
        case .up, .down: return rawWidth
        case .left, .right: return rawHeight
        }
    }

    public var height: Int {
        switch orientation {
        case .up, .down: return rawHeight
        case .left, .right: return rawWidth
        }
    }

    public var isLandscape: Bool {
        width > height
    }

    public init(
        bgraBase: UnsafePointer<UInt8>,
        rawWidth: Int,
        rawHeight: Int,
        bytesPerRow: Int,
        orientation: RawBufferOrientation = .up
    ) {
        self.rawWidth = rawWidth
        self.rawHeight = rawHeight
        self.orientation = orientation
        self.layout = .bgra32(base: bgraBase, bytesPerRow: bytesPerRow)
    }

    /// Khởi tạo không cấp phát từ một `CVPixelBuffer` đã khóa (`.readOnly`).
    public init?(lockedPixelBuffer pixelBuffer: CVPixelBuffer, orientation: RawBufferOrientation = .up) {
        let rw = CVPixelBufferGetWidth(pixelBuffer)
        let rh = CVPixelBufferGetHeight(pixelBuffer)
        guard rw > 0, rh > 0 else { return nil }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if format == kCVPixelFormatType_32BGRA {
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
            guard bpr >= rw * 4 else { return nil }
            self.rawWidth = rw
            self.rawHeight = rh
            self.orientation = orientation
            self.layout = .bgra32(base: base, bytesPerRow: bpr)
            return
        }

        if format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
                  let yPtr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
                  let uvPtr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            let yBpr = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let uvBpr = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            self.rawWidth = rw
            self.rawHeight = rh
            self.orientation = orientation
            self.layout = .nv12(
                yBase: yPtr,
                yBytesPerRow: yBpr,
                uvBase: uvPtr,
                uvBytesPerRow: uvBpr,
                fullRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            )
            return
        }

        return nil
    }

    @inline(__always)
    private func physicalCoords(lx: Int, ly: Int) -> (Int, Int) {
        switch orientation {
        case .up:
            return (lx, ly)
        case .down:
            return (rawWidth - 1 - lx, rawHeight - 1 - ly)
        case .right:
            // EXIF .right: hàng 0 bên phải, cột 0 ở trên -> rawCol = ly, rawRow = rawHeight - 1 - lx.
            return (ly, rawHeight - 1 - lx)
        case .left:
            // EXIF .left: hàng 0 bên trái, cột 0 ở dưới -> rawCol = rawWidth - 1 - ly, rawRow = lx.
            return (rawWidth - 1 - ly, lx)
        }
    }

    /// Đọc trực tiếp `(r, g, b)` trong dải `0...255` tại tọa độ logic `(lx, ly)` (gốc trên-trái).
    @inline(__always)
    public func readRGB(x lx: Int, y ly: Int) -> (r: Int, g: Int, b: Int) {
        let (col, row) = physicalCoords(lx: lx, ly: ly)
        switch layout {
        case let .bgra32(base, bpr):
            let offset = row * bpr + col * 4
            let b = Int(base[offset])
            let g = Int(base[offset + 1])
            let r = Int(base[offset + 2])
            return (r, g, b)

        case let .nv12(yBase, yBpr, uvBase, uvBpr, fullRange):
            let yVal = Int(yBase[row * yBpr + col])
            let uvOffset = (row >> 1) * uvBpr + ((col >> 1) << 1)
            let d = Int(uvBase[uvOffset]) - 128
            let e = Int(uvBase[uvOffset + 1]) - 128
            let r: Int
            let g: Int
            let b: Int
            if fullRange {
                let c = yVal << 8
                r = (c + 359 * e + 128) >> 8
                g = (c - 88 * d - 183 * e + 128) >> 8
                b = (c + 454 * d + 128) >> 8
            } else {
                let c = max(yVal - 16, 0) * 298
                r = (c + 409 * e + 128) >> 8
                g = (c - 100 * d - 208 * e + 128) >> 8
                b = (c + 516 * d + 128) >> 8
            }
            return (
                min(max(r, 0), 255),
                min(max(g, 0), 255),
                min(max(b, 0), 255)
            )
        }
    }

    /// Đọc độ sáng `luma` (`0...255`) cực nhanh tại tọa độ logic `(lx, ly)`.
    @inline(__always)
    public func readLuma(x lx: Int, y ly: Int) -> Int {
        let (col, row) = physicalCoords(lx: lx, ly: ly)
        switch layout {
        case let .bgra32(base, bpr):
            let offset = row * bpr + col * 4
            let b = Int(base[offset])
            let g = Int(base[offset + 1])
            let r = Int(base[offset + 2])
            return (77 * r + 150 * g + 29 * b) >> 8
        case let .nv12(yBase, yBpr, _, _, _):
            return Int(yBase[row * yBpr + col])
        }
    }

    /// Quy đổi `normRect` Top-Left (`0...1`) sang vùng pixel nguyên hợp lệ bên trong ảnh logic.
    public func pixelBounds(for normRect: CGRect) -> (x0: Int, y0: Int, w: Int, h: Int) {
        let x0 = min(max(Int((Double(normRect.origin.x) * Double(width)).rounded()), 0), max(width - 1, 0))
        let y0 = min(max(Int((Double(normRect.origin.y) * Double(height)).rounded()), 0), max(height - 1, 0))
        let x1 = min(max(Int(((Double(normRect.origin.x + normRect.size.width)) * Double(width)).rounded()), x0), width)
        let y1 = min(max(Int(((Double(normRect.origin.y + normRect.size.height)) * Double(height)).rounded()), y0), height)
        return (x0, y0, x1 - x0, y1 - y0)
    }
}

// MARK: - Analysis Result Models

public enum ScaleMeasurementSource: String, Equatable, Sendable {
    case yellowRulerTicks = "yellow_ruler_ticks"
    case whiteCameraBorderFallback = "camera_border_fallback"
    case cachedPreviousScale = "cached_scale"
}

public enum AngleMeasurementSource: String, Equatable, Sendable {
    case dpadTemplate = "dpad_16x24"
    case yellowAimRay = "yellow_aim_ray"
    case dpadCrossChecked = "dpad_and_ray"
    case dpadZeroHold = "dpad_zero_hold"
    case none = "none"
}

public struct DPadAngleResult: Equatable, Sendable {
    public let angle: Int?
    public let isExplicitZero: Bool
    public let confidence: Double
}

public struct RawFrameAnalysisResult: Equatable, Sendable {
    public let pixelsPerUnit: Double?
    public let scaleSource: ScaleMeasurementSource
    public let playerPx: CGPoint?
    public let enemyPx: CGPoint?
    public let enemyCount: Int
    public let distanceUnits: Double?
    public let deltaYUnits: Double?
    public let angle: Int?
    public let angleSource: AngleMeasurementSource
    public let dpadZeroDetected: Bool
}

// MARK: - 16x24 Binary Bitmap Template Matcher (< 9 KB RAM, < 0.5ms)

/// Bộ nhận diện chữ số góc bắn (`0-9` và dấu `-`) trên lưới nhị phân chuẩn hóa `16×24`.
/// Tổng dung lượng bảng mẫu + halo chỉ `8,448 bytes` (< 10 KB RAM), chạy thuần số nguyên.
public final class AngleBitmapTemplateMatcher {
    private static let gridW = 16
    private static let gridH = 24
    private static let cellCount = 384 // 16 * 24

    private struct CompiledTemplate {
        let digitValue: Int    // 0...9, hoặc -1 cho dấu '-'
        let mask: [UInt8]      // 384 bytes (0 hoặc 1)
        let halo: [UInt8]      // 384 bytes (giãn nở 1 ô xung quanh nét chữ)
        let foregroundCount: Int
    }

    private let digitTemplates: [CompiledTemplate] // 0...9 + mẫu phụ '1' chân đế (11 mẫu = 8.4 KB)
    private let minusTemplate: CompiledTemplate

    public init() {
        let patterns: [(Int, [String])] = [
            (0, [
                ".....######.....", "....#########...", "...###########..", "..#############.",
                ".######...######", ".#####....######", ".#####.....#####", "######.....#####",
                "######.....#####", "######.....#####", "######.....#####", "######.....#####",
                "######.....#####", "######.....#####", "######.....#####", "######.....#####",
                "######.....#####", "######.....#####", ".#####.....#####", ".######...######",
                "..#############.", "..#############.", "...###########..", "....#########..."
            ]),
            (1, [
                "...........#####", "..........######", "..........######", ".......#########",
                "......##########", "....############", "...#############", "################",
                "#######...######", "#####.....######", "###.......######", "..........######",
                "..........######", "..........######", "..........######", "..........######",
                "..........######", "..........######", "..........######", "..........######",
                "..........######", "..........######", "..........######", "..........######"
            ]),
            (1, [
                "......######....", ".....#######....", "....########....", "..##########....",
                "############....", "#####.######....", "......######....", "......######....",
                "......######....", "......######....", "......######....", "......######....",
                "......######....", "......######....", "......######....", "......######....",
                "......######....", "......######....", "......######....", "......######....",
                "################", "################", "################", "################"
            ]),
            (2, [
                "......######....", "....##########..", "...############.", "..##############",
                "..######...#####", ".#####.....#####", ".#####.....#####", ".#####.....#####",
                "...........#####", "...........#####", "...........#####", ".........######.",
                "........######..", ".......######...", ".......#####....", ".....######.....",
                "....######......", "...######.......", "...#####........", "..##############",
                ".###############", ".###############", ".###############", "################"
            ]),
            (3, [
                ".....#####......", "...#########....", "...##########...", ".#############..",
                ".#####...######.", "#####.....#####.", "#####.....#####.", "..##......#####.",
                "..........#####.", "........######..", ".......######...", "......######....",
                "......########..", "..........#####.", "...........#####", "...........#####",
                "..##.......#####", "####.......#####", "#####......#####", "#######..#######",
                ".##############.", "..############..", "...##########...", "....########...."
            ]),
            (4, [
                ".........#####..", ".........#####..", ".........#####..", "........######..",
                ".......#######..", "......########..", "......########..", ".....#########..",
                ".....#########..", "....####.#####..", "...#####.#####..", "...####..#####..",
                "..#####..#####..", "..####...#####..", ".####....#####..", "################",
                "################", "################", "################", "################",
                ".........#####..", ".........#####..", ".........#####..", ".........#####.."
            ]),
            (5, [
                "...#############", "...#############", "...#############", "...#############",
                "...#############", "..#####.........", "..#####.........", "..####..........",
                "..####.#####....", ".############...", ".#############..", ".##############.",
                ".#####....######", ".####......#####", "...........#####", "...........#####",
                "..###......#####", "#####......#####", "#####......#####", ".######...######",
                ".##############.", "..#############.", "...###########..", "....########...."
            ]),
            (6, [
                ".......#####....", "....#########...", "...###########..", "..#############.",
                "..######..######", ".######....#####", ".#####.....#####", "######..........",
                "#####...........", "#####..#####....", "#####.#######...", "###############.",
                "################", "#######...######", "######.....#####", "######.....#####",
                "#####......#####", "#####......#####", ".#####.....#####", ".######...######",
                "..##############", "...############.", "...###########..", "....#########..."
            ]),
            (7, [
                "################", "################", "################", "################",
                "################", "...........####.", "..........#####.", ".........#####..",
                ".........####...", "........####....", "........####....", ".......####.....",
                "......#####.....", "......#####.....", ".....######.....", ".....#####......",
                ".....#####......", ".....#####......", ".....####.......", "....#####.......",
                "....#####.......", "....#####.......", "....####........", "....####........"
            ]),
            (8, [
                ".....######.....", "....#########...", "..#############.", ".##############.",
                ".#####....######", ".#####.....#####", "######.....#####", ".#####.....#####",
                ".#####....######", "..#############.", "...###########..", "...###########..",
                "..##############", ".#####....######", "######.....#####", "#####......#####",
                "#####.......####", "######......####", "######.....#####", "#######....#####",
                ".###############", "..##############", "...############.", "....#########..."
            ]),
            (9, [
                "......#####.....", "....########....", "...##########...", "..#############.",
                ".######...######", ".#####.....#####", ".####......#####", "#####......#####",
                "#####......#####", "#####......#####", ".#####.....#####", ".###############",
                "..##############", "...#############", "...#############", ".....#####.#####",
                "...........#####", "...........#####", ".#####.....#####", ".######...######",
                "..#############.", "..############..", "...##########...", "....########...."
            ])
        ]

        let minusPattern: [String] = [
            "................", "................", "................", "................",
            "................", "................", "................", "................",
            "................", "################", "################", "################",
            "################", "################", "################", "................",
            "................", "................", "................", "................",
            "................", "................", "................", "................"
        ]

        self.digitTemplates = patterns.map { Self.compile(digitValue: $0.0, rows: $0.1) }
        self.minusTemplate = Self.compile(digitValue: -1, rows: minusPattern)
    }

    private static func compile(digitValue: Int, rows: [String]) -> CompiledTemplate {
        var mask = [UInt8](repeating: 0, count: cellCount)
        var fgCount = 0
        for y in 0..<min(rows.count, gridH) {
            let chars = Array(rows[y])
            for x in 0..<min(chars.count, gridW) {
                if chars[x] == "#" {
                    mask[y * gridW + x] = 1
                    fgCount += 1
                }
            }
        }
        let halo = dilate1(mask)
        return CompiledTemplate(digitValue: digitValue, mask: mask, halo: halo, foregroundCount: max(fgCount, 1))
    }

    private static func dilate1(_ src: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: cellCount)
        for y in 0..<gridH {
            let y0 = max(0, y - 1)
            let y1 = min(gridH - 1, y + 1)
            for x in 0..<gridW {
                let x0 = max(0, x - 1)
                let x1 = min(gridW - 1, x + 1)
                var hit: UInt8 = 0
                outer: for ny in y0...y1 {
                    let rowBase = ny * gridW
                    for nx in x0...x1 {
                        if src[rowBase + nx] != 0 {
                            hit = 1
                            break outer
                        }
                    }
                }
                out[y * gridW + x] = hit
            }
        }
        return out
    }

    private struct GlyphBox {
        var minX: Int
        var maxX: Int
        var minY: Int
        var maxY: Int
        var count: Int

        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        var midX: Double { Double(minX + maxX) * 0.5 }
        var midY: Double { Double(minY + maxY) * 0.5 }
    }

    /// Đọc trực tiếp góc bắn (`-35 ... 85`) từ vùng tâm D-pad (`x: 0.082...0.145, y: 0.745...0.855`) trên buffer thô.
    public func readAngle(from buffer: RawFrameBuffer, roi: CGRect = GunnyROIs.dpadAngle) -> DPadAngleResult {
        let bounds = buffer.pixelBounds(for: roi)
        let w = bounds.w
        let h = bounds.h
        guard w >= 16, h >= 16 else {
            return DPadAngleResult(angle: nil, isExplicitZero: false, confidence: 0.0)
        }

        let total = w * h
        var lumaBuf = [Int](repeating: 0, count: total)
        var validColor = [UInt8](repeating: 0, count: total)
        var histogram = [Int](repeating: 0, count: 256)

        for y in 0..<h {
            let gy = bounds.y0 + y
            let rowBase = y * w
            for x in 0..<w {
                let gx = bounds.x0 + x
                let (r, g, b) = buffer.readRGB(x: gx, y: gy)
                let lum = (77 * r + 150 * g + 29 * b) >> 8
                lumaBuf[rowBase + x] = lum
                histogram[lum] += 1
                // Chữ số góc màu trắng (R,G,B đều cao) hoặc xanh lơ sắc nét (G, B cao).
                if (r >= 135 && g >= 135 && b >= 135) || (g >= 150 && b >= 165 && r <= b) {
                    validColor[rowBase + x] = 1
                }
            }
        }

        let loLuma = percentileFromHistogram(histogram, total: total, ratio: 0.25)
        let hiLuma = percentileFromHistogram(histogram, total: total, ratio: 0.96)
        guard hiLuma - loLuma >= 50, hiLuma >= 130 else {
            return DPadAngleResult(angle: nil, isExplicitZero: false, confidence: 0.0)
        }

        let thresh = max(120, loLuma + ((hiLuma - loLuma) * 52) / 100)
        var binary = [UInt8](repeating: 0, count: total)
        for i in 0..<total {
            if lumaBuf[i] >= thresh && validColor[i] != 0 {
                binary[i] = 1
            }
        }

        var visited = [UInt8](repeating: 0, count: total)
        var rawGlyphs: [GlyphBox] = []
        rawGlyphs.reserveCapacity(8)
        var qx: [Int] = []
        var qy: [Int] = []
        qx.reserveCapacity(128)
        qy.reserveCapacity(128)

        for sy in 1..<(h - 1) {
            for sx in 1..<(w - 1) {
                let si = sy * w + sx
                guard binary[si] != 0, visited[si] == 0 else { continue }
                visited[si] = 1
                qx.removeAll(keepingCapacity: true)
                qy.removeAll(keepingCapacity: true)
                qx.append(sx)
                qy.append(sy)

                var head = 0
                var minX = sx
                var maxX = sx
                var minY = sy
                var maxY = sy
                var count = 0

                while head < qx.count {
                    let cx = qx[head]
                    let cy = qy[head]
                    head += 1
                    count += 1
                    if cx < minX { minX = cx }
                    if cx > maxX { maxX = cx }
                    if cy < minY { minY = cy }
                    if cy > maxY { maxY = cy }

                    let yFrom = max(0, cy - 1)
                    let yTo = min(h - 1, cy + 1)
                    let xFrom = max(0, cx - 1)
                    let xTo = min(w - 1, cx + 1)
                    for ny in yFrom...yTo {
                        let nRow = ny * w
                        for nx in xFrom...xTo {
                            if nx == cx && ny == cy { continue }
                            let ni = nRow + nx
                            if binary[ni] != 0 && visited[ni] == 0 {
                                visited[ni] = 1
                                qx.append(nx)
                                qy.append(ny)
                            }
                        }
                    }
                }

                let box = GlyphBox(minX: minX, maxX: maxX, minY: minY, maxY: maxY, count: count)
                // Loại bỏ nhiễu hoặc mũi tên viền ngoài D-pad nằm sát mép ROI.
                guard count >= 6,
                      box.width <= Int(Double(w) * 0.70),
                      box.height <= Int(Double(h) * 0.75),
                      box.midX >= Double(w) * 0.10, box.midX <= Double(w) * 0.90,
                      box.midY >= Double(h) * 0.12, box.midY <= Double(h) * 0.88 else {
                    continue
                }
                rawGlyphs.append(box)
            }
        }

        guard !rawGlyphs.isEmpty else {
            return DPadAngleResult(angle: nil, isExplicitZero: false, confidence: 0.0)
        }

        let minDigitH = max(8, Int(Double(h) * 0.16))
        var digitBoxes: [GlyphBox] = []
        for g in rawGlyphs where g.height >= minDigitH {
            let aspect = Double(g.width) / Double(g.height)
            if aspect > 1.05 && aspect < 2.2 {
                if let split = splitTouchingDigits(g, binary: binary, width: w) {
                    digitBoxes.append(split.0)
                    digitBoxes.append(split.1)
                } else {
                    digitBoxes.append(g)
                }
            } else if aspect <= 1.05 {
                digitBoxes.append(g)
            }
        }

        guard !digitBoxes.isEmpty else {
            return DPadAngleResult(angle: nil, isExplicitZero: false, confidence: 0.0)
        }

        // Lọc các chữ số nằm cùng hàng chính, bỏ ký hiệu '°' nhỏ phía trên-phải.
        let maxDigitH = digitBoxes.map(\.height).max() ?? minDigitH
        digitBoxes = digitBoxes.filter { Double($0.height) >= Double(maxDigitH) * 0.65 }
        guard !digitBoxes.isEmpty else {
            return DPadAngleResult(angle: nil, isExplicitZero: false, confidence: 0.0)
        }

        let avgMidY = digitBoxes.map(\.midY).reduce(0.0, +) / Double(digitBoxes.count)
        digitBoxes = digitBoxes.filter { abs($0.midY - avgMidY) <= Double(maxDigitH) * 0.35 }
        digitBoxes.sort { $0.minX < $1.minX }

        if digitBoxes.count > 2 {
            digitBoxes = Array(digitBoxes.prefix(2))
        }
        guard !digitBoxes.isEmpty, let firstDigit = digitBoxes.first else {
            return DPadAngleResult(angle: nil, isExplicitZero: false, confidence: 0.0)
        }

        var isNegative = false
        for g in rawGlyphs {
            if g.maxX < firstDigit.minX + 2
                && g.width >= Int(Double(g.height) * 1.35)
                && Double(g.height) <= Double(maxDigitH) * 0.42
                && abs(g.midY - avgMidY) <= Double(maxDigitH) * 0.35 {
                let normMinus = resampleToGrid(box: g, binary: binary, width: w, preserveNarrowAspect: false)
                if similarityScore(input: normMinus, template: minusTemplate) >= 0.45 {
                    isNegative = true
                    break
                }
            }
        }

        var value = 0
        var minConf = 1.0
        for box in digitBoxes {
            let (digit, conf) = matchDigit(box: box, binary: binary, width: w)
            guard conf >= 0.45 else {
                return DPadAngleResult(angle: nil, isExplicitZero: false, confidence: conf)
            }
            value = value * 10 + digit
            if conf < minConf { minConf = conf }
        }

        let signedValue = isNegative ? -value : value
        if signedValue == 0 {
            return DPadAngleResult(angle: nil, isExplicitZero: true, confidence: minConf)
        }
        guard signedValue >= -35 && signedValue <= 85 else {
            return DPadAngleResult(angle: nil, isExplicitZero: false, confidence: 0.0)
        }
        return DPadAngleResult(angle: signedValue, isExplicitZero: false, confidence: minConf)
    }

    private func splitTouchingDigits(_ g: GlyphBox, binary: [UInt8], width: Int) -> (GlyphBox, GlyphBox)? {
        let searchStart = g.minX + g.width / 3
        let searchEnd = g.maxX - g.width / 3
        guard searchEnd > searchStart else { return nil }

        var bestCol = (searchStart + searchEnd) / 2
        var minHits = Int.max
        for x in searchStart...searchEnd {
            var hits = 0
            for y in g.minY...g.maxY where binary[y * width + x] != 0 {
                hits += 1
            }
            if hits < minHits {
                minHits = hits
                bestCol = x
            }
        }
        let left = GlyphBox(minX: g.minX, maxX: bestCol, minY: g.minY, maxY: g.maxY, count: g.count / 2)
        let right = GlyphBox(minX: bestCol + 1, maxX: g.maxX, minY: g.minY, maxY: g.maxY, count: g.count / 2)
        return (left, right)
    }

    private func matchDigit(box: GlyphBox, binary: [UInt8], width: Int) -> (Int, Double) {
        let aspect = Double(box.width) / Double(max(box.height, 1))
        let isThinOne = aspect < 0.36
        let normGrid = resampleToGrid(box: box, binary: binary, width: width, preserveNarrowAspect: false)
        let upperLeftOpen = zoneFill(normGrid, x0: 0, x1: 4, y0: 4, y1: 9) < 0.16

        var bestDigit = 0
        var bestScore = -10.0

        for template in digitTemplates {
            let d = template.digitValue
            var score = similarityScore(input: normGrid, template: template)
            if d == 1 && isThinOne { score += 0.45 }
            if d == 3 && upperLeftOpen { score += 0.04 }
            if score > bestScore {
                bestScore = score
                bestDigit = d
            }
        }
        return (bestDigit, bestScore)
    }

    private func zoneFill(_ grid: [UInt8], x0: Int, x1: Int, y0: Int, y1: Int) -> Double {
        var hits = 0
        for y in y0...y1 {
            let rowBase = y * Self.gridW
            for x in x0...x1 where grid[rowBase + x] != 0 {
                hits += 1
            }
        }
        return Double(hits) / Double((x1 - x0 + 1) * (y1 - y0 + 1))
    }

    private func resampleToGrid(box: GlyphBox, binary: [UInt8], width: Int, preserveNarrowAspect: Bool) -> [UInt8] {
        var grid = [UInt8](repeating: 0, count: Self.cellCount)
        let bw = max(box.width, 1)
        let bh = max(box.height, 1)

        var targetW = Self.gridW
        var offsetX = 0
        if preserveNarrowAspect {
            let scaledW = max(3, min(Self.gridW, Int((Double(bw) / Double(bh) * Double(Self.gridH)).rounded())))
            targetW = scaledW
            offsetX = (Self.gridW - scaledW) / 2
        }

        for gy in 0..<Self.gridH {
            let sy0 = box.minY + (gy * bh) / Self.gridH
            let sy1 = min(box.maxY, max(sy0, box.minY + (((gy + 1) * bh) / Self.gridH) - 1))
            for gx in 0..<targetW {
                let sx0 = box.minX + (gx * bw) / targetW
                let sx1 = min(box.maxX, max(sx0, box.minX + (((gx + 1) * bw) / targetW) - 1))

                var onPixels = 0
                var sampleCount = 0
                for sy in sy0...sy1 {
                    let rowBase = sy * width
                    for sx in sx0...sx1 {
                        if binary[rowBase + sx] != 0 { onPixels += 1 }
                        sampleCount += 1
                    }
                }
                if onPixels * 5 >= sampleCount * 2 {
                    grid[gy * Self.gridW + (offsetX + gx)] = 1
                }
            }
        }
        return grid
    }

    private func similarityScore(input: [UInt8], template: CompiledTemplate) -> Double {
        let inputHalo = Self.dilate1(input)
        var inputFg = 0
        var sum = 0.0

        for i in 0..<Self.cellCount {
            let inp = input[i] != 0
            let tmp = template.mask[i] != 0
            if inp {
                inputFg += 1
                if tmp {
                    sum += 2.0
                } else if template.halo[i] != 0 {
                    sum += 0.65
                } else {
                    sum -= 1.8
                }
            }
            if tmp {
                if inp {
                    sum += 2.0
                } else if inputHalo[i] != 0 {
                    sum += 0.65
                } else {
                    sum -= 1.8
                }
            }
        }

        let denom = Double(max(inputFg + template.foregroundCount, 1)) * 2.0
        return sum / denom
    }

    private func percentileFromHistogram(_ hist: [Int], total: Int, ratio: Double) -> Int {
        let target = max(1, Int(Double(total) * ratio))
        var acc = 0
        for v in 0..<256 {
            acc += hist[v]
            if acc >= target { return v }
        }
        return 255
    }
}

// MARK: - Zero-Crash Raw Buffer Vision Processor (< 4 MB RAM, < 2ms/frame)

/// Bộ xử lý khung hình thô `BGRA`/`NV12` không cấp phát bộ đệm phụ, không phụ thuộc thư viện nặng (< 4 MB RAM, < 2ms/khung hình):
/// 1. Đọc góc bắn từ tâm D-pad (`16×24` template matching) đối chiếu chéo với tia chấm vàng cạnh nhân vật.
/// 2. Đo tỷ lệ `pixelsPerUnit = tickSpacingPixels / 5.0` trực tiếp từ vạch chia tối màu trên thước vàng đáy Minimap (dự phòng khung camera trắng `/ 10.0`).
/// 3. Tìm vị trí người chơi xanh thuần & mục tiêu đỏ tươi thuần trên Minimap (kháng nền đồi hồng/tím/nâu), tính `distanceUnits` và `deltaYUnits`.
public final class VisionProcessor {
    private let angleMatcher = AngleBitmapTemplateMatcher()

    public init() {}

    /// Phân tích toàn bộ 1 khung hình logic ngang trực tiếp trên vùng nhớ thô `BGRA`/`NV12` (< 2ms).
    public func analyzeFrame(
        _ buffer: RawFrameBuffer,
        fallbackPlayerPx: CGPoint? = nil,
        previousEnemyPx: CGPoint? = nil,
        cachedPixelsPerUnit: Double? = nil
    ) -> RawFrameAnalysisResult {
        // 1. Bước 1 cự ly: Đo `pixelsPerUnit` từ khoảng cách vạch tối 5.0 đơn vị trên thước vàng đáy Minimap.
        let minimapBounds = buffer.pixelBounds(for: GunnyROIs.minimapStrip)
        let rulerPpu = detectYellowRulerPixelsPerUnit(in: buffer, roi: GunnyROIs.minimapYellowRuler)

        // 2. Bước 2 cự ly: Tìm người chơi xanh & mục tiêu đỏ tươi trên Minimap (đồng thời lấy khung camera trắng dự phòng).
        let (playerPx, enemyPx, enemyCount, cameraPpu) = analyzeMinimapMarkersAndCamera(
            in: buffer,
            bounds: minimapBounds,
            primaryPpu: rulerPpu,
            cachedPpu: cachedPixelsPerUnit,
            fallbackPlayerPx: fallbackPlayerPx,
            previousEnemyPx: previousEnemyPx
        )

        let chosenPpu: Double?
        let scaleSource: ScaleMeasurementSource
        if let ppu = rulerPpu {
            chosenPpu = ppu
            scaleSource = .yellowRulerTicks
        } else if let camPpu = cameraPpu {
            chosenPpu = camPpu
            scaleSource = .whiteCameraBorderFallback
        } else {
            chosenPpu = cachedPixelsPerUnit
            scaleSource = .cachedPreviousScale
        }

        let effectivePlayer = playerPx ?? fallbackPlayerPx
        let distanceUnits: Double?
        let deltaYUnits: Double?
        if let ppu = chosenPpu, ppu > 2.0, let p = effectivePlayer, let e = enemyPx {
            distanceUnits = abs(Double(e.x - p.x)) / ppu
            deltaYUnits = Double(p.y - e.y) / (ppu * 0.55)
        } else {
            distanceUnits = nil
            deltaYUnits = nil
        }

        // 3. Đọc góc bắn: Nguồn 1 (D-pad 16x24) đối chiếu chéo Nguồn 2 (Tia chấm vàng cạnh nhân vật).
        let dpadResult = angleMatcher.readAngle(from: buffer, roi: GunnyROIs.dpadAngle)
        let rayAngle = detectYellowAimRayAngle(in: buffer, roi: GunnyROIs.yellowAimRay)

        let finalAngle: Int?
        let angleSource: AngleMeasurementSource

        if dpadResult.isExplicitZero {
            finalAngle = nil
            angleSource = .dpadZeroHold
        } else if let dpadAng = dpadResult.angle {
            if let rAng = rayAngle {
                if abs(dpadAng - rAng) <= 12 || dpadResult.confidence >= 0.62 {
                    finalAngle = dpadAng
                    angleSource = .dpadCrossChecked
                } else {
                    finalAngle = rAng
                    angleSource = .yellowAimRay
                }
            } else {
                finalAngle = dpadAng
                angleSource = .dpadTemplate
            }
        } else if let rAng = rayAngle {
            finalAngle = rAng
            angleSource = .yellowAimRay
        } else {
            finalAngle = nil
            angleSource = .none
        }

        return RawFrameAnalysisResult(
            pixelsPerUnit: chosenPpu,
            scaleSource: scaleSource,
            playerPx: playerPx,
            enemyPx: enemyPx,
            enemyCount: enemyCount,
            distanceUnits: distanceUnits,
            deltaYUnits: deltaYUnits,
            angle: finalAngle,
            angleSource: angleSource,
            dpadZeroDetected: dpadResult.isExplicitZero
        )
    }

    // MARK: - Bước 1: Đo `pixelsPerUnit` từ vạch chia tối 5.0 đơn vị trên thước vàng đáy Minimap

    public func detectYellowRulerPixelsPerUnit(
        in buffer: RawFrameBuffer,
        roi: CGRect = GunnyROIs.minimapYellowRuler
    ) -> Double? {
        let b = buffer.pixelBounds(for: roi)
        let w = b.w
        let h = b.h
        guard w >= 24, h >= 2 else { return nil }

        var colLum = [Double](repeating: 0.0, count: w)
        for x in 0..<w {
            let gx = b.x0 + x
            var sum = 0
            for y in 0..<h {
                sum += buffer.readLuma(x: gx, y: b.y0 + y)
            }
            colLum[x] = Double(sum) / Double(h)
        }

        let sorted = colLum.sorted()
        let brightRef = sorted[min(Int(Double(w) * 0.75), w - 1)]
        guard brightRef >= 65.0 else { return nil }

        let darkThreshold = min(brightRef * 0.74, brightRef - 22.0)
        let maxTickWidth = max(3, Int(Double(w) * 0.06))
        var tickCenters: [Double] = []
        tickCenters.reserveCapacity(10)

        var x = 1
        while x < (w - 1) {
            guard colLum[x] <= darkThreshold else {
                x += 1
                continue
            }
            let startX = x
            var weightedSum = 0.0
            var weightTotal = 0.0
            while x < (w - 1) && colLum[x] <= darkThreshold {
                let depth = max(brightRef - colLum[x], 1.0)
                weightedSum += Double(x) * depth
                weightTotal += depth
                x += 1
            }
            let endX = x - 1
            let valleyW = endX - startX + 1
            if valleyW <= maxTickWidth && weightTotal > 0 {
                tickCenters.append(weightedSum / weightTotal)
            }
        }

        guard tickCenters.count >= 2 else { return nil }

        let minSpacing = Double(w) * 0.14
        let maxSpacing = Double(w) * 0.46
        var validSpacings: [Double] = []
        validSpacings.reserveCapacity(tickCenters.count)
        for i in 0..<(tickCenters.count - 1) {
            let gap = tickCenters[i + 1] - tickCenters[i]
            if gap >= minSpacing && gap <= maxSpacing {
                validSpacings.append(gap)
            }
        }

        guard !validSpacings.isEmpty else { return nil }
        validSpacings.sort()
        let medianTickSpacingPx = validSpacings[validSpacings.count / 2]
        return medianTickSpacingPx / 5.0
    }

    // MARK: - Bước 2: Người chơi xanh, mục tiêu đỏ tươi thuần & khung camera dự phòng

    private struct MinimapCluster {
        var centerX: Double
        var centerY: Double
        var maxY: Int
        var count: Int
    }

    private func analyzeMinimapMarkersAndCamera(
        in buffer: RawFrameBuffer,
        bounds b: (x0: Int, y0: Int, w: Int, h: Int),
        primaryPpu: Double?,
        cachedPpu: Double?,
        fallbackPlayerPx: CGPoint?,
        previousEnemyPx: CGPoint?
    ) -> (CGPoint?, CGPoint?, Int, Double?) {
        let w = b.w
        let h = b.h
        guard w >= 16, h >= 8 else { return (nil, nil, 0, nil) }

        let total = w * h
        var blueMask = [UInt8](repeating: 0, count: total)
        var redMask = [UInt8](repeating: 0, count: total)
        var lumaGrid = [Int](repeating: 0, count: total)

        for y in 0..<h {
            let gy = b.y0 + y
            let rowBase = y * w
            for x in 0..<w {
                let gx = b.x0 + x
                let (r, g, bVal) = buffer.readRGB(x: gx, y: gy)
                let idx = rowBase + x
                lumaGrid[idx] = (77 * r + 150 * g + 29 * bVal) >> 8

                // Người chơi (Xanh dương thuần): B > 185 && R < 85 && G < 140 && (B - R) > 120
                if bVal > 185 && r < 85 && g < 140 && (bVal - r) > 120 {
                    blueMask[idx] = 1
                }
                // Mục tiêu (Đỏ tươi thuần): R > 195 && G < 60 && B < 60 && (R - G) > 140 && (R - B) > 140
                else if r > 195 && g < 60 && bVal < 60 && (r - g) > 140 && (r - bVal) > 140 {
                    redMask[idx] = 1
                }
            }
        }

        let playerPx = detectBluePlayerPx(mask: blueMask, width: w, height: h)
        let refPlayer = playerPx ?? fallbackPlayerPx

        let cameraPpu: Double?
        if primaryPpu == nil {
            cameraPpu = detectCameraFallbackPixelsPerUnit(
                lumaGrid: lumaGrid,
                width: w,
                height: h,
                playerPxX: refPlayer.map { Double($0.x) }
            )
        } else {
            cameraPpu = nil
        }

        let refPpu = primaryPpu ?? cameraPpu ?? cachedPpu ?? (Double(w) * 0.62 / 10.0)
        let minEnemyDistPx = max(3.0, refPpu * 0.5)
        let (enemyPx, enemyCount) = detectNearestRedEnemyPx(
            mask: redMask,
            width: w,
            height: h,
            referencePlayer: refPlayer,
            previousEnemy: previousEnemyPx,
            minDistancePx: minEnemyDistPx
        )

        return (playerPx, enemyPx, enemyCount, cameraPpu)
    }

    private func extract8Clusters(
        mask: [UInt8],
        width: Int,
        height: Int,
        minPixels: Int,
        maxW: Int,
        maxH: Int
    ) -> [MinimapCluster] {
        var visited = [UInt8](repeating: 0, count: width * height)
        var clusters: [MinimapCluster] = []
        var qx: [Int] = []
        var qy: [Int] = []
        qx.reserveCapacity(48)
        qy.reserveCapacity(48)

        for sy in 0..<height {
            for sx in 0..<width {
                let si = sy * width + sx
                guard mask[si] != 0, visited[si] == 0 else { continue }
                visited[si] = 1
                qx.removeAll(keepingCapacity: true)
                qy.removeAll(keepingCapacity: true)
                qx.append(sx)
                qy.append(sy)

                var head = 0
                var sumX = 0.0
                var sumY = 0.0
                var count = 0
                var minX = sx
                var maxX = sx
                var minY = sy
                var maxY = sy

                while head < qx.count {
                    let cx = qx[head]
                    let cy = qy[head]
                    head += 1
                    sumX += Double(cx)
                    sumY += Double(cy)
                    count += 1
                    if cx < minX { minX = cx }
                    if cx > maxX { maxX = cx }
                    if cy < minY { minY = cy }
                    if cy > maxY { maxY = cy }

                    let yFrom = max(0, cy - 1)
                    let yTo = min(height - 1, cy + 1)
                    let xFrom = max(0, cx - 1)
                    let xTo = min(width - 1, cx + 1)
                    for ny in yFrom...yTo {
                        let nRow = ny * width
                        for nx in xFrom...xTo {
                            if nx == cx && ny == cy { continue }
                            let ni = nRow + nx
                            if mask[ni] != 0 && visited[ni] == 0 {
                                visited[ni] = 1
                                qx.append(nx)
                                qy.append(ny)
                            }
                        }
                    }
                }

                if count >= minPixels && (maxX - minX + 1) <= maxW && (maxY - minY + 1) <= maxH {
                    clusters.append(
                        MinimapCluster(
                            centerX: sumX / Double(count),
                            centerY: sumY / Double(count),
                            maxY: maxY,
                            count: count
                        )
                    )
                }
            }
        }
        return clusters
    }

    private func detectBluePlayerPx(mask: [UInt8], width: Int, height: Int) -> CGPoint? {
        let clusters = extract8Clusters(
            mask: mask,
            width: width,
            height: height,
            minPixels: 2,
            maxW: max(8, Int(Double(width) * 0.18)),
            maxH: max(8, Int(Double(height) * 0.45))
        )
        guard let best = clusters.max(by: { $0.count < $1.count }) else { return nil }
        return CGPoint(x: best.centerX, y: Double(best.maxY))
    }

    private func detectNearestRedEnemyPx(
        mask: [UInt8],
        width: Int,
        height: Int,
        referencePlayer: CGPoint?,
        previousEnemy: CGPoint?,
        minDistancePx: Double
    ) -> (CGPoint?, Int) {
        let raw = extract8Clusters(
            mask: mask,
            width: width,
            height: height,
            minPixels: 2,
            maxW: max(8, Int(Double(width) * 0.14)),
            maxH: max(8, Int(Double(height) * 0.40))
        )
        guard !raw.isEmpty else { return (nil, 0) }

        let mergeDistPx = max(3.0, Double(width) * 0.018)
        var merged = raw
        var didMerge = true
        while didMerge {
            didMerge = false
            var i = 0
            while i < merged.count {
                var j = i + 1
                while j < merged.count {
                    if hypot(merged[i].centerX - merged[j].centerX, merged[i].centerY - merged[j].centerY) <= mergeDistPx {
                        let tot = Double(merged[i].count + merged[j].count)
                        merged[i].centerX = (merged[i].centerX * Double(merged[i].count) + merged[j].centerX * Double(merged[j].count)) / tot
                        merged[i].centerY = (merged[i].centerY * Double(merged[i].count) + merged[j].centerY * Double(merged[j].count)) / tot
                        merged[i].maxY = max(merged[i].maxY, merged[j].maxY)
                        merged[i].count += merged[j].count
                        merged.remove(at: j)
                        didMerge = true
                    } else {
                        j += 1
                    }
                }
                i += 1
            }
        }

        var points = merged.map { CGPoint(x: $0.centerX, y: Double($0.maxY)) }
        if let player = referencePlayer {
            points = points.filter { hypot(Double($0.x - player.x), Double($0.y - player.y)) >= minDistancePx }
            guard !points.isEmpty else { return (nil, 0) }

            points.sort { lhs, rhs in
                let dL = abs(Double(lhs.x - player.x))
                let dR = abs(Double(rhs.x - player.x))
                if abs(dL - dR) > 1.5 { return dL < dR }
                return hypot(Double(lhs.x - player.x), Double(lhs.y - player.y))
                    < hypot(Double(rhs.x - player.x), Double(rhs.y - player.y))
            }

            if let prev = previousEnemy, let closest = points.first {
                let closestDist = abs(Double(closest.x - player.x))
                if let sticky = points.first(where: { cand in
                    hypot(Double(cand.x - prev.x), Double(cand.y - prev.y)) <= max(6.0, Double(width) * 0.035)
                        && abs(Double(cand.x - player.x)) <= closestDist + max(4.0, Double(width) * 0.02)
                }) {
                    return (sticky, points.count)
                }
            }
        }
        return (points.first, points.count)
    }

    private func detectCameraFallbackPixelsPerUnit(
        lumaGrid: [Int],
        width: Int,
        height: Int,
        playerPxX: Double?
    ) -> Double? {
        guard width >= 24, height >= 8 else { return nil }
        let invH = 1.0 / Double(height)

        var leftRatio = [Double](repeating: 0.0, count: width)
        var rightRatio = [Double](repeating: 0.0, count: width)
        for col in 1..<(width - 1) {
            var lHits = 0
            var rHits = 0
            for y in 0..<height {
                let idx = y * width + col
                let cur = lumaGrid[idx]
                if cur - lumaGrid[idx - 1] >= 10 { lHits += 1 }
                if cur - lumaGrid[idx + 1] >= 10 { rHits += 1 }
            }
            leftRatio[col] = Double(lHits) * invH
            rightRatio[col] = Double(rHits) * invH
        }

        let leftCols = extractPeakCols(ratios: leftRatio, minRatio: 0.55)
        let rightCols = extractPeakCols(ratios: rightRatio, minRatio: 0.55)

        var bestSpanPx: Double?
        var bestScore = -1.0
        for lc in leftCols {
            for rc in rightCols where rc > lc + 8 {
                let spanPx = Double(rc - lc)
                let spanNorm = spanPx / Double(width)
                guard spanNorm >= 0.40 && spanNorm <= 0.88 else { continue }
                if let px = playerPxX, px < Double(lc) - 4.0 || px > Double(rc) + 4.0 {
                    continue
                }
                let score = leftRatio[lc] + rightRatio[rc]
                if score > bestScore {
                    bestScore = score
                    bestSpanPx = spanPx
                }
            }
        }

        guard let camWidthPx = bestSpanPx else { return nil }
        return camWidthPx / BallisticsEngine.unitsPerScreen
    }

    private func extractPeakCols(ratios: [Double], minRatio: Double) -> [Int] {
        var peaks: [Int] = []
        var col = 1
        while col < ratios.count - 1 {
            guard ratios[col] >= minRatio else {
                col += 1
                continue
            }
            var bestCol = col
            var bestR = ratios[col]
            var gap = 0
            col += 1
            while col < ratios.count - 1 {
                if ratios[col] >= minRatio {
                    gap = 0
                    if ratios[col] > bestR {
                        bestR = ratios[col]
                        bestCol = col
                    }
                } else {
                    gap += 1
                    if gap > 2 { break }
                }
                col += 1
            }
            peaks.append(bestCol)
        }
        return peaks
    }

    // MARK: - Nguồn 2 Góc Bắn: Tia chấm vàng chỉ góc bắn cạnh thanh máu xanh (`atan2(dy, dx)`)

    public func detectYellowAimRayAngle(
        in buffer: RawFrameBuffer,
        roi: CGRect = GunnyROIs.yellowAimRay
    ) -> Int? {
        let b = buffer.pixelBounds(for: roi)
        guard b.w >= 40, b.h >= 40 else { return nil }

        // Tìm nhanh thanh máu xanh người chơi với bước nhảy (4, 2) để đạt < 0.25ms.
        let stepX = 4
        let stepY = 2
        let sw = b.w / stepX
        let sh = b.h / stepY
        guard sw >= 12, sh >= 12 else { return nil }

        var blueSumX = 0.0
        var blueSumY = 0.0
        var blueCount = 0
        for sy in 0..<sh {
            let gy = b.y0 + sy * stepY
            for sx in 0..<sw {
                let gx = b.x0 + sx * stepX
                let (r, g, bVal) = buffer.readRGB(x: gx, y: gy)
                if bVal > 195 && r < 70 && g < 120 {
                    blueSumX += Double(gx)
                    blueSumY += Double(gy)
                    blueCount += 1
                }
            }
        }
        guard blueCount >= 4 else { return nil }
        let anchorX = blueSumX / Double(blueCount)
        let anchorY = blueSumY / Double(blueCount)

        // Quét cửa sổ cục bộ quanh nhân vật tại bước 2 để gom các chấm vàng (R > 220, G > 200, B < 80).
        let step = 2
        let radX = Int(Double(buffer.width) * 0.16)
        let radUp = Int(Double(buffer.height) * 0.24)
        let radDown = Int(Double(buffer.height) * 0.14)
        let wx0 = max(b.x0, Int(anchorX) - radX)
        let wx1 = min(b.x0 + b.w, Int(anchorX) + radX)
        let wy0 = max(b.y0, Int(anchorY) - radUp)
        let wy1 = min(b.y0 + b.h, Int(anchorY) + radDown)
        let lw = (wx1 - wx0) / step
        let lh = (wy1 - wy0) / step
        guard lw >= 8, lh >= 8 else { return nil }

        var yellowMask = [UInt8](repeating: 0, count: lw * lh)
        var yellowHits = 0
        for ly in 0..<lh {
            let gy = wy0 + ly * step
            let rowBase = ly * lw
            for lx in 0..<lw {
                let gx = wx0 + lx * step
                let (r, g, bVal) = buffer.readRGB(x: gx, y: gy)
                if r > 220 && g > 200 && bVal < 80 {
                    yellowMask[rowBase + lx] = 1
                    yellowHits += 1
                }
            }
        }
        guard yellowHits >= 6 else { return nil }

        let dotClusters = extract8Clusters(
            mask: yellowMask,
            width: lw,
            height: lh,
            minPixels: 2,
            maxW: 10,
            maxH: 10
        )
        guard dotClusters.count >= 3 else { return nil }

        let dots: [CGPoint] = dotClusters.map { c in
            CGPoint(x: Double(wx0) + c.centerX * Double(step), y: Double(wy0) + c.centerY * Double(step))
        }

        var bestInliers: [CGPoint] = []
        let tolPx = 5.0
        for i in 0..<dots.count {
            for j in (i + 1)..<dots.count {
                let dx = Double(dots[j].x - dots[i].x)
                let dy = Double(dots[j].y - dots[i].y)
                let len = hypot(dx, dy)
                guard len >= 14.0 else { continue }
                let invLen = 1.0 / len

                var inliers: [CGPoint] = []
                for p in dots {
                    let perp = abs(Double(p.x - dots[i].x) * dy - Double(p.y - dots[i].y) * dx) * invLen
                    if perp <= tolPx {
                        inliers.append(p)
                    }
                }
                if inliers.count > bestInliers.count {
                    bestInliers = inliers
                }
            }
        }

        guard bestInliers.count >= 3 else { return nil }

        bestInliers.sort { lhs, rhs in
            hypot(Double(lhs.x) - anchorX, Double(lhs.y) - anchorY)
                < hypot(Double(rhs.x) - anchorX, Double(rhs.y) - anchorY)
        }
        guard let startPt = bestInliers.first, let endPt = bestInliers.last else { return nil }

        let rayDX = abs(Double(endPt.x - startPt.x))
        let rayDY = Double(startPt.y - endPt.y)
        guard hypot(rayDX, rayDY) >= 24.0 else { return nil }

        let deg = Int((atan2(rayDY, max(rayDX, 1e-4)) * 180.0 / .pi).rounded())
        guard deg >= -35 && deg <= 85 else { return nil }
        return deg
    }
}
