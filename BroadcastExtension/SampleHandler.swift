import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import ReplayKit

/// Handler nhận khung hình thụ động từ ReplayKit ở tốc độ 8 FPS (< 25MB RAM).
/// - Dùng duy nhất 1 `sharedCIContext`, bọc `processSampleBuffer` trong `autoreleasepool`.
/// - Khóa chống nhảy Gió/Góc, gom cụm mục tiêu có trễ chống nhảy (hysteresis) và làm mượt EMA (`alpha = 0.35`).
/// - Gửi gói `TelemetryData` qua `Darwin.socket` (BSD UDP `127.0.0.1:45678`) an toàn tuyệt đối (không `!`, không `fatalError`).
final class SampleHandler: RPBroadcastSampleHandler {
    private struct SnapshotState {
        let playerX: Double
        let playerY: Double
        let enemyX: Double
        let enemyY: Double
        let enemies: [NormalizedPoint]
        let lockedEnemyIndex: Int
        let cameraRect: NormalizedRect?
        let cameraWidthNorm: Double
        let minimapAspectHOverW: Double
        let angle: Double
        let wind: Double
        let windDir: Int
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

    private var heartbeatTimer: DispatchSourceTimer?
    private var udpSocketFD: Int32 = -1
    private var udpDestination: sockaddr_in?

    private var lastProcessedTime: TimeInterval = 0
    private var lastPacketSentTime: TimeInterval = 0
    private var isProcessingFrame = false
    private var frameCounter: Int = 0

    // Bộ đệm trạng thái hợp lệ gần nhất & thông số khóa chống nhảy.
    private var lastPlayerX: Double = 0.20
    private var lastPlayerY: Double = 0.68
    private var lastEnemyX: Double = 0.72
    private var lastEnemyY: Double = 0.68
    private var lastEnemies: [NormalizedPoint] = [NormalizedPoint(x: 0.72, y: 0.68)]
    private var lockedEnemyIndex: Int = 0
    private var hasLockedEnemy: Bool = false
    private var lostTrackCount: Int = 0
    private var switchCandidateCount: Int = 0

    private var lastCameraRect: NormalizedRect? = NormalizedRect(x: 0.10, y: 0.24, width: 0.40, height: 0.56)
    private var lastCameraWidthNorm: Double = 0.40
    private var lastMinimapAspect: Double = 0.72
    private var lastMinimapJPEG: Data?

    private var lastAngle: Double = 56.0
    private var pendingAngle: Double?
    private var pendingAngleCount: Int = 0

    private var lastWind: Double = 0.0
    private var lastWindDir: Int = 1
    private var pendingWindValue: Double?
    private var pendingWindDir: Int = 1
    private var pendingWindCount: Int = 0

    private let minimumFrameInterval: TimeInterval = 0.125 // 8 FPS
    private let maxScaledWidth: CGFloat = 960.0

    deinit {
        stopHeartbeatTimer()
        closeUDPSocket()
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let now = Date().timeIntervalSince1970
        stateLock.lock()
        lastProcessedTime = 0
        isProcessingFrame = false
        frameCounter = 1
        lastPacketSentTime = now
        hasLockedEnemy = false
        lostTrackCount = 0
        switchCandidateCount = 0
        pendingAngle = nil
        pendingAngleCount = 0
        pendingWindValue = nil
        pendingWindCount = 0
        emaSmoother.reset()
        let initialSnapshot = currentSnapshotLocked()
        stateLock.unlock()

        let startupTelemetry = buildTelemetry(frameId: 1, from: initialSnapshot, targetSwitched: true)
        sendUDPPacket(startupTelemetry)
        ipc.saveTelemetry(startupTelemetry)

        startHeartbeatTimer()
    }

