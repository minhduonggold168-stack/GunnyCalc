import CoreGraphics
import CoreVideo
import Foundation
import Vision

// MARK: - Buffer Orientation & Zero-Copy Raw CVPixelBuffer Reader

/// Ba chiều bộ đệm màn hình hỗ trợ tự động khóa điểm neo `[X]` ở góc trên phải (`0.955, 0.025`).
public enum BufferOrientationMode: Int, CaseIterable, Equatable, Sendable {
    case landscapeDirect = 0
    case portraitLeft = 1
    case portraitRight = 2
}

/// Bộ đọc pixel không cấp phát (Zero-Copy) trực tiếp từ vùng nhớ `BGRA` (hoặc NV12) của `CVPixelBuffer` đã khóa `.readOnly`.
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
    public let layout: PixelLayout

    public init(bgraBase: UnsafePointer<UInt8>, rawWidth: Int, rawHeight: Int, bytesPerRow: Int) {
        self.rawWidth = rawWidth
        self.rawHeight = rawHeight
        self.layout = .bgra32(base: bgraBase, bytesPerRow: bytesPerRow)
    }

    /// Khởi tạo trực tiếp từ `CVPixelBuffer` đang được khóa `.readOnly`, không sao chép bộ nhớ toàn màn hình.
    public init?(lockedPixelBuffer pixelBuffer: CVPixelBuffer) {
        let rw = CVPixelBufferGetWidth(pixelBuffer)
        let rh = CVPixelBufferGetHeight(pixelBuffer)
        guard rw > 16, rh > 16 else { return nil }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if format == kCVPixelFormatType_32BGRA {
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
            guard bpr >= rw * 4 else { return nil }
            self.rawWidth = rw
            self.rawHeight = rh
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
            self.rawWidth = rw
            self.rawHeight = rh
            self.layout = .nv12(
                yBase: yPtr,
                yBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
                uvBase: uvPtr,
                uvBytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
                fullRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            )
            return
        }

        return nil
    }

    /// Chiều rộng & chiều cao logic khi màn hình xoay ngang theo từng chế độ ánh xạ.
    public func logicalDimensions(for mode: BufferOrientationMode) -> (width: Int, height: Int) {
        switch mode {
        case .landscapeDirect:
            return (rawWidth, rawHeight)
        case .portraitLeft, .portraitRight:
            return (rawHeight, rawWidth)
        }
    }

    /// Quy đổi tọa độ chuẩn hóa màn hình ngang `(normX: 0...1, normY: 0...1)` sang chỉ số pixel vật lý `(col, row)`.
    @inline(__always)
    public func physicalColRow(normX: Double, normY: Double, mode: BufferOrientationMode) -> (col: Int, row: Int) {
        let nx = min(max(normX, 0.0), 1.0)
        let ny = min(max(normY, 0.0), 1.0)
        let maxCol = Double(rawWidth - 1)
        let maxRow = Double(rawHeight - 1)

        let rawCol: Int
        let rawRow: Int
        switch mode {
        case .landscapeDirect:
            rawCol = Int((nx * maxCol).rounded())
            rawRow = Int((ny * maxRow).rounded())
        case .portraitLeft:
            rawCol = Int(((1.0 - ny) * maxCol).rounded())
            rawRow = Int((nx * maxRow).rounded())
        case .portraitRight:
            rawCol = Int((ny * maxCol).rounded())
            rawRow = Int(((1.0 - nx) * maxRow).rounded())
        }

        return (
            min(max(rawCol, 0), rawWidth - 1),
            min(max(rawRow, 0), rawHeight - 1)
        )
    }

    @inline(__always)
    public func readRGB(normX: Double, normY: Double, mode: BufferOrientationMode) -> (r: Int, g: Int, b: Int) {
        let (col, row) = physicalColRow(normX: normX, normY: normY, mode: mode)
        return readRGBPhysical(col: col, row: row)
    }

    @inline(__always)
    public func readLuma(normX: Double, normY: Double, mode: BufferOrientationMode) -> Int {
        let (col, row) = physicalColRow(normX: normX, normY: normY, mode: mode)
        return readLumaPhysical(col: col, row: row)
    }

    @inline(__always)
    private func readRGBPhysical(col: Int, row: Int) -> (r: Int, g: Int, b: Int) {
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

    @inline(__always)
    private func readLumaPhysical(col: Int, row: Int) -> Int {
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
}

// MARK: - Analysis Models & Angle Parser

public struct MainScreenHealthBarResult: Equatable, Sendable {
    /// Tọa độ chuẩn hóa toàn màn hình của người chơi (dùng cả cho Tầng 1 và neo cắt ô OCR 33 KB).
    public let playerScreenPos: CGPoint
    /// Tọa độ chuẩn hóa toàn màn hình của kẻ địch gần nhất (nếu nhìn thấy trên màn hình chính `< 10` đơn vị).
    public let enemyScreenPos: CGPoint?
    public let distanceUnits: Double?
    public let deltaYUnits: Double?
}

public struct MinimapAnalysisResult: Equatable, Sendable {
    public let playerPos: CGPoint?
    public let enemyPos: CGPoint?
    public let screenWidthNorm: Double?
}

/// Bộ tách góc bắn (`-35° ... 85°`) cho Gunny Mobi bằng regex chuẩn hóa, hỗ trợ cả góc âm lẫn lỗi OCR (`G6c`, `G0c`).
public enum AngleParser {
    private static let rawRegex = try? NSRegularExpression(
        pattern: #"(?:g[oóôòỏõọ06]c)?\s*(-?\d{1,2})\s*[°ºo]"#,
        options: [.caseInsensitive]
    )
    private static let rawLabelRegex = try? NSRegularExpression(
        pattern: #"(?:g[oóôòỏõọ06]c)\s*(?::|-\s+)?\s*(-?\d{1,2})"#,
        options: [.caseInsensitive]
    )
    private static let foldedLabelRegex = try? NSRegularExpression(
        pattern: #"(?:g[o06]c)\s*(?::|-\s+)?\s*(-?\d{1,2})"#,
        options: [.caseInsensitive]
    )

    public static func extractAngle(from texts: [String]) -> Int? {
        for raw in texts {
            if let regex = rawRegex,
               let value = extractFirstInt(using: regex, in: raw),
               value >= -35 && value <= 85 {
                return value
            }
            if let regex = rawLabelRegex,
               let value = extractFirstInt(using: regex, in: raw),
               value >= -35 && value <= 85 {
                return value
            }
            let folded = raw.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            if let regex = foldedLabelRegex,
               let value = extractFirstInt(using: regex, in: folded),
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

// MARK: - VisionProcessor (< 12 MB RAM, Zero Full-Screen Context)

/// Bộ xử lý thị giác hợp nhất 3 tầng trực tiếp trên byte thô `BGRA`:
/// - Tự khóa chiều xoay bằng nút đóng màu đỏ `[X]` tại `(0.955, 0.025)`.
/// - Cắt 1 `CGImage` xám siêu nhỏ `260 × 130` (~33 KB) ngay phía trên thanh máu xanh để chạy `VNRecognizeTextRequest` `.fast`.
/// - Tầng 1: Đo trực tiếp thanh máu xanh & đỏ trên màn hình chính (`< 10` đơn vị).
/// - Tầng 2: Đo qua Minimap (`0.848...0.996, 0.042...0.147`) với dải trời `screenWidthNorm` khóa chặt `0.46...0.76` (mặc định `0.65`).
public final class VisionProcessor {
    public static let defaultScreenWidthNorm: Double = 0.65
    private let grayColorSpace = CGColorSpaceCreateDeviceGray()

    public init() {}

    // MARK: - 1. Auto-Lock Buffer Orientation via Red [X] Button Anchor (0.955, 0.025)

    /// Kiểm tra điểm neo nút `[X]` đỏ (`R > 180, G < 70, B < 70`) quanh `(0.955, 0.025)` trên cả 3 chiều để xác định chiều chuẩn & trạng thái vào trận.
    public func detectBattleOrientation(
        in buffer: RawFrameBuffer,
        preferredMode: BufferOrientationMode?
    ) -> BufferOrientationMode? {
        let candidates: [BufferOrientationMode]
        if buffer.rawWidth >= buffer.rawHeight {
            candidates = [.landscapeDirect]
        } else if let preferred = preferredMode, preferred != .landscapeDirect {
            let other: BufferOrientationMode = (preferred == .portraitRight) ? .portraitLeft : .portraitRight
            candidates = [preferred, other]
        } else {
            candidates = [.portraitRight, .portraitLeft]
        }

        let center = GunnyROIs.redCloseButtonCenter
        let minX = Double(center.x) - 0.014
        let maxX = Double(center.x) + 0.016
        let minY = Double(center.y) - 0.012
        let maxY = Double(center.y) + 0.014

        for mode in candidates {
            var redHits = 0
            for gy in 0..<7 {
                let ny = minY + (maxY - minY) * (Double(gy) / 6.0)
                for gx in 0..<9 {
                    let nx = minX + (maxX - minX) * (Double(gx) / 8.0)
                    let (r, g, b) = buffer.readRGB(normX: nx, normY: ny, mode: mode)
                    if r > 180 && g < 70 && b < 70 {
                        redHits += 1
                        if redHits >= 6 {
                            return mode
                        }
                    }
                }
            }
        }
        return nil
    }

    // MARK: - 2. Tầng 1 & Định vị Thanh Máu Xanh Người Chơi (normX: 0.10...0.86, normY: 0.20...0.82)

    private struct RowRun {
        var xStart: Int
        var xEnd: Int
        var clusterId: Int
    }

    private struct RunCluster {
        var parent: Int
        var minX: Int
        var maxX: Int
        var minY: Int
        var maxY: Int
        var sumX: Double
        var sumY: Double
        var count: Int
    }

    private struct ScreenHealthBar {
        var fullX: Double
        var fullY: Double
        var normW: Double
        var score: Double
    }

    /// Quét nhanh vùng chiến trường chính tìm thanh máu xanh người chơi (`B > 190 && R < 75 && G < 125`)
    /// và thanh máu đỏ tươi địch gần nhất (`R > 200 && G < 60 && B < 60 && R - G > 140`).
    public func detectMainScreenHealthBars(
        in buffer: RawFrameBuffer,
        mode: BufferOrientationMode
    ) -> MainScreenHealthBarResult? {
        let dims = buffer.logicalDimensions(for: mode)
        let roi = GunnyROIs.mainBattlefield
        // Quét với bước nhảy ~2px chiều ngang (tối đa ~640 mẫu) và ~2px chiều dọc (~240 hàng) để đạt < 1.5ms.
        let sampleW = min(max(Int((Double(dims.width) * Double(roi.size.width)) / 2.0), 160), 640)
        let sampleH = min(max(Int((Double(dims.height) * Double(roi.size.height)) / 2.0), 90), 300)

        var blueClusters: [RunCluster] = []
        var redClusters: [RunCluster] = []
        blueClusters.reserveCapacity(12)
        redClusters.reserveCapacity(24)

        var prevBlueRuns: [RowRun] = []
        var currBlueRuns: [RowRun] = []
        var prevRedRuns: [RowRun] = []
        var currRedRuns: [RowRun] = []
        prevBlueRuns.reserveCapacity(12)
        currBlueRuns.reserveCapacity(12)
        prevRedRuns.reserveCapacity(24)
        currRedRuns.reserveCapacity(24)

        let roiX = Double(roi.origin.x)
        let roiY = Double(roi.origin.y)
        let roiW = Double(roi.size.width)
        let roiH = Double(roi.size.height)
        let invSampleW = 1.0 / Double(sampleW)
        let invSampleH = 1.0 / Double(sampleH)
        let minRunLen = max(2, Int((0.008 / roiW) * Double(sampleW)))

        for sy in 0..<sampleH {
            currBlueRuns.removeAll(keepingCapacity: true)
            currRedRuns.removeAll(keepingCapacity: true)
            let normY = roiY + (Double(sy) + 0.5) * invSampleH * roiH

            var sx = 0
            while sx < sampleW {
                let normX = roiX + (Double(sx) + 0.5) * invSampleW * roiW
                let (r, g, b) = buffer.readRGB(normX: normX, normY: normY, mode: mode)

                // Thanh máu xanh người chơi: B > 190 && R < 75 && G < 125
                if b > 190 && r < 75 && g < 125 {
                    let startX = sx
                    sx += 1
                    while sx < sampleW {
                        let nx = roiX + (Double(sx) + 0.5) * invSampleW * roiW
                        let (nr, ng, nb) = buffer.readRGB(normX: nx, normY: normY, mode: mode)
                        if nb > 190 && nr < 75 && ng < 125 {
                            sx += 1
                        } else {
                            break
                        }
                    }
                    if (sx - startX) >= minRunLen {
                        appendRun(
                            startX: startX,
                            endX: sx - 1,
                            y: sy,
                            prevRuns: prevBlueRuns,
                            currRuns: &currBlueRuns,
                            clusters: &blueClusters
                        )
                    }
                }
                // Thanh máu đỏ địch: R > 200 && G < 60 && B < 60 && (R - G) > 140
                else if r > 200 && g < 60 && b < 60 && (r - g) > 140 {
                    let startX = sx
                    sx += 1
                    while sx < sampleW {
                        let nx = roiX + (Double(sx) + 0.5) * invSampleW * roiW
                        let (nr, ng, nb) = buffer.readRGB(normX: nx, normY: normY, mode: mode)
                        if nr > 200 && ng < 60 && nb < 60 && (nr - ng) > 140 {
                            sx += 1
                        } else {
                            break
                        }
                    }
                    if (sx - startX) >= minRunLen {
                        appendRun(
                            startX: startX,
                            endX: sx - 1,
                            y: sy,
                            prevRuns: prevRedRuns,
                            currRuns: &currRedRuns,
                            clusters: &redClusters
                        )
                    }
                } else {
                    sx += 1
                }
            }

            swap(&prevBlueRuns, &currBlueRuns)
            swap(&prevRedRuns, &currRedRuns)
        }

        let blueBars = extractScreenBars(
            from: &blueClusters,
            sampleW: sampleW,
            sampleH: sampleH,
            roi: roi,
            minNormW: 0.020,
            maxNormW: 0.060
        )
        guard let playerBar = blueBars.max(by: { $0.score < $1.score }) else {
            return nil
        }

        let playerPos = CGPoint(x: playerBar.fullX, y: playerBar.fullY)
        let redBars = extractScreenBars(
            from: &redClusters,
            sampleW: sampleW,
            sampleH: sampleH,
            roi: roi,
            minNormW: 0.022,
            maxNormW: 0.065
        )

        let validEnemies = redBars.filter { abs($0.fullX - playerBar.fullX) > 0.04 }
        guard let nearestEnemy = validEnemies.min(by: { lhs, rhs in
            let dL = hypot((lhs.fullX - playerBar.fullX) * 10.0, (lhs.fullY - playerBar.fullY) * 6.0)
            let dR = hypot((rhs.fullX - playerBar.fullX) * 10.0, (rhs.fullY - playerBar.fullY) * 6.0)
            return dL < dR
        }) else {
            return MainScreenHealthBarResult(
                playerScreenPos: playerPos,
                enemyScreenPos: nil,
                distanceUnits: nil,
                deltaYUnits: nil
            )
        }

        let enemyPos = CGPoint(x: nearestEnemy.fullX, y: nearestEnemy.fullY)
        let distanceUnits = abs(nearestEnemy.fullX - playerBar.fullX) * BallisticsEngine.unitsPerScreen
        let deltaYUnits = (playerBar.fullY - nearestEnemy.fullY) * 6.0

        return MainScreenHealthBarResult(
            playerScreenPos: playerPos,
            enemyScreenPos: enemyPos,
            distanceUnits: distanceUnits,
            deltaYUnits: deltaYUnits
        )
    }

    private func findClusterRoot(_ clusters: inout [RunCluster], _ idx: Int) -> Int {
        var root = idx
        while clusters[root].parent != root {
            root = clusters[root].parent
        }
        var curr = idx
        while clusters[curr].parent != root {
            let next = clusters[curr].parent
            clusters[curr].parent = root
            curr = next
        }
        return root
    }

    private func unionClusters(_ clusters: inout [RunCluster], _ a: Int, _ b: Int) -> Int {
        let rootA = findClusterRoot(&clusters, a)
        let rootB = findClusterRoot(&clusters, b)
        if rootA == rootB { return rootA }

        clusters[rootB].parent = rootA
        if clusters[rootB].minX < clusters[rootA].minX { clusters[rootA].minX = clusters[rootB].minX }
        if clusters[rootB].maxX > clusters[rootA].maxX { clusters[rootA].maxX = clusters[rootB].maxX }
        if clusters[rootB].minY < clusters[rootA].minY { clusters[rootA].minY = clusters[rootB].minY }
        if clusters[rootB].maxY > clusters[rootA].maxY { clusters[rootA].maxY = clusters[rootB].maxY }
        clusters[rootA].sumX += clusters[rootB].sumX
        clusters[rootA].sumY += clusters[rootB].sumY
        clusters[rootA].count += clusters[rootB].count
        return rootA
    }

    private func appendRun(
        startX: Int,
        endX: Int,
        y: Int,
        prevRuns: [RowRun],
        currRuns: inout [RowRun],
        clusters: inout [RunCluster]
    ) {
        let runLen = endX - startX + 1
        let runSumX = Double(startX + endX) * 0.5 * Double(runLen)
        let runSumY = Double(y) * Double(runLen)

        var mergedId = -1
        for prev in prevRuns {
            if prev.xEnd < startX - 1 { continue }
            if prev.xStart > endX + 1 { break }
            let pr = findClusterRoot(&clusters, prev.clusterId)
            mergedId = (mergedId < 0) ? pr : unionClusters(&clusters, mergedId, pr)
        }

        if mergedId < 0 {
            let newId = clusters.count
            clusters.append(
                RunCluster(
                    parent: newId,
                    minX: startX,
                    maxX: endX,
                    minY: y,
                    maxY: y,
                    sumX: runSumX,
                    sumY: runSumY,
                    count: runLen
                )
            )
            mergedId = newId
        } else {
            if startX < clusters[mergedId].minX { clusters[mergedId].minX = startX }
            if endX > clusters[mergedId].maxX { clusters[mergedId].maxX = endX }
            if y < clusters[mergedId].minY { clusters[mergedId].minY = y }
            if y > clusters[mergedId].maxY { clusters[mergedId].maxY = y }
            clusters[mergedId].sumX += runSumX
            clusters[mergedId].sumY += runSumY
            clusters[mergedId].count += runLen
        }

        currRuns.append(RowRun(xStart: startX, xEnd: endX, clusterId: mergedId))
    }

    private func extractScreenBars(
        from clusters: inout [RunCluster],
        sampleW: Int,
        sampleH: Int,
        roi: CGRect,
        minNormW: Double,
        maxNormW: Double
    ) -> [ScreenHealthBar] {
        var result: [ScreenHealthBar] = []
        let rectX = Double(roi.origin.x)
        let rectY = Double(roi.origin.y)
        let rectW = Double(roi.size.width)
        let rectH = Double(roi.size.height)

        for idx in 0..<clusters.count {
            guard clusters[idx].parent == idx else { continue }
            let c = clusters[idx]
            let bw = c.maxX - c.minX + 1
            let bh = c.maxY - c.minY + 1
            guard bw >= 3, bh >= 2, c.count >= 6 else { continue }

            let normW = (Double(bw) / Double(sampleW)) * rectW
            let normH = (Double(bh) / Double(sampleH)) * rectH
            guard normW >= minNormW && normW <= maxNormW,
                  normH >= 0.004 && normH <= 0.022,
                  normW > normH * 1.4 else {
                continue
            }

            let fillRatio = Double(c.count) / Double(bw * bh)
            guard fillRatio >= 0.42 else { continue }

            let cx = c.sumX / Double(c.count)
            let cy = c.sumY / Double(c.count)
            let fullX = rectX + ((cx + 0.5) / Double(sampleW)) * rectW
            let fullY = rectY + ((cy + 0.5) / Double(sampleH)) * rectH

            result.append(
                ScreenHealthBar(
                    fullX: min(max(fullX, 0.0), 1.0),
                    fullY: min(max(fullY, 0.0), 1.0),
                    normW: normW,
                    score: fillRatio * Double(c.count)
                )
            )
        }
        return result
    }

    // MARK: - 3. Tiny 260 x 130 Grayscale CGImage (~33 KB) + Fast Angle OCR (60ms)

    /// Trích xuất 1 `CGImage` thang độ xám siêu nhẹ `260 x 130` px (~33 KB, đọc trực tiếp byte thô) ngay phía trên thanh máu xanh
    /// (hoặc vùng mặc định `normX: 0.12...0.65, normY: 0.18...0.56` nếu chưa thấy thanh máu).
    public func makeTinyGrayscaleAngleImage(
        from buffer: RawFrameBuffer,
        mode: BufferOrientationMode,
        playerScreenPos: CGPoint?
    ) -> CGImage? {
        let outW = 260
        let outH = 130

        let roi: CGRect
        if let player = playerScreenPos {
            let x = min(max(Double(player.x) - 0.12, 0.02), 0.72)
            let y = min(max(Double(player.y) - 0.22, 0.06), 0.64)
            roi = CGRect(x: x, y: y, width: 0.24, height: 0.20)
        } else {
            roi = GunnyROIs.defaultAngleFallback
        }

        var grayBytes = [UInt8](repeating: 0, count: outW * outH)
        let x0 = Double(roi.origin.x)
        let y0 = Double(roi.origin.y)
        let rw = Double(roi.size.width)
        let rh = Double(roi.size.height)
        let invW = 1.0 / Double(max(outW - 1, 1))
        let invH = 1.0 / Double(max(outH - 1, 1))

        for y in 0..<outH {
            let normY = y0 + (Double(y) * invH) * rh
            let rowBase = y * outW
            for x in 0..<outW {
                let normX = x0 + (Double(x) * invW) * rw
                let lum = buffer.readLuma(normX: normX, normY: normY, mode: mode)
                // Tăng tương phản tuyến tính nhẹ quanh ngưỡng trung tâm để chữ góc trắng/vàng tách rõ khỏi nền.
                let boosted = ((lum - 128) * 16) / 10 + 128
                grayBytes[rowBase + x] = UInt8(min(max(boosted, 0), 255))
            }
        }

        let data = Data(grayBytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: outW,
            space: grayColorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Chạy `VNRecognizeTextRequest` (`.fast`, `usesLanguageCorrection = false`) trên ô ảnh 33 KB để đọc góc `-35° ... 85°`.
    public func detectAngleFast(fromGrayscaleImage grayImage: CGImage) -> Int? {
        guard grayImage.width >= 16, grayImage.height >= 16 else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["vi-VN", "en-US"]

        let handler = VNImageRequestHandler(cgImage: grayImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else { return nil }
        var texts: [String] = []
        texts.reserveCapacity(observations.count * 2)
        for obs in observations {
            for candidate in obs.topCandidates(2) {
                texts.append(candidate.string)
            }
        }
        return AngleParser.extractAngle(from: texts)
    }

    // MARK: - 4. Tầng 2: Minimap Markers (groundY) & Upper Sky Camera Width (0.46 ... 0.76)

    private struct MinimapCluster {
        var centerX: Double
        var centerY: Double
        var maxY: Int
        var count: Int
        var bboxW: Int
        var bboxH: Int
    }

    /// Quét Minimap (`normX: 0.848...0.996, normY: 0.042...0.147`) trực tiếp từ byte thô.
    /// Đo `screenWidthNorm` trên dải trời nửa trên Minimap (`y: 0.05...0.40`), khóa trong dải `0.46 ... 0.76`.
    public func analyzeMinimap(
        in buffer: RawFrameBuffer,
        mode: BufferOrientationMode,
        fallbackPlayerPos: CGPoint?,
        previousEnemyPos: CGPoint?
    ) -> MinimapAnalysisResult? {
        let dims = buffer.logicalDimensions(for: mode)
        let roi = GunnyROIs.minimapStrip
        let outW = min(max(Int((Double(dims.width) * Double(roi.size.width)).rounded()), 140), 320)
        let outH = min(max(Int((Double(dims.height) * Double(roi.size.height)).rounded()), 64), 160)
        guard outW >= 24, outH >= 12 else { return nil }

        let pixelCount = outW * outH
        var blueMask = [UInt8](repeating: 0, count: pixelCount)
        var redMask = [UInt8](repeating: 0, count: pixelCount)
        var lumaGrid = [Double](repeating: 0.0, count: pixelCount)

        let roiX = Double(roi.origin.x)
        let roiY = Double(roi.origin.y)
        let roiW = Double(roi.size.width)
        let roiH = Double(roi.size.height)
        let invW = 1.0 / Double(outW)
        let invH = 1.0 / Double(outH)

        for y in 0..<outH {
            let normY = roiY + (Double(y) + 0.5) * invH * roiH
            let rowBase = y * outW
            for x in 0..<outW {
                let normX = roiX + (Double(x) + 0.5) * invW * roiW
                let (r, g, b) = buffer.readRGB(normX: normX, normY: normY, mode: mode)
                let idx = rowBase + x
                lumaGrid[idx] = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)

                // Người chơi (xanh dương thuần): B > 180 && R < 85 && G < 135 && (B - R) > 115
                if b > 180 && r < 85 && g < 135 && (b - r) > 115 {
                    blueMask[idx] = 1
                }
                // Mục tiêu (đỏ tươi thuần): R > 190 && G < 60 && B < 60 && (R - G) > 135 && (R - B) > 135
                else if r > 190 && g < 60 && b < 60 && (r - g) > 135 && (r - b) > 135 {
                    redMask[idx] = 1
                }
            }
        }

        let playerPos = detectBluePlayer(mask: blueMask, width: outW, height: outH)
        let refPlayer = playerPos ?? fallbackPlayerPos
        let enemyPos = detectNearestRedEnemy(
            mask: redMask,
            width: outW,
            height: outH,
            referencePlayer: refPlayer,
            previousEnemy: previousEnemyPos
        )

        let measuredWidth = detectSkyBandCameraWidthNorm(
            lumaGrid: lumaGrid,
            blueMask: blueMask,
            redMask: redMask,
            width: outW,
            height: outH,
            playerX: refPlayer.map { Double($0.x) }
        )

        return MinimapAnalysisResult(
            playerPos: playerPos,
            enemyPos: enemyPos,
            screenWidthNorm: measuredWidth
        )
    }

    private func extract8ConnectedClusters(
        from mask: [UInt8],
        width: Int,
        height: Int,
        minPixels: Int,
        maxBBoxWidthRatio: Double,
        maxBBoxHeightRatio: Double
    ) -> [MinimapCluster] {
        var visited = [UInt8](repeating: 0, count: width * height)
        var clusters: [MinimapCluster] = []
        let maxBBoxW = max(6, Int(Double(width) * maxBBoxWidthRatio))
        let maxBBoxH = max(6, Int(Double(height) * maxBBoxHeightRatio))

        var qx: [Int] = []
        var qy: [Int] = []
        qx.reserveCapacity(48)
        qy.reserveCapacity(48)

        for startY in 0..<height {
            for startX in 0..<width {
                let startIdx = startY * width + startX
                guard mask[startIdx] != 0, visited[startIdx] == 0 else { continue }

                visited[startIdx] = 1
                qx.removeAll(keepingCapacity: true)
                qy.removeAll(keepingCapacity: true)
                qx.append(startX)
                qy.append(startY)

                var head = 0
                var sumX = 0.0
                var sumY = 0.0
                var count = 0
                var minX = startX
                var maxX = startX
                var minY = startY
                var maxY = startY

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
                        let rowBase = ny * width
                        for nx in xFrom...xTo {
                            if nx == cx && ny == cy { continue }
                            let ni = rowBase + nx
                            if mask[ni] != 0 && visited[ni] == 0 {
                                visited[ni] = 1
                                qx.append(nx)
                                qy.append(ny)
                            }
                        }
                    }
                }

                let bboxW = maxX - minX + 1
                let bboxH = maxY - minY + 1
                guard count >= minPixels, bboxW <= maxBBoxW, bboxH <= maxBBoxH else { continue }

                clusters.append(
                    MinimapCluster(
                        centerX: sumX / Double(count),
                        centerY: sumY / Double(count),
                        maxY: maxY,
                        count: count,
                        bboxW: bboxW,
                        bboxH: bboxH
                    )
                )
            }
        }
        return clusters
    }

    private func detectBluePlayer(mask: [UInt8], width: Int, height: Int) -> CGPoint? {
        let clusters = extract8ConnectedClusters(
            from: mask,
            width: width,
            height: height,
            minPixels: 2,
            maxBBoxWidthRatio: 0.20,
            maxBBoxHeightRatio: 0.45
        )
        guard let best = clusters.max(by: { $0.count < $1.count }) else { return nil }
        return CGPoint(
            x: min(max((best.centerX + 0.5) / Double(width), 0.0), 1.0),
            y: min(max((Double(best.maxY) + 0.5) / Double(height), 0.0), 1.0)
        )
    }

    private func detectNearestRedEnemy(
        mask: [UInt8],
        width: Int,
        height: Int,
        referencePlayer: CGPoint?,
        previousEnemy: CGPoint?
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

        let mergeDistPx = max(3.0, Double(width) * 0.018)
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

        var points = merged.map {
            CGPoint(
                x: min(max(($0.centerX + 0.5) / Double(width), 0.0), 1.0),
                y: min(max((Double($0.maxY) + 0.5) / Double(height), 0.0), 1.0)
            )
        }

        if let player = referencePlayer {
            points = points.filter { hypot(Double($0.x - player.x), Double($0.y - player.y)) >= 0.025 }
            guard !points.isEmpty else { return nil }

            points.sort { lhs, rhs in
                let dL = abs(Double(lhs.x - player.x))
                let dR = abs(Double(rhs.x - player.x))
                if abs(dL - dR) > 0.005 { return dL < dR }
                return hypot(Double(lhs.x - player.x), Double(lhs.y - player.y))
                    < hypot(Double(rhs.x - player.x), Double(rhs.y - player.y))
            }

            if let prev = previousEnemy, let closest = points.first {
                let closestDist = abs(Double(closest.x - player.x))
                if let sticky = points.first(where: { cand in
                    hypot(Double(cand.x - prev.x), Double(cand.y - prev.y)) <= 0.04
                        && abs(Double(cand.x - player.x)) <= closestDist + 0.02
                }) {
                    return sticky
                }
            }
        }

        return points.first
    }

    /// Đo chiều rộng khung camera trắng `screenWidthNorm` trên dải trời nửa trên Minimap (`y: 0.05...0.40` của Minimap)
    /// để tránh hoàn toàn địa hình đá/cỏ; khóa chặt trong dải vật lý `0.46 ... 0.76`.
    private func detectSkyBandCameraWidthNorm(
        lumaGrid: [Double],
        blueMask: [UInt8],
        redMask: [UInt8],
        width: Int,
        height: Int,
        playerX: Double?
    ) -> Double? {
        let yStart = min(max(Int((Double(height) * 0.05).rounded()), 0), max(height - 3, 0))
        let yEnd = min(max(Int((Double(height) * 0.40).rounded()), yStart + 3), height)
        let skyRows = Double(yEnd - yStart)
        guard width >= 24, skyRows >= 3.0 else { return nil }

        // 1. Ưu tiên dò 2 cạnh đứng khung camera trắng trên dải trời (y: 0.05...0.40).
        var leftRatio = [Double](repeating: 0.0, count: width)
        var rightRatio = [Double](repeating: 0.0, count: width)
        var colMean = [Double](repeating: 0.0, count: width)

        for x in 0..<width {
            var sum = 0.0
            var samples = 0
            for y in yStart..<yEnd {
                let idx = y * width + x
                if blueMask[idx] != 0 || redMask[idx] != 0 { continue }
                sum += lumaGrid[idx]
                samples += 1
            }
            colMean[x] = samples > 0 ? (sum / Double(samples)) : 0.0
        }

        for col in 1..<(width - 1) {
            var lHits = 0
            var rHits = 0
            for y in yStart..<yEnd {
                let idx = y * width + col
                let cur = lumaGrid[idx]
                if cur - lumaGrid[idx - 1] >= 10.0 { lHits += 1 }
                if cur - lumaGrid[idx + 1] >= 10.0 { rHits += 1 }
            }
            leftRatio[col] = Double(lHits) / skyRows
            rightRatio[col] = Double(rHits) / skyRows
        }

        let leftCols = extractPeakCols(ratios: leftRatio, minRatio: 0.55)
        let rightCols = extractPeakCols(ratios: rightRatio, minRatio: 0.55)

        var bestBorderWidth: Double?
        var bestBorderScore = -1.0
        for lc in leftCols {
            for rc in rightCols where rc > lc + 8 {
                let bl = Double(lc) / Double(width)
                let br = Double(rc) / Double(width)
                let span = br - bl
                guard span >= 0.46 && span <= 0.76 else { continue }
                if let px = playerX, px < bl - 0.02 || px > br + 0.02 { continue }
                let score = leftRatio[lc] + rightRatio[rc]
                if score > bestBorderScore {
                    bestBorderScore = score
                    bestBorderWidth = span
                }
            }
        }
        if let validBorder = bestBorderWidth {
            return validBorder
        }

        // 2. Dự phòng: dò khoảng trời sáng hơn nền ngoài >= 15% trong dải y: 0.05...0.40.
        var smooth = [Double](repeating: 0.0, count: width)
        for x in 0..<width {
            let l = colMean[max(0, x - 1)]
            let c = colMean[x]
            let r = colMean[min(width - 1, x + 1)]
            smooth[x] = (l + c + r) / 3.0
        }

        let sorted = smooth.sorted()
        let darkCount = max(4, Int(Double(width) * 0.14))
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
        guard insideMean >= max(outsideMean * 1.15, outsideMean + 4.0) else { return nil }

        let midThreshold = (insideMean + outsideMean) * 0.5
        var refinedStart = bestStart
        var refinedEnd = bestEnd
        while refinedStart < refinedEnd && colMean[refinedStart] < midThreshold {
            refinedStart += 1
        }
        while refinedEnd > refinedStart && colMean[refinedEnd] < midThreshold {
            refinedEnd -= 1
        }

        let spanStart = Double(refinedStart) / Double(width)
        let spanEnd = Double(refinedEnd + 1) / Double(width)
        let span = spanEnd - spanStart
        guard span >= 0.46 && span <= 0.76 else { return nil }
        if let px = playerX, px < spanStart - 0.02 || px > spanEnd + 0.02 { return nil }
        return span
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
}
