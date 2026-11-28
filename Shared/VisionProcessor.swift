import CoreGraphics
import Foundation
import Vision

/// Kết quả phân tích Minimap bằng HSV + Connected-Component Labeling 8 hướng + trích xuất địa hình 32 cột.
public struct MinimapAnalysisResult: Equatable, Sendable {
    public let playerPos: CGPoint?
    public let enemyPositions: [CGPoint]
    public let cameraWidthNorm: Double?
    public let minimapAspectHOverW: Double
    public let terrainProfile: [Double]
    public let lumaGrid64x24: [UInt8]
}

/// Bộ tách góc bắn 2 tầng regex cho Gunny Mobi (`-35 ... 85`), hỗ trợ cả lỗi OCR (`G6c`, `G0c`, thiếu chữ `Góc`).
public enum AngleParser {
    private static let tier1RawRegex = try? NSRegularExpression(
        pattern: #"(?:g[oóôòỏõọốồổỗộớờởỡợ06]c)\s*(?::|-\s+)?\s*(-?\d{1,2})"#,
        options: [.caseInsensitive]
    )
    private static let tier1FoldedRegex = try? NSRegularExpression(
        pattern: #"(?:g[o06]c)\s*(?::|-\s+)?\s*(-?\d{1,2})"#,
        options: [.caseInsensitive]
    )
    private static let tier2DegreeRegex = try? NSRegularExpression(
        pattern: #"(-?\d{1,2})\s*[°ºo](?![a-zA-Z])"#,
        options: []
    )

    /// Tách góc bắn nguyên hợp lệ (`-35 ... 85`) từ danh sách chuỗi OCR theo 2 tầng ưu tiên.
    public static func extractAngle(from texts: [String]) -> Int? {
        for raw in texts {
            if let regex = tier1RawRegex,
               let value = extractFirstInt(using: regex, in: raw),
               value >= -35 && value <= 85 {
                return value
            }
            let folded = raw.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            if let regex = tier1FoldedRegex,
               let value = extractFirstInt(using: regex, in: folded),
               value >= -35 && value <= 85 {
                return value
            }
        }

        for raw in texts {
            if let regex = tier2DegreeRegex,
               let value = extractFirstInt(using: regex, in: raw),
               value >= -35 && value <= 85 {
                return value
            }
        }

        return nil
    }

    private static func extractFirstInt(using regex: NSRegularExpression, in text: String) -> Int? {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: fullRange),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[range])
    }
}

/// Bộ xử lý thị giác máy tính siêu nhẹ (< 25MB RAM, < 50ms):
/// - Phân cụm không gian màu HSV + Connected-Component Labeling 8 hướng + lọc hình thái.
/// - Tự động đo khung chữ nhật camera trắng (`S < 0.15, V > 0.82`) làm chuẩn `10.0` đơn vị.
/// - Trích xuất hồ sơ độ cao địa hình 32 cột (`terrainProfile`) và dò vệt nổ trên Minimap.
public final class VisionProcessor {
    public static let terrainColumnCount = 32
    public static let lumaGridWidth = 64
    public static let lumaGridHeight = 24

    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()

    public init() {}

    // MARK: - 1. HSV Color-Space Clustering + 8-Neighbor CCL + White Camera + Terrain Profile

    public func analyzeMinimap(
        from cropped: CGImage,
        fallbackPlayerPos: CGPoint = CGPoint(x: 0.20, y: 0.72),
        fallbackEnemyPos: CGPoint = CGPoint(x: 0.70, y: 0.72)
    ) -> MinimapAnalysisResult? {
        let outW = cropped.width
        let outH = cropped.height
        guard outW >= 8, outH >= 6,
              let context = makeRGBAContext(width: outW, height: outH),
              let rgbaPtr = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }

