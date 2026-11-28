import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import ReplayKit

/// Handler nhận khung hình thụ động từ ReplayKit cho Gunny Mobi bản không gió (< 25MB RAM).
/// - Chỉ kích hoạt khi màn hình nằm ngang (`width > height`) và đủ 3 dấu hiệu giao diện chiến đấu (`isInBattle`).
/// - Quét Minimap trực tiếp từ `CVPixelBuffer` ở tốc độ 25 FPS (40ms) bằng 1 `sharedCIContext` trong `autoreleasepool`.
/// - Đọc góc bắn (`-30° ... 85°`) trên luồng OCR riêng mỗi 100ms, không chặn luồng 25 FPS.
/// - Gửi gói JSON qua BSD UDP `127.0.0.1:45678` an toàn tuyệt đối (không `!`, không `fatalError`).
final class SampleHandler: RPBroadcastSampleHandler {
    private struct BattleSnapshot {
        let isInBattle: Bool
        let playerNorm: CGPoint
        let enemyNorm: CGPoint
        let allEnemiesNorm: [CGPoint]
        let cameraWidthNorm: Double
        let minimapAspectHOverW: Double
        let angle: Double
        let minimapJPEG: Data?
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
    private var frameCounter: Int = 0

    // Trạng thái khóa chiến đấu (`isInBattle`) & bộ đệm chống nhảy.
    private var isInBattle: Bool = false
    private var missingUICount: Int = 0
    private var missingUnitsCount: Int = 0

    private var lastPlayerNorm = CGPoint(x: 0.20, y: 0.68)
    private var lastEnemyNorm = CGPoint(x: 0.72, y: 0.68)
    private var lastAllEnemiesNorm: [CGPoint] = []
    private var hasLockedEnemy: Bool = false
    private var lostTrackCount: Int = 0
    private var switchCandidateCount: Int = 0

    private var lastCameraWidthNorm: Double = 0.40
    private var lastMinimapAspect: Double = 0.72
    private var lastMinimapJPEG: Data?

    private var lastAngle: Double = 50.0
    private var hasConfirmedAngle: Bool = false
    private var pendingAngle: Double?
    private var pendingAngleCount: Int = 0

    private let minimumFrameInterval: TimeInterval = 0.040 // 25 FPS (40ms)
    private let minimumOCRInterval: TimeInterval = 0.100   // 10 FPS (100ms)

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
        frameCounter = 1
        lastPacketSentTime = now
        resetBattleStateLocked()
        stateLock.unlock()

        let startupWaiting = TelemetryData.waiting(frameId: 1)
        sendUDPPacket(startupWaiting)
        ipc.saveTelemetry(startupWaiting)

        startHeartbeatTimer()
    }

