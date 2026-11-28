import AVFoundation
import AVKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import UIKit

/// Container UIView sử dụng `AVSampleBufferDisplayLayer` làm lớp nền cho Picture-in-Picture.
final class PiPSampleBufferView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var displayLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable:next force_cast
        layer as! AVSampleBufferDisplayLayer
    }
}

/// Bridge SwiftUI gắn `PiPSampleBufferView` vào hệ thống phân cấp UIKit để `AVPictureInPictureController` hoạt động ổn định.
struct PiPHostView: UIViewRepresentable {
    @ObservedObject var manager: PiPOverlayManager

    func makeUIView(context: Context) -> PiPSampleBufferView {
        let view = manager.sampleBufferView
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: PiPSampleBufferView, context: Context) {
        manager.configureIfNeeded()
    }
}

/// Quản lý cửa sổ nổi Picture-in-Picture (`680 x 235` px), lắng nghe BSD UDP socket (`127.0.0.1:45678`)
/// trên luồng nền ưu tiên cao và duy trì chạy nền 100% bằng âm thanh câm lặp vô hạn.
@MainActor
final class PiPOverlayManager: NSObject, ObservableObject {
    static let shared = PiPOverlayManager()

    @Published private(set) var isPiPActive = false
    @Published private(set) var isReceivingLiveStream = false
    @Published private(set) var liveFPS: Int = 0
    @Published private(set) var latestFrameId: Int = 0
    @Published private(set) var statusMessage: String?

    let sampleBufferView = PiPSampleBufferView(frame: CGRect(x: 0, y: 0, width: 680, height: 235))

    private var pipController: AVPictureInPictureController?
    private var currentTelemetry: TelemetryData = .placeholder
    private var lastPacketReceivedAt: TimeInterval = 0
    private var packetTimestamps: [TimeInterval] = []
    private var refreshTimer: Timer?
    private var silentAudioPlayer: AVAudioPlayer?

    private let udpReceiver = BSDUDPReceiver()
    private var isUDPStarted = false

    private var cachedMinimapJPEG: Data?
    private var cachedMinimapCGImage: CGImage?

    private let renderSize = CGSize(width: 680, height: 235)
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    private let ballisticsEngine = BallisticsEngine()
    private let liveTimeoutSeconds: TimeInterval = 1.5

    private override init() {
        super.init()
        configureAudioSessionAndSilentLoop()
        startMonitoringTimer()
    }

