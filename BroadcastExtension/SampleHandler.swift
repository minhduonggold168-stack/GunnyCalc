import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ReplayKit
import Vision

/// Handler nhận khung hình thụ động từ ReplayKit.
/// Giới hạn 4 FPS, bọc toàn bộ xử lý trong `autoreleasepool`, xoay đúng hướng ngang bằng `RPVideoSampleOrientationKey`
/// và thu nhỏ khung hình <= 960px trước khi chạy Vision OCR (.fast) để giữ RAM luôn dưới 25 MB.
final class SampleHandler: RPBroadcastSampleHandler {
    private let visionProcessor = VisionProcessor()
    private let ballisticsEngine = BallisticsEngine()
    private let ipc = SharedIPC.shared

    /// CIContext tắt cache trung gian nhằm tránh phình bộ nhớ vượt ngưỡng Jetsam 50 MB của Broadcast Extension.
    private let ciContext = CIContext(options: [
        .cacheIntermediates: false,
        .priorityRequestLow: true
    ])

    private var ballisticsConfig: BallisticsConfig = .default
    private var roiConfig: ROIConfig = .default
    private var lastProcessedTimestamp: TimeInterval = 0
    private var isProcessingFrame = false

    private let minimumFrameInterval: TimeInterval = 0.25 // Tối đa 4 FPS
    private let maxScaledWidth: CGFloat = 960.0
    private let stateLock = NSLock()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        reloadConfigurations()
        stateLock.lock()
        lastProcessedTimestamp = 0
        isProcessingFrame = false
        stateLock.unlock()

        ipc.startObservingConfig { [weak self] in
            self?.reloadConfigurations()
        }
    }

    override func broadcastPaused() {
        // Tạm dừng xử lý khi hệ thống tạm ngưng broadcast.
    }

    override func broadcastResumed() {
        reloadConfigurations()
    }

    override func broadcastFinished() {
        ipc.stopObservingConfig()
        ciContext.clearCaches()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        autoreleasepool {
            guard sampleBufferType == .video else { return }

            let now = Date().timeIntervalSince1970
            stateLock.lock()
            if isProcessingFrame || (now - lastProcessedTimestamp) < minimumFrameInterval {
                stateLock.unlock()
                return
            }
            isProcessingFrame = true
            lastProcessedTimestamp = now
            let currentROI = roiConfig
            let currentBallistics = ballisticsConfig
            stateLock.unlock()

            defer {
                stateLock.lock()
                isProcessingFrame = false
                stateLock.unlock()
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            // Đọc hướng xoay thực tế từ ReplayKit để chuẩn hóa khung hình ngang khớp màn hình game Gunny Mobi.
            let orientation = extractVideoOrientation(from: sampleBuffer)
            guard let scaledImage = makeOrientedDownscaledCGImage(
                from: pixelBuffer,
                orientation: orientation
            ) else {
                return
            }

            let observation = visionProcessor.process(
                cgImage: scaledImage,
                roiConfig: currentROI,
                includeAngle: false
            )
            guard observation.hasValidMinimap else { return }

            // Ưu tiên bộ lọc OCR tìm chuỗi chứa ký hiệu `°` hoặc đứng sau chữ `Góc` (ví dụ `Góc 31°` -> 31.0).
            let priorityAngle: Double?
            if currentBallistics.useOCRAngle {
                let angleCandidates = visionProcessor.recognizeTextCandidates(
                    from: scaledImage,
                    normalizedRect: NormalizedRect(currentBallistics.angleROI),
                    maxDimension: 560,
                    minimumTextHeight: 0.03
                )
                priorityAngle = filterBattlefieldAngle(from: angleCandidates)
            } else {
                priorityAngle = nil
            }

            let previous = ipc.loadTelemetry()
            let resolvedWind = observation.wind ?? previous?.wind ?? 0.0

            let telemetry = ballisticsEngine.computeTelemetry(
                dx: observation.dx,
                dy: observation.dy,
                wind: resolvedWind,
                detectedAngle: priorityAngle,
                config: currentBallistics,
                timestamp: now
            )

            // Gửi dữ liệu tức thì qua UDP nội bộ 127.0.0.1:45678 và đồng bộ qua App Group IPC.
            ipc.sendTelemetryUDP(telemetry)
            ipc.saveTelemetry(telemetry, notify: true)
            ciContext.clearCaches()
        }
    }

    // MARK: - Orientation & Low-Memory Downscale Helpers

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

    private func makeOrientedDownscaledCGImage(
        from pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> CGImage? {
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)

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

        return ciContext.createCGImage(ciImage, from: renderBounds)
    }

    /// Tối ưu bộ lọc OCR cho `angleROI`: ưu tiên chuỗi chứa chữ `Góc` (ví dụ `Góc 31°`) hoặc ký hiệu `°`.
    private func filterBattlefieldAngle(from candidates: [String]) -> Double? {
        VisionProcessor.extractPriorityAngle(from: candidates, allowPlainFallback: false)
    }

    private func reloadConfigurations() {
        let loadedBallistics = BallisticsConfig.load()
        let loadedROI = loadedBallistics.roiConfig

        stateLock.lock()
        ballisticsConfig = loadedBallistics
        roiConfig = loadedROI
        stateLock.unlock()
    }
}
