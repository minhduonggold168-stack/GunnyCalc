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
        run("testMinimapAndBallistics", testMinimapAndBallistics)
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
        // Minimap Top-Left y=0.045, h=0.095 -> CoreImage Bottom-Left y=(1 - 0.14)*886 = 761.96 (upper half!)
        try expect(
            minimapRect.origin.y > imgH * 0.5,
            "Expected minimap Y in upper half of CoreImage (> \(imgH * 0.5)), got \(minimapRect.origin.y)"
        )
        try expect(
            abs(minimapRect.origin.x - 1628.0) <= 2.0 && abs(minimapRect.origin.y - 761.0) <= 2.0,
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
        // Angle Top-Left y=0.14, h=0.54 -> CoreImage Bottom-Left y=(1 - 0.68)*886 = 283.52
        try expect(
            abs(angleRect.origin.y - 283.0) <= 2.0,
            "Unexpected angle rect Y: \(angleRect.origin.y)"
        )

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

        return "verified \(cases.count) regex cases (65, 65, 65, 65, -18, bounds)"
    }

    // MARK: - 3. testMinimapAndBallistics

    private static func testMinimapAndBallistics() throws -> String {
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

        // Nền chiến trường tối giả lập màn hình ngang 1920x886.
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [0.08, 0.11, 0.16, 1.0])!)
        ctx.fill(CGRect(x: 0, y: 0, width: imgW, height: imgH))

        let minimapCI = ciRectFromTopLeft(
            normRect: GunnyROIs.minimapStrip,
            imageWidth: CGFloat(imgW),
            imageHeight: CGFloat(imgH)
        )
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [0.05, 0.08, 0.12, 1.0])!)
        ctx.fill(minimapCI)

        // Cụm xanh dương đậm người chơi tại x = 3.5 / 20.0 trong Minimap (B > 165, B-R > 75, B-G > 55).
        let blueX = minimapCI.minX + (3.5 / 20.0) * minimapCI.width
        let dotY = minimapCI.midY
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [20.0 / 255.0, 90.0 / 255.0, 245.0 / 255.0, 1.0])!)
        ctx.fill(CGRect(x: blueX - 5.0, y: dotY - 5.0, width: 10.0, height: 10.0))

        // Cụm đỏ mục tiêu tại x = 17.5 / 20.0 trong Minimap (R > 155, R-G > 55, R-B > 55).
        let redX = minimapCI.minX + (17.5 / 20.0) * minimapCI.width
        ctx.setFillColor(CGColor(colorSpace: rgbSpace, components: [240.0 / 255.0, 30.0 / 255.0, 30.0 / 255.0, 1.0])!)
        ctx.fill(CGRect(x: redX - 5.0, y: dotY - 5.0, width: 10.0, height: 10.0))

        // Vẽ chữ "Góc 65°" sắc nét trong vùng chiến trường nửa trên.
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

        // 1. Kiểm thử cắt Minimap bằng ciRectFromTopLeft & tính khoảng cách 14.0 đơn vị.
        let stripPatch = ciImage
            .cropped(to: minimapCI)
            .transformed(by: CGAffineTransform(translationX: -minimapCI.origin.x, y: -minimapCI.origin.y))
        guard let stripCG = ciContext.createCGImage(stripPatch, from: CGRect(origin: .zero, size: minimapCI.size)),
              let positions = vision.detectMinimapStripPositions(from: stripCG),
              let playerX = positions.playerX,
              let enemyX = positions.enemyXs.first else {
            throw TestFailure(description: "Failed to detect blue player and red enemy in synthetic Minimap")
        }

        let distanceUnits = abs(enemyX - playerX) * BallisticsEngine.minimapTotalUnits
        try expect(
            abs(distanceUnits - 14.0) <= 0.35,
            "Expected distanceUnits ≈ 14.0, got \(distanceUnits) (playerX=\(playerX), enemyX=\(enemyX))"
        )

        // 2. Kiểm thử cắt góc bằng ciRectFromTopLeft + CIColorControls (contrast 1.8, saturation 0.0) + Vision .accurate.
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
            throw TestFailure(description: "Vision OCR failed to read 'Góc 65°' from synthetic battlefield image")
        }

        try expect(detectedAngle == 65, "Expected angle == 65, got \(detectedAngle)")

        // 3. Kiểm thử bảng lực chuẩn NPH: d=14.0, angle=65° -> power == 67.0 (±0.5).
        let power = BallisticsEngine().calculatePower(distanceUnits: distanceUnits, angle: detectedAngle)
        try expect(
            abs(power - 67.0) <= 0.5,
            "Expected power == 67.0 (±0.5), got \(power) at distance=\(distanceUnits), angle=\(detectedAngle)"
        )

        return String(format: "distance=%.2f, angle=%d°, power=%.1f (target 67.0 ± 0.5)", distanceUnits, detectedAngle, power)
    }

    // MARK: - 4. testUDPLatency

    private static func testUDPLatency() throws -> String {
        let sample = TelemetryData(frameId: 42, angle: 65, power: 67.0)
        let encoded = try JSONEncoder().encode(sample)
        try expect(
            encoded.count < 50,
            "Expected TelemetryData JSON < 50 bytes, got \(encoded.count) bytes"
        )

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

        // Chờ luồng nhận vào trạng thái recvfrom.
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

        return String(format: "payload=%d bytes (<50), roundTrip=%.2fms (<50ms)", encoded.count, latencyMs)
    }
}
