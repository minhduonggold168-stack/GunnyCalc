import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Kết quả phân tích hình ảnh từ 3 vùng ROI (`minimapRect`, `windRect`, `angleRect`).
public struct VisionObservationResult: Equatable, Sendable {
    public let dx: Double
    public let dy: Double
    public let wind: Double?
    public let angle: Double?
    public let hasValidMinimap: Bool

    public init(
        dx: Double,
        dy: Double,
        wind: Double?,
        angle: Double?,
        hasValidMinimap: Bool
    ) {
        self.dx = dx
        self.dy = dy
        self.wind = wind
        self.angle = angle
        self.hasValidMinimap = hasValidMinimap
    }
}

/// Kết quả tìm tọa độ tâm cụm điểm xanh dương (người chơi) và đỏ (mục tiêu) trên minimap.
public struct MinimapCentroids: Equatable, Sendable {
    public let dx: Double
    public let dy: Double
    public let blueCentroid: CGPoint
    public let redCentroid: CGPoint
    public let bluePixelCount: Int
    public let redPixelCount: Int
}

/// Bộ xử lý hình ảnh tối ưu bộ nhớ (< 20MB RAM) dùng thuần CoreGraphics + Vision.
/// Không tạo `CIContext` hay bản sao toàn màn hình; chỉ trích xuất đúng vùng ROI cần thiết.
public final class VisionProcessor {
    private static let maxMinimapSampleDimension = 240
    private static let maxOCRSampleDimension = 280
    private static let maxBattlefieldOCRSampleDimension = 560
    private static let allowedNumericChars = CharacterSet(charactersIn: "0123456789-+.")

    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    private let grayColorSpace = CGColorSpaceCreateDeviceGray()

    public init() {}

    /// Xử lý trực tiếp `CVPixelBuffer` nhận từ `ReplayKit` trong `autoreleasepool`.
    public func process(
        pixelBuffer: CVPixelBuffer,
        roiConfig: ROIConfig,
        includeAngle: Bool = true
    ) -> VisionObservationResult {
        autoreleasepool {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            guard width > 0, height > 0 else {
                return VisionObservationResult(dx: 0, dy: 0, wind: nil, angle: nil, hasValidMinimap: false)
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            let minimap = analyzeMinimap(from: pixelBuffer, normalizedRect: roiConfig.minimapRect)
            let wind = recognizeNumericValue(from: pixelBuffer, normalizedRect: roiConfig.windRect, allowNegative: true)
            let angle = includeAngle
                ? recognizeBattlefieldAngle(from: pixelBuffer, normalizedRect: roiConfig.angleRect)
                : nil

            return VisionObservationResult(
                dx: minimap?.dx ?? 0.0,
                dy: minimap?.dy ?? 0.0,
                wind: wind,
                angle: angle,
                hasValidMinimap: minimap != nil
            )
        }
    }

    /// Xử lý từ `CGImage` tĩnh (dùng cho chế độ căn chỉnh ROI bằng ảnh từ Thư viện ảnh).
    public func process(cgImage: CGImage, roiConfig: ROIConfig) -> VisionObservationResult {
        autoreleasepool {
            let minimap = analyzeMinimap(from: cgImage, normalizedRect: roiConfig.minimapRect)
            let wind = recognizeNumericValue(from: cgImage, normalizedRect: roiConfig.windRect, allowNegative: true)
            let angle = recognizeBattlefieldAngle(from: cgImage, normalizedRect: roiConfig.angleRect)

            return VisionObservationResult(
                dx: minimap?.dx ?? 0.0,
                dy: minimap?.dy ?? 0.0,
                wind: wind,
                angle: angle,
                hasValidMinimap: minimap != nil
            )
        }
    }

    // MARK: - Minimap RGBA -> HSV Centroid Detection

    private func analyzeMinimap(from pixelBuffer: CVPixelBuffer, normalizedRect: NormalizedRect) -> MinimapCentroids? {
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        let roiPixel = normalizedRect.pixelRect(width: srcWidth, height: srcHeight)
        let cropW = Int(roiPixel.width)
        let cropH = Int(roiPixel.height)
        guard cropW >= 4, cropH >= 4 else { return nil }

        let (outW, outH) = clampedSize(width: cropW, height: cropH, maxDimension: Self.maxMinimapSampleDimension)
        guard let context = makeRGBAContext(width: outW, height: outH),
              let destBase = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }

        guard fillRGBABuffer(
            from: pixelBuffer,
            cropRect: roiPixel,
            destBuffer: destBase,
            destWidth: outW,
            destHeight: outH,
            destBytesPerRow: context.bytesPerRow
        ) else {
            return nil
        }

        return computeMinimapCentroids(
            rgbaBuffer: destBase,
            width: outW,
            height: outH,
            bytesPerRow: context.bytesPerRow
        )
    }

