import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import ReplayKit

/// Handler nhận khung hình thụ động từ ReplayKit.
/// - Dùng duy nhất 1 `sharedCIContext`, bọc `processSampleBuffer` trong `autoreleasepool` ở tốc độ 10 FPS (100ms).
/// - Tự xoay khung hình về chiều ngang (`width > height`) bằng `RPVideoSampleOrientationKey`.
/// - Gửi ngay gói khởi động (`frameId = 1`) khi bắt đầu truyền phát và duy trì heartbeat 0.5s bằng `DispatchSourceTimer`.
/// - Gửi gói `TelemetryData` qua `Darwin.socket` (BSD UDP `127.0.0.1:45678`) an toàn tuyệt đối (không `!`, không `fatalError`).
final class SampleHandler: RPBroadcastSampleHandler {
    private struct SnapshotState {
        let playerX: Double
        let playerY: Double
        let enemyX: Double
        let enemyY: Double
        let angle: Double
        let wind: Double
        let windDir: Int
    }

    private let sharedCIContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])
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
    private var frameCounter: Int = 0

    // Bộ đệm giữ giá trị hợp lệ gần nhất khi bị hiệu ứng game che tạm thời.
    private var lastPlayerX: Double = 0.25
    private var lastPlayerY: Double = 0.65
    private var lastEnemyX: Double = 0.75
    private var lastEnemyY: Double = 0.65
    private var lastAngle: Double = 65.0
    private var lastWind: Double = 0.0
    private var lastWindDir: Int = 1

    private let minimumFrameInterval: TimeInterval = 0.10 // 10 FPS (100ms)
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
        let initialSnapshot = currentSnapshotLocked()
        stateLock.unlock()

        let startupTelemetry = buildTelemetry(frameId: 1, from: initialSnapshot)
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

            // 1. Quét Minimap (0.848, 0.005, 0.148, 0.170)
            let minimap = visionProcessor.detectMinimapLocations(
                from: landscapeImage,
                normalizedRect: GunnyROIs.minimap
            )

            // 2. Quét Ô Gió (0.435, 0.005, 0.130, 0.070)
            let windObservation = visionProcessor.detectWind(
                from: landscapeImage,
                normalizedRect: GunnyROIs.wind
            )

            // 3. Quét Góc bắn vùng chiến trường (0.080, 0.120, 0.760, 0.600)
            let detectedAngle = visionProcessor.detectBattlefieldAngle(
                from: landscapeImage,
                normalizedRect: GunnyROIs.angle
            )

            stateLock.lock()
            if let minimap {
                if minimap.hasPlayer {
                    lastPlayerX = minimap.playerX
                    lastPlayerY = minimap.playerY
                }
                if minimap.hasEnemy {
                    lastEnemyX = minimap.enemyX
                    lastEnemyY = minimap.enemyY
                }
            }
            if let windValue = windObservation.value {
                lastWind = windValue
                lastWindDir = windObservation.direction
            }
            if let detectedAngle {
                lastAngle = detectedAngle
            }

            frameCounter += 1
            let currentFrameId = frameCounter
            lastPacketSentTime = Date().timeIntervalSince1970
            let snapshot = currentSnapshotLocked()
            stateLock.unlock()

            let telemetry = buildTelemetry(frameId: currentFrameId, from: snapshot)
            sendUDPPacket(telemetry)
            ipc.saveTelemetry(telemetry)
        }
    }

    // MARK: - Snapshot & Heartbeat Timer (0.5s)

    private func currentSnapshotLocked() -> SnapshotState {
        SnapshotState(
            playerX: lastPlayerX,
            playerY: lastPlayerY,
            enemyX: lastEnemyX,
            enemyY: lastEnemyY,
            angle: lastAngle,
            wind: lastWind,
            windDir: lastWindDir
        )
    }

    private func buildTelemetry(frameId: Int, from snapshot: SnapshotState) -> TelemetryData {
        ballisticsEngine.buildTelemetry(
            frameId: frameId,
            playerX: snapshot.playerX,
            playerY: snapshot.playerY,
            enemyX: snapshot.enemyX,
            enemyY: snapshot.enemyY,
            angle: snapshot.angle,
            windMagnitude: snapshot.wind,
            windDir: snapshot.windDir
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
        stateLock.unlock()

        let telemetry = buildTelemetry(frameId: currentFrameId, from: snapshot)
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

        // Luôn xoay sang đúng chiều ngang (width > height) trước khi cắt 3 vùng Gunny Mobi.
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
