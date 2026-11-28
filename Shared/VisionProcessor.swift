import CoreGraphics
import Foundation
import Vision

/// Kết quả phân tích Minimap gồm tọa độ người chơi, mục tiêu đỏ và chiều rộng chuẩn 10.0 đơn vị (`screenWidthNorm`).
public struct MinimapAnalysisResult: Equatable, Sendable {
    public let playerPos: CGPoint?
    public let enemyPos: CGPoint?
    public let screenWidthNorm: Double?
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

/// Bộ xử lý thị giác máy tính siêu nhẹ (< 20MB RAM, < 50ms):
/// - Tìm tâm người chơi (xanh dương thuần) & mục tiêu (đỏ tươi thuần).
/// - Đo chiều rộng chuẩn `10.0` đơn vị (`screenWidthNorm`) tự động theo 2 tầng:
///   1) Quét vùng camera sáng ở nửa trên Minimap (`y: 0.048...0.105`, sáng hơn nền tối >= 15%).
///   2) Dự phòng đo khoảng cách 2 vạch tối màu liên tiếp (`5.0` đơn vị × 2) trên thước vàng đáy Minimap (`y: 0.148...0.163`).
public final class VisionProcessor {
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()

    public init() {}

    // MARK: - 1. Minimap Player, Enemy & Dynamic 10.0-Unit Screen Width Measurement

    public func analyzeMinimap(
        minimapCrop: CGImage,
        yellowRulerCrop: CGImage? = nil,
        fallbackPlayerPos: CGPoint? = nil
    ) -> MinimapAnalysisResult? {
        let outW = minimapCrop.width
        let outH = minimapCrop.height
        guard outW >= 8, outH >= 6,
              let context = makeRGBAContext(width: outW, height: outH),
              let rgbaPtr = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }

        context.interpolationQuality = .none
        context.draw(minimapCrop, in: CGRect(x: 0, y: 0, width: outW, height: outH))

        let pixelCount = outW * outH
        var blueMask = [Bool](repeating: false, count: pixelCount)
        var redMask = [Bool](repeating: false, count: pixelCount)

        let bytesPerRow = context.bytesPerRow
        for y in 0..<outH {
            let rowPtr = rgbaPtr.advanced(by: y * bytesPerRow)
            for x in 0..<outW {
                let px = x * 4
                let r = Int(rowPtr[px])
                let g = Int(rowPtr[px + 1])
                let b = Int(rowPtr[px + 2])
                let idx = y * outW + x

                // Người chơi (Xanh dương thuần): B > 190 && R < 80 && G < 135 && (B - R) > 125.
                if b > 190 && r < 80 && g < 135 && (b - r) > 125 {
                    blueMask[idx] = true
                }
                // Mục tiêu (Đỏ tươi thuần): R > 190 && G < 70 && B < 70 && (R - G) > 135 && (R - B) > 135.
                else if r > 190 && g < 70 && b < 70 && (r - g) > 135 && (r - b) > 135 {
                    redMask[idx] = true
                }
            }
        }

        let playerPos = detectBluePlayer(mask: blueMask, width: outW, height: outH)
        let refPlayer = playerPos ?? fallbackPlayerPos
        let enemyPos = detectNearestRedEnemy(
            mask: redMask,
            width: outW,
            height: outH,
            referencePlayer: refPlayer
        )

        // Cách 1: Đo vùng camera sáng ở nửa trên Minimap (tương ứng y màn hình 0.048...0.105).
        var screenWidthNorm = detectBrightCameraWidthNorm(
            rgbaPtr: rgbaPtr,
            bytesPerRow: bytesPerRow,
            width: outW,
            height: outH,
            blueMask: blueMask,
            redMask: redMask
        )

        // Cách 2 (dự phòng): Đối chiếu khoảng cách 2 vạch tối liên tiếp (5.0 đơn vị x 2) trên thước vàng đáy Minimap.
        if screenWidthNorm == nil, let rulerImage = yellowRulerCrop {
            screenWidthNorm = detectYellowRulerScreenWidthNorm(from: rulerImage)
        }

        return MinimapAnalysisResult(
            playerPos: playerPos,
            enemyPos: enemyPos,
            screenWidthNorm: screenWidthNorm
        )
    }

    // MARK: - 8-Neighbor CCL for Pure Blue Player & Pure Red Enemy

    private struct PixelCluster {
        var centerX: Double
        var centerY: Double
        var count: Int
        var bboxW: Int
        var bboxH: Int
    }

