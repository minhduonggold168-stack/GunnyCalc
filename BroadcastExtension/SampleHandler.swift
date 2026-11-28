import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import ReplayKit

/// Handler nhận khung hình thụ động từ ReplayKit chế độ 24/24 khi xoay ngang (< 25MB RAM).
/// - Chỉ tạm nghỉ gửi khi màn hình đang dựng dọc (`width <= height`).
/// - Ngay khi xoay ngang (`width > height`), luôn quét Minimap ở độ phân giải gốc 25 FPS (40ms) và gửi sang PiP.
/// - Luồng OCR riêng chạy mỗi 80ms với `CIColorControls` (`contrast = 1.6`, `brightness = 0.05`) + `.accurate` bắt `Góc -35° ... 85°`.
/// - Gửi gói JSON qua BSD UDP `127.0.0.1:45678` an toàn tuyệt đối (không `!`, không `fatalError`).
final class SampleHandler: RPBroadcastSampleHandler {
    private struct LiveSnapshot {
        let playerNorm: CGPoint
        let enemyNorm: CGPoint
        let allEnemiesNorm: [CGPoint]
        let cameraWidthNorm: Double
        let minimapAspectHOverW: Double
        let angle: Double
        let minimapJPEG: Data?
        let hasLiveEnemy: Bool
        let fallbackDistanceUnits: Double
        let fallbackDeltaY: Double
    }

