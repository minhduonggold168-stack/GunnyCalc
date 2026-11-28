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
        run("testShipwreckMap", testShipwreckMap)
        run("testWideMap", testWideMap)
        run("testYellowRulerFallback", testYellowRulerFallback)
        run("testElevationAnd80DegTable", testElevationAnd80DegTable)
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
        try expect(minimapRect.origin.y > imgH * 0.5, "Expected minimap Y in upper half of CoreImage")
        try expect(abs(minimapRect.origin.x - 1628.0) <= 2.0 && abs(minimapRect.origin.y - 747.0) <= 2.0, "Unexpected minimap origin: \(minimapRect.origin)")

        let rulerRect = ciRectFromTopLeft(
            normRect: GunnyROIs.minimapYellowRuler,
            imageWidth: imgW,
            imageHeight: imgH
        )
        try expect(rulerRect.origin.y > imgH * 0.5 && rulerRect.origin.y < minimapRect.maxY, "Unexpected yellow ruler rect: \(rulerRect)")

        return "minimapCI=\(minimapRect), rulerCI=\(rulerRect)"
    }

    // MARK: - 2. testAngleParser

    private static func testAngleParser() throws -> String {
        let cases: [([String], Int?)] = [
            (["Góc 50°"], 50),
            (["Góc 46°"], 46),
            (["Góc 65°"], 65),
            (["Goc 65"], 65),
            (["G6c 65"], 65),
            (["65°"], 65),
            (["Góc -18°"], -18),
            (["Góc 99°"], nil)
        ]
        for (inputs, expected) in cases {
            let actual = AngleParser.extractAngle(from: inputs)
            try expect(actual == expected, "AngleParser(\(inputs))=\(String(describing: actual)), expected \(String(describing: expected))")
        }
        return "verified \(cases.count) regex cases"
    }

    // MARK: - Shared Synthetic Map Builder (1920x886)

    private static func runSyntheticMapTest(
        cameraStartNorm: Double,
        cameraEndNorm: Double,
        playerNormX: Double,
        enemyNormX: Double,
        angleText: String,
        expectedAngle: Int,
        expectedDistance: Double,
        expectedPower: Double
    ) throws -> String {
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

        // Nền chiến trường tối.
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [0.08, 0.10, 0.14, 1.0])!)
        ctx.fill(CGRect(x: 0, y: 0, width: imgW, height: imgH))

        // Vùng Minimap với nền ngoài tối (lum ~38) và vùng camera sáng (> +15% độ sáng, lum ~108).
        let minimapCI = ciRectFromTopLeft(
            normRect: GunnyROIs.minimapStrip,
            imageWidth: CGFloat(imgW),
            imageHeight: CGFloat(imgH)
        )
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [32.0 / 255.0, 38.0 / 255.0, 46.0 / 255.0, 1.0])!)
        ctx.fill(minimapCI)

        let camX = minimapCI.minX + CGFloat(cameraStartNorm) * minimapCI.width
        let camW = CGFloat(cameraEndNorm - cameraStartNorm) * minimapCI.width
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [98.0 / 255.0, 108.0 / 255.0, 122.0 / 255.0, 1.0])!)
        ctx.fill(CGRect(x: camX, y: minimapCI.minY, width: camW, height: minimapCI.height))

        // Viền khung camera trắng mảnh.
        ctx.setStrokeColor(CGColor(colorSpace: rgbSpace, components: [0.95, 0.95, 0.95, 1.0])!)
        ctx.setLineWidth(1.5)
        ctx.stroke(CGRect(x: camX, y: minimapCI.minY + 4, width: camW, height: minimapCI.height - 8))

        // Chấm xanh dương thuần người chơi (B > 190, R < 80, G < 135, B-R > 125).
        let blueX = minimapCI.minX + CGFloat(playerNormX) * minimapCI.width
        let dotY = minimapCI.minY + minimapCI.height * 0.40
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [20.0 / 255.0, 90.0 / 255.0, 245.0 / 255.0, 1.0])!)
        ctx.fill(CGRect(x: blueX - 4.0, y: dotY - 4.0, width: 8.0, height: 8.0))

        // Chấm đỏ tươi thuần mục tiêu (R > 190, G < 70, B < 70, R-G > 135, R-B > 135).
        let redX = minimapCI.minX + CGFloat(enemyNormX) * minimapCI.width
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [240.0 / 255.0, 25.0 / 255.0, 25.0 / 255.0, 1.0])!)
        ctx.fill(CGRect(x: redX - 4.0, y: dotY - 4.0, width: 8.0, height: 8.0))

        // Vẽ chữ góc trong vùng chiến trường nửa trên.
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
        let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, angleText as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrStr)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: angleCI.minX + 260.0, y: angleCI.midY)
        CTLineDraw(line, ctx)

        guard let fullCG = ctx.makeImage() else {
            throw TestFailure(description: "Failed to build synthetic 1920x886 CGImage")
        }

        let ciImage = CIImage(cgImage: fullCG)
        let ciContext = CIContext(options: nil)
        let vision = VisionProcessor()
        let engine = BallisticsEngine()

        // 1. Chạy thuật toán đọc Minimap + đo screenWidthNorm động.
        let t0 = CFAbsoluteTimeGetCurrent()
        let stripPatch = ciImage
            .cropped(to: minimapCI)
            .transformed(by: CGAffineTransform(translationX: -minimapCI.origin.x, y: -minimapCI.origin.y))
        guard let stripCG = ciContext.createCGImage(stripPatch, from: CGRect(origin: .zero, size: minimapCI.size)),
              let analysis = vision.analyzeMinimap(minimapCrop: stripCG),
              let player = analysis.playerPos,
              let enemy = analysis.enemyPos,
              let screenWidthNorm = analysis.screenWidthNorm else {
            throw TestFailure(description: "Failed to measure player, enemy, or bright camera viewport width")
        }

        let distanceUnits = (abs(Double(enemy.x - player.x)) / screenWidthNorm) * BallisticsEngine.unitsPerScreen
        let deltaYUnits = (Double(player.y - enemy.y) / screenWidthNorm) * BallisticsEngine.unitsPerScreen
        let minimapMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0

        let expectedCamW = cameraEndNorm - cameraStartNorm
        try expect(
            abs(screenWidthNorm - expectedCamW) <= 0.03,
            String(format: "Expected screenWidthNorm ≈ %.3f, got %.3f", expectedCamW, screenWidthNorm)
        )
        try expect(
            abs(distanceUnits - expectedDistance) <= 0.3,
            String(format: "Expected distanceUnits = %.1f ± 0.3, got %.2f", expectedDistance, distanceUnits)
        )
        try expect(minimapMs < 50.0, String(format: "Minimap processing %.2fms >= 50ms", minimapMs))

        // 2. Chạy OCR đọc góc.
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
            throw TestFailure(description: "OCR failed to read '\(angleText)'")
        }
        try expect(detectedAngle == expectedAngle, "Expected angle \(expectedAngle)°, got \(detectedAngle)°")

        // 3. Tính lực chuẩn NPH.
        let power = engine.calculatePower(
            distanceUnits: distanceUnits,
            angle: detectedAngle,
            deltaYUnits: deltaYUnits
        )
        try expect(
            abs(power - expectedPower) <= 1.5,
            String(format: "Expected power = %.1f ± 1.5, got %.1f (dist=%.2f, angle=%d°)", expectedPower, power, distanceUnits, detectedAngle)
        )

        return String(
            format: "camW=%.3f, dist=%.2f (target %.1f), angle=%d°, power=%.1f (target %.1f), latency=%.2fms",
            screenWidthNorm,
            distanceUnits,
            expectedDistance,
            detectedAngle,
            power,
            expectedPower,
            minimapMs
        )
    }

    // MARK: - 3. testShipwreckMap (Map Tàu Đắm: camera 70%, x_player=0.69, x_enemy=0.12, góc 50° -> CL 8.1, Lực ~42.5)

    private static func testShipwreckMap() throws -> String {
        try runSyntheticMapTest(
            cameraStartNorm: 0.17,
            cameraEndNorm: 0.87,
            playerNormX: 0.69,
            enemyNormX: 0.12,
            angleText: "Góc 50°",
            expectedAngle: 50,
            expectedDistance: 8.1,
            expectedPower: 42.5
        )
    }

    // MARK: - 4. testWideMap (Map Rộng: camera 46.5%, x_player=0.255, x_enemy=0.790, góc 46° -> CL 11.5, Lực ~51.4)

    private static func testWideMap() throws -> String {
        try runSyntheticMapTest(
            cameraStartNorm: 0.05,
            cameraEndNorm: 0.515,
            playerNormX: 0.255,
            enemyNormX: 0.790,
            angleText: "Góc 46°",
            expectedAngle: 46,
            expectedDistance: 11.5,
            expectedPower: 51.4
        )
    }

    // MARK: - 5. testYellowRulerFallback (Cách 2: vạch chia tối 5 đơn vị trên thước vàng đáy Minimap)

    private static func testYellowRulerFallback() throws -> String {
        let w = 284
        let h = 14
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
            throw TestFailure(description: "Failed to allocate yellow ruler CGContext")
        }

        // Nền thước vàng sáng.
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [235.0 / 255.0, 200.0 / 255.0, 65.0 / 255.0, 1.0])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Vẽ 3 vạch chia tối màu cách đều 0.35 (5.0 đơn vị -> 10.0 đơn vị = 0.70).
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [25.0 / 255.0, 20.0 / 255.0, 15.0 / 255.0, 1.0])!)
        for normX in [0.15, 0.50, 0.85] {
            let tx = normX * Double(w)
            ctx.fill(CGRect(x: tx - 1.5, y: 0, width: 3.0, height: Double(h)))
        }

        guard let rulerImg = ctx.makeImage(),
              let measured = VisionProcessor().detectYellowRulerScreenWidthNorm(from: rulerImg) else {
            throw TestFailure(description: "Failed to measure screenWidthNorm from yellow ruler ticks")
        }

        try expect(abs(measured - 0.70) <= 0.03, String(format: "Expected 0.70 from ruler ticks, got %.3f", measured))
        return String(format: "rulerFallback screenWidthNorm=%.3f (target 0.700)", measured)
    }

    // MARK: - 6. testElevationAnd80DegTable

    private static func testElevationAnd80DegTable() throws -> String {
        let engine = BallisticsEngine()
        let p80d10 = engine.calculatePower(distanceUnits: 10.0, angle: 80, deltaYUnits: 0.0)
        try expect(abs(p80d10 - 93.0) <= 0.1, "Expected 80° d=10 -> 93.0, got \(p80d10)")

        let p50High = engine.calculatePower(distanceUnits: 10.0, angle: 50, deltaYUnits: 2.0)
        try expect(abs(p50High - 49.2) <= 0.1, "Expected 50° d=10 dy=+2 -> 49.2, got \(p50High)")

        let p50Low = engine.calculatePower(distanceUnits: 10.0, angle: 50, deltaYUnits: -2.0)
        try expect(abs(p50Low - 46.8) <= 0.1, "Expected 50° d=10 dy=-2 -> 46.8, got \(p50Low)")

        return "80°@10=\(p80d10), 50°@10(dy+2)=\(p50High), 50°@10(dy-2)=\(p50Low)"
    }

    // MARK: - 7. testUDPLatency

    private static func testUDPLatency() throws -> String {
        let sample = TelemetryData(frameId: 42, angle: 50, distanceUnits: 8.1, power: 42.4)
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
