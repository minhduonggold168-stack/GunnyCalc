import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Kết quả phân tích Minimap ở độ phân giải gốc: tọa độ người chơi, các cụm địch, khung camera trắng và ảnh JPEG.
public struct MinimapAnalysis: Equatable, Sendable {
    public let playerPos: CGPoint?
    public let enemies: [CGPoint]
    public let cameraRect: NormalizedRect?
    public let minimapAspectHOverW: Double
    public let minimapJPEG: Data?
}

/// Bộ xử lý thị giác độ chính xác cao (< 25MB RAM) dùng thuần CoreGraphics, ImageIO và Vision.
public final class VisionProcessor {
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

    public init() {}

    // MARK: - 1. Native-Resolution Minimap Analysis (No Pre-Downscale)

    /// Quét trực tiếp ảnh Minimap ở độ phân giải gốc để không làm mất các chấm đỏ nhỏ (từ 2 pixel trở lên).
    public func analyzeMinimapCrop(
        _ cropped: CGImage,
        includeJPEG: Bool = true
    ) -> MinimapAnalysis? {
        let outW = cropped.width
        let outH = cropped.height
        guard outW >= 8, outH >= 8 else { return nil }

        let minimapAspectHOverW = Double(outH) / Double(outW)
        guard let context = makeRGBAContext(width: outW, height: outH),
              let rgbaPtr = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }

        context.interpolationQuality = .none
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
                let r = Int(rowPtr[px])
                let g = Int(rowPtr[px + 1])
                let b = Int(rowPtr[px + 2])
                let idx = y * outW + x

                // Khung camera trắng bên trong Minimap (loại bỏ sát viền 2px ngoài cùng).
                if x >= 2 && x < (outW - 2) && y >= 2 && y < (outH - 2) {
                    let maxRGB = max(r, max(g, b))
                    let minRGB = min(r, min(g, b))
                    if r >= 205 && g >= 205 && b >= 205 && (maxRGB - minRGB) <= 38 {
                        whiteMask[idx] = true
                    }
                }

