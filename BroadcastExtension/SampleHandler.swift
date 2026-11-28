import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import ReplayKit

/// Handler nhận khung hình thụ động từ ReplayKit theo kiến trúc hợp nhất 3 tầng (Multi-Cue Fusion, < 25MB RAM, < 35ms):
/// - Chạy 24/24 ở tốc độ 30 FPS (mỗi 33ms) khi màn hình xoay ngang (`width > height`), dùng 1 `CIContext` duy nhất trong `autoreleasepool`.
/// - Tầng 1 (Ưu tiên cao nhất): Quét thanh máu xanh người chơi và thanh máu đỏ địch trên màn hình chính (`< 10` đơn vị).
/// - Tầng 2: Cắt Minimap (`0.848, 0.042, 0.148, 0.106`), tìm tâm X + đáy chân `groundY` và dò viền đứng khung camera `10.0` đơn vị (`0.42...0.86`).
/// - Tầng 3: Đối chiếu vạch chia `5.0` đơn vị trên thước vàng đáy Minimap (`0.848, 0.148, 0.148, 0.015`, mặc định dự phòng `0.62`).
/// - Đọc góc bắn `-35° ... 85°` song song 50ms và truyền tức thời qua BSD UDP `127.0.0.1:45678` (an toàn tuyệt đối, không force-unwrap).
final class SampleHandler: RPBroadcastSampleHandler {
    private let sharedCIContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    private let grayColorSpace = CGColorSpaceCreateDeviceGray()
    private let visionProcessor = VisionProcessor()
    private let ballisticsEngine = BallisticsEngine()
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
    private var lastPlayerPos = CGPoint(x: 0.25, y: 0.65)
    private var lastEnemyPos: CGPoint?
    private var lastScreenWidthNorm: Double = VisionProcessor.defaultScreenWidthNorm // 0.62
    private var lastDistanceUnits: Double = 10.0
    private var lastDeltaYUnits: Double = 0.0
    private var lastAngle: Int = 50

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
        lastPlayerPos = CGPoint(x: 0.25, y: 0.65)
        lastEnemyPos = nil
        lastScreenWidthNorm = VisionProcessor.defaultScreenWidthNorm
        lastDistanceUnits = 10.0
        lastDeltaYUnits = 0.0
        lastAngle = 50
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
            let previousEnemy = lastEnemyPos
            stateLock.unlock()

            // Tầng 1 (Ưu tiên cao nhất): Quét thanh máu người chơi & địch trực tiếp trên màn hình chính (< 10 đơn vị).
            let tier1Result: MainScreenHealthBarResult?
            if let battlefieldCrop = renderBattlefieldForTier1(from: ciImage) {
                tier1Result = visionProcessor.detectMainScreenHealthBars(battlefieldCrop: battlefieldCrop)
            } else {
                tier1Result = nil
            }

            // Tầng 2 + Tầng 3: Khi địch ngoài màn hình chính hoặc bị che thanh máu -> đo Minimap theo viền camera + thước vàng.
            let minimapAnalysis: MinimapAnalysisResult?
            if tier1Result == nil {
                if let minimapCrop = renderNativeROI(GunnyROIs.minimapStrip, from: ciImage) {
                    let yellowRulerCrop = renderNativeROI(GunnyROIs.minimapYellowRuler, from: ciImage)
                    minimapAnalysis = visionProcessor.analyzeMinimap(
                        minimapCrop: minimapCrop,
                        yellowRulerCrop: yellowRulerCrop,
                        fallbackPlayerPos: fallbackPlayer,
                        previousEnemyPos: previousEnemy
                    )
                } else {
                    minimapAnalysis = nil
                }
            } else {
                minimapAnalysis = nil
            }

            stateLock.lock()
            isCurrentlyLandscape = true

