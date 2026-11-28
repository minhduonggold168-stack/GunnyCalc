import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Kết quả phân tích Minimap bản không gió: tọa độ người chơi, cụm mục tiêu độc lập, khung camera trắng và ảnh JPEG.
public struct MinimapAnalysis: Equatable, Sendable {
    public let playerPos: CGPoint?
    public let enemies: [CGPoint]
    public let cameraRect: NormalizedRect?
    public let minimapAspectHOverW: Double
    public let minimapJPEG: Data?
}

/// Bộ xử lý thị giác tốc độ cao (< 20MB RAM) dùng thuần CoreGraphics, ImageIO và Vision (.fast).
/// - Không quét vùng gió hay đồng hồ đếm ngược lượt ở giữa trên cùng.
public final class VisionProcessor {
    private static let maxMinimapSampleDimension = 160
    private static let maxBattlefieldAngleDimension = 560
    private static let minimapJPEGWidth = 160
    private static let minimapJPEGHeight = 100

    private static let gocRawRegex = try? NSRegularExpression(
        pattern: #"g[oóôòỏõọốồổỗộớờởỡợ]c\s*[:=]?\s*(-?\d{1,2})\s*[°º]?"#,
        options: [.caseInsensitive]
    )
    private static let gocFoldedRegex = try? NSRegularExpression(
        pattern: #"goc\s*[:=]?\s*(-?\d{1,2})\s*[°º]?"#,
        options: [.caseInsensitive]
    )
    private static let degreeOnlyRegex = try? NSRegularExpression(
        pattern: #"(-?\d{1,2})\s*[°º]"#,
        options: []
    )

    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    private let grayColorSpace = CGColorSpaceCreateDeviceGray()

    public init() {}

    // MARK: - 1. Battle UI Verification (3 Combat Signs)

    /// Dấu hiệu 1a: Nút đóng màu đỏ `[X]` ở góc trên bên phải (`x: 0.94...0.99, y: 0.005...0.055`).
    public func detectRedCloseButton(in cropped: CGImage) -> Bool {
        let (outW, outH) = clampedSize(width: cropped.width, height: cropped.height, maxDimension: 48)
        guard outW >= 4, outH >= 4,
              let context = makeRGBAContext(width: outW, height: outH),
              let ptr = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return false
        }

