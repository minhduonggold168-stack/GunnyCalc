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

    private var roiConfig: ROIConfig = .default
    private var ballisticsConfig: BallisticsConfig = .default
    private var lastProcessedTimestamp: TimeInterval = 0
    private var isProcessingFrame = false

    private let minimumFrameInterval: TimeInterval = 0.25
    private let stateLock = NSLock()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        stateLock.lock()
        roiConfig = ipc.loadROIConfig()
        ballisticsConfig = ipc.loadBallisticsConfig()
        lastProcessedTimestamp = 0
        isProcessingFrame = false
        stateLock.unlock()

        ipc.startObservingConfig { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            self.roiConfig = self.ipc.loadROIConfig()
            self.ballisticsConfig = self.ipc.loadBallisticsConfig()
            self.stateLock.unlock()
        }
    }

    override func broadcastPaused() {
        // Tạm dừng xử lý khi hệ thống tạm ngưng broadcast.
    }

    override func broadcastResumed() {
        stateLock.lock()
        roiConfig = ipc.loadROIConfig()
        ballisticsConfig = ipc.loadBallisticsConfig()
        stateLock.unlock()
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
            let observation = visionProcessor.process(pixelBuffer: pixelBuffer, roiConfig: currentROI)
            guard observation.hasValidMinimap else { return }

            let previous = ipc.loadTelemetry()
            let resolvedWind = observation.wind ?? previous?.wind ?? 0.0
            let resolvedAngle = observation.angle

            let telemetry = ballisticsEngine.computeTelemetry(
                dx: observation.dx,
                dy: observation.dy,
                wind: resolvedWind,
                detectedAngle: resolvedAngle,
                config: currentBallistics,
                timestamp: now
            )

            ipc.saveTelemetry(telemetry, notify: true)
        }
    }
}