    private func extract8ConnectedClusters(
        from mask: [Bool],
        width: Int,
        height: Int,
        minPixels: Int,
        maxBBoxWidthRatio: Double,
        maxBBoxHeightRatio: Double
    ) -> [PixelCluster] {
        var visited = [Bool](repeating: false, count: width * height)
        var clusters: [PixelCluster] = []
        let maxBBoxW = max(6, Int(Double(width) * maxBBoxWidthRatio))
        let maxBBoxH = max(6, Int(Double(height) * maxBBoxHeightRatio))

        var queueX: [Int] = []
        var queueY: [Int] = []
        queueX.reserveCapacity(48)
        queueY.reserveCapacity(48)

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
                guard count >= minPixels, bboxW <= maxBBoxW, bboxH <= maxBBoxH else { continue }

                clusters.append(
                    PixelCluster(
                        centerX: sumX / Double(count),
                        centerY: sumY / Double(count),
                        count: count,
                        bboxW: bboxW,
                        bboxH: bboxH
                    )
                )
            }
        }

        return clusters
    }

    private func detectBluePlayer(mask: [Bool], width: Int, height: Int) -> CGPoint? {
        let clusters = extract8ConnectedClusters(
            from: mask,
            width: width,
            height: height,
            minPixels: 2,
            maxBBoxWidthRatio: 0.20,
            maxBBoxHeightRatio: 0.45
        )
        guard !clusters.isEmpty else { return nil }

        var best = clusters[0]
        for comp in clusters where comp.count > best.count {
            best = comp
        }
        return CGPoint(
            x: min(max(best.centerX / Double(width), 0.0), 1.0),
            y: min(max(best.centerY / Double(height), 0.0), 1.0)
        )
    }

    private func detectNearestRedEnemy(
        mask: [Bool],
        width: Int,
        height: Int,
        referencePlayer: CGPoint?
    ) -> CGPoint? {
        let raw = extract8ConnectedClusters(
            from: mask,
            width: width,
            height: height,
            minPixels: 2,
            maxBBoxWidthRatio: 0.16,
            maxBBoxHeightRatio: 0.40
        )
        guard !raw.isEmpty else { return nil }

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

        // Bỏ qua nhiễu đỏ nằm quá sát người chơi (< 0.02).
        if let player = referencePlayer {
            points = points.filter { hypot(Double($0.x - player.x), Double($0.y - player.y)) >= 0.02 }
            points.sort {
                hypot(Double($0.x - player.x), Double($0.y - player.y))
                    < hypot(Double($1.x - player.x), Double($1.y - player.y))
            }
        }

        return points.first
    }

    // MARK: - Method 1: Upper-Half Bright Camera Viewport Detection (10.0 Units)

    /// Quét độ sáng trung bình theo từng cột X ở nửa trên Minimap (tương ứng `y: 0.048...0.105` toàn màn hình).
    /// Tìm khoảng liên tục sáng hơn nền tối xung quanh ít nhất `15%` nằm trong dải hợp lệ `0.35...0.85`.
    private func detectBrightCameraWidthNorm(
        rgbaPtr: UnsafeMutablePointer<UInt8>,
        bytesPerRow: Int,
        width: Int,
        height: Int,
        blueMask: [Bool],
        redMask: [Bool]
    ) -> Double? {
        guard width >= 20, height >= 8 else { return nil }

        // Ánh xạ dải màn hình y ∈ [0.048, 0.105] vào bên trong minimapStrip (y = 0.042, h = 0.114).
        let localYStart = (0.048 - Double(GunnyROIs.minimapStrip.origin.y)) / Double(GunnyROIs.minimapStrip.size.height)
        let localYEnd = (0.105 - Double(GunnyROIs.minimapStrip.origin.y)) / Double(GunnyROIs.minimapStrip.size.height)
        let yStart = min(max(Int((localYStart * Double(height)).rounded()), 0), max(height - 2, 0))
        let yEnd = min(max(Int((localYEnd * Double(height)).rounded()), yStart + 2), height)

        var colMean = [Double](repeating: 0.0, count: width)
        for x in 0..<width {
            var sum = 0.0
            var samples = 0
            for y in yStart..<yEnd {
                let idx = y * width + x
                if blueMask[idx] || redMask[idx] { continue }
                let px = y * bytesPerRow + x * 4
                let lum = 0.299 * Double(rgbaPtr[px]) + 0.587 * Double(rgbaPtr[px + 1]) + 0.114 * Double(rgbaPtr[px + 2])
                sum += lum
                samples += 1
            }
            colMean[x] = samples > 0 ? (sum / Double(samples)) : 0.0
        }

        // Làm mượt nhẹ 3 cột để tránh nhiễu 1 pixel mà vẫn giữ sắc nét biên khung camera.
        var smooth = [Double](repeating: 0.0, count: width)
        for x in 0..<width {
            let l = colMean[max(0, x - 1)]
            let c = colMean[x]
            let r = colMean[min(width - 1, x + 1)]
            smooth[x] = (l + c + r) / 3.0
        }

        // Lấy mức nền tối từ 12% cột tối nhất (đảm bảo luôn lấy đúng nền tối ngoài khung camera dù khung rộng tới 85%).
        let sorted = smooth.sorted()
        let darkCount = max(4, Int(Double(width) * 0.12))
        var darkSum = 0.0
        for i in 0..<min(darkCount, sorted.count) {
            darkSum += sorted[i]
        }
        let darkBaseline = darkSum / Double(max(min(darkCount, sorted.count), 1))
        let threshold = max(darkBaseline * 1.15, darkBaseline + 4.0)

        var bestStart = -1
        var bestEnd = -1
        var bestLen = 0
        var x = 0
        while x < width {
            guard smooth[x] >= threshold else {
                x += 1
                continue
            }
            let runStart = x
            var runEnd = x
            var gap = 0
            while x < width {
                if smooth[x] >= threshold {
                    runEnd = x
                    gap = 0
                } else {
                    gap += 1
                    if gap > 2 { break }
                }
                x += 1
            }
            let runLen = runEnd - runStart + 1
            if runLen > bestLen {
                bestLen = runLen
                bestStart = runStart
                bestEnd = runEnd
            }
        }

        guard bestLen >= 8, bestStart >= 0, bestEnd >= bestStart else { return nil }

        // Kiểm chứng độ sáng trung bình bên trong khung thực sự cao hơn nền tối xung quanh >= 15%.
        var insideSum = 0.0
        var insideCount = 0
        var outsideSum = 0.0
        var outsideCount = 0
        for idx in 0..<width {
            if idx >= bestStart && idx <= bestEnd {
                insideSum += colMean[idx]
                insideCount += 1
            } else {
                outsideSum += colMean[idx]
                outsideCount += 1
            }
        }

        let insideMean = insideSum / Double(max(insideCount, 1))
        let outsideMean = outsideCount >= 4 ? (outsideSum / Double(outsideCount)) : darkBaseline
        guard insideMean >= max(outsideMean * 1.15, outsideMean + 4.0) else {
            return nil
        }

        // Tinh chỉnh chính xác 2 mép khung camera bằng ngưỡng trung bình (mid-point) trên colMean gốc để loại sai số làm mượt 1px.
        let midThreshold = (insideMean + outsideMean) * 0.5
        var refinedStart = bestStart
        var refinedEnd = bestEnd
        while refinedStart < refinedEnd && colMean[refinedStart] < midThreshold {
            refinedStart += 1
        }
        while refinedEnd > refinedStart && colMean[refinedEnd] < midThreshold {
            refinedEnd -= 1
        }

        let widthNorm = Double(refinedEnd - refinedStart + 1) / Double(width)
        guard widthNorm >= 0.35 && widthNorm <= 0.85 else {
            return nil
        }
        return widthNorm
    }

    // MARK: - Method 2: Fallback Yellow Ruler 5-Unit Tick Spacing (y: 0.148...0.163)

    /// Tìm các vạch chia tối màu dọc thước vàng đáy Minimap để lấy khoảng cách 2 vạch liên tiếp (`5.0` đơn vị) và nhân đôi (`10.0` đơn vị).
    public func detectYellowRulerScreenWidthNorm(from rulerImage: CGImage) -> Double? {
        let outW = rulerImage.width
        let outH = rulerImage.height
        guard outW >= 20, outH >= 2,
              let context = makeRGBAContext(width: outW, height: outH),
              let rgbaPtr = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }

        context.interpolationQuality = .none
        context.draw(rulerImage, in: CGRect(x: 0, y: 0, width: outW, height: outH))

        let bytesPerRow = context.bytesPerRow
        var colLum = [Double](repeating: 0.0, count: outW)
        for x in 0..<outW {
            var sum = 0.0
            for y in 0..<outH {
                let px = y * bytesPerRow + x * 4
                sum += 0.299 * Double(rgbaPtr[px]) + 0.587 * Double(rgbaPtr[px + 1]) + 0.114 * Double(rgbaPtr[px + 2])
            }
            colLum[x] = sum / Double(outH)
        }

        let sorted = colLum.sorted()
        let brightRef = sorted[min(Int(Double(outW) * 0.75), outW - 1)]
        guard brightRef >= 60.0 else { return nil }

        let darkThreshold = min(brightRef * 0.72, brightRef - 25.0)
        var tickCenters: [Double] = []
        let maxTickWidthPx = max(2, Int(Double(outW) * 0.06))

        var x = 1
        while x < (outW - 1) {
            guard colLum[x] <= darkThreshold else {
                x += 1
                continue
            }
            let startX = x
            while x < (outW - 1) && colLum[x] <= darkThreshold {
                x += 1
            }
            let endX = x - 1
            let tickW = endX - startX + 1
            if tickW <= maxTickWidthPx {
                let centerNorm = (Double(startX + endX) * 0.5) / Double(outW)
                tickCenters.append(centerNorm)
            }
        }

        guard tickCenters.count >= 2 else { return nil }

        var validSpacings: [Double] = []
        for i in 0..<(tickCenters.count - 1) {
            let spacing = tickCenters[i + 1] - tickCenters[i]
            // 1 khoảng vạch = 5.0 đơn vị -> 2 * spacing phải nằm trong [0.35, 0.85].
            if spacing >= 0.175 && spacing <= 0.425 {
                validSpacings.append(spacing)
            }
        }
        guard !validSpacings.isEmpty else { return nil }

        validSpacings.sort()
        let medianSpacing = validSpacings[validSpacings.count / 2]
        let screenWidth = 2.0 * medianSpacing
        guard screenWidth >= 0.35 && screenWidth <= 0.85 else { return nil }
        return screenWidth
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
