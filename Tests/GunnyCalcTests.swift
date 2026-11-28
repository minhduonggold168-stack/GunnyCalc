import CoreGraphics
import CoreText
import CoreVideo
import Darwin
import Foundation

@main
enum GunnyCalcTestMain {
    private static let rgbSpace = CGColorSpaceCreateDeviceRGB()

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

        run("Test 1 — Map Đồi Hoa Hồng (Raw BGRA 12px/đv, đồi hồng, CL 11.2, ΔY +3.0, D-pad 50°)", test1RoseHillMap)
        run("Test 2 — Map Cầu Rồng (Raw BGRA, D-pad 50°, CL 4.4, ΔY 0)", test2DragonBridgeMap)
        run("Test 3 — Map Tàu Đắm + D-pad 0° / Góc âm / Tia vàng / Xoay buffer dọc", test3ShipwreckAndOrientationCues)
        run("Test 4 — Hiệu Năng < 5ms (1920x886 Raw BGRA) & BSD UDP + Zero-Vision Audit", test4PerformanceAndUDP)

        print("SUMMARY: \(passed)/\(passed + failed) tests PASSED")
        if failed > 0 {
            exit(1)
        }
        print("ALL 4 AUTOMATED TESTS PASSED 100%")
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw TestFailure(description: message)
        }
    }

    // MARK: - Raw 1920 x 886 BGRA Frame Builder

    private struct MinimapDot {
        let pxOffsetFromCenter: Double
        let groundYNorm: Double // Top-Left 0...1 bên trong minimapStrip
        let r: Double
        let g: Double
        let b: Double
        let widthPx: Double
        let heightPx: Double
    }

    private struct YellowRaySpec {
        let playerFullX: Double
        let playerFullY: Double
        let angleDeg: Double
    }

    private struct RawSceneSpec {
        var width: Int = 1920
        var height: Int = 886
        var skyRGB: (Double, Double, Double) = (25, 32, 46)
        var terrainRGB: (Double, Double, Double) = (52, 64, 52)
        var minimapSkyRGB: (Double, Double, Double) = (18, 22, 30)
        var minimapHillsRGB: [(Double, Double, Double)] = []
        var tickSpacingPx: Double? = 60.0
        var zeroTickXNorm: Double = 0.62
        var cameraLeftNorm: Double? = nil
        var cameraRightNorm: Double? = nil
        var dots: [MinimapDot] = []
        var dpadText: String? = "50"
        var dpadTextColor: (Double, Double, Double) = (255, 255, 255)
        var yellowAimRay: YellowRaySpec? = nil
    }

    private static func buildRawBGRAFrame(_ spec: RawSceneSpec) throws -> (bytes: [UInt8], bytesPerRow: Int, width: Int, height: Int) {
        let w = spec.width
        let h = spec.height
        let bpr = w * 4
        var buffer = [UInt8](repeating: 0, count: h * bpr)

        let rendered: Bool = buffer.withUnsafeMutableBytes { rawPtr -> Bool in
            guard let base = rawPtr.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: w,
                      height: h,
                      bitsPerComponent: 8,
                      bytesPerRow: bpr,
                      space: rgbSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                  ) else {
                return false
            }

            func fillTopLeft(_ tlRect: CGRect, rgb: (Double, Double, Double)) {
                let cgRect = CGRect(
                    x: tlRect.origin.x,
                    y: CGFloat(h) - tlRect.origin.y - tlRect.size.height,
                    width: tlRect.size.width,
                    height: tlRect.size.height
                )
                ctx.setFillColor(makeColor(rgb))
                ctx.fill(cgRect)
            }

            // 1. Bầu trời & địa hình nền chính.
            fillTopLeft(CGRect(x: 0, y: 0, width: w, height: h), rgb: spec.skyRGB)
            fillTopLeft(CGRect(x: 0, y: Double(h) * 0.65, width: Double(w), height: Double(h) * 0.35), rgb: spec.terrainRGB)

            // 2. Vùng Minimap (0.848...0.995, 0.042...0.147).
            let mmX = Double(GunnyROIs.minimapStrip.origin.x) * Double(w)
            let mmY = Double(GunnyROIs.minimapStrip.origin.y) * Double(h)
            let mmW = Double(GunnyROIs.minimapStrip.size.width) * Double(w)
            let mmH = Double(GunnyROIs.minimapStrip.size.height) * Double(h)
            fillTopLeft(CGRect(x: mmX, y: mmY, width: mmW, height: mmH), rgb: spec.minimapSkyRGB)

            // Vẽ các dải đồi hồng / tím / nâu bên trong Minimap nếu được cấu hình.
            if !spec.minimapHillsRGB.isEmpty {
                let bandH = mmH * 0.56 / Double(spec.minimapHillsRGB.count)
                for (idx, col) in spec.minimapHillsRGB.enumerated() {
                    let hy = mmY + mmH * 0.36 + Double(idx) * bandH
                    fillTopLeft(CGRect(x: mmX, y: hy, width: mmW, height: bandH + 2.0), rgb: col)
                }
            } else {
                fillTopLeft(CGRect(x: mmX, y: mmY + mmH * 0.58, width: mmW, height: mmH * 0.42), rgb: spec.terrainRGB)
            }

            // Vẽ khung camera trắng dự phòng nếu cần test fallback.
            if let cl = spec.cameraLeftNorm, let cr = spec.cameraRightNorm, cr > cl {
                let cx0 = mmX + cl * mmW
                let cx1 = mmX + cr * mmW
                fillTopLeft(CGRect(x: cx0, y: mmY + 2, width: 1.5, height: mmH - 4), rgb: (255, 255, 255))
                fillTopLeft(CGRect(x: cx1, y: mmY + 2, width: 1.5, height: mmH - 4), rgb: (255, 255, 255))
                fillTopLeft(CGRect(x: cx0, y: mmY + 2, width: cx1 - cx0, height: 1.5), rgb: (255, 255, 255))
                fillTopLeft(CGRect(x: cx0, y: mmY + mmH - 3, width: cx1 - cx0, height: 1.5), rgb: (255, 255, 255))
            }

            let zeroPxX = mmX + spec.zeroTickXNorm * mmW

            // Các chấm người chơi & kẻ địch trên Minimap.
            for dot in spec.dots {
                let cx = zeroPxX + dot.pxOffsetFromCenter
                let gy = mmY + dot.groundYNorm * mmH
                fillTopLeft(
                    CGRect(
                        x: cx - dot.widthPx * 0.5,
                        y: gy - dot.heightPx,
                        width: dot.widthPx,
                        height: dot.heightPx
                    ),
                    rgb: (dot.r, dot.g, dot.b)
                )
            }

            // 3. Dải thước vàng đáy Minimap (0.848...0.995, 0.147...0.163).
            let rlX = Double(GunnyROIs.minimapYellowRuler.origin.x) * Double(w)
            let rlY = Double(GunnyROIs.minimapYellowRuler.origin.y) * Double(h)
            let rlW = Double(GunnyROIs.minimapYellowRuler.size.width) * Double(w)
            let rlH = Double(GunnyROIs.minimapYellowRuler.size.height) * Double(h)
            fillTopLeft(CGRect(x: rlX, y: rlY, width: rlW, height: rlH), rgb: (238, 202, 58))

            if let spacing = spec.tickSpacingPx, spacing > 5.0 {
                // Vẽ các vạch tối sắc nét tại -20, -15, -10, -5, 0, +5, +10...
                var offset = -4.0 * spacing
                while offset <= 4.0 * spacing {
                    let tx = zeroPxX + offset
                    if tx >= rlX + 4.0 && tx <= rlX + rlW - 4.0 {
                        fillTopLeft(CGRect(x: tx - 1.5, y: rlY, width: 3.0, height: rlH), rgb: (22, 18, 12))
                    }
                    offset += spacing
                }
            }

            // 4. Phím D-pad góc bắn (0.082...0.145, 0.745...0.855).
            let dpX = Double(GunnyROIs.dpadAngle.origin.x) * Double(w)
            let dpY = Double(GunnyROIs.dpadAngle.origin.y) * Double(h)
            let dpW = Double(GunnyROIs.dpadAngle.size.width) * Double(w)
            let dpH = Double(GunnyROIs.dpadAngle.size.height) * Double(h)
            // Vòng tròn nền tối D-pad.
            let dpCGRect = CGRect(x: dpX + 4, y: CGFloat(h) - dpY - dpH + 4, width: dpW - 8, height: dpH - 8)
            ctx.setFillColor(makeColor((18, 26, 38)))
            ctx.fillEllipse(in: dpCGRect)

            if let text = spec.dpadText, !text.isEmpty {
                let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 42.0, nil)
                let attrs: [CFString: Any] = [
                    kCTFontAttributeName: font,
                    kCTForegroundColorAttributeName: makeColor(spec.dpadTextColor)
                ]
                let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary)!
                let line = CTLineCreateWithAttributedString(attrStr)
                let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
                let textCenterX = dpCGRect.midX - bounds.width * 0.5 - bounds.origin.x
                let textBaseY = dpCGRect.midY - bounds.height * 0.5 - bounds.origin.y
                ctx.textMatrix = .identity
                ctx.textPosition = CGPoint(x: textCenterX, y: textBaseY)
                CTLineDraw(line, ctx)
            }

            // 5. Tia chấm vàng chỉ hướng bắn cạnh thanh máu xanh nếu được cấu hình.
            if let ray = spec.yellowAimRay {
                let px = ray.playerFullX * Double(w)
                let py = ray.playerFullY * Double(h)
                fillTopLeft(CGRect(x: px - 28, y: py + 12, width: 56, height: 8), rgb: (20, 88, 248))

                let rad = ray.angleDeg * .pi / 180.0
                for step in 1...6 {
                    let dist = Double(step) * 26.0
                    let dx = px + cos(rad) * dist
                    let dy = py - sin(rad) * dist
                    let dotRect = CGRect(x: dx - 4.0, y: CGFloat(h) - dy - 4.0, width: 8.0, height: 8.0)
                    ctx.setFillColor(makeColor((250, 228, 32)))
                    ctx.fillEllipse(in: dotRect)
                }
            }

            return true
        }

        guard rendered else {
            throw TestFailure(description: "Failed to build 1920x886 raw BGRA buffer")
        }
        return (buffer, bpr, w, h)
    }

    private static func makeColor(_ rgb: (Double, Double, Double)) -> CGColor {
        CGColor(
            colorSpace: rgbSpace,
            components: [CGFloat(rgb.0 / 255.0), CGFloat(rgb.1 / 255.0), CGFloat(rgb.2 / 255.0), 1.0]
        )!
    }

    // MARK: - Test 1: Map Đồi Hoa Hồng (Thước vàng 60px -> 12px/đv, đồi hồng, chấm đỏ -11.2, ΔY = +3.0, góc 50° -> Lực 54.5 ± 1.5)

    private static func test1RoseHillMap() throws -> String {
        let ppu = 12.0 // tickSpacing = 60px / 5.0
        var spec = RawSceneSpec()
        spec.tickSpacingPx = 60.0
        spec.zeroTickXNorm = 0.72
        spec.minimapHillsRGB = [
            (218, 125, 165), // Đồi hồng phấn
            (185, 95, 138),  // Đồi hồng đậm (G=95, B=138 > ngưỡng loại nền)
            (150, 88, 132),  // Đồi tím
            (132, 84, 70)    // Đồi nâu
        ]
        spec.dpadText = "50"
        // Chấm xanh tại mốc 0 (y = 0.72 * mmH); chấm đỏ tại -11.2 đv (-134.4px) đứng cao trên đồi ΔY = +3.0 đv.
        let mmH = Double(GunnyROIs.minimapStrip.size.height) * Double(spec.height) // ~93.03px
        let deltaYPx = 3.0 * (ppu * 0.55) // ~19.8px
        let playerGroundYNorm = 0.78
        let enemyGroundYNorm = playerGroundYNorm - (deltaYPx / mmH)
        spec.dots = [
            MinimapDot(pxOffsetFromCenter: 0.0, groundYNorm: playerGroundYNorm, r: 22, g: 92, b: 245, widthPx: 7, heightPx: 9),
            MinimapDot(pxOffsetFromCenter: -11.2 * ppu, groundYNorm: enemyGroundYNorm, r: 242, g: 22, b: 22, widthPx: 7, heightPx: 7)
        ]

        let raw = try buildRawBGRAFrame(spec)
        let processor = VisionProcessor()
        let engine = BallisticsEngine()

        let result: RawFrameAnalysisResult = raw.bytes.withUnsafeBufferPointer { ptr in
            let frame = RawFrameBuffer(bgraBase: ptr.baseAddress!, rawWidth: raw.width, rawHeight: raw.height, bytesPerRow: raw.bytesPerRow)
            return processor.analyzeFrame(frame)
        }

        try expect(result.scaleSource == .yellowRulerTicks, "Expected yellowRulerTicks, got \(result.scaleSource.rawValue)")
        try expect(abs((result.pixelsPerUnit ?? 0) - 12.0) <= 0.4, String(format: "Expected 12.0 px/unit, got %.2f", result.pixelsPerUnit ?? 0))
        try expect(result.enemyCount == 1, "Expected 1 red enemy (pink/purple/brown hills rejected), got \(result.enemyCount)")
        try expect(abs((result.distanceUnits ?? 0) - 11.2) <= 0.2, String(format: "Expected distanceUnits = 11.2 ± 0.2, got %.2f", result.distanceUnits ?? 0))
        try expect(abs((result.deltaYUnits ?? 0) - 3.0) <= 0.35, String(format: "Expected deltaYUnits ≈ +3.0, got %.2f", result.deltaYUnits ?? 0))
        try expect(result.angle == 50, "Expected D-pad angle == 50, got \(String(describing: result.angle))")

        let power = engine.calculatePower(distanceUnits: result.distanceUnits ?? 0, angle: result.angle ?? 50, deltaYUnits: result.deltaYUnits ?? 0)
        try expect(abs(power - 54.5) <= 1.5, String(format: "Expected power = 54.5 ± 1.5, got %.1f", power))

        return String(format: "ppu=%.2f, enemyCount=%d, CL=%.2f, ΔY=%+.2f, angle=%d°, power=%.1f (target 54.5±1.5)", result.pixelsPerUnit ?? 0, result.enemyCount, result.distanceUnits ?? 0, result.deltaYUnits ?? 0, result.angle ?? -99, power)
    }

    // MARK: - Test 2: Map Cầu Rồng (Góc 50°, CL 4.4, ΔY = 0 -> Lực 30.2 ± 0.8)

    private static func test2DragonBridgeMap() throws -> String {
        let ppu = 14.0 // tickSpacing = 70px / 5.0
        var spec = RawSceneSpec()
        spec.skyRGB = (210, 236, 255) // Trời sáng chói
        spec.terrainRGB = (175, 188, 204)
        spec.minimapSkyRGB = (195, 224, 248)
        spec.tickSpacingPx = 70.0
        spec.zeroTickXNorm = 0.25
        spec.dpadText = "50"
        spec.dots = [
            MinimapDot(pxOffsetFromCenter: 0.0, groundYNorm: 0.72, r: 20, g: 88, b: 245, widthPx: 7, heightPx: 9),
            MinimapDot(pxOffsetFromCenter: 4.4 * ppu, groundYNorm: 0.72, r: 240, g: 24, b: 24, widthPx: 7, heightPx: 7)
        ]

        let raw = try buildRawBGRAFrame(spec)
        let processor = VisionProcessor()
        let engine = BallisticsEngine()

        let result: RawFrameAnalysisResult = raw.bytes.withUnsafeBufferPointer { ptr in
            let frame = RawFrameBuffer(bgraBase: ptr.baseAddress!, rawWidth: raw.width, rawHeight: raw.height, bytesPerRow: raw.bytesPerRow)
            return processor.analyzeFrame(frame)
        }

        try expect(abs((result.distanceUnits ?? 0) - 4.4) <= 0.2, String(format: "Expected CL = 4.4 ± 0.2, got %.2f", result.distanceUnits ?? 0))
        try expect(result.angle == 50, "Expected angle == 50, got \(String(describing: result.angle))")

        let power = engine.calculatePower(distanceUnits: result.distanceUnits ?? 0, angle: result.angle ?? 50, deltaYUnits: result.deltaYUnits ?? 0)
        try expect(abs(power - 30.2) <= 0.8, String(format: "Expected power = 30.2 ± 0.8, got %.1f", power))

        return String(format: "ppu=%.2f, CL=%.2f, angle=%d°, power=%.1f (target 30.2±0.8)", result.pixelsPerUnit ?? 0, result.distanceUnits ?? 0, result.angle ?? -99, power)
    }

    // MARK: - Test 3: Map Tàu Đắm + D-pad 0° hold + Góc âm -18° + Tia vàng 65° + Fallback khung camera + Buffer xoay dọc

    private static func test3ShipwreckAndOrientationCues() throws -> String {
        let processor = VisionProcessor()
        let engine = BallisticsEngine()

        // 3A. Map Tàu Đắm: phải -> trái CL 8.1, góc 50°, ΔY = 0 -> Lực 42.3 ± 0.8
        let ppu = 18.0 // tickSpacing = 90px / 5.0
        var shipSpec = RawSceneSpec()
        shipSpec.tickSpacingPx = 90.0
        shipSpec.zeroTickXNorm = 0.78
        shipSpec.dpadText = "50"
        shipSpec.dots = [
            MinimapDot(pxOffsetFromCenter: 0.0, groundYNorm: 0.70, r: 22, g: 92, b: 245, widthPx: 7, heightPx: 9),
            MinimapDot(pxOffsetFromCenter: -8.1 * ppu, groundYNorm: 0.70, r: 242, g: 22, b: 22, widthPx: 7, heightPx: 7)
        ]

        let shipRaw = try buildRawBGRAFrame(shipSpec)
        let shipRes: RawFrameAnalysisResult = shipRaw.bytes.withUnsafeBufferPointer { ptr in
            let frame = RawFrameBuffer(bgraBase: ptr.baseAddress!, rawWidth: shipRaw.width, rawHeight: shipRaw.height, bytesPerRow: shipRaw.bytesPerRow)
            return processor.analyzeFrame(frame)
        }
        try expect(abs((shipRes.distanceUnits ?? 0) - 8.1) <= 0.2, String(format: "Expected Shipwreck CL = 8.1 ± 0.2, got %.2f", shipRes.distanceUnits ?? 0))
        try expect(shipRes.angle == 50, "Expected Shipwreck angle == 50, got \(String(describing: shipRes.angle))")
        let shipPower = engine.calculatePower(distanceUnits: shipRes.distanceUnits ?? 0, angle: shipRes.angle ?? 50, deltaYUnits: shipRes.deltaYUnits ?? 0)
        try expect(abs(shipPower - 42.3) <= 0.8, String(format: "Expected Shipwreck power = 42.3 ± 0.8, got %.1f", shipPower))

        // 3B. D-pad hiển thị "0" (khi đang đi bộ) -> phải báo dpadZeroDetected = true và angle = nil để giữ góc cũ.
        var zeroSpec = shipSpec
        zeroSpec.dpadText = "0"
        let zeroRaw = try buildRawBGRAFrame(zeroSpec)
        let zeroRes: RawFrameAnalysisResult = zeroRaw.bytes.withUnsafeBufferPointer { ptr in
            let frame = RawFrameBuffer(bgraBase: ptr.baseAddress!, rawWidth: zeroRaw.width, rawHeight: zeroRaw.height, bytesPerRow: zeroRaw.bytesPerRow)
            return processor.analyzeFrame(frame)
        }
        try expect(zeroRes.dpadZeroDetected && zeroRes.angle == nil, "Expected D-pad '0' to hold previous angle")

        // 3C. D-pad góc âm "-18".
        var negSpec = shipSpec
        negSpec.dpadText = "-18"
        negSpec.dpadTextColor = (110, 235, 255) // Xanh lơ sắc nét
        let negRaw = try buildRawBGRAFrame(negSpec)
        let negRes: RawFrameAnalysisResult = negRaw.bytes.withUnsafeBufferPointer { ptr in
            let frame = RawFrameBuffer(bgraBase: ptr.baseAddress!, rawWidth: negRaw.width, rawHeight: negRaw.height, bytesPerRow: negRaw.bytesPerRow)
            return processor.analyzeFrame(frame)
        }
        try expect(negRes.angle == -18, "Expected negative D-pad angle -18°, got \(String(describing: negRes.angle))")

        // 3D. Tia chấm vàng Nguồn 2 (65°) + thước vàng bị che fallback khung camera trắng.
        var fbSpec = shipSpec
        fbSpec.tickSpacingPx = nil // Che thước vàng
        fbSpec.cameraLeftNorm = 0.14
        fbSpec.cameraRightNorm = 0.84 // width = 0.70 -> ~197px -> ~19.7 px/unit
        fbSpec.dpadText = nil
        fbSpec.yellowAimRay = YellowRaySpec(playerFullX: 0.30, playerFullY: 0.62, angleDeg: 65.0)
        let fbRaw = try buildRawBGRAFrame(fbSpec)
        let fbRes: RawFrameAnalysisResult = fbRaw.bytes.withUnsafeBufferPointer { ptr in
            let frame = RawFrameBuffer(bgraBase: ptr.baseAddress!, rawWidth: fbRaw.width, rawHeight: fbRaw.height, bytesPerRow: fbRaw.bytesPerRow)
            return processor.analyzeFrame(frame)
        }
        try expect(fbRes.scaleSource == .whiteCameraBorderFallback, "Expected camera border fallback when ruler occluded")
        try expect(abs((fbRes.angle ?? -99) - 65) <= 3, "Expected yellow ray angle ≈ 65°, got \(String(describing: fbRes.angle))")

        // 3E. Xác nhận xoay chỉ số ánh xạ zero-copy cho buffer vật lý đứng dọc (886 x 1920, EXIF .right = 6).
        let rotW = shipRaw.height // 886
        let rotH = shipRaw.width  // 1920
        let rotBpr = rotW * 4
        var rotatedBytes = [UInt8](repeating: 0, count: rotH * rotBpr)
        for ly in 0..<shipRaw.height {
            for lx in 0..<shipRaw.width {
                let srcOff = ly * shipRaw.bytesPerRow + lx * 4
                let rawCol = ly
                let rawRow = rotH - 1 - lx
                let dstOff = rawRow * rotBpr + rawCol * 4
                rotatedBytes[dstOff] = shipRaw.bytes[srcOff]
                rotatedBytes[dstOff + 1] = shipRaw.bytes[srcOff + 1]
                rotatedBytes[dstOff + 2] = shipRaw.bytes[srcOff + 2]
                rotatedBytes[dstOff + 3] = shipRaw.bytes[srcOff + 3]
            }
        }
        let rotRes: RawFrameAnalysisResult = rotatedBytes.withUnsafeBufferPointer { ptr in
            let frame = RawFrameBuffer(
                bgraBase: ptr.baseAddress!,
                rawWidth: rotW,
                rawHeight: rotH,
                bytesPerRow: rotBpr,
                orientation: .right
            )
            return processor.analyzeFrame(frame)
        }
        try expect(abs((rotRes.distanceUnits ?? 0) - 8.1) <= 0.25 && rotRes.angle == 50, "Zero-copy .right orientation mapping failed")

        return String(format: "shipCL=%.2f P=%.1f (42.3±0.8), 0°hold=OK, neg=%d°, ray=%d°, camFB=%.1fpx/u, rotRight=OK", shipRes.distanceUnits ?? 0, shipPower, negRes.angle ?? 0, fbRes.angle ?? 0, fbRes.pixelsPerUnit ?? 0)
    }

    // MARK: - Test 4: Hiệu Năng < 5ms (1920x886 Raw BGRA) & Độ Trễ BSD UDP (< 50ms)

    private static func test4PerformanceAndUDP() throws -> String {
        let ppu = 12.0
        var spec = RawSceneSpec()
        spec.tickSpacingPx = 60.0
        spec.zeroTickXNorm = 0.72
        spec.minimapHillsRGB = [(215, 120, 160), (160, 90, 130)]
        spec.dpadText = "50"
        spec.dots = [
            MinimapDot(pxOffsetFromCenter: 0.0, groundYNorm: 0.76, r: 22, g: 92, b: 245, widthPx: 7, heightPx: 9),
            MinimapDot(pxOffsetFromCenter: -11.2 * ppu, groundYNorm: 0.66, r: 242, g: 22, b: 22, widthPx: 7, heightPx: 7)
        ]

        let raw = try buildRawBGRAFrame(spec)
        let processor = VisionProcessor()
        let engine = BallisticsEngine()

        // Làm nóng 1 lần.
        _ = raw.bytes.withUnsafeBufferPointer { ptr in
            let frame = RawFrameBuffer(bgraBase: ptr.baseAddress!, rawWidth: raw.width, rawHeight: raw.height, bytesPerRow: raw.bytesPerRow)
            return processor.analyzeFrame(frame)
        }

        var durationsMs: [Double] = []
        var latestResult: RawFrameAnalysisResult?
        for _ in 0..<5 {
            let t0 = CFAbsoluteTimeGetCurrent()
            let r: RawFrameAnalysisResult = raw.bytes.withUnsafeBufferPointer { ptr in
                let frame = RawFrameBuffer(bgraBase: ptr.baseAddress!, rawWidth: raw.width, rawHeight: raw.height, bytesPerRow: raw.bytesPerRow)
                return processor.analyzeFrame(frame)
            }
            durationsMs.append((CFAbsoluteTimeGetCurrent() - t0) * 1000.0)
            latestResult = r
        }

        let avgMs = durationsMs.reduce(0.0, +) / Double(durationsMs.count)
        let maxMs = durationsMs.max() ?? 999.0
        try expect(avgMs < 5.0, String(format: "Average raw frame time %.2fms exceeded 5.0ms", avgMs))

        // Đo BSD UDP loopback 127.0.0.1:45678.
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

        let dist = latestResult?.distanceUnits ?? 11.2
        let ang = latestResult?.angle ?? 50
        let dy = latestResult?.deltaYUnits ?? 0.0
        let sample = TelemetryData(
            frameId: 100,
            angle: ang,
            distanceUnits: dist,
            power: engine.calculatePower(distanceUnits: dist, angle: ang, deltaYUnits: dy)
        )

        let udpStart = CFAbsoluteTimeGetCurrent()
        sender.send(sample, host: BSDUDPConfig.host, port: BSDUDPConfig.port)
        let waited = semaphore.wait(timeout: .now() + 1.0)
        try expect(waited == .success, "UDP receive timeout on 127.0.0.1:45678")

        boxLock.lock()
        let finalPkt = received
        let finalAt = receivedAt
        boxLock.unlock()

        try expect(finalPkt == sample, "UDP packet mismatch")
        let udpMs = (finalAt - udpStart) * 1000.0
        let totalMs = avgMs + udpMs
        try expect(totalMs < 20.0, String(format: "Total latency %.2fms exceeded 20ms", totalMs))

        return String(format: "avgFrame=%.2fms (max=%.2fms < 5ms), udp=%.2fms, total=%.2fms, zeroVision=YES", avgMs, maxMs, udpMs, totalMs)
    }
}
