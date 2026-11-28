import CoreGraphics
import Foundation
import Vision

/// Tầng đo cự ly đang cung cấp kết quả cho khung hình hiện tại.
public enum DistanceMeasurementTier: String, Equatable, Sendable {
    case tier1MainScreenHealthBars = "tier1_healthbars"
    case tier2MinimapCameraBorder = "tier2_camera_border"
    case tier3MinimapYellowRuler = "tier3_yellow_ruler"
    case fallbackCachedScale = "fallback_cached_scale"
}

/// Kết quả Tầng 1: đo trực tiếp thanh máu người chơi (xanh) và kẻ địch (đỏ) trên màn hình chính (< 10 đơn vị).
public struct MainScreenHealthBarResult: Equatable, Sendable {
    /// Tọa độ chuẩn hóa toàn màn hình Top-Left (`0.0 ... 1.0`) của thanh máu xanh người chơi.
    public let playerPos: CGPoint
    /// Tọa độ chuẩn hóa toàn màn hình Top-Left (`0.0 ... 1.0`) của thanh máu đỏ kẻ địch gần nhất.
    public let enemyPos: CGPoint
    /// Cự ly trực tiếp = `abs(enemy.x - player.x) * 10.0`.
    public let distanceUnits: Double
    /// Độ chênh cao trực tiếp = `(player.y - enemy.y) * 6.2`.
    public let deltaYUnits: Double
}

/// Kết quả Tầng 2 + Tầng 3 trên Minimap gồm tọa độ `(centerX, groundY)`, số quái và tỷ lệ khung camera `10.0` đơn vị.
public struct MinimapAnalysisResult: Equatable, Sendable {
    public let playerPos: CGPoint?
    public let enemyPos: CGPoint?
    public let enemyCount: Int
    public let tier2CameraWidthNorm: Double?
    public let tier3RulerWidthNorm: Double?
    public let screenWidthNorm: Double?
    public let scaleSource: DistanceMeasurementTier
}

/// Kết quả hợp nhất 3 tầng (Multi-Cue Fusion) cho một khung hình chiến đấu.
public struct MultiCueFusionResult: Equatable, Sendable {
    public let tier: DistanceMeasurementTier
    public let distanceUnits: Double
    public let deltaYUnits: Double
    public let screenWidthNorm: Double
    public let mainScreenResult: MainScreenHealthBarResult?
    public let minimapResult: MinimapAnalysisResult?
}

/// Bộ tách góc bắn 2 tầng regex cho Gunny Mobi (`-35 ... 85`), hỗ trợ góc âm và lỗi OCR (`G6c`, `G0c`, thiếu chữ `Góc`).
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

/// Bộ xử lý thị giác máy tính hợp nhất 3 tầng siêu nhẹ (< 25MB RAM, < 35ms/khung hình):
/// - **Tầng 1 (Ưu tiên cao nhất):** Quét thanh máu xanh người chơi và thanh máu đỏ địch trực tiếp trên màn hình chính (`< 10` đơn vị).
/// - **Tầng 2:** Quét Minimap tìm tâm X + đáy chân `groundY` và dò đường viền đứng khung camera trắng (`>= 55%` chiều cao, `0.42...0.86`).
/// - **Tầng 3:** Đối chiếu bước vạch `5.0` đơn vị tối màu trên thước vàng đáy Minimap (`clamp(tickSpacing * 2.0, 0.44, 0.85)`, mặc định `0.62`).
public final class VisionProcessor {
    public static let defaultScreenWidthNorm: Double = 0.62
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()

    public init() {}

    // MARK: - Tầng 1: Main Screen Health Bar Detection (< 10 Units)

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

    private struct HealthBarBox {
        var fullX: Double
        var fullY: Double
        var normW: Double
        var normH: Double
        var count: Int
        var fillRatio: Double
    }

