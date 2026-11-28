import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import ReplayKit

/// Handler nhận khung hình thụ động từ ReplayKit đạt độ trễ < 0.1s (< 20MB RAM).
/// - Tắt hoàn toàn EMA (độ trễ = 0 khung hình), chạy 30 FPS (33ms) ngay khi màn hình xoay ngang (`width > height`).
/// - Quét dải giữa Minimap (`x: 0.848, y: 0.046, w: 0.148, h: 0.096`) theo chuẩn toàn bản đồ = `20.0` đơn vị (`abs(enemyX - playerX) * 20.0`).
/// - Chạy OCR Grayscale `.fast` song song mỗi 50ms đọc góc nguyên `-35...85`.
/// - Gửi gói JSON siêu nhỏ (< 60 bytes) qua BSD UDP `127.0.0.1:45678` an toàn tuyệt đối (không `!`, không `fatalError`).
final class SampleHandler: RPBroadcastSampleHandler {
    private let sharedCIContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])
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
    private var lastPlayerX: Double = 0.20
    private var lastDistanceUnits: Double = 10.0
    private var lastAngle: Int = 50

    private let minimumFrameInterval: TimeInterval = 0.033 // 30 FPS (33ms)
    private let minimumOCRInterval: TimeInterval = 0.050   // 20 Hz (50ms)
    private let maxGrayAngleWidth: CGFloat = 640.0

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
        lastPlayerX = 0.20
        lastDistanceUnits = 10.0
        lastAngle = 50
        let startupPower = ballisticsEngine.calculatePower(distanceUnits: lastDistanceUnits, angle: lastAngle)
        let startupTelemetry = TelemetryData(frameId: 1, angle: lastAngle, power: startupPower)
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

            // 1. Cắt trực tiếp dải giữa Minimap (dưới nút [X], trên thước vàng) ở độ phân giải gốc.
            let stripPositions: MinimapStripPositions?
            if let nativeStrip = renderNativeMinimapStrip(from: ciImage) {
                stripPositions = visionProcessor.detectMinimapStripPositions(from: nativeStrip)
            } else {
                stripPositions = nil
            }

            stateLock.lock()
            isCurrentlyLandscape = true

            if let strip = stripPositions {
                if let px = strip.playerX {
                    lastPlayerX = px
                }
                if !strip.enemyXs.isEmpty {
                    var nearestEnemyX = strip.enemyXs[0]
                    var bestDelta = abs(nearestEnemyX - lastPlayerX)
                    for ex in strip.enemyXs.dropFirst() {
                        let d = abs(ex - lastPlayerX)
                        if d < bestDelta {
                            bestDelta = d
                            nearestEnemyX = ex
                        }
                    }
                    // Toàn bộ chiều rộng Minimap = 20.0 đơn vị cự ly (1 màn hình = 10.0 đơn vị).
                    lastDistanceUnits = abs(nearestEnemyX - lastPlayerX) * BallisticsEngine.minimapTotalUnits
                }
            }

            let shouldDispatchOCR = !isOCRBusy && (now - lastOCRStartedAt) >= minimumOCRInterval
            if shouldDispatchOCR {
                isOCRBusy = true
                lastOCRStartedAt = now
            }

            frameCounter += 1
            let currentFrameId = frameCounter
            let currentAngle = lastAngle
            let currentDistance = lastDistanceUnits
            lastPacketSentTime = Date().timeIntervalSince1970
            stateLock.unlock()

            // Tính lực bắn tức thời (0 khung hình trễ) và bắn gói UDP < 60 byte ngay lập tức.
            let power = ballisticsEngine.calculatePower(distanceUnits: currentDistance, angle: currentAngle)
            let telemetry = TelemetryData(frameId: currentFrameId, angle: currentAngle, power: power)
            sendUDPPacket(telemetry)

            // 2. Chạy OCR Grayscale .fast trên luồng song song mỗi 50ms.
            if shouldDispatchOCR {
                if let grayAngleCrop = renderGrayscaleAngleCrop(from: ciImage) {
                    dispatchFastAngleOCR(grayscaleAngleImage: grayAngleCrop)
                } else {
                    stateLock.lock()
                    isOCRBusy = false
                    stateLock.unlock()
                }
            }
        }
    }

    // MARK: - Parallel Grayscale Fast Angle OCR (50ms)

    private func dispatchFastAngleOCR(grayscaleAngleImage: CGImage) {
        angleOCRQueue.async { [weak self] in
            autoreleasepool {
                guard let self else { return }
                defer {
                    self.stateLock.lock()
                    self.isOCRBusy = false
                    self.stateLock.unlock()
                }

                guard let detectedAngle = self.visionProcessor.detectAngle(fromGrayscaleImage: grayscaleAngleImage) else {
                    return
                }

                self.stateLock.lock()
                let angleChanged = detectedAngle != self.lastAngle
                self.lastAngle = detectedAngle
                let currentDistance = self.lastDistanceUnits
                let immediateFrameId: Int
                if angleChanged {
                    self.frameCounter += 1
                    immediateFrameId = self.frameCounter
                    self.lastPacketSentTime = Date().timeIntervalSince1970
                } else {
                    immediateFrameId = self.frameCounter
                }
                self.stateLock.unlock()

                // Nếu góc vừa đổi, đẩy ngay gói UDP mới để đạt phản hồi < 50ms mà không cần chờ khung video kế tiếp.
                if angleChanged {
                    let immediatePower = self.ballisticsEngine.calculatePower(
                        distanceUnits: currentDistance,
                        angle: detectedAngle
                    )
                    self.sendUDPPacket(
                        TelemetryData(frameId: immediateFrameId, angle: detectedAngle, power: immediatePower)
                    )
                }
            }
        }
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
        let currentAngle = lastAngle
        let currentDistance = lastDistanceUnits
        lastPacketSentTime = now
        stateLock.unlock()

        let power = ballisticsEngine.calculatePower(distanceUnits: currentDistance, angle: currentAngle)
        let telemetry = TelemetryData(frameId: currentFrameId, angle: currentAngle, power: power)
        sendUDPPacket(telemetry)
        ipc.saveTelemetry(telemetry)
    }

    // MARK: - Safe Darwin BSD UDP Sender (< 60 bytes JSON)

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

    // MARK: - Orientation, Native Strip Crop & Grayscale Angle Crop

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
        let cropRect = GunnyROIs.minimapStrip.ciRect(width: ciImage.extent.width, height: ciImage.extent.height)
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

    /// Cắt vùng chữ góc và chuyển thẳng sang ảnh xám 8-bit (`CIFormat.L8`) trên GPU để tăng tốc OCR gấp 3 lần.
    private func renderGrayscaleAngleCrop(from ciImage: CIImage) -> CGImage? {
        let cropRect = GunnyROIs.angleBattlefield.ciRect(width: ciImage.extent.width, height: ciImage.extent.height)
        guard cropRect.width >= 16, cropRect.height >= 16 else { return nil }

        var patch = ciImage
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))

        if patch.extent.width > maxGrayAngleWidth, patch.extent.width > 0 {
            let scale = maxGrayAngleWidth / patch.extent.width
            patch = patch.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        patch = patch.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputSaturationKey: 0.0,
                kCIInputContrastKey: 1.45,
                kCIInputBrightnessKey: 0.04
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
