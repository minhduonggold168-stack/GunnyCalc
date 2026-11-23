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

/// Quản lý cửa sổ nổi Picture-in-Picture (`640 x 210` px), lắng nghe BSD UDP socket (`127.0.0.1:45678`)
/// trên luồng nền ưu tiên cao và duy trì chạy nền 100% bằng âm thanh câm lặp vô hạn.
@MainActor
final class PiPOverlayManager: NSObject, ObservableObject {
    static let shared = PiPOverlayManager()

    @Published private(set) var isPiPActive = false
    @Published private(set) var isReceivingLiveStream = false
    @Published private(set) var liveFPS: Int = 0
    @Published private(set) var latestFrameId: Int = 0
    @Published private(set) var statusMessage: String?

    let sampleBufferView = PiPSampleBufferView(frame: CGRect(x: 0, y: 0, width: 640, height: 210))

    private var pipController: AVPictureInPictureController?
    private var currentTelemetry: TelemetryData = .placeholder
    private var lastPacketReceivedAt: TimeInterval = 0
    private var packetTimestamps: [TimeInterval] = []
    private var refreshTimer: Timer?
    private var silentAudioPlayer: AVAudioPlayer?

    private let udpReceiver = BSDUDPReceiver()
    private var isUDPStarted = false

    private let renderSize = CGSize(width: 640, height: 210)
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    private let ballisticsEngine = BallisticsEngine()
    private let liveTimeoutSeconds: TimeInterval = 1.0

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
        data.append("RIFF".data(using: .ascii)!)
        withUnsafeBytes(of: riffSize.littleEndian) { data.append(contentsOf: $0) }
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        withUnsafeBytes(of: UInt32(16).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: numChannels.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: blockAlign.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: bitsPerSample.littleEndian) { data.append(contentsOf: $0) }
        data.append("data".data(using: .ascii)!)
        withUnsafeBytes(of: dataByteSize.littleEndian) { data.append(contentsOf: $0) }
        data.append(Data(count: Int(dataByteSize)))
        return data
    }

    // MARK: - CoreGraphics HUD Rendering (640 x 210 px)

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

        if telemetry.trajectoryPoints.count >= 2 && telemetry.power > 0.0 {
            return (telemetry, isLive)
        }

        let effectivePower = telemetry.power > 0.0 ? telemetry.power : 45.0
        let points = ballisticsEngine.generateTrajectoryPoints(
            playerX: telemetry.playerX,
            playerY: telemetry.playerY,
            enemyX: telemetry.enemyX,
            enemyY: telemetry.enemyY,
            angleDeg: telemetry.angle,
            signedWind: abs(telemetry.wind) * Double(telemetry.windDir),
            power: effectivePower
        )

        let resolved = TelemetryData(
            frameId: telemetry.frameId,
            playerX: telemetry.playerX,
            playerY: telemetry.playerY,
            enemyX: telemetry.enemyX,
            enemyY: telemetry.enemyY,
            angle: telemetry.angle,
            wind: telemetry.wind,
            windDir: telemetry.windDir,
            power: effectivePower,
            trajectoryPoints: points
        )
        return (resolved, isLive)
    }

    private func drawHUD(in rect: CGRect, telemetry: TelemetryData) {
        let cgContext = UIGraphicsGetCurrentContext()
        let (displayTelemetry, isLive) = resolveDisplayTelemetry(telemetry)

        // Nền tối bán trong suốt & viền sáng sắc nét kích thước 640 x 210 px.
        UIColor(red: 0.03, green: 0.04, blue: 0.06, alpha: 0.90).setFill()
        UIRectFill(rect)

        let outerPath = UIBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: 14)
        UIColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 0.96).setFill()
        outerPath.fill()

        UIColor(white: 1.0, alpha: 0.42).setStroke()
        outerPath.lineWidth = 1.6
        outerPath.stroke()

        let splitY: CGFloat = 152.0
        let divider = UIBezierPath()
        divider.move(to: CGPoint(x: 12, y: splitY))
        divider.addLine(to: CGPoint(x: rect.width - 12, y: splitY))
        UIColor(white: 1.0, alpha: 0.16).setStroke()
        divider.lineWidth = 1.0
        divider.stroke()

        drawBattlefieldSection(
            in: CGRect(x: 0, y: 0, width: rect.width, height: splitY),
            telemetry: displayTelemetry,
            isLive: isLive,
            cgContext: cgContext
        )

        drawPowerBarSection(
            in: CGRect(x: 0, y: splitY, width: rect.width, height: rect.height - splitY),
            telemetry: displayTelemetry,
            cgContext: cgContext
        )
    }

    // MARK: - Top Battlefield Plot (152px)

    private func drawBattlefieldSection(
        in sectionRect: CGRect,
        telemetry: TelemetryData,
        isLive: Bool,
        cgContext: CGContext?
    ) {
        // Thanh tiêu đề góc trên: LIVE • [frameId] | Tọa độ: (dx, dy) | Góc: [angle]° | Gió: [wind]
        let statusColor = isLive
            ? UIColor(red: 0.0, green: 1.0, blue: 0.533, alpha: 1.0)
            : UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1.0)
        let statusLabel = isLive ? "LIVE • \(telemetry.frameId)" : "CHỜ • \(telemetry.frameId)"

        let windArrow = telemetry.windDir < 0 ? "<" : ">"
        let infoText = String(
            format: "| Tọa độ: (%.2f, %.2f) | Góc: %.0f° | Gió: %@%.1f",
            telemetry.dx,
            telemetry.dy,
            telemetry.angle,
            windArrow,
            abs(telemetry.wind)
        )

        let barRect = CGRect(x: 12, y: 7, width: sectionRect.width - 24, height: 22)
        let barPath = UIBezierPath(roundedRect: barRect, cornerRadius: 6)
        UIColor(red: 0.10, green: 0.13, blue: 0.20, alpha: 0.96).setFill()
        barPath.fill()
        UIColor(white: 1.0, alpha: 0.16).setStroke()
        barPath.lineWidth = 1.0
        barPath.stroke()

        let dotCenter = CGPoint(x: barRect.minX + 12, y: barRect.midY)
        statusColor.withAlphaComponent(0.32).setFill()
        UIBezierPath(arcCenter: dotCenter, radius: 6.0, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()
        statusColor.setFill()
        UIBezierPath(arcCenter: dotCenter, radius: 3.5, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()

        let statusAttr = NSAttributedString(
            string: statusLabel,
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .heavy),
                .foregroundColor: statusColor
            ]
        )
        let statusSize = statusAttr.size()
        statusAttr.draw(at: CGPoint(x: barRect.minX + 21, y: barRect.minY + (barRect.height - statusSize.height) / 2.0))

        let infoAttr = NSAttributedString(
            string: infoText,
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .bold),
                .foregroundColor: UIColor.white
            ]
        )
        let infoSize = infoAttr.size()
        infoAttr.draw(at: CGPoint(
            x: barRect.minX + 25 + statusSize.width,
            y: barRect.minY + (barRect.height - infoSize.height) / 2.0
        ))

        // Khung vẽ chiến trường: tọa độ thực tế người chơi & mục tiêu từ Minimap.
        let plotRect = CGRect(x: 12, y: 33, width: sectionRect.width - 24, height: sectionRect.height - 39)
        let plotBg = UIBezierPath(roundedRect: plotRect, cornerRadius: 9)
        UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 0.90).setFill()
        plotBg.fill()
        UIColor(white: 1.0, alpha: 0.10).setStroke()
        plotBg.lineWidth = 1.0
        plotBg.stroke()

        cgContext?.saveGState()
        plotBg.addClip()

        let gridPath = UIBezierPath()
        for idx in 1..<8 {
            let gx = plotRect.minX + (plotRect.width * CGFloat(idx) / 8.0)
            gridPath.move(to: CGPoint(x: gx, y: plotRect.minY))
            gridPath.addLine(to: CGPoint(x: gx, y: plotRect.maxY))
        }
        for idx in 1..<3 {
            let gy = plotRect.minY + (plotRect.height * CGFloat(idx) / 3.0)
            gridPath.move(to: CGPoint(x: plotRect.minX, y: gy))
            gridPath.addLine(to: CGPoint(x: plotRect.maxX, y: gy))
        }
        UIColor(white: 1.0, alpha: 0.07).setStroke()
        gridPath.lineWidth = 0.8
        gridPath.stroke()

        let mappedPoints: [CGPoint] = telemetry.trajectoryPoints.map { pt in
            CGPoint(
                x: plotRect.minX + CGFloat(pt.x) * plotRect.width,
                y: plotRect.minY + CGFloat(pt.y) * plotRect.height
            )
        }

        let playerPoint: CGPoint
        let enemyPoint: CGPoint
        if let first = mappedPoints.first, let last = mappedPoints.last, mappedPoints.count >= 2 {
            playerPoint = first
            enemyPoint = last
        } else {
            let px = min(max(telemetry.playerX, 0.06), 0.94)
            let py = 0.42 + min(max(telemetry.playerY, 0.0), 1.0) * 0.48
            let ex = min(max(telemetry.enemyX, 0.06), 0.94)
            let ey = 0.42 + min(max(telemetry.enemyY, 0.0), 1.0) * 0.48
            playerPoint = CGPoint(x: plotRect.minX + CGFloat(px) * plotRect.width, y: plotRect.minY + CGFloat(py) * plotRect.height)
            enemyPoint = CGPoint(x: plotRect.minX + CGFloat(ex) * plotRect.width, y: plotRect.minY + CGFloat(ey) * plotRect.height)
        }

        // Đường mặt đất ngang tại cao độ người chơi.
        let groundY = min(max(playerPoint.y, plotRect.minY + 12), plotRect.maxY - 8)
        let groundPath = UIBezierPath()
        groundPath.move(to: CGPoint(x: plotRect.minX, y: groundY))
        groundPath.addLine(to: CGPoint(x: plotRect.maxX, y: groundY))
        UIColor(red: 0.35, green: 0.75, blue: 0.55, alpha: 0.25).setStroke()
        groundPath.lineWidth = 1.0
        groundPath.stroke()

        // Tia thẳng màu vàng chỉ góc bắn từ chấm xanh dương.
        let safeAngleRad = CGFloat(min(max(telemetry.angle, 1.0), 89.0) * .pi / 180.0)
        let dirSign: CGFloat = telemetry.dx >= 0.0 ? 1.0 : -1.0
        let rayLen: CGFloat = 260.0
        let rayEnd = CGPoint(
            x: playerPoint.x + dirSign * cos(safeAngleRad) * rayLen,
            y: playerPoint.y - sin(safeAngleRad) * rayLen
        )
        let angleRay = UIBezierPath()
        angleRay.move(to: playerPoint)
        angleRay.addLine(to: rayEnd)
        UIColor(red: 1.0, green: 0.84, blue: 0.10, alpha: 0.95).setStroke()
        angleRay.lineWidth = 1.4
        angleRay.stroke()

        // Đường cong parabol nét đứt màu xanh lá neon (#00FF88) cắm thẳng vào mục tiêu đỏ.
        if mappedPoints.count >= 2 {
            let curvePath = UIBezierPath()
            curvePath.move(to: mappedPoints[0])
            for pt in mappedPoints.dropFirst() {
                curvePath.addLine(to: pt)
            }
            let dashPattern: [CGFloat] = [7.0, 5.0]
            curvePath.lineCapStyle = .round
            curvePath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)

            UIColor(red: 0.0, green: 1.0, blue: 0.533, alpha: 0.30).setStroke()
            curvePath.lineWidth = 5.0
            curvePath.stroke()

            UIColor(red: 0.0, green: 1.0, blue: 0.533, alpha: 1.0).setStroke()
            curvePath.lineWidth = 2.3
            curvePath.stroke()
        }

        // Chấm xanh dương (Người chơi).
        UIColor(red: 0.16, green: 0.62, blue: 1.0, alpha: 0.35).setFill()
        UIBezierPath(arcCenter: playerPoint, radius: 10, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()
        let playerCircle = UIBezierPath(arcCenter: playerPoint, radius: 5.5, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        UIColor(red: 0.16, green: 0.65, blue: 1.0, alpha: 1.0).setFill()
        playerCircle.fill()
        UIColor.white.setStroke()
        playerCircle.lineWidth = 1.4
        playerCircle.stroke()

        // Chấm đỏ (Mục tiêu địch) kèm tâm ngắm.
        UIColor(red: 1.0, green: 0.20, blue: 0.20, alpha: 0.32).setFill()
        UIBezierPath(arcCenter: enemyPoint, radius: 10, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()
        let enemyCircle = UIBezierPath(arcCenter: enemyPoint, radius: 6.0, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        UIColor(red: 1.0, green: 0.22, blue: 0.22, alpha: 0.96).setFill()
        enemyCircle.fill()
        UIColor.white.setStroke()
        enemyCircle.lineWidth = 1.3
        enemyCircle.stroke()

        let reticle = UIBezierPath()
        let arm: CGFloat = 9.5
        reticle.move(to: CGPoint(x: enemyPoint.x - arm, y: enemyPoint.y))
        reticle.addLine(to: CGPoint(x: enemyPoint.x + arm, y: enemyPoint.y))
        reticle.move(to: CGPoint(x: enemyPoint.x, y: enemyPoint.y - arm))
        reticle.addLine(to: CGPoint(x: enemyPoint.x, y: enemyPoint.y + arm))
        UIColor(red: 1.0, green: 0.85, blue: 0.85, alpha: 0.95).setStroke()
        reticle.lineWidth = 1.1
        reticle.stroke()

        cgContext?.restoreGState()
    }

    // MARK: - Bottom Power Bar (0 — 25 — 50 — 75 — 100)

    private func drawPowerBarSection(in sectionRect: CGRect, telemetry: TelemetryData, cgContext: CGContext?) {
        let barMarginX: CGFloat = 20.0
        let barRect = CGRect(
            x: barMarginX,
            y: sectionRect.minY + 18.0,
            width: sectionRect.width - barMarginX * 2.0,
            height: 16.0
        )

        let clampedPower = CGFloat(min(max(telemetry.power, 0.0), 100.0))
        let fillWidth = barRect.width * (clampedPower / 100.0)
        let markerX = barRect.minX + fillWidth

        let trackPath = UIBezierPath(roundedRect: barRect, cornerRadius: 5)
        UIColor(red: 0.12, green: 0.14, blue: 0.19, alpha: 1.0).setFill()
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

        UIColor(white: 1.0, alpha: 0.35).setStroke()
        trackPath.lineWidth = 1.0
        trackPath.stroke()

        let tickAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold),
            .foregroundColor: UIColor(white: 0.78, alpha: 1.0)
        ]
        for step in stride(from: 0, through: 100, by: 5) {
            let tx = barRect.minX + barRect.width * (CGFloat(step) / 100.0)
            let isMajor = step % 25 == 0
            let tick = UIBezierPath()
            if isMajor {
                tick.move(to: CGPoint(x: tx, y: barRect.minY))
                tick.addLine(to: CGPoint(x: tx, y: barRect.maxY + 3))
                UIColor(white: 1.0, alpha: 0.75).setStroke()
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
                tick.move(to: CGPoint(x: tx, y: barRect.maxY - 4))
                tick.addLine(to: CGPoint(x: tx, y: barRect.maxY))
                UIColor(white: 1.0, alpha: 0.24).setStroke()
                tick.lineWidth = 0.8
                tick.stroke()
            }
        }

        // Vạch chỉ thị đỏ nổi bật tại vị trí lực cần bắn.
        let redLine = UIBezierPath()
        redLine.move(to: CGPoint(x: markerX, y: barRect.minY - 4))
        redLine.addLine(to: CGPoint(x: markerX, y: barRect.maxY + 4))
        redLine.lineCapStyle = .round
        UIColor(red: 1.0, green: 0.16, blue: 0.14, alpha: 1.0).setStroke()
        redLine.lineWidth = 4.2
        redLine.stroke()

        let whiteCore = UIBezierPath()
        whiteCore.move(to: CGPoint(x: markerX, y: barRect.minY - 3))
        whiteCore.addLine(to: CGPoint(x: markerX, y: barRect.maxY + 3))
        whiteCore.lineCapStyle = .round
        UIColor.white.setStroke()
        whiteCore.lineWidth = 1.6
        whiteCore.stroke()

        let powerText = String(format: "%.1f", clampedPower)
        let powerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 13.0, weight: .heavy),
            .foregroundColor: UIColor.white
        ]
        let attrPower = NSAttributedString(string: powerText, attributes: powerAttrs)
        let powerSize = attrPower.size()
        let desiredX = markerX - powerSize.width / 2.0
        let clampedX = min(max(desiredX, barRect.minX), barRect.maxX - powerSize.width)
        let badgeY = sectionRect.minY + 1.0

        let badgeRect = CGRect(x: clampedX - 6, y: badgeY, width: powerSize.width + 12, height: 16)
        let badgePath = UIBezierPath(roundedRect: badgeRect, cornerRadius: 4)
        UIColor(red: 0.90, green: 0.16, blue: 0.12, alpha: 0.96).setFill()
        badgePath.fill()
        UIColor(white: 1.0, alpha: 0.80).setStroke()
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