    /// Tầng 1: Quét vùng chiến trường chính tìm thanh máu xanh người chơi và thanh máu đỏ địch gần nhất.
    /// Sử dụng gom đoạn ngang (Row-Wise RLE Union-Find) không cấp phát mảng mask kích thước lớn nên đạt tốc độ ~1-3ms.
    public func detectMainScreenHealthBars(
        battlefieldCrop: CGImage,
        normRect: CGRect = GunnyROIs.mainBattlefield
    ) -> MainScreenHealthBarResult? {
        return withRGBA8Pixels(of: battlefieldCrop) { rgbaPtr, bytesPerRow, outW, outH -> MainScreenHealthBarResult? in
            guard outW >= 32, outH >= 16 else { return nil }

            var blueClusters: [RunCluster] = []
            var redClusters: [RunCluster] = []
            blueClusters.reserveCapacity(16)
            redClusters.reserveCapacity(32)

            var prevBlueRuns: [RowRun] = []
            var currBlueRuns: [RowRun] = []
            var prevRedRuns: [RowRun] = []
            var currRedRuns: [RowRun] = []
            prevBlueRuns.reserveCapacity(16)
            currBlueRuns.reserveCapacity(16)
            prevRedRuns.reserveCapacity(32)
            currRedRuns.reserveCapacity(32)

            let minRunLen = max(2, Int((0.008 / max(Double(normRect.size.width), 0.1)) * Double(outW)))

            for y in 0..<outH {
                currBlueRuns.removeAll(keepingCapacity: true)
                currRedRuns.removeAll(keepingCapacity: true)
                let rowPtr = rgbaPtr.advanced(by: y * bytesPerRow)

                var x = 0
                while x < outW {
                    let px = x * 4
                    let r = Int(rowPtr[px])
                    let g = Int(rowPtr[px + 1])
                    let b = Int(rowPtr[px + 2])

                    // Thanh máu xanh người chơi: B > 195 && R < 70 && G < 120
                    if b > 195 && r < 70 && g < 120 {
                        let startX = x
                        x += 1
                        while x < outW {
                            let npx = x * 4
                            let nr = Int(rowPtr[npx])
                            let ng = Int(rowPtr[npx + 1])
                            let nb = Int(rowPtr[npx + 2])
                            if nb > 195 && nr < 70 && ng < 120 {
                                x += 1
                            } else {
                                break
                            }
                        }
                        let endX = x - 1
                        if (endX - startX + 1) >= minRunLen {
                            appendRun(
                                startX: startX,
                                endX: endX,
                                y: y,
                                prevRuns: prevBlueRuns,
                                currRuns: &currBlueRuns,
                                clusters: &blueClusters
                            )
                        }
                    }
                    // Thanh máu đỏ kẻ địch: R > 205 && G < 60 && B < 60
                    else if r > 205 && g < 60 && b < 60 {
                        let startX = x
                        x += 1
                        while x < outW {
                            let npx = x * 4
                            let nr = Int(rowPtr[npx])
                            let ng = Int(rowPtr[npx + 1])
                            let nb = Int(rowPtr[npx + 2])
                            if nr > 205 && ng < 60 && nb < 60 {
                                x += 1
                            } else {
                                break
                            }
                        }
                        let endX = x - 1
                        if (endX - startX + 1) >= minRunLen {
                            appendRun(
                                startX: startX,
                                endX: endX,
                                y: y,
                                prevRuns: prevRedRuns,
                                currRuns: &currRedRuns,
                                clusters: &redClusters
                            )
                        }
                    } else {
                        x += 1
                    }
                }

                swap(&prevBlueRuns, &currBlueRuns)
                swap(&prevRedRuns, &currRedRuns)
            }

            let tolW = Double(normRect.size.width) / Double(outW)
            let tolH = Double(normRect.size.height) / Double(outH)

            let blueBars = extractHealthBars(
                from: &blueClusters,
                cropWidth: outW,
                cropHeight: outH,
                normRect: normRect,
                minNormW: 0.025 - tolW,
                maxNormW: 0.055 + tolW,
                minNormH: 0.006 - tolH,
                maxNormH: 0.016 + tolH
            )
            guard let playerBar = blueBars.max(by: { ($0.fillRatio * Double($0.count)) < ($1.fillRatio * Double($1.count)) }) else {
                return nil
            }

            let redBars = extractHealthBars(
                from: &redClusters,
                cropWidth: outW,
                cropHeight: outH,
                normRect: normRect,
                minNormW: 0.025 - tolW,
                maxNormW: 0.065 + tolW,
                minNormH: 0.006 - tolH,
                maxNormH: 0.016 + tolH
            )

            // Chỉ nhận mục tiêu cách người chơi > 0.04 chiều rộng màn hình và chọn cụm gần nhất.
            let validEnemies = redBars.filter { abs($0.fullX - playerBar.fullX) > 0.04 }
            guard let nearestEnemy = validEnemies.min(by: { lhs, rhs in
                let dL = hypot((lhs.fullX - playerBar.fullX) * 10.0, (lhs.fullY - playerBar.fullY) * 6.2)
                let dR = hypot((rhs.fullX - playerBar.fullX) * 10.0, (rhs.fullY - playerBar.fullY) * 6.2)
                return dL < dR
            }) else {
                return nil
            }

            let distanceUnits = abs(nearestEnemy.fullX - playerBar.fullX) * BallisticsEngine.unitsPerScreen
            let deltaYUnits = (playerBar.fullY - nearestEnemy.fullY) * 6.2

            return MainScreenHealthBarResult(
                playerPos: CGPoint(x: playerBar.fullX, y: playerBar.fullY),
                enemyPos: CGPoint(x: nearestEnemy.fullX, y: nearestEnemy.fullY),
                distanceUnits: distanceUnits,
                deltaYUnits: deltaYUnits
            )
        }
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

        var mergedClusterId = -1
        for prev in prevRuns {
            if prev.xEnd < startX - 1 { continue }
            if prev.xStart > endX + 1 { break }
            let prevRoot = findClusterRoot(&clusters, prev.clusterId)
            if mergedClusterId < 0 {
                mergedClusterId = prevRoot
            } else {
                mergedClusterId = unionClusters(&clusters, mergedClusterId, prevRoot)
            }
        }

        if mergedClusterId < 0 {
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
            mergedClusterId = newId
        } else {
            if startX < clusters[mergedClusterId].minX { clusters[mergedClusterId].minX = startX }
            if endX > clusters[mergedClusterId].maxX { clusters[mergedClusterId].maxX = endX }
            if y < clusters[mergedClusterId].minY { clusters[mergedClusterId].minY = y }
            if y > clusters[mergedClusterId].maxY { clusters[mergedClusterId].maxY = y }
            clusters[mergedClusterId].sumX += runSumX
            clusters[mergedClusterId].sumY += runSumY
            clusters[mergedClusterId].count += runLen
        }

        currRuns.append(RowRun(xStart: startX, xEnd: endX, clusterId: mergedClusterId))
    }