    private func analyzeMinimap(from cgImage: CGImage, normalizedRect: NormalizedRect) -> MinimapCentroids? {
        let roiPixel = normalizedRect.pixelRect(width: cgImage.width, height: cgImage.height)
        let cropW = Int(roiPixel.width)
        let cropH = Int(roiPixel.height)
        guard cropW >= 4, cropH >= 4,
              let cropped = cgImage.cropping(to: roiPixel) else {
            return nil
        }

        let (outW, outH) = clampedSize(width: cropW, height: cropH, maxDimension: Self.maxMinimapSampleDimension)
        guard let context = makeRGBAContext(width: outW, height: outH),
              let destBase = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))

        return computeMinimapCentroids(
            rgbaBuffer: destBase,
            width: outW,
            height: outH,
            bytesPerRow: context.bytesPerRow
        )
    }

    private func computeMinimapCentroids(
        rgbaBuffer: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> MinimapCentroids? {
        var blueSumX = 0.0
        var blueSumY = 0.0
        var blueCount = 0

        var redSumX = 0.0
        var redSumY = 0.0
        var redCount = 0

        for y in 0..<height {
            let rowPtr = rgbaBuffer.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let px = x * 4
                let r = rowPtr[px]
                let g = rowPtr[px + 1]
                let b = rowPtr[px + 2]

                let hsv = rgbToHSV(r: r, g: g, b: b)

                // Cụm màu xanh dương: vị trí người chơi trên minimap.
                if hsv.h >= 185.0 && hsv.h <= 255.0 && hsv.s >= 0.45 && hsv.v >= 0.35 {
                    blueSumX += Double(x)
                    blueSumY += Double(y)
                    blueCount += 1
                }
                // Cụm màu đỏ: vị trí mục tiêu / boss trên minimap.
                else if (hsv.h <= 22.0 || hsv.h >= 338.0) && hsv.s >= 0.48 && hsv.v >= 0.35 {
                    redSumX += Double(x)
                    redSumY += Double(y)
                    redCount += 1
                }
            }
        }

        guard blueCount > 0, redCount > 0 else { return nil }

        let blueX = blueSumX / Double(blueCount)
        let blueY = blueSumY / Double(blueCount)
        let redX = redSumX / Double(redCount)
        let redY = redSumY / Double(redCount)

        let minimapWidth = Double(width)
        let minimapHeight = Double(height)

        let dx = (redX - blueX) / minimapWidth
        let dy = (blueY - redY) / minimapHeight

        return MinimapCentroids(
            dx: dx,
            dy: dy,
            blueCentroid: CGPoint(x: blueX, y: blueY),
            redCentroid: CGPoint(x: redX, y: redY),
            bluePixelCount: blueCount,
            redPixelCount: redCount
        )
    }

    /// Đọc các chuỗi OCR thô từ một vùng `NormalizedRect` trong `CVPixelBuffer` (dùng trong `SampleHandler`).
    public func recognizeTextCandidates(
        from pixelBuffer: CVPixelBuffer,
        normalizedRect: NormalizedRect,
        maxDimension: Int = 560,
        minimumTextHeight: Float = 0.03
    ) -> [String] {
        guard let image = makeContrastGrayscaleImage(
            from: pixelBuffer,
            normalizedRect: normalizedRect,
            maxDimension: maxDimension
        ) else {
            return []
        }
        return performFastTextRecognition(on: image, minimumTextHeight: minimumTextHeight)
    }

    /// Trích xuất giá trị góc ưu tiên chuỗi có ký hiệu `°`/`º` hoặc đứng sau chữ `Góc` (ví dụ: `"Góc 31°"` -> `31.0`).
    public static func extractPriorityAngle(from candidates: [String], allowPlainFallback: Bool = false) -> Double? {
        for raw in candidates {
            if let matched = parseAngleNearGocKeyword(raw) {
                return matched
            }
        }
        for raw in candidates {
            if let matched = parseAngleBeforeDegreeSymbol(raw) {
                return matched
            }
        }
        if allowPlainFallback {
            let joined = candidates.joined(separator: " ")
            if let plain = parseFilteredNumber(from: joined, allowNegative: false),
               plain >= 0.0 && plain <= 90.0 {
                return plain
            }
        }
        return nil
    }

    // MARK: - Wind & Angle High-Contrast Grayscale + Fast Vision OCR

    private func recognizeBattlefieldAngle(from pixelBuffer: CVPixelBuffer, normalizedRect: NormalizedRect) -> Double? {
        let isWideBattlefield = normalizedRect.width > 0.22 || normalizedRect.height > 0.16
        guard let image = makeContrastGrayscaleImage(
            from: pixelBuffer,
            normalizedRect: normalizedRect,
            maxDimension: isWideBattlefield ? Self.maxBattlefieldOCRSampleDimension : Self.maxOCRSampleDimension
        ) else {
            return nil
        }

        let candidates = performFastTextRecognition(
            on: image,
            minimumTextHeight: isWideBattlefield ? 0.03 : 0.15
        )
        return Self.extractPriorityAngle(from: candidates, allowPlainFallback: !isWideBattlefield)
    }

    private func recognizeBattlefieldAngle(from cgImage: CGImage, normalizedRect: NormalizedRect) -> Double? {
        let isWideBattlefield = normalizedRect.width > 0.22 || normalizedRect.height > 0.16
        guard let image = makeContrastGrayscaleImage(
            from: cgImage,
            normalizedRect: normalizedRect,
            maxDimension: isWideBattlefield ? Self.maxBattlefieldOCRSampleDimension : Self.maxOCRSampleDimension
        ) else {
            return nil
        }

        let candidates = performFastTextRecognition(
            on: image,
            minimumTextHeight: isWideBattlefield ? 0.03 : 0.15
        )
        return Self.extractPriorityAngle(from: candidates, allowPlainFallback: !isWideBattlefield)
    }

    private func recognizeNumericValue(
        from pixelBuffer: CVPixelBuffer,
        normalizedRect: NormalizedRect,
        allowNegative: Bool
    ) -> Double? {
        guard let enhancedImage = makeContrastGrayscaleImage(
            from: pixelBuffer,
            normalizedRect: normalizedRect,
            maxDimension: Self.maxOCRSampleDimension
        ) else {
            return nil
        }
        return performFastDigitOCR(on: enhancedImage, allowNegative: allowNegative)
    }

    private func recognizeNumericValue(
        from cgImage: CGImage,
        normalizedRect: NormalizedRect,
        allowNegative: Bool
    ) -> Double? {
        guard let enhancedImage = makeContrastGrayscaleImage(
            from: cgImage,
            normalizedRect: normalizedRect,
            maxDimension: Self.maxOCRSampleDimension
        ) else {
            return nil
        }
        return performFastDigitOCR(on: enhancedImage, allowNegative: allowNegative)
    }

    private func makeContrastGrayscaleImage(
        from pixelBuffer: CVPixelBuffer,
        normalizedRect: NormalizedRect,
        maxDimension: Int
    ) -> CGImage? {
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        let roiPixel = normalizedRect.pixelRect(width: srcWidth, height: srcHeight)
        let cropW = Int(roiPixel.width)
        let cropH = Int(roiPixel.height)
        guard cropW >= 4, cropH >= 4 else { return nil }

        let scale = cropH < 48 ? 2 : 1
        let (outW, outH) = clampedSize(
            width: cropW * scale,
            height: cropH * scale,
            maxDimension: maxDimension
        )

        guard let grayContext = makeGrayscaleContext(width: outW, height: outH),
              let grayPtr = grayContext.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }

        guard fillGrayscaleBuffer(
            from: pixelBuffer,
            cropRect: roiPixel,
            destBuffer: grayPtr,
            destWidth: outW,
            destHeight: outH,
            destBytesPerRow: grayContext.bytesPerRow
        ) else {
            return nil
        }

        enhanceContrastInPlace(
            grayBuffer: grayPtr,
            width: outW,
            height: outH,
            bytesPerRow: grayContext.bytesPerRow
        )

        return grayContext.makeImage()
    }

    private func makeContrastGrayscaleImage(
        from cgImage: CGImage,
        normalizedRect: NormalizedRect,
        maxDimension: Int
    ) -> CGImage? {
        let roiPixel = normalizedRect.pixelRect(width: cgImage.width, height: cgImage.height)
        let cropW = Int(roiPixel.width)
        let cropH = Int(roiPixel.height)
        guard cropW >= 4, cropH >= 4,
              let cropped = cgImage.cropping(to: roiPixel) else {
            return nil
        }

        let scale = cropH < 48 ? 2 : 1
        let (outW, outH) = clampedSize(
            width: cropW * scale,
            height: cropH * scale,
            maxDimension: maxDimension
        )

        guard let grayContext = makeGrayscaleContext(width: outW, height: outH),
              let grayPtr = grayContext.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }

        grayContext.interpolationQuality = .medium
        grayContext.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))

        enhanceContrastInPlace(
            grayBuffer: grayPtr,
            width: outW,
            height: outH,
            bytesPerRow: grayContext.bytesPerRow
        )

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

    private func performFastDigitOCR(on image: CGImage, allowNegative: Bool) -> Double? {
        let recognizedString = performFastTextRecognition(on: image, minimumTextHeight: 0.15)
            .joined(separator: " ")
        return Self.parseFilteredNumber(from: recognizedString, allowNegative: allowNegative)
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
        guard let value = Double(token), value >= -90.0 && value <= 90.0 else { return nil }
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
            if let value = Double(digits), value >= -90.0 && value <= 90.0 {
                return value
            }
        }
        return nil
    }

    private static func parseFilteredNumber(from rawText: String, allowNegative: Bool) -> Double? {
        var filtered = ""
        filtered.reserveCapacity(rawText.count)

        for scalar in rawText.unicodeScalars where allowedNumericChars.contains(scalar) {
            filtered.unicodeScalars.append(scalar)
        }

        guard !filtered.isEmpty else { return nil }

        // Trích xuất token số đầu tiên hợp lệ (ví dụ: "-2.5", "+1.4", "65").
        var numberToken = ""
        var hasDecimal = false

        for ch in filtered {
            if (ch == "-" || ch == "+") && numberToken.isEmpty {
                if ch == "-" && !allowNegative {
                    continue
                }
                numberToken.append(ch)
            } else if ch == "." && !hasDecimal {
                hasDecimal = true
                if numberToken.isEmpty || numberToken == "-" || numberToken == "+" {
                    numberToken.append("0")
                }
                numberToken.append(ch)
            } else if ch.isASCII && ch.isNumber {
                numberToken.append(ch)
            } else if !numberToken.isEmpty {
                break
            }
        }

        return Double(numberToken)
    }

    // MARK: - CoreGraphics Context & Direct ROI Extraction

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

    private func fillRGBABuffer(
        from pixelBuffer: CVPixelBuffer,
        cropRect: CGRect,
        destBuffer: UnsafeMutablePointer<UInt8>,
        destWidth: Int,
        destHeight: Int,
        destBytesPerRow: Int
    ) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let originX = Int(cropRect.origin.x)
        let originY = Int(cropRect.origin.y)
        let cropW = Int(cropRect.width)
        let cropH = Int(cropRect.height)

        switch format {
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA:
            guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            let srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let isBGRA = (format == kCVPixelFormatType_32BGRA)

            for dy in 0..<destHeight {
                let sy = originY + (dy * cropH) / destHeight
                let srcRow = srcBase.advanced(by: sy * srcBytesPerRow)
                let dstRow = destBuffer.advanced(by: dy * destBytesPerRow)

                for dx in 0..<destWidth {
                    let sx = originX + (dx * cropW) / destWidth
                    let sIdx = sx * 4
                    let dIdx = dx * 4

                    if isBGRA {
                        dstRow[dIdx] = srcRow[sIdx + 2]
                        dstRow[dIdx + 1] = srcRow[sIdx + 1]
                        dstRow[dIdx + 2] = srcRow[sIdx]
                        dstRow[dIdx + 3] = 255
                    } else {
                        dstRow[dIdx] = srcRow[sIdx]
                        dstRow[dIdx + 1] = srcRow[sIdx + 1]
                        dstRow[dIdx + 2] = srcRow[sIdx + 2]
                        dstRow[dIdx + 3] = 255
                    }
                }
            }
            return true

        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
                  let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
                  let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let isFullRange = (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)

            for dy in 0..<destHeight {
                let sy = originY + (dy * cropH) / destHeight
                let yRow = yBase.advanced(by: sy * yBytesPerRow)
                let uvRow = uvBase.advanced(by: (sy >> 1) * uvBytesPerRow)
                let dstRow = destBuffer.advanced(by: dy * destBytesPerRow)

                for dx in 0..<destWidth {
                    let sx = originX + (dx * cropW) / destWidth
                    let yVal = Int(yRow[sx])
                    let uvIdx = (sx >> 1) * 2
                    let cb = Int(uvRow[uvIdx]) - 128
                    let cr = Int(uvRow[uvIdx + 1]) - 128

                    let r: Int
                    let g: Int
                    let b: Int
                    if isFullRange {
                        let yScaled = yVal << 10
                        r = (yScaled + 1436 * cr) >> 10
                        g = (yScaled - 352 * cb - 731 * cr) >> 10
                        b = (yScaled + 1815 * cb) >> 10
                    } else {
                        let c = max(0, yVal - 16) * 1192
                        r = (c + 1634 * cr) >> 10
                        g = (c - 401 * cb - 832 * cr) >> 10
                        b = (c + 2066 * cb) >> 10
                    }

                    let dIdx = dx * 4
                    dstRow[dIdx] = clampByte(r)
                    dstRow[dIdx + 1] = clampByte(g)
                    dstRow[dIdx + 2] = clampByte(b)
                    dstRow[dIdx + 3] = 255
                }
            }
            return true

        default:
            return false
        }
    }

    private func fillGrayscaleBuffer(
        from pixelBuffer: CVPixelBuffer,
        cropRect: CGRect,
        destBuffer: UnsafeMutablePointer<UInt8>,
        destWidth: Int,
        destHeight: Int,
        destBytesPerRow: Int
    ) -> Bool {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let originX = Int(cropRect.origin.x)
        let originY = Int(cropRect.origin.y)
        let cropW = Int(cropRect.width)
        let cropH = Int(cropRect.height)

        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let isVideoRange = (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

            for dy in 0..<destHeight {
                let sy = originY + (dy * cropH) / destHeight
                let yRow = yBase.advanced(by: sy * yBytesPerRow)
                let dstRow = destBuffer.advanced(by: dy * destBytesPerRow)

                for dx in 0..<destWidth {
                    let sx = originX + (dx * cropW) / destWidth
                    let luma = Int(yRow[sx])
                    if isVideoRange {
                        dstRow[dx] = clampByte(((luma - 16) * 255) / 219)
                    } else {
                        dstRow[dx] = UInt8(luma)
                    }
                }
            }
            return true

        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32RGBA:
            guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            let srcBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let isBGRA = (format == kCVPixelFormatType_32BGRA)

            for dy in 0..<destHeight {
                let sy = originY + (dy * cropH) / destHeight
                let srcRow = srcBase.advanced(by: sy * srcBytesPerRow)
                let dstRow = destBuffer.advanced(by: dy * destBytesPerRow)

                for dx in 0..<destWidth {
                    let sx = originX + (dx * cropW) / destWidth
                    let sIdx = sx * 4
                    let r = Int(isBGRA ? srcRow[sIdx + 2] : srcRow[sIdx])
                    let g = Int(srcRow[sIdx + 1])
                    let b = Int(isBGRA ? srcRow[sIdx] : srcRow[sIdx + 2])
                    // Chuẩn độ sáng Rec.601: 0.299R + 0.587G + 0.114B.
                    dstRow[dx] = clampByte((77 * r + 150 * g + 29 * b) >> 8)
                }
            }
            return true

        default:
            return false
        }
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

        // Kéo giãn dải sáng (contrast stretching) kết hợp tăng hệ số tương phản quanh trung điểm.
        let minInt = Int(minLum)
        for y in 0..<height {
            let row = grayBuffer.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let stretched = ((Int(row[x]) - minInt) * 255) / span
                let boosted = ((stretched - 128) * 16) / 10 + 128
                row[x] = clampByte(boosted)
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

    @inline(__always)
    private func clampByte(_ value: Int) -> UInt8 {
        UInt8(min(max(value, 0), 255))
    }
}
