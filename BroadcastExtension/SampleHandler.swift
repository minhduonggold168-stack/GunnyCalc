import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ReplayKit

/// Handler nhận khung hình thụ động từ ReplayKit (< 12 MB RAM, độ trễ < 0.05s):
/// - Khóa bộ nhớ trực tiếp `CVPixelBufferLockBaseAddress(..., .readOnly)` và đọc mảng byte `BGRA` ở tốc độ 25 FPS (40ms).
/// - Tự khóa chiều xoay chuẩn qua điểm neo nút đóng đỏ `[X]` tại `(0.955, 0.025)`; mất `[X]` -> gửi `isInBattle = false` ngay.
/// - Đo cự ly hợp nhất 3 tầng: (1) thanh máu xanh/đỏ màn hình chính -> (2) Minimap dải trời `0.46...0.76` (mặc định `0.65`) -> (3) giữ ổn định.
/// - Cắt 1 `CGImage` xám `260×130` (~33 KB) ngay trên thanh máu xanh, chạy `.fast` OCR mỗi `60ms` giữ góc hợp lệ gần nhất.
/// - Truyền tức thời qua BSD UDP `127.0.0.1:45678` (tuyệt đối không dùng bộ lọc trễ EMA hay khung hình trung gian toàn màn hình).
final class SampleHandler: RPBroadcastSampleHandler {
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
    private var isCurrentlyInBattle = false
    private var lockedOrientationMode: BufferOrientationMode?
    private var frameCounter: Int = 0

    // Trạng thái tức thời (không EMA).
    private var lastMinimapPlayerPos = CGPoint(x: 0.25, y: 0.65)
    private var lastMinimapEnemyPos: CGPoint?
    private var lastScreenWidthNorm: Double = VisionProcessor.defaultScreenWidthNorm // 0.65
    private var lastDistanceUnits: Double = 10.0
    private var lastDeltaYUnits: Double = 0.0
    private var lastAngle: Int = 50