    private func extractHealthBars(
        from clusters: inout [RunCluster],
        cropWidth: Int,
        cropHeight: Int,
        normRect: CGRect,
        minNormW: Double,
        maxNormW: Double,
        minNormH: Double,
        maxNormH: Double
    ) -> [HealthBarBox] {
        var result: [HealthBarBox] = []
        let rectX = Double(normRect.origin.x)
        let rectY = Double(normRect.origin.y)
        let rectW = Double(normRect.size.width)
        let rectH = Double(normRect.size.height)

        for idx in 0..<clusters.count {
            guard clusters[idx].parent == idx else { continue }
            let comp = clusters[idx]
            let bboxW = comp.maxX - comp.minX + 1
            let bboxH = comp.maxY - comp.minY + 1
            guard bboxW >= 3, bboxH >= 2, comp.count >= 6 else { continue }

            let normW = (Double(bboxW) / Double(cropWidth)) * rectW
            let normH = (Double(bboxH) / Double(cropHeight)) * rectH
            guard normW >= minNormW, normW <= maxNormW, normH >= minNormH, normH <= maxNormH else {
                continue
            }

            let fillRatio = Double(comp.count) / Double(bboxW * bboxH)
            guard fillRatio >= 0.45, normW > normH * 1.4 else { continue }

            let centerX = comp.sumX / Double(comp.count)
            let centerY = comp.sumY / Double(comp.count)
            let fullX = rectX + ((centerX + 0.5) / Double(cropWidth)) * rectW
            let fullY = rectY + ((centerY + 0.5) / Double(cropHeight)) * rectH

            result.append(
                HealthBarBox(
                    fullX: min(max(fullX, 0.0), 1.0),
                    fullY: min(max(fullY, 0.0), 1.0),
                    normW: normW,
                    normH: normH,
                    count: comp.count,
                    fillRatio: fillRatio
                )
            )
        }
        return result
    }

