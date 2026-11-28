import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import ReplayKit

/// Handler nhận khung hình thụ động từ ReplayKit (< 25MB RAM, độ trễ < 0.1s).
/// - Thuật toán 1: Phân cụm không gian màu HSV + Connected-Component Labeling 8 hướng + tự đo khung camera trắng (`10.0` đơn vị).
/// - Thuật toán 2: Trích xuất địa hình 32 cột & Terrain Raycast 25 điểm cảnh báo vướng núi (`isBlocked`, `suggestedAngle`).
/// - Thuật toán 3: Theo dõi vệt nổ sau phát bắn & tự học `mapScaleMultiplier` (`learningRate = 0.15`, `0.85...1.15`).
/// - Gửi gói JSON qua BSD UDP `127.0.0.1:45678` an toàn tuyệt đối (không `!`, không `fatalError`).
final class SampleHandler: RPBroadcastSampleHandler {
    private let sharedCIContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])
    private let grayColorSpace = CGColorSpaceCreateDeviceGray()
    private let visionProcessor = VisionProcessor()
    private let ballisticsEngine = BallisticsEngine()
    private let calibrationEngine = AdaptiveCalibrationEngine()
    private let ipc = SharedIPC.shared

    private let stateLock = NSLock()
    private let udpLock = NSLock()
    private let heartbeatQueue = DispatchQueue(label: "com.gunny.pipcalc.broadcast.heartbeat", qos: .utility)
    private let angleOCRQueue = DispatchQueue(label: "com.gunny.pipcalc.broadcast.angleOCR", qos: .userInteractive)

    private var heartbeatTimer: DispatchSourceTimer?
    private var udpSocketFD: Int32 = -1
    private var udpDestination: sockaddr_in?

    private var lastProcessedTime: TimeInterval = 0
    private var lastPacketSentTime: TimeInterval = 0
    private var lastOCRStartedAt: TimeInterval = 0
    private var isProcessingFrame = false
    private var isOCRBusy = false
    private var isCurrentlyLandscape = false
    private var frameCounter: Int = 0

    // Trạng thái tức thời (không làm mượt EMA).
    private var lastPlayerPos = CGPoint(x: 0.20, y: 0.72)
    private var lastEnemyPos = CGPoint(x: 0.70, y: 0.72)
    private var lastCameraWidthNorm: Double = 0.50 // 10.0 đơn vị = 50% Minimap (20.0 đơn vị toàn bản đồ)
    private var lastMinimapAspect: Double = 0.36
    private var lastTerrainProfile: [Double] = []
    private var lastRawDistanceUnits: Double = 10.0
    private var lastAngle: Int = 50

    // Trạng thái theo dõi phát bắn cho Adaptive Online Calibration.
    private var consecutiveNilOCR: Int = 0
    private var isShotInFlight: Bool = false
    private var shotStartedAt: TimeInterval = 0
    private var preShotPlayerX: Double = 0.20
    private var preShotTargetDistance: Double = 10.0
    private var preShotCameraWidthNorm: Double = 0.50
    private var preShotBaselineLuma: [UInt8] = []

    private let minimumFrameInterval: TimeInterval = 0.033 // 30 FPS (33ms)
    private let minimumOCRInterval: TimeInterval = 0.050   // 20 Hz (50ms)
    private let maxAngleCropWidth: CGFloat = 640.0

    deinit {
        stopHeartbeatTimer()
        closeUDPSocket()
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let now = Date().timeIntervalSince1970
        stateLock.lock()
        lastProcessedTime = 0
        lastOCRStartedAt = 0
        isProcessingFrame = false
        isOCRBusy = false
        isCurrentlyLandscape = false
        frameCounter = 1
        lastPacketSentTime = now
        lastPlayerPos = CGPoint(x: 0.20, y: 0.72)
        lastEnemyPos = CGPoint(x: 0.70, y: 0.72)
        lastCameraWidthNorm = 0.50
        lastMinimapAspect = 0.36
        lastTerrainProfile = []
        lastRawDistanceUnits = 10.0
        lastAngle = 50
        consecutiveNilOCR = 0
        isShotInFlight = false
        preShotBaselineLuma = []
        calibrationEngine.reset()

        let startupTelemetry = buildTelemetryLocked(frameId: 1)
        stateLock.unlock()

        sendUDPPacket(startupTelemetry)
        ipc.saveTelemetry(startupTelemetry)

        startHeartbeatTimer()
    }

    override func broadcastPaused() {
        // Giữ heartbeat khi khung hình ngang đứng yên.
    }

    override func broadcastResumed() {
        stateLock.lock()
        lastProcessedTime = 0
        stateLock.unlock()
    }

    override func broadcastFinished() {
        stopHeartbeatTimer()
        closeUDPSocket()
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
            var ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
            let origin = ciImage.extent.origin
            if origin != .zero {
                ciImage = ciImage.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
            }

            let extent = ciImage.extent
            guard extent.width > 0, extent.height > 0 else { return }

            // Bỏ qua khung hình dọc (màn hình chính iPhone / app GunnyCalc).
            guard extent.width > extent.height else {
                stateLock.lock()
                isCurrentlyLandscape = false
                stateLock.unlock()
                return
            }

            stateLock.lock()
            let fallbackPlayer = lastPlayerPos
            let fallbackEnemy = lastEnemyPos
            stateLock.unlock()

            // 1. Phân tích Minimap (HSV + 8-Neighbor CCL + khung camera trắng + địa hình 32 cột).
            let analysis: MinimapAnalysisResult?
            if let nativeStrip = renderNativeMinimapStrip(from: ciImage) {
                analysis = visionProcessor.analyzeMinimap(
                    from: nativeStrip,
                    fallbackPlayerPos: fallbackPlayer,
                    fallbackEnemyPos: fallbackEnemy
                )
            } else {
                analysis = nil
            }

            stateLock.lock()
            isCurrentlyLandscape = true

            if let analysis {
                lastMinimapAspect = analysis.minimapAspectHOverW
                lastTerrainProfile = analysis.terrainProfile

                // Khóa tự động chiều rộng khung camera trắng = 10.0 đơn vị cự ly theo tỷ lệ zoom từng bản đồ.
                if let camW = analysis.cameraWidthNorm, camW >= 0.22, camW <= 0.88 {
                    lastCameraWidthNorm = camW
                }

                if let playerPos = analysis.playerPos {
                    lastPlayerPos = playerPos
                }

                if let nearestEnemy = analysis.enemyPositions.first {
                    lastEnemyPos = nearestEnemy
                    let safeCamW = min(max(lastCameraWidthNorm, 0.20), 0.90)
                    lastRawDistanceUnits = (abs(Double(nearestEnemy.x - lastPlayerPos.x)) / safeCamW) * BallisticsEngine.unitsPerScreen
                }

                // Thuật toán 3: Theo dõi vệt nổ trên Minimap khi đạn đang bay để tự học `mapScaleMultiplier`.
                if isShotInFlight {
                    if (now - shotStartedAt) > 5.0 {
                        isShotInFlight = false
                    } else if !preShotBaselineLuma.isEmpty,
                              let impactX = visionProcessor.detectImpactFlashX(
                                  baseline: preShotBaselineLuma,
                                  current: analysis.lumaGrid64x24,
                                  playerX: preShotPlayerX
                              ) {
                        let safeCamW = min(max(preShotCameraWidthNorm, 0.20), 0.90)
                        let actualDistance = (abs(impactX - preShotPlayerX) / safeCamW) * BallisticsEngine.unitsPerScreen
                        calibrationEngine.recordShotOutcome(
                            targetDistance: preShotTargetDistance,
                            actualDistance: actualDistance
                        )
                        isShotInFlight = false
                    }
                } else {
                    preShotPlayerX = Double(lastPlayerPos.x)
                    preShotTargetDistance = lastRawDistanceUnits
                    preShotCameraWidthNorm = lastCameraWidthNorm
                    preShotBaselineLuma = analysis.lumaGrid64x24
                }
            }

            let shouldDispatchOCR = !isOCRBusy && (now - lastOCRStartedAt) >= minimumOCRInterval
            if shouldDispatchOCR {
                isOCRBusy = true
                lastOCRStartedAt = now
            }

            frameCounter += 1
            let currentFrameId = frameCounter
            lastPacketSentTime = Date().timeIntervalSince1970
            let telemetry = buildTelemetryLocked(frameId: currentFrameId)
            stateLock.unlock()

            sendUDPPacket(telemetry)

            // 2. Chạy OCR đen trắng tương phản cao (.accurate) trên luồng song song mỗi 50ms.
            if shouldDispatchOCR {
                if let contrastAngleCrop = renderContrastAngleCrop(from: ciImage) {
                    dispatchAngleOCR(contrastAngleImage: contrastAngleCrop)
                } else {
                    stateLock.lock()
                    isOCRBusy = false
                    stateLock.unlock()
                }
            }
        }
    }

    // MARK: - Parallel High-Contrast Accurate Angle OCR (50ms)

    private func dispatchAngleOCR(contrastAngleImage: CGImage) {
        angleOCRQueue.async { [weak self] in
            autoreleasepool {
                guard let self else { return }
                defer {
                    self.stateLock.lock()
                    self.isOCRBusy = false
                    self.stateLock.unlock()
                }

                let detectedAngle = self.visionProcessor.detectAngle(fromContrastImage: contrastAngleImage)

                self.stateLock.lock()
                if let detectedAngle {
                    let angleChanged = detectedAngle != self.lastAngle
                    self.lastAngle = detectedAngle
                    self.consecutiveNilOCR = 0
                    self.isShotInFlight = false

                    if angleChanged {
                        self.frameCounter += 1
                        let immediateId = self.frameCounter
                        self.lastPacketSentTime = Date().timeIntervalSince1970
                        let immediateTelemetry = self.buildTelemetryLocked(frameId: immediateId)
                        self.stateLock.unlock()
                        self.sendUDPPacket(immediateTelemetry)
                        return
                    }
                } else {
                    // Khi chữ góc biến mất liên tiếp >= 2 lần (~100ms), kích hoạt theo dõi điểm rơi/vụ nổ trên Minimap.
                    self.consecutiveNilOCR += 1
                    if self.consecutiveNilOCR >= 2 && !self.isShotInFlight && !self.preShotBaselineLuma.isEmpty {
                        self.isShotInFlight = true
                        self.shotStartedAt = Date().timeIntervalSince1970
                    }
                }
                self.stateLock.unlock()
            }
        }
    }

    // MARK: - Telemetry Assembly (Ballistics + Terrain Raycast + Online Calibration)

    private func buildTelemetryLocked(frameId: Int) -> TelemetryData {
        let calibratedDist = calibrationEngine.calibratedDistance(rawDistanceUnits: lastRawDistanceUnits)
        let power = ballisticsEngine.calculatePower(distanceUnits: calibratedDist, angle: lastAngle)
        let raycast = ballisticsEngine.checkTerrainObstruction(
            playerPos: lastPlayerPos,
            enemyPos: lastEnemyPos,
            minimapAspectHOverW: lastMinimapAspect,
            terrainProfile: lastTerrainProfile,
            angle: lastAngle
        )
        return TelemetryData(
            frameId: frameId,
            angle: lastAngle,
            power: power,
            isBlocked: raycast.isBlocked,
            suggestedAngle: raycast.suggestedAngle
        )
    }

    // MARK: - Heartbeat Timer (0.5s when static landscape)

    private func startHeartbeatTimer() {
        stopHeartbeatTimer()

        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.handleHeartbeatTick()
        }

        stateLock.lock()
        heartbeatTimer = timer
        stateLock.unlock()

        timer.resume()
    }

    private func stopHeartbeatTimer() {
        stateLock.lock()
        let existingTimer = heartbeatTimer
        heartbeatTimer = nil
        stateLock.unlock()

        existingTimer?.setEventHandler {}
        existingTimer?.cancel()
    }

    private func handleHeartbeatTick() {
        let now = Date().timeIntervalSince1970
        stateLock.lock()
        guard isCurrentlyLandscape, (now - lastPacketSentTime) >= 0.45 else {
            stateLock.unlock()
            return
        }

        frameCounter += 1
        let currentFrameId = frameCounter
        lastPacketSentTime = now
        let telemetry = buildTelemetryLocked(frameId: currentFrameId)
        stateLock.unlock()

        sendUDPPacket(telemetry)
        ipc.saveTelemetry(telemetry)
    }

    // MARK: - Safe Darwin BSD UDP Sender

    private func ensureUDPSocketLocked() -> (Int32, sockaddr_in)? {
        if udpSocketFD >= 0, let existingDest = udpDestination {
            return (udpSocketFD, existingDest)
        }

        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }

        var noSigPipe: Int32 = 1
        _ = Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = BSDUDPConfig.port.bigEndian

        let ptonStatus = BSDUDPConfig.host.withCString { cHost in
            Darwin.inet_pton(AF_INET, cHost, &addr.sin_addr)
        }
        guard ptonStatus == 1 else {
            Darwin.close(fd)
            return nil
        }

        udpSocketFD = fd
        udpDestination = addr
        return (fd, addr)
    }

    private func sendUDPPacket(_ telemetry: TelemetryData) {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(telemetry)
        } catch {
            return
        }
        guard !payload.isEmpty else { return }

        udpLock.lock()
        defer { udpLock.unlock() }

        guard let (fd, dest) = ensureUDPSocketLocked() else { return }
        var mutableDest = dest
        let sentCount: ssize_t = payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return withUnsafePointer(to: &mutableDest) { destPtr in
                destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                    Darwin.sendto(
                        fd,
                        baseAddress,
                        rawBuffer.count,
                        0,
                        sockAddrPtr,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }

        if sentCount < 0 {
            let err = errno
            if err != EAGAIN && err != EWOULDBLOCK {
                Darwin.close(fd)
                udpSocketFD = -1
                udpDestination = nil
            }
        }
    }

    private func closeUDPSocket() {
        udpLock.lock()
        if udpSocketFD >= 0 {
            Darwin.close(udpSocketFD)
            udpSocketFD = -1
        }
        udpDestination = nil
        udpLock.unlock()
    }

    // MARK: - Orientation, Native Minimap Crop & High-Contrast Angle Crop

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

    private func renderNativeMinimapStrip(from ciImage: CIImage) -> CGImage? {
        let cropRect = ciRectFromTopLeft(
            normRect: GunnyROIs.minimapStrip,
            imageWidth: ciImage.extent.width,
            imageHeight: ciImage.extent.height
        ).intersection(ciImage.extent)
        guard cropRect.width >= 8, cropRect.height >= 6 else { return nil }

        let patch = ciImage
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))

        let bounds = CGRect(
            x: 0,
            y: 0,
            width: floor(patch.extent.width),
            height: floor(patch.extent.height)
        )
        guard bounds.width >= 8, bounds.height >= 6 else { return nil }
        return sharedCIContext.createCGImage(patch, from: bounds)
    }

    /// Cắt vùng chữ góc bằng `ciRectFromTopLeft` và chuyển sang đen trắng tương phản cao (`contrast = 1.8`, `saturation = 0.0`).
    private func renderContrastAngleCrop(from ciImage: CIImage) -> CGImage? {
        let cropRect = ciRectFromTopLeft(
            normRect: GunnyROIs.angleBattlefield,
            imageWidth: ciImage.extent.width,
            imageHeight: ciImage.extent.height
        ).intersection(ciImage.extent)
        guard cropRect.width >= 16, cropRect.height >= 16 else { return nil }

        var patch = ciImage
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))

        if patch.extent.width > maxAngleCropWidth, patch.extent.width > 0 {
            let scale = maxAngleCropWidth / patch.extent.width
            patch = patch.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        patch = patch.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputContrastKey: 1.8,
                kCIInputSaturationKey: 0.0
            ]
        )

        let bounds = CGRect(
            x: 0,
            y: 0,
            width: floor(patch.extent.width),
            height: floor(patch.extent.height)
        )
        guard bounds.width >= 16, bounds.height >= 16 else { return nil }
        return sharedCIContext.createCGImage(patch, from: bounds, format: .L8, colorSpace: grayColorSpace)
    }
}
