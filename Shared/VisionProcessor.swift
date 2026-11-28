import CoreGraphics
import Foundation
import Vision

/// Kết quả tọa độ ngang chuẩn hóa (`0.0 ... 1.0`) đọc từ dải giữa Minimap (`x: 0.848, y: 0.046, w: 0.148, h: 0.096`).
public struct MinimapStripPositions: Equatable, Sendable {
    public let playerX: Double?
    public let enemyXs: [Double]
}

/// Bộ xử lý thị giác độ trễ siêu thấp (< 100ms, < 20MB RAM) dùng thuần CoreGraphics và Vision (`.fast`).
public final class VisionProcessor {
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

    // MARK: - 1. Native Minimap Middle-Strip X Detection (30 FPS)

    /// Quét trực tiếp dải giữa Minimap (dưới nút [X], trên thước vàng) ở độ phân giải gốc để lấy `playerX` và các `enemyXs` (`0.0...1.0`).
    public func detectMinimapStripPositions(from cropped: CGImage) -> MinimapStripPositions? {
        let outW = cropped.width
        let outH = cropped.height
        guard outW >= 8, outH >= 6,
              let context = makeRGBAContext(width: outW, height: outH),
              let rgbaPtr = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }

        context.interpolationQuality = .none
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))

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

                // Cụm xanh dương đậm của người chơi.
                if b > 170 && (b - r) > 80 && (b - g) > 60 {
                    blueMask[idx] = true
                }
                // Cụm đỏ mục tiêu địch.
                else if r > 155 && (r - g) > 55 && (r - b) > 55 {
                    redMask[idx] = true
                }
            }
        }

        let searchRadius = outW >= 240 ? 3 : 2
        let playerX = detectPlayerCenterX(mask: blueMask, width: outW, height: outH, searchRadius: searchRadius)
        let enemyXs = detectEnemyCenterXs(
            mask: redMask,
            width: outW,
            height: outH,
            searchRadius: searchRadius,
            playerX: playerX
        )

        return MinimapStripPositions(playerX: playerX, enemyXs: enemyXs)
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

    private func detectPlayerCenterX(
        mask: [Bool],
        width: Int,
        height: Int,
        searchRadius: Int
    ) -> Double? {
        let clusters = extractClusters(
            from: mask,
            width: width,
            height: height,
            searchRadius: searchRadius,
            minPixels: 3,
            maxBBoxWidthRatio: 0.22,
            maxBBoxHeightRatio: 0.45
        )
        guard !clusters.isEmpty else { return nil }

        var best = clusters[0]
        for cluster in clusters where cluster.count > best.count {
            best = cluster
        }
        return min(max(best.centerX / Double(width), 0.0), 1.0)
    }

    private func detectEnemyCenterXs(
        mask: [Bool],
        width: Int,
        height: Int,
        searchRadius: Int,
        playerX: Double?
    ) -> [Double] {
        let rawClusters = extractClusters(
            from: mask,
            width: width,
            height: height,
            searchRadius: searchRadius,
            minPixels: 2,
            maxBBoxWidthRatio: 0.16,
            maxBBoxHeightRatio: 0.35
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
                        merged.remove(at: j)
                        didMerge = true
                    } else {
                        j += 1
                    }
                }
                i += 1
            }
        }

        var xs = merged.map { min(max($0.centerX / Double(width), 0.0), 1.0) }
        if let playerX {
            xs.sort { abs($0 - playerX) < abs($1 - playerX) }
        } else {
            xs.sort()
        }
        return xs
    }

    // MARK: - 2. Ultra-Fast Grayscale Angle OCR (.fast, -35 ... 85)

    /// Nhận diện siêu tốc (< 50ms) số nguyên góc `-35...85` cạnh chữ `Góc` hoặc ký hiệu `°` trên ảnh xám Grayscale.
    public func detectAngle(fromGrayscaleImage cropped: CGImage) -> Int? {
        guard cropped.width >= 16, cropped.height >= 16 else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.025

        let handler = VNImageRequestHandler(cgImage: cropped, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else { return nil }

        for obs in observations {
            guard let text = obs.topCandidates(1).first?.string else { continue }
            if let matched = Self.matchGocRegex(in: text) {
                return matched
            }
        }

        for obs in observations {
            if obs.boundingBox.minX < 0.16 && obs.boundingBox.minY < 0.14 {
                continue
            }
            guard let text = obs.topCandidates(1).first?.string else { continue }
            if let matched = Self.matchDegreeFallback(in: text), matched != 0 {
                return matched
            }
        }

        return nil
    }

    public static func matchGocRegex(in rawText: String) -> Int? {
        if let regex = gocRawRegex,
           let val = extractFirstIntegerGroup(using: regex, in: rawText),
           val >= -35 && val <= 85 {
            return val
        }

        let folded = rawText.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        if let regex = gocFoldedRegex,
           let val = extractFirstIntegerGroup(using: regex, in: folded),
           val >= -35 && val <= 85 {
            return val
        }

        return nil
    }

    private static func matchDegreeFallback(in rawText: String) -> Int? {
        guard let regex = degreeOnlyRegex,
              let val = extractFirstIntegerGroup(using: regex, in: rawText),
              val >= -35 && val <= 85 else {
            return nil
        }
        return val
    }

    private static func extractFirstIntegerGroup(using regex: NSRegularExpression, in text: String) -> Int? {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: fullRange),
              match.numberOfRanges >= 2,
              let groupRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(text[groupRange])
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
