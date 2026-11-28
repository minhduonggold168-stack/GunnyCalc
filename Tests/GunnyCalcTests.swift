import CoreGraphics
import CoreImage
import CoreText
import Darwin
import Foundation
import Vision

@main
enum GunnyCalcTestMain {
    private static let rgbSpace = CGColorSpaceCreateDeviceRGB()
    private static let graySpace = CGColorSpaceCreateDeviceGray()
    private static let sharedCIContext = CIContext(options: [.cacheIntermediates: false])

    static func main() {
        var passed = 0
        var failed = 0

        func run(_ name: String, _ block: () throws -> String) {
            do {
                let detail = try block()
                print("[PASS] \(name): \(detail)")
                passed += 1
            } catch {
                print("[FAIL] \(name): \(error)")
                failed += 1
            }
        }

        run("Test 1 — Map Cầu Rồng (Trời sáng, Tầng 1 CL 4.4, Góc 50°)", test1DragonBridgeBrightSkyTier1)
        run("Test 2 — Map Tàu Đắm (Map hẹp, phải→trái CL 8.1, Góc 50°)", test2ShipwreckNarrowMapTier2)
        run("Test 3 — Map Sân Bóng / Chợ Bến Thành (Map rộng 0.465, CL 11.5, Góc 46°)", test3WideMapTier2AndTier3)
        run("Test 4 — Map Địa Hình Nâu Đỏ / Dung Nham (Chống nhiễu nền đỏ RGB 175,80,60)", test4RedLavaTerrainNoiseRejection)
        run("Test 5 — Map Chênh Cao Địa Hình (CL 7.0, ΔY +2.5, Góc 65°)", test5ElevationUphillCompensation)
        run("Test 6 — Phó Bản / Ải Viễn Chinh Nhiều Quái (3 chấm đỏ khóa ổn định)", test6MultiEnemyStableLock)
        run("Test 7 — Góc Âm Hố Sâu (OCR Góc -18°, CL 5.0)", test7NegativeAnglePit)
        run("Test 8 — Hiệu Năng & Độ Trễ Khứ Hồi 1920x886 + UDP (< 35ms)", test8PerformanceAndUDPRoundTripLatency)

        print("SUMMARY: \(passed)/\(passed + failed) tests PASSED")
        if failed > 0 {
            exit(1)
        }
        print("ALL 8 AUTOMATED TESTS PASSED 100%")
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw TestFailure(description: message)
        }
    }

    // MARK: - Synthetic Frame Builder (1920 x 886)

    private struct HealthBarSpec {
        let fullX: Double
        let fullY: Double
        let normW: Double
        let normH: Double
        let r: Double
        let g: Double
        let b: Double
    }

    private struct MinimapDotSpec {
        let normX: Double
        let groundY: Double // Top-Left normalized Y inside minimapStrip (0...1)
        let r: Double
        let g: Double
        let b: Double
        let widthPx: Double
        let heightPx: Double
    }

    private struct SyntheticSceneConfig {
        var skyRGB: (Double, Double, Double) = (22, 28, 40)
        var terrainRGB: (Double, Double, Double) = (45, 58, 48)
        var minimapOutsideRGB: (Double, Double, Double) = (32, 38, 46)
        var minimapInsideRGB: (Double, Double, Double) = (98, 108, 122)
        var minimapTerrainOutsideRGB: (Double, Double, Double) = (46, 52, 42)
        var minimapTerrainInsideRGB: (Double, Double, Double) = (86, 98, 82)
        var cameraStartNorm: Double? = 0.17
        var cameraEndNorm: Double? = 0.87
        var drawWhiteCameraBorder: Bool = true
        var rulerTickNormXs: [Double] = []
        var mainHealthBars: [HealthBarSpec] = []
        var minimapDots: [MinimapDotSpec] = []
        var angleText: String? = "Góc 50°"
        var angleTextColor: (Double, Double, Double) = (255, 255, 255)
        var angleBgPill: Bool = false
    }

    private static func buildSyntheticFrame(_ cfg: SyntheticSceneConfig) throws -> CGImage {
        let imgW = 1920
        let imgH = 886
        guard let ctx = CGContext(
            data: nil,
            width: imgW,
            height: imgH,
            bitsPerComponent: 8,
            bytesPerRow: imgW * 4,
            space: rgbSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw TestFailure(description: "Failed to allocate 1920x886 CGContext")
        }

        // 1. Nền bầu trời và địa hình chiến trường chính.
        ctx.setFillColor(makeColor(cfg.skyRGB))
        ctx.fill(CGRect(x: 0, y: 0, width: imgW, height: imgH))

        ctx.setFillColor(makeColor(cfg.terrainRGB))
        ctx.fill(CGRect(x: 0, y: 0, width: imgW, height: Int(Double(imgH) * 0.36)))

        // 2. Vẽ các thanh máu trên màn hình chính (Tầng 1) theo tọa độ Top-Left quy đổi sang CoreGraphics Bottom-Left.
        for bar in cfg.mainHealthBars {
            let bw = bar.normW * Double(imgW)
            let bh = bar.normH * Double(imgH)
            let cx = bar.fullX * Double(imgW)
            let topLeftCenterY = bar.fullY * Double(imgH)
            let cgBottomY = Double(imgH) - topLeftCenterY - bh * 0.5
            ctx.setFillColor(makeColor((bar.r, bar.g, bar.b)))
            ctx.fill(CGRect(x: cx - bw * 0.5, y: cgBottomY, width: bw, height: bh))
        }

        // 3. Vùng Minimap (Tầng 2: x=0.848, y=0.042, w=0.148, h=0.106).
        let minimapCI = ciRectFromTopLeft(
            normRect: GunnyROIs.minimapStrip,
            imageWidth: CGFloat(imgW),
            imageHeight: CGFloat(imgH)
        )
        ctx.setFillColor(makeColor(cfg.minimapOutsideRGB))
        ctx.fill(minimapCI)

        // Phần mặt đất nửa dưới Minimap.
        let terrainH = minimapCI.height * 0.38
        ctx.setFillColor(makeColor(cfg.minimapTerrainOutsideRGB))
        ctx.fill(CGRect(x: minimapCI.minX, y: minimapCI.minY, width: minimapCI.width, height: terrainH))

        if let camStart = cfg.cameraStartNorm, let camEnd = cfg.cameraEndNorm, camEnd > camStart {
            let camX = minimapCI.minX + CGFloat(camStart) * minimapCI.width
            let camW = CGFloat(camEnd - camStart) * minimapCI.width
            ctx.setFillColor(makeColor(cfg.minimapInsideRGB))
            ctx.fill(CGRect(x: camX, y: minimapCI.minY + terrainH, width: camW, height: minimapCI.height - terrainH))
            ctx.setFillColor(makeColor(cfg.minimapTerrainInsideRGB))
            ctx.fill(CGRect(x: camX, y: minimapCI.minY, width: camW, height: terrainH))

            if cfg.drawWhiteCameraBorder {
                ctx.setFillColor(makeColor((255, 255, 255)))
                // 2 đường viền đứng khung camera trắng chạy suốt từ trên xuống dưới (kể cả phần mặt đất).
                ctx.fill(CGRect(x: round(camX), y: minimapCI.minY + 2, width: 1.5, height: minimapCI.height - 4))
                ctx.fill(CGRect(x: round(camX + camW), y: minimapCI.minY + 2, width: 1.5, height: minimapCI.height - 4))
                // Viền ngang trên & dưới khung camera.
                ctx.fill(CGRect(x: round(camX), y: minimapCI.maxY - 3, width: camW, height: 1.5))
                ctx.fill(CGRect(x: round(camX), y: minimapCI.minY + 2, width: camW, height: 1.5))
            }
        }

        // Các chấm người chơi (xanh) & mục tiêu (đỏ) trên Minimap với đáy chân tại `groundY` (Top-Left).
        for dot in cfg.minimapDots {
            let cx = minimapCI.minX + CGFloat(dot.normX) * minimapCI.width
            let groundOffsetFromTop = CGFloat(dot.groundY) * minimapCI.height
            // Trong CoreGraphics (Bottom-Left), đáy chân nằm tại `minimapCI.maxY - groundOffsetFromTop`.
            let cgBottomY = minimapCI.maxY - groundOffsetFromTop
            ctx.setFillColor(makeColor((dot.r, dot.g, dot.b)))
            ctx.fill(CGRect(
                x: cx - CGFloat(dot.widthPx) * 0.5,
                y: cgBottomY,
                width: CGFloat(dot.widthPx),
                height: CGFloat(dot.heightPx)
            ))
        }

        // 4. Dải thước vàng đáy Minimap (Tầng 3: x=0.848, y=0.148, w=0.148, h=0.015).
        let rulerCI = ciRectFromTopLeft(
            normRect: GunnyROIs.minimapYellowRuler,
            imageWidth: CGFloat(imgW),
            imageHeight: CGFloat(imgH)
        )
        ctx.setFillColor(makeColor((235, 200, 65)))
        ctx.fill(rulerCI)

        if !cfg.rulerTickNormXs.isEmpty {
            ctx.setFillColor(makeColor((24, 20, 15)))
            for normX in cfg.rulerTickNormXs {
                let tx = rulerCI.minX + CGFloat(normX) * rulerCI.width
                ctx.fill(CGRect(x: tx - 1.5, y: rulerCI.minY, width: 3.0, height: rulerCI.height))
            }
        }

        // 5. Chữ góc bắn trong vùng chiến trường (`angleBattlefield`).
        if let angleText = cfg.angleText {
            let angleCI = ciRectFromTopLeft(
                normRect: GunnyROIs.angleBattlefield,
                imageWidth: CGFloat(imgW),
                imageHeight: CGFloat(imgH)
            )
            if cfg.angleBgPill {
                ctx.setFillColor(makeColor((18, 22, 30)))
                ctx.fill(CGRect(x: angleCI.minX + 230, y: angleCI.midY - 22, width: 340, height: 86))
            }
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 54.0, nil)
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: makeColor(cfg.angleTextColor)
            ]
            let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, angleText as CFString, attrs as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attrStr)
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: angleCI.minX + 255.0, y: angleCI.midY)
            CTLineDraw(line, ctx)
        }

        guard let image = ctx.makeImage() else {
            throw TestFailure(description: "Failed to create synthetic 1920x886 CGImage")
        }
        return image
    }

    private static func makeColor(_ rgb: (Double, Double, Double)) -> CGColor {
        CGColor(
            colorSpace: rgbSpace,
            components: [CGFloat(rgb.0 / 255.0), CGFloat(rgb.1 / 255.0), CGFloat(rgb.2 / 255.0), 1.0]
        )!
    }

    // MARK: - Production Crop Helpers (Mirroring SampleHandler.swift)

    private static func cropTier1Battlefield(from ciImage: CIImage) -> CGImage? {
        let cropRect = ciRectFromTopLeft(
            normRect: GunnyROIs.mainBattlefield,
            imageWidth: ciImage.extent.width,
            imageHeight: ciImage.extent.height
        ).intersection(ciImage.extent)
        guard cropRect.width >= 32, cropRect.height >= 16 else { return nil }

        var patch = ciImage
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))

        if patch.extent.width > 960.0 {
            patch = patch
                .samplingNearest()
                .transformed(by: CGAffineTransform(scaleX: 0.5, y: 1.0))
        }
        let bounds = CGRect(x: 0, y: 0, width: floor(patch.extent.width), height: floor(patch.extent.height))
        return sharedCIContext.createCGImage(patch, from: bounds, format: .RGBA8, colorSpace: rgbSpace)
    }

    private static func cropNativeROI(_ normRect: CGRect, from ciImage: CIImage) -> CGImage? {
        let cropRect = ciRectFromTopLeft(
            normRect: normRect,
            imageWidth: ciImage.extent.width,
            imageHeight: ciImage.extent.height
        ).intersection(ciImage.extent)
        guard cropRect.width >= 8, cropRect.height >= 2 else { return nil }

        let patch = ciImage
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
        let bounds = CGRect(x: 0, y: 0, width: floor(patch.extent.width), height: floor(patch.extent.height))
        return sharedCIContext.createCGImage(patch, from: bounds, format: .RGBA8, colorSpace: rgbSpace)
    }

    private static func cropContrastAngle(from ciImage: CIImage) -> CGImage? {
        let cropRect = ciRectFromTopLeft(
            normRect: GunnyROIs.angleBattlefield,
            imageWidth: ciImage.extent.width,
            imageHeight: ciImage.extent.height
        ).intersection(ciImage.extent)
        guard cropRect.width >= 16, cropRect.height >= 16 else { return nil }

        var patch = ciImage
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))

        if patch.extent.width > 640.0 {
            let scale = 640.0 / patch.extent.width
            patch = patch.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        patch = patch.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputContrastKey: 1.8,
                kCIInputSaturationKey: 0.0
            ]
        )
        let bounds = CGRect(x: 0, y: 0, width: floor(patch.extent.width), height: floor(patch.extent.height))
        return sharedCIContext.createCGImage(patch, from: bounds, format: .L8, colorSpace: graySpace)
    }

    // MARK: - Test 1: Map Cầu Rồng (Trời sáng chói, Tầng 1 CL 4.4, Góc 50° -> Lực 30.2 ± 0.8)

    private static func test1DragonBridgeBrightSkyTier1() throws -> String {
        var cfg = SyntheticSceneConfig()
        cfg.skyRGB = (215, 238, 255) // Trời sáng chói
        cfg.terrainRGB = (185, 195, 210)
        cfg.minimapOutsideRGB = (210, 232, 250)
        cfg.minimapInsideRGB = (218, 238, 255)
        cfg.angleText = "Góc 50°"
        cfg.angleBgPill = true
        // Người chơi tại x=0.26, địch tại x=0.70 (cùng độ cao y=0.62) -> dx = 0.44 -> CL 4.4
        cfg.mainHealthBars = [
            HealthBarSpec(fullX: 0.26, fullY: 0.62, normW: 0.040, normH: 0.010, r: 20, g: 85, b: 245),
            HealthBarSpec(fullX: 0.70, fullY: 0.62, normW: 0.044, normH: 0.010, r: 242, g: 22, b: 22)
        ]

        let frame = try buildSyntheticFrame(cfg)
        let ciImage = CIImage(cgImage: frame)
        let vision = VisionProcessor()
        let engine = BallisticsEngine()

        guard let battlefieldCG = cropTier1Battlefield(from: ciImage),
              let minimapCG = cropNativeROI(GunnyROIs.minimapStrip, from: ciImage),
              let rulerCG = cropNativeROI(GunnyROIs.minimapYellowRuler, from: ciImage),
              let fusion = vision.fuseMultiCueMeasurement(
                  battlefieldCrop: battlefieldCG,
                  minimapCrop: minimapCG,
                  yellowRulerCrop: rulerCG,
                  fallbackPlayerPos: nil,
                  previousEnemyPos: nil,
                  cachedScreenWidthNorm: VisionProcessor.defaultScreenWidthNorm
              ) else {
            throw TestFailure(description: "Multi-Cue Fusion failed on Dragon Bridge bright-sky scene")
        }

        try expect(fusion.tier == .tier1MainScreenHealthBars, "Expected Tier 1 health bars, got \(fusion.tier.rawValue)")
        try expect(
            abs(fusion.distanceUnits - 4.4) <= 0.2,
            String(format: "Expected distanceUnits = 4.4 ± 0.2, got %.2f", fusion.distanceUnits)
        )

        guard let angleCG = cropContrastAngle(from: ciImage),
              let angle = vision.detectAngle(fromContrastImage: angleCG) else {
            throw TestFailure(description: "OCR failed to read 'Góc 50°' on bright-sky scene")
        }
        try expect(angle == 50, "Expected angle 50°, got \(angle)°")

        let power = engine.calculatePower(distanceUnits: fusion.distanceUnits, angle: angle, deltaYUnits: fusion.deltaYUnits)
        try expect(
            abs(power - 30.2) <= 0.8,
            String(format: "Expected power = 30.2 ± 0.8, got %.1f", power)
        )

        return String(format: "tier=%@, dist=%.2f, angle=%d°, power=%.1f (target 30.2±0.8)", fusion.tier.rawValue, fusion.distanceUnits, angle, power)
    }

    // MARK: - Test 2: Map Tàu Đắm (Map hẹp, bắn phải→trái CL 8.1, Góc 50° -> Lực 42.3 ± 1.0)

    private static func test2ShipwreckNarrowMapTier2() throws -> String {
        var cfg = SyntheticSceneConfig()
        cfg.cameraStartNorm = 0.17
        cfg.cameraEndNorm = 0.87 // camW = 0.70
        cfg.angleText = "Góc 50°"
        cfg.minimapDots = [
            // Người chơi bên phải (0.69), địch ngoài mép trái khung camera (0.12) -> dx=0.57 -> 0.57/0.70*10 = 8.14
            MinimapDotSpec(normX: 0.69, groundY: 0.65, r: 22, g: 92, b: 245, widthPx: 7, heightPx: 9),
            MinimapDotSpec(normX: 0.12, groundY: 0.65, r: 240, g: 24, b: 24, widthPx: 7, heightPx: 7)
        ]

        let frame = try buildSyntheticFrame(cfg)
        let ciImage = CIImage(cgImage: frame)
        let vision = VisionProcessor()
        let engine = BallisticsEngine()

        guard let battlefieldCG = cropTier1Battlefield(from: ciImage),
              let minimapCG = cropNativeROI(GunnyROIs.minimapStrip, from: ciImage),
              let rulerCG = cropNativeROI(GunnyROIs.minimapYellowRuler, from: ciImage),
              let fusion = vision.fuseMultiCueMeasurement(
                  battlefieldCrop: battlefieldCG,
                  minimapCrop: minimapCG,
                  yellowRulerCrop: rulerCG,
                  fallbackPlayerPos: nil,
                  previousEnemyPos: nil,
                  cachedScreenWidthNorm: VisionProcessor.defaultScreenWidthNorm
              ) else {
            throw TestFailure(description: "Multi-Cue Fusion failed on Shipwreck narrow map")
        }

        try expect(fusion.tier == .tier2MinimapCameraBorder, "Expected Tier 2 vertical camera border, got \(fusion.tier.rawValue)")
        try expect(abs(fusion.screenWidthNorm - 0.70) <= 0.03, String(format: "Expected camW ≈ 0.70, got %.3f", fusion.screenWidthNorm))
        try expect(abs(fusion.distanceUnits - 8.1) <= 0.3, String(format: "Expected dist = 8.1 ± 0.3, got %.2f", fusion.distanceUnits))

        guard let angleCG = cropContrastAngle(from: ciImage),
              let angle = vision.detectAngle(fromContrastImage: angleCG) else {
            throw TestFailure(description: "OCR failed to read 'Góc 50°' on Shipwreck map")
        }
        try expect(angle == 50, "Expected angle 50°, got \(angle)°")

        let power = engine.calculatePower(distanceUnits: fusion.distanceUnits, angle: angle, deltaYUnits: fusion.deltaYUnits)
        try expect(abs(power - 42.3) <= 1.0, String(format: "Expected power = 42.3 ± 1.0, got %.1f", power))

        return String(format: "tier=%@, camW=%.3f, dist=%.2f, angle=%d°, power=%.1f (target 42.3±1.0)", fusion.tier.rawValue, fusion.screenWidthNorm, fusion.distanceUnits, angle, power)
    }

    // MARK: - Test 3: Map Sân Bóng / Chợ Bến Thành (Map rộng 21.5 đơn vị, tỷ lệ 0.465, CL 11.5, Góc 46° -> Lực 51.4 ± 1.0)

    private static func test3WideMapTier2AndTier3() throws -> String {
        var cfg = SyntheticSceneConfig()
        cfg.cameraStartNorm = 0.05
        cfg.cameraEndNorm = 0.515 // camW = 0.465
        cfg.rulerTickNormXs = [0.10, 0.3325, 0.565, 0.7975] // spacing = 0.2325 (5.0 units -> 10.0 units = 0.465)
        cfg.angleText = "Góc 46°"
        cfg.minimapDots = [
            MinimapDotSpec(normX: 0.255, groundY: 0.68, r: 22, g: 92, b: 245, widthPx: 7, heightPx: 9),
            MinimapDotSpec(normX: 0.790, groundY: 0.68, r: 242, g: 20, b: 20, widthPx: 7, heightPx: 7)
        ]

        let frame = try buildSyntheticFrame(cfg)
        let ciImage = CIImage(cgImage: frame)
        let vision = VisionProcessor()
        let engine = BallisticsEngine()

        guard let battlefieldCG = cropTier1Battlefield(from: ciImage),
              let minimapCG = cropNativeROI(GunnyROIs.minimapStrip, from: ciImage),
              let rulerCG = cropNativeROI(GunnyROIs.minimapYellowRuler, from: ciImage),
              let fusion = vision.fuseMultiCueMeasurement(
                  battlefieldCrop: battlefieldCG,
                  minimapCrop: minimapCG,
                  yellowRulerCrop: rulerCG,
                  fallbackPlayerPos: nil,
                  previousEnemyPos: nil,
                  cachedScreenWidthNorm: VisionProcessor.defaultScreenWidthNorm
              ),
              let minimap = fusion.minimapResult,
              let tier2W = minimap.tier2CameraWidthNorm,
              let tier3W = minimap.tier3RulerWidthNorm else {
            throw TestFailure(description: "Tier 2 + Tier 3 measurement failed on wide map")
        }

        try expect(abs(tier2W - 0.465) <= 0.025, String(format: "Expected Tier 2 camW ≈ 0.465, got %.3f", tier2W))
        try expect(abs(tier3W - 0.465) <= 0.025, String(format: "Expected Tier 3 rulerW ≈ 0.465, got %.3f", tier3W))
        try expect(abs(fusion.distanceUnits - 11.5) <= 0.3, String(format: "Expected dist = 11.5 ± 0.3, got %.2f", fusion.distanceUnits))

        // Xác nhận Tầng 3 fallback độc lập khi không vẽ khung camera Tầng 2.
        var fallbackCfg = cfg
        fallbackCfg.cameraStartNorm = nil
        fallbackCfg.cameraEndNorm = nil
        let fallbackFrame = try buildSyntheticFrame(fallbackCfg)
        let fallbackCI = CIImage(cgImage: fallbackFrame)
        guard let fbMinimap = cropNativeROI(GunnyROIs.minimapStrip, from: fallbackCI),
              let fbRuler = cropNativeROI(GunnyROIs.minimapYellowRuler, from: fallbackCI),
              let fbFusion = vision.fuseMultiCueMeasurement(
                  battlefieldCrop: nil,
                  minimapCrop: fbMinimap,
                  yellowRulerCrop: fbRuler,
                  fallbackPlayerPos: nil,
                  previousEnemyPos: nil,
                  cachedScreenWidthNorm: VisionProcessor.defaultScreenWidthNorm
              ) else {
            throw TestFailure(description: "Tier 3 yellow ruler fallback failed on wide map")
        }
        try expect(fbFusion.tier == .tier3MinimapYellowRuler, "Expected Tier 3 ruler fallback, got \(fbFusion.tier.rawValue)")
        try expect(abs(fbFusion.distanceUnits - 11.5) <= 0.3, String(format: "Expected Tier 3 dist = 11.5 ± 0.3, got %.2f", fbFusion.distanceUnits))

        guard let angleCG = cropContrastAngle(from: ciImage),
              let angle = vision.detectAngle(fromContrastImage: angleCG) else {
            throw TestFailure(description: "OCR failed to read 'Góc 46°' on wide map")
        }
        try expect(angle == 46, "Expected angle 46°, got \(angle)°")

        let power = engine.calculatePower(distanceUnits: fusion.distanceUnits, angle: angle, deltaYUnits: fusion.deltaYUnits)
        try expect(abs(power - 51.4) <= 1.0, String(format: "Expected power = 51.4 ± 1.0, got %.1f", power))

        return String(format: "tier2W=%.3f, tier3W=%.3f, dist=%.2f, angle=%d°, power=%.1f (target 51.4±1.0)", tier2W, tier3W, fusion.distanceUnits, angle, power)
    }

    // MARK: - Test 4: Map Địa Hình Nâu Đỏ / Dung Nham (Nền đỏ gạch RGB(175, 80, 60))

    private static func test4RedLavaTerrainNoiseRejection() throws -> String {
        var cfg = SyntheticSceneConfig()
        cfg.skyRGB = (95, 38, 30)
        cfg.terrainRGB = (175, 80, 60) // Địa hình nâu đỏ / dung nham
        cfg.minimapOutsideRGB = (130, 58, 44)
        cfg.minimapInsideRGB = (175, 80, 60) // Phủ đỏ gạch ngay trong khung camera
        cfg.minimapTerrainOutsideRGB = (145, 66, 50)
        cfg.minimapTerrainInsideRGB = (175, 80, 60)
        cfg.cameraStartNorm = 0.12
        cfg.cameraEndNorm = 0.82 // camW = 0.70
        cfg.angleText = "Góc 50°"
        // Chèn thanh máu giả màu đỏ gạch RGB(175, 80, 60) trên màn hình chính -> Tầng 1 phải bỏ qua.
        cfg.mainHealthBars = [
            HealthBarSpec(fullX: 0.25, fullY: 0.60, normW: 0.040, normH: 0.010, r: 20, g: 85, b: 245),
            HealthBarSpec(fullX: 0.55, fullY: 0.60, normW: 0.045, normH: 0.010, r: 175, g: 80, b: 60)
        ]
        // Trên Minimap: người chơi xanh tại 0.22, 1 mục tiêu đỏ tươi duy nhất tại 0.78 -> dx = 0.56 -> 0.56/0.70*10 = 8.0
        cfg.minimapDots = [
            MinimapDotSpec(normX: 0.22, groundY: 0.66, r: 22, g: 92, b: 245, widthPx: 7, heightPx: 9),
            MinimapDotSpec(normX: 0.78, groundY: 0.66, r: 242, g: 20, b: 20, widthPx: 7, heightPx: 7)
        ]

        let frame = try buildSyntheticFrame(cfg)
        let ciImage = CIImage(cgImage: frame)
        let vision = VisionProcessor()
        let engine = BallisticsEngine()

        guard let battlefieldCG = cropTier1Battlefield(from: ciImage),
              let minimapCG = cropNativeROI(GunnyROIs.minimapStrip, from: ciImage),
              let rulerCG = cropNativeROI(GunnyROIs.minimapYellowRuler, from: ciImage) else {
            throw TestFailure(description: "Failed to crop lava map ROIs")
        }

        // Xác nhận Tầng 1 không bắt nhầm địa hình đỏ gạch RGB(175,80,60).
        let tier1Fake = vision.detectMainScreenHealthBars(battlefieldCrop: battlefieldCG)
        try expect(tier1Fake == nil, "Tier 1 falsely matched brick-red RGB(175,80,60) terrain bar")

        guard let fusion = vision.fuseMultiCueMeasurement(
            battlefieldCrop: battlefieldCG,
            minimapCrop: minimapCG,
            yellowRulerCrop: rulerCG,
            fallbackPlayerPos: nil,
            previousEnemyPos: nil,
            cachedScreenWidthNorm: VisionProcessor.defaultScreenWidthNorm
        ), let minimap = fusion.minimapResult, let enemy = minimap.enemyPos else {
            throw TestFailure(description: "Failed to lock bright red enemy on lava map")
        }

        try expect(minimap.enemyCount == 1, "Expected exactly 1 bright-red enemy cluster on lava map, got \(minimap.enemyCount)")
        try expect(abs(Double(enemy.x) - 0.78) <= 0.025, String(format: "Expected enemyX ≈ 0.78, got %.3f", enemy.x))
        try expect(abs(fusion.distanceUnits - 8.0) <= 0.3, String(format: "Expected dist = 8.0 ± 0.3, got %.2f", fusion.distanceUnits))

        let power = engine.calculatePower(distanceUnits: fusion.distanceUnits, angle: 50, deltaYUnits: fusion.deltaYUnits)
        try expect(abs(power - 42.0) <= 1.0, String(format: "Expected power = 42.0 ± 1.0, got %.1f", power))

        return String(format: "rejected RGB(175,80,60), enemyCount=%d, enemyX=%.3f, dist=%.2f, power=%.1f", minimap.enemyCount, enemy.x, fusion.distanceUnits, power)
    }

    // MARK: - Test 5: Map Chênh Cao Địa Hình (CL 7.0, địch đứng cao trên bục ΔY = +2.5, Góc 65°)

    private static func test5ElevationUphillCompensation() throws -> String {
        var cfg = SyntheticSceneConfig()
        cfg.angleText = "Góc 65°"
        // Trên màn hình chính: player tại (0.15, 0.74), enemy trên bục cao tại (0.85, 0.3368)
        // -> dx = 0.70 -> CL = 7.0; dy = (0.74 - 0.3368) * 6.2 = +2.50 đơn vị.
        cfg.mainHealthBars = [
            HealthBarSpec(fullX: 0.15, fullY: 0.7400, normW: 0.040, normH: 0.010, r: 20, g: 85, b: 245),
            HealthBarSpec(fullX: 0.85, fullY: 0.3368, normW: 0.044, normH: 0.010, r: 242, g: 20, b: 20)
        ]

        let frame = try buildSyntheticFrame(cfg)
        let ciImage = CIImage(cgImage: frame)
        let vision = VisionProcessor()
        let engine = BallisticsEngine()

        guard let battlefieldCG = cropTier1Battlefield(from: ciImage),
              let fusion = vision.fuseMultiCueMeasurement(
                  battlefieldCrop: battlefieldCG,
                  minimapCrop: nil,
                  yellowRulerCrop: nil,
                  fallbackPlayerPos: nil,
                  previousEnemyPos: nil,
                  cachedScreenWidthNorm: VisionProcessor.defaultScreenWidthNorm
              ) else {
            throw TestFailure(description: "Tier 1 failed on elevated platform scene")
        }

        try expect(abs(fusion.distanceUnits - 7.0) <= 0.2, String(format: "Expected dist = 7.0 ± 0.2, got %.2f", fusion.distanceUnits))
        try expect(abs(fusion.deltaYUnits - 2.5) <= 0.2, String(format: "Expected ΔY = +2.5 ± 0.2, got %+.2f", fusion.deltaYUnits))

        guard let angleCG = cropContrastAngle(from: ciImage),
              let angle = vision.detectAngle(fromContrastImage: angleCG) else {
            throw TestFailure(description: "OCR failed to read 'Góc 65°'")
        }
        try expect(angle == 65, "Expected angle 65°, got \(angle)°")

        let flatPower = engine.calculatePower(distanceUnits: 7.0, angle: 65, deltaYUnits: 0.0)
        let uphillPower = engine.calculatePower(distanceUnits: fusion.distanceUnits, angle: angle, deltaYUnits: fusion.deltaYUnits)
        let downhillPower = engine.calculatePower(distanceUnits: 7.0, angle: 65, deltaYUnits: -2.5)
        let extremeCliffPower = engine.calculatePower(distanceUnits: 1.0, angle: 20, deltaYUnits: 2.0)

        // Lý thuyết chuẩn: P_flat(7.0, 65°) = 45.0; ratio = 1 - 2.5/(7*tan65°) = 0.83346 -> P = 45/sqrt(0.83346) = 49.3.
        try expect(abs(flatPower - 45.0) <= 0.1, "Expected flat power 45.0, got \(flatPower)")
        try expect(uphillPower > flatPower + 3.0 && abs(uphillPower - 49.3) <= 0.8, String(format: "Expected uphill power ≈ 49.3, got %.1f", uphillPower))
        try expect(downhillPower < flatPower - 2.0, "Expected downhill power < flat power, got \(downhillPower)")
        try expect(extremeCliffPower == 100.0, "Expected ratio <= 0.15 clamp to 100.0, got \(extremeCliffPower)")

        return String(format: "dist=%.2f, ΔY=%+.2f, P_flat=%.1f -> P_uphill=%.1f (target 49.3), P_down=%.1f", fusion.distanceUnits, fusion.deltaYUnits, flatPower, uphillPower, downhillPower)
    }

    // MARK: - Test 6: Phó Bản / Ải Viễn Chinh Nhiều Quái (3 chấm đỏ cùng lúc khóa ổn định mục tiêu gần nhất)

    private static func test6MultiEnemyStableLock() throws -> String {
        let vision = VisionProcessor()
        var previousEnemy: CGPoint?
        var measuredDistances: [Double] = []
        var measuredEnemyXs: [Double] = []

        // Mô phỏng 6 khung hình liên tiếp với 3 quái (gần nhất tại 0.42, các quái xa tại 0.64 và 0.86) có rung nhẹ ±1px.
        let jitters: [Double] = [0.0, 0.003, -0.003, 0.002, -0.002, 0.001]
        for frameIdx in 0..<jitters.count {
            let j = jitters[frameIdx]
            var cfg = SyntheticSceneConfig()
            cfg.cameraStartNorm = 0.08
            cfg.cameraEndNorm = 0.73 // camW = 0.65
            cfg.angleText = nil
            cfg.minimapDots = [
                MinimapDotSpec(normX: 0.16, groundY: 0.65, r: 22, g: 92, b: 245, widthPx: 7, heightPx: 9),
                MinimapDotSpec(normX: 0.42 + j, groundY: 0.65, r: 242, g: 20, b: 20, widthPx: 7, heightPx: 7),
                MinimapDotSpec(normX: 0.64 - j, groundY: 0.62, r: 242, g: 20, b: 20, widthPx: 7, heightPx: 7),
                MinimapDotSpec(normX: 0.86 + j, groundY: 0.60, r: 242, g: 20, b: 20, widthPx: 7, heightPx: 7)
            ]

            let frame = try buildSyntheticFrame(cfg)
            let ciImage = CIImage(cgImage: frame)
            guard let minimapCG = cropNativeROI(GunnyROIs.minimapStrip, from: ciImage),
                  let fusion = vision.fuseMultiCueMeasurement(
                      battlefieldCrop: nil,
                      minimapCrop: minimapCG,
                      yellowRulerCrop: nil,
                      fallbackPlayerPos: nil,
                      previousEnemyPos: previousEnemy,
                      cachedScreenWidthNorm: VisionProcessor.defaultScreenWidthNorm
                  ),
                  let minimap = fusion.minimapResult,
                  let lockedEnemy = minimap.enemyPos else {
                throw TestFailure(description: "Multi-enemy lock failed at frame \(frameIdx)")
            }

            try expect(minimap.enemyCount == 3, "Expected 3 enemies on minimap, got \(minimap.enemyCount)")
            try expect(abs(Double(lockedEnemy.x) - 0.42) <= 0.025, String(format: "Frame %d jumped away from nearest enemy 0.42 to %.3f", frameIdx, lockedEnemy.x))

            previousEnemy = lockedEnemy
            measuredEnemyXs.append(Double(lockedEnemy.x))
            measuredDistances.append(fusion.distanceUnits)
        }

        let minDist = measuredDistances.min() ?? 0.0
        let maxDist = measuredDistances.max() ?? 0.0
        let spread = maxDist - minDist
        try expect(spread <= 0.25, String(format: "Multi-enemy distance jitter %.2f > 0.25", spread))
        // Expected: (0.42 - 0.16) / 0.65 * 10 = 4.00
        try expect(abs(minDist - 4.0) <= 0.3 && abs(maxDist - 4.0) <= 0.3, String(format: "Expected locked nearest dist ≈ 4.0, got %.2f...%.2f", minDist, maxDist))

        return String(format: "3 enemies detected across %d frames, lockedX≈%.3f, dist=%.2f...%.2f (spread=%.2f)", jitters.count, measuredEnemyXs[0], minDist, maxDist, spread)
    }

    // MARK: - Test 7: Góc Âm Hố Sâu (OCR Góc -18°, CL 5.0)

    private static func test7NegativeAnglePit() throws -> String {
        // Kiểm tra thêm regex góc âm cho các biến thể OCR.
        let regexCases: [([String], Int?)] = [
            (["Góc -18°"], -18),
            (["Goc -18"], -18),
            (["-18°"], -18),
            (["Góc -35°"], -35),
            (["Góc 85°"], 85),
            (["Góc 99°"], nil)
        ]
        for (texts, expected) in regexCases {
            let actual = AngleParser.extractAngle(from: texts)
            try expect(actual == expected, "AngleParser(\(texts)) = \(String(describing: actual)), expected \(String(describing: expected))")
        }

        var cfg = SyntheticSceneConfig()
        cfg.angleText = "Góc -18°"
        // CL = 5.0 trên màn hình chính (0.20 -> 0.70).
        cfg.mainHealthBars = [
            HealthBarSpec(fullX: 0.20, fullY: 0.52, normW: 0.040, normH: 0.010, r: 20, g: 85, b: 245),
            HealthBarSpec(fullX: 0.70, fullY: 0.52, normW: 0.044, normH: 0.010, r: 242, g: 20, b: 20)
        ]

        let frame = try buildSyntheticFrame(cfg)
        let ciImage = CIImage(cgImage: frame)
        let vision = VisionProcessor()
        let engine = BallisticsEngine()

        guard let battlefieldCG = cropTier1Battlefield(from: ciImage),
              let fusion = vision.fuseMultiCueMeasurement(
                  battlefieldCrop: battlefieldCG,
                  minimapCrop: nil,
                  yellowRulerCrop: nil,
                  fallbackPlayerPos: nil,
                  previousEnemyPos: nil,
                  cachedScreenWidthNorm: VisionProcessor.defaultScreenWidthNorm
              ) else {
            throw TestFailure(description: "Failed to measure CL 5.0 on negative-angle pit scene")
        }

        guard let angleCG = cropContrastAngle(from: ciImage),
              let detectedAngle = vision.detectAngle(fromContrastImage: angleCG) else {
            throw TestFailure(description: "Vision OCR failed to read 'Góc -18°'")
        }
        try expect(detectedAngle == -18, "Expected OCR angle -18°, got \(detectedAngle)°")
        try expect(abs(fusion.distanceUnits - 5.0) <= 0.2, String(format: "Expected dist = 5.0 ± 0.2, got %.2f", fusion.distanceUnits))

        let power = engine.calculatePower(distanceUnits: fusion.distanceUnits, angle: detectedAngle, deltaYUnits: fusion.deltaYUnits)
        try expect(power.isFinite && abs(power - 36.0) <= 1.0, String(format: "Expected smooth power ≈ 36.0 at -18° CL 5.0, got %.1f", power))

        return String(format: "OCR=%d°, dist=%.2f, power=%.1f (target 36.0)", detectedAngle, fusion.distanceUnits, power)
    }

    // MARK: - Test 8: Hiệu Năng & Độ Trễ Khứ Hồi Toàn Khung Hình 1920x886 + BSD UDP 127.0.0.1:45678 (< 35ms)

    private static func test8PerformanceAndUDPRoundTripLatency() throws -> String {
        var cfg = SyntheticSceneConfig()
        cfg.cameraStartNorm = 0.05
        cfg.cameraEndNorm = 0.515
        cfg.rulerTickNormXs = [0.10, 0.3325, 0.565, 0.7975]
        cfg.angleText = nil
        cfg.minimapDots = [
            MinimapDotSpec(normX: 0.255, groundY: 0.68, r: 22, g: 92, b: 245, widthPx: 7, heightPx: 9),
            MinimapDotSpec(normX: 0.790, groundY: 0.68, r: 242, g: 20, b: 20, widthPx: 7, heightPx: 7)
        ]

        let frame = try buildSyntheticFrame(cfg)
        let ciImage = CIImage(cgImage: frame)
        let vision = VisionProcessor()
        let engine = BallisticsEngine()

        // Làm nóng 1 khung hình CIContext duy nhất (mô phỏng trạng thái ổn định 30 FPS của SampleHandler).
        autoreleasepool {
            let b = cropTier1Battlefield(from: ciImage)
            let m = cropNativeROI(GunnyROIs.minimapStrip, from: ciImage)
            let r = cropNativeROI(GunnyROIs.minimapYellowRuler, from: ciImage)
            _ = vision.fuseMultiCueMeasurement(
                battlefieldCrop: b,
                minimapCrop: m,
                yellowRulerCrop: r,
                fallbackPlayerPos: nil,
                previousEnemyPos: nil,
                cachedScreenWidthNorm: VisionProcessor.defaultScreenWidthNorm
            )
        }

        let receiver = BSDUDPReceiver()
        let sender = BSDUDPSender()
        let semaphore = DispatchSemaphore(value: 0)
        let boxLock = NSLock()
        var received: TelemetryData?
        var receivedAt: CFAbsoluteTime = 0

        receiver.start(host: BSDUDPConfig.host, port: BSDUDPConfig.port) { packet in
            let ts = CFAbsoluteTimeGetCurrent()
            boxLock.lock()
            if received == nil {
                received = packet
                receivedAt = ts
                semaphore.signal()
            }
            boxLock.unlock()
        }
        defer { receiver.stop() }

        usleep(30_000)

        // Đo toàn bộ chu trình: Cắt ROI Tầng 1 + Tầng 2 + Tầng 3 -> Vision -> Ballistics -> JSON -> BSD UDP 127.0.0.1:45678 -> Nhận.
        let tStart = CFAbsoluteTimeGetCurrent()
        var builtTelemetry: TelemetryData?
        autoreleasepool {
            let battlefieldCG = cropTier1Battlefield(from: ciImage)
            let minimapCG = cropNativeROI(GunnyROIs.minimapStrip, from: ciImage)
            let rulerCG = cropNativeROI(GunnyROIs.minimapYellowRuler, from: ciImage)
            if let fusion = vision.fuseMultiCueMeasurement(
                battlefieldCrop: battlefieldCG,
                minimapCrop: minimapCG,
                yellowRulerCrop: rulerCG,
                fallbackPlayerPos: nil,
                previousEnemyPos: nil,
                cachedScreenWidthNorm: VisionProcessor.defaultScreenWidthNorm
            ) {
                let power = engine.calculatePower(
                    distanceUnits: fusion.distanceUnits,
                    angle: 46,
                    deltaYUnits: fusion.deltaYUnits
                )
                builtTelemetry = TelemetryData(
                    frameId: 88,
                    angle: 46,
                    distanceUnits: fusion.distanceUnits,
                    power: power
                )
            }
        }
        guard let sentTelemetry = builtTelemetry else {
            throw TestFailure(description: "Pipeline failed during Test 8 benchmark")
        }

        let visionDoneAt = CFAbsoluteTimeGetCurrent()
        sender.send(sentTelemetry, host: BSDUDPConfig.host, port: BSDUDPConfig.port)

        let waitResult = semaphore.wait(timeout: .now() + 1.0)
        try expect(waitResult == .success, "Timed out waiting for UDP packet on 127.0.0.1:45678")

        boxLock.lock()
        let finalPacket = received
        let finalReceivedAt = receivedAt
        boxLock.unlock()

        try expect(finalPacket == sentTelemetry, "UDP received packet mismatch: \(String(describing: finalPacket))")

        let visionMs = (visionDoneAt - tStart) * 1000.0
        let totalRoundTripMs = (finalReceivedAt - tStart) * 1000.0
        let payloadBytes = (try? JSONEncoder().encode(sentTelemetry).count) ?? 0

        try expect(totalRoundTripMs < 35.0, String(format: "End-to-end 1920x886 + UDP latency %.2fms exceeded 35ms target", totalRoundTripMs))

        return String(
            format: "1920x886 vision=%.2fms, totalRoundTrip=%.2fms (<35ms), payload=%d bytes",
            visionMs,
            totalRoundTripMs,
            payloadBytes
        )
    }
}