    override func broadcastPaused() {
        // Giữ heartbeat 0.5s để PiP duy trì kết nối khi hệ thống tạm ngưng video.
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

            // Khóa ngang tuyệt đối: màn hình dọc (Home Screen / ứng dụng khác) => isInBattle = false ngay lập tức.
            guard extent.width > extent.height else {
                emitWaitingPacket()
                return
            }

            // Kiểm tra Dấu hiệu 1 (Nút đóng đỏ [X] + thước vàng đáy Minimap) & Dấu hiệu 2 (Thanh thước lực cạnh dưới).
            let sign1Close = renderCroppedROI(GunnyROIs.battleCloseButton, from: ciImage, maxWidth: 48)
                .map { visionProcessor.detectRedCloseButton(in: $0) } ?? false
            let sign1Ruler = sign1Close
                ? (renderCroppedROI(GunnyROIs.battleMinimapRuler, from: ciImage, maxWidth: 120)
                    .map { visionProcessor.detectGoldenMinimapRuler(in: $0) } ?? false)
                : false
            let sign1 = sign1Close && sign1Ruler

            let sign2 = sign1
                ? (renderCroppedROI(GunnyROIs.battlePowerBar, from: ciImage, maxWidth: 160)
                    .map { visionProcessor.detectBottomPowerBar(in: $0) } ?? false)
                : false

            stateLock.lock()
            let wasInBattle = isInBattle
            stateLock.unlock()

            // Nếu đang ở ngoài trận và không có đủ dấu hiệu UI chiến đấu, bỏ qua quét Minimap để tiết kiệm CPU/RAM.
            if !wasInBattle && !(sign1 && sign2) {
                emitWaitingPacket()
                return
            }

            // Quét trực tiếp vùng Minimap (25 FPS) từ CVPixelBuffer qua 1 CIContext duy nhất.
            let minimap: MinimapAnalysis?
            if let minimapCrop = renderCroppedROI(GunnyROIs.minimap, from: ciImage, maxWidth: 180) {
                minimap = visionProcessor.analyzeMinimapCrop(minimapCrop, includeJPEG: true)
            } else {
                minimap = nil
            }

            let sign3 = (minimap?.playerPos != nil) && !(minimap?.enemies.isEmpty ?? true)

            stateLock.lock()
            let battleActive = updateBattleStateLocked(sign1And2: sign1 && sign2, sign3: sign3)
            guard battleActive else {
                frameCounter += 1
                let waitingId = frameCounter
                lastPacketSentTime = Date().timeIntervalSince1970
                stateLock.unlock()

                let waiting = TelemetryData.waiting(frameId: waitingId)
                sendUDPPacket(waiting)
                ipc.saveTelemetry(waiting)
                return
            }

            var targetSwitched = false
            if let minimap {
                lastMinimapAspect = minimap.minimapAspectHOverW
                if let jpeg = minimap.minimapJPEG {
                    lastMinimapJPEG = jpeg
                }
                if let camRect = minimap.cameraRect, camRect.width >= 0.20, camRect.width <= 0.72 {
                    lastCameraWidthNorm = 0.25 * camRect.width + 0.75 * lastCameraWidthNorm
                }
                if let playerPos = minimap.playerPos {
                    lastPlayerNorm = playerPos
                }
                if !minimap.enemies.isEmpty {
                    targetSwitched = updateLockedEnemyLocked(detectedEnemies: minimap.enemies)
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
            let snapshot = currentSnapshotLocked()
            let telemetry = buildTelemetryLocked(frameId: currentFrameId, from: snapshot, targetSwitched: targetSwitched)
            stateLock.unlock()

            // Gửi gói UDP 25 FPS ngay lập tức trước khi chạy OCR góc bất đồng bộ.
            sendUDPPacket(telemetry)
            ipc.saveTelemetry(telemetry)

            // Luồng OCR đọc góc bắn riêng mỗi 100ms trên vùng chiến trường (không chặn 25 FPS).
            if shouldDispatchOCR {
                if let angleCrop = renderCroppedROI(GunnyROIs.angleBattlefield, from: ciImage, maxWidth: 640) {
                    dispatchAngleOCR(croppedAngleImage: angleCrop)
                } else {
                    stateLock.lock()
                    isOCRBusy = false
                    stateLock.unlock()
                }
            }
        }
    }

    // MARK: - Asynchronous Angle OCR (100ms)

    private func dispatchAngleOCR(croppedAngleImage: CGImage) {
        angleOCRQueue.async { [weak self] in
            autoreleasepool {
                guard let self else { return }
                defer {
                    self.stateLock.lock()
                    self.isOCRBusy = false
                    self.stateLock.unlock()
                }

                let detected = self.visionProcessor.detectBattlefieldAngle(fromCroppedImage: croppedAngleImage)
                guard let detected else { return }

                self.stateLock.lock()
                self.updateAngleLocked(detectedAngle: detected)
                self.stateLock.unlock()
            }
        }
    }

    private func updateAngleLocked(detectedAngle: Double) {
        guard detectedAngle >= -30.0 && detectedAngle <= 85.0 else { return }

        if !hasConfirmedAngle || abs(detectedAngle - lastAngle) <= 20.0 {
            lastAngle = detectedAngle
            hasConfirmedAngle = true
            pendingAngle = nil
            pendingAngleCount = 0
            return
        }

        // Tránh nhảy vọt do 1 khung hình hiệu ứng đè chữ: yêu cầu 2 lần đọc liên tiếp khớp ±2°.
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

    // MARK: - Battle Lock & Hysteresis Target Tracking (Locked)

    private func updateBattleStateLocked(sign1And2: Bool, sign3: Bool) -> Bool {
        if sign1And2 && sign3 {
            isInBattle = true
            missingUICount = 0
            missingUnitsCount = 0
            return true
        }

        guard isInBattle else {
            return false
        }

        if !sign1And2 {
            missingUICount += 1
            if missingUICount >= 2 {
                resetBattleStateLocked()
                return false
            }
            return true
        }

        // Giao diện chiến đấu (dấu hiệu 1 & 2) vẫn còn, chỉ chấm Minimap bị hiệu ứng che thoáng qua.
        missingUICount = 0
        missingUnitsCount += 1
        if missingUnitsCount >= 12 {
            resetBattleStateLocked()
            return false
        }
        return true
    }

    private func resetBattleStateLocked() {
        isInBattle = false
        missingUICount = 0
        missingUnitsCount = 0
        hasLockedEnemy = false
        lostTrackCount = 0
        switchCandidateCount = 0
        lastAllEnemiesNorm = []
        lastMinimapJPEG = nil
        hasConfirmedAngle = false
        pendingAngle = nil
        pendingAngleCount = 0
        emaSmoother.reset()
    }

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

        let trackRadius = 0.070
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

            // Khóa mục tiêu gần nhất có độ trễ chống nhảy (hysteresis 3 khung hình).
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

    private func emitWaitingPacket() {
        stateLock.lock()
        resetBattleStateLocked()
        frameCounter += 1
        let waitingId = frameCounter
        lastPacketSentTime = Date().timeIntervalSince1970
        stateLock.unlock()

        let waiting = TelemetryData.waiting(frameId: waitingId)
        sendUDPPacket(waiting)
        ipc.saveTelemetry(waiting)
    }

    // MARK: - Snapshot & Heartbeat Timer (0.5s)

    private func currentSnapshotLocked() -> BattleSnapshot {
        BattleSnapshot(
            isInBattle: isInBattle,
            playerNorm: lastPlayerNorm,
            enemyNorm: lastEnemyNorm,
            allEnemiesNorm: lastAllEnemiesNorm,
            cameraWidthNorm: lastCameraWidthNorm,
            minimapAspectHOverW: lastMinimapAspect,
            angle: lastAngle,
            minimapJPEG: lastMinimapJPEG
        )
    }

    private func buildTelemetryLocked(
        frameId: Int,
        from snapshot: BattleSnapshot,
        targetSwitched: Bool
    ) -> TelemetryData {
        guard snapshot.isInBattle else {
            return TelemetryData.waiting(frameId: frameId)
        }
        return ballisticsEngine.buildBattleTelemetry(
            frameId: frameId,
            playerNorm: snapshot.playerNorm,
            enemyNorm: snapshot.enemyNorm,
            allEnemiesNorm: snapshot.allEnemiesNorm,
            cameraWidthNorm: snapshot.cameraWidthNorm,
            minimapAspectHOverW: snapshot.minimapAspectHOverW,
            angle: snapshot.angle,
            minimapJPEG: snapshot.minimapJPEG,
            smoother: emaSmoother,
            targetSwitched: targetSwitched
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
        guard (now - lastPacketSentTime) >= 0.45 else {
            stateLock.unlock()
            return
        }

        frameCounter += 1
        let currentFrameId = frameCounter
        lastPacketSentTime = now
        let snapshot = currentSnapshotLocked()
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

    // MARK: - Orientation & Direct CIImage ROI Cropping

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

    private func renderCroppedROI(
        _ roi: NormalizedRect,
        from ciImage: CIImage,
        maxWidth: CGFloat
    ) -> CGImage? {
        let cropRect = roi.ciRect(width: ciImage.extent.width, height: ciImage.extent.height)
        guard cropRect.width >= 4, cropRect.height >= 4 else { return nil }

        var patch = ciImage
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))

        if patch.extent.width > maxWidth, patch.extent.width > 0 {
            let scale = maxWidth / patch.extent.width
            patch = patch.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let bounds = CGRect(
            x: 0,
            y: 0,
            width: floor(patch.extent.width),
            height: floor(patch.extent.height)
        )
        guard bounds.width >= 4, bounds.height >= 4 else { return nil }
        return sharedCIContext.createCGImage(patch, from: bounds)
    }
}
