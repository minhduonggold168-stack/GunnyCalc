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

/// Quản lý thanh ngang Picture-in-Picture siêu mảnh (`320 x 72` px, giảm >50% diện tích):
/// - Phần trên (`50px`): 2 cột lớn `GÓC: [angle]°` (vàng #FFD60A) và `LỰC: [power]` (xanh neon #00FF88).
/// - Phần dưới (`22px`): thanh thước lực `0 — 20 — 40 — 60 — 80 — 100` kèm kim chỉ thị đỏ rực.
/// - Đẩy `CMSampleBuffer` ngay lập tức trong callback nhận UDP (`127.0.0.1:45678`) để đạt độ trễ < 0.1s.
@MainActor
final class PiPOverlayManager: NSObject, ObservableObject {
    static let shared = PiPOverlayManager()

    @Published private(set) var isPiPActive = false
    @Published private(set) var isReceivingLiveStream = false
    @Published private(set) var liveFPS: Int = 0
    @Published private(set) var latestFrameId: Int = 0
    @Published private(set) var statusMessage: String?

    let sampleBufferView = PiPSampleBufferView(frame: CGRect(x: 0, y: 0, width: 320, height: 72))

    private var pipController: AVPictureInPictureController?
    private var currentTelemetry: TelemetryData = .initialLive
    private var lastPacketReceivedAt: TimeInterval = 0
    private var lastPublishedStatsAt: TimeInterval = 0
    private var packetTimestamps: [TimeInterval] = []
    private var statsMonitorTimer: Timer?
    private var silentAudioPlayer: AVAudioPlayer?

    private let udpReceiver = BSDUDPReceiver()
    private var isUDPStarted = false

    private let renderSize = CGSize(width: 320, height: 72)
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
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

    // MARK: - Zero-Lag 30 FPS BSD UDP Receiver (127.0.0.1:45678)

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

        currentTelemetry = telemetry
        // Đẩy CMSampleBuffer mới ngay lập tức trong callback nhận UDP (không qua timer trễ).
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

    // MARK: - Compact CoreGraphics HUD Rendering (340 x 115 px)

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
        drawMinimalHUD(in: CGRect(origin: .zero, size: renderSize), telemetry: telemetry, cgContext: cgContext)
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

    private func drawMinimalHUD(in rect: CGRect, telemetry: TelemetryData, cgContext: CGContext) {
        let neonGreen = UIColor(red: 0.0, green: 1.0, blue: 0.533, alpha: 1.0)
        let brightYellow = UIColor(red: 1.0, green: 0.839, blue: 0.039, alpha: 1.0) // #FFD60A
        let warningOrange = UIColor(red: 1.0, green: 0.584, blue: 0.0, alpha: 1.0)  // #FF9500

        // Nền đen bán trong suốt (alpha = 0.85); viền cam #FF9500 khi vướng núi, xanh lá #00FF88 khi thông thoáng.
        cgContext.clear(rect)
        let outerPath = UIBezierPath(roundedRect: rect.insetBy(dx: 1.0, dy: 1.0), cornerRadius: 8)
        UIColor(white: 0.0, alpha: 0.85).setFill()
        outerPath.fill()

        (telemetry.isBlocked ? warningOrange : neonGreen).setStroke()
        outerPath.lineWidth = telemetry.isBlocked ? 2.0 : 1.4
        outerPath.stroke()

        // MARK: Phần trên (50px): 2 cột ngang GÓC: [angle]° (+ cảnh báo vướng núi) & LỰC: [power]
        let topHeight: CGFloat = 50.0
        let splitX: CGFloat = telemetry.isBlocked ? 174.0 : (rect.width / 2.0)

        let verticalSep = UIBezierPath()
        verticalSep.move(to: CGPoint(x: splitX, y: 8))
        verticalSep.addLine(to: CGPoint(x: splitX, y: topHeight - 8))
        UIColor(white: 1.0, alpha: 0.18).setStroke()
        verticalSep.lineWidth = 1.0
        verticalSep.stroke()

        if telemetry.isBlocked {
            // Cột trái (khi vướng địa hình): chỉ số GÓC phía trên + nhãn cảnh báo cam bên dưới.
            drawFittedMetric(
                text: "GÓC: \(telemetry.angle)°",
                color: brightYellow,
                baseSize: 22.0,
                minSize: 16.0,
                in: CGRect(x: 4, y: 2, width: splitX - 8, height: 28)
            )

            let pillRect = CGRect(x: 6, y: 31, width: splitX - 12, height: 16)
            let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: 4)
            warningOrange.withAlphaComponent(0.24).setFill()
            pillPath.fill()
            warningOrange.setStroke()
            pillPath.lineWidth = 0.9
            pillPath.stroke()

            drawFittedMetric(
                text: "⚠️ VƯỚNG NÚI (NÂNG \(telemetry.suggestedAngle)°)",
                color: UIColor(red: 1.0, green: 0.82, blue: 0.35, alpha: 1.0),
                baseSize: 8.8,
                minSize: 6.5,
                in: pillRect.insetBy(dx: 3, dy: 0)
            )

            drawFittedMetric(
                text: String(format: "LỰC: %.1f", telemetry.power),
                color: neonGreen,
                baseSize: 25.0,
                minSize: 18.0,
                in: CGRect(x: splitX + 4, y: 0, width: rect.width - splitX - 8, height: topHeight)
            )
        } else {
            // Cột trái: GÓC: [angle]° (vàng #FFD60A 26pt đậm)
            drawFittedMetric(
                text: "GÓC: \(telemetry.angle)°",
                color: brightYellow,
                baseSize: 26.0,
                minSize: 18.0,
                in: CGRect(x: 4, y: 0, width: splitX - 8, height: topHeight)
            )

            // Cột phải: LỰC: [power] (xanh neon #00FF88 26pt đậm, 1 chữ số thập phân)
            drawFittedMetric(
                text: String(format: "LỰC: %.1f", telemetry.power),
                color: neonGreen,
                baseSize: 26.0,
                minSize: 18.0,
                in: CGRect(x: splitX + 4, y: 0, width: rect.width - splitX - 8, height: topHeight)
            )
        }