        context.interpolationQuality = .low
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))

        let bytesPerRow = context.bytesPerRow
        let total = max(outW * outH, 1)
        var redHits = 0
        var brightCrossHits = 0

        for y in 0..<outH {
            let row = ptr.advanced(by: y * bytesPerRow)
            for x in 0..<outW {
                let px = x * 4
                let r = row[px]
                let g = row[px + 1]
                let b = row[px + 2]
                let hsv = rgbToHSV(r: r, g: g, b: b)

                if (hsv.h <= 22.0 || hsv.h >= 338.0) && hsv.s >= 0.40 && hsv.v >= 0.32 {
                    redHits += 1
                } else if r >= 185 && g >= 185 && b >= 185 && hsv.s <= 0.25 {
                    brightCrossHits += 1
                }
            }
        }

        let redRatio = Double(redHits) / Double(total)
        let crossRatio = Double(brightCrossHits) / Double(total)
        return redRatio >= 0.12 && crossRatio >= 0.02
    }

    /// Dấu hiệu 1b: Thước chia màu vàng `0 - 5 - 10` ở đáy Minimap (`x: 0.848...0.995, y: 0.145...0.175`).
    public func detectGoldenMinimapRuler(in cropped: CGImage) -> Bool {
        let (outW, outH) = clampedSize(width: cropped.width, height: cropped.height, maxDimension: 120)
        guard outW >= 8, outH >= 4,
              let context = makeRGBAContext(width: outW, height: outH),
              let ptr = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return false
        }

        context.interpolationQuality = .low
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))

        let bytesPerRow = context.bytesPerRow
        let total = max(outW * outH, 1)
        var goldHits = 0

        for y in 0..<outH {
            let row = ptr.advanced(by: y * bytesPerRow)
            for x in 0..<outW {
                let px = x * 4
                let hsv = rgbToHSV(r: row[px], g: row[px + 1], b: row[px + 2])
                if hsv.h >= 24.0 && hsv.h <= 66.0 && hsv.s >= 0.30 && hsv.v >= 0.40 {
                    goldHits += 1
                }
            }
        }

        let goldRatio = Double(goldHits) / Double(total)
        return goldRatio >= 0.035
    }

    /// Dấu hiệu 2: Thanh thước lực `10 20 30 ... 100` ở cạnh dưới màn hình (`x: 0.30...0.72, y: 0.88...0.95`).
    public func detectBottomPowerBar(in cropped: CGImage) -> Bool {
        let (outW, outH) = clampedSize(width: cropped.width, height: cropped.height, maxDimension: 160)
        guard outW >= 24, outH >= 6,
              let context = makeGrayscaleContext(width: outW, height: outH),
              let ptr = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return false
        }

        context.interpolationQuality = .low
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))

        let bytesPerRow = context.bytesPerRow
        let bucketCount = 8
        var bucketContrastHits = [Int](repeating: 0, count: bucketCount)
        var bucketBrightHits = [Int](repeating: 0, count: bucketCount)
        var strongBorderRows = 0

        for y in 0..<(outH - 1) {
            let row = ptr.advanced(by: y * bytesPerRow)
            let nextRow = ptr.advanced(by: (y + 1) * bytesPerRow)
            var rowVertEdges = 0

            for x in 0..<(outW - 1) {
                let lum = Int(row[x])
                let rightLum = Int(row[x + 1])
                let downLum = Int(nextRow[x])
                let bucket = min((x * bucketCount) / outW, bucketCount - 1)

                if abs(lum - downLum) >= 34 {
                    rowVertEdges += 1
                    bucketContrastHits[bucket] += 1
                } else if abs(lum - rightLum) >= 34 {
                    bucketContrastHits[bucket] += 1
                }

                if lum >= 160 {
                    bucketBrightHits[bucket] += 1
                }
            }

            if Double(rowVertEdges) / Double(max(outW - 1, 1)) >= 0.20 {
                strongBorderRows += 1
            }
        }

        let activeContrastBuckets = bucketContrastHits.filter { $0 >= 6 }.count
        let activeBrightBuckets = bucketBrightHits.filter { $0 >= 3 }.count
        return strongBorderRows >= 2 && activeContrastBuckets >= 5 && activeBrightBuckets >= 4
    }

    // MARK: - 2. Direct-Crop Minimap Analysis (25 FPS Fast Path)

    public func analyzeMinimapCrop(
        _ cropped: CGImage,
        includeJPEG: Bool = true
    ) -> MinimapAnalysis? {
        let cropW = cropped.width
        let cropH = cropped.height
        guard cropW >= 8, cropH >= 8 else { return nil }

        let minimapAspectHOverW = Double(cropH) / Double(cropW)
        let (outW, outH) = clampedSize(width: cropW, height: cropH, maxDimension: Self.maxMinimapSampleDimension)
        guard let context = makeRGBAContext(width: outW, height: outH),
              let rgbaPtr = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))

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

                if x >= 2 && x < (outW - 2) && y >= 2 && y < (outH - 2) {
                    let maxRGB = max(r, max(g, b))
                    let minRGB = min(r, min(g, b))
                    if r >= 205 && g >= 205 && b >= 205 && (maxRGB - minRGB) <= 38 {
                        whiteMask[idx] = true
                    }
                }

                let hsv = rgbToHSV(r: r, g: g, b: b)
                if hsv.h >= 195.0 && hsv.h <= 248.0 && hsv.s >= 0.45 && hsv.v >= 0.38 {
                    blueMask[idx] = true
                } else if (hsv.h <= 18.0 || hsv.h >= 342.0) && hsv.s >= 0.48 && hsv.v >= 0.38 {
                    redMask[idx] = true
                }
            }
        }

        let playerPos = detectPlayerCluster(mask: blueMask, width: outW, height: outH)
        let enemies = detectEnemyClusters(
            mask: redMask,
            width: outW,
            height: outH,
            playerPos: playerPos
        )
        let cameraRect = detectCameraRectangle(whiteMask: whiteMask, width: outW, height: outH)
        let jpegData = includeJPEG ? encodeMinimapJPEG(from: cropped) : nil

        return MinimapAnalysis(
            playerPos: playerPos,
            enemies: enemies,
            cameraRect: cameraRect,
            minimapAspectHOverW: minimapAspectHOverW,
            minimapJPEG: jpegData
        )
    }

    private struct PixelCluster {
        var centerX: Double
        var centerY: Double
        var count: Int
        var bboxW: Int
        var bboxH: Int
    }

    private func extractClusters(
        from mask: [Bool],
        width: Int,
        height: Int,
        minPixels: Int,
        maxBBoxWidthRatio: Double,
        maxBBoxHeightRatio: Double
    ) -> [PixelCluster] {
        var visited = [Bool](repeating: false, count: width * height)
        var clusters: [PixelCluster] = []
        let maxBBoxW = max(4, Int(Double(width) * maxBBoxWidthRatio))
        let maxBBoxH = max(4, Int(Double(height) * maxBBoxHeightRatio))

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

                    let yFrom = max(0, cy - 2)
                    let yTo = min(height - 1, cy + 2)
                    let xFrom = max(0, cx - 2)
                    let xTo = min(width - 1, cx + 2)

                    for ny in yFrom...yTo {
                        for nx in xFrom...xTo {
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

    private func detectPlayerCluster(mask: [Bool], width: Int, height: Int) -> CGPoint? {
        let clusters = extractClusters(
            from: mask,
            width: width,
            height: height,
            minPixels: 4,
            maxBBoxWidthRatio: 0.22,
            maxBBoxHeightRatio: 0.26
        )
        guard !clusters.isEmpty else { return nil }

        var bestCluster = clusters[0]
        var bestScore = -1.0
        for cluster in clusters {
            let triangleBonus = Double(cluster.bboxH) >= Double(cluster.bboxW) * 0.85 ? 14.0 : 0.0
            let score = Double(min(cluster.count, 160)) + triangleBonus
            if score > bestScore {
                bestScore = score
                bestCluster = cluster
            }
        }

        return CGPoint(
            x: bestCluster.centerX / Double(width),
            y: bestCluster.centerY / Double(height)
        )
    }

    private func detectEnemyClusters(
        mask: [Bool],
        width: Int,
        height: Int,
        playerPos: CGPoint?
    ) -> [CGPoint] {
        let rawClusters = extractClusters(
            from: mask,
            width: width,
            height: height,
            minPixels: 3,
            maxBBoxWidthRatio: 0.20,
            maxBBoxHeightRatio: 0.24
        )
        guard !rawClusters.isEmpty else { return [] }

        let mergeDistPx = max(5.0, Double(width) * 0.045)
        var merged = rawClusters
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
                        merged[i].bboxW = max(merged[i].bboxW, merged[j].bboxW)
                        merged[i].bboxH = max(merged[i].bboxH, merged[j].bboxH)
                        merged.remove(at: j)
                        didMerge = true
                    } else {
                        j += 1
                    }
                }
                i += 1
            }
        }

        var normalized = merged.map {
            CGPoint(x: $0.centerX / Double(width), y: $0.centerY / Double(height))
        }

        if let playerPos {
            normalized.sort {
                hypot(Double($0.x - playerPos.x), Double($0.y - playerPos.y))
                    < hypot(Double($1.x - playerPos.x), Double($1.y - playerPos.y))
            }
        } else {
            normalized.sort { $0.x < $1.x }
        }

        return Array(normalized.prefix(8))
    }

    private struct VerticalEdgeCandidate {
        let x: Int
        let yTop: Int
        let yBottom: Int
        let coverage: Double
    }

    private func detectCameraRectangle(whiteMask: [Bool], width: Int, height: Int) -> NormalizedRect? {
        let minEdgeH = max(8, Int(Double(height) * 0.20))
        let maxEdgeH = Int(Double(height) * 0.88)
        let minRectW = max(12, Int(Double(width) * 0.20))
        let maxRectW = Int(Double(width) * 0.72)
        guard width >= 20, height >= 16, minRectW < maxRectW else { return nil }

        var candidates: [VerticalEdgeCandidate] = []
        for x in 2..<(width - 2) {
            var y = 2
            while y < (height - 2) {
                guard whiteMask[y * width + x] else {
                    y += 1
                    continue
                }
                let startY = y
                var endY = y
                var whiteHits = 0
                var gap = 0
                while y < (height - 2) {
                    if whiteMask[y * width + x] {
                        whiteHits += 1
                        endY = y
                        gap = 0
                    } else {
                        gap += 1
                        if gap > 1 { break }
                    }
                    y += 1
                }
                let spanH = endY - startY + 1
                if spanH >= minEdgeH && spanH <= maxEdgeH {
                    let cov = Double(whiteHits) / Double(spanH)
                    if cov >= 0.60 {
                        candidates.append(VerticalEdgeCandidate(x: x, yTop: startY, yBottom: endY, coverage: cov))
                    }
                }
            }
        }

        guard candidates.count >= 2 else { return nil }
        candidates.sort {
            ($0.coverage * Double($0.yBottom - $0.yTop)) > ($1.coverage * Double($1.yBottom - $1.yTop))
        }
        let topEdges = Array(candidates.prefix(20))

        var bestRect: NormalizedRect?
        var bestScore = 0.0

        for i in 0..<topEdges.count {
            for j in (i + 1)..<topEdges.count {
                let first = topEdges[i]
                let second = topEdges[j]
                let left = first.x < second.x ? first : second
                let right = first.x < second.x ? second : first
                let rectW = right.x - left.x
                guard rectW >= minRectW && rectW <= maxRectW else { continue }

                let yTop = max(left.yTop, right.yTop)
                let yBottom = min(left.yBottom, right.yBottom)
                let rectH = yBottom - yTop + 1
                guard rectH >= minEdgeH else { continue }

                let aspect = Double(rectW) / Double(rectH)
                guard aspect >= 1.0 && aspect <= 3.2 else { continue }

                let topCov = horizontalWhiteCoverage(whiteMask: whiteMask, width: width, height: height, xStart: left.x, xEnd: right.x, yTarget: yTop)
                let bottomCov = horizontalWhiteCoverage(whiteMask: whiteMask, width: width, height: height, xStart: left.x, xEnd: right.x, yTarget: yBottom)
                guard (topCov + bottomCov) * 0.5 >= 0.35 else { continue }

                let totalScore = (left.coverage + right.coverage + topCov + bottomCov) * 0.25
                if totalScore >= 0.45 && totalScore > bestScore {
                    bestScore = totalScore
                    bestRect = NormalizedRect(
                        x: Double(left.x) / Double(width),
                        y: Double(yTop) / Double(height),
                        width: Double(rectW) / Double(width),
                        height: Double(rectH) / Double(height)
                    )
                }
            }
        }

        return bestRect
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
        let yMin = max(0, yTarget - 1)
        let yMax = min(height - 1, yTarget + 1)

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

    private func encodeMinimapJPEG(from cropped: CGImage) -> Data? {
        let targetW = Self.minimapJPEGWidth
        let targetH = Self.minimapJPEGHeight
        guard let context = makeRGBAContext(width: targetW, height: targetH) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        guard let scaledImage = context.makeImage() else { return nil }

        let qualityLevels: [CGFloat] = [0.55, 0.40, 0.28]
        for quality in qualityLevels {
            if let encoded = encodeJPEGData(image: scaledImage, quality: quality),
               encoded.count <= 5200 {
                return encoded
            }
        }
        return encodeJPEGData(image: scaledImage, quality: 0.22)
    }

    private func encodeJPEGData(image: CGImage, quality: CGFloat) -> Data? {
        guard let mutableData = CFDataCreateMutable(kCFAllocatorDefault, 0),
              let destination = CGImageDestinationCreateWithData(
                  mutableData,
                  UTType.jpeg.identifier as CFString,
                  1,
                  nil
              ) else {
            return nil
        }

        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    // MARK: - 3. Battlefield Angle OCR (-30° ... 85°, hỗ trợ góc âm "Góc -18°")

    /// Đọc chuỗi `G[oóô]c\s*(-?\d{1,2})\s*°?` từ vùng chiến trường (`x: 0.04, y: 0.12, w: 0.85, h: 0.62`), bỏ qua cụm D-pad góc dưới trái.
    public func detectBattlefieldAngle(fromCroppedImage cropped: CGImage) -> Double? {
        let cropW = cropped.width
        let cropH = cropped.height
        guard cropW >= 16, cropH >= 16 else { return nil }

        let (outW, outH) = clampedSize(width: cropW, height: cropH, maxDimension: Self.maxBattlefieldAngleDimension)
        guard let enhancedImage = makeContrastGrayImage(from: cropped, width: outW, height: outH) else {
            return nil
        }

        let observations = performFastTextObservations(on: enhancedImage, minimumTextHeight: 0.025)
        guard !observations.isEmpty else { return nil }

        // Ưu tiên 1: Khớp chính xác chuỗi "Góc -18°" / "Góc 56°" / "Gôc 45" (-30°...85°).
        for obs in observations {
            guard let text = obs.topCandidates(1).first?.string else { continue }
            if let matched = Self.matchGocRegex(in: text) {
                return matched
            }
        }

        // Ưu tiên 2: Nếu chữ "Góc" bị hiệu ứng che khuất nhưng còn ký hiệu độ `°`, bỏ qua góc dưới trái và bỏ qua số 0 đơn lẻ.
        for obs in observations {
            // Bỏ qua vùng sát góc dưới trái để tuyệt đối tránh cụm D-pad.
            if obs.boundingBox.minX < 0.18 && obs.boundingBox.minY < 0.15 {
                continue
            }
            guard let text = obs.topCandidates(1).first?.string else { continue }
            if let matched = Self.matchDegreeFallback(in: text), matched != 0.0 {
                return matched
            }
        }

        return nil
    }

    public static func matchGocRegex(in rawText: String) -> Double? {
        if let regex = gocRawRegex,
           let val = extractFirstNumericGroup(using: regex, in: rawText),
           val >= -30.0 && val <= 85.0 {
            return val
        }

        let folded = rawText.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        if let regex = gocFoldedRegex,
           let val = extractFirstNumericGroup(using: regex, in: folded),
           val >= -30.0 && val <= 85.0 {
            return val
        }

        return nil
    }

    private static func matchDegreeFallback(in rawText: String) -> Double? {
        guard let regex = degreeOnlyRegex,
              let val = extractFirstNumericGroup(using: regex, in: rawText),
              val >= -30.0 && val <= 85.0 else {
            return nil
        }
        return val
    }

    private static func extractFirstNumericGroup(using regex: NSRegularExpression, in text: String) -> Double? {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: fullRange),
              match.numberOfRanges >= 2,
              let groupRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Double(text[groupRange])
    }

    // MARK: - CoreGraphics & Vision Helpers

    private func makeContrastGrayImage(from cropped: CGImage, width: Int, height: Int) -> CGImage? {
        guard let grayContext = makeGrayscaleContext(width: width, height: height),
              let grayPtr = grayContext.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }

        grayContext.interpolationQuality = .medium
        grayContext.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        enhanceContrastInPlace(grayBuffer: grayPtr, width: width, height: height, bytesPerRow: grayContext.bytesPerRow)
        return grayContext.makeImage()
    }

    private func performFastTextObservations(on image: CGImage, minimumTextHeight: Float) -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = minimumTextHeight

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return request.results ?? []
    }

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

    private func makeGrayscaleContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: grayColorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
    }

    private func enhanceContrastInPlace(
        grayBuffer: UnsafeMutablePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) {
        var minLum: UInt8 = 255
        var maxLum: UInt8 = 0

        for y in 0..<height {
            let row = grayBuffer.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let val = row[x]
                if val < minLum { minLum = val }
                if val > maxLum { maxLum = val }
            }
        }

        let span = Int(maxLum) - Int(minLum)
        guard span > 8 else { return }

        let minInt = Int(minLum)
        for y in 0..<height {
            let row = grayBuffer.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let stretched = ((Int(row[x]) - minInt) * 255) / span
                let boosted = ((stretched - 128) * 16) / 10 + 128
                row[x] = UInt8(min(max(boosted, 0), 255))
            }
        }
    }

    private func clampedSize(width: Int, height: Int, maxDimension: Int) -> (Int, Int) {
        let longest = max(width, height)
        guard longest > maxDimension else { return (width, height) }
        let ratio = Double(maxDimension) / Double(longest)
        return (
            max(1, Int((Double(width) * ratio).rounded())),
            max(1, Int((Double(height) * ratio).rounded()))
        )
    }

    private func rgbToHSV(r: UInt8, g: UInt8, b: UInt8) -> (h: Double, s: Double, v: Double) {
        let rf = Double(r) / 255.0
        let gf = Double(g) / 255.0
        let bf = Double(b) / 255.0

        let maxC = max(rf, gf, bf)
        let minC = min(rf, gf, bf)
        let delta = maxC - minC

        let v = maxC
        let s = maxC > 0.0 ? delta / maxC : 0.0

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
}