    override func broadcastPaused() {
        // Giữ heartbeat 0.5s để PiP biết phiên truyền phát vẫn tồn tại khi hệ thống tạm ngưng video.
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
            guard let landscapeImage = makeLandscapeDownscaledCGImage(
                from: pixelBuffer,
                orientation: orientation
            ) else {
                return
            }

            // 1. Phân tích Minimap: người chơi xanh dương, cụm mục tiêu đỏ, khung camera trắng 10 đơn vị & ảnh JPEG.
            let minimap = visionProcessor.analyzeMinimap(
                from: landscapeImage,
                normalizedRect: GunnyROIs.minimap
            )

            // 2. Quét ô Gió kèm kiểm tra viền khung mũi tên chống đọc nhầm đồng hồ lượt.
            let windObs = visionProcessor.detectWind(
                from: landscapeImage,
                normalizedRect: GunnyROIs.wind
            )

            // 3. Đọc kép Góc bắn (chiến trường có ký hiệu `°` + tâm D-pad góc dưới trái), chỉ nhận 10° - 85°.
            let angleObs = visionProcessor.detectDualAngle(from: landscapeImage)

            stateLock.lock()
            var targetSwitched = false

            if let minimap {
                lastMinimapAspect = minimap.minimapAspectHOverW
                if let jpeg = minimap.minimapJPEG {
                    lastMinimapJPEG = jpeg
                }
                if let camRect = minimap.cameraRect, camRect.width >= 0.20, camRect.width <= 0.72 {
                    lastCameraRect = camRect
                    lastCameraWidthNorm = 0.25 * camRect.width + 0.75 * lastCameraWidthNorm
                }
                if let playerPos = minimap.playerPos {
                    lastPlayerX = playerPos.x
                    lastPlayerY = playerPos.y
                }
                if !minimap.enemies.isEmpty {
                    targetSwitched = updateLockedEnemyLocked(detectedEnemies: minimap.enemies)
                }
            }

            updateWindLocked(observation: windObs)
            updateAngleLocked(observation: angleObs)

            frameCounter += 1
            let currentFrameId = frameCounter
            lastPacketSentTime = Date().timeIntervalSince1970
            let snapshot = currentSnapshotLocked()
            let telemetry = buildTelemetry(frameId: currentFrameId, from: snapshot, targetSwitched: targetSwitched)
            stateLock.unlock()

            sendUDPPacket(telemetry)
            ipc.saveTelemetry(telemetry)
        }
    }

    // MARK: - Anti-Jitter Locks & Hysteresis Target Tracking (Locked)

    private func updateLockedEnemyLocked(detectedEnemies: [NormalizedPoint]) -> Bool {
        lastEnemies = detectedEnemies

        var nearestIdx = 0
        var minPlayerDist = Double.greatestFiniteMagnitude
        for (idx, pt) in detectedEnemies.enumerated() {
            let d = hypot(pt.x - lastPlayerX, pt.y - lastPlayerY)
            if d < minPlayerDist {
                minPlayerDist = d
                nearestIdx = idx
            }
        }

        if !hasLockedEnemy {
            hasLockedEnemy = true
            lockedEnemyIndex = nearestIdx
            lastEnemyX = detectedEnemies[nearestIdx].x
            lastEnemyY = detectedEnemies[nearestIdx].y
            lostTrackCount = 0
            switchCandidateCount = 0
            return true
        }

        // Tìm mục tiêu khớp với vị trí đang khóa trong bán kính dung sai 0.070.
        let trackRadius = 0.070
        var trackedIdx: Int?
        var minTrackDelta = Double.greatestFiniteMagnitude
        for (idx, pt) in detectedEnemies.enumerated() {
            let delta = hypot(pt.x - lastEnemyX, pt.y - lastEnemyY)
            if delta <= trackRadius && delta < minTrackDelta {
                minTrackDelta = delta
                trackedIdx = idx
            }
        }

        if let tracked = trackedIdx {
            lostTrackCount = 0
            let trackedDistToPlayer = hypot(detectedEnemies[tracked].x - lastPlayerX, detectedEnemies[tracked].y - lastPlayerY)

            // Chỉ chuyển khóa sang mục tiêu mới nếu gần hơn hẳn ít nhất 0.045 trong 3 khung hình liên tiếp.
            if nearestIdx != tracked && minPlayerDist < (trackedDistToPlayer - 0.045) {
                switchCandidateCount += 1
                if switchCandidateCount >= 3 {
                    lockedEnemyIndex = nearestIdx
                    lastEnemyX = detectedEnemies[nearestIdx].x
                    lastEnemyY = detectedEnemies[nearestIdx].y
                    switchCandidateCount = 0
                    return true
                }
            } else {
                switchCandidateCount = 0
            }

            lockedEnemyIndex = tracked
            lastEnemyX = detectedEnemies[tracked].x
            lastEnemyY = detectedEnemies[tracked].y
            return false
        }

        // Nếu chấm đỏ bị hiệu ứng che 1-2 khung hình, giữ nguyên mục tiêu cũ trước khi chuyển sang nearestIdx.
        switchCandidateCount = 0
        lostTrackCount += 1
        if lostTrackCount >= 3 {
            lockedEnemyIndex = nearestIdx
            lastEnemyX = detectedEnemies[nearestIdx].x
            lastEnemyY = detectedEnemies[nearestIdx].y
            lostTrackCount = 0
            return true
        }

        return false
    }