        // Đường ngăn ngang giữa phần trên (50px) và thanh thước lực (22px).
        let horizontalSep = UIBezierPath()
        horizontalSep.move(to: CGPoint(x: 6, y: topHeight))
        horizontalSep.addLine(to: CGPoint(x: rect.width - 6, y: topHeight))
        UIColor(white: 1.0, alpha: 0.18).setStroke()
        horizontalSep.lineWidth = 0.9
        horizontalSep.stroke()

        // MARK: Phần dưới (22px): Thanh thước lực 0 — 20 — 40 — 60 — 80 — 100 toàn chiều ngang 320px
        let barMarginX: CGFloat = 8.0
        let barRect = CGRect(
            x: barMarginX,
            y: topHeight + 2.5,
            width: rect.width - barMarginX * 2.0,
            height: 7.5
        )

        let clampedPower = CGFloat(min(max(telemetry.power, 0.0), 100.0))
        let fillWidth = barRect.width * (clampedPower / 100.0)
        let markerX = barRect.minX + fillWidth

        let trackPath = UIBezierPath(roundedRect: barRect, cornerRadius: 3)
        UIColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 1.0).setFill()
        trackPath.fill()

        if fillWidth > 0.5 {
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

        UIColor(white: 1.0, alpha: 0.34).setStroke()
        trackPath.lineWidth = 0.8
        trackPath.stroke()

        let tickAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 8.2, weight: .bold),
            .foregroundColor: UIColor(white: 0.86, alpha: 1.0)
        ]

        for step in stride(from: 0, through: 100, by: 10) {
            let tx = barRect.minX + barRect.width * (CGFloat(step) / 100.0)
            let isMajor = step % 20 == 0
            let tick = UIBezierPath()
            if isMajor {
                tick.move(to: CGPoint(x: tx, y: barRect.minY))
                tick.addLine(to: CGPoint(x: tx, y: barRect.maxY + 1.5))
                UIColor(white: 1.0, alpha: 0.82).setStroke()
                tick.lineWidth = 1.0
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
                label.draw(at: CGPoint(x: labelX, y: barRect.maxY + 1.0))
            } else {
                tick.move(to: CGPoint(x: tx, y: barRect.maxY - 3.0))
                tick.addLine(to: CGPoint(x: tx, y: barRect.maxY))
                UIColor(white: 1.0, alpha: 0.32).setStroke()
                tick.lineWidth = 0.7
                tick.stroke()
            }
        }

        // Kim chỉ thị màu đỏ rực tại vị trí `power`.
        let redNeedle = UIBezierPath()
        redNeedle.move(to: CGPoint(x: markerX, y: barRect.minY - 1.8))
        redNeedle.addLine(to: CGPoint(x: markerX, y: barRect.maxY + 1.8))
        redNeedle.lineCapStyle = .round
        UIColor(red: 1.0, green: 0.14, blue: 0.12, alpha: 1.0).setStroke()
        redNeedle.lineWidth = 3.4
        redNeedle.stroke()

        let whiteCore = UIBezierPath()
        whiteCore.move(to: CGPoint(x: markerX, y: barRect.minY - 1.0))
        whiteCore.addLine(to: CGPoint(x: markerX, y: barRect.maxY + 1.0))
        whiteCore.lineCapStyle = .round
        UIColor.white.setStroke()
        whiteCore.lineWidth = 1.2
        whiteCore.stroke()
    }

    private func drawFittedMetric(text: String, color: UIColor, baseSize: CGFloat, minSize: CGFloat, in rect: CGRect) {
        var fontSize = baseSize
        var attr = NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .heavy),
                .foregroundColor: color
            ]
        )
        var size = attr.size()
        while size.width > rect.width && fontSize > minSize {
            fontSize -= 0.5
            attr = NSAttributedString(
                string: text,
                attributes: [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .heavy),
                    .foregroundColor: color
                ]
            )
            size = attr.size()
        }
        attr.draw(at: CGPoint(
            x: rect.midX - size.width / 2.0,
            y: rect.midY - size.height / 2.0
        ))
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