            if let tier1 = tier1Result {
                lastDistanceUnits = tier1.distanceUnits
                lastDeltaYUnits = tier1.deltaYUnits
            } else if let analysis = minimapAnalysis {
                if let measuredWidth = analysis.screenWidthNorm,
                   measuredWidth >= 0.42 && measuredWidth <= 0.86 {
                    lastScreenWidthNorm = measuredWidth
                }

                if let playerPos = analysis.playerPos {
                    lastPlayerPos = playerPos
                }

                if let enemyPos = analysis.enemyPos {
                    lastEnemyPos = enemyPos
                    let safeScreenW = min(max(lastScreenWidthNorm, 0.42), 0.86)
                    lastDistanceUnits = (abs(Double(enemyPos.x - lastPlayerPos.x)) / safeScreenW) * BallisticsEngine.unitsPerScreen
                    lastDeltaYUnits = (Double(lastPlayerPos.y - enemyPos.y) / (safeScreenW * 0.55)) * BallisticsEngine.unitsPerScreen
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

            // Chạy OCR đen trắng tương phản cao (.accurate) trên luồng song song mỗi 50ms (-35° ... 85°).
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

                guard let detectedAngle = self.visionProcessor.detectAngle(fromContrastImage: contrastAngleImage) else {
                    return
                }

                self.stateLock.lock()
                let angleChanged = detectedAngle != self.lastAngle
                self.lastAngle = detectedAngle
                if angleChanged {
                    self.frameCounter += 1
                    let immediateId = self.frameCounter
                    self.lastPacketSentTime = Date().timeIntervalSince1970
                    let immediateTelemetry = self.buildTelemetryLocked(frameId: immediateId)
                    self.stateLock.unlock()
                    self.sendUDPPacket(immediateTelemetry)
                    return
                }
                self.stateLock.unlock()
            }
        }
    }

    private func buildTelemetryLocked(frameId: Int) -> TelemetryData {
        let power = ballisticsEngine.calculatePower(
            distanceUnits: lastDistanceUnits,
            angle: lastAngle,
            deltaYUnits: lastDeltaYUnits
        )
        return TelemetryData(
            frameId: frameId,
            angle: lastAngle,
            distanceUnits: lastDistanceUnits,
            power: power
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

    // MARK: - Orientation, Tier-1 Nearest-Sampled Crop, Native ROI Crop & High-Contrast Angle Crop

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

    /// Cắt vùng chiến trường chính Tầng 1 (`0.05, 0.18, 0.90, 0.65`) với giảm 0.5x chiều ngang (nearest-neighbor để không lem màu thanh máu)
    /// và giữ nguyên độ phân giải dọc 100% để bảo toàn chính xác thanh máu mảnh (`h: 0.006...0.016`).
    private func renderBattlefieldForTier1(from ciImage: CIImage) -> CGImage? {
        let cropRect = ciRectFromTopLeft(
            normRect: GunnyROIs.mainBattlefield,
            imageWidth: ciImage.extent.width,
            imageHeight: ciImage.extent.height
        ).intersection(ciImage.extent)
        guard cropRect.width >= 32, cropRect.height >= 16 else { return nil }

        var patch = ciImage
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))

        if patch.extent.width > 960.0 {
            patch = patch
                .samplingNearest()
                .transformed(by: CGAffineTransform(scaleX: 0.5, y: 1.0))
        }

        let bounds = CGRect(
            x: 0,
            y: 0,
            width: floor(patch.extent.width),
            height: floor(patch.extent.height)
        )
        guard bounds.width >= 32, bounds.height >= 16 else { return nil }
        return sharedCIContext.createCGImage(patch, from: bounds, format: .RGBA8, colorSpace: rgbColorSpace)
    }

    private func renderNativeROI(_ normRect: CGRect, from ciImage: CIImage) -> CGImage? {
        let cropRect = ciRectFromTopLeft(
            normRect: normRect,
            imageWidth: ciImage.extent.width,
            imageHeight: ciImage.extent.height
        ).intersection(ciImage.extent)
        guard cropRect.width >= 8, cropRect.height >= 2 else { return nil }

        let patch = ciImage
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))

        let bounds = CGRect(
            x: 0,
            y: 0,
            width: floor(patch.extent.width),
            height: floor(patch.extent.height)
        )
        guard bounds.width >= 8, bounds.height >= 2 else { return nil }
        return sharedCIContext.createCGImage(patch, from: bounds, format: .RGBA8, colorSpace: rgbColorSpace)
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
