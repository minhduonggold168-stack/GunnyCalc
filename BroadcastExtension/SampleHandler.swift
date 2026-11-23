import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ReplayKit

/// Handler nhận khung hình thụ động từ ReplayKit.
/// - Dùng duy nhất 1 `sharedCIContext`, bọc `processSampleBuffer` trong `autoreleasepool` ở tốc độ 10 FPS (100ms).
/// - Tự xoay khung hình về chiều ngang (`width > height`) bằng `RPVideoSampleOrientationKey`.
/// - Quét 3 vùng chuẩn Gunny Mobi và bắn gói `TelemetryData` qua BSD UDP loopback `127.0.0.1:45678`.
final class SampleHandler: RPBroadcastSampleHandler {
    private let sharedCIContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])
    private let visionProcessor = VisionProcessor()
    private let ballisticsEngine = BallisticsEngine()
    private let udpSender = BSDUDPSender()
    private let ipc = SharedIPC.shared

    private let stateLock = NSLock()
    private var lastProcessedTime: TimeInterval = 0
    private var isProcessingFrame = false
    private var frameCounter: Int = 0

    // Bộ đệm giữ giá trị hợp lệ gần nhất khi bị hiệu ứng game che tạm thời.
    private var lastPlayerX: Double = 0.25
    private var lastPlayerY: Double = 0.65
    private var lastEnemyX: Double = 0.75
    private var lastEnemyY: Double = 0.65
    private var lastAngle: Double = 65.0
    private var lastWind: Double = 0.0
    private var lastWindDir: Int = 1

    private let minimumFrameInterval: TimeInterval = 0.10 // 10 FPS (100ms)
    private let maxScaledWidth: CGFloat = 960.0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        stateLock.lock()
        lastProcessedTime = 0
        isProcessingFrame = false
        frameCounter = 0
        stateLock.unlock()
    }

    override func broadcastPaused() {
        // Tạm dừng xử lý khi hệ thống tạm ngưng broadcast.
    }

    override func broadcastResumed() {
        stateLock.lock()
        lastProcessedTime = 0
        stateLock.unlock()
    }

    override func broadcastFinished() {
        sharedCIContext.clearCaches()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        autoreleasepool {
            guard sampleBufferType == .video else { return }

            let now = Date().timeIntervalSince1970
            stateLock.lock()
            if isProcessingFrame || (now - lastProcessedTime) < minimumFrameInterval {
                stateLock.unlock()
                return
            }
            isProcessingFrame = true
            lastProcessedTime = now
            stateLock.unlock()

            defer {
                stateLock.lock()
                isProcessingFrame = false
                stateLock.unlock()
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            let orientation = extractVideoOrientation(from: sampleBuffer)
            guard let landscapeImage = makeLandscapeDownscaledCGImage(
                from: pixelBuffer,
                orientation: orientation
            ) else {
                return
            }

            // 1. Quét Minimap (0.848, 0.005, 0.148, 0.170)
            let minimap = visionProcessor.detectMinimapLocations(
                from: landscapeImage,
                normalizedRect: GunnyROIs.minimap
            )

            // 2. Quét Ô Gió (0.435, 0.005, 0.130, 0.070)
            let windObservation = visionProcessor.detectWind(
                from: landscapeImage,
                normalizedRect: GunnyROIs.wind
            )

            // 3. Quét Góc bắn vùng chiến trường (0.080, 0.120, 0.760, 0.600)
            let detectedAngle = visionProcessor.detectBattlefieldAngle(
                from: landscapeImage,
                normalizedRect: GunnyROIs.angle
            )

            stateLock.lock()
            if let minimap {
                if minimap.hasPlayer {
                    lastPlayerX = minimap.playerX
                    lastPlayerY = minimap.playerY
                }
                if minimap.hasEnemy {
                    lastEnemyX = minimap.enemyX
                    lastEnemyY = minimap.enemyY
                }
            }
            if let windValue = windObservation.value {
                lastWind = windValue
                lastWindDir = windObservation.direction
            }
            if let detectedAngle {
                lastAngle = detectedAngle
            }

            frameCounter += 1
            let currentFrameId = frameCounter
            let resolvedPX = lastPlayerX
            let resolvedPY = lastPlayerY
            let resolvedEX = lastEnemyX
            let resolvedEY = lastEnemyY
            let resolvedAngle = lastAngle
            let resolvedWind = lastWind
            let resolvedWindDir = lastWindDir
            stateLock.unlock()

            let telemetry = ballisticsEngine.buildTelemetry(
                frameId: currentFrameId,
                playerX: resolvedPX,
                playerY: resolvedPY,
                enemyX: resolvedEX,
                enemyY: resolvedEY,
                angle: resolvedAngle,
                windMagnitude: resolvedWind,
                windDir: resolvedWindDir
            )

            udpSender.send(telemetry)
            ipc.saveTelemetry(telemetry)
        }
    }

    // MARK: - Orientation & 960px Landscape Downscale

    private func extractVideoOrientation(from sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        if let attachment = CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber {
            return CGImagePropertyOrientation(rawValue: attachment.uint32Value) ?? .up
        }
        return .up
    }

    private func makeLandscapeDownscaledCGImage(
        from pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> CGImage? {
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)

        // Luôn xoay sang đúng chiều ngang (width > height) trước khi cắt 3 vùng Gunny Mobi.
        if ciImage.extent.height > ciImage.extent.width {
            ciImage = ciImage.oriented(.left)
        }

        let origin = ciImage.extent.origin
        if origin != .zero {
            ciImage = ciImage.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        }

        let currentWidth = ciImage.extent.width
        guard currentWidth > 0, ciImage.extent.height > 0 else { return nil }

        if currentWidth > maxScaledWidth {
            let scale = maxScaledWidth / currentWidth
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let renderBounds = CGRect(
            x: 0,
            y: 0,
            width: floor(ciImage.extent.width),
            height: floor(ciImage.extent.height)
        )
        guard renderBounds.width >= 16, renderBounds.height >= 16 else { return nil }

        return sharedCIContext.createCGImage(ciImage, from: renderBounds)
    }
}
