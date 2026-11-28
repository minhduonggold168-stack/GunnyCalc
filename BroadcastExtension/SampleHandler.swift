import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ReplayKit

/// Handler nhận khung hình thụ động từ ReplayKit theo kiến trúc Zero-Crash (< 4 MB RAM, < 2ms/khung hình):
/// - Đọc trực tiếp vùng nhớ thô từ `CVPixelBuffer` (`BGRA` / `420f` / `420v`) qua `CVPixelBufferLockBaseAddress(..., .readOnly)`.
/// - Tự động xoay ánh xạ tọa độ logic bằng phép tính chỉ số mảng khi buffer đang ở chiều dọc, không cấp phát bộ nhớ mới.
/// - Đo cự ly bằng thước vàng đáy Minimap (`pixelsPerUnit = tickSpacingPixels / 5.0`), dự phòng khung camera trắng `/ 10.0`.
/// - Đọc góc bắn từ tâm D-pad (`16×24` bitmap matching) đối chiếu tia chấm vàng, giữ nguyên góc khi D-pad hiện `0`.
/// - Truyền tức thời gói JSON siêu nhẹ 25 FPS (mỗi 40ms) qua BSD UDP `127.0.0.1:45678`.
final class SampleHandler: RPBroadcastSampleHandler {
    private let visionProcessor = VisionProcessor()
    private let ballisticsEngine = BallisticsEngine()
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
    private var isCurrentlyLandscape = false
    private var frameCounter: Int = 0

    // Trạng thái tức thời (không làm mượt trễ EMA).
    private var lastPlayerPx: CGPoint?
    private var lastEnemyPx: CGPoint?
    private var lastPixelsPerUnit: Double?
    private var lastDistanceUnits: Double = 10.0
    private var lastDeltaYUnits: Double = 0.0
    private var lastAngle: Int = 50

    private let minimumFrameInterval: TimeInterval = 0.040 // 25 FPS (40ms)

    deinit {
        stopHeartbeatTimer()
        closeUDPSocket()
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let now = Date().timeIntervalSince1970
        stateLock.lock()
        lastProcessedTime = 0
        isProcessingFrame = false
        isCurrentlyLandscape = false
        frameCounter = 1
        lastPacketSentTime = now
        lastPlayerPx = nil
        lastEnemyPx = nil
        lastPixelsPerUnit = nil
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
            let lockResult = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            guard lockResult == kCVReturnSuccess else { return }
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            let orientation = extractRawOrientation(from: sampleBuffer)
            guard let rawFrame = RawFrameBuffer(lockedPixelBuffer: pixelBuffer, orientation: orientation) else {
                return
            }

            // Bỏ qua khung hình đang dựng dọc (màn hình chính iPhone / app GunnyCalc).
            guard rawFrame.isLandscape else {
                stateLock.lock()
                isCurrentlyLandscape = false
                stateLock.unlock()
                return
            }

            stateLock.lock()
            let cachedPlayer = lastPlayerPx
            let cachedEnemy = lastEnemyPx
            let cachedPpu = lastPixelsPerUnit
            stateLock.unlock()

            let analysis = visionProcessor.analyzeFrame(
                rawFrame,
                fallbackPlayerPx: cachedPlayer,
                previousEnemyPx: cachedEnemy,
                cachedPixelsPerUnit: cachedPpu
            )

            stateLock.lock()
            isCurrentlyLandscape = true

            if let ppu = analysis.pixelsPerUnit, ppu > 2.0 {
                lastPixelsPerUnit = ppu
            }
            if let pPx = analysis.playerPx {
                lastPlayerPx = pPx
            }
            if let ePx = analysis.enemyPx {
                lastEnemyPx = ePx
            }
            if let dist = analysis.distanceUnits, dist.isFinite, dist > 0.05 {
                lastDistanceUnits = dist
                lastDeltaYUnits = analysis.deltaYUnits ?? 0.0
            }
            if let detectedAngle = analysis.angle {
                lastAngle = detectedAngle
            }

            frameCounter += 1
            let currentFrameId = frameCounter
            lastPacketSentTime = Date().timeIntervalSince1970
            let telemetry = buildTelemetryLocked(frameId: currentFrameId)
            stateLock.unlock()

            sendUDPPacket(telemetry)
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

    // MARK: - Orientation Helper (Zero Allocation)

    private func extractRawOrientation(from sampleBuffer: CMSampleBuffer) -> RawBufferOrientation {
        if let attachment = CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber {
            return RawBufferOrientation(exifRawValue: attachment.uint32Value)
        }
        return .up
    }

    // MARK: - Heartbeat Timer (0.35s keeps live green LED pulsing on static screens)

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
        guard isCurrentlyLandscape, (now - lastPacketSentTime) >= 0.30 else {
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