    private let sharedCIContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])
    private let visionProcessor = VisionProcessor()
    private let ballisticsEngine = BallisticsEngine()
    private let emaSmoother = BallisticsEMASmoother(alpha: 0.35)
    private let ipc = SharedIPC.shared

    private let stateLock = NSLock()
    private let udpLock = NSLock()
    private let heartbeatQueue = DispatchQueue(label: "com.gunny.pipcalc.broadcast.heartbeat", qos: .utility)
    private let angleOCRQueue = DispatchQueue(label: "com.gunny.pipcalc.broadcast.angleOCR", qos: .userInitiated)

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

    // Bộ đệm trạng thái liên tục 24/24 (không bao giờ khóa màn hình PiP khi thiếu chấm đỏ).
    private let defaultCameraWidthNorm: Double = 0.62
    private var lastCameraWidthNorm: Double = 0.62
    private var hasSeenCameraRect: Bool = false
    private var missingCameraFrames: Int = 0
    private var lastMinimapAspect: Double = 0.56
    private var lastMinimapJPEG: Data?

    private var lastPlayerNorm = CGPoint(x: 0.20, y: 0.68)
    private var lastEnemyNorm = CGPoint(x: 0.82, y: 0.68)
    private var lastAllEnemiesNorm: [CGPoint] = []
    private var hasLockedEnemy: Bool = false
    private var lostTrackCount: Int = 0
    private var switchCandidateCount: Int = 0

    private var lastValidDistanceUnits: Double = 10.0
    private var lastValidDeltaY: Double = 0.0

    private var lastAngle: Double = 50.0
    private var hasConfirmedAngle: Bool = false
    private var pendingAngle: Double?
    private var pendingAngleCount: Int = 0

    private let minimumFrameInterval: TimeInterval = 0.040 // 25 FPS (40ms)
    private let minimumOCRInterval: TimeInterval = 0.080   // 12.5 Hz (80ms)
    private let maxAngleCropWidth: CGFloat = 960.0

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
        lastCameraWidthNorm = defaultCameraWidthNorm
        hasSeenCameraRect = false
        missingCameraFrames = 0
        hasLockedEnemy = false
        lostTrackCount = 0
        switchCandidateCount = 0
        lastAllEnemiesNorm = []
        lastValidDistanceUnits = 10.0
        lastValidDeltaY = 0.0
        hasConfirmedAngle = false
        pendingAngle = nil
        pendingAngleCount = 0
        emaSmoother.reset()
        let initialSnapshot = currentSnapshotLocked(hasLiveEnemy: false)
        let startupTelemetry = buildTelemetryLocked(frameId: 1, from: initialSnapshot, targetSwitched: true)
        stateLock.unlock()

        sendUDPPacket(startupTelemetry)
        ipc.saveTelemetry(startupTelemetry)

        startHeartbeatTimer()
    }

    override func broadcastPaused() {
        // Giữ heartbeat khi màn hình ngang tạm dừng thay đổi khung hình.
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

            // Chỉ tạm nghỉ gửi dữ liệu khi màn hình đang dựng dọc (Home Screen / trong app GunnyCalc).
            guard extent.width > extent.height else {
                stateLock.lock()
                isCurrentlyLandscape = false
                stateLock.unlock()
                return
            }

            // 1. Cắt Minimap trực tiếp ở độ phân giải gốc (tuyệt đối không thu nhỏ trước khi cắt).
            let minimap: MinimapAnalysis?
            if let nativeMinimapCrop = renderNativeMinimapCrop(from: ciImage) {
                minimap = visionProcessor.analyzeMinimapCrop(nativeMinimapCrop, includeJPEG: true)
            } else {
                minimap = nil
            }

            stateLock.lock()
            isCurrentlyLandscape = true
            var targetSwitched = false
            var hasLiveEnemy = false

            if let minimap {
                lastMinimapAspect = minimap.minimapAspectHOverW
                if let jpeg = minimap.minimapJPEG {
                    lastMinimapJPEG = jpeg
                }

                // Khung camera trắng = 10.0 đơn vị; nếu không thấy khung trắng thì dùng chuẩn 62% chiều rộng Minimap.
                if let camRect = minimap.cameraRect, camRect.width >= 0.22, camRect.width <= 0.85 {
                    if !hasSeenCameraRect {
                        lastCameraWidthNorm = camRect.width
                        hasSeenCameraRect = true
                    } else {
                        lastCameraWidthNorm = 0.25 * camRect.width + 0.75 * lastCameraWidthNorm
                    }
                    missingCameraFrames = 0
                } else {
                    missingCameraFrames += 1
                    if !hasSeenCameraRect || missingCameraFrames >= 25 {
                        lastCameraWidthNorm = defaultCameraWidthNorm
                    }
                }

                if let playerPos = minimap.playerPos {
                    lastPlayerNorm = playerPos
                }

                if !minimap.enemies.isEmpty {
                    hasLiveEnemy = true
                    targetSwitched = updateLockedEnemyLocked(detectedEnemies: minimap.enemies)
                    let safeCamW = min(max(lastCameraWidthNorm, 0.12), 0.90)
                    let safeAspect = min(max(lastMinimapAspect, 0.35), 2.5)
                    lastValidDistanceUnits = (abs(Double(lastEnemyNorm.x - lastPlayerNorm.x)) / safeCamW) * BallisticsEngine.unitsPerScreen
                    lastValidDeltaY = ((Double(lastPlayerNorm.y - lastEnemyNorm.y) * safeAspect) / safeCamW) * BallisticsEngine.unitsPerScreen
                } else {
                    // Chưa thấy chấm đỏ: giữ nguyên cự ly hợp lệ gần nhất (mặc định 10.0), vẫn cập nhật góc & bảng lực.
                    lastAllEnemiesNorm = []
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
            let snapshot = currentSnapshotLocked(hasLiveEnemy: hasLiveEnemy)
            let telemetry = buildTelemetryLocked(frameId: currentFrameId, from: snapshot, targetSwitched: targetSwitched)
            stateLock.unlock()

            // Gửi ngay gói UDP 25 FPS sang PiP mà không bao giờ khóa giao diện.
            sendUDPPacket(telemetry)
            ipc.saveTelemetry(telemetry)

            // 2. Luồng OCR riêng mỗi 80ms với CIColorControls (contrast = 1.6, brightness = 0.05) + .accurate.
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

    // MARK: - Asynchronous High-Sensitivity Angle OCR (80ms)

    private func dispatchAngleOCR(contrastAngleImage: CGImage) {
        angleOCRQueue.async { [weak self] in
            autoreleasepool {
                guard let self else { return }
                defer {
                    self.stateLock.lock()
                    self.isOCRBusy = false
                    self.stateLock.unlock()
                }

                let detected = self.visionProcessor.detectBattlefieldAngle(fromContrastImage: contrastAngleImage)
                guard let detected else { return }

                self.stateLock.lock()
                self.updateAngleLocked(detectedAngle: detected)
                self.stateLock.unlock()
            }
        }
    }

    private func updateAngleLocked(detectedAngle: Double) {
        guard detectedAngle >= -35.0 && detectedAngle <= 85.0 else { return }

        if !hasConfirmedAngle || abs(detectedAngle - lastAngle) <= 22.0 {
            lastAngle = detectedAngle
            hasConfirmedAngle = true
            pendingAngle = nil
            pendingAngleCount = 0
            return
        }

        // Tránh nhảy vọt do 1 khung hình hiệu ứng: yêu cầu 2 lần đọc liên tiếp khớp ±2° (160ms).
        if let pending = pendingAngle, abs(detectedAngle - pending) <= 2.0 {
            pendingAngleCount += 1
            if pendingAngleCount >= 2 {
                lastAngle = detectedAngle
                hasConfirmedAngle = true
                pendingAngle = nil
                pendingAngleCount = 0
            }
        } else {
            pendingAngle = detectedAngle
            pendingAngleCount = 1
        }
    }

    // MARK: - Hysteresis Target Tracking (Locked)

    private func updateLockedEnemyLocked(detectedEnemies: [CGPoint]) -> Bool {
        lastAllEnemiesNorm = detectedEnemies

        var nearestIdx = 0
        var minPlayerDist = Double.greatestFiniteMagnitude
        for (idx, pt) in detectedEnemies.enumerated() {
            let d = hypot(Double(pt.x - lastPlayerNorm.x), Double(pt.y - lastPlayerNorm.y))
            if d < minPlayerDist {
                minPlayerDist = d
                nearestIdx = idx
            }
        }

        if !hasLockedEnemy {
            hasLockedEnemy = true
            lastEnemyNorm = detectedEnemies[nearestIdx]
            lostTrackCount = 0
            switchCandidateCount = 0
            return true
        }

        let trackRadius = 0.075
        var trackedIdx: Int?
        var minTrackDelta = Double.greatestFiniteMagnitude
        for (idx, pt) in detectedEnemies.enumerated() {
            let delta = hypot(Double(pt.x - lastEnemyNorm.x), Double(pt.y - lastEnemyNorm.y))
            if delta <= trackRadius && delta < minTrackDelta {
                minTrackDelta = delta
                trackedIdx = idx
            }
        }

        if let tracked = trackedIdx {
            lostTrackCount = 0
            let trackedDist = hypot(
                Double(detectedEnemies[tracked].x - lastPlayerNorm.x),
                Double(detectedEnemies[tracked].y - lastPlayerNorm.y)
            )

            if nearestIdx != tracked && minPlayerDist < (trackedDist - 0.045) {
                switchCandidateCount += 1
                if switchCandidateCount >= 3 {
                    lastEnemyNorm = detectedEnemies[nearestIdx]
                    switchCandidateCount = 0
                    return true
                }
            } else {
                switchCandidateCount = 0
            }

            lastEnemyNorm = detectedEnemies[tracked]
            return false
        }

        switchCandidateCount = 0
        lostTrackCount += 1
        if lostTrackCount >= 3 {
            lastEnemyNorm = detectedEnemies[nearestIdx]
            lostTrackCount = 0
            return true
        }

        return false
    }

    // MARK: - Snapshot & Heartbeat Timer (0.5s when static landscape)

    private func currentSnapshotLocked(hasLiveEnemy: Bool) -> LiveSnapshot {
        LiveSnapshot(
            playerNorm: lastPlayerNorm,
            enemyNorm: lastEnemyNorm,
            allEnemiesNorm: lastAllEnemiesNorm,
            cameraWidthNorm: lastCameraWidthNorm,
            minimapAspectHOverW: lastMinimapAspect,
            angle: lastAngle,
            minimapJPEG: lastMinimapJPEG,
            hasLiveEnemy: hasLiveEnemy,
            fallbackDistanceUnits: lastValidDistanceUnits,
            fallbackDeltaY: lastValidDeltaY
        )
    }

    private func buildTelemetryLocked(
        frameId: Int,
        from snapshot: LiveSnapshot,
        targetSwitched: Bool
    ) -> TelemetryData {
        ballisticsEngine.buildBattleTelemetry(
            frameId: frameId,
            playerNorm: snapshot.playerNorm,
            enemyNorm: snapshot.enemyNorm,
            allEnemiesNorm: snapshot.allEnemiesNorm,
            cameraWidthNorm: snapshot.cameraWidthNorm,
            minimapAspectHOverW: snapshot.minimapAspectHOverW,
            angle: snapshot.angle,
            minimapJPEG: snapshot.minimapJPEG,
            smoother: emaSmoother,
            targetSwitched: targetSwitched,
            distanceOverride: snapshot.hasLiveEnemy ? nil : snapshot.fallbackDistanceUnits,
            deltaYOverride: snapshot.hasLiveEnemy ? nil : snapshot.fallbackDeltaY
        )
    }

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
        // Chỉ gửi heartbeat khi đang ở màn hình ngang (dừng gửi khi màn hình dựng dọc).
        guard isCurrentlyLandscape, (now - lastPacketSentTime) >= 0.45 else {
            stateLock.unlock()
            return
        }

        frameCounter += 1
        let currentFrameId = frameCounter
        lastPacketSentTime = now
        let snapshot = currentSnapshotLocked(hasLiveEnemy: !lastAllEnemiesNorm.isEmpty)
        let telemetry = buildTelemetryLocked(frameId: currentFrameId, from: snapshot, targetSwitched: false)
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
        var sendBuf: Int32 = 65536
        _ = Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDBUF,
            &sendBuf,
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
        let encoder = JSONEncoder()
        var encoded: Data?
        do {
            encoded = try encoder.encode(telemetry)
        } catch {
            return
        }

        if let data = encoded, data.count > BSDUDPConfig.safeDatagramLimit {
            var trimmed = telemetry
            trimmed.minimapJPEG = nil
            encoded = try? encoder.encode(trimmed)
        }

        guard let payload = encoded, !payload.isEmpty else { return }

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
            if err != EAGAIN && err != EWOULDBLOCK && err != EMSGSIZE {
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

    // MARK: - Native Minimap Crop & High-Contrast Angle Crop

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

    /// Cắt trực tiếp vùng Minimap ở 100% độ phân giải gốc từ CVPixelBuffer (không thu nhỏ ảnh trước khi cắt).
    private func renderNativeMinimapCrop(from ciImage: CIImage) -> CGImage? {
        let cropRect = GunnyROIs.minimap.ciRect(width: ciImage.extent.width, height: ciImage.extent.height)
        guard cropRect.width >= 8, cropRect.height >= 8 else { return nil }

        let patch = ciImage
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))

        let bounds = CGRect(
            x: 0,
            y: 0,
            width: floor(patch.extent.width),
            height: floor(patch.extent.height)
        )
        guard bounds.width >= 8, bounds.height >= 8 else { return nil }
        return sharedCIContext.createCGImage(patch, from: bounds)
    }

    /// Cắt vùng chữ `Góc XX°` và tăng tương phản bằng `CIColorControls` (`contrast = 1.6`, `brightness = 0.05`) trước khi đưa vào Vision `.accurate`.
    private func renderContrastAngleCrop(from ciImage: CIImage) -> CGImage? {
        let cropRect = GunnyROIs.angleBattlefield.ciRect(width: ciImage.extent.width, height: ciImage.extent.height)
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
                kCIInputContrastKey: 1.6,
                kCIInputBrightnessKey: 0.05
            ]
        )

        let bounds = CGRect(
            x: 0,
            y: 0,
            width: floor(patch.extent.width),
            height: floor(patch.extent.height)
        )
        guard bounds.width >= 16, bounds.height >= 16 else { return nil }
        return sharedCIContext.createCGImage(patch, from: bounds)
    }
}
