import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Kết quả phân tích Minimap gồm tọa độ người chơi, danh sách mục tiêu độc lập, khung camera trắng và ảnh JPEG cắt trực tiếp.
public struct MinimapAnalysis: Equatable, Sendable {
    public let playerPos: NormalizedPoint?
    public let enemies: [NormalizedPoint]
    public let cameraRect: NormalizedRect?
    public let minimapAspectHOverW: Double
    public let minimapJPEG: Data?
}

/// Kết quả đọc ô Gió sau bước kiểm tra viền khung mũi tên gió.
public struct WindObservation: Equatable, Sendable {
    public let value: Double?
    public let direction: Int
    public let hasWindFrame: Bool
}

/// Kết quả đọc kép Góc bắn từ cả vùng chiến trường (`°`) và cụm phím D-pad góc dưới trái.
public struct AngleObservation: Equatable, Sendable {
    public let battlefieldAngle: Double?
    public let dpadAngle: Double?
}

/// Bộ xử lý thị giác máy tính (< 25MB RAM) dùng thuần CoreGraphics, ImageIO và Vision (.fast).
public final class VisionProcessor {
    private static let maxMinimapSampleDimension = 180
    private static let maxWindSampleDimension = 220
    private static let maxBattlefieldAngleDimension = 560
    private static let maxDPadSampleDimension = 220
    private static let minimapJPEGWidth = 160
    private static let minimapJPEGHeight = 100
    private static let allowedNumericChars = CharacterSet(charactersIn: "0123456789-+.")

    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    private let grayColorSpace = CGColorSpaceCreateDeviceGray()

    public init() {}

    // MARK: - 1. Minimap Clustering, Camera Viewport & JPEG Compression

