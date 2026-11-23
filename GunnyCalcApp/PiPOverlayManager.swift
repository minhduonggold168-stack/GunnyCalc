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

    let sampleBufferView = PiPSampleBufferView(frame: CGRect(x: 0, y: 0, width: 640, height: 280))

    private var pipController: AVPictureInPictureController?
    private var currentTelemetry: TelemetryData = .placeholder
    private var keepAliveTimer: Timer?
    private var isUDPListening = false

    private let renderSize = CGSize(width: 640, height: 280)
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    private let ballisticsEngine = BallisticsEngine()
    private let defaultFallbackPower: Double = 45.0

    private override init() {
        super.init()
        configureAudioSession()
    }

    func configureIfNeeded() {
        if !isUDPListening {
            isUDPListening = true
            SharedIPC.shared.startUDPTelemetryListener { [weak self] incoming in
                Task { @MainActor [weak self] in
                    self?.updateOverlay(with: incoming)
                }
            }
        }

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

    func updateOverlay(with telemetry: TelemetryData) {
        currentTelemetry = telemetry
        configureIfNeeded()
        enqueueHUDFrame(for: telemetry)
    }

    func updateTelemetry(_ telemetry: TelemetryData) {
        updateOverlay(with: telemetry)
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

    private func resolveDisplayTelemetry(_ telemetry: TelemetryData) -> (data: TelemetryData, isLive: Bool) {
        let now = Date().timeIntervalSince1970
        let hasLiveSignal = telemetry.timestamp > 0
            && (now - telemetry.timestamp) <= 4.0
            && telemetry.calculatedPower > 0.0

        let effectivePower = telemetry.calculatedPower > 0.0 ? telemetry.calculatedPower : defaultFallbackPower
        let effectiveAngle = telemetry.angle > 0.0 ? telemetry.angle : 65.0
        let effectiveDx = abs(telemetry.dx) > 0.0001 ? telemetry.dx : 0.48
        let effectiveHold = telemetry.calculatedPower > 0.0
            ? telemetry.holdSeconds
            : ballisticsEngine.calculateHoldSeconds(
                power: effectivePower,
                maxHoldSeconds: BallisticsConfig.default.maxHoldSeconds
            )

        let points: [TrajectoryPoint]
        if telemetry.trajectoryPoints.count >= 2 && telemetry.calculatedPower > 0.0 {
            points = telemetry.trajectoryPoints
        } else {
            points = ballisticsEngine.generateTrajectoryPoints(
                dx: effectiveDx,
                dy: telemetry.dy,
                angleDeg: effectiveAngle,
                wind: telemetry.wind,
                power: effectivePower
            )
        }

        let resolved = TelemetryData(
            dx: effectiveDx,
            dy: telemetry.dy,
            wind: telemetry.wind,
            angle: effectiveAngle,
            calculatedPower: effectivePower,
            holdSeconds: effectiveHold,
            timestamp: telemetry.timestamp,
            trajectoryPoints: points
        )
        return (resolved, hasLiveSignal)
    }

    private func drawHUD(in rect: CGRect, telemetry: TelemetryData) {
        let cgContext = UIGraphicsGetCurrentContext()
        let (displayTelemetry, isLive) = resolveDisplayTelemetry(telemetry)

        // Nền tối bán trong suốt & viền sáng sắc nét kích thước 640 x 280.
        UIColor(red: 0.03, green: 0.04, blue: 0.06, alpha: 0.88).setFill()
        UIRectFill(rect)

        let outerRect = rect.insetBy(dx: 2, dy: 2)
        let outerPath = UIBezierPath(roundedRect: outerRect, cornerRadius: 16)
        UIColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 0.94).setFill()
        outerPath.fill()

        UIColor(white: 1.0, alpha: 0.45).setStroke()
        outerPath.lineWidth = 2.0
        outerPath.stroke()

        let innerBorderPath = UIBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), cornerRadius: 14)
        UIColor(red: 0.0, green: 1.0, blue: 0.533, alpha: 0.22).setStroke()
        innerBorderPath.lineWidth = 1.0
        innerBorderPath.stroke()

        // Chia rõ 2 vùng: phần trên 185px (quỹ đạo) và phần dưới 95px (thanh lực).
        let splitY: CGFloat = 185.0
        let dividerPath = UIBezierPath()
        dividerPath.move(to: CGPoint(x: 14, y: splitY))
        dividerPath.addLine(to: CGPoint(x: rect.width - 14, y: splitY))
        UIColor(white: 1.0, alpha: 0.20).setStroke()
        dividerPath.lineWidth = 1.0
        dividerPath.stroke()

        drawTrajectorySection(
            in: CGRect(x: 0, y: 0, width: rect.width, height: splitY),
            telemetry: displayTelemetry,
            isLive: isLive,
            cgContext: cgContext
        )

        drawPowerGaugeSection(
            in: CGRect(x: 0, y: splitY, width: rect.width, height: rect.height - splitY),
            telemetry: displayTelemetry,
            cgContext: cgContext
        )
    }

    // MARK: - Phần trên (185px): Khung đường kẻ quỹ đạo đến địch

    private func drawTrajectorySection(
        in sectionRect: CGRect,
        telemetry: TelemetryData,
        isLive: Bool,
        cgContext: CGContext?
    ) {
        let plotRect = CGRect(
            x: 16,
            y: 36,
            width: sectionRect.width - 32,
            height: sectionRect.height - 44
        )

        // Nền vùng plot quỹ đạo & lưới tọa độ mờ.
        let plotBg = UIBezierPath(roundedRect: plotRect, cornerRadius: 10)
        UIColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 0.85).setFill()
        plotBg.fill()
        UIColor(white: 1.0, alpha: 0.10).setStroke()
        plotBg.lineWidth = 1.0
        plotBg.stroke()

        cgContext?.saveGState()
        plotBg.addClip()

        let gridPath = UIBezierPath()
        let verticalDivisions = 8
        for idx in 1..<verticalDivisions {
            let gx = plotRect.minX + (plotRect.width * CGFloat(idx) / CGFloat(verticalDivisions))
            gridPath.move(to: CGPoint(x: gx, y: plotRect.minY))
            gridPath.addLine(to: CGPoint(x: gx, y: plotRect.maxY))
        }
        let horizontalDivisions = 4
        for idx in 1..<horizontalDivisions {
            let gy = plotRect.minY + (plotRect.height * CGFloat(idx) / CGFloat(horizontalDivisions))
            gridPath.move(to: CGPoint(x: plotRect.minX, y: gy))
            gridPath.addLine(to: CGPoint(x: plotRect.maxX, y: gy))
        }
        UIColor(white: 1.0, alpha: 0.07).setStroke()
        gridPath.lineWidth = 0.8
        gridPath.stroke()

        // Xác định danh sách điểm quỹ đạo hoặc điểm người chơi / mục tiêu mặc định.
        let mappedPoints: [CGPoint] = telemetry.trajectoryPoints.map { pt in
            CGPoint(
                x: plotRect.minX + CGFloat(pt.x) * plotRect.width,
                y: plotRect.minY + CGFloat(pt.y) * plotRect.height
            )
        }

        let playerPoint: CGPoint
        let targetPoint: CGPoint
        if let first = mappedPoints.first, let last = mappedPoints.last, mappedPoints.count >= 2 {
            playerPoint = first
            targetPoint = last
        } else {
            let shootsRight = telemetry.dx >= 0.0
            let leftX = plotRect.minX + plotRect.width * 0.12
            let rightX = plotRect.minX + plotRect.width * 0.88
            let baselineY = plotRect.minY + plotRect.height * 0.78
            playerPoint = CGPoint(x: shootsRight ? leftX : rightX, y: baselineY)
            let clampedDy = min(max(telemetry.dy, -0.5), 0.5)
            let targetY = min(max(baselineY - CGFloat(clampedDy) * plotRect.height * 0.7, plotRect.minY + 18), plotRect.maxY - 14)
            targetPoint = CGPoint(x: shootsRight ? rightX : leftX, y: targetY)
        }

        // Đường mặt đất ngang tại cao độ người chơi.
        let groundY = min(max(playerPoint.y, plotRect.minY + 14), plotRect.maxY - 10)
        let groundPath = UIBezierPath()
        groundPath.move(to: CGPoint(x: plotRect.minX, y: groundY))
        groundPath.addLine(to: CGPoint(x: plotRect.maxX, y: groundY))
        UIColor(red: 0.35, green: 0.75, blue: 0.55, alpha: 0.32).setStroke()
        groundPath.lineWidth = 1.4
        groundPath.stroke()

        // Đường cong parabol nét đứt màu xanh lá neon (#00FF88).
        if mappedPoints.count >= 2 {
            let curvePath = UIBezierPath()
            curvePath.move(to: mappedPoints[0])
            for pt in mappedPoints.dropFirst() {
                curvePath.addLine(to: pt)
            }

            let dashPattern: [CGFloat] = [8.0, 5.0]
            curvePath.lineCapStyle = .round
            curvePath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)

            // Lớp phát sáng nhẹ bên ngoài.
            UIColor(red: 0.0, green: 1.0, blue: 0.533, alpha: 0.28).setStroke()
            curvePath.lineWidth = 5.5
            curvePath.stroke()

            // Đường nét đứt neon chính sắc nét.
            UIColor(red: 0.0, green: 1.0, blue: 0.533, alpha: 1.0).setStroke()
            curvePath.lineWidth = 2.4
            curvePath.stroke()
        }

        // Điểm người chơi: hình tròn xanh dương phát sáng.
        let playerGlow = UIBezierPath(arcCenter: playerPoint, radius: 11, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        UIColor(red: 0.18, green: 0.62, blue: 1.0, alpha: 0.32).setFill()
        playerGlow.fill()

        let playerCircle = UIBezierPath(arcCenter: playerPoint, radius: 6, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        UIColor(red: 0.16, green: 0.65, blue: 1.0, alpha: 1.0).setFill()
        playerCircle.fill()
        UIColor.white.setStroke()
        playerCircle.lineWidth = 1.6
        playerCircle.stroke()

        // Điểm mục tiêu địch: hình tròn đỏ có tâm ngắm.
        let enemyGlow = UIBezierPath(arcCenter: targetPoint, radius: 11, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        UIColor(red: 1.0, green: 0.22, blue: 0.22, alpha: 0.28).setFill()
        enemyGlow.fill()

        let enemyRing = UIBezierPath(arcCenter: targetPoint, radius: 6.5, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        UIColor(red: 1.0, green: 0.24, blue: 0.24, alpha: 0.95).setFill()
        enemyRing.fill()
        UIColor.white.setStroke()
        enemyRing.lineWidth = 1.4
        enemyRing.stroke()

        let reticlePath = UIBezierPath()
        let arm: CGFloat = 10.5
        reticlePath.move(to: CGPoint(x: targetPoint.x - arm, y: targetPoint.y))
        reticlePath.addLine(to: CGPoint(x: targetPoint.x + arm, y: targetPoint.y))
        reticlePath.move(to: CGPoint(x: targetPoint.x, y: targetPoint.y - arm))
        reticlePath.addLine(to: CGPoint(x: targetPoint.x, y: targetPoint.y + arm))
        UIColor(red: 1.0, green: 0.85, blue: 0.85, alpha: 0.95).setStroke()
        reticlePath.lineWidth = 1.2
        reticlePath.stroke()

        cgContext?.restoreGState()

        // Thanh thông số gọn ở góc trên: Góc | Gió | Giữ.
        let windSign = telemetry.wind > 0 ? "+" : ""
        let headerText = String(
            format: "Góc: %.0f°  |  Gió: %@%.1f  |  Giữ: %.2fs",
            telemetry.angle,
            windSign,
            telemetry.wind,
            telemetry.holdSeconds
        )
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 13.5, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        let attrHeader = NSAttributedString(string: headerText, attributes: headerAttrs)
        let headerSize = attrHeader.size()
        let pillRect = CGRect(
            x: 16,
            y: 8,
            width: min(sectionRect.width - 110, headerSize.width + 20),
            height: 22
        )
        let pillPath = UIBezierPath(roundedRect: pillRect, cornerRadius: 7)
        UIColor(red: 0.12, green: 0.15, blue: 0.22, alpha: 0.95).setFill()
        pillPath.fill()
        UIColor(white: 1.0, alpha: 0.18).setStroke()
        pillPath.lineWidth = 1.0
        pillPath.stroke()

        attrHeader.draw(at: CGPoint(x: pillRect.minX + 10, y: pillRect.minY + (pillRect.height - headerSize.height) / 2.0))

        // Chấm trạng thái ở góc trên bên phải PiP: xanh lá khi nhận dữ liệu sống, vàng khi chờ tín hiệu.
        let statusColor = isLive
            ? UIColor(red: 0.0, green: 1.0, blue: 0.533, alpha: 1.0)
            : UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1.0)
        let statusText = isLive ? "LIVE" : "CHỜ"
        let statusAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10.5, weight: .bold),
            .foregroundColor: statusColor
        ]
        let attrStatus = NSAttributedString(string: statusText, attributes: statusAttrs)
        let statusTextSize = attrStatus.size()
        let statusPillWidth = statusTextSize.width + 26.0
        let statusPillRect = CGRect(
            x: sectionRect.width - statusPillWidth - 16.0,
            y: 8,
            width: statusPillWidth,
            height: 22
        )
        let statusPill = UIBezierPath(roundedRect: statusPillRect, cornerRadius: 7)
        UIColor(red: 0.10, green: 0.13, blue: 0.19, alpha: 0.95).setFill()
        statusPill.fill()
        statusColor.withAlphaComponent(0.45).setStroke()
        statusPill.lineWidth = 1.0
        statusPill.stroke()

        let dotCenter = CGPoint(x: statusPillRect.minX + 11.0, y: statusPillRect.midY)
        statusColor.withAlphaComponent(0.35).setFill()
        UIBezierPath(arcCenter: dotCenter, radius: 6.5, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()
        statusColor.setFill()
        UIBezierPath(arcCenter: dotCenter, radius: 3.8, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()

        attrStatus.draw(at: CGPoint(
            x: statusPillRect.minX + 20.0,
            y: statusPillRect.minY + (statusPillRect.height - statusTextSize.height) / 2.0
        ))
    }

    // MARK: - Phần dưới (95px): Thanh vạch lực bắn trực quan (0 - 100)

    private func drawPowerGaugeSection(in sectionRect: CGRect, telemetry: TelemetryData, cgContext: CGContext?) {
        let barMarginX: CGFloat = 22.0
        let barRect = CGRect(
            x: barMarginX,
            y: sectionRect.minY + 42.0,
            width: sectionRect.width - barMarginX * 2.0,
            height: 22.0
        )

        let clampedPower = CGFloat(min(max(telemetry.calculatedPower, 0.0), 100.0))
        let fillWidth = barRect.width * (clampedPower / 100.0)
        let markerX = barRect.minX + fillWidth

        // Nền thanh lực tối.
        let trackPath = UIBezierPath(roundedRect: barRect, cornerRadius: 6)
        UIColor(red: 0.12, green: 0.14, blue: 0.19, alpha: 1.0).setFill()
        trackPath.fill()

        // Tô màu từ 0 đến calculatedPower bằng gradient Vàng -> Cam -> Đỏ.
        if fillWidth > 0.5, let cgContext {
            cgContext.saveGState()
            let fillClipRect = CGRect(x: barRect.minX, y: barRect.minY, width: fillWidth, height: barRect.height)
            trackPath.addClip()
            cgContext.clip(to: fillClipRect)

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

        // Viền ngoài thanh lực.
        UIColor(white: 1.0, alpha: 0.35).setStroke()
        trackPath.lineWidth = 1.2
        trackPath.stroke()

        // Chia vạch nhỏ mỗi 5 đơn vị và vạch lớn + nhãn tại 0, 25, 50, 75, 100.
        let tickLabelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor(white: 0.78, alpha: 1.0)
        ]

        for step in stride(from: 0, through: 100, by: 5) {
            let ratio = CGFloat(step) / 100.0
            let tx = barRect.minX + barRect.width * ratio
            let isMajor = step % 25 == 0

            let tickPath = UIBezierPath()
            if isMajor {
                tickPath.move(to: CGPoint(x: tx, y: barRect.minY))
                tickPath.addLine(to: CGPoint(x: tx, y: barRect.maxY + 4))
                UIColor(white: 1.0, alpha: 0.72).setStroke()
                tickPath.lineWidth = 1.4
                tickPath.stroke()

                let label = NSAttributedString(string: "\(step)", attributes: tickLabelAttrs)
                let labelSize = label.size()
                let labelX: CGFloat
                if step == 0 {
                    labelX = tx
                } else if step == 100 {
                    labelX = tx - labelSize.width
                } else {
                    labelX = tx - labelSize.width / 2.0
                }
                label.draw(at: CGPoint(x: labelX, y: barRect.maxY + 6))
            } else {
                tickPath.move(to: CGPoint(x: tx, y: barRect.maxY - 6))
                tickPath.addLine(to: CGPoint(x: tx, y: barRect.maxY))
                UIColor(white: 1.0, alpha: 0.25).setStroke()
                tickPath.lineWidth = 0.8
                tickPath.stroke()
            }
        }

        // Vạch chỉ thị dọc màu trắng/đỏ nổi bật tại vị trí lực cần bắn.
        let markerTop = barRect.minY - 5
        let markerBottom = barRect.maxY + 5

        let redMarkerPath = UIBezierPath()
        redMarkerPath.move(to: CGPoint(x: markerX, y: markerTop))
        redMarkerPath.addLine(to: CGPoint(x: markerX, y: markerBottom))
        redMarkerPath.lineCapStyle = .round
        UIColor(red: 1.0, green: 0.18, blue: 0.18, alpha: 0.95).setStroke()
        redMarkerPath.lineWidth = 5.0
        redMarkerPath.stroke()

        let whiteMarkerPath = UIBezierPath()
        whiteMarkerPath.move(to: CGPoint(x: markerX, y: markerTop + 1))
        whiteMarkerPath.addLine(to: CGPoint(x: markerX, y: markerBottom - 1))
        whiteMarkerPath.lineCapStyle = .round
        UIColor.white.setStroke()
        whiteMarkerPath.lineWidth = 2.2
        whiteMarkerPath.stroke()

        // Con số lực lớn ngay phía trên vạch chỉ thị.
        let powerText = String(format: "%.1f", clampedPower)
        let powerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 24, weight: .heavy),
            .foregroundColor: UIColor.white
        ]
        let attrPower = NSAttributedString(string: powerText, attributes: powerAttrs)
        let powerSize = attrPower.size()
        let desiredPowerX = markerX - powerSize.width / 2.0
        let clampedPowerX = min(max(desiredPowerX, barRect.minX), barRect.maxX - powerSize.width)
        let powerY = sectionRect.minY + 7.0

        let badgeRect = CGRect(
            x: clampedPowerX - 7,
            y: powerY - 1,
            width: powerSize.width + 14,
            height: powerSize.height + 2
        )
        let badgePath = UIBezierPath(roundedRect: badgeRect, cornerRadius: 6)
        UIColor(red: 0.88, green: 0.18, blue: 0.14, alpha: 0.92).setFill()
        badgePath.fill()
        UIColor(white: 1.0, alpha: 0.85).setStroke()
        badgePath.lineWidth = 1.0
        badgePath.stroke()

        attrPower.draw(at: CGPoint(x: clampedPowerX, y: powerY))
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