        context.interpolationQuality = .none
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))

        let minimapAspectHOverW = Double(outH) / Double(outW)
        let pixelCount = outW * outH
        var blueMask = [Bool](repeating: false, count: pixelCount)
        var redMask = [Bool](repeating: false, count: pixelCount)
        var whiteMask = [Bool](repeating: false, count: pixelCount)

        let bytesPerRow = context.bytesPerRow
        for y in 0..<outH {
            let rowPtr = rgbaPtr.advanced(by: y * bytesPerRow)
            for x in 0..<outW {
                let px = x * 4
                let r = rowPtr[px]
                let g = rowPtr[px + 1]
                let b = rowPtr[px + 2]
                let idx = y * outW + x

                let hsv = Self.rgbToHSV(r: r, g: g, b: b)

                // Khung camera trắng bên trong Minimap: S < 0.15, V > 0.82 (loại 2px sát mép ngoài).
                if x >= 2 && x < (outW - 2) && y >= 2 && y < (outH - 2) {
                    if hsv.s < 0.15 && hsv.v > 0.82 {
                        whiteMask[idx] = true
                    }
                }

                // Người chơi (Blue Marker): H ∈ [205°, 245°], S > 0.65, V > 0.65.
                if hsv.h >= 205.0 && hsv.h <= 245.0 && hsv.s > 0.65 && hsv.v > 0.65 {
                    blueMask[idx] = true
                }
                // Mục tiêu (Red Marker): H ∈ [348°, 360°] ∪ [0°, 10°], S > 0.78, V > 0.70 (loại nền gạch đỏ/đất nâu/dung nham).
                else if (hsv.h >= 348.0 || hsv.h <= 10.0) && hsv.s > 0.78 && hsv.v > 0.70 {
                    redMask[idx] = true
                }
            }
        }

        let playerPos = detectBluePlayerMarker(mask: blueMask, width: outW, height: outH)
        let enemyPositions = detectRedEnemyMarkers(
            mask: redMask,
            width: outW,
            height: outH,
            playerPos: playerPos ?? fallbackPlayerPos
        )
        let cameraWidthNorm = detectWhiteCameraWidthNorm(whiteMask: whiteMask, width: outW, height: outH)

        let resolvedPlayer = playerPos ?? fallbackPlayerPos
        let resolvedEnemy = enemyPositions.first ?? fallbackEnemyPos
        let terrainProfile = extractTerrainProfile(
            rgbaPtr: rgbaPtr,
            bytesPerRow: bytesPerRow,
            width: outW,
            height: outH,
            blueMask: blueMask,
            redMask: redMask,
            whiteMask: whiteMask,
            playerPos: resolvedPlayer,
            enemyPos: resolvedEnemy
        )

        let lumaGrid = buildLumaGrid64x24(rgbaPtr: rgbaPtr, bytesPerRow: bytesPerRow, width: outW, height: outH)

        return MinimapAnalysisResult(
            playerPos: playerPos,
            enemyPositions: enemyPositions,
            cameraWidthNorm: cameraWidthNorm,
            minimapAspectHOverW: minimapAspectHOverW,
            terrainProfile: terrainProfile,
            lumaGrid64x24: lumaGrid
        )
    }

    /// Chuyển đổi RGB (0...255) sang không gian màu HSV (`h: 0...360`, `s: 0...1`, `v: 0...1`).
    public static func rgbToHSV(r: UInt8, g: UInt8, b: UInt8) -> (h: Double, s: Double, v: Double) {
        let rf = Double(r) / 255.0
        let gf = Double(g) / 255.0
        let bf = Double(b) / 255.0

        let maxC = max(rf, max(gf, bf))
        let minC = min(rf, min(gf, bf))
        let delta = maxC - minC

        let v = maxC
        let s = maxC > 0.00001 ? delta / maxC : 0.0

        var h = 0.0
        if delta > 0.00001 {
            if maxC == rf {
                h = 60.0 * (((gf - bf) / delta).truncatingRemainder(dividingBy: 6.0))
            } else if maxC == gf {
                h = 60.0 * (((bf - rf) / delta) + 2.0)
            } else {
                h = 60.0 * (((rf - gf) / delta) + 4.0)
            }
            if h < 0.0 {
                h += 360.0
            }
        }

        return (h, s, v)
    }

    // MARK: - 8-Neighbor Connected-Component Labeling & Morphological Filtering

    private struct CCLComponent {
        var centerX: Double
        var centerY: Double
        var count: Int
        var bboxW: Int
        var bboxH: Int
        var fillDensity: Double
    }

    private func extract8ConnectedComponents(
        from mask: [Bool],
        width: Int,
        height: Int,
        minPixels: Int,
        maxBBoxWidthRatio: Double,
        maxBBoxHeightRatio: Double,
        minFillDensity: Double,
        minAspect: Double,
        maxAspect: Double
    ) -> [CCLComponent] {
        var visited = [Bool](repeating: false, count: width * height)
        var components: [CCLComponent] = []

        let maxBBoxW = max(6, Int(Double(width) * maxBBoxWidthRatio))
        let maxBBoxH = max(6, Int(Double(height) * maxBBoxHeightRatio))

        var queueX: [Int] = []
        var queueY: [Int] = []
        queueX.reserveCapacity(64)
        queueY.reserveCapacity(64)

        for startY in 0..<height {
            for startX in 0..<width {
                let startIdx = startY * width + startX
                guard mask[startIdx], !visited[startIdx] else { continue }

                visited[startIdx] = true
                queueX.removeAll(keepingCapacity: true)
                queueY.removeAll(keepingCapacity: true)
                queueX.append(startX)
                queueY.append(startY)

                var head = 0
                var sumX = 0.0
                var sumY = 0.0
                var count = 0
                var minX = startX
                var maxX = startX
                var minY = startY
                var maxY = startY

                // Gom cụm 8 hướng (8-Neighbor Connected-Component Labeling).
                while head < queueX.count {
                    let cx = queueX[head]
                    let cy = queueY[head]
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
                        for nx in xFrom...xTo {
                            if nx == cx && ny == cy { continue }
                            let nIdx = ny * width + nx
                            if mask[nIdx] && !visited[nIdx] {
                                visited[nIdx] = true
                                queueX.append(nx)
                                queueY.append(ny)
                            }
                        }
                    }
                }

                let bboxW = maxX - minX + 1
                let bboxH = maxY - minY + 1
                let bboxArea = max(bboxW * bboxH, 1)
                let fillDensity = Double(count) / Double(bboxArea)
                let aspect = Double(bboxW) / Double(max(bboxH, 1))

                // Lọc hình thái học: loại bỏ điểm nhiễu đơn lẻ, đường thẳng mảnh hoặc mảng nền lớn.
                guard count >= minPixels,
                      bboxW <= maxBBoxW,
                      bboxH <= maxBBoxH,
                      fillDensity >= minFillDensity,
                      aspect >= minAspect,
                      aspect <= maxAspect else {
                    continue
                }

                components.append(
                    CCLComponent(
                        centerX: sumX / Double(count),
                        centerY: sumY / Double(count),
                        count: count,
                        bboxW: bboxW,
                        bboxH: bboxH,
                        fillDensity: fillDensity
                    )
                )
            }
        }

        return components
    }

    private func detectBluePlayerMarker(mask: [Bool], width: Int, height: Int) -> CGPoint? {
        let components = extract8ConnectedComponents(
            from: mask,
            width: width,
            height: height,
            minPixels: 3,
            maxBBoxWidthRatio: 0.20,
            maxBBoxHeightRatio: 0.42,
            minFillDensity: 0.22,
            minAspect: 0.30,
            maxAspect: 3.0
        )
        guard !components.isEmpty else { return nil }

        // Ưu tiên cụm xanh dương đặc trưng có hình dạng mũi tên / chấm tròn gọn.
        var best = components[0]
        var bestScore = -1.0
        for comp in components {
            let shapeBonus = Double(comp.bboxH) >= Double(comp.bboxW) * 0.80 ? 12.0 : 0.0
            let score = Double(min(comp.count, 220)) * (0.6 + comp.fillDensity) + shapeBonus
            if score > bestScore {
                bestScore = score
                best = comp
            }
        }

        return CGPoint(
            x: min(max(best.centerX / Double(width), 0.0), 1.0),
            y: min(max(best.centerY / Double(height), 0.0), 1.0)
        )
    }

    private func detectRedEnemyMarkers(
        mask: [Bool],
        width: Int,
        height: Int,
        playerPos: CGPoint
    ) -> [CGPoint] {
        let raw = extract8ConnectedComponents(
            from: mask,
            width: width,
            height: height,
            minPixels: 2,
            maxBBoxWidthRatio: 0.14,
            maxBBoxHeightRatio: 0.34,
            minFillDensity: 0.25,
            minAspect: 0.35,
            maxAspect: 2.8
        )
        guard !raw.isEmpty else { return [] }

        let mergeDistPx = max(4.0, Double(width) * 0.025)
        var merged = raw
        var didMerge = true
        while didMerge {
            didMerge = false
            var i = 0
            while i < merged.count {
                var j = i + 1
                while j < merged.count {
                    let dist = hypot(merged[i].centerX - merged[j].centerX, merged[i].centerY - merged[j].centerY)
                    if dist <= mergeDistPx {
                        let total = Double(merged[i].count + merged[j].count)
                        merged[i].centerX = (merged[i].centerX * Double(merged[i].count) + merged[j].centerX * Double(merged[j].count)) / total
                        merged[i].centerY = (merged[i].centerY * Double(merged[i].count) + merged[j].centerY * Double(merged[j].count)) / total
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

        var points = merged.map {
            CGPoint(
                x: min(max($0.centerX / Double(width), 0.0), 1.0),
                y: min(max($0.centerY / Double(height), 0.0), 1.0)
            )
        }
        points.sort {
            hypot(Double($0.x - playerPos.x), Double($0.y - playerPos.y))
                < hypot(Double($1.x - playerPos.x), Double($1.y - playerPos.y))
        }
        return Array(points.prefix(8))
    }

    // MARK: - Automatic White Camera Viewport Width Detection (10.0 Units Reference)

    private struct VerticalEdge {
        let x: Int
        let yTop: Int
        let yBottom: Int
        let coverage: Double
    }

    private func detectWhiteCameraWidthNorm(whiteMask: [Bool], width: Int, height: Int) -> Double? {
        let minEdgeH = max(8, Int(Double(height) * 0.28))
        let maxEdgeH = Int(Double(height) * 0.96)
        let minRectW = max(14, Int(Double(width) * 0.22))
        let maxRectW = Int(Double(width) * 0.88)
        guard width >= 20, height >= 14, minRectW < maxRectW else { return nil }

        let maxGap = width >= 240 ? 2 : 1
        var edges: [VerticalEdge] = []
        for x in 2..<(width - 2) {
            var y = 2
            while y < (height - 2) {
                guard whiteMask[y * width + x] else {
                    y += 1
                    continue
                }
                let startY = y
                var endY = y
                var hits = 0
                var gap = 0
                while y < (height - 2) {
                    if whiteMask[y * width + x] {
                        hits += 1
                        endY = y
                        gap = 0
                    } else {
                        gap += 1
                        if gap > maxGap { break }
                    }
                    y += 1
                }
                let spanH = endY - startY + 1
                if spanH >= minEdgeH && spanH <= maxEdgeH {
                    let cov = Double(hits) / Double(spanH)
                    if cov >= 0.55 {
                        edges.append(VerticalEdge(x: x, yTop: startY, yBottom: endY, coverage: cov))
                    }
                }
            }
        }

        guard edges.count >= 2 else { return nil }
        edges.sort { ($0.coverage * Double($0.yBottom - $0.yTop)) > ($1.coverage * Double($1.yBottom - $1.yTop)) }
        let topEdges = Array(edges.prefix(24))

        var bestWidthNorm: Double?
        var bestScore = 0.0

        for i in 0..<topEdges.count {
            for j in (i + 1)..<topEdges.count {
                let a = topEdges[i]
                let b = topEdges[j]
                let left = a.x < b.x ? a : b
                let right = a.x < b.x ? b : a
                let rectW = right.x - left.x
                guard rectW >= minRectW && rectW <= maxRectW else { continue }

                let yTop = max(left.yTop, right.yTop)
                let yBottom = min(left.yBottom, right.yBottom)
                let rectH = yBottom - yTop + 1
                guard rectH >= minEdgeH else { continue }

                let aspect = Double(rectW) / Double(rectH)
                guard aspect >= 1.0 && aspect <= 4.2 else { continue }

                let topCov = horizontalWhiteCoverage(whiteMask: whiteMask, width: width, height: height, xStart: left.x, xEnd: right.x, yTarget: yTop)
                let bottomCov = horizontalWhiteCoverage(whiteMask: whiteMask, width: width, height: height, xStart: left.x, xEnd: right.x, yTarget: yBottom)
                guard (topCov + bottomCov) * 0.5 >= 0.35 else { continue }

                let score = (left.coverage + right.coverage + topCov + bottomCov) * 0.25
                if score >= 0.45 && score > bestScore {
                    bestScore = score
                    bestWidthNorm = Double(rectW) / Double(width)
                }
            }
        }

        return bestWidthNorm
    }

    private func horizontalWhiteCoverage(
        whiteMask: [Bool],
        width: Int,
        height: Int,
        xStart: Int,
        xEnd: Int,
        yTarget: Int
    ) -> Double {
        guard xEnd > xStart else { return 0.0 }
        var hits = 0
        let total = xEnd - xStart + 1
        let yMin = max(0, yTarget - 2)
        let yMax = min(height - 1, yTarget + 2)

        for x in xStart...xEnd {
            var found = false
            for y in yMin...yMax {
                if whiteMask[y * width + x] {
                    found = true
                    break
                }
            }
            if found { hits += 1 }
        }
        return Double(hits) / Double(total)
    }

    // MARK: - 32-Column Terrain Surface Height Extraction

    /// Trích xuất 32 cột độ cao bề mặt địa hình (`0.0` đáy -> `1.0` đỉnh) dọc đoạn nối từ `playerPos` tới `enemyPos`.
    private func extractTerrainProfile(
        rgbaPtr: UnsafeMutablePointer<UInt8>,
        bytesPerRow: Int,
        width: Int,
        height: Int,
        blueMask: [Bool],
        redMask: [Bool],
        whiteMask: [Bool],
        playerPos: CGPoint,
        enemyPos: CGPoint
    ) -> [Double] {
        // Ước lượng màu nền trời từ 3 hàng trên cùng (loại trừ chấm người chơi/địch/khung camera).
        var skySumR = 0
        var skySumG = 0
        var skySumB = 0
        var skySamples = 0
        let skyRows = min(3, height)
        for y in 0..<skyRows {
            let row = rgbaPtr.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let idx = y * width + x
                if blueMask[idx] || redMask[idx] || whiteMask[idx] { continue }
                let px = x * 4
                skySumR += Int(row[px])
                skySumG += Int(row[px + 1])
                skySumB += Int(row[px + 2])
                skySamples += 1
            }
        }

        let skyR = skySamples > 0 ? skySumR / skySamples : 18
        let skyG = skySamples > 0 ? skySumG / skySamples : 24
        let skyB = skySamples > 0 ? skySumB / skySamples : 34

        let colCount = Self.terrainColumnCount
        var profile = [Double](repeating: 0.0, count: colCount)
        let startX = Double(playerPos.x)
        let endX = Double(enemyPos.x)
        let colorDiffThreshold = 55

        for c in 0..<colCount {
            let u = Double(c) / Double(colCount - 1)
            let normX = startX + (endX - startX) * u
            let colX = min(max(Int((normX * Double(width)).rounded()), 0), width - 1)

            var contiguousTerrain = 0
            var surfaceY: Int?
            for y in 0..<height {
                let idx = y * width + colX
                if blueMask[idx] || redMask[idx] || whiteMask[idx] {
                    continue
                }
                let px = y * bytesPerRow + colX * 4
                let dr = abs(Int(rgbaPtr[px]) - skyR)
                let dg = abs(Int(rgbaPtr[px + 1]) - skyG)
                let db = abs(Int(rgbaPtr[px + 2]) - skyB)
                if (dr + dg + db) >= colorDiffThreshold {
                    contiguousTerrain += 1
                    if contiguousTerrain >= 3 {
                        surfaceY = max(0, y - 2)
                        break
                    }
                } else {
                    contiguousTerrain = 0
                }
            }

            if let ySurf = surfaceY {
                profile[c] = min(max(1.0 - (Double(ySurf) / Double(height)), 0.0), 1.0)
            } else {
                profile[c] = 0.0
            }
        }

        return profile
    }

    // MARK: - Post-Shot Impact Flash Detection (Adaptive Online Calibration)

    private func buildLumaGrid64x24(
        rgbaPtr: UnsafeMutablePointer<UInt8>,
        bytesPerRow: Int,
        width: Int,
        height: Int
    ) -> [UInt8] {
        let gw = Self.lumaGridWidth
        let gh = Self.lumaGridHeight
        var grid = [UInt8](repeating: 0, count: gw * gh)
        for gy in 0..<gh {
            let sy = min((gy * height) / gh, height - 1)
            let row = rgbaPtr.advanced(by: sy * bytesPerRow)
            for gx in 0..<gw {
                let sx = min((gx * width) / gw, width - 1)
                let px = sx * 4
                let lum = (Int(row[px]) * 77 + Int(row[px + 1]) * 150 + Int(row[px + 2]) * 29) >> 8
                grid[gy * gw + gx] = UInt8(min(max(lum, 0), 255))
            }
        }
        return grid
    }

    /// So sánh khung Minimap hiện tại với khung nền trước lúc bắn để định vị tâm X vụ nổ (`0.0...1.0`).
    public func detectImpactFlashX(
        baseline: [UInt8],
        current: [UInt8],
        playerX: Double
    ) -> Double? {
        let gw = Self.lumaGridWidth
        let gh = Self.lumaGridHeight
        guard baseline.count == gw * gh, current.count == gw * gh else { return nil }

        var weightedSumX = 0.0
        var totalWeight = 0.0
        var changedCount = 0

        for gy in 0..<gh {
            for gx in 0..<gw {
                let normX = Double(gx) / Double(gw)
                // Bỏ qua vùng đứng của chính nhân vật để tránh hiệu ứng bắn đạn ngay nòng.
                if abs(normX - playerX) < 0.05 { continue }

                let idx = gy * gw + gx
                let diff = abs(Int(current[idx]) - Int(baseline[idx]))
                if diff >= 48 {
                    let brightBoost = Int(current[idx]) >= 190 ? 2.0 : 1.0
                    let w = Double(diff) * brightBoost
                    weightedSumX += normX * w
                    totalWeight += w
                    changedCount += 1
                }
            }
        }

        // Cần đủ mật độ điểm ảnh nổ/rung nhưng không phải chuyển cảnh toàn màn hình.
        guard changedCount >= 4 && changedCount <= (gw * gh) / 3, totalWeight > 0.0 else {
            return nil
        }

        return min(max(weightedSumX / totalWeight, 0.0), 1.0)
    }

    // MARK: - 2. Accurate Vietnamese/English Angle OCR (-35 ... 85)

    /// Chạy `VNRecognizeTextRequest` (`.accurate`, `usesLanguageCorrection = false`, `["vi-VN", "en-US"]`) trên ảnh đen trắng tương phản cao.
    public func detectAngle(fromContrastImage cropped: CGImage) -> Int? {
        guard cropped.width >= 16, cropped.height >= 16 else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["vi-VN", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cropped, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else { return nil }

        var recognizedTexts: [String] = []
        recognizedTexts.reserveCapacity(observations.count * 2)
        for obs in observations {
            for candidate in obs.topCandidates(2) {
                recognizedTexts.append(candidate.string)
            }
        }
        return AngleParser.extractAngle(from: recognizedTexts)
    }

    // MARK: - CoreGraphics Helper

    private func makeRGBAContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
    }
}