    public func analyzeMinimap(
        from cgImage: CGImage,
        normalizedRect: NormalizedRect = GunnyROIs.minimap
    ) -> MinimapAnalysis? {
        let roiPixel = normalizedRect.pixelRect(width: cgImage.width, height: cgImage.height)
        let cropW = Int(roiPixel.width)
        let cropH = Int(roiPixel.height)
        guard cropW >= 8, cropH >= 8,
              let cropped = cgImage.cropping(to: roiPixel) else {
            return nil
        }

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

                // Khung chữ nhật camera trắng bên trong Minimap (loại bỏ sát viền 2px ngoài cùng).
                if x >= 2 && x < (outW - 2) && y >= 2 && y < (outH - 2) {
                    let maxRGB = max(r, max(g, b))
                    let minRGB = min(r, min(g, b))
                    if r >= 205 && g >= 205 && b >= 205 && (maxRGB - minRGB) <= 38 {
                        whiteMask[idx] = true
                    }
                }

                let hsv = rgbToHSV(r: r, g: g, b: b)

                // Cụm xanh dương kèm dấu tam giác chỉ người chơi.
                if hsv.h >= 195.0 && hsv.h <= 248.0 && hsv.s >= 0.45 && hsv.v >= 0.38 {
                    blueMask[idx] = true
                }
                // Cụm đỏ chỉ kẻ địch.
                else if (hsv.h <= 18.0 || hsv.h >= 342.0) && hsv.s >= 0.48 && hsv.v >= 0.38 {
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
        let minimapJPEG = encodeMinimapJPEG(from: cropped)

        return MinimapAnalysis(
            playerPos: playerPos,
            enemies: enemies,
            cameraRect: cameraRect,
            minimapAspectHOverW: minimapAspectHOverW,
            minimapJPEG: minimapJPEG
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

    private func detectPlayerCluster(mask: [Bool], width: Int, height: Int) -> NormalizedPoint? {
        let clusters = extractClusters(
            from: mask,
            width: width,
            height: height,
            minPixels: 4,
            maxBBoxWidthRatio: 0.22,
            maxBBoxHeightRatio: 0.26
        )
        guard !clusters.isEmpty else { return nil }

        // Ưu tiên cụm xanh dương nhỏ gọn có dấu tam giác định hướng dọc phía trên chấm.
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

        return NormalizedPoint(
            x: bestCluster.centerX / Double(width),
            y: bestCluster.centerY / Double(height)
        )
    }

    private func detectEnemyClusters(
        mask: [Bool],
        width: Int,
        height: Int,
        playerPos: NormalizedPoint?
    ) -> [NormalizedPoint] {
        let rawClusters = extractClusters(
            from: mask,
            width: width,
            height: height,
            minPixels: 3,
            maxBBoxWidthRatio: 0.20,
            maxBBoxHeightRatio: 0.24
        )
        guard !rawClusters.isEmpty else { return [] }

        // Gom các mảnh chấm đỏ cùng 1 mục tiêu lại theo ngưỡng khoảng cách, tách biệt hoàn toàn từng mục tiêu độc lập.
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
            NormalizedPoint(x: $0.centerX / Double(width), y: $0.centerY / Double(height))
        }

        if let playerPos {
            normalized.sort {
                hypot($0.x - playerPos.x, $0.y - playerPos.y) < hypot($1.x - playerPos.x, $1.y - playerPos.y)
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

    // MARK: - 2. Wind Arrow Frame Lock + OCR + Direction

    public func detectWind(
        from cgImage: CGImage,
        normalizedRect: NormalizedRect = GunnyROIs.wind
    ) -> WindObservation {
        let roiPixel = normalizedRect.pixelRect(width: cgImage.width, height: cgImage.height)
        let cropW = Int(roiPixel.width)
        let cropH = Int(roiPixel.height)
        guard cropW >= 8, cropH >= 4,
              let cropped = cgImage.cropping(to: roiPixel) else {
            return WindObservation(value: nil, direction: 1, hasWindFrame: false)
        }

        let scale = cropH < 44 ? 2 : 1
        let (outW, outH) = clampedSize(width: cropW * scale, height: cropH * scale, maxDimension: Self.maxWindSampleDimension)
        guard let rgbaContext = makeRGBAContext(width: outW, height: outH),
              let rgbaPtr = rgbaContext.data?.assumingMemoryBound(to: UInt8.self) else {
            return WindObservation(value: nil, direction: 1, hasWindFrame: false)
        }

        rgbaContext.interpolationQuality = .medium
        rgbaContext.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))

        let rgbaBytesPerRow = rgbaContext.bytesPerRow
        var lumBuffer = [UInt8](repeating: 0, count: outW * outH)
        var frameColorHits = 0
        var innerPixels = 0

        let x0 = max(1, Int(Double(outW) * 0.08))
        let x1 = min(outW - 2, Int(Double(outW) * 0.92))
        let y0 = max(1, Int(Double(outH) * 0.12))
        let y1 = min(outH - 2, Int(Double(outH) * 0.88))

        let midX = outW / 2
        var leftBright = 0
        var rightBright = 0

        for y in 0..<outH {
            let row = rgbaPtr.advanced(by: y * rgbaBytesPerRow)
            for x in 0..<outW {
                let px = x * 4
                let r = row[px]
                let g = row[px + 1]
                let b = row[px + 2]
                let lumInt = (Int(r) * 77 + Int(g) * 150 + Int(b) * 29) >> 8
                let lum = UInt8(min(max(lumInt, 0), 255))
                lumBuffer[y * outW + x] = lum

                if lum >= 175 {
                    if x < midX {
                        leftBright += 1
                    } else {
                        rightBright += 1
                    }
                }

                if x >= x0 && x <= x1 && y >= y0 && y <= y1 {
                    innerPixels += 1
                    let hsv = rgbToHSV(r: r, g: g, b: b)
                    if (hsv.v >= 0.55 && hsv.s >= 0.26) || (hsv.v >= 0.84 && hsv.s <= 0.24) {
                        frameColorHits += 1
                    }
                }
            }
        }

        var borderEdgeHits = 0
        if x1 > x0 && y1 > y0 {
            for y in y0...y1 {
                for x in x0...x1 {
                    let cur = Int(lumBuffer[y * outW + x])
                    let right = Int(lumBuffer[y * outW + (x + 1)])
                    let down = Int(lumBuffer[(y + 1) * outW + x])
                    if abs(cur - right) >= 42 || abs(cur - down) >= 42 {
                        borderEdgeHits += 1
                    }
                }
            }
        }

        let safeInner = max(innerPixels, 1)
        let borderEdgeDensity = Double(borderEdgeHits) / Double(safeInner)
        let frameColorDensity = Double(frameColorHits) / Double(safeInner)

        // Khóa chống đọc nhầm đồng hồ lượt: không thấy đặc trưng viền khung mũi tên gió => Gió = 0.0, bỏ qua OCR.
        guard borderEdgeDensity >= 0.055 && frameColorDensity >= 0.075 else {
            return WindObservation(value: 0.0, direction: 1, hasWindFrame: false)
        }

        let direction = leftBright > rightBright ? -1 : 1

        guard let grayContext = makeGrayscaleContext(width: outW, height: outH),
              let grayPtr = grayContext.data?.assumingMemoryBound(to: UInt8.self) else {
            return WindObservation(value: nil, direction: direction, hasWindFrame: true)
        }

        let grayBytesPerRow = grayContext.bytesPerRow
        for y in 0..<outH {
            let dstRow = grayPtr.advanced(by: y * grayBytesPerRow)
            for x in 0..<outW {
                dstRow[x] = lumBuffer[y * outW + x]
            }
        }

        enhanceContrastInPlace(grayBuffer: grayPtr, width: outW, height: outH, bytesPerRow: grayBytesPerRow)
        guard let enhancedImage = grayContext.makeImage() else {
            return WindObservation(value: nil, direction: direction, hasWindFrame: true)
        }

        let candidates = performFastTextRecognition(on: enhancedImage, minimumTextHeight: 0.15)
        guard let parsed = Self.parseFilteredNumber(from: candidates.joined(separator: " ")) else {
            return WindObservation(value: nil, direction: direction, hasWindFrame: true)
        }

        let magnitude = abs(parsed)
        guard magnitude <= 5.5 else {
            return WindObservation(value: nil, direction: direction, hasWindFrame: true)
        }

        let clampedWind = min(max(magnitude, 0.0), 5.0)
        if clampedWind < 0.05 {
            return WindObservation(value: 0.0, direction: 1, hasWindFrame: true)
        }
        return WindObservation(value: clampedWind, direction: direction, hasWindFrame: true)
    }

    // MARK: - 3. Dual-Region Angle OCR (Battlefield + D-Pad Center, 10°...85°)

    public func detectDualAngle(from cgImage: CGImage) -> AngleObservation {
        let battlefield = detectBattlefieldAngle(from: cgImage, normalizedRect: GunnyROIs.angleBattlefield)
        let dpad = detectDPadAngle(from: cgImage, normalizedRect: GunnyROIs.angleDPad)
        return AngleObservation(battlefieldAngle: battlefield, dpadAngle: dpad)
    }

    public func detectBattlefieldAngle(
        from cgImage: CGImage,
        normalizedRect: NormalizedRect = GunnyROIs.angleBattlefield
    ) -> Double? {
        let roiPixel = normalizedRect.pixelRect(width: cgImage.width, height: cgImage.height)
        let cropW = Int(roiPixel.width)
        let cropH = Int(roiPixel.height)
        guard cropW >= 8, cropH >= 8,
              let cropped = cgImage.cropping(to: roiPixel) else {
            return nil
        }

        let (outW, outH) = clampedSize(width: cropW, height: cropH, maxDimension: Self.maxBattlefieldAngleDimension)
        guard let enhancedImage = makeContrastGrayImage(from: cropped, width: outW, height: outH) else {
            return nil
        }

        let candidates = performFastTextRecognition(on: enhancedImage, minimumTextHeight: 0.03)
        return Self.extractPriorityAngle(from: candidates)
    }

    public func detectDPadAngle(
        from cgImage: CGImage,
        normalizedRect: NormalizedRect = GunnyROIs.angleDPad
    ) -> Double? {
        let roiPixel = normalizedRect.pixelRect(width: cgImage.width, height: cgImage.height)
        let cropW = Int(roiPixel.width)
        let cropH = Int(roiPixel.height)
        guard cropW >= 6, cropH >= 6,
              let cropped = cgImage.cropping(to: roiPixel) else {
            return nil
        }

        let (outW, outH) = clampedSize(width: cropW * 2, height: cropH * 2, maxDimension: Self.maxDPadSampleDimension)
        guard let enhancedImage = makeContrastGrayImage(from: cropped, width: outW, height: outH) else {
            return nil
        }

        let candidates = performFastTextRecognition(on: enhancedImage, minimumTextHeight: 0.16)
        if let priority = Self.extractPriorityAngle(from: candidates) {
            return priority
        }
        return Self.extractCleanDPadNumber(from: candidates)
    }

    // MARK: - Text Parsing Helpers

    public static func extractPriorityAngle(from candidates: [String]) -> Double? {
        for raw in candidates {
            if let matched = parseAngleNearGocKeyword(raw), matched >= 10.0 && matched <= 85.0 {
                return matched
            }
        }
        for raw in candidates {
            if let matched = parseAngleBeforeDegreeSymbol(raw), matched >= 10.0 && matched <= 85.0 {
                return matched
            }
        }
        return nil
    }

    private static func extractCleanDPadNumber(from candidates: [String]) -> Double? {
        for raw in candidates {
            let trimmed = raw
                .replacingOccurrences(of: "°", with: "")
                .replacingOccurrences(of: "º", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmed.isEmpty, trimmed.count <= 4 else { continue }
            guard !trimmed.contains("/"), !trimmed.contains("%"), !trimmed.contains(":"), !trimmed.contains(",") else {
                continue
            }

            if let value = Double(trimmed), value >= 10.0 && value <= 85.0 {
                return value.rounded()
            }
        }
        return nil
    }

    private static func parseAngleNearGocKeyword(_ text: String) -> Double? {
        let folded = text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        guard let range = folded.range(of: "goc") else { return nil }

        let tail = String(folded[range.upperBound...])
        var token = ""
        var started = false
        for ch in tail {
            if !started {
                if ch == "-" || (ch.isASCII && ch.isNumber) {
                    started = true
                    token.append(ch)
                } else if ch == "°" || ch == "º" {
                    break
                }
            } else {
                if (ch.isASCII && ch.isNumber) || ch == "." {
                    token.append(ch)
                } else {
                    break
                }
            }
        }
        guard let value = Double(token), value >= 10.0 && value <= 85.0 else { return nil }
        return value
    }

    private static func parseAngleBeforeDegreeSymbol(_ text: String) -> Double? {
        let chars = Array(text)
        for (idx, ch) in chars.enumerated() where ch == "°" || ch == "º" {
            var digits = ""
            var i = idx - 1
            while i >= 0 && chars[i] == " " {
                i -= 1
            }
            while i >= 0 {
                let c = chars[i]
                if (c.isASCII && c.isNumber) || c == "." {
                    digits.insert(c, at: digits.startIndex)
                } else if c == "-" {
                    digits.insert(c, at: digits.startIndex)
                    break
                } else {
                    break
                }
                i -= 1
            }
            if let value = Double(digits), value >= 10.0 && value <= 85.0 {
                return value
            }
        }
        return nil
    }

    private static func parseFilteredNumber(from rawText: String) -> Double? {
        var filtered = ""
        filtered.reserveCapacity(rawText.count)
        for scalar in rawText.unicodeScalars where allowedNumericChars.contains(scalar) {
            filtered.unicodeScalars.append(scalar)
        }
        guard !filtered.isEmpty else { return nil }

        var token = ""
        var hasDecimal = false
        for ch in filtered {
            if (ch == "-" || ch == "+") && token.isEmpty {
                token.append(ch)
            } else if ch == "." && !hasDecimal {
                hasDecimal = true
                if token.isEmpty || token == "-" || token == "+" {
                    token.append("0")
                }
                token.append(ch)
            } else if ch.isASCII && ch.isNumber {
                token.append(ch)
            } else if !token.isEmpty {
                break
            }
        }
        return Double(token)
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

    private func performFastTextRecognition(on image: CGImage, minimumTextHeight: Float) -> [String] {
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
        guard let observations = request.results else { return [] }
        return observations.compactMap { $0.topCandidates(1).first?.string }
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