                // Cụm xanh dương đậm của người chơi: B > 170, B - R > 80, B - G > 60.
                if b > 170 && (b - r) > 80 && (b - g) > 60 {
                    blueMask[idx] = true
                }
                // Ngưỡng mở rộng bắt chấm đỏ mục tiêu: R > 155, R - G > 55, R - B > 55.
                else if r > 155 && (r - g) > 55 && (r - b) > 55 {
                    redMask[idx] = true
                }
            }
        }

        let searchRadius = outW >= 240 ? 3 : 2
        let playerPos = detectPlayerCluster(mask: blueMask, width: outW, height: outH, searchRadius: searchRadius)
        let enemies = detectEnemyClusters(
            mask: redMask,
            width: outW,
            height: outH,
            searchRadius: searchRadius,
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
        searchRadius: Int,
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

                    let yFrom = max(0, cy - searchRadius)
                    let yTo = min(height - 1, cy + searchRadius)
                    let xFrom = max(0, cx - searchRadius)
                    let xTo = min(width - 1, cx + searchRadius)

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

    private func detectPlayerCluster(
        mask: [Bool],
        width: Int,
        height: Int,
        searchRadius: Int
    ) -> CGPoint? {
        let clusters = extractClusters(
            from: mask,
            width: width,
            height: height,
            searchRadius: searchRadius,
            minPixels: 3,
            maxBBoxWidthRatio: 0.22,
            maxBBoxHeightRatio: 0.26
        )
        guard !clusters.isEmpty else { return nil }

        var bestCluster = clusters[0]
        var bestScore = -1.0
        for cluster in clusters {
            let triangleBonus = Double(cluster.bboxH) >= Double(cluster.bboxW) * 0.85 ? 16.0 : 0.0
            let score = Double(min(cluster.count, 240)) + triangleBonus
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
        searchRadius: Int,
        playerPos: CGPoint?
    ) -> [CGPoint] {
        // Chấp nhận cụm mục tiêu đỏ từ 2 pixel trở lên để bắt chấm rất nhỏ sát mép phải hoặc đè vạch 15.
        let rawClusters = extractClusters(
            from: mask,
            width: width,
            height: height,
            searchRadius: searchRadius,
            minPixels: 2,
            maxBBoxWidthRatio: 0.14,
            maxBBoxHeightRatio: 0.18
        )
        guard !rawClusters.isEmpty else { return [] }

        let mergeDistPx = max(5.0, Double(width) * 0.032)
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
        let maxEdgeH = Int(Double(height) * 0.90)
        let minRectW = max(14, Int(Double(width) * 0.22))
        let maxRectW = Int(Double(width) * 0.85)
        guard width >= 20, height >= 16, minRectW < maxRectW else { return nil }

        let maxGap = width >= 240 ? 2 : 1
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
                        if gap > maxGap { break }
                    }
                    y += 1
                }
                let spanH = endY - startY + 1
                if spanH >= minEdgeH && spanH <= maxEdgeH {
                    let cov = Double(whiteHits) / Double(spanH)
                    if cov >= 0.55 {
                        candidates.append(VerticalEdgeCandidate(x: x, yTop: startY, yBottom: endY, coverage: cov))
                    }
                }
            }
        }

        guard candidates.count >= 2 else { return nil }
        candidates.sort {
            ($0.coverage * Double($0.yBottom - $0.yTop)) > ($1.coverage * Double($1.yBottom - $1.yTop))
        }
        let topEdges = Array(candidates.prefix(24))

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
                guard aspect >= 1.0 && aspect <= 3.4 else { continue }

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

    // MARK: - 2. High-Sensitivity Battlefield Angle OCR (.accurate, -35° ... 85°)

    /// Nhận diện chuỗi `Góc 38°`, `Góc -18°`, `Góc 67°` bằng `VNRecognizeTextRequest` (`.accurate`) trên ảnh đã tăng tương phản `CIColorControls`.
    public func detectBattlefieldAngle(fromContrastImage cropped: CGImage) -> Double? {
        guard cropped.width >= 16, cropped.height >= 16 else { return nil }

        let observations = performAccurateTextObservations(on: cropped, minimumTextHeight: 0.02)
        guard !observations.isEmpty else { return nil }

        // Ưu tiên 1: Khớp chính xác chuỗi "Góc XX°" / "Góc -18°" (-35°...85°).
        for obs in observations {
            for candidate in obs.topCandidates(2) {
                if let matched = Self.matchGocRegex(in: candidate.string) {
                    return matched
                }
            }
        }

        // Ưu tiên 2: Nếu chữ "Góc" bị hiệu ứng che khuất nhưng còn ký hiệu độ `°`, bỏ qua góc dưới trái và số 0 đơn lẻ.
        for obs in observations {
            if obs.boundingBox.minX < 0.16 && obs.boundingBox.minY < 0.14 {
                continue
            }
            for candidate in obs.topCandidates(2) {
                if let matched = Self.matchDegreeFallback(in: candidate.string), matched != 0.0 {
                    return matched
                }
            }
        }

        return nil
    }

    public static func matchGocRegex(in rawText: String) -> Double? {
        if let regex = gocRawRegex,
           let val = extractFirstNumericGroup(using: regex, in: rawText),
           val >= -35.0 && val <= 85.0 {
            return val
        }

        let folded = rawText.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        if let regex = gocFoldedRegex,
           let val = extractFirstNumericGroup(using: regex, in: folded),
           val >= -35.0 && val <= 85.0 {
            return val
        }

        return nil
    }

    private static func matchDegreeFallback(in rawText: String) -> Double? {
        guard let regex = degreeOnlyRegex,
              let val = extractFirstNumericGroup(using: regex, in: rawText),
              val >= -35.0 && val <= 85.0 else {
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

    private func performAccurateTextObservations(on image: CGImage, minimumTextHeight: Float) -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
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
}