    func configureIfNeeded() {
        startSilentAudioLoopIfNeeded()
        startUDPReceiverIfNeeded()

        guard pipController == nil else { return }

        sampleBufferView.displayLayer.videoGravity = .resizeAspect
        enqueueHUDFrame(for: currentTelemetry)

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            statusMessage = "Thiết bị này không hỗ trợ Picture-in-Picture."
            return
        }

        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sampleBufferView.displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = true
        pipController = controller
    }

    func startRealTimeAimPiP() {
        configureIfNeeded()
        configureAudioSessionAndSilentLoop()

        guard let pipController else {
            statusMessage = "Không thể khởi tạo cửa sổ PiP."
            return
        }

        enqueueHUDFrame(for: currentTelemetry)
        if !pipController.isPictureInPictureActive {
            pipController.startPictureInPicture()
        }
    }

    // MARK: - BSD UDP Receiver (127.0.0.1:45678)

    private func startUDPReceiverIfNeeded() {
        guard !isUDPStarted else { return }
        isUDPStarted = true

        udpReceiver.start(host: BSDUDPConfig.host, port: BSDUDPConfig.port) { [weak self] telemetry in
            Task { @MainActor [weak self] in
                self?.handleIncomingTelemetry(telemetry)
            }
        }
    }

    private func handleIncomingTelemetry(_ telemetry: TelemetryData) {
        let now = Date().timeIntervalSince1970
        lastPacketReceivedAt = now
        latestFrameId = telemetry.frameId
        isReceivingLiveStream = true

        packetTimestamps.append(now)
        packetTimestamps.removeAll { (now - $0) > 1.0 }
        liveFPS = packetTimestamps.count

        if let jpegData = telemetry.minimapJPEG, jpegData != cachedMinimapJPEG {
            cachedMinimapJPEG = jpegData
            cachedMinimapCGImage = UIImage(data: jpegData)?.cgImage
        }

        currentTelemetry = telemetry
        enqueueHUDFrame(for: telemetry)
    }

    private func startMonitoringTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = Date().timeIntervalSince1970
                self.packetTimestamps.removeAll { (now - $0) > 1.0 }
                self.liveFPS = self.packetTimestamps.count
                let liveNow = self.lastPacketReceivedAt > 0 && (now - self.lastPacketReceivedAt) <= self.liveTimeoutSeconds
                self.isReceivingLiveStream = liveNow

                if self.isPiPActive {
                    self.enqueueHUDFrame(for: self.currentTelemetry)
                }
            }
        }
    }

    // MARK: - Background Silent Audio Keep-Alive

    private func configureAudioSessionAndSilentLoop() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            statusMessage = "Không thể bật Audio Session nền: \(error.localizedDescription)"
        }
        startSilentAudioLoopIfNeeded()
    }

    private func startSilentAudioLoopIfNeeded() {
        if let player = silentAudioPlayer {
            if !player.isPlaying {
                player.play()
            }
            return
        }

        let silentData = makeSilentWAVData(durationSeconds: 1.0, sampleRate: 8000)
        do {
            let player = try AVAudioPlayer(data: silentData, fileTypeHint: AVFileType.wav.rawValue)
            player.numberOfLoops = -1
            player.volume = 0.0
            player.prepareToPlay()
            player.play()
            silentAudioPlayer = player
        } catch {
            statusMessage = "Không thể khởi tạo âm thanh câm giữ nền: \(error.localizedDescription)"
        }
    }

    private func makeSilentWAVData(durationSeconds: Double, sampleRate: Int) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sampleCount = max(1, Int(Double(sampleRate) * durationSeconds))
        let dataByteSize = UInt32(sampleCount * Int(numChannels) * Int(bitsPerSample / 8))
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = numChannels * (bitsPerSample / 8)
        let riffSize: UInt32 = 36 + dataByteSize

        var data = Data()
        data.reserveCapacity(Int(44 + dataByteSize))
        data.append(contentsOf: "RIFF".utf8)
        withUnsafeBytes(of: riffSize.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        withUnsafeBytes(of: UInt32(16).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: numChannels.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: blockAlign.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: bitsPerSample.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: "data".utf8)
        withUnsafeBytes(of: dataByteSize.littleEndian) { data.append(contentsOf: $0) }
        data.append(Data(count: Int(dataByteSize)))
        return data
    }

    // MARK: - CoreGraphics HUD Rendering (680 x 235 px)

    private func enqueueHUDFrame(for telemetry: TelemetryData) {
        let displayLayer = sampleBufferView.displayLayer
        if displayLayer.status == .failed {
            displayLayer.flush()
        }

        guard let sampleBuffer = renderHUDSampleBuffer(telemetry: telemetry) else { return }
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sampleBuffer)
        } else {
            displayLayer.flush()
            displayLayer.enqueue(sampleBuffer)
        }
    }

    private func renderHUDSampleBuffer(telemetry: TelemetryData) -> CMSampleBuffer? {
        let width = Int(renderSize.width)
        let height = Int(renderSize.height)

        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBufferOut
        )

        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let cgContext = CGContext(
                  data: baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: rgbColorSpace,
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else {
            return nil
        }

        cgContext.translateBy(x: 0, y: CGFloat(height))
        cgContext.scaleBy(x: 1, y: -1)

        UIGraphicsPushContext(cgContext)
        drawHUD(in: CGRect(origin: .zero, size: renderSize), telemetry: telemetry)
        UIGraphicsPopContext()

        var formatDescription: CMVideoFormatDescription?
        let descStatus = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard descStatus == noErr, let formatDescription else { return nil }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid
        )

        var sampleBufferOut: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBufferOut
        )
        guard sbStatus == noErr, let sampleBuffer = sampleBufferOut else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        return sampleBuffer
    }

    private func resolveDisplayTelemetry(_ telemetry: TelemetryData) -> (data: TelemetryData, isLive: Bool) {
        let now = Date().timeIntervalSince1970
        let isLive = lastPacketReceivedAt > 0 && (now - lastPacketReceivedAt) <= liveTimeoutSeconds

        if telemetry.trajectoryPoints.count >= 2 {
            return (telemetry, isLive)
        }

        let effectivePower = telemetry.power > 0.0 ? telemetry.power : 62.0
        let points = ballisticsEngine.generateMinimapTrajectoryPoints(
            playerX: telemetry.playerX,
            playerY: telemetry.playerY,
            enemyX: telemetry.enemyX,
            enemyY: telemetry.enemyY,
            cameraWidthNorm: telemetry.cameraWidthNorm,
            minimapAspectHOverW: 165.0 / 310.0,
            angleDeg: telemetry.angle,
            signedWind: abs(telemetry.wind) * Double(telemetry.windDir),
            power: effectivePower
        )

        var resolved = telemetry
        resolved.power = effectivePower
        resolved.trajectoryPoints = points
        return (resolved, isLive)
    }

    private func drawHUD(in rect: CGRect, telemetry: TelemetryData) {
        let cgContext = UIGraphicsGetCurrentContext()
        let (displayTelemetry, isLive) = resolveDisplayTelemetry(telemetry)

        // Khung tổng thể 680 x 235 px.
        UIColor(red: 0.025, green: 0.035, blue: 0.055, alpha: 1.0).setFill()
        UIRectFill(rect)

        let outerPath = UIBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: 12)
        UIColor(red: 0.055, green: 0.075, blue: 0.115, alpha: 1.0).setFill()
        outerPath.fill()
        UIColor(white: 1.0, alpha: 0.36).setStroke()
        outerPath.lineWidth = 1.4
        outerPath.stroke()

        // Nửa trái (310 x 165 px): Khung Radar Minimap thực tế & Đường đạn.
        let radarPanelRect = CGRect(x: 8, y: 6, width: 310, height: 165)
        drawRadarMinimapSection(in: radarPanelRect, telemetry: displayTelemetry, cgContext: cgContext)

        // Nửa phải (350 x 165 px): Bảng 4 thông số chiến đấu lớn chống rung + LIVE/CHỜ.
        let metricsPanelRect = CGRect(x: 322, y: 6, width: 350, height: 165)
        drawCombatMetricsSection(in: metricsPanelRect, telemetry: displayTelemetry, isLive: isLive)

        // Thanh ngăn ngang giữa phần trên và thước lực 0-100 bên dưới.
        let dividerY: CGFloat = 175.0
        let divider = UIBezierPath()
        divider.move(to: CGPoint(x: 10, y: dividerY))
        divider.addLine(to: CGPoint(x: rect.width - 10, y: dividerY))
        UIColor(white: 1.0, alpha: 0.18).setStroke()
        divider.lineWidth = 1.0
        divider.stroke()

        // Cạnh dưới toàn chiều ngang (680 x 60 px): Thước lực chi tiết 0 — 10 — ... — 100.
        let powerSectionRect = CGRect(x: 0, y: dividerY, width: rect.width, height: rect.height - dividerY)
        drawPowerBarSection(in: powerSectionRect, telemetry: displayTelemetry, cgContext: cgContext)
    }

    // MARK: - Top-Left Radar Minimap Panel (310 x 165 px)

    private func drawRadarMinimapSection(
        in panelRect: CGRect,
        telemetry: TelemetryData,
        cgContext: CGContext?
    ) {
        let mapRect = CGRect(x: panelRect.minX, y: panelRect.minY, width: panelRect.width, height: 145)
        let rulerRect = CGRect(x: panelRect.minX, y: mapRect.maxY, width: panelRect.width, height: panelRect.height - mapRect.height)

        let panelPath = UIBezierPath(roundedRect: panelRect, cornerRadius: 9)
        UIColor(red: 0.04, green: 0.055, blue: 0.085, alpha: 1.0).setFill()
        panelPath.fill()

        cgContext?.saveGState()
        panelPath.addClip()

        // 1. Ảnh Minimap thực tế từ trận đấu (hoặc lưới tối khi chưa nhận luồng).
        if let minimapCG = cachedMinimapCGImage {
            UIImage(cgImage: minimapCG).draw(in: mapRect)
            UIColor(white: 0.0, alpha: 0.22).setFill()
            UIRectFill(mapRect)
        } else {
            let fallbackGrid = UIBezierPath()
            for idx in 1..<6 {
                let gx = mapRect.minX + (mapRect.width * CGFloat(idx) / 6.0)
                fallbackGrid.move(to: CGPoint(x: gx, y: mapRect.minY))
                fallbackGrid.addLine(to: CGPoint(x: gx, y: mapRect.maxY))
            }
            for idx in 1..<4 {
                let gy = mapRect.minY + (mapRect.height * CGFloat(idx) / 4.0)
                fallbackGrid.move(to: CGPoint(x: mapRect.minX, y: gy))
                fallbackGrid.addLine(to: CGPoint(x: mapRect.maxX, y: gy))
            }
            UIColor(white: 1.0, alpha: 0.08).setStroke()
            fallbackGrid.lineWidth = 0.8
            fallbackGrid.stroke()
        }

        // 2. Khung chữ nhật camera màu trắng (1 khung = 10 đơn vị cự ly).
        if let camRect = telemetry.cameraRect {
            let camDrawRect = CGRect(
                x: mapRect.minX + CGFloat(camRect.x) * mapRect.width,
                y: mapRect.minY + CGFloat(camRect.y) * mapRect.height,
                width: CGFloat(camRect.width) * mapRect.width,
                height: CGFloat(camRect.height) * mapRect.height
            )
            let camPath = UIBezierPath(rect: camDrawRect)
            UIColor(white: 1.0, alpha: 0.78).setStroke()
            camPath.lineWidth = 1.3
            camPath.stroke()

            let camLabel = NSAttributedString(
                string: "10đv",
                attributes: [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold),
                    .foregroundColor: UIColor(white: 1.0, alpha: 0.88)
                ]
            )
            let camLabelSize = camLabel.size()
            let lx = min(max(camDrawRect.maxX - camLabelSize.width - 3, mapRect.minX + 4), mapRect.maxX - camLabelSize.width - 3)
            let ly = min(max(camDrawRect.minY + 2, mapRect.minY + 2), mapRect.maxY - camLabelSize.height - 2)
            camLabel.draw(at: CGPoint(x: lx, y: ly))
        }

        let playerPoint = CGPoint(
            x: mapRect.minX + CGFloat(telemetry.playerX) * mapRect.width,
            y: mapRect.minY + CGFloat(telemetry.playerY) * mapRect.height
        )
        let dirSign: CGFloat = telemetry.dx >= 0.0 ? 1.0 : -1.0
        let unitPx = max((CGFloat(telemetry.cameraWidthNorm) * mapRect.width) / 10.0, 4.0)

        // 3. Vạch chia cự ly dọc mờ trên radar khớp với thước 0 - 5 - 10 - 15 - 20 bên dưới.
        cgContext?.saveGState()
        UIRectClip(mapRect)
        let gridMarks = [5, 10, 15, 20]
        for mark in gridMarks {
            let gx = playerPoint.x + dirSign * CGFloat(mark) * unitPx
            if gx > mapRect.minX + 4 && gx < mapRect.maxX - 4 {
                let tickGuide = UIBezierPath()
                tickGuide.move(to: CGPoint(x: gx, y: mapRect.minY))
                tickGuide.addLine(to: CGPoint(x: gx, y: mapRect.maxY))
                let dash: [CGFloat] = [3.0, 3.0]
                tickGuide.setLineDash(dash, count: dash.count, phase: 0)
                UIColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 0.25).setStroke()
                tickGuide.lineWidth = 0.8
                tickGuide.stroke()
            }
        }

        // 4. Tia thẳng màu vàng chỉ hướng góc bắn.
        let safeAngleRad = CGFloat(min(max(telemetry.angle, 10.0), 85.0) * .pi / 180.0)
        let rayLen: CGFloat = 220.0
        let rayEnd = CGPoint(
            x: playerPoint.x + dirSign * cos(safeAngleRad) * rayLen,
            y: playerPoint.y - sin(safeAngleRad) * rayLen
        )
        let angleRay = UIBezierPath()
        angleRay.move(to: playerPoint)
        angleRay.addLine(to: rayEnd)
        UIColor(red: 1.0, green: 0.84, blue: 0.08, alpha: 0.92).setStroke()
        angleRay.lineWidth = 1.4
        angleRay.stroke()

        // 5. Đường cong parabol nét đứt màu xanh neon (#00FF88) bay vồng vào mục tiêu.
        let mappedTrajectory: [CGPoint] = telemetry.trajectoryPoints.map { pt in
            CGPoint(
                x: mapRect.minX + CGFloat(pt.x) * mapRect.width,
                y: mapRect.minY + CGFloat(pt.y) * mapRect.height
            )
        }
        if mappedTrajectory.count >= 2 {
            let curvePath = UIBezierPath()
            curvePath.move(to: mappedTrajectory[0])
            for pt in mappedTrajectory.dropFirst() {
                curvePath.addLine(to: pt)
            }
            let dashPattern: [CGFloat] = [6.0, 4.0]
            curvePath.lineCapStyle = .round
            curvePath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)

            UIColor(red: 0.0, green: 1.0, blue: 0.533, alpha: 0.32).setStroke()
            curvePath.lineWidth = 4.6
            curvePath.stroke()

            UIColor(red: 0.0, green: 1.0, blue: 0.533, alpha: 1.0).setStroke()
            curvePath.lineWidth = 2.2
            curvePath.stroke()
        }

        // 6. Tâm ngắm đỏ đánh số tất cả mục tiêu địch + vòng sáng quanh mục tiêu đang khóa.
        let allEnemies = telemetry.enemies.isEmpty
            ? [NormalizedPoint(x: telemetry.enemyX, y: telemetry.enemyY)]
            : telemetry.enemies
        let lockedIdx = min(max(telemetry.lockedEnemyIndex, 0), max(allEnemies.count - 1, 0))

        for (idx, enemy) in allEnemies.enumerated() {
            let pt = CGPoint(
                x: mapRect.minX + CGFloat(enemy.x) * mapRect.width,
                y: mapRect.minY + CGFloat(enemy.y) * mapRect.height
            )
            let isLocked = idx == lockedIdx

            if isLocked {
                UIColor(red: 1.0, green: 0.24, blue: 0.20, alpha: 0.35).setFill()
                UIBezierPath(arcCenter: pt, radius: 11.5, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()

                let lockRing = UIBezierPath(arcCenter: pt, radius: 9.5, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                UIColor(red: 1.0, green: 0.85, blue: 0.25, alpha: 0.95).setStroke()
                lockRing.lineWidth = 1.4
                lockRing.stroke()

                let arm: CGFloat = 12.0
                let reticle = UIBezierPath()
                reticle.move(to: CGPoint(x: pt.x - arm, y: pt.y))
                reticle.addLine(to: CGPoint(x: pt.x + arm, y: pt.y))
                reticle.move(to: CGPoint(x: pt.x, y: pt.y - arm))
                reticle.addLine(to: CGPoint(x: pt.x, y: pt.y + arm))
                UIColor(red: 1.0, green: 0.90, blue: 0.88, alpha: 0.92).setStroke()
                reticle.lineWidth = 1.0
                reticle.stroke()
            }

            let dotRadius: CGFloat = isLocked ? 6.5 : 5.2
            let enemyDot = UIBezierPath(arcCenter: pt, radius: dotRadius, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            UIColor(red: 0.96, green: 0.16, blue: 0.18, alpha: isLocked ? 1.0 : 0.82).setFill()
            enemyDot.fill()
            UIColor.white.setStroke()
            enemyDot.lineWidth = isLocked ? 1.3 : 1.0
            enemyDot.stroke()

            let idxText = NSAttributedString(
                string: "\(idx + 1)",
                attributes: [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: isLocked ? 8.5 : 7.5, weight: .heavy),
                    .foregroundColor: UIColor.white
                ]
            )
            let idxSize = idxText.size()
            idxText.draw(at: CGPoint(x: pt.x - idxSize.width / 2.0, y: pt.y - idxSize.height / 2.0))
        }

        // 7. Tâm ngắm xanh (Bạn).
        UIColor(red: 0.15, green: 0.62, blue: 1.0, alpha: 0.36).setFill()
        UIBezierPath(arcCenter: playerPoint, radius: 10.0, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()
        let playerDot = UIBezierPath(arcCenter: playerPoint, radius: 5.8, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        UIColor(red: 0.14, green: 0.64, blue: 1.0, alpha: 1.0).setFill()
        playerDot.fill()
        UIColor.white.setStroke()
        playerDot.lineWidth = 1.4
        playerDot.stroke()

        drawCompactTag(
            text: "Bạn",
            anchor: CGPoint(x: playerPoint.x, y: playerPoint.y - 16),
            within: mapRect,
            bgColor: UIColor(red: 0.08, green: 0.38, blue: 0.85, alpha: 0.92),
            textColor: .white
        )

        cgContext?.restoreGState()

        // 8. Thanh thước chia cự ly 0 — 5 — 10 — 15 — 20 dưới đáy Radar (20px).
        UIColor(red: 0.08, green: 0.11, blue: 0.17, alpha: 1.0).setFill()
        UIRectFill(rulerRect)

        let topRuleBorder = UIBezierPath()
        topRuleBorder.move(to: CGPoint(x: rulerRect.minX, y: rulerRect.minY))
        topRuleBorder.addLine(to: CGPoint(x: rulerRect.maxX, y: rulerRect.minY))
        UIColor(white: 1.0, alpha: 0.22).setStroke()
        topRuleBorder.lineWidth = 0.8
        topRuleBorder.stroke()

        let rulerLabelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold),
            .foregroundColor: UIColor(red: 0.72, green: 0.90, blue: 1.0, alpha: 1.0)
        ]

        for mark in [0, 5, 10, 15, 20] {
            let tx = playerPoint.x + dirSign * CGFloat(mark) * unitPx
            guard tx >= rulerRect.minX + 6 && tx <= rulerRect.maxX - 6 else { continue }

            let tick = UIBezierPath()
            tick.move(to: CGPoint(x: tx, y: rulerRect.minY))
            tick.addLine(to: CGPoint(x: tx, y: rulerRect.minY + 5))
            UIColor(white: 1.0, alpha: 0.82).setStroke()
            tick.lineWidth = 1.1
            tick.stroke()

            let label = NSAttributedString(string: "\(mark)", attributes: rulerLabelAttrs)
            let labelSize = label.size()
            let labelX = min(max(tx - labelSize.width / 2.0, rulerRect.minX + 3), rulerRect.maxX - labelSize.width - 3)
            label.draw(at: CGPoint(x: labelX, y: rulerRect.minY + 5.5))
        }

        cgContext?.restoreGState()

        UIColor(white: 1.0, alpha: 0.24).setStroke()
        panelPath.lineWidth = 1.1
        panelPath.stroke()
    }

    private func drawCompactTag(
        text: String,
        anchor: CGPoint,
        within bounds: CGRect,
        bgColor: UIColor,
        textColor: UIColor
    ) {
        let attr = NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: 8.5, weight: .bold),
                .foregroundColor: textColor
            ]
        )
        let size = attr.size()
        let pillW = size.width + 8
        let pillH = size.height + 2
        let pillX = min(max(anchor.x - pillW / 2.0, bounds.minX + 3), bounds.maxX - pillW - 3)
        let pillY = min(max(anchor.y - pillH / 2.0, bounds.minY + 3), bounds.maxY - pillH - 3)
        let pillRect = CGRect(x: pillX, y: pillY, width: pillW, height: pillH)
        let path = UIBezierPath(roundedRect: pillRect, cornerRadius: 4)
        bgColor.setFill()
        path.fill()
        attr.draw(at: CGPoint(x: pillX + 4, y: pillY + 1))
    }

    // MARK: - Top-Right 4 Combat Metrics Panel (350 x 165 px)

    private func drawCombatMetricsSection(
        in panelRect: CGRect,
        telemetry: TelemetryData,
        isLive: Bool
    ) {
        // Hàng 1: CỰ LY + Trạng thái LIVE / CHỜ góc trên phải.
        let row1Rect = CGRect(x: panelRect.minX, y: panelRect.minY, width: panelRect.width, height: 34)
        drawMetricCard(in: row1Rect, fill: UIColor(red: 0.08, green: 0.11, blue: 0.18, alpha: 1.0), stroke: UIColor(white: 1.0, alpha: 0.16))

        let distString = String(format: "CỰ LY: %.1f (%.2f màn)", telemetry.distanceUnits, telemetry.screens)
        let distAttr = NSAttributedString(
            string: distString,
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 14.5, weight: .heavy),
                .foregroundColor: UIColor.white
            ]
        )
        let distSize = distAttr.size()
        distAttr.draw(at: CGPoint(x: row1Rect.minX + 11, y: row1Rect.midY - distSize.height / 2.0))

        // Chấm trạng thái LIVE (xanh lá) hoặc CHỜ (vàng) ở góc trên phải.
        let statusColor = isLive
            ? UIColor(red: 0.0, green: 1.0, blue: 0.533, alpha: 1.0)
            : UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1.0)
        let statusText = isLive ? "LIVE" : "CHỜ"
        let statusAttr = NSAttributedString(
            string: statusText,
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .heavy),
                .foregroundColor: statusColor
            ]
        )
        let statusSize = statusAttr.size()
        let badgeW = statusSize.width + 22
        let badgeRect = CGRect(x: row1Rect.maxX - badgeW - 7, y: row1Rect.minY + 5, width: badgeW, height: 24)
        let badgePath = UIBezierPath(roundedRect: badgeRect, cornerRadius: 6)
        statusColor.withAlphaComponent(0.14).setFill()
        badgePath.fill()
        statusColor.withAlphaComponent(0.45).setStroke()
        badgePath.lineWidth = 1.0
        badgePath.stroke()

        let dotCenter = CGPoint(x: badgeRect.minX + 10, y: badgeRect.midY)
        statusColor.setFill()
        UIBezierPath(arcCenter: dotCenter, radius: 4.0, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()
        statusAttr.draw(at: CGPoint(x: badgeRect.minX + 18, y: badgeRect.midY - statusSize.height / 2.0))

        // Hàng 2: GÓC (trái) & GIÓ (phải).
        let row2Y = row1Rect.maxY + 5
        let row2H: CGFloat = 53
        let halfW = (panelRect.width - 8) / 2.0
        let angleCardRect = CGRect(x: panelRect.minX, y: row2Y, width: halfW, height: row2H)
        let windCardRect = CGRect(x: angleCardRect.maxX + 8, y: row2Y, width: halfW, height: row2H)

        drawMetricCard(in: angleCardRect, fill: UIColor(red: 0.08, green: 0.11, blue: 0.18, alpha: 1.0), stroke: UIColor(white: 1.0, alpha: 0.16))
        drawMetricCard(in: windCardRect, fill: UIColor(red: 0.08, green: 0.11, blue: 0.18, alpha: 1.0), stroke: UIColor(white: 1.0, alpha: 0.16))

        let captionAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10.5, weight: .bold),
            .foregroundColor: UIColor(white: 0.72, alpha: 1.0)
        ]

        let angleCaption = NSAttributedString(string: "GÓC", attributes: captionAttrs)
        angleCaption.draw(at: CGPoint(x: angleCardRect.minX + 11, y: angleCardRect.minY + 6))

        let angleValAttr = NSAttributedString(
            string: String(format: "%.0f°", telemetry.angle),
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 25.0, weight: .heavy),
                .foregroundColor: UIColor(red: 1.0, green: 0.86, blue: 0.14, alpha: 1.0)
            ]
        )
        let angleValSize = angleValAttr.size()
        angleValAttr.draw(at: CGPoint(x: angleCardRect.midX - angleValSize.width / 2.0, y: angleCardRect.minY + 20))

        let windCaption = NSAttributedString(string: "GIÓ", attributes: captionAttrs)
        windCaption.draw(at: CGPoint(x: windCardRect.minX + 11, y: windCardRect.minY + 6))

        let isCalm = telemetry.wind < 0.05
        let windArrow = telemetry.windDir < 0 ? "← " : "→ "
        let windDisplay = isCalm ? "0.0" : "\(windArrow)\(String(format: "%.1f", telemetry.wind))"
        let shotSign = telemetry.dx >= 0.0 ? 1 : -1
        let isTailwind = telemetry.windDir * shotSign > 0
        let windColor: UIColor
        if isCalm {
            windColor = UIColor(red: 0.75, green: 0.94, blue: 1.0, alpha: 1.0)
        } else if isTailwind {
            windColor = UIColor(red: 0.25, green: 0.96, blue: 0.68, alpha: 1.0)
        } else {
            windColor = UIColor(red: 1.0, green: 0.45, blue: 0.42, alpha: 1.0)
        }

        let windValAttr = NSAttributedString(
            string: windDisplay,
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 24.0, weight: .heavy),
                .foregroundColor: windColor
            ]
        )
        let windValSize = windValAttr.size()
        windValAttr.draw(at: CGPoint(x: windCardRect.midX - windValSize.width / 2.0, y: windCardRect.minY + 21))

        // Hàng 3: Ô nổi bật cỡ lớn LỰC BẮN + GIỮ.
        let row3Y = angleCardRect.maxY + 5
        let row3Rect = CGRect(x: panelRect.minX, y: row3Y, width: panelRect.width, height: panelRect.maxY - row3Y)
        drawMetricCard(
            in: row3Rect,
            fill: UIColor(red: 0.04, green: 0.14, blue: 0.12, alpha: 1.0),
            stroke: UIColor(red: 0.0, green: 1.0, blue: 0.533, alpha: 0.65),
            lineWidth: 1.5
        )

        let powerCaption = NSAttributedString(
            string: "LỰC BẮN",
            attributes: [
                .font: UIFont.systemFont(ofSize: 11.0, weight: .heavy),
                .foregroundColor: UIColor(red: 0.45, green: 1.0, blue: 0.75, alpha: 1.0)
            ]
        )
        powerCaption.draw(at: CGPoint(x: row3Rect.minX + 12, y: row3Rect.minY + 6))

        let powerValAttr = NSAttributedString(
            string: String(format: "%.1f", telemetry.power),
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 35.0, weight: .heavy),
                .foregroundColor: UIColor(red: 0.0, green: 1.0, blue: 0.533, alpha: 1.0)
            ]
        )
        let powerValSize = powerValAttr.size()
        powerValAttr.draw(at: CGPoint(x: row3Rect.minX + 12, y: row3Rect.maxY - powerValSize.height - 5))

        // Vạch chia nhỏ bên phải cho thông số GIỮ (s) và ΔY.
        let subDividerX = row3Rect.maxX - 134
        let subDiv = UIBezierPath()
        subDiv.move(to: CGPoint(x: subDividerX, y: row3Rect.minY + 10))
        subDiv.addLine(to: CGPoint(x: subDividerX, y: row3Rect.maxY - 10))
        UIColor(white: 1.0, alpha: 0.18).setStroke()
        subDiv.lineWidth = 1.0
        subDiv.stroke()

        let holdText = String(format: "GIỮ: %.2fs", telemetry.holdSeconds)
        let holdAttr = NSAttributedString(
            string: holdText,
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 17.5, weight: .heavy),
                .foregroundColor: UIColor(red: 1.0, green: 0.90, blue: 0.25, alpha: 1.0)
            ]
        )
        let holdSize = holdAttr.size()
        holdAttr.draw(at: CGPoint(x: subDividerX + 12, y: row3Rect.minY + 13))

        let deltaSign = telemetry.deltaYUnits >= 0.0 ? "+" : ""
        let deltaYText = String(format: "Chênh cao ΔY: %@%.1f", deltaSign, telemetry.deltaYUnits)
        let deltaYAttr = NSAttributedString(
            string: deltaYText,
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: UIColor(white: 0.78, alpha: 1.0)
            ]
        )
        deltaYAttr.draw(at: CGPoint(x: subDividerX + 12, y: row3Rect.minY + 16 + holdSize.height + 2))
    }

    private func drawMetricCard(
        in rect: CGRect,
        fill: UIColor,
        stroke: UIColor,
        lineWidth: CGFloat = 1.0
    ) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 8)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }

    // MARK: - Bottom Full-Width Power Bar (0 — 10 — ... — 100)

    private func drawPowerBarSection(in sectionRect: CGRect, telemetry: TelemetryData, cgContext: CGContext?) {
        let barMarginX: CGFloat = 18.0
        let barRect = CGRect(
            x: barMarginX,
            y: sectionRect.minY + 21.0,
            width: sectionRect.width - barMarginX * 2.0,
            height: 17.0
        )

        let clampedPower = CGFloat(min(max(telemetry.power, 0.0), 100.0))
        let fillWidth = barRect.width * (clampedPower / 100.0)
        let markerX = barRect.minX + fillWidth

        let trackPath = UIBezierPath(roundedRect: barRect, cornerRadius: 5)
        UIColor(red: 0.10, green: 0.13, blue: 0.19, alpha: 1.0).setFill()
        trackPath.fill()

        if fillWidth > 0.5, let cgContext {
            cgContext.saveGState()
            trackPath.addClip()
            cgContext.clip(to: CGRect(x: barRect.minX, y: barRect.minY, width: fillWidth, height: barRect.height))

            let colors = [
                UIColor(red: 1.0, green: 0.90, blue: 0.12, alpha: 1.0).cgColor,
                UIColor(red: 1.0, green: 0.52, blue: 0.05, alpha: 1.0).cgColor,
                UIColor(red: 1.0, green: 0.16, blue: 0.05, alpha: 1.0).cgColor
            ] as CFArray
            let locations: [CGFloat] = [0.0, 0.55, 1.0]
            if let gradient = CGGradient(colorsSpace: rgbColorSpace, colors: colors, locations: locations) {
                cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: barRect.minX, y: barRect.midY),
                    end: CGPoint(x: barRect.maxX, y: barRect.midY),
                    options: []
                )
            }
            cgContext.restoreGState()
        }

        UIColor(white: 1.0, alpha: 0.36).setStroke()
        trackPath.lineWidth = 1.0
        trackPath.stroke()

        // Thước đo chia từng 10 đơn vị: 0 — 10 — 20 — ... — 100 kèm vạch nhỏ 5 đơn vị.
        let tickAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 10.0, weight: .bold),
            .foregroundColor: UIColor(white: 0.84, alpha: 1.0)
        ]
        for step in stride(from: 0, through: 100, by: 5) {
            let tx = barRect.minX + barRect.width * (CGFloat(step) / 100.0)
            let isMajor = step % 10 == 0
            let tick = UIBezierPath()
            if isMajor {
                tick.move(to: CGPoint(x: tx, y: barRect.minY))
                tick.addLine(to: CGPoint(x: tx, y: barRect.maxY + 3.5))
                UIColor(white: 1.0, alpha: 0.78).setStroke()
                tick.lineWidth = 1.2
                tick.stroke()

                let label = NSAttributedString(string: "\(step)", attributes: tickAttrs)
                let labelSize = label.size()
                let labelX: CGFloat
                if step == 0 {
                    labelX = tx
                } else if step == 100 {
                    labelX = tx - labelSize.width
                } else {
                    labelX = tx - labelSize.width / 2.0
                }
                label.draw(at: CGPoint(x: labelX, y: barRect.maxY + 4))
            } else {
                tick.move(to: CGPoint(x: tx, y: barRect.maxY - 5))
                tick.addLine(to: CGPoint(x: tx, y: barRect.maxY + 1))
                UIColor(white: 1.0, alpha: 0.28).setStroke()
                tick.lineWidth = 0.8
                tick.stroke()
            }
        }

        // Kim chỉ thị màu đỏ rực tại vị trí lực bắn.
        let redLine = UIBezierPath()
        redLine.move(to: CGPoint(x: markerX, y: barRect.minY - 3))
        redLine.addLine(to: CGPoint(x: markerX, y: barRect.maxY + 4))
        redLine.lineCapStyle = .round
        UIColor(red: 1.0, green: 0.14, blue: 0.12, alpha: 1.0).setStroke()
        redLine.lineWidth = 4.4
        redLine.stroke()

        let whiteCore = UIBezierPath()
        whiteCore.move(to: CGPoint(x: markerX, y: barRect.minY - 2))
        whiteCore.addLine(to: CGPoint(x: markerX, y: barRect.maxY + 3))
        whiteCore.lineCapStyle = .round
        UIColor.white.setStroke()
        whiteCore.lineWidth = 1.6
        whiteCore.stroke()

        // Hộp số lực nằm ngay phía trên vạch chỉ thị.
        let powerText = String(format: "%.1f", clampedPower)
        let powerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .heavy),
            .foregroundColor: UIColor.white
        ]
        let attrPower = NSAttributedString(string: powerText, attributes: powerAttrs)
        let powerSize = attrPower.size()
        let desiredX = markerX - powerSize.width / 2.0
        let clampedX = min(max(desiredX, barRect.minX), barRect.maxX - powerSize.width)
        let badgeY = sectionRect.minY + 3.0

        let badgeRect = CGRect(x: clampedX - 6, y: badgeY, width: powerSize.width + 12, height: 16)
        let badgePath = UIBezierPath(roundedRect: badgeRect, cornerRadius: 4)
        UIColor(red: 0.92, green: 0.15, blue: 0.12, alpha: 1.0).setFill()
        badgePath.fill()
        UIColor(white: 1.0, alpha: 0.85).setStroke()
        badgePath.lineWidth = 0.8
        badgePath.stroke()
        attrPower.draw(at: CGPoint(x: clampedX, y: badgeY + (16.0 - powerSize.height) / 2.0))
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPOverlayManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = true
            self.statusMessage = nil
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = false
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            self.isPiPActive = false
            self.statusMessage = "Không thể mở PiP: \(error.localizedDescription)"
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PiPOverlayManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
