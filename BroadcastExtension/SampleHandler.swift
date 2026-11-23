import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Network
import ReplayKit
import Vision

/// Handler nhận khung hình thụ động từ ReplayKit.
/// - Dùng duy nhất 1 `sharedCIContext` trong suốt vòng đời Extension để giữ RAM < 25 MB.
/// - Giới hạn tốc độ 3 FPS (0.33s/frame) và bọc toàn bộ trong `autoreleasepool`.
/// - Tự chuẩn hóa khung hình sang chiều ngang, đọc Minimap + Gió + Hướng mũi tên gió + Góc `Góc ...°`,
///   sau đó gửi gói JSON qua UDP IPv4 tới `127.0.0.1:45678` bằng `NWConnection`.
final class SampleHandler: RPBroadcastSampleHandler {
    private let sharedCIContext = CIContext(options: [.useSoftwareRenderer: false])
    private let visionProcessor = VisionProcessor()
    private let ballisticsEngine = BallisticsEngine()
    private let ipc = SharedIPC.shared
    private let jsonEncoder = JSONEncoder()

    private var ballisticsConfig: BallisticsConfig = .default
    private var roiConfig: ROIConfig = .default
    private var lastProcessedTimestamp: TimeInterval = 0
    private var isProcessingFrame = false
    private var frameCount: Int = 0
    private var lastValidDx: Double = 0.48
    private var lastValidDy: Double = 0.0
    private var lastValidAngle: Double?

    private let minimumFrameInterval: TimeInterval = 0.33 // 3 FPS
    private let maxScaledWidth: CGFloat = 960.0
    private let stateLock = NSLock()
    private let udpQueue = DispatchQueue(label: "com.gunny.pipcalc.ext.udp", qos: .userInteractive)
    private var udpConnection: NWConnection?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        reloadConfigurations()
        stateLock.lock()
        lastProcessedTimestamp = 0
        isProcessingFrame = false
        frameCount = 0
        stateLock.unlock()

        startUDPConnectionIfNeeded()
        ipc.startObservingConfig { [weak self] in
            self?.reloadConfigurations()
        }
    }

    override func broadcastPaused() {
        // Tạm dừng xử lý khi hệ thống tạm ngưng broadcast.
    }

    override func broadcastResumed() {
        reloadConfigurations()
        startUDPConnectionIfNeeded()
    }

    override func broadcastFinished() {
        ipc.stopObservingConfig()
        stopUDPConnection()
        sharedCIContext.clearCaches()
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

            let orientation = extractVideoOrientation(from: sampleBuffer)
            guard let scaledImage = makeLandscapeDownscaledCGImage(
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

            // Xác định hướng mũi tên gió (< = -1, > = +1) bằng mật độ điểm sáng nửa trái/phải trong windROI.
            let windDirection = visionProcessor.detectWindDirection(
                from: scaledImage,
                normalizedRect: currentROI.windRect
            )

            // Đọc góc bắn trong angleROI: ưu tiên chuỗi có ký hiệu `°` hoặc đứng sau `Góc` (ví dụ `Góc 21°`).
            let detectedAngle: Double?
            if currentBallistics.useOCRAngle {
                let angleCandidates = visionProcessor.recognizeTextCandidates(
                    from: scaledImage,
                    normalizedRect: currentROI.angleRect,
                    maxDimension: 560,
                    minimumTextHeight: 0.03
                )
                if let matched = filterBattlefieldAngle(from: angleCandidates) {
                    detectedAngle = matched
                    stateLock.lock()
                    lastValidAngle = matched
                    stateLock.unlock()
                } else {
                    stateLock.lock()
                    detectedAngle = lastValidAngle
                    stateLock.unlock()
                }
            } else {
                detectedAngle = nil
            }

            let previous = ipc.loadTelemetry()
            let windMagnitude = abs(observation.wind ?? previous?.wind ?? 0.0)
            let signedWind = windMagnitude * Double(windDirection)

            let resolvedDx: Double
            let resolvedDy: Double
            stateLock.lock()
            if observation.hasValidMinimap {
                lastValidDx = observation.dx
                lastValidDy = observation.dy
            }
            resolvedDx = lastValidDx
            resolvedDy = lastValidDy
            frameCount += 1
            let currentFrameNumber = frameCount
            stateLock.unlock()

            let telemetry = ballisticsEngine.computeTelemetry(
                dx: resolvedDx,
                dy: resolvedDy,
                wind: signedWind,
                windDirection: windDirection,
                detectedAngle: detectedAngle,
                config: currentBallistics,
                timestamp: now,
                frameCount: currentFrameNumber
            )

            sendUDPPacket(telemetry)
            ipc.saveTelemetry(telemetry, notify: true)
        }
    }

    // MARK: - Orientation & 960px Downscale

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

        // Nếu sau khi áp dụng RPVideoSampleOrientationKey vẫn là khung đứng (height > width), tự xoay 90° sang ngang.
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

    private func filterBattlefieldAngle(from candidates: [String]) -> Double? {
        VisionProcessor.extractPriorityAngle(from: candidates, allowPlainFallback: false)
    }

    // MARK: - UDP IPv4 Sender (NWParameters.udp -> 127.0.0.1:45678)

    private func startUDPConnectionIfNeeded() {
        udpQueue.async { [weak self] in
            guard let self, self.udpConnection == nil else { return }

            let parameters = NWParameters.udp
            if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ipOptions.version = .v4
            }

            let connection = NWConnection(
                host: NWEndpoint.Host(SharedIPC.udpHost),
                port: NWEndpoint.Port(rawValue: SharedIPC.udpPort)!,
                using: parameters
            )
            connection.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    self?.udpConnection = nil
                }
            }
            connection.start(queue: self.udpQueue)
            self.udpConnection = connection
        }
    }

    private func stopUDPConnection() {
        udpQueue.async { [weak self] in
            self?.udpConnection?.cancel()
            self?.udpConnection = nil
        }
    }

    private func sendUDPPacket(_ telemetry: TelemetryData) {
        guard let payload = try? jsonEncoder.encode(telemetry), !payload.isEmpty else { return }

        udpQueue.async { [weak self] in
            guard let self else { return }
            if self.udpConnection == nil {
                let parameters = NWParameters.udp
                if let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                    ipOptions.version = .v4
                }
                let conn = NWConnection(
                    host: NWEndpoint.Host(SharedIPC.udpHost),
                    port: NWEndpoint.Port(rawValue: SharedIPC.udpPort)!,
                    using: parameters
                )
                conn.stateUpdateHandler = { [weak self] state in
                    if case .failed = state {
                        self?.udpConnection = nil
                    }
                }
                conn.start(queue: self.udpQueue)
                self.udpConnection = conn
            }

            self.udpConnection?.send(content: payload, completion: .contentProcessed { _ in })
        }
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