    private let minimumFrameInterval: TimeInterval = 0.040 // 25 FPS (40ms)
    private let minimumOCRInterval: TimeInterval = 0.060   // 60ms

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
        isCurrentlyInBattle = false
        lockedOrientationMode = nil
        frameCounter = 1
        lastPacketSentTime = now
        lastMinimapPlayerPos = CGPoint(x: 0.25, y: 0.65)
        lastMinimapEnemyPos = nil
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
        // Giữ heartbeat khi khung hình đứng yên.
    }

    override func broadcastResumed() {
        stateLock.lock()
        lastProcessedTime = 0
        stateLock.unlock()
    }

    override func broadcastFinished() {
        stopHeartbeatTimer()
        closeUDPSocket()
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
            let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            guard lockStatus == kCVReturnSuccess else { return }
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            guard let rawFrame = RawFrameBuffer(lockedPixelBuffer: pixelBuffer) else { return }

            stateLock.lock()
            let preferredOrientation = lockedOrientationMode
            let fallbackPlayerMinimap = lastMinimapPlayerPos
            let previousEnemyMinimap = lastMinimapEnemyPos
            stateLock.unlock()

            // Tự động khóa chiều xoay chuẩn thông qua nút đóng màu đỏ [X] tại (0.955, 0.025).
            guard let orientationMode = visionProcessor.detectBattleOrientation(
                in: rawFrame,
                preferredMode: preferredOrientation
            ) else {
                stateLock.lock()
                isCurrentlyInBattle = false
                frameCounter += 1
                let outId = frameCounter
                lastPacketSentTime = Date().timeIntervalSince1970
                let idleTelemetry = buildTelemetryLocked(frameId: outId)
                stateLock.unlock()

                sendUDPPacket(idleTelemetry)
                return
            }

            // Tầng 1 (Ưu tiên cao nhất): Thanh máu xanh người chơi & đỏ địch trên màn hình chính (< 10 đơn vị).
            let tier1Result = visionProcessor.detectMainScreenHealthBars(in: rawFrame, mode: orientationMode)
            let hasTier1Distance = (tier1Result?.distanceUnits != nil)

            // Tầng 2 (Ngoài tầm màn hình chính): Đo qua Minimap (0.848...0.996, 0.042...0.147).
            let minimapResult: MinimapAnalysisResult?
            if !hasTier1Distance {
                minimapResult = visionProcessor.analyzeMinimap(
                    in: rawFrame,
                    mode: orientationMode,
                    fallbackPlayerPos: fallbackPlayerMinimap,
                    previousEnemyPos: previousEnemyMinimap
                )
            } else {
                minimapResult = nil
            }

            stateLock.lock()
            isCurrentlyInBattle = true
            lockedOrientationMode = orientationMode

            if let dist1 = tier1Result?.distanceUnits, dist1.isFinite, dist1 > 0.05 {
                lastDistanceUnits = dist1
                lastDeltaYUnits = tier1Result?.deltaYUnits ?? 0.0
            } else if let mm = minimapResult {
                if let measuredWidth = mm.screenWidthNorm,
                   measuredWidth >= 0.46 && measuredWidth <= 0.76 {
                    lastScreenWidthNorm = measuredWidth
                }
                if let pPos = mm.playerPos {
                    lastMinimapPlayerPos = pPos
                }
                if let ePos = mm.enemyPos {
                    lastMinimapEnemyPos = ePos
                    let safeW = min(max(lastScreenWidthNorm, 0.46), 0.76)
                    lastDistanceUnits = (abs(Double(ePos.x - lastMinimapPlayerPos.x)) / safeW) * BallisticsEngine.unitsPerScreen
                    lastDeltaYUnits = (Double(lastMinimapPlayerPos.y - ePos.y) / (safeW * 0.55)) * BallisticsEngine.unitsPerScreen
                }
            }
            // Tầng 3: Nếu cả Tầng 1 & Tầng 2 bị che mất mục tiêu ở frame hiện tại -> giữ nguyên lastDistanceUnits & lastDeltaYUnits.

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

            // Cắt 1 CGImage xám siêu nhỏ 260 x 130 (~33 KB) trong khi pixelBuffer vẫn đang khóa, rồi đẩy OCR sang luồng song song.
            if shouldDispatchOCR {
                if let tinyGrayCrop = visionProcessor.makeTinyGrayscaleAngleImage(
                    from: rawFrame,
                    mode: orientationMode,
                    playerScreenPos: tier1Result?.playerScreenPos
                ) {
                    dispatchFastAngleOCR(grayscaleImage: tinyGrayCrop)
                } else {
                    stateLock.lock()
                    isOCRBusy = false
                    stateLock.unlock()
                }
            }
        }
    }

    // MARK: - Parallel 33 KB Grayscale Fast Angle OCR (60ms)

    private func dispatchFastAngleOCR(grayscaleImage: CGImage) {
        angleOCRQueue.async { [weak self] in
            autoreleasepool {
                guard let self else { return }
                defer {
                    self.stateLock.lock()
                    self.isOCRBusy = false
                    self.stateLock.unlock()
                }

                guard let detectedAngle = self.visionProcessor.detectAngleFast(fromGrayscaleImage: grayscaleImage) else {
                    return
                }

                self.stateLock.lock()
                let changed = detectedAngle != self.lastAngle
                self.lastAngle = detectedAngle
                if changed && self.isCurrentlyInBattle {
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
            isInBattle: isCurrentlyInBattle,
            angle: lastAngle,
            distanceUnits: lastDistanceUnits,
            power: power
        )
    }

    // MARK: - Heartbeat Timer (0.35s for Live Status LED Continuity)

    private func startHeartbeatTimer() {
        stopHeartbeatTimer()

        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer.schedule(deadline: .now() + 0.35, repeating: 0.35)
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
        guard (now - lastPacketSentTime) >= 0.30 else {
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
}
