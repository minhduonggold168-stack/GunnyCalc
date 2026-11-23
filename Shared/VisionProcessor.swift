import CoreGraphics
import Foundation
import Vision

/// Kết quả tọa độ chuẩn hóa (0.0 - 1.0) đọc được từ khung Minimap.
public struct MinimapLocations: Equatable, Sendable {
    public let playerX: Double
    public let playerY: Double
    public let enemyX: Double
    public let enemyY: Double
    public let hasPlayer: Bool
    public let hasEnemy: Bool
}

/// Bộ xử lý hình ảnh gọn nhẹ (< 25MB RAM) dùng thuần CoreGraphics + Vision (.fast).
public final class VisionProcessor {
    private static let maxMinimapSampleDimension = 220
    private static let maxWindSampleDimension = 200
    private static let maxAngleSampleDimension = 560
    private static let allowedNumericChars = CharacterSet(charactersIn: "0123456789-+.")

    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    private let grayColorSpace = CGColorSpaceCreateDeviceGray()

    public init() {}

    // MARK: - 1. Minimap Player (Blue) & Enemy (Red) Centroids

    public func detectMinimapLocations(
        from cgImage: CGImage,
        normalizedRect: NormalizedRect = GunnyROIs.minimap
    ) -> MinimapLocations? {
        let roiPixel = normalizedRect.pixelRect(width: cgImage.width, height: cgImage.height)
        let cropW = Int(roiPixel.width)
        let cropH = Int(roiPixel.height)
        guard cropW >= 4, cropH >= 4,
              let cropped = cgImage.cropping(to: roiPixel) else {
            return nil
        }

        let (outW, outH) = clampedSize(width: cropW, height: cropH, maxDimension: Self.maxMinimapSampleDimension)
        guard let context = makeRGBAContext(width: outW, height: outH),
              let rgbaPtr = context.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))

        var blueSumX = 0.0
        var blueSumY = 0.0
        var blueCount = 0

        var redSumX = 0.0
        var redSumY = 0.0
        var redCount = 0

        let bytesPerRow = context.bytesPerRow
        for y in 0..<outH {
            let rowPtr = rgbaPtr.advanced(by: y * bytesPerRow)
            for x in 0..<outW {
                let px = x * 4
                let hsv = rgbToHSV(r: rowPtr[px], g: rowPtr[px + 1], b: rowPtr[px + 2])

                // Cụm màu xanh dương: vị trí người chơi.
                if hsv.h >= 180.0 && hsv.h <= 255.0 && hsv.s >= 0.35 && hsv.v >= 0.30 {
                    blueSumX += Double(x)
                    blueSumY += Double(y)
                    blueCount += 1
                }
                // Cụm màu đỏ: vị trí mục tiêu / địch.
                else if (hsv.h <= 25.0 || hsv.h >= 335.0) && hsv.s >= 0.38 && hsv.v >= 0.30 {
                    redSumX += Double(x)
                    redSumY += Double(y)
                    redCount += 1
                }
            }
        }

        guard blueCount > 0 || redCount > 0 else { return nil }

        let w = Double(outW)
        let h = Double(outH)

        let playerX = blueCount > 0 ? (blueSumX / Double(blueCount)) / w : 0.25
        let playerY = blueCount > 0 ? (blueSumY / Double(blueCount)) / h : 0.65
        let enemyX = redCount > 0 ? (redSumX / Double(redCount)) / w : 0.75
        let enemyY = redCount > 0 ? (redSumY / Double(redCount)) / h : 0.65

        return MinimapLocations(
            playerX: playerX,
            playerY: playerY,
            enemyX: enemyX,
            enemyY: enemyY,
            hasPlayer: blueCount > 0,
            hasEnemy: redCount > 0
        )
    }

    // MARK: - 2. Wind Value (VNRecognizeTextRequest .fast) & Wind Arrow Direction

    public func detectWind(
        from cgImage: CGImage,
        normalizedRect: NormalizedRect = GunnyROIs.wind
    ) -> (value: Double?, direction: Int) {
        let roiPixel = normalizedRect.pixelRect(width: cgImage.width, height: cgImage.height)
        let cropW = Int(roiPixel.width)
        let cropH = Int(roiPixel.height)
        guard cropW >= 8, cropH >= 4,
              let cropped = cgImage.cropping(to: roiPixel) else {
            return (nil, 1)
        }

        let scale = cropH < 48 ? 2 : 1
        let (outW, outH) = clampedSize(width: cropW * scale, height: cropH * scale, maxDimension: Self.maxWindSampleDimension)
        guard let grayContext = makeGrayscaleContext(width: outW, height: outH),
              let grayPtr = grayContext.data?.assumingMemoryBound(to: UInt8.self) else {
            return (nil, 1)
        }

        grayContext.interpolationQuality = .medium
        grayContext.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))

        // So sánh độ sáng nửa trái và nửa phải vùng mũi tên để xác định chiều gió (-1 trái, +1 phải).
        let midX = outW / 2
        let bytesPerRow = grayContext.bytesPerRow
        var leftBright = 0
        var rightBright = 0
        for y in 0..<outH {
            let row = grayPtr.advanced(by: y * bytesPerRow)
            for x in 0..<outW where row[x] >= 175 {
                if x < midX {
                    leftBright += 1
                } else {
                    rightBright += 1
                }
            }
        }
        let direction = leftBright > rightBright ? -1 : 1

        enhanceContrastInPlace(grayBuffer: grayPtr, width: outW, height: outH, bytesPerRow: bytesPerRow)
        guard let enhancedImage = grayContext.makeImage() else {
            return (nil, direction)
        }

        let candidates = performFastTextRecognition(on: enhancedImage, minimumTextHeight: 0.15)
        let windVal = Self.parseFilteredNumber(from: candidates.joined(separator: " "))
        return (windVal.map { abs($0) }, direction)
    }

    // MARK: - 3. Battlefield Angle OCR ("Góc 21°" -> 21.0)

    public func detectBattlefieldAngle(
        from cgImage: CGImage,
        normalizedRect: NormalizedRect = GunnyROIs.angle
    ) -> Double? {
        let roiPixel = normalizedRect.pixelRect(width: cgImage.width, height: cgImage.height)
        let cropW = Int(roiPixel.width)
        let cropH = Int(roiPixel.height)
        guard cropW >= 8, cropH >= 8,
              let cropped = cgImage.cropping(to: roiPixel) else {
            return nil
        }

        let (outW, outH) = clampedSize(width: cropW, height: cropH, maxDimension: Self.maxAngleSampleDimension)
        guard let grayContext = makeGrayscaleContext(width: outW, height: outH),
              let grayPtr = grayContext.data?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }

        grayContext.interpolationQuality = .medium
        grayContext.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        enhanceContrastInPlace(grayBuffer: grayPtr, width: outW, height: outH, bytesPerRow: grayContext.bytesPerRow)

        guard let enhancedImage = grayContext.makeImage() else { return nil }
        let candidates = performFastTextRecognition(on: enhancedImage, minimumTextHeight: 0.03)
        return Self.extractPriorityAngle(from: candidates)
    }

    // MARK: - Text Parsing Helpers

    public static func extractPriorityAngle(from candidates: [String]) -> Double? {
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

    // MARK: - CoreGraphics Helpers

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
