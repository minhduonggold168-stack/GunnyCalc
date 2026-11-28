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

/// Quản lý cửa sổ nổi Picture-in-Picture siêu gọn (`340 x 115` px, nhỏ hơn 50%):
/// - Chỉ hiển thị 2 thông số cỡ lớn (`GÓC` và `LỰC BẮN`) kèm thanh thước lực `0 — 20 — 40 — 60 — 80 — 100`.
/// - Đẩy `CMSampleBuffer` ngay lập tức trong callback nhận UDP (`127.0.0.1:45678`) để đạt độ trễ < 100ms.
@MainActor
final class PiPOverlayManager: NSObject, ObservableObject {
    static let shared = PiPOverlayManager()

    @Published private(set) var isPiPActive = false
    @Published private(set) var isReceivingLiveStream = false
    @Published private(set) var liveFPS: Int = 0
    @Published private(set) var latestFrameId: Int = 0
    @Published private(set) var statusMessage: String?

    let sampleBufferView = PiPSampleBufferView(frame: CGRect(x: 0, y: 0, width: 340, height: 115))

    private var pipController: AVPictureInPictureController?
    private var currentTelemetry: TelemetryData = .initialLive
    private var lastPacketReceivedAt: TimeInterval = 0
    private var lastPublishedStatsAt: TimeInterval = 0
    private var packetTimestamps: [TimeInterval] = []
    private var statsMonitorTimer: Timer?
    private var silentAudioPlayer: AVAudioPlayer?

    private let udpReceiver = BSDUDPReceiver()
    private var isUDPStarted = false

    private let renderSize = CGSize(width: 340, height: 115)
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
        let brightYellow = UIColor(red: 1.0, green: 0.86, blue: 0.10, alpha: 1.0)
        let lightGray = UIColor(white: 0.72, alpha: 1.0)

        // Nền đen bán trong suốt (alpha = 0.85) + viền mảnh xanh lá #00FF88.
        cgContext.clear(rect)
        let outerPath = UIBezierPath(roundedRect: rect.insetBy(dx: 1.2, dy: 1.2), cornerRadius: 10)
        UIColor(white: 0.0, alpha: 0.85).setFill()
        outerPath.fill()

        neonGreen.setStroke()
        outerPath.lineWidth = 1.5
        outerPath.stroke()

        // MARK: Phần trên (75px): 2 cột lớn GÓC & LỰC BẮN
        let topHeight: CGFloat = 75.0
        let midX = rect.width / 2.0

        let verticalSep = UIBezierPath()
        verticalSep.move(to: CGPoint(x: midX, y: 10))
        verticalSep.addLine(to: CGPoint(x: midX, y: topHeight - 8))
        UIColor(white: 1.0, alpha: 0.16).setStroke()
        verticalSep.lineWidth = 1.0
        verticalSep.stroke()

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11.0, weight: .bold),
            .foregroundColor: lightGray
        ]

        // Cột trái: GÓC (36pt vàng rực)
        let angleLabel = NSAttributedString(string: "GÓC", attributes: labelAttrs)
        let angleLabelSize = angleLabel.size()
        angleLabel.draw(at: CGPoint(x: midX / 2.0 - angleLabelSize.width / 2.0, y: 8))

        let angleValue = NSAttributedString(
            string: "\(telemetry.angle)°",
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 36.0, weight: .heavy),
                .foregroundColor: brightYellow
            ]
        )
        let angleValSize = angleValue.size()
        angleValue.draw(at: CGPoint(x: midX / 2.0 - angleValSize.width / 2.0, y: 22))

        // Cột phải: LỰC BẮN (36pt xanh neon #00FF88, 1 chữ số thập phân)
        let powerLabel = NSAttributedString(string: "LỰC BẮN", attributes: labelAttrs)
        let powerLabelSize = powerLabel.size()
        powerLabel.draw(at: CGPoint(x: midX + midX / 2.0 - powerLabelSize.width / 2.0, y: 8))

        let powerValue = NSAttributedString(
            string: String(format: "%.1f", telemetry.power),
            attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 36.0, weight: .heavy),
                .foregroundColor: neonGreen
            ]
        )
        let powerValSize = powerValue.size()
        powerValue.draw(at: CGPoint(x: midX + midX / 2.0 - powerValSize.width / 2.0, y: 22))

        // Đường ngăn ngang giữa phần trên (75px) và thanh thước lực (40px).
        let horizontalSep = UIBezierPath()
        horizontalSep.move(to: CGPoint(x: 8, y: topHeight))
        horizontalSep.addLine(to: CGPoint(x: rect.width - 8, y: topHeight))
        UIColor(white: 1.0, alpha: 0.16).setStroke()
        horizontalSep.lineWidth = 1.0
        horizontalSep.stroke()

        // MARK: Phần dưới (40px): Thanh thước lực 0 — 20 — 40 — 60 — 80 — 100 toàn chiều ngang 340px
        let barMarginX: CGFloat = 10.0
        let barRect = CGRect(
            x: barMarginX,
            y: topHeight + 6.0,
            width: rect.width - barMarginX * 2.0,
            height: 14.0
        )

        let clampedPower = CGFloat(min(max(telemetry.power, 0.0), 100.0))
        let fillWidth = barRect.width * (clampedPower / 100.0)
        let markerX = barRect.minX + fillWidth

        let trackPath = UIBezierPath(roundedRect: barRect, cornerRadius: 4)
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
        trackPath.lineWidth = 0.9
        trackPath.stroke()

        let tickAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold),
            .foregroundColor: UIColor(white: 0.84, alpha: 1.0)
        ]

        for step in stride(from: 0, through: 100, by: 10) {
            let tx = barRect.minX + barRect.width * (CGFloat(step) / 100.0)
            let isMajor = step % 20 == 0
            let tick = UIBezierPath()
            if isMajor {
                tick.move(to: CGPoint(x: tx, y: barRect.minY))
                tick.addLine(to: CGPoint(x: tx, y: barRect.maxY + 3.0))
                UIColor(white: 1.0, alpha: 0.80).setStroke()
                tick.lineWidth = 1.1
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
                label.draw(at: CGPoint(x: labelX, y: barRect.maxY + 3.5))
            } else {
                tick.move(to: CGPoint(x: tx, y: barRect.maxY - 4.5))
                tick.addLine(to: CGPoint(x: tx, y: barRect.maxY + 1.0))
                UIColor(white: 1.0, alpha: 0.30).setStroke()
                tick.lineWidth = 0.8
                tick.stroke()
            }
        }

        // Vạch kim đỏ rực chỉ chính xác vị trí `power` để canh thẳng xuống thanh lực game.
        let redNeedle = UIBezierPath()
        redNeedle.move(to: CGPoint(x: markerX, y: barRect.minY - 3.0))
        redNeedle.addLine(to: CGPoint(x: markerX, y: barRect.maxY + 3.0))
        redNeedle.lineCapStyle = .round
        UIColor(red: 1.0, green: 0.14, blue: 0.12, alpha: 1.0).setStroke()
        redNeedle.lineWidth = 3.8
        redNeedle.stroke()

        let whiteCore = UIBezierPath()
        whiteCore.move(to: CGPoint(x: markerX, y: barRect.minY - 2.0))
        whiteCore.addLine(to: CGPoint(x: markerX, y: barRect.maxY + 2.0))
        whiteCore.lineCapStyle = .round
        UIColor.white.setStroke()
        whiteCore.lineWidth = 1.4
        whiteCore.stroke()
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
