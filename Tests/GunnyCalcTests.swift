import CoreGraphics
import CoreImage
import CoreText
import Darwin
import Foundation
import Vision

@main
enum GunnyCalcTestMain {
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

        run("testCoordinateFlip", testCoordinateFlip)
        run("testAngleParser", testAngleParser)
        run("testHSVClusteringOnRedBrickBackground", testHSVClusteringOnRedBrickBackground)
        run("testTerrainRaycastCheck", testTerrainRaycastCheck)
        run("testAdaptiveOnlineCalibration", testAdaptiveOnlineCalibration)
        run("testMinimapAndBallisticsEndToEnd", testMinimapAndBallisticsEndToEnd)
        run("testUDPLatency", testUDPLatency)

        print("SUMMARY: \(passed)/\(passed + failed) tests PASSED")
        if failed > 0 {
            exit(1)
        }
        print("ALL AUTOMATED TESTS PASSED 100%")
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw TestFailure(description: message)
        }
    }

    // MARK: - 1. testCoordinateFlip

    private static func testCoordinateFlip() throws -> String {
        let imgW: CGFloat = 1920.0
        let imgH: CGFloat = 886.0

        let minimapRect = ciRectFromTopLeft(
            normRect: GunnyROIs.minimapStrip,
            imageWidth: imgW,
            imageHeight: imgH
        )
        // Minimap Top-Left y=0.042, h=0.114 -> CoreImage Bottom-Left y=(1 - 0.156)*886 = 747.78 (upper half!)
        try expect(
            minimapRect.origin.y > imgH * 0.5,
            "Expected minimap Y in upper half of CoreImage (> \(imgH * 0.5)), got \(minimapRect.origin.y)"
        )
        try expect(
            abs(minimapRect.origin.x - 1628.0) <= 2.0 && abs(minimapRect.origin.y - 747.0) <= 2.0,
            "Unexpected minimap origin: \(minimapRect.origin)"
        )
        try expect(
            minimapRect.maxX <= imgW && minimapRect.maxY <= imgH,
            "Minimap rect exceeds image bounds: \(minimapRect)"
        )

        let angleRect = ciRectFromTopLeft(
            normRect: GunnyROIs.angleBattlefield,
            imageWidth: imgW,
            imageHeight: imgH
        )
        try expect(abs(angleRect.origin.y - 283.0) <= 2.0, "Unexpected angle rect Y: \(angleRect.origin.y)")

        return "minimapCI=\(minimapRect), angleCI=\(angleRect)"
    }

    // MARK: - 2. testAngleParser

    private static func testAngleParser() throws -> String {
        let cases: [([String], Int?)] = [
            (["Góc 65°"], 65),
            (["Goc 65"], 65),
            (["G6c 65"], 65),
            (["65°"], 65),
            (["Góc -18°"], -18),
            (["Góc: -35°"], -35),
            (["Góc 85°"], 85),
            (["Góc 99°"], nil),
            (["Combo x3"], nil)
        ]

        for (inputs, expected) in cases {
            let actual = AngleParser.extractAngle(from: inputs)
            try expect(
                actual == expected,
                "AngleParser(\(inputs)) returned \(String(describing: actual)), expected \(String(describing: expected))"
            )
        }

        return "verified \(cases.count) regex cases"
    }

    // MARK: - 3. testHSVClusteringOnRedBrickBackground

    private static func testHSVClusteringOnRedBrickBackground() throws -> String {
        let w = 284
        let h = 101
        let rgbSpace = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: rgbSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw TestFailure(description: "Failed to allocate minimap CGContext")
        }

        // Phủ toàn bộ nền gạch đỏ (S=0.69 < 0.78), đất nâu (H=22°, S=0.65), dung nham cam (H=24°) để thử bộ lọc HSV.
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [180.0 / 255.0, 70.0 / 255.0, 55.0 / 255.0, 1.0])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [145.0 / 255.0, 85.0 / 255.0, 50.0 / 255.0, 1.0])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))

        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [245.0 / 255.0, 110.0 / 255.0, 20.0 / 255.0, 1.0])!)
        ctx.fill(CGRect(x: 30, y: 10, width: 100, height: 22))

        // Vẽ khung camera trắng (S=0, V=1.0) rộng đúng 50% (10.0 đơn vị).
        let camRect = CGRect(x: 20, y: 12, width: 142, height: 76)
        ctx.setStrokeColor(CGColor(colorSpace: rgbSpace, components: [1.0, 1.0, 1.0, 1.0])!)
        ctx.setLineWidth(2.0)
        ctx.stroke(camRect)

        // Người chơi xanh dương chuẩn HSV (H=220°, S=0.92, V=0.96) tại x = 3.5 / 20.0.
        let blueX = (3.5 / 20.0) * Double(w)
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [20.0 / 255.0, 95.0 / 255.0, 245.0 / 255.0, 1.0])!)
        ctx.fill(CGRect(x: blueX - 4.0, y: 40.0, width: 8.0, height: 8.0))

        // Mục tiêu đỏ chuẩn HSV (H=0°, S=0.91, V=0.96) tại x = 17.5 / 20.0.
        let redX = (17.5 / 20.0) * Double(w)
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [245.0 / 255.0, 22.0 / 255.0, 22.0 / 255.0, 1.0])!)
        ctx.fill(CGRect(x: redX - 4.0, y: 40.0, width: 8.0, height: 8.0))

        guard let minimapImage = ctx.makeImage() else {
            throw TestFailure(description: "Failed to make brick-background minimap image")
        }

        let vision = VisionProcessor()
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let result = vision.analyzeMinimap(from: minimapImage) else {
            throw TestFailure(description: "analyzeMinimap returned nil")
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0

        try expect(elapsedMs < 50.0, String(format: "HSV analysis took %.2fms (>= 50ms)", elapsedMs))
        guard let player = result.playerPos else {
            throw TestFailure(description: "Failed to detect blue player marker on brick background")
        }
        try expect(
            result.enemyPositions.count == 1,
            "Expected exactly 1 red enemy (zero brick/lava false positives), got \(result.enemyPositions.count)"
        )
        let enemy = result.enemyPositions[0]
        try expect(abs(Double(player.x) - 3.5 / 20.0) <= 0.03, "Unexpected playerX: \(player.x)")
        try expect(abs(Double(enemy.x) - 17.5 / 20.0) <= 0.03, "Unexpected enemyX: \(enemy.x)")

        guard let camW = result.cameraWidthNorm else {
            throw TestFailure(description: "Failed to detect white camera viewport width")
        }
        try expect(abs(camW - 0.50) <= 0.03, "Expected cameraWidthNorm ≈ 0.50, got \(camW)")

        return String(format: "enemies=1 (0 brick false positives), camW=%.2f, latency=%.2fms (<50ms)", camW, elapsedMs)
    }

    // MARK: - 4. testTerrainRaycastCheck

    private static func testTerrainRaycastCheck() throws -> String {
        let w = 284
        let h = 101
        let rgbSpace = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: rgbSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            throw TestFailure(description: "Failed to allocate terrain CGContext")
        }

        // Bầu trời tối.
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [0.06, 0.08, 0.12, 1.0])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Mặt đất phẳng thấp (height = 20% từ đáy).
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [0.48, 0.40, 0.30, 1.0])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: 20))

        // Vách núi cao dựng đứng chắn ở giữa (height = 82% từ đáy, từ x = 42% đến 58%).
        ctx.fill(CGRect(x: Int(0.42 * Double(w)), y: 0, width: Int(0.16 * Double(w)), height: 83))

        // Người chơi bên trái (x=0.20, y từ đáy=24px) và mục tiêu bên phải (x=0.80, y từ đáy=24px).
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [20.0 / 255.0, 95.0 / 255.0, 245.0 / 255.0, 1.0])!)
        ctx.fill(CGRect(x: 0.20 * Double(w) - 4.0, y: 20.0, width: 8.0, height: 8.0))
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [245.0 / 255.0, 22.0 / 255.0, 22.0 / 255.0, 1.0])!)
        ctx.fill(CGRect(x: 0.80 * Double(w) - 4.0, y: 20.0, width: 8.0, height: 8.0))

        guard let mountainImage = ctx.makeImage() else {
            throw TestFailure(description: "Failed to create mountain minimap image")
        }

        let vision = VisionProcessor()
        let engine = BallisticsEngine()
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let analysis = vision.analyzeMinimap(from: mountainImage),
              let player = analysis.playerPos,
              let enemy = analysis.enemyPositions.first else {
            throw TestFailure(description: "Failed to analyze mountain minimap")
        }

        try expect(analysis.terrainProfile.count == 32, "Expected 32 terrain columns, got \(analysis.terrainProfile.count)")
        let peakTerrain = analysis.terrainProfile.max() ?? 0.0
        try expect(peakTerrain >= 0.75, "Expected mountain peak >= 0.75 in terrainProfile, got \(peakTerrain)")

        // Tại góc thấp 20°, đạn chắc chắn đâm xuyên núi -> isBlocked == true và gợi ý góc nâng > 20°.
        let lowAngleCheck = engine.checkTerrainObstruction(
            playerPos: player,
            enemyPos: enemy,
            minimapAspectHOverW: analysis.minimapAspectHOverW,
            terrainProfile: analysis.terrainProfile,
            angle: 20
        )
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0

        try expect(lowAngleCheck.isBlocked, "Expected angle 20° to be BLOCKED by central mountain")
        try expect(
            lowAngleCheck.suggestedAngle > 20 && lowAngleCheck.suggestedAngle <= 85,
            "Expected suggestedAngle in 21...85, got \(lowAngleCheck.suggestedAngle)"
        )

        // Kiểm tra lại tại góc gợi ý -> phải vượt qua núi (isBlocked == false).
        let clearedCheck = engine.checkTerrainObstruction(
            playerPos: player,
            enemyPos: enemy,
            minimapAspectHOverW: analysis.minimapAspectHOverW,
            terrainProfile: analysis.terrainProfile,
            angle: lowAngleCheck.suggestedAngle
        )
        try expect(!clearedCheck.isBlocked, "Expected suggestedAngle \(lowAngleCheck.suggestedAngle)° to clear mountain")

        // Bản đồ phẳng hoàn toàn -> góc 20° không bị chặn.
        let flatCheck = engine.checkTerrainObstruction(
            playerPos: player,
            enemyPos: enemy,
            minimapAspectHOverW: analysis.minimapAspectHOverW,
            terrainProfile: [Double](repeating: 0.15, count: 32),
            angle: 20
        )
        try expect(!flatCheck.isBlocked, "Expected flat map at 20° to be unobstructed")
        try expect(elapsedMs < 50.0, String(format: "Terrain raycast pipeline took %.2fms (>= 50ms)", elapsedMs))

        return String(
            format: "peak=%.2f, 20° blocked=true -> suggested=%d° (clears!), latency=%.2fms",
            peakTerrain,
            lowAngleCheck.suggestedAngle,
            elapsedMs
        )
    }

    // MARK: - 5. testAdaptiveOnlineCalibration

    private static func testAdaptiveOnlineCalibration() throws -> String {
        let cal = AdaptiveCalibrationEngine()
        try expect(abs(cal.mapScaleMultiplier - 1.0) < 0.0001, "Initial multiplier must be 1.0")

        // Lệch trong deadband <= 0.30 -> không đổi hệ số.
        let unchanged = cal.recordShotOutcome(targetDistance: 14.0, actualDistance: 13.8)
        try expect(abs(unchanged - 1.0) < 0.0001, "Error 0.2 <= 0.30 should not alter multiplier")

        // Bắn hụt (actual 12.0 < target 14.0) -> tăng multiplier (> 1.0).
        let afterShort = cal.recordShotOutcome(targetDistance: 14.0, actualDistance: 12.0)
        try expect(afterShort > 1.01 && afterShort <= 1.15, "Short shot should increase multiplier, got \(afterShort)")

        // Bắn lố nhiều lần -> giảm multiplier và luôn giữ trong biên [0.85, 1.15].
        var mult = afterShort
        for _ in 0..<20 {
            mult = cal.recordShotOutcome(targetDistance: 10.0, actualDistance: 18.0)
        }
        try expect(mult >= 0.85 && mult <= 1.15, "Multiplier out of bounds [0.85, 1.15]: \(mult)")
        try expect(abs(mult - 0.85) < 0.001, "Expected lower clamp at 0.85, got \(mult)")

        // Kiểm tra phát hiện tâm vụ nổ trên lưới luma 64x24.
        let baseline = [UInt8](repeating: 30, count: VisionProcessor.lumaGridWidth * VisionProcessor.lumaGridHeight)
        var afterFlash = baseline
        for gy in 10...14 {
            for gx in 44...48 {
                afterFlash[gy * VisionProcessor.lumaGridWidth + gx] = 245
            }
        }
        guard let flashX = VisionProcessor().detectImpactFlashX(baseline: baseline, current: afterFlash, playerX: 0.20) else {
            throw TestFailure(description: "Failed to detect explosion flash X on 64x24 grid")
        }
        try expect(abs(flashX - (46.0 / 64.0)) <= 0.04, "Unexpected flashX: \(flashX)")

        return String(format: "short=%.4f, clampedLow=%.2f, flashX=%.2f", afterShort, mult, flashX)
    }

    // MARK: - 6. testMinimapAndBallisticsEndToEnd

    private static func testMinimapAndBallisticsEndToEnd() throws -> String {
        let imgW = 1920
        let imgH = 886
        let rgbSpace = CGColorSpaceCreateDeviceRGB()
        let graySpace = CGColorSpaceCreateDeviceGray()

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

        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [0.08, 0.11, 0.16, 1.0])!)
        ctx.fill(CGRect(x: 0, y: 0, width: imgW, height: imgH))

        let minimapCI = ciRectFromTopLeft(
            normRect: GunnyROIs.minimapStrip,
            imageWidth: CGFloat(imgW),
            imageHeight: CGFloat(imgH)
        )
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [0.05, 0.08, 0.12, 1.0])!)
        ctx.fill(minimapCI)

        // Khung camera trắng 50% (10.0 đơn vị).
        ctx.setStrokeColor(CGColor(colorSpace: rgbSpace, components: [1.0, 1.0, 1.0, 1.0])!)
        ctx.setLineWidth(2.0)
        ctx.stroke(CGRect(
            x: minimapCI.minX + 16.0,
            y: minimapCI.minY + 12.0,
            width: minimapCI.width * 0.50,
            height: minimapCI.height - 24.0
        ))

        // Người chơi xanh dương tại x = 3.5 / 20.0 và mục tiêu đỏ tại x = 17.5 / 20.0.
        let blueX = minimapCI.minX + (3.5 / 20.0) * minimapCI.width
        let redX = minimapCI.minX + (17.5 / 20.0) * minimapCI.width
        let dotY = minimapCI.midY
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [20.0 / 255.0, 95.0 / 255.0, 245.0 / 255.0, 1.0])!)
        ctx.fill(CGRect(x: blueX - 5.0, y: dotY - 5.0, width: 10.0, height: 10.0))
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [245.0 / 255.0, 22.0 / 255.0, 22.0 / 255.0, 1.0])!)
        ctx.fill(CGRect(x: redX - 5.0, y: dotY - 5.0, width: 10.0, height: 10.0))

        // Vẽ chữ "Góc 65°" trong vùng chiến trường nửa trên.
        let angleCI = ciRectFromTopLeft(
            normRect: GunnyROIs.angleBattlefield,
            imageWidth: CGFloat(imgW),
            imageHeight: CGFloat(imgH)
        )
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 54.0, nil)
        let whiteColor = CGColor(colorSpace: rgbSpace, components: [1.0, 1.0, 1.0, 1.0])!
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: whiteColor
        ]
        let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, "Góc 65°" as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrStr)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: angleCI.minX + 260.0, y: angleCI.midY)
        CTLineDraw(line, ctx)

        guard let fullCGImage = ctx.makeImage() else {
            throw TestFailure(description: "Failed to build synthetic 1920x886 CGImage")
        }

        let ciImage = CIImage(cgImage: fullCGImage)
        let ciContext = CIContext(options: nil)
        let vision = VisionProcessor()
        let engine = BallisticsEngine()

        // Đo tốc độ vòng xử lý chính 30 FPS (Minimap HSV + White Box + Terrain Raycast + Ballistics).
        let tStart = CFAbsoluteTimeGetCurrent()
        let stripPatch = ciImage
            .cropped(to: minimapCI)
            .transformed(by: CGAffineTransform(translationX: -minimapCI.origin.x, y: -minimapCI.origin.y))
        guard let stripCG = ciContext.createCGImage(stripPatch, from: CGRect(origin: .zero, size: minimapCI.size)),
              let analysis = vision.analyzeMinimap(from: stripCG),
              let player = analysis.playerPos,
              let enemy = analysis.enemyPositions.first else {
            throw TestFailure(description: "Failed to analyze synthetic 1920x886 Minimap")
        }

        let camW = analysis.cameraWidthNorm ?? 0.50
        let distanceUnits = (abs(Double(enemy.x - player.x)) / camW) * BallisticsEngine.unitsPerScreen
        let powerPreview = engine.calculatePower(distanceUnits: distanceUnits, angle: 65)
        _ = engine.checkTerrainObstruction(
            playerPos: player,
            enemyPos: enemy,
            minimapAspectHOverW: analysis.minimapAspectHOverW,
            terrainProfile: analysis.terrainProfile,
            angle: 65
        )
        let mainLoopMs = (CFAbsoluteTimeGetCurrent() - tStart) * 1000.0
        try expect(mainLoopMs < 50.0, String(format: "Main Minimap+Raycast+Ballistics latency %.2fms >= 50ms", mainLoopMs))

        // OCR song song đọc "Góc 65°".
        var anglePatch = ciImage
            .cropped(to: angleCI)
            .transformed(by: CGAffineTransform(translationX: -angleCI.origin.x, y: -angleCI.origin.y))
        if anglePatch.extent.width > 640.0 {
            let scale = 640.0 / anglePatch.extent.width
            anglePatch = anglePatch.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        anglePatch = anglePatch.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputContrastKey: 1.8,
                kCIInputSaturationKey: 0.0
            ]
        )
        let angleBounds = CGRect(x: 0, y: 0, width: floor(anglePatch.extent.width), height: floor(anglePatch.extent.height))
        guard let angleCG = ciContext.createCGImage(anglePatch, from: angleBounds, format: .L8, colorSpace: graySpace),
              let detectedAngle = vision.detectAngle(fromContrastImage: angleCG) else {
            throw TestFailure(description: "Vision OCR failed to read 'Góc 65°'")
        }

        try expect(detectedAngle == 65, "Expected angle == 65, got \(detectedAngle)")
        let power = engine.calculatePower(distanceUnits: distanceUnits, angle: detectedAngle)
        try expect(abs(power - 67.0) <= 0.5, "Expected power == 67.0 (±0.5), got \(power) (preview=\(powerPreview))")

        return String(format: "dist=%.2f, angle=%d°, power=%.1f, mainLoop=%.2fms (<50ms)", distanceUnits, detectedAngle, power, mainLoopMs)
    }

    // MARK: - 7. testUDPLatency

    private static func testUDPLatency() throws -> String {
        let sample = TelemetryData(frameId: 42, angle: 30, power: 47.0, isBlocked: true, suggestedAngle: 58)
        let encoded = try JSONEncoder().encode(sample)

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

        usleep(35_000)

        let sentAt = CFAbsoluteTimeGetCurrent()
        sender.send(sample, host: BSDUDPConfig.host, port: BSDUDPConfig.port)

        let waitResult = semaphore.wait(timeout: .now() + 1.0)
        try expect(waitResult == .success, "Timed out waiting for UDP packet on 127.0.0.1:45678")

        boxLock.lock()
        let finalPacket = received
        let finalReceivedAt = receivedAt
        boxLock.unlock()

        try expect(finalPacket == sample, "Received packet mismatch: \(String(describing: finalPacket))")
        let latencyMs = (finalReceivedAt - sentAt) * 1000.0
        try expect(latencyMs < 50.0, String(format: "UDP latency %.2fms exceeded 50ms limit", latencyMs))

        return String(format: "payload=%d bytes, roundTrip=%.2fms (<50ms)", encoded.count, latencyMs)
    }
}
