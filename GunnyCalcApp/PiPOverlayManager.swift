import AVFoundation
import AVKit
import CoreGraphics
import CoreMedia
import CoreVideo
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

/// Quản lý cửa sổ nổi Picture-in-Picture (`AVKit` + `AVSampleBufferDisplayLayer`) hiển thị thông số lực bắn theo thời gian thực.
@MainActor
final class PiPOverlayManager: NSObject, ObservableObject {
    static let shared = PiPOverlayManager()

    @Published private(set) var isPiPActive = false
    @Published private(set) var isPiPSupported = AVPictureInPictureController.isPictureInPictureSupported()
    @Published private(set) var statusMessage: String?

    let sampleBufferView = PiPSampleBufferView(frame: CGRect(x: 0, y: 0, width: 440, height: 148))

    private var pipController: AVPictureInPictureController?
    private var currentTelemetry: TelemetryData = .placeholder
    private var keepAliveTimer: Timer?

    private let renderSize = CGSize(width: 440, height: 148)
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()

    private override init() {
        super.init()
        configureAudioSession()
    }

    func configureIfNeeded() {
        guard pipController == nil else { return }

        sampleBufferView.displayLayer.videoGravity = .resizeAspect
        enqueueHUDFrame(for: currentTelemetry)

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            isPiPSupported = false
            statusMessage = "Thiết bị này không hỗ trợ Picture-in-Picture."
            return
        }

        isPiPSupported = true
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

    func togglePiP() {
        configureIfNeeded()
        configureAudioSession()

        guard let pipController else {
            statusMessage = "Không thể khởi tạo bộ điều khiển PiP."
            return
        }

        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            enqueueHUDFrame(for: currentTelemetry)
            pipController.startPictureInPicture()
        }
    }

    func startPiP() {
        configureIfNeeded()
        configureAudioSession()
        guard let pipController, !pipController.isPictureInPictureActive else { return }
        enqueueHUDFrame(for: currentTelemetry)
        pipController.startPictureInPicture()
    }

    func stopPiP() {
        guard let pipController, pipController.isPictureInPictureActive else { return }
        pipController.stopPictureInPicture()
    }

    func updateTelemetry(_ telemetry: TelemetryData) {
        currentTelemetry = telemetry
        configureIfNeeded()
        enqueueHUDFrame(for: telemetry)
    }

    // MARK: - Private Audio & Keep-Alive

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            statusMessage = "Không thể cấu hình Audio Session nền: \(error.localizedDescription)"
        }
    }

    private func startKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPiPActive else { return }
                self.enqueueHUDFrame(for: self.currentTelemetry)
            }
        }
    }

    private func stopKeepAliveTimer() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    // MARK: - CoreGraphics HUD Frame Rendering

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

        // Chuyển gốc tọa độ sang trên-trái để vẽ UIKit text & layout chuẩn xác.
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

    private func drawHUD(in rect: CGRect, telemetry: TelemetryData) {
        UIColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 1.0).setFill()
        UIRectFill(rect)

        let cardRect = rect.insetBy(dx: 8, dy: 8)
        let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: 16)
        UIColor(red: 0.12, green: 0.14, blue: 0.19, alpha: 1.0).setFill()
        cardPath.fill()
        UIColor(white: 1.0, alpha: 0.12).setStroke()
        cardPath.lineWidth = 1.5
        cardPath.stroke()

        // Thanh phân cách giữa Lực/Giữ và Gió/Góc.
        let dividerX = rect.width * 0.62
        let dividerPath = UIBezierPath()
        dividerPath.move(to: CGPoint(x: dividerX, y: 20))
        dividerPath.addLine(to: CGPoint(x: dividerX, y: rect.height - 20))
        UIColor(white: 1.0, alpha: 0.10).setStroke()
        dividerPath.lineWidth = 1
        dividerPath.stroke()

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: UIColor(white: 0.68, alpha: 1.0)
        ]

        let powerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 44, weight: .bold),
            .foregroundColor: UIColor(red: 0.22, green: 0.88, blue: 0.56, alpha: 1.0)
        ]

        let holdAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 22, weight: .bold),
            .foregroundColor: UIColor(red: 1.0, green: 0.78, blue: 0.24, alpha: 1.0)
        ]

        let metaLabelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: UIColor(white: 0.62, alpha: 1.0)
        ]

        let metaValueAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 22, weight: .bold),
            .foregroundColor: UIColor.white
        ]

        NSString(string: "LỰC BẮN").draw(at: CGPoint(x: 24, y: 20), withAttributes: titleAttrs)
        NSString(string: String(format: "%.1f", telemetry.calculatedPower))
            .draw(at: CGPoint(x: 22, y: 38), withAttributes: powerAttrs)

        let holdText = String(format: "GIỮ: %.2fs", telemetry.holdSeconds)
        NSString(string: holdText).draw(at: CGPoint(x: 24, y: 96), withAttributes: holdAttrs)

        let rightX = dividerX + 18
        let windSign = telemetry.wind > 0 ? "+" : ""
        let windText = String(format: "%@%.1f", windSign, telemetry.wind)
        NSString(string: "GIÓ").draw(at: CGPoint(x: rightX, y: 22), withAttributes: metaLabelAttrs)
        NSString(string: windText).draw(at: CGPoint(x: rightX, y: 38), withAttributes: metaValueAttrs)

        let angleText = String(format: "%.0f°", telemetry.angle)
        NSString(string: "GÓC").draw(at: CGPoint(x: rightX, y: 78), withAttributes: metaLabelAttrs)
        NSString(string: angleText).draw(at: CGPoint(x: rightX, y: 94), withAttributes: metaValueAttrs)
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPOverlayManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = true
            self.statusMessage = nil
            self.startKeepAliveTimer()
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            self.isPiPActive = false
            self.stopKeepAliveTimer()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            self.isPiPActive = false
            self.stopKeepAliveTimer()
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