    // MARK: - Tầng 2 + Tầng 3: Minimap Markers (groundY), Vertical Camera Border & Yellow Ruler

    /// Phân tích Minimap (`normRect = (0.848, 0.042, 0.148, 0.106)`) và dải thước vàng đáy Minimap (`0.848, 0.148, 0.148, 0.015`).
    public func analyzeMinimap(
        minimapCrop: CGImage,
        yellowRulerCrop: CGImage? = nil,
        fallbackPlayerPos: CGPoint? = nil,
        previousEnemyPos: CGPoint? = nil
    ) -> MinimapAnalysisResult? {
        return withRGBA8Pixels(of: minimapCrop) { rgbaPtr, bytesPerRow, outW, outH -> MinimapAnalysisResult? in
            guard outW >= 8, outH >= 6 else { return nil }

            let pixelCount = outW * outH
            var blueMask = [Bool](repeating: false, count: pixelCount)
            var redMask = [Bool](repeating: false, count: pixelCount)
            var lumaGrid = [Double](repeating: 0.0, count: pixelCount)

            for y in 0..<outH {
                let rowPtr = rgbaPtr.advanced(by: y * bytesPerRow)
                let rowBase = y * outW
                for x in 0..<outW {
                    let px = x * 4
                    let r = Int(rowPtr[px])
                    let g = Int(rowPtr[px + 1])
                    let b = Int(rowPtr[px + 2])
                    let idx = rowBase + x

                    lumaGrid[idx] = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)

                    // Người chơi (xanh dương thuần): B > 185 && R < 85 && G < 140 && (B - R) > 120
                    if b > 185 && r < 85 && g < 140 && (b - r) > 120 {
                        blueMask[idx] = true
                    }
                    // Mục tiêu (đỏ tươi thuần): R > 190 && G < 65 && B < 65 && (R - G) > 135 && (R - B) > 135
                    else if r > 190 && g < 65 && b < 65 && (r - g) > 135 && (r - b) > 135 {
                        redMask[idx] = true
                    }
                }
            }

            let playerPos = detectBluePlayer(mask: blueMask, width: outW, height: outH)
            let refPlayer = playerPos ?? fallbackPlayerPos
            let (enemyPos, enemyCount) = detectNearestRedEnemy(
                mask: redMask,
                width: outW,
                height: outH,
                referencePlayer: refPlayer,
                previousEnemyPos: previousEnemyPos
            )

            // Tầng 2: Dò đường viền đứng khung camera trắng (>= 55% chiều cao, 0.42 ... 0.86, chứa playerX).
            let tier2Width = detectVerticalCameraBorderWidthNorm(
                lumaGrid: lumaGrid,
                width: outW,
                height: outH,
                playerX: refPlayer.map { Double($0.x) }
            )

            // Tầng 3: Đo bước vạch 5.0 đơn vị trên thước vàng đáy Minimap (`clamp(tickSpacing * 2.0, 0.44, 0.85)`).
            let tier3Width = yellowRulerCrop.flatMap { detectYellowRulerScreenWidthNorm(from: $0) }

            let chosenWidth: Double?
            let scaleSource: DistanceMeasurementTier
            if let camW = tier2Width {
                chosenWidth = camW
                scaleSource = .tier2MinimapCameraBorder
            } else if let rulerW = tier3Width {
                chosenWidth = rulerW
                scaleSource = .tier3MinimapYellowRuler
            } else {
                chosenWidth = nil
                scaleSource = .fallbackCachedScale
            }

            return MinimapAnalysisResult(
                playerPos: playerPos,
                enemyPos: enemyPos,
                enemyCount: enemyCount,
                tier2CameraWidthNorm: tier2Width,
                tier3RulerWidthNorm: tier3Width,
                screenWidthNorm: chosenWidth,
                scaleSource: scaleSource
            )
        }
    }

    /// Hợp nhất 3 tầng cho toàn bộ khung hình (dùng chung cho cả `SampleHandler` và bộ test tự động).
    public func fuseMultiCueMeasurement(
        battlefieldCrop: CGImage?,
        minimapCrop: CGImage?,
        yellowRulerCrop: CGImage?,
        fallbackPlayerPos: CGPoint?,
        previousEnemyPos: CGPoint?,
        cachedScreenWidthNorm: Double
    ) -> MultiCueFusionResult? {
        // Tầng 1 (Ưu tiên cao nhất): Thanh máu trên màn hình chính (< 10 đơn vị).
        if let battlefieldCrop,
           let tier1 = detectMainScreenHealthBars(battlefieldCrop: battlefieldCrop) {
            return MultiCueFusionResult(
                tier: .tier1MainScreenHealthBars,
                distanceUnits: tier1.distanceUnits,
                deltaYUnits: tier1.deltaYUnits,
                screenWidthNorm: cachedScreenWidthNorm,
                mainScreenResult: tier1,
                minimapResult: nil
            )
        }

        // Tầng 2 + Tầng 3: Minimap + Viền đứng khung camera + Thước vàng đáy Minimap.
        guard let minimapCrop,
              let minimap = analyzeMinimap(
                  minimapCrop: minimapCrop,
                  yellowRulerCrop: yellowRulerCrop,
                  fallbackPlayerPos: fallbackPlayerPos,
                  previousEnemyPos: previousEnemyPos
              ) else {
            return nil
        }

        let effectiveScale = minimap.screenWidthNorm ?? min(max(cachedScreenWidthNorm, 0.42), 0.86)
        guard let player = minimap.playerPos ?? fallbackPlayerPos,
              let enemy = minimap.enemyPos else {
            return nil
        }

        let distanceUnits = (abs(Double(enemy.x - player.x)) / effectiveScale) * BallisticsEngine.unitsPerScreen
        let deltaYUnits = (Double(player.y - enemy.y) / (effectiveScale * 0.55)) * BallisticsEngine.unitsPerScreen

        return MultiCueFusionResult(
            tier: minimap.scaleSource,
            distanceUnits: distanceUnits,
            deltaYUnits: deltaYUnits,
            screenWidthNorm: effectiveScale,
            mainScreenResult: nil,
            minimapResult: minimap
        )
    }

    // MARK: - 8-Neighbor CCL for Pure Blue Player & Pure Red Enemy (with groundY)

    private struct PixelCluster {
        var centerX: Double
        var centerY: Double
        var maxY: Int
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
            x: min(max((best.centerX + 0.5) / Double(width), 0.0), 1.0),
            y: min(max((Double(best.maxY) + 0.5) / Double(height), 0.0), 1.0)
        )
    }

    private func detectNearestRedEnemy(
        mask: [Bool],
        width: Int,
        height: Int,
        referencePlayer: CGPoint?,
        previousEnemyPos: CGPoint?
    ) -> (CGPoint?, Int) {
        let raw = extract8ConnectedClusters(
            from: mask,
            width: width,
            height: height,
            minPixels: 2,
            maxBBoxWidthRatio: 0.16,
            maxBBoxHeightRatio: 0.40
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

        // Bỏ qua nhiễu đỏ cách người chơi < 0.025.
        if let player = referencePlayer {
            points = points.filter { hypot(Double($0.x - player.x), Double($0.y - player.y)) >= 0.025 }
            guard !points.isEmpty else { return (nil, 0) }

            points.sort { lhs, rhs in
                let dL = abs(Double(lhs.x - player.x))
                let dR = abs(Double(rhs.x - player.x))
                if abs(dL - dR) > 0.005 {
                    return dL < dR
                }
                return hypot(Double(lhs.x - player.x), Double(lhs.y - player.y))
                    < hypot(Double(rhs.x - player.x), Double(rhs.y - player.y))
            }

            // Chống nhảy mục tiêu qua lại khi có nhiều quái cách người chơi gần như nhau.
            if let prev = previousEnemyPos, let closest = points.first {
                let closestDist = abs(Double(closest.x - player.x))
                if let sticky = points.first(where: { candidate in
                    hypot(Double(candidate.x - prev.x), Double(candidate.y - prev.y)) <= 0.04
                        && abs(Double(candidate.x - player.x)) <= closestDist + 0.02
                }) {
                    return (sticky, points.count)
                }
            }
        }

        return (points.first, points.count)
    }

    // MARK: - Tầng 2: Vertical Camera Border Edge Detection (10.0 Units)

    private struct VerticalEdgeCandidate {
        let col: Int
        let ratio: Double
        let meanGrad: Double
    }

    /// Dò 2 đường viền đứng khung camera trắng (`boxLeft`, `boxRight`):
    /// Với mỗi cột `col`, đếm số hàng từ trên xuống dưới (bao gồm cả mặt đất) có `luma[col] - luma[col - 1] >= 10` (cạnh trái)
    /// hoặc `luma[col] - luma[col + 1] >= 10` (cạnh phải). Cột có tỷ lệ `>= 55%` chiều cao là mép khung camera `10.0` đơn vị.
    private func detectVerticalCameraBorderWidthNorm(
        lumaGrid: [Double],
        width: Int,
        height: Int,
        playerX: Double?
    ) -> Double? {
        guard width >= 24, height >= 8 else { return nil }

        var leftRatio = [Double](repeating: 0.0, count: width)
        var rightRatio = [Double](repeating: 0.0, count: width)
        var leftMeanGrad = [Double](repeating: 0.0, count: width)
        var rightMeanGrad = [Double](repeating: 0.0, count: width)
        var colMeanLuma = [Double](repeating: 0.0, count: width)

        let invH = 1.0 / Double(height)
        for col in 0..<width {
            var sumLuma = 0.0
            for y in 0..<height {
                sumLuma += lumaGrid[y * width + col]
            }
            colMeanLuma[col] = sumLuma * invH
        }

        for col in 1..<(width - 1) {
            var lHits = 0
            var rHits = 0
            var lGradSum = 0.0
            var rGradSum = 0.0

            for y in 0..<height {
                let idx = y * width + col
                let cur = lumaGrid[idx]
                let dL = cur - lumaGrid[idx - 1]
                let dR = cur - lumaGrid[idx + 1]
                if dL >= 10.0 {
                    lHits += 1
                    lGradSum += dL
                }
                if dR >= 10.0 {
                    rHits += 1
                    rGradSum += dR
                }
            }

            leftRatio[col] = Double(lHits) * invH
            rightRatio[col] = Double(rHits) * invH
            leftMeanGrad[col] = lHits > 0 ? (lGradSum / Double(lHits)) : 0.0
            rightMeanGrad[col] = rHits > 0 ? (rGradSum / Double(rHits)) : 0.0
        }

        let leftPeaks = extractVerticalEdgePeaks(ratios: leftRatio, meanGrads: leftMeanGrad, minRatio: 0.55)
        let rightPeaks = extractVerticalEdgePeaks(ratios: rightRatio, meanGrads: rightMeanGrad, minRatio: 0.55)

        var bestSpan: Double?
        var bestScore: Double = -1.0

        func evaluatePair(leftCol: Int, rightCol: Int, lRatio: Double, rRatio: Double, lGrad: Double, rGrad: Double) {
            guard rightCol > leftCol + 6 else { return }
            let boxLeft = Double(leftCol) / Double(width)
            let boxRight = Double(rightCol) / Double(width)
            let span = boxRight - boxLeft
            guard span >= 0.42 && span <= 0.86 else { return }

            if let px = playerX {
                guard px >= (boxLeft - 0.015) && px <= (boxRight + 0.015) else { return }
            }

            // Kiểm tra độ sáng trung bình bên trong khung so với ngoài khung (thưởng điểm nếu khung camera sáng hơn nền ngoài).
            var insideSum = 0.0
            var insideCnt = 0
            var outsideSum = 0.0
            var outsideCnt = 0
            for c in 0..<width {
                if c > leftCol + 1 && c < rightCol - 1 {
                    insideSum += colMeanLuma[c]
                    insideCnt += 1
                } else if c < leftCol - 1 || c > rightCol + 1 {
                    outsideSum += colMeanLuma[c]
                    outsideCnt += 1
                }
            }
            let brightnessBonus: Double
            if insideCnt >= 4 && outsideCnt >= 4 {
                let diff = (insideSum / Double(insideCnt)) - (outsideSum / Double(outsideCnt))
                brightnessBonus = diff >= 4.0 ? 18.0 : (diff >= -2.0 ? 4.0 : -10.0)
            } else {
                brightnessBonus = 0.0
            }

            let strictContainBonus: Double
            if let px = playerX, px >= boxLeft && px <= boxRight {
                strictContainBonus = 12.0
            } else {
                strictContainBonus = 0.0
            }

            let score = (lRatio + rRatio) * 100.0
                + min(lGrad, 80.0) * 0.25
                + min(rGrad, 80.0) * 0.25
                + brightnessBonus
                + strictContainBonus

            if score > bestScore {
                bestScore = score
                bestSpan = span
            }
        }

        for lp in leftPeaks {
            for rp in rightPeaks where rp.col > lp.col {
                evaluatePair(
                    leftCol: lp.col,
                    rightCol: rp.col,
                    lRatio: lp.ratio,
                    rRatio: rp.ratio,
                    lGrad: lp.meanGrad,
                    rGrad: rp.meanGrad
                )
            }
        }

        // Trường hợp khung camera áp sát mép trái (`col = 0`) hoặc mép phải (`col = width - 1`) Minimap.
        if bestSpan == nil {
            for rp in rightPeaks {
                let insideMean = meanLuma(colMeanLuma, from: 0, to: max(0, rp.col - 2))
                let outsideMean = meanLuma(colMeanLuma, from: min(width - 1, rp.col + 2), to: width - 1)
                if insideMean - outsideMean >= 8.0 {
                    evaluatePair(leftCol: 0, rightCol: rp.col, lRatio: 0.60, rRatio: rp.ratio, lGrad: 15.0, rGrad: rp.meanGrad)
                }
            }
            for lp in leftPeaks {
                let insideMean = meanLuma(colMeanLuma, from: min(width - 1, lp.col + 2), to: width - 1)
                let outsideMean = meanLuma(colMeanLuma, from: 0, to: max(0, lp.col - 2))
                if insideMean - outsideMean >= 8.0 {
                    evaluatePair(leftCol: lp.col, rightCol: width - 1, lRatio: lp.ratio, rRatio: 0.60, lGrad: lp.meanGrad, rGrad: 15.0)
                }
            }
        }

        return bestSpan
    }

    private func extractVerticalEdgePeaks(
        ratios: [Double],
        meanGrads: [Double],
        minRatio: Double
    ) -> [VerticalEdgeCandidate] {
        var peaks: [VerticalEdgeCandidate] = []
        let count = ratios.count
        var col = 1
        while col < count - 1 {
            guard ratios[col] >= minRatio else {
                col += 1
                continue
            }
            var bestCol = col
            var bestRatio = ratios[col]
            var bestGrad = meanGrads[col]
            var gap = 0
            col += 1
            while col < count - 1 {
                if ratios[col] >= minRatio {
                    gap = 0
                    if ratios[col] > bestRatio || (abs(ratios[col] - bestRatio) < 0.01 && meanGrads[col] > bestGrad) {
                        bestCol = col
                        bestRatio = ratios[col]
                        bestGrad = meanGrads[col]
                    }
                } else {
                    gap += 1
                    if gap > 2 { break }
                }
                col += 1
            }
            peaks.append(VerticalEdgeCandidate(col: bestCol, ratio: bestRatio, meanGrad: bestGrad))
        }
        return peaks
    }

    private func meanLuma(_ arr: [Double], from start: Int, to end: Int) -> Double {
        guard start <= end, start >= 0, end < arr.count else { return 0.0 }
        var sum = 0.0
        for i in start...end {
            sum += arr[i]
        }
        return sum / Double(end - start + 1)
    }

    // MARK: - Tầng 3: Yellow Ruler 5.0-Unit Dark Tick Spacing (y: 0.148...0.163)

    /// Tìm các vạch chia dọc tối màu trên thước vàng đáy Minimap (`5.0` đơn vị), trả về `clamp(tickSpacing * 2.0, 0.44, 0.85)`.
    public func detectYellowRulerScreenWidthNorm(from rulerImage: CGImage) -> Double? {
        return withRGBA8Pixels(of: rulerImage) { rgbaPtr, bytesPerRow, outW, outH -> Double? in
            guard outW >= 20, outH >= 2 else { return nil }

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
                    let centerNorm = (Double(startX + endX) * 0.5 + 0.5) / Double(outW)
                    tickCenters.append(centerNorm)
                }
            }

            guard tickCenters.count >= 2 else { return nil }

            var validSpacings: [Double] = []
            for i in 0..<(tickCenters.count - 1) {
                let spacing = tickCenters[i + 1] - tickCenters[i]
                // 1 khoảng vạch = 5.0 đơn vị -> 2 * spacing ứng với 10.0 đơn vị.
                if spacing >= 0.18 && spacing <= 0.45 {
                    validSpacings.append(spacing)
                }
            }
            guard !validSpacings.isEmpty else { return nil }

            validSpacings.sort()
            let medianSpacing = validSpacings[validSpacings.count / 2]
            return min(max(medianSpacing * 2.0, 0.44), 0.85)
        }
    }

    // MARK: - Accurate Vietnamese/English Angle OCR (-35 ... 85)

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

    // MARK: - Zero-Copy RGBA8 Pixel Access Helper

    private func withRGBA8Pixels<T>(
        of image: CGImage,
        _ body: (UnsafePointer<UInt8>, Int, Int, Int) -> T?
    ) -> T? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let alphaInfo = image.alphaInfo
        let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
        let isRGBA8 = image.bitsPerComponent == 8
            && image.bitsPerPixel == 32
            && (byteOrder.rawValue == 0 || byteOrder == .byteOrder32Big)
            && (alphaInfo == .premultipliedLast || alphaInfo == .last || alphaInfo == .noneSkipLast)

        if isRGBA8,
           let provider = image.dataProvider,
           let cfData = provider.data,
           let ptr = CFDataGetBytePtr(cfData),
           CFDataGetLength(cfData) >= image.bytesPerRow * height {
            return body(ptr, image.bytesPerRow, width, height)
        }

        guard let context = makeRGBAContext(width: width, height: height),
              let rawData = context.data else {
            return nil
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let ptr = rawData.assumingMemoryBound(to: UInt8.self)
        return body(ptr, context.bytesPerRow, width, height)
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