    private func updateWindLocked(observation: WindObservation) {
        if !observation.hasWindFrame {
            lastWind = 0.0
            lastWindDir = 1
            pendingWindValue = nil
            pendingWindCount = 0
            return
        }

        guard let detectedWind = observation.value else {
            return
        }

        let resolvedDir = detectedWind < 0.05 ? 1 : observation.direction
        let isSmallDelta = abs(detectedWind - lastWind) <= 0.6
        let isSameDir = (detectedWind < 0.05) || (lastWind < 0.05) || (resolvedDir == lastWindDir)

        if (isSmallDelta && isSameDir) || frameCounter <= 2 {
            lastWind = detectedWind
            lastWindDir = resolvedDir
            pendingWindValue = nil
            pendingWindCount = 0
            return
        }

        if let pending = pendingWindValue,
           abs(detectedWind - pending) <= 0.4,
           resolvedDir == pendingWindDir {
            pendingWindCount += 1
            if pendingWindCount >= 2 {
                lastWind = detectedWind
                lastWindDir = resolvedDir
                pendingWindValue = nil
                pendingWindCount = 0
            }
        } else {
            pendingWindValue = detectedWind
            pendingWindDir = resolvedDir
            pendingWindCount = 1
        }
    }

    private func updateAngleLocked(observation: AngleObservation) {
        let candidate: Double?
        let highConfidence: Bool

        switch (observation.battlefieldAngle, observation.dpadAngle) {
        case let (b?, d?):
            if abs(b - d) <= 2.0 {
                candidate = ((b + d) * 0.5).rounded()
                highConfidence = true
            } else if abs(b - lastAngle) <= abs(d - lastAngle) {
                candidate = b
                highConfidence = false
            } else {
                candidate = d
                highConfidence = false
            }
        case let (b?, nil):
            candidate = b
            highConfidence = false
        case let (nil, d?):
            candidate = d
            highConfidence = false
        case (nil, nil):
            pendingAngleCount = 0
            return
        }

        guard let cand = candidate, cand >= 10.0 && cand <= 85.0 else {
            return
        }

        let delta = abs(cand - lastAngle)
        if (highConfidence && delta <= 25.0) || delta <= 15.0 || frameCounter <= 2 {
            lastAngle = cand
            pendingAngle = nil
            pendingAngleCount = 0
            return
        }

        if let pending = pendingAngle, abs(cand - pending) <= 2.0 {
            pendingAngleCount += 1
            if pendingAngleCount >= 2 {
                lastAngle = cand
                pendingAngle = nil
                pendingAngleCount = 0
            }
        } else {
            pendingAngle = cand
            pendingAngleCount = 1
        }
    }

    // MARK: - Snapshot & Heartbeat Timer (0.5s)

    private func currentSnapshotLocked() -> SnapshotState {
        SnapshotState(
            playerX: lastPlayerX,
            playerY: lastPlayerY,
            enemyX: lastEnemyX,
            enemyY: lastEnemyY,
            enemies: lastEnemies,
            lockedEnemyIndex: lockedEnemyIndex,
            cameraRect: lastCameraRect,
            cameraWidthNorm: lastCameraWidthNorm,
            minimapAspectHOverW: lastMinimapAspect,
            angle: lastAngle,
            wind: lastWind,
            windDir: lastWindDir,
            minimapJPEG: lastMinimapJPEG
        )
    }

    private func buildTelemetry(frameId: Int, from snapshot: SnapshotState, targetSwitched: Bool) -> TelemetryData {
        ballisticsEngine.buildTelemetry(
            frameId: frameId,
            playerX: snapshot.playerX,
            playerY: snapshot.playerY,
            enemyX: snapshot.enemyX,
            enemyY: snapshot.enemyY,
            enemies: snapshot.enemies,
            lockedEnemyIndex: snapshot.lockedEnemyIndex,
            cameraRect: snapshot.cameraRect,
            cameraWidthNorm: snapshot.cameraWidthNorm,
            minimapAspectHOverW: snapshot.minimapAspectHOverW,
            angle: snapshot.angle,
            windMagnitude: snapshot.wind,
            windDir: snapshot.windDir,
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
        let telemetry = buildTelemetry(frameId: currentFrameId, from: snapshot, targetSwitched: false)
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

        // Luôn xoay sang đúng chiều ngang (width > height) trước khi cắt các vùng Gunny Mobi.
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
