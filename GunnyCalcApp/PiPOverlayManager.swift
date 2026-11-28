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

/// Quản lý cửa sổ nổi Picture-in-Picture (`680 x 235` px) chạy trực tiếp 24/24:
/// - Loại bỏ hoàn toàn màn hình khóa chờ; vẽ lại `CMSampleBuffer` ngay lập tức mỗi khi nhận gói UDP `127.0.0.1:45678`.
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
    private var currentTelemetry: TelemetryData = .initialLive
    private var lastPacketReceivedAt: TimeInterval = 0
    private var lastPublishedStatsAt: TimeInterval = 0
    private var packetTimestamps: [TimeInterval] = []
    private var statsMonitorTimer: Timer?
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
        startStatsMonitor()
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

    // MARK: - Instant 25 FPS BSD UDP Receiver (127.0.0.1:45678)

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

        packetTimestamps.append(now)
        packetTimestamps.removeAll { (now - $0) > 1.0 }

        if !isReceivingLiveStream || (now - lastPublishedStatsAt) >= 0.25 {
            lastPublishedStatsAt = now
            isReceivingLiveStream = true
            liveFPS = packetTimestamps.count
            latestFrameId = telemetry.frameId
        }

        if let jpegData = telemetry.minimapJPEG, jpegData != cachedMinimapJPEG {
            cachedMinimapJPEG = jpegData
            cachedMinimapCGImage = UIImage(data: jpegData)?.cgImage
        }

        currentTelemetry = telemetry
        // Vẽ lại khung hình CMSampleBuffer ngay lập tức mỗi khi nhận gói UDP (25 FPS trực tiếp).
        enqueueHUDFrame(for: telemetry)
    }

    private func startStatsMonitor() {
        statsMonitorTimer?.invalidate()
        statsMonitorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = Date().timeIntervalSince1970
                self.packetTimestamps.removeAll { (now - $0) > 1.0 }
                let liveNow = self.lastPacketReceivedAt > 0 && (now - self.lastPacketReceivedAt) <= self.liveTimeoutSeconds
                if !liveNow && (self.isReceivingLiveStream || self.liveFPS != 0) {
                    self.isReceivingLiveStream = false
                    self.liveFPS = 0
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
            duration: CMTime(value: 1, timescale: 25),
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

    private func drawHUD(in rect: CGRect, telemetry: TelemetryData) {
        let cgContext = UIGraphicsGetCurrentContext()

        // Khung tổng thể 680 x 235 px luôn hiển thị trực tiếp 24/24.
        UIColor(red: 0.025, green: 0.035, blue: 0.055, alpha: 1.0).setFill()
        UIRectFill(rect)

        let outerPath = UIBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: 12)
        UIColor(red: 0.055, green: 0.075, blue: 0.115, alpha: 1.0).setFill()
        outerPath.fill()
        UIColor(white: 1.0, alpha: 0.36).setStroke()
        outerPath.lineWidth = 1.4
        outerPath.stroke()

        var displayTelemetry = telemetry
        if displayTelemetry.trajectoryPoints.count < 2 {
            displayTelemetry.trajectoryPoints = ballisticsEngine.generateMinimapTrajectoryPoints(
                playerNorm: displayTelemetry.playerNorm,
                enemyNorm: displayTelemetry.enemyNorm,
                angleDeg: displayTelemetry.angle,
                minimapAspectHOverW: 145.0 / 310.0
            )
        }

        // Nửa trái (310 x 165 px): Ảnh Minimap thực tế + thước cự ly + parabol.
        let radarPanelRect = CGRect(x: 8, y: 6, width: 310, height: 165)
        drawRadarMinimapSection(in: radarPanelRect, telemetry: displayTelemetry, cgContext: cgContext)

        // Nửa phải (350 x 165 px): CỰ LY, GÓC, LỰC BẮN (GIỮ), gợi ý 30° | 50° | 65° và chấm LIVE 24/24.
        let metricsPanelRect = CGRect(x: 322, y: 6, width: 350, height: 165)
        drawCombatMetricsSection(in: metricsPanelRect, telemetry: displayTelemetry)

        // Thanh ngăn ngang phân tách thước lực 0-100 bên dưới.
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

        // 1. Ảnh địa hình Minimap cắt trực tiếp từ game.
        if let minimapCG = cachedMinimapCGImage {
            UIImage(cgImage: minimapCG).draw(in: mapRect)
            UIColor(white: 0.0, alpha: 0.20).setFill()
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

        let playerPoint = CGPoint(
            x: mapRect.minX + telemetry.playerNorm.x * mapRect.width,
            y: mapRect.minY + telemetry.playerNorm.y * mapRect.height
        )
        let lockedEnemyPoint = CGPoint(
            x: mapRect.minX + telemetry.enemyNorm.x * mapRect.width,
            y: mapRect.minY + telemetry.enemyNorm.y * mapRect.height
        )

        let dxNorm = telemetry.enemyNorm.x - telemetry.playerNorm.x
        let dirSign: CGFloat = dxNorm >= 0.0 ? 1.0 : -1.0
        let absDxNorm = abs(dxNorm)
        let unitPx: CGFloat
        if telemetry.distanceUnits > 0.25 && absDxNorm > 0.02 {
            unitPx = max((absDxNorm * mapRect.width) / CGFloat(telemetry.distanceUnits), 4.0)
        } else {
            unitPx = max((0.62 * mapRect.width) / 10.0, 4.0)
        }

        cgContext?.saveGState()
        UIRectClip(mapRect)

        // 2. Đường gióng dọc chia cự ly 5 - 10 - 15 - 20 trên radar.
        for mark in [5, 10, 15, 20] {
            let gx = playerPoint.x + dirSign * CGFloat(mark) * unitPx
            if gx > mapRect.minX + 4 && gx < mapRect.maxX - 4 {
                let guide = UIBezierPath()
                guide.move(to: CGPoint(x: gx, y: mapRect.minY))
                guide.addLine(to: CGPoint(x: gx, y: mapRect.maxY))
                let dash: [CGFloat] = [3.0, 3.0]
                guide.setLineDash(dash, count: dash.count, phase: 0)
                UIColor(red: 0.35, green: 0.85, blue: 1.0, alpha: 0.26).setStroke()
                guide.lineWidth = 0.8
                guide.stroke()
            }
        }

        // 3. Tia thẳng màu vàng chỉ góc bắn (-35° tới 85°).
        let angleRad = CGFloat(min(max(telemetry.angle, -35.0), 85.0) * .pi / 180.0)
        let rayLen: CGFloat = 220.0
        let rayEnd = CGPoint(
            x: playerPoint.x + dirSign * cos(angleRad) * rayLen,
            y: playerPoint.y - sin(angleRad) * rayLen
        )
        let angleRay = UIBezierPath()
        angleRay.move(to: playerPoint)
        angleRay.addLine(to: rayEnd)
        UIColor(red: 1.0, green: 0.84, blue: 0.08, alpha: 0.94).setStroke()
        angleRay.lineWidth = 1.4
        angleRay.stroke()

        // 4. Đường cong parabol nét đứt màu xanh neon (#00FF88).
        let mappedTrajectory: [CGPoint] = telemetry.trajectoryPoints.map { pt in
            CGPoint(
                x: mapRect.minX + pt.x * mapRect.width,
                y: mapRect.minY + pt.y * mapRect.height
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

        // 5. Các chấm đỏ mục tiêu địch + khóa sáng mục tiêu chính (`Địch`).
        let allEnemies = telemetry.allEnemiesNorm.isEmpty ? [telemetry.enemyNorm] : telemetry.allEnemiesNorm
        var lockedIdx = 0
        var minLockDist = CGFloat.greatestFiniteMagnitude
        for (idx, pt) in allEnemies.enumerated() {
            let dist = hypot(pt.x - telemetry.enemyNorm.x, pt.y - telemetry.enemyNorm.y)
            if dist < minLockDist {
                minLockDist = dist
                lockedIdx = idx
            }
        }

        for (idx, enemy) in allEnemies.enumerated() {
            let pt = CGPoint(
                x: mapRect.minX + enemy.x * mapRect.width,
                y: mapRect.minY + enemy.y * mapRect.height
            )
            let isLocked = idx == lockedIdx

            if isLocked {
                UIColor(red: 1.0, green: 0.24, blue: 0.20, alpha: 0.34).setFill()
                UIBezierPath(arcCenter: pt, radius: 11.5, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()

                let lockRing = UIBezierPath(arcCenter: pt, radius: 9.5, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                UIColor(red: 1.0, green: 0.85, blue: 0.25, alpha: 0.96).setStroke()
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

            let dotRadius: CGFloat = isLocked ? 6.2 : 4.8
            let enemyDot = UIBezierPath(arcCenter: pt, radius: dotRadius, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            UIColor(red: 0.96, green: 0.16, blue: 0.18, alpha: isLocked ? 1.0 : 0.80).setFill()
            enemyDot.fill()
            UIColor.white.setStroke()
            enemyDot.lineWidth = isLocked ? 1.3 : 0.9
            enemyDot.stroke()

            let idxText = NSAttributedString(
                string: "\(idx + 1)",
                attributes: [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: isLocked ? 8.2 : 7.2, weight: .heavy),
                    .foregroundColor: UIColor.white
                ]
            )
            let idxSize = idxText.size()
            idxText.draw(at: CGPoint(x: pt.x - idxSize.width / 2.0, y: pt.y - idxSize.height / 2.0))
        }

        drawCompactTag(
            text: "Địch",
            anchor: CGPoint(x: lockedEnemyPoint.x, y: lockedEnemyPoint.y - 17),
            within: mapRect,
            bgColor: UIColor(red: 0.86, green: 0.14, blue: 0.16, alpha: 0.92),
            textColor: .white
        )

        // 6. Chấm xanh dương người chơi (`Bạn`).
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

        // 7. Thước chia cự ly 0 — 5 — 10 — 15 — 20 dưới đáy Radar (20px).
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

    // MARK: - Top-Right Always-Live Combat Metrics Panel (350 x 165 px)

    private func drawCombatMetricsSection(
        in panelRect: CGRect,
        telemetry: TelemetryData
    ) {
        // Hàng 1 (46px): CỰ LY (trái) & GÓC + chấm LIVE 24/24 (phải).
        let row1H: CGFloat = 46
        let distCardRect = CGRect(x: panelRect.minX, y: panelRect.minY, width: 158, height: row1H)
        let angleCardRect = CGRect(x: distCardRect.maxX + 6, y: panelRect.minY, width: panelRect.width - 164, height: row1H)

        drawMetricCard(in: distCardRect, fill: UIColor(red: 0.08, green: 0.11, blue: 0.18, alpha: 1.0), stroke: UIColor(white: 1.0, alpha: 0.16))
        drawMetricCard(in: angleCardRect, fill: UIColor(red: 0.08, green: 0.11, blue: 0.18, alpha: 1.0), stroke: UIColor(white: 1.0, alpha: 0.16))

        let distTitle = NSAttributedString(
            string: String(format: "CỰ LY: %.1f", telemetry.distanceUnits),
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 16.5, weight: .heavy),
                .foregroundColor: UIColor.white
            ]
        )
        distTitle.draw(at: CGPoint(x: distCardRect.minX + 9, y: distCardRect.minY + 6))

        let screensSub = NSAttributedString(
            string: String(format: "%.2f màn hình", telemetry.screens),
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 9.8, weight: .semibold),
                .foregroundColor: UIColor(red: 0.58, green: 0.84, blue: 1.0, alpha: 0.92)
            ]
        )
        screensSub.draw(at: CGPoint(x: distCardRect.minX + 9, y: distCardRect.maxY - 16))

        // Chấm LIVE 24/24 nổi bật ở góc trên phải, không chồng lên số GÓC (kể cả góc âm -35°).
        drawStatusPill(
            text: "LIVE 24/24",
            color: UIColor(red: 0.0, green: 1.0, blue: 0.533, alpha: 1.0),
            topRightAnchor: CGPoint(x: angleCardRect.maxX - 5, y: angleCardRect.minY + 4)
        )

        let angleAttr = NSAttributedString(
            string: String(format: "GÓC: %.0f°", telemetry.angle),
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 18.0, weight: .heavy),
                .foregroundColor: UIColor(red: 1.0, green: 0.86, blue: 0.14, alpha: 1.0)
            ]
        )
        angleAttr.draw(at: CGPoint(x: angleCardRect.minX + 9, y: angleCardRect.maxY - angleAttr.size().height - 4))

        // Hàng 2 (72px): Ô nổi bật cỡ lớn LỰC BẮN + GIỮ (s) + ΔY.
        let row2Y = distCardRect.maxY + 5
        let row2Rect = CGRect(x: panelRect.minX, y: row2Y, width: panelRect.width, height: 72)
        drawMetricCard(
            in: row2Rect,
            fill: UIColor(red: 0.04, green: 0.14, blue: 0.12, alpha: 1.0),
            stroke: UIColor(red: 0.0, green: 1.0, blue: 0.533, alpha: 0.68),
            lineWidth: 1.5
        )

        let powerCaption = NSAttributedString(
            string: "LỰC BẮN",
            attributes: [
                .font: UIFont.systemFont(ofSize: 11.0, weight: .heavy),
                .foregroundColor: UIColor(red: 0.45, green: 1.0, blue: 0.75, alpha: 1.0)
            ]
        )
        powerCaption.draw(at: CGPoint(x: row2Rect.minX + 12, y: row2Rect.minY + 6))

        let powerValAttr = NSAttributedString(
            string: String(format: "%.1f", telemetry.power),
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 35.0, weight: .heavy),
                .foregroundColor: UIColor(red: 0.0, green: 1.0, blue: 0.533, alpha: 1.0)
            ]
        )
        let powerValSize = powerValAttr.size()
        powerValAttr.draw(at: CGPoint(x: row2Rect.minX + 12, y: row2Rect.maxY - powerValSize.height - 5))

        let subDividerX = row2Rect.maxX - 138
        let subDiv = UIBezierPath()
        subDiv.move(to: CGPoint(x: subDividerX, y: row2Rect.minY + 10))
        subDiv.addLine(to: CGPoint(x: subDividerX, y: row2Rect.maxY - 10))
        UIColor(white: 1.0, alpha: 0.18).setStroke()
        subDiv.lineWidth = 1.0
        subDiv.stroke()

        let holdAttr = NSAttributedString(
            string: String(format: "GIỮ: %.2fs", telemetry.holdSeconds),
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 17.5, weight: .heavy),
                .foregroundColor: UIColor(red: 1.0, green: 0.90, blue: 0.25, alpha: 1.0)
            ]
        )
        let holdSize = holdAttr.size()
        holdAttr.draw(at: CGPoint(x: subDividerX + 12, y: row2Rect.minY + 14))

        let deltaSign = telemetry.deltaY >= 0.0 ? "+" : ""
        let deltaYAttr = NSAttributedString(
            string: String(format: "Chênh cao ΔY: %@%.1f", deltaSign, telemetry.deltaY),
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: UIColor(white: 0.80, alpha: 1.0)
            ]
        )
        deltaYAttr.draw(at: CGPoint(x: subDividerX + 12, y: row2Rect.minY + 17 + holdSize.height + 3))

        // Hàng 3 (37px): Gợi ý tra nhanh 3 góc chuẩn 30° | 50° | 65°.
        let row3Y = row2Rect.maxY + 5
        let row3Rect = CGRect(x: panelRect.minX, y: row3Y, width: panelRect.width, height: panelRect.maxY - row3Y)
        drawMetricCard(
            in: row3Rect,
            fill: UIColor(red: 0.08, green: 0.11, blue: 0.18, alpha: 1.0),
            stroke: UIColor(red: 0.45, green: 0.78, blue: 1.0, alpha: 0.28),
            lineWidth: 1.0
        )

        let presets: [(String, Double)] = [
            ("30°:", telemetry.power30),
            ("50°:", telemetry.power50),
            ("65°:", telemetry.power65)
        ]
        let cellW = row3Rect.width / 3.0
        for (idx, item) in presets.enumerated() {
            let cellRect = CGRect(x: row3Rect.minX + CGFloat(idx) * cellW, y: row3Rect.minY, width: cellW, height: row3Rect.height)

            if idx > 0 {
                let sep = UIBezierPath()
                sep.move(to: CGPoint(x: cellRect.minX, y: row3Rect.minY + 7))
                sep.addLine(to: CGPoint(x: cellRect.minX, y: row3Rect.maxY - 7))
                UIColor(white: 1.0, alpha: 0.20).setStroke()
                sep.lineWidth = 1.0
                sep.stroke()
            }

            let combined = NSMutableAttributedString(
                string: item.0 + " ",
                attributes: [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 13.0, weight: .bold),
                    .foregroundColor: UIColor(red: 1.0, green: 0.84, blue: 0.25, alpha: 1.0)
                ]
            )
            combined.append(
                NSAttributedString(
                    string: String(format: "%.1f", item.1),
                    attributes: [
                        .font: UIFont.monospacedDigitSystemFont(ofSize: 14.5, weight: .heavy),
                        .foregroundColor: UIColor.white
                    ]
                )
            )
            let size = combined.size()
            combined.draw(at: CGPoint(
                x: cellRect.midX - size.width / 2.0,
                y: cellRect.midY - size.height / 2.0
            ))
        }
    }

    private func drawStatusPill(text: String, color: UIColor, topRightAnchor: CGPoint) {
        let attr = NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 9.0, weight: .heavy),
                .foregroundColor: color
            ]
        )
        let size = attr.size()
        let pillW = size.width + 16
        let pillH: CGFloat = 17
        let pillRect = CGRect(x: topRightAnchor.x - pillW, y: topRightAnchor.y, width: pillW, height: pillH)
        let path = UIBezierPath(roundedRect: pillRect, cornerRadius: 5)
        color.withAlphaComponent(0.15).setFill()
        path.fill()
        color.withAlphaComponent(0.50).setStroke()
        path.lineWidth = 0.9
        path.stroke()

        let dotCenter = CGPoint(x: pillRect.minX + 7, y: pillRect.midY)
        color.setFill()
        UIBezierPath(arcCenter: dotCenter, radius: 2.9, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()
        attr.draw(at: CGPoint(x: pillRect.minX + 12.5, y: pillRect.midY - size.height / 2.0))
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

        // Thước chia lực từng 10 đơn vị: 0 — 10 — 20 — ... — 100 kèm vạch phụ 5 đơn vị.
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

        // Kim chỉ thị màu đỏ rực đặt thẳng hàng với thanh lực của game.
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
