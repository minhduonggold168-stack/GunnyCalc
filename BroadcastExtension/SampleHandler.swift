import CoreGraphics
import CoreVideo
import Foundation
import ReplayKit
import Vision

/// Handler nhận khung hình thụ động từ ReplayKit.
/// Lưu ý ràng buộc: Không dùng OpenCV, giải phóng bộ nhớ ngay trong `autoreleasepool`
/// và giới hạn tần suất lấy mẫu để duy trì RAM của Broadcast Extension luôn dưới ngưỡng 25MB.
final class SampleHandler: RPBroadcastSampleHandler {
    private let visionProcessor = VisionProcessor()
    private let ballisticsEngine = BallisticsEngine()
    private let ipc = SharedIPC.shared

    private var ballisticsConfig: BallisticsConfig = .default
    private var roiConfig: ROIConfig = .default
    private var lastProcessedTimestamp: TimeInterval = 0
    private var isProcessingFrame = false

    private let minimumFrameInterval: TimeInterval = 0.25
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
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
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

        autoreleasepool {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

            let observation = visionProcessor.process(
                pixelBuffer: pixelBuffer,
                roiConfig: currentROI,
                includeAngle: false
            )
            guard observation.hasValidMinimap else { return }

            // Ưu tiên bộ lọc OCR tìm chuỗi chứa ký hiệu `°` hoặc đứng sau chữ `Góc` (ví dụ `Góc 31°` -> 31.0) trong angleROI.
            let priorityAngle: Double?
            if currentBallistics.useOCRAngle {
                CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                let angleCandidates = visionProcessor.recognizeTextCandidates(
                    from: pixelBuffer,
                    normalizedRect: NormalizedRect(currentBallistics.angleROI),
                    maxDimension: 560,
                    minimumTextHeight: 0.03
                )
                CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
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

            ipc.saveTelemetry(telemetry, notify: true)
        }
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
